import CryptoKit
import Foundation

struct PEProfile: Codable {
    let path: String
    let fileName: String
    let architecture: String
    let is64Bit: Bool
    let timeDateStamp: UInt32
    let sizeOfImage: UInt32
    let buildHash: String
    let importedDLLs: [String]
    let detectedAPIs: [String]
    let detectedUpscalers: [String]
}

enum PEInspectError: Error, CustomStringConvertible {
    case unreadableFile(String)
    case invalidHeader(String)

    var description: String {
        switch self {
        case .unreadableFile(let m), .invalidHeader(let m):
            return m
        }
    }
}

private struct SectionSpan {
    let virtualAddress: UInt32
    let virtualSize: UInt32
    let pointerToRawData: UInt32
    let sizeOfRawData: UInt32
}

private extension Data {
    func readUInt16LE(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func readUInt32LE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    func readCString(at offset: Int, maxLen: Int = 256) -> String? {
        guard offset >= 0, offset < count else { return nil }
        let limit = Swift.min(count, offset + maxLen)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        var i = offset
        while i < limit {
            let b = self[i]
            if b == 0 { break }
            bytes.append(b)
            i += 1
        }
        return String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .ascii)
    }
}

/// Disk-backed memo of `PEInspector` results at `~/Library/Caches/DirectMetal/pe_inspect_cache.json`.
///
/// Keyed by canonical (`realpath`) EXE path and validated with a handful of `stat(2)` calls:
///   * EXE `(mtime, size)`
///   * mtimes of every directory whose listing feeds detection (EXE dir, Source `bin/`, `bin/x64/`,
///     UE `Engine/Plugins/Marketplace`), so newly dropped DLSS/FSR/XeSS plugins invalidate cleanly.
/// `DIRECTMETAL_PE_CACHE_PATH` overrides the location; `DIRECTMETAL_DISABLE_PE_CACHE=1` bypasses it.
private final class PEInspectCache: @unchecked Sendable {
    struct Entry: Codable {
        let mtime: Double
        let size: UInt64
        let dirMtimes: [Double]
        let profile: PEProfile
    }

    static let shared = PEInspectCache()
    static let schemaVersion = 1

    private struct DiskFormat: Codable {
        let version: Int
        let entries: [String: Entry]
    }

    private let lock = NSLock()
    private var entries: [String: Entry]?
    let disabled: Bool
    let fileURL: URL

    private init() {
        let env = ProcessInfo.processInfo.environment
        disabled = env["DIRECTMETAL_DISABLE_PE_CACHE"] == "1"
        if let p = env["DIRECTMETAL_PE_CACHE_PATH"], !p.isEmpty {
            fileURL = URL(fileURLWithPath: p)
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            fileURL = caches.appendingPathComponent("DirectMetal/pe_inspect_cache.json")
        }
    }

    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Returns `(mtime, size)` for a file, or nil if it cannot be stat'ed.
    static func statFile(_ path: String) -> (mtime: Double, size: UInt64)? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        let mt = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000.0
        return (mt, UInt64(st.st_size))
    }

    /// Mtimes of the directories `inspectUncached` lists (same derivation as the uncached scan).
    static func neighborhoodMtimes(exePath: String) -> [Double] {
        let exeDir = (exePath as NSString).deletingLastPathComponent
        // UE5 layout: <GameRoot>/<Project>/Binaries/Win64/<Game>.exe -> <GameRoot>/Engine/Plugins/Marketplace
        var ueRoot = exeDir
        for _ in 0..<3 { ueRoot = (ueRoot as NSString).deletingLastPathComponent }
        let dirs = [
            exeDir,
            exeDir + "/bin",
            exeDir + "/bin/x64",
            ueRoot + "/Engine/Plugins/Marketplace",
        ]
        return dirs.map { statFile($0)?.mtime ?? 0 }
    }

    private func loadLocked() -> [String: Entry] {
        if let e = entries { return e }
        var loaded: [String: Entry] = [:]
        if let data = try? Data(contentsOf: fileURL),
           let disk = try? JSONDecoder().decode(DiskFormat.self, from: data),
           disk.version == Self.schemaVersion {
            loaded = disk.entries
        }
        entries = loaded
        return loaded
    }

    func lookup(key: String, mtime: Double, size: UInt64, dirMtimes: [Double]) -> PEProfile? {
        lock.lock()
        defer { lock.unlock() }
        guard let e = loadLocked()[key],
              e.mtime == mtime, e.size == size, e.dirMtimes == dirMtimes else { return nil }
        return e.profile
    }

    func store(key: String, entry: Entry) {
        lock.lock()
        defer { lock.unlock() }
        var all = loadLocked()
        all[key] = entry
        if all.count > 4096 {
            all = all.filter { access($0.key, F_OK) == 0 }
        }
        entries = all
        let disk = DiskFormat(version: Self.schemaVersion, entries: all)
        guard let data = try? JSONEncoder().encode(disk) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}

enum PEInspector {
    static func inspect(exePath: String) throws -> PEProfile {
        let cache = PEInspectCache.shared
        guard !cache.disabled else { return try inspectUncached(exePath: exePath) }

        let url = URL(fileURLWithPath: exePath)
        let key = PEInspectCache.canonicalPath(url.path)
        guard let st = PEInspectCache.statFile(key) else {
            return try inspectUncached(exePath: exePath)
        }
        let dirMtimes = PEInspectCache.neighborhoodMtimes(exePath: url.path)

        if let hit = cache.lookup(key: key, mtime: st.mtime, size: st.size, dirMtimes: dirMtimes) {
            // Preserve caller-visible path fields exactly as an uncached inspect would report them.
            if hit.path == url.path { return hit }
            return PEProfile(
                path: url.path,
                fileName: url.lastPathComponent,
                architecture: hit.architecture,
                is64Bit: hit.is64Bit,
                timeDateStamp: hit.timeDateStamp,
                sizeOfImage: hit.sizeOfImage,
                buildHash: hit.buildHash,
                importedDLLs: hit.importedDLLs,
                detectedAPIs: hit.detectedAPIs,
                detectedUpscalers: hit.detectedUpscalers
            )
        }

        let profile = try inspectUncached(exePath: exePath)
        cache.store(key: key, entry: .init(mtime: st.mtime, size: st.size, dirMtimes: dirMtimes, profile: profile))
        return profile
    }

    private static func inspectUncached(exePath: String) throws -> PEProfile {
        let url = URL(fileURLWithPath: exePath)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw PEInspectError.unreadableFile("Cannot open PE binary at \(exePath)")
        }

        guard let mz = data.readUInt16LE(at: 0), mz == 0x5A4D else {
            throw PEInspectError.invalidHeader("Missing MZ signature")
        }
        guard let peOffsetU32 = data.readUInt32LE(at: 0x3C) else {
            throw PEInspectError.invalidHeader("Truncated DOS header")
        }
        let peOffset = Int(peOffsetU32)
        guard let peSig = data.readUInt32LE(at: peOffset), peSig == 0x0000_4550 else {
            throw PEInspectError.invalidHeader("Missing PE\\0\\0 signature")
        }

        let coffOffset = peOffset + 4
        guard
            let machine = data.readUInt16LE(at: coffOffset),
            let numSections = data.readUInt16LE(at: coffOffset + 2),
            let timeDateStamp = data.readUInt32LE(at: coffOffset + 4),
            let sizeOfOptional = data.readUInt16LE(at: coffOffset + 16)
        else {
            throw PEInspectError.invalidHeader("Truncated COFF header")
        }

        let optOffset = coffOffset + 20
        guard let optMagic = data.readUInt16LE(at: optOffset) else {
            throw PEInspectError.invalidHeader("Missing optional header")
        }
        let isPE32Plus = (optMagic == 0x020B)
        guard optMagic == 0x010B || isPE32Plus else {
            throw PEInspectError.invalidHeader("Unknown PE optional header magic 0x\(String(optMagic, radix: 16))")
        }

        let sizeOfImage = data.readUInt32LE(at: optOffset + 56) ?? 0
        let dataDirBase = optOffset + (isPE32Plus ? 112 : 96)
        let numRvaAndSizes = data.readUInt32LE(at: optOffset + (isPE32Plus ? 108 : 92)) ?? 0

        let secBase = optOffset + Int(sizeOfOptional)
        var sections: [SectionSpan] = []
        sections.reserveCapacity(Int(numSections))
        for i in 0..<Int(numSections) {
            let sOff = secBase + i * 40
            guard
                let vSize = data.readUInt32LE(at: sOff + 8),
                let vAddr = data.readUInt32LE(at: sOff + 12),
                let rSize = data.readUInt32LE(at: sOff + 16),
                let rPtr = data.readUInt32LE(at: sOff + 20)
            else { continue }
            sections.append(SectionSpan(virtualAddress: vAddr, virtualSize: vSize, pointerToRawData: rPtr, sizeOfRawData: rSize))
        }

        func rvaToOffset(_ rva: UInt32) -> Int? {
            for s in sections {
                let span = Swift.max(s.virtualSize, s.sizeOfRawData)
                if rva >= s.virtualAddress && rva < s.virtualAddress + span {
                    let delta = rva - s.virtualAddress
                    let raw = s.pointerToRawData + delta
                    return raw < UInt32(data.count) ? Int(raw) : nil
                }
            }
            return rva < UInt32(data.count) ? Int(rva) : nil
        }

        var dllSet: [String] = []
        var seen = Set<String>()
        func addDLL(_ name: String) {
            let low = name.lowercased()
            if !low.isEmpty && !seen.contains(low) {
                seen.insert(low)
                dllSet.append(name)
            }
        }

        // Standard Import Directory (DataDirectory[1])
        if numRvaAndSizes > 1,
           let impRVA = data.readUInt32LE(at: dataDirBase + 1 * 8),
           impRVA != 0,
           var cursor = rvaToOffset(impRVA) {
            for _ in 0..<512 {
                guard
                    let origThunk = data.readUInt32LE(at: cursor),
                    let nameRVA = data.readUInt32LE(at: cursor + 12),
                    let firstThunk = data.readUInt32LE(at: cursor + 16)
                else { break }
                if origThunk == 0 && nameRVA == 0 && firstThunk == 0 { break }
                if let nameOff = rvaToOffset(nameRVA), let dll = data.readCString(at: nameOff) {
                    addDLL(dll)
                }
                cursor += 20
            }
        }

        // Delay-Load Import Directory (DataDirectory[13])
        if numRvaAndSizes > 13,
           let delayRVA = data.readUInt32LE(at: dataDirBase + 13 * 8),
           delayRVA != 0,
           var cursor = rvaToOffset(delayRVA) {
            for _ in 0..<256 {
                guard
                    let attrs = data.readUInt32LE(at: cursor),
                    let nameRVA = data.readUInt32LE(at: cursor + 4)
                else { break }
                if attrs == 0 && nameRVA == 0 { break }
                if let nameOff = rvaToOffset(nameRVA), let dll = data.readCString(at: nameOff) {
                    addDLL(dll)
                }
                cursor += 32
            }
        }

        let arch: String
        switch machine {
        case 0x8664: arch = "x86_64"
        case 0x014C: arch = "x86"
        case 0xAA64: arch = "ARM64"
        case 0xA641: arch = "ARM64EC"
        default: arch = "0x\(String(machine, radix: 16))"
        }

        let lowerDLLs = dllSet.map { $0.lowercased() }
        var apis: [String] = []
        if lowerDLLs.contains(where: { $0 == "d3d12.dll" }) { apis.append("D3D12") }
        if lowerDLLs.contains(where: { $0 == "d3d11.dll" }) { apis.append("D3D11") }
        if lowerDLLs.contains(where: { $0 == "d3d10.dll" || $0 == "d3d10_1.dll" || $0 == "d3d10core.dll" }) {
            apis.append("D3D10")
        }
        if lowerDLLs.contains(where: { $0 == "d3d9.dll" || $0.hasPrefix("d3dx9_") }) {
            apis.append("D3D9")
        }
        if lowerDLLs.contains(where: { $0 == "dxgi.dll" }) { apis.append("DXGI") }

        let exeDir = url.deletingLastPathComponent()
        let fm = FileManager.default
        // Source Engine / dynamically loaded D3D9 games (e.g., Team Fortress 2 loads bin/x64/shaderapidx9.dll)
        if apis.isEmpty {
            let sourceDX9Paths = [
                exeDir.appendingPathComponent("bin/x64/shaderapidx9.dll").path,
                exeDir.appendingPathComponent("bin/shaderapidx9.dll").path,
                exeDir.appendingPathComponent("shaderapidx9.dll").path,
            ]
            if sourceDX9Paths.contains(where: { fm.fileExists(atPath: $0) }) {
                apis.append("D3D9")
            }
        }

        var upscalers: [String] = []
        func addUpscaler(_ name: String) {
            if !upscalers.contains(name) { upscalers.append(name) }
        }
        if lowerDLLs.contains(where: { $0.contains("nvngx") }) { addUpscaler("DLSS") }
        if lowerDLLs.contains(where: { $0.contains("ffx_fsr") || $0.contains("fidelityfx") }) { addUpscaler("FSR") }
        if lowerDLLs.contains(where: { $0.contains("libxess") }) { addUpscaler("XeSS") }

        // Also scan game binary directory & Unreal Engine plugin directories for dynamically loaded upscaler DLLs
        var searchDirs: [URL] = [exeDir]
        // UE5 layout: <GameRoot>/<Project>/Binaries/Win64/<Game>.exe -> <GameRoot>/Engine/Plugins/Marketplace
        let ueRoot = exeDir
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let uePlugins = ueRoot.appendingPathComponent("Engine/Plugins/Marketplace", isDirectory: true)
        if fm.fileExists(atPath: uePlugins.path) {
            searchDirs.append(uePlugins)
        }
        for dir in searchDirs {
            if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for item in items {
                    let low = item.lastPathComponent.lowercased()
                    if low.contains("nvngx_dlss") || low == "dlss" { addUpscaler("DLSS") }
                    if low.contains("amd_fidelityfx") || low.contains("ffx_fsr") || low == "fsr" || low == "fsr3" { addUpscaler("FSR") }
                    if low.contains("libxess") || low == "xess" { addUpscaler("XeSS") }
                }
            }
        }

        let digest = SHA256.hash(data: data.prefix(65536))
        let shortHash = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        let buildHash = "\(shortHash)_\(timeDateStamp)_\(sizeOfImage)"

        return PEProfile(
            path: url.path,
            fileName: url.lastPathComponent,
            architecture: arch,
            is64Bit: isPE32Plus,
            timeDateStamp: timeDateStamp,
            sizeOfImage: sizeOfImage,
            buildHash: buildHash,
            importedDLLs: dllSet,
            detectedAPIs: apis,
            detectedUpscalers: upscalers
        )
    }
}
