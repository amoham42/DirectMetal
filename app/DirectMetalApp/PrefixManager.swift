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
        guard fm.fileExists(atPath: basePrefix.appendingPathComponent("system.reg").path) else {
            throw PrefixError.missingBasePrefix("Golden base prefix not initialized at \(basePrefix.path). Run scripts/setup_runtime.sh first.")
        }
        try fm.createDirectory(at: prefixRoot, withIntermediateDirectories: true)

        let dest = prefixURL(named: name)
        if forceReset && fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }

        if fm.fileExists(atPath: dest.path) {
            return (dest, false, 0.0)
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let rc = Darwin.clonefile(basePrefix.path, dest.path, UInt32(CLONE_NOFOLLOW))
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0

        if rc != 0 {
            let errStr = String(cString: strerror(errno))
            throw PrefixError.cloneFailed("APFS clonefile(\(basePrefix.path) -> \(dest.path)) failed: \(errStr)")
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
}
