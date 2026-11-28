import Darwin
import Foundation

// Self-contained Shader Cache Integrity Verifier & Safe Quarantine Engine.
// Scans DirectMetal's Metal/DXVK shader cache safely without descending into symlinks,
// detects truncated, zero-byte, corrupted, malformed JSON, broken-symlink, symlink-escape,
// and unreadable artifacts, and safely quarantines corrupt entries into `_quarantine/<timestamp>/`.

// MARK: - Models & Errors

enum ShaderCacheIssueKind: String, Codable, CaseIterable, Hashable, Sendable {
    case zeroByteFile
    case invalidMetallibHeader
    case truncatedArchive
    case invalidJSON
    case brokenSymlink
    case symlinkEscape
    case unreadableFile

    var displayName: String {
        switch self {
        case .zeroByteFile:
            return "Zero-Byte File"
        case .invalidMetallibHeader:
            return "Invalid Metallib Header"
        case .truncatedArchive:
            return "Truncated Archive"
        case .invalidJSON:
            return "Invalid JSON"
        case .brokenSymlink:
            return "Broken Symlink"
        case .symlinkEscape:
            return "Symlink Escape"
        case .unreadableFile:
            return "Unreadable File"
        }
    }
}

struct ShaderCacheIssue: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let relativePath: String
    let kind: ShaderCacheIssueKind
    let sizeBytes: UInt64
    let detail: String

    init(
        id: String? = nil,
        relativePath: String,
        kind: ShaderCacheIssueKind,
        sizeBytes: UInt64,
        detail: String
    ) {
        self.id = id ?? "\(kind.rawValue):\(relativePath)"
        self.relativePath = relativePath
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.detail = detail
    }
}

struct ShaderCacheVerificationReport: Codable, Equatable, Sendable {
    let cacheRoot: String
    let scannedAtUtc: String
    let totalFilesScanned: Int
    let healthyFileCount: Int
    let totalBytesScanned: UInt64
    let corruptByteCount: UInt64
    let issues: [ShaderCacheIssue]

    var isHealthy: Bool { issues.isEmpty }
}

struct ShaderCacheQuarantineResult: Codable, Equatable, Sendable {
    let quarantineDirectory: String
    let dryRun: Bool
    let movedCount: Int
    let movedBytes: UInt64
    let movedRelativePaths: [String]
    let skippedPaths: [String]
}

enum ShaderCacheVerifierError: Error, LocalizedError, Equatable, Sendable {
    case invalidRelativePath(String)
    case symlinkEscapeBlocked(String)

    var errorDescription: String? {
        switch self {
        case .invalidRelativePath(let path):
            return "Invalid shader cache relative path: '\(path)'"
        case .symlinkEscapeBlocked(let path):
            return "Blocked symlink escape while quarantining shader cache entry: '\(path)'"
        }
    }
}

// MARK: - Verifier & Quarantine Engine

enum ShaderCacheVerifier {
    static let quarantineFolderName = "_quarantine"

    private static let headerReadLimit = 64
    private static let maxJSONInspectionBytes: UInt64 = 4 * 1024 * 1024

    private static let metallibMagic: [UInt8] = [0x4D, 0x54, 0x4C, 0x42] // "MTLB"
    private static let bitcodeMagic: [UInt8] = [0x42, 0x43, 0xC0, 0xDE]  // "BC\xC0\xDE"
    private static let gzipMagic: [UInt8] = [0x1F, 0x8B]

    private static let binaryCacheExtensions: Set<String> = [
        "bin",
        "binaryarchive",
        "metallibarchive",
        "dxvk-cache",
        "cache",
        "pipeline",
    ]

    // MARK: - Verification

    /// Walks `cacheRoot` safely without descending into symlinks, skipping the top-level
    /// `_quarantine` directory and `.DS_Store` metadata files, and reports corrupt artifacts.
    static func verify(cacheRoot: URL = RuntimeLauncher.shaderCacheRoot()) -> ShaderCacheVerificationReport {
        let standardizedRoot = cacheRoot.standardizedFileURL
        let scannedAtUtc = currentUtcTimestamp()

        var rootStat = stat()
        guard stat(standardizedRoot.path, &rootStat) == 0,
              (rootStat.st_mode & S_IFMT) == S_IFDIR,
              let canonicalRootPath = canonicalPath(for: standardizedRoot.path) else {
            return ShaderCacheVerificationReport(
                cacheRoot: standardizedRoot.path,
                scannedAtUtc: scannedAtUtc,
                totalFilesScanned: 0,
                healthyFileCount: 0,
                totalBytesScanned: 0,
                corruptByteCount: 0,
                issues: []
            )
        }

        let canonicalRootURL = URL(fileURLWithPath: canonicalRootPath, isDirectory: true)
        let canonicalRootPrefix = canonicalRootPath == "/" ? "/" : canonicalRootPath + "/"

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: canonicalRootURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return ShaderCacheVerificationReport(
                cacheRoot: standardizedRoot.path,
                scannedAtUtc: scannedAtUtc,
                totalFilesScanned: 0,
                healthyFileCount: 0,
                totalBytesScanned: 0,
                corruptByteCount: 0,
                issues: []
            )
        }

        var totalFilesScanned = 0
        var healthyFileCount = 0
        var totalBytesScanned: UInt64 = 0
        var corruptByteCount: UInt64 = 0
        var issues: [ShaderCacheIssue] = []

        for case let entryURL as URL in enumerator {
            let entryPath = trimTrailingSlashes(entryURL.path)
            guard entryPath.hasPrefix(canonicalRootPrefix) else {
                enumerator.skipDescendants()
                continue
            }

            let relativePath = String(entryPath.dropFirst(canonicalRootPrefix.count))
            guard !relativePath.isEmpty else {
                continue
            }

            // Skip top-level _quarantine folder and anything beneath it.
            if relativePath == quarantineFolderName || relativePath.hasPrefix(quarantineFolderName + "/") {
                enumerator.skipDescendants()
                continue
            }

            var st = stat()
            guard Darwin.lstat(entryPath, &st) == 0 else {
                let errText = String(cString: strerror(errno))
                totalFilesScanned += 1
                issues.append(ShaderCacheIssue(
                    relativePath: relativePath,
                    kind: .unreadableFile,
                    sizeBytes: 0,
                    detail: "Unable to stat cache entry: \(errText)"
                ))
                continue
            }

            let fileType = st.st_mode & S_IFMT

            if fileType == S_IFLNK {
                // Never descend into symlinked directories.
                enumerator.skipDescendants()
                totalFilesScanned += 1

                if let symlinkIssue = inspectSymlink(
                    atPath: entryPath,
                    relativePath: relativePath,
                    canonicalRootPrefix: canonicalRootPrefix
                ) {
                    issues.append(symlinkIssue)
                } else {
                    healthyFileCount += 1
                }
                continue
            }

            if fileType == S_IFDIR {
                continue
            }

            guard fileType == S_IFREG else {
                continue
            }

            if entryURL.lastPathComponent == ".DS_Store" {
                continue
            }

            let sizeBytes: UInt64 = st.st_size > 0 ? UInt64(st.st_size) : 0
            totalFilesScanned += 1
            totalBytesScanned &+= sizeBytes

            if let issue = inspectRegularFile(
                at: entryURL,
                relativePath: relativePath,
                sizeBytes: sizeBytes
            ) {
                issues.append(issue)
                corruptByteCount &+= sizeBytes
            } else {
                healthyFileCount += 1
            }
        }

        issues.sort {
            if $0.relativePath != $1.relativePath {
                return $0.relativePath < $1.relativePath
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }

        return ShaderCacheVerificationReport(
            cacheRoot: standardizedRoot.path,
            scannedAtUtc: scannedAtUtc,
            totalFilesScanned: totalFilesScanned,
            healthyFileCount: healthyFileCount,
            totalBytesScanned: totalBytesScanned,
            corruptByteCount: corruptByteCount,
            issues: issues
        )
    }

    // MARK: - Safe Quarantine

    /// Moves corrupt artifacts reported in `report` into `<cacheRoot>/_quarantine/<YYYYMMDD-HHmmss>/...`
    /// while preserving relative parent subdirectories. Never follows symlinks or moves external targets.
    static func quarantineCorruptFiles(
        report: ShaderCacheVerificationReport,
        cacheRoot: URL = RuntimeLauncher.shaderCacheRoot(),
        dryRun: Bool = false
    ) throws -> ShaderCacheQuarantineResult {
        let standardizedRoot = cacheRoot.standardizedFileURL
        let quarantineBaseURL = standardizedRoot.appendingPathComponent(quarantineFolderName, isDirectory: true)
        let timestamp = quarantineTimestampString()

        var quarantineRunURL = quarantineBaseURL.appendingPathComponent(timestamp, isDirectory: true)
        if !dryRun && pathExistsViaLstat(quarantineRunURL.path) {
            var suffix = 1
            while true {
                let candidate = quarantineBaseURL.appendingPathComponent("\(timestamp)-\(suffix)", isDirectory: true)
                if !pathExistsViaLstat(candidate.path) {
                    quarantineRunURL = candidate
                    break
                }
                suffix += 1
            }
        }

        // 1. Validate EVERY issue relativePath upfront before touching the filesystem.
        for issue in report.issues {
            try validateQuarantineRelativePath(issue.relativePath)
        }

        guard !report.issues.isEmpty else {
            return ShaderCacheQuarantineResult(
                quarantineDirectory: quarantineRunURL.path,
                dryRun: dryRun,
                movedCount: 0,
                movedBytes: 0,
                movedRelativePaths: [],
                skippedPaths: []
            )
        }

        // Verify `_quarantine` itself (if present) is not a symlink escaping cacheRoot.
        if pathExistsViaLstat(quarantineBaseURL.path) {
            var qst = stat()
            if Darwin.lstat(quarantineBaseURL.path, &qst) == 0,
               (qst.st_mode & S_IFMT) == S_IFLNK {
                throw ShaderCacheVerifierError.symlinkEscapeBlocked(quarantineFolderName)
            }
        }

        let canonicalRootPath = canonicalPath(for: standardizedRoot.path)
        let canonicalRootPrefix: String? = canonicalRootPath.map { $0 == "/" ? "/" : $0 + "/" }

        // Deduplicate issues by relativePath in deterministic order.
        let orderedIssues = report.issues.sorted {
            if $0.relativePath != $1.relativePath {
                return $0.relativePath < $1.relativePath
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }

        struct PlannedMove {
            let relativePath: String
            let sourceURL: URL
            let isSymlink: Bool
            let sizeBytes: UInt64
        }

        var seenPaths: Set<String> = []
        var plannedMoves: [PlannedMove] = []
        var skippedPaths: [String] = []

        // 2. Inspect each candidate safely via lstat and verify intermediate components contain no symlinks.
        for issue in orderedIssues {
            let relPath = issue.relativePath
            guard seenPaths.insert(relPath).inserted else {
                continue
            }

            try validateNoSymlinkParents(relativePath: relPath, under: standardizedRoot)

            let sourceURL = standardizedRoot.appendingPathComponent(relPath, isDirectory: false)
            var st = stat()
            guard Darwin.lstat(sourceURL.path, &st) == 0 else {
                skippedPaths.append(relPath)
                continue
            }

            let fileType = st.st_mode & S_IFMT
            if fileType == S_IFLNK {
                // Only the symlink itself inside cacheRoot will be moved — never its target.
                plannedMoves.append(PlannedMove(
                    relativePath: relPath,
                    sourceURL: sourceURL,
                    isSymlink: true,
                    sizeBytes: 0
                ))
            } else if fileType == S_IFREG {
                // Confirm the regular file's canonical path stays strictly within canonical cacheRoot.
                if let rootPrefix = canonicalRootPrefix,
                   let canonicalSource = canonicalPath(for: sourceURL.path),
                   !canonicalSource.hasPrefix(rootPrefix) {
                    throw ShaderCacheVerifierError.symlinkEscapeBlocked(relPath)
                }
                let sizeBytes: UInt64 = st.st_size > 0 ? UInt64(st.st_size) : 0
                plannedMoves.append(PlannedMove(
                    relativePath: relPath,
                    sourceURL: sourceURL,
                    isSymlink: false,
                    sizeBytes: sizeBytes
                ))
            } else {
                skippedPaths.append(relPath)
            }
        }

        if dryRun {
            let totalMovedBytes = plannedMoves.reduce(UInt64(0)) { $0 &+ $1.sizeBytes }
            return ShaderCacheQuarantineResult(
                quarantineDirectory: quarantineRunURL.path,
                dryRun: true,
                movedCount: plannedMoves.count,
                movedBytes: totalMovedBytes,
                movedRelativePaths: plannedMoves.map(\.relativePath),
                skippedPaths: skippedPaths
            )
        }

        guard !plannedMoves.isEmpty else {
            return ShaderCacheQuarantineResult(
                quarantineDirectory: quarantineRunURL.path,
                dryRun: false,
                movedCount: 0,
                movedBytes: 0,
                movedRelativePaths: [],
                skippedPaths: skippedPaths
            )
        }

        // 3. Execute moves into <cacheRoot>/_quarantine/<YYYYMMDD-HHmmss>/...
        let fm = FileManager.default
        try fm.createDirectory(at: quarantineRunURL, withIntermediateDirectories: true)

        var movedRelativePaths: [String] = []
        var movedBytes: UInt64 = 0

        for item in plannedMoves {
            let destinationURL = quarantineRunURL.appendingPathComponent(item.relativePath, isDirectory: false)
            let parentDir = destinationURL.deletingLastPathComponent()
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

            // Re-verify right before moving that no parent component became a symlink.
            try validateNoSymlinkParents(relativePath: item.relativePath, under: standardizedRoot)

            // POSIX rename moves regular files AND symlinks atomically without ever dereferencing symlinks.
            if Darwin.rename(item.sourceURL.path, destinationURL.path) == 0 {
                movedRelativePaths.append(item.relativePath)
                movedBytes &+= item.sizeBytes
            } else if errno == ENOENT {
                skippedPaths.append(item.relativePath)
            } else if errno == EXDEV && !item.isSymlink {
                try fm.moveItem(at: item.sourceURL, to: destinationURL)
                movedRelativePaths.append(item.relativePath)
                movedBytes &+= item.sizeBytes
            } else {
                let err = errno
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(err),
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Failed to quarantine '\(item.relativePath)': \(String(cString: strerror(err)))"
                    ]
                )
            }
        }

        return ShaderCacheQuarantineResult(
            quarantineDirectory: quarantineRunURL.path,
            dryRun: false,
            movedCount: movedRelativePaths.count,
            movedBytes: movedBytes,
            movedRelativePaths: movedRelativePaths,
            skippedPaths: skippedPaths
        )
    }

    // MARK: - Formatters

    static func formatText(_ report: ShaderCacheVerificationReport) -> String {
        let redact: (String) -> String = { LaunchDiagnostics.redactHome($0) }
        let statusText: String
        if report.isHealthy {
            statusText = "HEALTHY"
        } else {
            let noun = report.issues.count == 1 ? "issue" : "issues"
            statusText = "CORRUPT (\(report.issues.count) \(noun) detected)"
        }

        let summaryRows: [(String, String)] = [
            ("Status", statusText),
            ("Cache Root", redact(report.cacheRoot)),
            ("Scanned At", report.scannedAtUtc),
            ("Files Scanned", "\(report.totalFilesScanned) (\(report.healthyFileCount) healthy, \(report.issues.count) issues)"),
            ("Total Size", "\(formatBytes(report.totalBytesScanned)) (\(formatBytes(report.corruptByteCount)) corrupt)"),
        ]

        let labelWidth = (summaryRows.map { $0.0.count }.max() ?? 0) + 2
        var lines: [String] = ["DirectMetal Shader Cache Integrity Report"]
        for (label, value) in summaryRows {
            let padded = (label + ":").padding(toLength: labelWidth, withPad: " ", startingAt: 0)
            lines.append("  \(padded)\(value)")
        }

        lines.append("")
        if report.issues.isEmpty {
            lines.append("No integrity issues detected.")
        } else {
            lines.append("[Issues (\(report.issues.count))]")
            for (index, issue) in report.issues.enumerated() {
                let sizeLabel = formatBytes(issue.sizeBytes)
                lines.append("  \(index + 1). [\(issue.kind.displayName)] \(redact(issue.relativePath)) (\(sizeLabel))")
                lines.append("     \(redact(issue.detail))")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    static func formatMarkdown(_ report: ShaderCacheVerificationReport) -> String {
        let redact: (String) -> String = { LaunchDiagnostics.redactHome($0) }
        func cell(_ raw: String) -> String {
            redact(raw)
                .replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
        }

        let statusText: String
        if report.isHealthy {
            statusText = "Healthy"
        } else {
            let noun = report.issues.count == 1 ? "issue" : "issues"
            statusText = "**Corrupt** (\(report.issues.count) \(noun))"
        }

        var lines: [String] = [
            "### DirectMetal Shader Cache Integrity Report",
            "",
            "| Field | Value |",
            "| :--- | :--- |",
            "| **Status** | \(statusText) |",
            "| **Cache Root** | `\(cell(report.cacheRoot))` |",
            "| **Scanned At** | `\(cell(report.scannedAtUtc))` |",
            "| **Files Scanned** | \(report.totalFilesScanned) (\(report.healthyFileCount) healthy, \(report.issues.count) issues) |",
            "| **Total Size** | \(formatBytes(report.totalBytesScanned)) (\(formatBytes(report.corruptByteCount)) corrupt) |",
            "",
        ]

        if report.issues.isEmpty {
            lines.append("_No integrity issues detected._")
        } else {
            lines.append("#### Issues (\(report.issues.count))")
            lines.append("")
            lines.append("| Kind | Relative Path | Size | Detail |")
            lines.append("| :--- | :--- | ---: | :--- |")
            for issue in report.issues {
                let kindCell = cell(issue.kind.displayName)
                let pathCell = cell(issue.relativePath)
                let sizeCell = formatBytes(issue.sizeBytes)
                let detailCell = cell(issue.detail)
                lines.append("| \(kindCell) | `\(pathCell)` | \(sizeCell) | \(detailCell) |")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Inspection Helpers

    private static func inspectSymlink(
        atPath entryPath: String,
        relativePath: String,
        canonicalRootPrefix: String
    ) -> ShaderCacheIssue? {
        var targetStat = stat()
        guard stat(entryPath, &targetStat) == 0 else {
            let errText = String(cString: strerror(errno))
            return ShaderCacheIssue(
                relativePath: relativePath,
                kind: .brokenSymlink,
                sizeBytes: 0,
                detail: "Dangling or unresolvable symlink (\(errText))"
            )
        }

        guard let canonicalTarget = canonicalPath(for: entryPath) else {
            return ShaderCacheIssue(
                relativePath: relativePath,
                kind: .brokenSymlink,
                sizeBytes: 0,
                detail: "Unable to resolve canonical symlink target"
            )
        }

        guard canonicalTarget.hasPrefix(canonicalRootPrefix) else {
            let redactedTarget = LaunchDiagnostics.redactHome(canonicalTarget)
            return ShaderCacheIssue(
                relativePath: relativePath,
                kind: .symlinkEscape,
                sizeBytes: 0,
                detail: "Symlink resolves outside shader cache root (\(redactedTarget))"
            )
        }

        return nil
    }

    private static func inspectRegularFile(
        at url: URL,
        relativePath: String,
        sizeBytes: UInt64
    ) -> ShaderCacheIssue? {
        if sizeBytes == 0 {
            return ShaderCacheIssue(
                relativePath: relativePath,
                kind: .zeroByteFile,
                sizeBytes: 0,
                detail: "File is 0 bytes (empty or crash-truncated)"
            )
        }

        let headerBytes: [UInt8]
        switch readRegularFilePrefix(at: url, maxBytes: headerReadLimit) {
        case .data(let data):
            headerBytes = Array(data)
        case .unreadable(let reason):
            return ShaderCacheIssue(
                relativePath: relativePath,
                kind: .unreadableFile,
                sizeBytes: sizeBytes,
                detail: "Unable to read file header: \(reason)"
            )
        }

        let ext = url.pathExtension.lowercased()

        switch ext {
        case "metallib":
            if sizeBytes < 32 {
                return ShaderCacheIssue(
                    relativePath: relativePath,
                    kind: .truncatedArchive,
                    sizeBytes: sizeBytes,
                    detail: "Metallib file is truncated (\(sizeBytes) bytes; minimum 32 bytes required)"
                )
            }
            if !hasMagic(headerBytes, metallibMagic) {
                return ShaderCacheIssue(
                    relativePath: relativePath,
                    kind: .invalidMetallibHeader,
                    sizeBytes: sizeBytes,
                    detail: "Invalid .metallib magic header (expected 'MTLB', got \(hexPreview(headerBytes, count: 4)))"
                )
            }

        case "air", "metalair":
            if sizeBytes < 16 {
                return ShaderCacheIssue(
                    relativePath: relativePath,
                    kind: .truncatedArchive,
                    sizeBytes: sizeBytes,
                    detail: "Metal AIR file is truncated (\(sizeBytes) bytes; minimum 16 bytes required)"
                )
            }
            if !hasMagic(headerBytes, bitcodeMagic) && !hasMagic(headerBytes, metallibMagic) {
                return ShaderCacheIssue(
                    relativePath: relativePath,
                    kind: .invalidMetallibHeader,
                    sizeBytes: sizeBytes,
                    detail: "Invalid Metal AIR magic header (expected LLVM bitcode or 'MTLB', got \(hexPreview(headerBytes, count: 4)))"
                )
            }

        case "gz", "tgz":
            if sizeBytes < 20 || !hasMagic(headerBytes, gzipMagic) {
                return ShaderCacheIssue(
                    relativePath: relativePath,
                    kind: .truncatedArchive,
                    sizeBytes: sizeBytes,
                    detail: "Corrupt or truncated gzip archive (\(sizeBytes) bytes, magic \(hexPreview(headerBytes, count: 2)))"
                )
            }

        case "json", "mtlp-json":
            if sizeBytes <= maxJSONInspectionBytes {
                let jsonData: Data
                if sizeBytes <= UInt64(headerReadLimit) && headerBytes.count == Int(sizeBytes) {
                    jsonData = Data(headerBytes)
                } else {
                    switch readRegularFilePrefix(at: url, maxBytes: Int(maxJSONInspectionBytes)) {
                    case .data(let data):
                        jsonData = data
                    case .unreadable(let reason):
                        return ShaderCacheIssue(
                            relativePath: relativePath,
                            kind: .unreadableFile,
                            sizeBytes: sizeBytes,
                            detail: "Unable to read JSON file: \(reason)"
                        )
                    }
                }
                do {
                    _ = try JSONSerialization.jsonObject(with: jsonData, options: [])
                } catch {
                    return ShaderCacheIssue(
                        relativePath: relativePath,
                        kind: .invalidJSON,
                        sizeBytes: sizeBytes,
                        detail: "Malformed JSON metadata: \(error.localizedDescription)"
                    )
                }
            } else if !startsWithJSONContainer(headerBytes) {
                return ShaderCacheIssue(
                    relativePath: relativePath,
                    kind: .invalidJSON,
                    sizeBytes: sizeBytes,
                    detail: "Large JSON file does not begin with a valid JSON object or array"
                )
            }

        case _ where binaryCacheExtensions.contains(ext):
            if sizeBytes < 16 {
                return ShaderCacheIssue(
                    relativePath: relativePath,
                    kind: .truncatedArchive,
                    sizeBytes: sizeBytes,
                    detail: "Binary cache file is truncated (\(sizeBytes) bytes; minimum 16 bytes required)"
                )
            }
            let inspectedCount = min(headerBytes.count, Int(min(sizeBytes, UInt64(headerReadLimit))))
            if inspectedCount == 0 || !headerBytes.prefix(inspectedCount).contains(where: { $0 != 0 }) {
                return ShaderCacheIssue(
                    relativePath: relativePath,
                    kind: .truncatedArchive,
                    sizeBytes: sizeBytes,
                    detail: "Binary cache header contains only zero bytes across first \(inspectedCount) bytes"
                )
            }

        default:
            break
        }

        return nil
    }

    // MARK: - Path & Filesystem Helpers

    private enum SafeReadResult {
        case data(Data)
        case unreadable(String)
    }

    private static func readRegularFilePrefix(at url: URL, maxBytes: Int) -> SafeReadResult {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            return .unreadable(String(cString: strerror(errno)))
        }
        defer { Darwin.close(fd) }

        var st = stat()
        guard Darwin.fstat(fd, &st) == 0 else {
            return .unreadable(String(cString: strerror(errno)))
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            return .unreadable("Entry is not a regular file")
        }

        var result = Data()
        result.reserveCapacity(min(maxBytes, Int(min(UInt64(maxBytes), st.st_size > 0 ? UInt64(st.st_size) : 0))))
        let chunkSize = min(maxBytes, 65536)
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        while result.count < maxBytes {
            let remaining = maxBytes - result.count
            let toRead = min(chunkSize, remaining)
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuf in
                Darwin.read(fd, rawBuf.baseAddress, toRead)
            }
            if bytesRead > 0 {
                result.append(buffer, count: bytesRead)
            } else if bytesRead == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                return .unreadable(String(cString: strerror(errno)))
            }
        }

        return .data(result)
    }

    private static func validateQuarantineRelativePath(_ relativePath: String) throws {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasSuffix("/"),
              !relativePath.contains("\\"),
              !relativePath.utf8.contains(0) else {
            throw ShaderCacheVerifierError.invalidRelativePath(relativePath)
        }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else {
            throw ShaderCacheVerifierError.invalidRelativePath(relativePath)
        }

        for (index, component) in components.enumerated() {
            if component.isEmpty || component == "." || component == ".." {
                throw ShaderCacheVerifierError.invalidRelativePath(relativePath)
            }
            if index == 0 && component.lowercased() == quarantineFolderName.lowercased() {
                throw ShaderCacheVerifierError.invalidRelativePath(relativePath)
            }
        }
    }

    private static func validateNoSymlinkParents(relativePath: String, under root: URL) throws {
        let components = relativePath.split(separator: "/").map(String.init)
        guard components.count > 1 else { return }

        var current = root
        for component in components.dropLast() {
            current = current.appendingPathComponent(component, isDirectory: true)
            var st = stat()
            guard Darwin.lstat(current.path, &st) == 0 else {
                // Parent does not exist; leaf will be skipped cleanly.
                return
            }
            if (st.st_mode & S_IFMT) == S_IFLNK {
                throw ShaderCacheVerifierError.symlinkEscapeBlocked(relativePath)
            }
        }
    }

    private static func canonicalPath(for path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else {
            return nil
        }
        defer { Darwin.free(resolved) }
        return String(cString: resolved)
    }

    private static func pathExistsViaLstat(_ path: String) -> Bool {
        var st = stat()
        return Darwin.lstat(path, &st) == 0
    }

    private static func trimTrailingSlashes(_ path: String) -> String {
        var out = path
        while out.count > 1 && out.hasSuffix("/") {
            out.removeLast()
        }
        return out
    }

    private static func hasMagic(_ bytes: [UInt8], _ magic: [UInt8]) -> Bool {
        guard bytes.count >= magic.count else { return false }
        for i in 0..<magic.count {
            if bytes[i] != magic[i] { return false }
        }
        return true
    }

    private static func startsWithJSONContainer(_ bytes: [UInt8]) -> Bool {
        var index = 0
        if bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
            index = 3
        }
        while index < bytes.count {
            let b = bytes[index]
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                index += 1
                continue
            }
            return b == 0x7B || b == 0x5B // '{' or '['
        }
        return false
    }

    private static func hexPreview(_ bytes: [UInt8], count: Int) -> String {
        let slice = bytes.prefix(count)
        guard !slice.isEmpty else { return "<empty>" }
        return "0x" + slice.map { String(format: "%02X", $0) }.joined()
    }

    private static func currentUtcTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date())
    }

    private static func quarantineTimestampString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let posix = Locale(identifier: "en_US_POSIX")
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1_048_576 {
            return String(format: "%.1f KB", locale: posix, Double(bytes) / 1024.0)
        } else if bytes < 1_073_741_824 {
            return String(format: "%.2f MB", locale: posix, Double(bytes) / 1_048_576.0)
        } else {
            return String(format: "%.2f GB", locale: posix, Double(bytes) / 1_073_741_824.0)
        }
    }
}
