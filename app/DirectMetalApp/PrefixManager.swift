import Darwin
import Foundation

struct PrefixMetadata: Codable {
    let createdUtc: String
    let basePrefix: String
    let gameExe: String
    let dxApi: String
    let shaderCacheKey: String
    let cowCloneMs: Double

    enum CodingKeys: String, CodingKey {
        case createdUtc = "created_utc"
        case basePrefix = "base_prefix"
        case gameExe = "game_exe"
        case dxApi = "dx_api"
        case shaderCacheKey = "shader_cache_key"
        case cowCloneMs = "cow_clone_ms"
    }
}

enum PrefixError: Error, CustomStringConvertible {
    case missingBasePrefix(String)
    case cloneFailed(String)

    var description: String {
        switch self {
        case .missingBasePrefix(let m), .cloneFailed(let m):
            return m
        }
    }
}

final class PrefixManager {
    let prefixRoot: URL

    init(prefixRoot: URL? = nil) {
        if let root = prefixRoot {
            self.prefixRoot = root
        } else if let env = ProcessInfo.processInfo.environment["DIRECTMETAL_PREFIX_ROOT"], !env.isEmpty {
            self.prefixRoot = URL(fileURLWithPath: env, isDirectory: true)
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.prefixRoot = appSupport
                .appendingPathComponent("DirectMetal", isDirectory: true)
                .appendingPathComponent("Prefixes", isDirectory: true)
        }
    }

    func prefixURL(named name: String) -> URL {
        let sanitized = name.replacingOccurrences(of: "/", with: "_")
        return prefixRoot.appendingPathComponent(sanitized, isDirectory: true)
    }

    func createOrEnsure(name: String,
                        basePrefix: URL,
                        gameExe: String = "",
                        dxApi: String = "auto",
                        shaderCacheKey: String = "",
                        forceReset: Bool = false) throws -> (url: URL, clonedNow: Bool, cloneMs: Double) {
        let fm = FileManager.default
        let dest = prefixURL(named: name)

        // Hot path: existing prefix -> a single access(2), no base-prefix probing / hydration at all.
        if !forceReset && access(dest.path, F_OK) == 0 {
            return (dest, false, 0.0)
        }

        // Accept a slim `base-prefix-dehydrated/` bundle transparently (hydrates once per runtime fingerprint).
        var basePrefix = basePrefix
        if access(basePrefix.appendingPathComponent("system.reg").path, F_OK) != 0,
           BasePrefixHydrator.isDehydratedBundle(basePrefix) {
            basePrefix = try BasePrefixHydrator.resolveOrHydrate(dehydratedDir: basePrefix)
        }
        guard access(basePrefix.appendingPathComponent("system.reg").path, F_OK) == 0 else {
            throw PrefixError.missingBasePrefix("Golden base prefix not initialized at \(basePrefix.path). Run scripts/setup_runtime.sh first.")
        }
        try fm.createDirectory(at: prefixRoot, withIntermediateDirectories: true)

        if forceReset && fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }

        if fm.fileExists(atPath: dest.path) {
            return (dest, false, 0.0)
        }

        let elapsedMs = try Self.cloneTree(from: basePrefix, to: dest)
        // Hydration marker belongs to the shared golden prefix only.
        unlink(dest.appendingPathComponent(BasePrefixHydrator.markerFileName).path)
        // Ensure Z: drive symlink exists (stripped from --include-rosetta bundles for strict codesign compliance).
        let dosdevices = dest.appendingPathComponent("dosdevices", isDirectory: true)
        let zDrive = dosdevices.appendingPathComponent("z:")
        if access(dosdevices.path, F_OK) == 0 && access(zDrive.path, F_OK) != 0 {
            _ = symlink("/", zDrive.path)
        }

        let formatter = ISO8601DateFormatter()
        let meta = PrefixMetadata(
            createdUtc: formatter.string(from: Date()),
            basePrefix: basePrefix.path,
            gameExe: gameExe,
            dxApi: dxApi,
            shaderCacheKey: shaderCacheKey,
            cowCloneMs: elapsedMs
        )
        if let jsonData = try? JSONEncoder().encode(meta) {
            try? jsonData.write(to: dest.appendingPathComponent("directmetal_prefix.json"))
        }

        return (dest, true, elapsedMs)
    }

    /// Clones a whole directory tree with a single Darwin `clonefile(2)` syscall (APFS copy-on-write,
    /// no `/bin/cp` fork/exec). Falls back to `FileManager.copyItem` only when the source lives on a
    /// different volume (`EXDEV`) or the filesystem lacks clone support (`ENOTSUP`).
    /// Returns elapsed milliseconds.
    @discardableResult
    static func cloneTree(from src: URL, to dst: URL) throws -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        if Darwin.clonefile(src.path, dst.path, UInt32(CLONE_NOFOLLOW)) != 0 {
            let err = errno
            guard err == EXDEV || err == ENOTSUP else {
                throw PrefixError.cloneFailed(
                    "APFS clonefile(\(src.path) -> \(dst.path)) failed: \(String(cString: strerror(err)))"
                )
            }
            do {
                try FileManager.default.copyItem(at: src, to: dst)
            } catch {
                try? FileManager.default.removeItem(at: dst)
                throw PrefixError.cloneFailed("Cross-volume copy \(src.path) -> \(dst.path) failed: \(error)")
            }
        }
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
    }

    func listPrefixes() -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: prefixRoot, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        return items.compactMap { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDir ? url.lastPathComponent : nil
        }.sorted()
    }

    func deletePrefix(named name: String) throws {
        let dest = prefixURL(named: name)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
    }

    struct PrefixStat: Codable, Identifiable {
        var id: String { name }
        let name: String
        let path: String
        let sizeBytes: UInt64
        let fileCount: Int
        let createdUtc: String?
        let gameExe: String?
        let dxApi: String?
        let cowCloneMs: Double?
    }

    /// Computes disk footprint and metadata for each managed prefix, sorted largest first.
    func prefixStats() -> [PrefixStat] {
        let fm = FileManager.default
        let names = listPrefixes()
        return names.map { name in
            let url = prefixURL(named: name)
            var bytes: UInt64 = 0
            var files = 0
            if let en = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: []
            ) {
                for case let f as URL in en {
                    let vals = try? f.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    if vals?.isSymbolicLink == true { continue }
                    if vals?.isRegularFile == true {
                        files += 1
                        bytes += UInt64(vals?.fileSize ?? 0)
                    }
                }
            }
            let metaURL = url.appendingPathComponent("directmetal_prefix.json")
            let meta = (try? Data(contentsOf: metaURL)).flatMap { try? JSONDecoder().decode(PrefixMetadata.self, from: $0) }
            return PrefixStat(
                name: name,
                path: url.path,
                sizeBytes: bytes,
                fileCount: files,
                createdUtc: meta?.createdUtc,
                gameExe: (meta?.gameExe.isEmpty == false) ? meta?.gameExe : nil,
                dxApi: meta?.dxApi,
                cowCloneMs: meta?.cowCloneMs
            )
        }.sorted {
            if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
            return $0.name < $1.name
        }
    }
}
