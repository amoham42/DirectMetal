import Foundation

// Data models and errors for DirectMetal's local & cloud Metal shader cache archives.

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

struct ShaderCacheLocalEntry: Codable, Identifiable {
    var id: String { name }
    let name: String
    let path: String
    let fileCount: Int
    let totalBytes: UInt64
    let matchesHostCacheKey: Bool
    let isKnownKeyedEntry: Bool
}

struct ShaderCachePruneResult: Codable {
    let dryRun: Bool
    let currentCacheKey: String
    let removedEntries: [String]
    let keptEntries: [String]
    let reclaimedBytes: UInt64
    let reclaimedFiles: Int
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
