import CryptoKit
import Foundation

struct ShaderCacheFileRecord: Codable {
    let relativePath: String
    let sizeBytes: UInt64
    let sha256: String

    enum CodingKeys: String, CodingKey {
        case relativePath = "relative_path"
        case sizeBytes = "size_bytes"
        case sha256
    }
}

struct ShaderCacheManifest: Codable {
    let schema: String
    let createdUtc: String
    let gpuName: String
    let gpuFamily: String
    let macosVersion: String
    let macosBuild: String
    let cacheKey: String
    let entryCount: Int
    let fileCount: Int
    let totalBytes: UInt64
    let files: [ShaderCacheFileRecord]

    enum CodingKeys: String, CodingKey {
        case schema
        case createdUtc = "created_utc"
        case gpuName = "gpu_name"
        case gpuFamily = "gpu_family"
        case macosVersion = "macos_version"
        case macosBuild = "macos_build"
        case cacheKey = "cache_key"
        case entryCount = "entry_count"
        case fileCount = "file_count"
        case totalBytes = "total_bytes"
        case files
    }
}

struct ShaderCacheExportResult: Codable {
    let archivePath: String
    let archiveBytes: UInt64
    let manifestSha256: String
    let gpuFamily: String
    let macosBuild: String
    let entryCount: Int
    let fileCount: Int
    let totalPayloadBytes: UInt64
}

struct ShaderCacheImportResult: Codable {
    let source: String
    let destination: String
    let verifiedFiles: Int
    let totalBytes: UInt64
    let gpuFamily: String
    let macosBuild: String
    let compatible: Bool
}

enum ShaderCacheError: Error, CustomStringConvertible {
    case emptyCache(String)
    case archiveFailed(String)
    case invalidManifest(String)
    case incompatibleHardware(String)
    case checksumMismatch(String)
    case downloadFailed(String)

    var description: String {
        switch self {
        case .emptyCache(let m),
             .archiveFailed(let m),
             .invalidManifest(let m),
             .incompatibleHardware(let m),
             .checksumMismatch(let m),
             .downloadFailed(let m):
            return m
        }
    }
}

enum ShaderCacheManager {
    private static func sha256Hex(fileAt url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var hasher = SHA256()
        while true {
            let chunk = fh.readData(ofLength: 65536)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func runTar(_ args: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? "tar exited \(proc.terminationStatus)"
            throw ShaderCacheError.archiveFailed(errText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func exportArchive(to outputPath: String, filterEntry: String? = nil) throws -> ShaderCacheExportResult {
        let fm = FileManager.default
        let root = RuntimeLauncher.shaderCacheRoot()
        guard fm.fileExists(atPath: root.path) else {
            throw ShaderCacheError.emptyCache("Shader cache directory does not exist: \(root.path)")
        }

        let staging = fm.temporaryDirectory.appendingPathComponent("dm_cache_export_\(UUID().uuidString)", isDirectory: true)
        let payloadDir = staging.appendingPathComponent("shaders", isDirectory: true)
        try fm.createDirectory(at: payloadDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let topItems = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var copiedEntries = 0
        for item in topItems {
            let name = item.lastPathComponent
            if let filter = filterEntry, !filter.isEmpty, !name.contains(filter) {
                continue
            }
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                try fm.copyItem(at: item, to: payloadDir.appendingPathComponent(name, isDirectory: true))
                copiedEntries += 1
            }
        }
        if copiedEntries == 0 {
            throw ShaderCacheError.emptyCache("No shader cache entries matched export filter in \(root.path)")
        }

        let resolvedPayloadPath = payloadDir.resolvingSymlinksInPath().path
        var fileRecords: [ShaderCacheFileRecord] = []
        var totalBytes: UInt64 = 0
        if let enumerator = fm.enumerator(at: payloadDir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for case let url as URL in enumerator {
                let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if vals?.isRegularFile == true {
                    let resolvedFile = url.resolvingSymlinksInPath().path
                    let rel: String
                    if resolvedFile.hasPrefix(resolvedPayloadPath + "/") {
                        rel = String(resolvedFile.dropFirst(resolvedPayloadPath.count + 1))
                    } else {
                        rel = url.lastPathComponent
                    }
                    let sz = UInt64(vals?.fileSize ?? 0)
                    let digest = try sha256Hex(fileAt: url)
                    fileRecords.append(ShaderCacheFileRecord(relativePath: rel, sizeBytes: sz, sha256: digest))
                    totalBytes += sz
                }
            }
        }
        fileRecords.sort { $0.relativePath < $1.relativePath }

        let hw = RuntimeLauncher.queryHardwareInfo()
        let manifest = ShaderCacheManifest(
            schema: "directmetal.shadercache.v1",
            createdUtc: ISO8601DateFormatter().string(from: Date()),
            gpuName: hw.gpuName,
            gpuFamily: hw.gpuFamily,
            macosVersion: hw.macosVersion,
            macosBuild: hw.macosBuild,
            cacheKey: hw.cacheKey,
            entryCount: copiedEntries,
            fileCount: fileRecords.count,
            totalBytes: totalBytes,
            files: fileRecords
        )

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try enc.encode(manifest)
        let manifestURL = staging.appendingPathComponent("manifest.json")
        try manifestData.write(to: manifestURL)
        let manifestSha = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()

        let outURL = URL(fileURLWithPath: outputPath)
        try fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: outURL.path) {
            try fm.removeItem(at: outURL)
        }
        try runTar(["-czf", outURL.path, "-C", staging.path, "manifest.json", "shaders"])

        let archiveAttrs = try fm.attributesOfItem(atPath: outURL.path)
        let archiveBytes = (archiveAttrs[.size] as? NSNumber)?.uint64Value ?? 0

        return ShaderCacheExportResult(
            archivePath: outURL.path,
            archiveBytes: archiveBytes,
            manifestSha256: manifestSha,
            gpuFamily: hw.gpuFamily,
            macosBuild: hw.macosBuild,
            entryCount: copiedEntries,
            fileCount: fileRecords.count,
            totalPayloadBytes: totalBytes
        )
    }

    static func importArchive(from source: String, allowCrossBuild: Bool = false) throws -> ShaderCacheImportResult {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("dm_cache_import_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let archiveURL: URL
        if source.lowercased().hasPrefix("https://") || source.lowercased().hasPrefix("http://") {
            let downloaded = staging.appendingPathComponent("remote.dmcache.tar.gz")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            proc.arguments = ["-fsSL", "--retry", "2", "--max-time", "60", "-o", downloaded.path, source]
            let errPipe = Pipe()
            proc.standardError = errPipe
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errText = String(data: errData, encoding: .utf8) ?? "curl exited \(proc.terminationStatus)"
                throw ShaderCacheError.downloadFailed(errText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            archiveURL = downloaded
        } else {
            archiveURL = URL(fileURLWithPath: source)
            guard fm.fileExists(atPath: archiveURL.path) else {
                throw ShaderCacheError.archiveFailed("Cache archive not found: \(source)")
            }
        }

        let extractDir = staging.appendingPathComponent("extracted", isDirectory: true)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try runTar(["-xzf", archiveURL.path, "-C", extractDir.path])

        let manifestURL = extractDir.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(ShaderCacheManifest.self, from: manifestData),
              manifest.schema == "directmetal.shadercache.v1" else {
            throw ShaderCacheError.invalidManifest("Missing or invalid directmetal.shadercache.v1 manifest.json")
        }

        let hw = RuntimeLauncher.queryHardwareInfo()
        let compatible = (manifest.gpuFamily == hw.gpuFamily && manifest.macosBuild == hw.macosBuild)
        if !compatible && !allowCrossBuild {
            throw ShaderCacheError.incompatibleHardware(
                "Cache built for \(manifest.gpuFamily)/\(manifest.macosBuild), host is \(hw.gpuFamily)/\(hw.macosBuild). Pass --force to override."
            )
        }

        let payloadDir = extractDir.appendingPathComponent("shaders", isDirectory: true)
        // Verify every single file's SHA-256 checksum & guard against path traversal
        for rec in manifest.files {
            if rec.relativePath.contains("..") || rec.relativePath.hasPrefix("/") {
                throw ShaderCacheError.checksumMismatch("Unsafe relative path in archive: \(rec.relativePath)")
            }
            let fileURL = payloadDir.appendingPathComponent(rec.relativePath)
            guard fm.fileExists(atPath: fileURL.path) else {
                throw ShaderCacheError.checksumMismatch("Missing file listed in manifest: \(rec.relativePath)")
            }
            let actualHash = try sha256Hex(fileAt: fileURL)
            if actualHash != rec.sha256 {
                throw ShaderCacheError.checksumMismatch("SHA-256 mismatch for \(rec.relativePath): expected \(rec.sha256), got \(actualHash)")
            }
        }

        let destRoot = RuntimeLauncher.shaderCacheRoot()
        try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)
        let extractedEntries = (try? fm.contentsOfDirectory(at: payloadDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for entry in extractedEntries {
            let target = destRoot.appendingPathComponent(entry.lastPathComponent, isDirectory: true)
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.moveItem(at: entry, to: target)
        }

        return ShaderCacheImportResult(
            source: source,
            destination: destRoot.path,
            verifiedFiles: manifest.files.count,
            totalBytes: manifest.totalBytes,
            gpuFamily: manifest.gpuFamily,
            macosBuild: manifest.macosBuild,
            compatible: compatible
        )
    }
}
