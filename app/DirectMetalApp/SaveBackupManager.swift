import CryptoKit
import Darwin
import Foundation

// Self-contained Prefix Save Data Backup & Restore Manager.
// Discovers Wine prefix save files under <prefix>/drive_c/users/, hashes payloads with CryptoKit SHA-256,
// packs verified .tar.gz archives with save_manifest.json, and validates paths, file types, and checksums
// before atomically restoring into a target prefix.

// MARK: - Data Models & Errors

struct SaveBackupFileRecord: Codable, Equatable, Sendable {
    let relativePath: String
    let sizeBytes: UInt64
    let sha256: String
}

struct SaveBackupManifest: Codable, Equatable, Sendable {
    static let currentSchema = "directmetal.prefix_saves.v1"

    let schema: String
    let prefixName: String
    let exportedUtc: String
    let fileCount: Int
    let totalBytes: UInt64
    let files: [SaveBackupFileRecord]
}

struct SaveBackupExportResult: Codable, Equatable, Sendable {
    let prefixName: String
    let archivePath: String
    let archiveBytes: UInt64
    let fileCount: Int
    let totalPayloadBytes: UInt64
    let manifestSha256: String
}

struct SaveBackupImportResult: Codable, Equatable, Sendable {
    let prefixName: String
    let sourceArchive: String
    let restoredFiles: Int
    let totalBytes: UInt64
}

enum SaveBackupError: Error, CustomStringConvertible, Equatable, Sendable {
    case prefixNotFound(String)
    case noSaveFilesFound(String)
    case archiveFailed(String)
    case invalidManifest(String)
    case unsafePath(String)
    case checksumMismatch(String)

    var description: String {
        switch self {
        case .prefixNotFound(let message),
             .noSaveFilesFound(let message),
             .archiveFailed(let message),
             .invalidManifest(let message),
             .unsafePath(let message),
             .checksumMismatch(let message):
            return message
        }
    }
}

// MARK: - Save Backup Manager

enum SaveBackupManager {
    static let manifestFileName = "save_manifest.json"
    static let payloadDirectoryName = "files"
    static let parallelHashThreshold = 8

    static let saveSubtrees: [String] = [
        "Documents",
        "Saved Games",
        "AppData/Local",
        "AppData/LocalLow",
        "AppData/Roaming",
    ]

    static let skippedFolderNames: Set<String> = [
        "temp",
        "temporary internet files",
        "inetcache",
        "crashdumps",
        "microsoft",
        "wine",
        "shadercache",
        "caches",
    ]

    // MARK: - Path Validation

    /// Validates that `rel` is a safe relative file path confined strictly inside `<prefix>/drive_c/users/`.
    /// Rejects empty paths, leading/trailing `/`, `.` or `..` path components, empty path segments,
    /// backslashes, NUL bytes, and any path escaping the users root.
    static func isSafeRelativePath(_ rel: String) -> Bool {
        guard !rel.isEmpty else { return false }
        guard !rel.hasPrefix("/"), !rel.hasSuffix("/") else { return false }
        guard !rel.contains("\\") else { return false }
        guard !rel.utf8.contains(0) else { return false }

        let components = rel.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        for component in components {
            if component.isEmpty || component == "." || component == ".." {
                return false
            }
        }

        let syntheticUsersRoot = URL(fileURLWithPath: "/directmetal_prefix/drive_c/users", isDirectory: true)
        let resolvedPath = syntheticUsersRoot.appendingPathComponent(rel).standardizedFileURL.path
        return resolvedPath.hasPrefix(syntheticUsersRoot.path + "/")
    }

    // MARK: - Save File Discovery

    /// Scans `<prefix>/drive_c/users/<user>/` save subtrees (`Documents`, `Saved Games`,
    /// `AppData/Local`, `AppData/LocalLow`, `AppData/Roaming`) while skipping symlinks,
    /// `Public`, and noisy system/temp folders.
    static func discoverSaveFiles(
        in prefixURL: URL
    ) -> [(relativePath: String, fileURL: URL, sizeBytes: UInt64)] {
        let fm = FileManager.default
        let driveC = prefixURL.appendingPathComponent("drive_c", isDirectory: true)
        let usersRoot = driveC.appendingPathComponent("users", isDirectory: true)

        guard isRealDirectory(driveC), isRealDirectory(usersRoot) else {
            return []
        }

        guard let userEntries = try? fm.contentsOfDirectory(
            at: usersRoot,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return []
        }

        var discovered: [(relativePath: String, fileURL: URL, sizeBytes: UInt64)] = []
        var seenRelativePaths: Set<String> = []

        for userURL in userEntries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let userName = userURL.lastPathComponent
            if userName.caseInsensitiveCompare("Public") == .orderedSame {
                continue
            }
            guard isRealDirectory(userURL) else {
                continue
            }

            for subtree in saveSubtrees {
                guard let subtreeURL = resolveRealSubtreeDirectory(under: userURL, relativeSubtree: subtree) else {
                    continue
                }
                let baseRelative = "\(userName)/\(subtree)"
                collectSaveFiles(
                    in: subtreeURL,
                    relativePrefix: baseRelative,
                    fileManager: fm,
                    seenRelativePaths: &seenRelativePaths,
                    into: &discovered
                )
            }
        }

        discovered.sort { $0.relativePath < $1.relativePath }
        return discovered
    }

    // MARK: - Export

    /// Discovers save files in `prefixName`, hashes each with CryptoKit `SHA256` (in parallel when >= 8 files),
    /// writes `save_manifest.json` + payload under `files/` in a temp staging directory, and packs them via
    /// `/usr/bin/tar -czf` to `archivePath`.
    static func exportSaves(
        prefixName: String,
        to archivePath: String,
        prefixManager: PrefixManager = PrefixManager()
    ) throws -> SaveBackupExportResult {
        let fm = FileManager.default
        let trimmedPrefix = prefixName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrefix.isEmpty else {
            throw SaveBackupError.prefixNotFound("Prefix name must not be empty")
        }

        let trimmedArchivePath = archivePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArchivePath.isEmpty else {
            throw SaveBackupError.archiveFailed("Destination archive path must not be empty")
        }

        let prefixURL = prefixManager.prefixURL(named: trimmedPrefix)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: prefixURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw SaveBackupError.prefixNotFound("Prefix '\(trimmedPrefix)' not found at \(prefixURL.path)")
        }

        let discovered = discoverSaveFiles(in: prefixURL)
        guard !discovered.isEmpty else {
            throw SaveBackupError.noSaveFilesFound(
                "No save files found in prefix '\(trimmedPrefix)' under \(prefixURL.path)/drive_c/users"
            )
        }

        let staging = fm.temporaryDirectory.appendingPathComponent(
            "dm_save_export_\(UUID().uuidString)",
            isDirectory: true
        )
        let payloadDir = staging.appendingPathComponent(payloadDirectoryName, isDirectory: true)
        do {
            try fm.createDirectory(at: payloadDir, withIntermediateDirectories: true)
        } catch {
            throw SaveBackupError.archiveFailed("Failed to create staging directory: \(error)")
        }
        defer { try? fm.removeItem(at: staging) }

        var stagedFiles: [(relativePath: String, stagedURL: URL, sizeBytes: UInt64)] = []
        stagedFiles.reserveCapacity(discovered.count)

        for item in discovered {
            guard isSafeRelativePath(item.relativePath) else {
                throw SaveBackupError.unsafePath("Discovered unsafe save path: \(item.relativePath)")
            }
            let stagedURL = payloadDir.appendingPathComponent(item.relativePath)
            let parentDir = stagedURL.deletingLastPathComponent()
            do {
                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            } catch {
                throw SaveBackupError.archiveFailed(
                    "Failed to create staging directory for \(item.relativePath): \(error)"
                )
            }
            let copiedSize = try copyRegularFileNoFollow(from: item.fileURL, to: stagedURL)
            stagedFiles.append((relativePath: item.relativePath, stagedURL: stagedURL, sizeBytes: copiedSize))
        }

        var records = try hashStagedFiles(stagedFiles)
        records.sort { $0.relativePath < $1.relativePath }

        let totalPayloadBytes = records.reduce(UInt64(0)) { $0 &+ $1.sizeBytes }
        let manifest = SaveBackupManifest(
            schema: SaveBackupManifest.currentSchema,
            prefixName: trimmedPrefix,
            exportedUtc: ISO8601DateFormatter().string(from: Date()),
            fileCount: records.count,
            totalBytes: totalPayloadBytes,
            files: records
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifestData: Data
        do {
            manifestData = try encoder.encode(manifest)
        } catch {
            throw SaveBackupError.archiveFailed("Failed to encode \(manifestFileName): \(error)")
        }

        let manifestURL = staging.appendingPathComponent(manifestFileName)
        do {
            try manifestData.write(to: manifestURL, options: .atomic)
        } catch {
            throw SaveBackupError.archiveFailed("Failed to write \(manifestFileName): \(error)")
        }
        let manifestSha256 = hexString(from: SHA256.hash(data: manifestData))

        let expandedArchivePath = (trimmedArchivePath as NSString).expandingTildeInPath
        let outURL = URL(fileURLWithPath: expandedArchivePath).standardizedFileURL
        let outParent = outURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: outParent, withIntermediateDirectories: true)
        } catch {
            throw SaveBackupError.archiveFailed("Failed to create archive parent directory \(outParent.path): \(error)")
        }

        let tmpArchiveURL = outParent.appendingPathComponent(".\(outURL.lastPathComponent).tmp.\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmpArchiveURL) }

        try runTar([
            "-czf", tmpArchiveURL.path,
            "-C", staging.path,
            manifestFileName,
            payloadDirectoryName,
        ])

        if Darwin.rename(tmpArchiveURL.path, outURL.path) != 0 {
            let err = errno
            throw SaveBackupError.archiveFailed(
                "Failed to move archive into place at \(outURL.path): \(String(cString: strerror(err)))"
            )
        }

        let archiveBytes: UInt64
        do {
            let attrs = try fm.attributesOfItem(atPath: outURL.path)
            archiveBytes = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        } catch {
            throw SaveBackupError.archiveFailed("Failed to stat output archive \(outURL.path): \(error)")
        }

        return SaveBackupExportResult(
            prefixName: trimmedPrefix,
            archivePath: outURL.path,
            archiveBytes: archiveBytes,
            fileCount: records.count,
            totalPayloadBytes: totalPayloadBytes,
            manifestSha256: manifestSha256
        )
    }

    // MARK: - Import

    /// Extracts `archivePath` into a fresh temp staging directory, parses and validates `save_manifest.json`,
    /// verifies every `relativePath` via `isSafeRelativePath`, verifies every extracted file is a regular
    /// non-symlink file whose SHA-256 matches `record.sha256` BEFORE writing anything to `<prefix>/drive_c/users/`,
    /// then atomically copies/replaces verified files into `<prefix>/drive_c/users/`.
    static func importSaves(
        from archivePath: String,
        into prefixName: String,
        prefixManager: PrefixManager = PrefixManager()
    ) throws -> SaveBackupImportResult {
        let fm = FileManager.default
        let trimmedPrefix = prefixName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrefix.isEmpty else {
            throw SaveBackupError.prefixNotFound("Prefix name must not be empty")
        }

        let trimmedArchivePath = archivePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArchivePath.isEmpty else {
            throw SaveBackupError.archiveFailed("Source archive path must not be empty")
        }

        let prefixURL = prefixManager.prefixURL(named: trimmedPrefix)
        var prefixIsDir: ObjCBool = false
        guard fm.fileExists(atPath: prefixURL.path, isDirectory: &prefixIsDir), prefixIsDir.boolValue else {
            throw SaveBackupError.prefixNotFound("Prefix '\(trimmedPrefix)' not found at \(prefixURL.path)")
        }

        let expandedArchivePath = (trimmedArchivePath as NSString).expandingTildeInPath
        let archiveURL = URL(fileURLWithPath: expandedArchivePath).standardizedFileURL
        guard fm.fileExists(atPath: archiveURL.path) else {
            throw SaveBackupError.archiveFailed("Save backup archive not found: \(archiveURL.path)")
        }

        let staging = fm.temporaryDirectory.appendingPathComponent(
            "dm_save_import_\(UUID().uuidString)",
            isDirectory: true
        )
        let extractDir = staging.appendingPathComponent("extracted", isDirectory: true)
        do {
            try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        } catch {
            throw SaveBackupError.archiveFailed("Failed to create import staging directory: \(error)")
        }
        defer { try? fm.removeItem(at: staging) }

        try runTar(["-xzf", archiveURL.path, "-C", extractDir.path])

        // 1. Parse and validate save_manifest.json
        let manifestURL = extractDir.appendingPathComponent(manifestFileName)
        guard isRealRegularFile(manifestURL) else {
            throw SaveBackupError.invalidManifest(
                "Missing or invalid \(manifestFileName) in archive \(archiveURL.lastPathComponent)"
            )
        }

        let manifest: SaveBackupManifest
        do {
            let manifestData = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode(SaveBackupManifest.self, from: manifestData)
        } catch {
            throw SaveBackupError.invalidManifest("Failed to decode \(manifestFileName): \(error)")
        }

        guard manifest.schema == SaveBackupManifest.currentSchema else {
            throw SaveBackupError.invalidManifest(
                "Unsupported save backup schema '\(manifest.schema)'; expected '\(SaveBackupManifest.currentSchema)'"
            )
        }

        guard manifest.fileCount == manifest.files.count else {
            throw SaveBackupError.invalidManifest(
                "Manifest fileCount (\(manifest.fileCount)) does not match files array count (\(manifest.files.count))"
            )
        }

        let payloadDir = extractDir.appendingPathComponent(payloadDirectoryName, isDirectory: true)
        guard isRealDirectory(payloadDir) else {
            if pathExistsViaLstat(payloadDir) {
                throw SaveBackupError.unsafePath("Archive payload root '\(payloadDirectoryName)' is not a regular directory")
            }
            throw SaveBackupError.invalidManifest("Archive is missing '\(payloadDirectoryName)/' payload directory")
        }

        let canonicalPayloadRoot = payloadDir.resolvingSymlinksInPath().path
        let driveC = prefixURL.appendingPathComponent("drive_c", isDirectory: true)
        let usersRoot = driveC.appendingPathComponent("users", isDirectory: true)

        // Ensure target prefix's drive_c / users are not symlinks before touching anything
        try validateNoSymlinkAtRoot(driveC, label: "drive_c")
        try validateNoSymlinkAtRoot(usersRoot, label: "drive_c/users")

        // 2. Validate EVERY relativePath, extracted file type (regular non-symlink), and destination safety
        var seenPaths: Set<String> = []
        seenPaths.reserveCapacity(manifest.files.count)
        var verifiedEntries: [(record: SaveBackupFileRecord, extractedURL: URL, actualSize: UInt64)] = []
        verifiedEntries.reserveCapacity(manifest.files.count)

        for record in manifest.files {
            guard isSafeRelativePath(record.relativePath) else {
                throw SaveBackupError.unsafePath("Unsafe relative path in manifest: '\(record.relativePath)'")
            }
            guard seenPaths.insert(record.relativePath).inserted else {
                throw SaveBackupError.invalidManifest("Duplicate relative path in manifest: '\(record.relativePath)'")
            }

            let extractedFileURL = try validateExtractedRegularFile(
                relativePath: record.relativePath,
                under: payloadDir,
                canonicalPayloadRoot: canonicalPayloadRoot
            )

            let actualSize = try regularFileSize(at: extractedFileURL)
            if actualSize != record.sizeBytes {
                throw SaveBackupError.checksumMismatch(
                    "File size mismatch for \(record.relativePath): expected \(record.sizeBytes) bytes, got \(actualSize) bytes"
                )
            }

            // Pre-flight destination path safety: ensure no existing symlink or conflicting file/dir in target prefix
            try validateDestinationPathSafety(relativePath: record.relativePath, under: usersRoot)

            verifiedEntries.append((record: record, extractedURL: extractedFileURL, actualSize: actualSize))
        }

        // 3. Verify EVERY extracted file's SHA-256 BEFORE writing anything to <prefix>/drive_c/users/
        try verifyExtractedFiles(verifiedEntries)

        // 4. Atomically copy & replace every verified file into <prefix>/drive_c/users/
        do {
            try fm.createDirectory(at: usersRoot, withIntermediateDirectories: true)
        } catch {
            throw SaveBackupError.archiveFailed("Failed to create \(usersRoot.path): \(error)")
        }

        var restoredBytes: UInt64 = 0
        for entry in verifiedEntries {
            let destURL = usersRoot.appendingPathComponent(entry.record.relativePath)
            let parentDir = destURL.deletingLastPathComponent()
            do {
                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            } catch {
                throw SaveBackupError.archiveFailed(
                    "Failed to create destination directory for \(entry.record.relativePath): \(error)"
                )
            }

            let tempDestURL = parentDir.appendingPathComponent(".dm_save_restore_\(UUID().uuidString).tmp")
            do {
                _ = try copyRegularFileNoFollow(from: entry.extractedURL, to: tempDestURL)
            } catch {
                try? fm.removeItem(at: tempDestURL)
                throw error
            }

            if Darwin.rename(tempDestURL.path, destURL.path) != 0 {
                let err = errno
                try? fm.removeItem(at: tempDestURL)
                throw SaveBackupError.archiveFailed(
                    "Failed to atomically restore \(entry.record.relativePath): \(String(cString: strerror(err)))"
                )
            }

            restoredBytes &+= entry.actualSize
        }

        return SaveBackupImportResult(
            prefixName: trimmedPrefix,
            sourceArchive: archiveURL.path,
            restoredFiles: verifiedEntries.count,
            totalBytes: restoredBytes
        )
    }

    // MARK: - Discovery Helpers

    private static func resolveRealSubtreeDirectory(under userURL: URL, relativeSubtree: String) -> URL? {
        var current = userURL
        for component in relativeSubtree.split(separator: "/") {
            current = current.appendingPathComponent(String(component), isDirectory: true)
            guard isRealDirectory(current) else {
                return nil
            }
        }
        return current
    }

    private static func collectSaveFiles(
        in directoryURL: URL,
        relativePrefix: String,
        fileManager: FileManager,
        seenRelativePaths: inout Set<String>,
        into output: inout [(relativePath: String, fileURL: URL, sizeBytes: UInt64)]
    ) {
        var stack: [(dirURL: URL, relPrefix: String)] = [(directoryURL, relativePrefix)]

        while let current = stack.popLast() {
            guard let children = try? fileManager.contentsOfDirectory(
                at: current.dirURL,
                includingPropertiesForKeys: nil,
                options: []
            ) else {
                continue
            }

            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = child.lastPathComponent
                if name == ".DS_Store" {
                    continue
                }

                var st = stat()
                guard lstat(child.path, &st) == 0 else {
                    continue
                }
                let fileType = st.st_mode & S_IFMT

                if fileType == S_IFLNK {
                    continue
                }

                let relPath = "\(current.relPrefix)/\(name)"

                if fileType == S_IFDIR {
                    if skippedFolderNames.contains(name.lowercased()) {
                        continue
                    }
                    stack.append((dirURL: child, relPrefix: relPath))
                } else if fileType == S_IFREG {
                    guard isSafeRelativePath(relPath), seenRelativePaths.insert(relPath).inserted else {
                        continue
                    }
                    let size = st.st_size > 0 ? UInt64(st.st_size) : 0
                    output.append((relativePath: relPath, fileURL: child, sizeBytes: size))
                }
            }
        }
    }

    // MARK: - Parallel Hashing & Verification

    private static func hashStagedFiles(
        _ items: [(relativePath: String, stagedURL: URL, sizeBytes: UInt64)]
    ) throws -> [SaveBackupFileRecord] {
        guard items.count >= parallelHashThreshold else {
            return try items.map { item in
                let digest = try sha256Hex(fileAt: item.stagedURL)
                return SaveBackupFileRecord(
                    relativePath: item.relativePath,
                    sizeBytes: item.sizeBytes,
                    sha256: digest
                )
            }
        }

        let lock = NSLock()
        var results = [SaveBackupFileRecord?](repeating: nil, count: items.count)
        var firstError: Error?

        DispatchQueue.concurrentPerform(iterations: items.count) { idx in
            lock.lock()
            let aborted = firstError != nil
            lock.unlock()
            if aborted { return }

            let item = items[idx]
            do {
                let digest = try sha256Hex(fileAt: item.stagedURL)
                let record = SaveBackupFileRecord(
                    relativePath: item.relativePath,
                    sizeBytes: item.sizeBytes,
                    sha256: digest
                )
                lock.lock()
                results[idx] = record
                lock.unlock()
            } catch {
                lock.lock()
                if firstError == nil { firstError = error }
                lock.unlock()
            }
        }

        if let error = firstError {
            throw error
        }
        return results.compactMap { $0 }
    }

    private static func verifyExtractedFiles(
        _ entries: [(record: SaveBackupFileRecord, extractedURL: URL, actualSize: UInt64)]
    ) throws {
        guard entries.count >= parallelHashThreshold else {
            for entry in entries {
                let actualHash = try sha256Hex(fileAt: entry.extractedURL)
                if actualHash.caseInsensitiveCompare(entry.record.sha256) != .orderedSame {
                    throw SaveBackupError.checksumMismatch(
                        "SHA-256 mismatch for \(entry.record.relativePath): expected \(entry.record.sha256), got \(actualHash)"
                    )
                }
            }
            return
        }

        let lock = NSLock()
        var firstError: Error?

        DispatchQueue.concurrentPerform(iterations: entries.count) { idx in
            lock.lock()
            let aborted = firstError != nil
            lock.unlock()
            if aborted { return }

            let entry = entries[idx]
            do {
                let actualHash = try sha256Hex(fileAt: entry.extractedURL)
                if actualHash.caseInsensitiveCompare(entry.record.sha256) != .orderedSame {
                    let mismatch = SaveBackupError.checksumMismatch(
                        "SHA-256 mismatch for \(entry.record.relativePath): expected \(entry.record.sha256), got \(actualHash)"
                    )
                    lock.lock()
                    if firstError == nil { firstError = mismatch }
                    lock.unlock()
                }
            } catch {
                lock.lock()
                if firstError == nil { firstError = error }
                lock.unlock()
            }
        }

        if let error = firstError {
            throw error
        }
    }

    // MARK: - Filesystem & Security Helpers

    private static func pathExistsViaLstat(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    private static func isRealRegularFile(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    private static func regularFileSize(at url: URL) throws -> UInt64 {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            throw SaveBackupError.checksumMismatch("Missing extracted file at \(url.path)")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw SaveBackupError.unsafePath("Expected regular file at \(url.path)")
        }
        return st.st_size > 0 ? UInt64(st.st_size) : 0
    }

    private static func validateNoSymlinkAtRoot(_ url: URL, label: String) throws {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            return
        }
        let fileType = st.st_mode & S_IFMT
        if fileType == S_IFLNK {
            throw SaveBackupError.unsafePath("Target prefix \(label) is a symlink: \(url.path)")
        }
        if fileType != S_IFDIR {
            throw SaveBackupError.unsafePath("Target prefix \(label) is not a directory: \(url.path)")
        }
    }

    private static func validateExtractedRegularFile(
        relativePath: String,
        under payloadDir: URL,
        canonicalPayloadRoot: String
    ) throws -> URL {
        let components = relativePath.split(separator: "/").map(String.init)
        var current = payloadDir

        for (index, component) in components.enumerated() {
            let isLast = (index == components.count - 1)
            current = current.appendingPathComponent(component, isDirectory: !isLast)

            var st = stat()
            if lstat(current.path, &st) != 0 {
                if errno == ENOENT {
                    throw SaveBackupError.checksumMismatch("Missing file listed in manifest: \(relativePath)")
                }
                throw SaveBackupError.archiveFailed(
                    "Unable to inspect extracted path '\(relativePath)': \(String(cString: strerror(errno)))"
                )
            }

            let fileType = st.st_mode & S_IFMT
            if fileType == S_IFLNK {
                throw SaveBackupError.unsafePath("Extracted path contains a symlink: '\(relativePath)'")
            }
            if isLast {
                guard fileType == S_IFREG else {
                    throw SaveBackupError.unsafePath("Extracted entry is not a regular file: '\(relativePath)'")
                }
            } else {
                guard fileType == S_IFDIR else {
                    throw SaveBackupError.unsafePath("Extracted parent component is not a directory: '\(relativePath)'")
                }
            }
        }

        let canonicalFile = current.resolvingSymlinksInPath().path
        guard canonicalFile.hasPrefix(canonicalPayloadRoot + "/") else {
            throw SaveBackupError.unsafePath("Extracted file escapes archive payload root: '\(relativePath)'")
        }

        return current
    }

    private static func validateDestinationPathSafety(relativePath: String, under usersRoot: URL) throws {
        let components = relativePath.split(separator: "/").map(String.init)
        var current = usersRoot

        for (index, component) in components.enumerated() {
            let isLast = (index == components.count - 1)
            current = current.appendingPathComponent(component, isDirectory: !isLast)

            var st = stat()
            guard lstat(current.path, &st) == 0 else {
                // Path does not exist yet in target prefix — safe to create later.
                return
            }

            let fileType = st.st_mode & S_IFMT
            if fileType == S_IFLNK {
                throw SaveBackupError.unsafePath(
                    "Target prefix contains a symlink along restore path '\(relativePath)': \(current.path)"
                )
            }
            if isLast {
                if fileType != S_IFREG {
                    throw SaveBackupError.unsafePath(
                        "Target prefix destination '\(relativePath)' exists and is not a regular file"
                    )
                }
            } else {
                if fileType != S_IFDIR {
                    throw SaveBackupError.unsafePath(
                        "Target prefix parent component along '\(relativePath)' is not a directory"
                    )
                }
            }
        }
    }

    @discardableResult
    private static func copyRegularFileNoFollow(from src: URL, to dst: URL) throws -> UInt64 {
        let srcFD = open(src.path, O_RDONLY | O_NOFOLLOW)
        guard srcFD >= 0 else {
            let err = errno
            if err == ELOOP {
                throw SaveBackupError.unsafePath("Refused to follow symlink during copy: \(src.path)")
            }
            throw SaveBackupError.archiveFailed(
                "Unable to open source file \(src.path): \(String(cString: strerror(err)))"
            )
        }
        defer { close(srcFD) }

        var st = stat()
        guard fstat(srcFD, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            throw SaveBackupError.unsafePath("Refused to copy non-regular file: \(src.path)")
        }

        let dstFD = open(dst.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard dstFD >= 0 else {
            let err = errno
            throw SaveBackupError.archiveFailed(
                "Unable to create destination file \(dst.path): \(String(cString: strerror(err)))"
            )
        }

        var succeeded = false
        defer {
            close(dstFD)
            if !succeeded {
                unlink(dst.path)
            }
        }

        var totalWritten: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuf in
                Darwin.read(srcFD, rawBuf.baseAddress, rawBuf.count)
            }
            if bytesRead > 0 {
                var offset = 0
                while offset < bytesRead {
                    let written = buffer.withUnsafeBytes { rawBuf in
                        Darwin.write(dstFD, rawBuf.baseAddress!.advanced(by: offset), bytesRead - offset)
                    }
                    if written > 0 {
                        offset += written
                    } else if errno == EINTR {
                        continue
                    } else {
                        throw SaveBackupError.archiveFailed(
                            "Write error copying \(src.path) to \(dst.path): \(String(cString: strerror(errno)))"
                        )
                    }
                }
                totalWritten &+= UInt64(bytesRead)
            } else if bytesRead == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw SaveBackupError.archiveFailed(
                    "Read error copying \(src.path): \(String(cString: strerror(errno)))"
                )
            }
        }

        let mode = (st.st_mode & 0o777)
        let targetMode: mode_t = mode == 0 ? 0o644 : mode
        _ = fchmod(dstFD, targetMode)

        succeeded = true
        return totalWritten
    }

    private static func sha256Hex(fileAt url: URL) throws -> String {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            let err = errno
            if err == ELOOP {
                throw SaveBackupError.unsafePath("Refused to hash symlink: \(url.path)")
            }
            throw SaveBackupError.archiveFailed(
                "Unable to open file for SHA-256 hashing (\(url.path)): \(String(cString: strerror(err)))"
            )
        }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            throw SaveBackupError.unsafePath("Refused to hash non-regular file: \(url.path)")
        }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuf in
                Darwin.read(fd, rawBuf.baseAddress, rawBuf.count)
            }
            if bytesRead > 0 {
                buffer.withUnsafeBytes { rawBuf in
                    hasher.update(
                        bufferPointer: UnsafeRawBufferPointer(start: rawBuf.baseAddress, count: bytesRead)
                    )
                }
            } else if bytesRead == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw SaveBackupError.archiveFailed(
                    "Read error while hashing \(url.path): \(String(cString: strerror(errno)))"
                )
            }
        }
        return hexString(from: hasher.finalize())
    }

    private static func hexString(from digest: SHA256Digest) -> String {
        let hexChars: [UInt8] = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(64)
        for byte in digest {
            out.append(hexChars[Int(byte >> 4)])
            out.append(hexChars[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func runTar(_ args: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["COPYFILE_DISABLE"] = "1"
        proc.environment = env

        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            throw SaveBackupError.archiveFailed("Failed to launch /usr/bin/tar: \(error)")
        }

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            let errText = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = errText.isEmpty ? "tar exited with status \(proc.terminationStatus)" : errText
            throw SaveBackupError.archiveFailed(detail)
        }
    }
}
