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

struct ShaderCacheIndexEntry: Codable {
    let buildHash: String
    let gpuFamily: String
    let macosBuild: String
    let title: String
    let archiveUrl: String
    let archiveSha256: String
    let archiveBytes: UInt64
    let fileCount: Int
    let updatedUtc: String

    enum CodingKeys: String, CodingKey {
        case buildHash = "build_hash"
        case gpuFamily = "gpu_family"
        case macosBuild = "macos_build"
        case title
        case archiveUrl = "archive_url"
        case archiveSha256 = "archive_sha256"
        case archiveBytes = "archive_bytes"
        case fileCount = "file_count"
        case updatedUtc = "updated_utc"
    }

    private enum CamelCodingKeys: String, CodingKey {
        case buildHash
        case gpuFamily
        case macosBuild
        case title
        case archiveUrl
        case archiveSha256
        case archiveBytes
        case fileCount
        case updatedUtc
    }

    init(
        buildHash: String,
        gpuFamily: String,
        macosBuild: String,
        title: String,
        archiveUrl: String,
        archiveSha256: String,
        archiveBytes: UInt64,
        fileCount: Int,
        updatedUtc: String
    ) {
        self.buildHash = buildHash
        self.gpuFamily = gpuFamily
        self.macosBuild = macosBuild
        self.title = title
        self.archiveUrl = archiveUrl
        self.archiveSha256 = archiveSha256
        self.archiveBytes = archiveBytes
        self.fileCount = fileCount
        self.updatedUtc = updatedUtc
    }

    init(from decoder: Decoder) throws {
        let snake = try decoder.container(keyedBy: CodingKeys.self)
        let camel = try decoder.container(keyedBy: CamelCodingKeys.self)

        func decodeString(_ sKey: CodingKeys, _ cKey: CamelCodingKeys) throws -> String {
            if let v = try snake.decodeIfPresent(String.self, forKey: sKey) { return v }
            return try camel.decode(String.self, forKey: cKey)
        }
        func decodeUInt64(_ sKey: CodingKeys, _ cKey: CamelCodingKeys) throws -> UInt64 {
            if let v = try snake.decodeIfPresent(UInt64.self, forKey: sKey) { return v }
            return try camel.decode(UInt64.self, forKey: cKey)
        }
        func decodeInt(_ sKey: CodingKeys, _ cKey: CamelCodingKeys) throws -> Int {
            if let v = try snake.decodeIfPresent(Int.self, forKey: sKey) { return v }
            return try camel.decode(Int.self, forKey: cKey)
        }

        self.buildHash = try decodeString(.buildHash, .buildHash)
        self.gpuFamily = try decodeString(.gpuFamily, .gpuFamily)
        self.macosBuild = try decodeString(.macosBuild, .macosBuild)
        self.title = try snake.decodeIfPresent(String.self, forKey: .title)
            ?? (try camel.decodeIfPresent(String.self, forKey: .title))
            ?? ""
        self.archiveUrl = try decodeString(.archiveUrl, .archiveUrl)
        self.archiveSha256 = try decodeString(.archiveSha256, .archiveSha256)
        self.archiveBytes = try decodeUInt64(.archiveBytes, .archiveBytes)
        self.fileCount = try decodeInt(.fileCount, .fileCount)
        self.updatedUtc = try decodeString(.updatedUtc, .updatedUtc)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(buildHash, forKey: .buildHash)
        try container.encode(gpuFamily, forKey: .gpuFamily)
        try container.encode(macosBuild, forKey: .macosBuild)
        try container.encode(title, forKey: .title)
        try container.encode(archiveUrl, forKey: .archiveUrl)
        try container.encode(archiveSha256, forKey: .archiveSha256)
        try container.encode(archiveBytes, forKey: .archiveBytes)
        try container.encode(fileCount, forKey: .fileCount)
        try container.encode(updatedUtc, forKey: .updatedUtc)
    }
}

struct ShaderCacheIndex: Codable {
    static let currentSchema = "directmetal.shadercache.index.v1"

    let schema: String
    let updatedUtc: String
    let entries: [ShaderCacheIndexEntry]

    enum CodingKeys: String, CodingKey {
        case schema
        case updatedUtc = "updated_utc"
        case entries
    }

    private enum CamelCodingKeys: String, CodingKey {
        case updatedUtc
    }

    init(
        schema: String = ShaderCacheIndex.currentSchema,
        updatedUtc: String = ISO8601DateFormatter().string(from: Date()),
        entries: [ShaderCacheIndexEntry]
    ) {
        self.schema = schema
        self.updatedUtc = updatedUtc
        self.entries = entries
    }

    init(from decoder: Decoder) throws {
        let snake = try decoder.container(keyedBy: CodingKeys.self)
        let camel = try decoder.container(keyedBy: CamelCodingKeys.self)
        self.schema = try snake.decode(String.self, forKey: .schema)
        if let u = try snake.decodeIfPresent(String.self, forKey: .updatedUtc) {
            self.updatedUtc = u
        } else {
            self.updatedUtc = try camel.decode(String.self, forKey: .updatedUtc)
        }
        self.entries = try snake.decode([ShaderCacheIndexEntry].self, forKey: .entries)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(updatedUtc, forKey: .updatedUtc)
        try container.encode(entries, forKey: .entries)
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

    private static func isRemoteHTTP(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://")
    }

    private static func runCurlDownload(from remoteURL: String, to destination: URL, maxTimeSeconds: Int = 60) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = ["-fsSL", "--retry", "2", "--max-time", "\(maxTimeSeconds)", "-o", destination.path, remoteURL]
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? "curl exited \(proc.terminationStatus)"
            throw ShaderCacheError.downloadFailed(
                "Failed to fetch \(remoteURL): \(errText.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
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
        if isRemoteHTTP(source) {
            let downloaded = staging.appendingPathComponent("remote.dmcache.tar.gz")
            try runCurlDownload(from: source, to: downloaded, maxTimeSeconds: 60)
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
        let compatible = (
            manifest.gpuFamily.caseInsensitiveCompare(hw.gpuFamily) == .orderedSame &&
            manifest.macosBuild == hw.macosBuild
        )
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
            if actualHash.caseInsensitiveCompare(rec.sha256) != .orderedSame {
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

    static func fetchIndex(from indexSource: String) throws -> ShaderCacheIndex {
        let fm = FileManager.default
        let indexData: Data

        if isRemoteHTTP(indexSource) {
            let staging = fm.temporaryDirectory.appendingPathComponent("dm_cache_index_\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }
            let indexFile = staging.appendingPathComponent("index.json")
            try runCurlDownload(from: indexSource, to: indexFile, maxTimeSeconds: 30)
            indexData = try Data(contentsOf: indexFile)
        } else {
            let rawURL: URL
            if indexSource.lowercased().hasPrefix("file://"), let u = URL(string: indexSource) {
                rawURL = u
            } else {
                rawURL = URL(fileURLWithPath: indexSource)
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: rawURL.path, isDirectory: &isDir) else {
                throw ShaderCacheError.archiveFailed("Shader cache index not found: \(indexSource)")
            }
            let targetURL = isDir.boolValue ? rawURL.appendingPathComponent("index.json") : rawURL
            guard fm.fileExists(atPath: targetURL.path) else {
                throw ShaderCacheError.archiveFailed("Shader cache index.json not found in directory: \(rawURL.path)")
            }
            indexData = try Data(contentsOf: targetURL)
        }

        guard let index = try? JSONDecoder().decode(ShaderCacheIndex.self, from: indexData),
              index.schema == ShaderCacheIndex.currentSchema else {
            throw ShaderCacheError.invalidManifest(
                "Missing or invalid \(ShaderCacheIndex.currentSchema) index at \(indexSource)"
            )
        }
        return index
    }

    private static func resolveArchiveSource(_ archiveUrl: String, relativeTo indexSource: String) -> String {
        if isRemoteHTTP(archiveUrl) || archiveUrl.hasPrefix("/") || archiveUrl.lowercased().hasPrefix("file://") {
            return archiveUrl
        }
        if isRemoteHTTP(indexSource), let base = URL(string: indexSource) {
            let baseDir = indexSource.hasSuffix("/") ? base : base.deletingLastPathComponent()
            if let resolved = URL(string: archiveUrl, relativeTo: baseDir)?.absoluteURL {
                return resolved.absoluteString
            }
        }
        let fm = FileManager.default
        let indexPathURL: URL
        if indexSource.lowercased().hasPrefix("file://"), let u = URL(string: indexSource) {
            indexPathURL = u
        } else {
            indexPathURL = URL(fileURLWithPath: indexSource)
        }
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: indexPathURL.path, isDirectory: &isDir), isDir.boolValue {
            return indexPathURL.appendingPathComponent(archiveUrl).standardizedFileURL.path
        }
        return indexPathURL.deletingLastPathComponent().appendingPathComponent(archiveUrl).standardizedFileURL.path
    }

    static func syncFromIndex(
        indexSource: String,
        buildHash: String,
        allowCrossBuild: Bool = false
    ) throws -> ShaderCacheImportResult {
        let trimmedHash = buildHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHash.isEmpty else {
            throw ShaderCacheError.invalidManifest("buildHash must not be empty when syncing shader cache index")
        }

        let index = try fetchIndex(from: indexSource)
        let hw = RuntimeLauncher.queryHardwareInfo()

        let matchingBuildEntries = index.entries.filter {
            $0.buildHash.caseInsensitiveCompare(trimmedHash) == .orderedSame
        }

        let exactMatch = matchingBuildEntries
            .filter {
                $0.gpuFamily.caseInsensitiveCompare(hw.gpuFamily) == .orderedSame &&
                $0.macosBuild == hw.macosBuild
            }
            .sorted { $0.updatedUtc > $1.updatedUtc }
            .first

        let selectedEntry: ShaderCacheIndexEntry
        if let exact = exactMatch {
            selectedEntry = exact
        } else if allowCrossBuild {
            let sameGpuFallback = matchingBuildEntries
                .filter { $0.gpuFamily.caseInsensitiveCompare(hw.gpuFamily) == .orderedSame }
                .sorted { $0.updatedUtc > $1.updatedUtc }
                .first
            if let gpuMatch = sameGpuFallback {
                selectedEntry = gpuMatch
            } else if let anyMatch = matchingBuildEntries.sorted(by: { $0.updatedUtc > $1.updatedUtc }).first {
                selectedEntry = anyMatch
            } else {
                throw ShaderCacheError.emptyCache(
                    "No shader cache entry found in index for buildHash=\(trimmedHash)"
                )
            }
        } else if !matchingBuildEntries.isEmpty {
            let availableTargets = matchingBuildEntries
                .map { "\($0.gpuFamily)/\($0.macosBuild)" }
                .joined(separator: ", ")
            throw ShaderCacheError.incompatibleHardware(
                "Index has buildHash=\(trimmedHash) for [\(availableTargets)], but host is \(hw.gpuFamily)/\(hw.macosBuild). Pass --force / allowCrossBuild to override."
            )
        } else {
            throw ShaderCacheError.emptyCache(
                "No shader cache entry found in index for buildHash=\(trimmedHash)"
            )
        }

        let expectedArchiveSha = selectedEntry.archiveSha256.trimmingCharacters(in: .whitespacesAndNewlines)
        guard expectedArchiveSha.count == 64 else {
            throw ShaderCacheError.invalidManifest(
                "Invalid archive_sha256 in index entry for \(selectedEntry.buildHash): '\(selectedEntry.archiveSha256)'"
            )
        }

        let resolvedArchiveSource = resolveArchiveSource(selectedEntry.archiveUrl, relativeTo: indexSource)

        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("dm_cache_sync_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let localArchiveURL: URL
        if isRemoteHTTP(resolvedArchiveSource) {
            let downloaded = staging.appendingPathComponent("synced.dmcache.tar.gz")
            try runCurlDownload(from: resolvedArchiveSource, to: downloaded, maxTimeSeconds: 60)
            localArchiveURL = downloaded
        } else if resolvedArchiveSource.lowercased().hasPrefix("file://"), let fileURL = URL(string: resolvedArchiveSource) {
            guard fm.fileExists(atPath: fileURL.path) else {
                throw ShaderCacheError.archiveFailed("Referenced cache archive not found: \(fileURL.path)")
            }
            localArchiveURL = fileURL
        } else {
            let fileURL = URL(fileURLWithPath: resolvedArchiveSource)
            guard fm.fileExists(atPath: fileURL.path) else {
                throw ShaderCacheError.archiveFailed("Referenced cache archive not found: \(fileURL.path)")
            }
            localArchiveURL = fileURL
        }

        // Verify the downloaded archive's outer SHA-256 against entry.archiveSha256 BEFORE extracting!
        let actualArchiveSha = try sha256Hex(fileAt: localArchiveURL)
        if actualArchiveSha.caseInsensitiveCompare(expectedArchiveSha) != .orderedSame {
            throw ShaderCacheError.checksumMismatch(
                "Archive SHA-256 mismatch for \(resolvedArchiveSource): expected \(expectedArchiveSha), got \(actualArchiveSha)"
            )
        }

        // Extract and verify every individual file SHA-256 inside manifest.json
        let imported = try importArchive(from: localArchiveURL.path, allowCrossBuild: allowCrossBuild)
        return ShaderCacheImportResult(
            source: resolvedArchiveSource,
            destination: imported.destination,
            verifiedFiles: imported.verifiedFiles,
            totalBytes: imported.totalBytes,
            gpuFamily: imported.gpuFamily,
            macosBuild: imported.macosBuild,
            compatible: imported.compatible
        )
    }
}
