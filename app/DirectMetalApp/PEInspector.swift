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

enum PEInspector {
    static func inspect(exePath: String) throws -> PEProfile {
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

        var upscalers: [String] = []
        if lowerDLLs.contains(where: { $0.contains("nvngx") }) { upscalers.append("DLSS") }
        if lowerDLLs.contains(where: { $0.contains("ffx_fsr") || $0.contains("fidelityfx") }) { upscalers.append("FSR") }
        if lowerDLLs.contains(where: { $0.contains("libxess") }) { upscalers.append("XeSS") }

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
