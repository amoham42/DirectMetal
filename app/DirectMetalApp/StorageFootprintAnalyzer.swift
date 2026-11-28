import Darwin
import Foundation

// Self-contained DirectMetal Storage Footprint & Reclamation Analyzer.
// Safely inspects DirectMetal's on-disk storage categories (Wine prefixes, Metal/DXVK shader
// caches, quarantined shaders, prefix save backups, user-installed runtimes, and App Support
// metadata) using symlink-safe `lstat` traversal, identifies reclaimable storage, and formats
// deterministic home-redacted CLI text and GitHub-Flavored Markdown reports.

// MARK: - Data Models

struct StorageCategoryBreakdown: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let path: String
    let itemCount: Int
    let totalBytes: UInt64
    let reclaimableBytes: UInt64
    let note: String
}

struct StorageReclamationSuggestion: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let reclaimableBytes: UInt64
    let commandHint: String
    let detail: String
}

struct StorageFootprintReport: Codable, Equatable, Sendable {
    let generatedAtUtc: String
    let totalBytes: UInt64
    let totalReclaimableBytes: UInt64
    let categories: [StorageCategoryBreakdown]
    let suggestions: [StorageReclamationSuggestion]
}

// MARK: - Storage Footprint Analyzer

enum StorageFootprintAnalyzer {
    private static let saveBackupsFolderName = "SaveBackups"
    private static let userRuntimeCandidateNames = [
        "Runtime",
        "Runtime-arm64ec",
        "Runtimes",
    ]

    /// Analyzes DirectMetal's disk footprint across all 6 managed storage categories without
    /// following symlinks or opening FIFOs/special files, and returns actionable reclamation
    /// suggestions sorted by highest `reclaimableBytes` first.
    static func analyze(
        supportRoot: URL? = nil,
        prefixRoot: URL? = nil,
        shaderCacheRoot: URL? = nil,
        libraryEntries: [GameLibraryEntry]? = nil,
        hostCacheKey: String? = nil
    ) -> StorageFootprintReport {
        let resolvedSupportRoot = (supportRoot ?? GameLibraryManager.defaultSupportRoot()).standardizedFileURL
        let resolvedPrefixRoot: URL
        if let explicitPrefixRoot = prefixRoot {
            resolvedPrefixRoot = explicitPrefixRoot.standardizedFileURL
        } else if supportRoot != nil {
            resolvedPrefixRoot = resolvedSupportRoot
                .appendingPathComponent("Prefixes", isDirectory: true)
                .standardizedFileURL
        } else {
            resolvedPrefixRoot = PrefixManager().prefixRoot.standardizedFileURL
        }
        let resolvedShaderCacheRoot = (shaderCacheRoot ?? RuntimeLauncher.shaderCacheRoot()).standardizedFileURL

        let resolvedEntries = libraryEntries ?? GameLibraryManager(
            supportRoot: resolvedSupportRoot,
            prefixRoot: resolvedPrefixRoot
        ).load()

        let effectiveHostCacheKey: String
        if let providedKey = hostCacheKey {
            effectiveHostCacheKey = providedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            effectiveHostCacheKey = RuntimeLauncher.queryHardwareInfo().cacheKey
        }

        var categories: [StorageCategoryBreakdown] = []
        var suggestions: [StorageReclamationSuggestion] = []

        // 1. Wine Prefixes
        let prefixResult = analyzePrefixes(
            prefixRoot: resolvedPrefixRoot,
            libraryEntries: resolvedEntries
        )
        categories.append(prefixResult.category)
        if let suggestion = prefixResult.suggestion {
            suggestions.append(suggestion)
        }

        // 2. Shader Caches (excluding _quarantine)
        let shaderCacheResult = analyzeShaderCaches(
            shaderCacheRoot: resolvedShaderCacheRoot,
            hostCacheKey: effectiveHostCacheKey
        )
        categories.append(shaderCacheResult.category)
        if let suggestion = shaderCacheResult.suggestion {
            suggestions.append(suggestion)
        }

        // 3. Quarantined Shaders (<shaderCacheRoot>/_quarantine)
        let quarantineResult = analyzeQuarantinedShaders(shaderCacheRoot: resolvedShaderCacheRoot)
        categories.append(quarantineResult.category)
        if let suggestion = quarantineResult.suggestion {
            suggestions.append(suggestion)
        }

        // 4. Save Backups (<supportRoot>/SaveBackups)
        categories.append(analyzeSaveBackups(supportRoot: resolvedSupportRoot))

        // 5. User Runtimes (<supportRoot>/Runtime, <supportRoot>/Runtime-arm64ec, <supportRoot>/Runtimes)
        categories.append(analyzeUserRuntimes(supportRoot: resolvedSupportRoot))

        // 6. Metadata & Config files in <supportRoot>
        categories.append(analyzeMetadata(supportRoot: resolvedSupportRoot))

        suggestions.sort {
            if $0.reclaimableBytes != $1.reclaimableBytes {
                return $0.reclaimableBytes > $1.reclaimableBytes
            }
            return $0.id < $1.id
        }

        let totalBytes = categories.reduce(UInt64(0)) { $0 &+ $1.totalBytes }
        let totalReclaimableBytes = categories.reduce(UInt64(0)) { $0 &+ $1.reclaimableBytes }

        return StorageFootprintReport(
            generatedAtUtc: currentUtcTimestamp(),
            totalBytes: totalBytes,
            totalReclaimableBytes: totalReclaimableBytes,
            categories: categories,
            suggestions: suggestions
        )
    }

    // MARK: - Formatting

    /// Formats a byte count into a deterministic human-readable `B`, `KB`, `MB`, or `GB` string.
    static func formatBytes(_ bytes: UInt64) -> String {
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

    /// Formats a storage footprint report as aligned, home-redacted plain text for CLI output.
    static func formatText(
        _ report: StorageFootprintReport,
        home: String = NSHomeDirectory()
    ) -> String {
        let normalizedHome = normalizeHome(home)
        let redact: (String) -> String = { LaunchDiagnostics.redactHome($0, home: normalizedHome) }

        let reclaimableSummary: String
        if report.totalBytes > 0 && report.totalReclaimableBytes > 0 {
            let pct = Double(report.totalReclaimableBytes) * 100.0 / Double(report.totalBytes)
            let pctText = String(format: "%.1f%%", locale: Locale(identifier: "en_US_POSIX"), pct)
            reclaimableSummary = "\(formatBytes(report.totalReclaimableBytes)) (\(pctText))"
        } else {
            reclaimableSummary = formatBytes(report.totalReclaimableBytes)
        }

        let overviewRows: [(String, String)] = [
            ("Generated At", report.generatedAtUtc),
            ("Total Footprint", formatBytes(report.totalBytes)),
            ("Reclaimable", reclaimableSummary),
            ("Categories", "\(report.categories.count) inspected"),
        ]

        let labelWidth = max((overviewRows.map { $0.0.count }.max() ?? 0) + 2, 18)
        var lines: [String] = ["DirectMetal Storage Footprint & Reclamation Report"]
        lines.append("")
        lines.append("[Overview]")
        for (label, value) in overviewRows {
            lines.append("  \(pad(label + ":", to: labelWidth))\(value)")
        }

        lines.append("")
        lines.append("[Category Breakdown]")
        if report.categories.isEmpty {
            lines.append("  No storage categories reported.")
        } else {
            let headers = ["CATEGORY", "ITEMS", "SIZE", "RECLAIMABLE", "PATH"]
            let rows: [[String]] = report.categories.map { cat in
                [
                    redact(cat.label),
                    "\(cat.itemCount)",
                    formatBytes(cat.totalBytes),
                    formatBytes(cat.reclaimableBytes),
                    redact(cat.path),
                ]
            }

            var widths = headers.map(\.count)
            for row in rows {
                for (index, value) in row.enumerated() where index < widths.count {
                    widths[index] = max(widths[index], value.count)
                }
            }

            lines.append("  " + formatTableRow(headers, widths: widths, rightAligned: [1, 2, 3]))
            lines.append("  " + widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
            for (index, row) in rows.enumerated() {
                lines.append("  " + formatTableRow(row, widths: widths, rightAligned: [1, 2, 3]))
                let note = redact(report.categories[index].note)
                if !note.isEmpty {
                    lines.append("    Note: \(note)")
                }
            }
        }

        lines.append("")
        lines.append("[Reclamation Suggestions]")
        if report.suggestions.isEmpty {
            lines.append("  No reclaimable storage detected.")
        } else {
            for (index, suggestion) in report.suggestions.enumerated() {
                let title = redact(suggestion.title)
                let size = formatBytes(suggestion.reclaimableBytes)
                let command = redact(suggestion.commandHint)
                let detail = redact(suggestion.detail)
                lines.append("  \(index + 1). \(title) (\(size))")
                lines.append("     Command: \(command)")
                lines.append("     Detail:  \(detail)")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Formats a storage footprint report as home-redacted GitHub-Flavored Markdown with
    /// escaped table pipes.
    static func formatMarkdown(
        _ report: StorageFootprintReport,
        home: String = NSHomeDirectory()
    ) -> String {
        let normalizedHome = normalizeHome(home)
        let redact: (String) -> String = { LaunchDiagnostics.redactHome($0, home: normalizedHome) }

        func escapeCell(_ raw: String) -> String {
            redact(raw)
                .replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
        }

        func inlineCodeCell(_ raw: String) -> String {
            let escaped = escapeCell(raw).replacingOccurrences(of: "`", with: "'")
            return "`\(escaped)`"
        }

        let reclaimableSummary: String
        if report.totalBytes > 0 && report.totalReclaimableBytes > 0 {
            let pct = Double(report.totalReclaimableBytes) * 100.0 / Double(report.totalBytes)
            let pctText = String(format: "%.1f%%", locale: Locale(identifier: "en_US_POSIX"), pct)
            reclaimableSummary = "\(formatBytes(report.totalReclaimableBytes)) (\(pctText))"
        } else {
            reclaimableSummary = formatBytes(report.totalReclaimableBytes)
        }

        var lines: [String] = [
            "### DirectMetal Storage Footprint & Reclamation Report",
            "",
            "| Field | Value |",
            "| :--- | :--- |",
            "| **Generated At** | \(inlineCodeCell(report.generatedAtUtc)) |",
            "| **Total Footprint** | \(formatBytes(report.totalBytes)) |",
            "| **Reclaimable** | \(reclaimableSummary) |",
            "| **Suggestions** | \(report.suggestions.count) |",
            "",
            "#### Category Breakdown",
            "",
            "| Category | Items | Size | Reclaimable | Path | Notes |",
            "| :--- | ---: | ---: | ---: | :--- | :--- |",
        ]

        for category in report.categories {
            let labelCell = escapeCell(category.label)
            let sizeCell = formatBytes(category.totalBytes)
            let reclaimableCell = formatBytes(category.reclaimableBytes)
            let pathCell = inlineCodeCell(category.path)
            let noteCell = escapeCell(category.note)
            lines.append("| \(labelCell) | \(category.itemCount) | \(sizeCell) | \(reclaimableCell) | \(pathCell) | \(noteCell) |")
        }

        lines.append("")
        lines.append("#### Reclamation Suggestions")
        lines.append("")
        if report.suggestions.isEmpty {
            lines.append("_No reclaimable storage detected._")
        } else {
            lines.append("| Action | Reclaimable | Command | Detail |")
            lines.append("| :--- | ---: | :--- | :--- |")
            for suggestion in report.suggestions {
                let titleCell = escapeCell(suggestion.title)
                let sizeCell = formatBytes(suggestion.reclaimableBytes)
                let commandCell = inlineCodeCell(suggestion.commandHint)
                let detailCell = escapeCell(suggestion.detail)
                lines.append("| \(titleCell) | \(sizeCell) | \(commandCell) | \(detailCell) |")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Category Analyzers

    private struct CategoryAnalysis {
        let category: StorageCategoryBreakdown
        let suggestion: StorageReclamationSuggestion?
    }

    private static func analyzePrefixes(
        prefixRoot: URL,
        libraryEntries: [GameLibraryEntry]
    ) -> CategoryAnalysis {
        let rootPath = prefixRoot.standardizedFileURL.path
        guard isRealDirectory(atPath: rootPath) else {
            return CategoryAnalysis(
                category: StorageCategoryBreakdown(
                    id: "prefixes",
                    label: "Wine Prefixes",
                    path: rootPath,
                    itemCount: 0,
                    totalBytes: 0,
                    reclaimableBytes: 0,
                    note: "No managed prefixes found."
                ),
                suggestion: nil
            )
        }

        var protectedNames = Set(
            libraryEntries.map { $0.launchPrefixName.replacingOccurrences(of: "/", with: "_") }
        )
        protectedNames.insert("default")

        let children = sortedDirectoryChildren(of: prefixRoot)
        var prefixCount = 0
        var totalBytes: UInt64 = 0
        var reclaimableBytes: UInt64 = 0
        var orphanedNames: [String] = []
        var skippedRunningNames: [String] = []

        for child in children {
            var st = Darwin.stat()
            guard Darwin.lstat(child.path, &st) == 0 else { continue }
            let fileType = st.st_mode & S_IFMT

            if fileType == S_IFLNK {
                continue
            }
            if fileType == S_IFDIR {
                let name = child.lastPathComponent
                let stats = measureDirectoryTree(at: child)
                prefixCount += 1
                totalBytes &+= stats.totalBytes

                if protectedNames.contains(name) {
                    continue
                }
                if WineserverPool.runningPID(prefixURL: child) != nil {
                    skippedRunningNames.append(name)
                    continue
                }
                orphanedNames.append(name)
                reclaimableBytes &+= stats.totalBytes
            } else if fileType == S_IFREG, child.lastPathComponent != ".DS_Store" {
                let sizeBytes: UInt64 = st.st_size > 0 ? UInt64(st.st_size) : 0
                totalBytes &+= sizeBytes
            }
        }

        let note: String
        if prefixCount == 0 {
            note = "No managed prefixes found."
        } else {
            let prefixNoun = prefixCount == 1 ? "prefix" : "prefixes"
            var parts: [String] = ["\(prefixCount) \(prefixNoun)"]
            if orphanedNames.isEmpty {
                parts.append("all referenced or default")
            } else {
                parts.append("\(orphanedNames.count) orphaned (\(formatBytes(reclaimableBytes)) reclaimable)")
            }
            if !skippedRunningNames.isEmpty {
                parts.append("\(skippedRunningNames.count) running protected")
            }
            note = parts.joined(separator: "; ")
        }

        let category = StorageCategoryBreakdown(
            id: "prefixes",
            label: "Wine Prefixes",
            path: rootPath,
            itemCount: prefixCount,
            totalBytes: totalBytes,
            reclaimableBytes: reclaimableBytes,
            note: note
        )

        let suggestion: StorageReclamationSuggestion?
        if reclaimableBytes > 0 {
            let orphanNoun = orphanedNames.count == 1 ? "prefix" : "prefixes"
            let preview = summarizeNames(orphanedNames)
            suggestion = StorageReclamationSuggestion(
                id: "prefixes",
                title: "Prune \(orphanedNames.count) orphaned Wine \(orphanNoun)",
                reclaimableBytes: reclaimableBytes,
                commandHint: "DirectMetal prefix prune",
                detail: "Unreferenced \(orphanNoun) (\(preview)); the 'default' prefix and running prefixes are preserved."
            )
        } else {
            suggestion = nil
        }

        return CategoryAnalysis(category: category, suggestion: suggestion)
    }

    private static func analyzeShaderCaches(
        shaderCacheRoot: URL,
        hostCacheKey: String
    ) -> CategoryAnalysis {
        let rootPath = shaderCacheRoot.standardizedFileURL.path
        guard isRealDirectory(atPath: rootPath) else {
            return CategoryAnalysis(
                category: StorageCategoryBreakdown(
                    id: "shader_caches",
                    label: "Shader Caches",
                    path: rootPath,
                    itemCount: 0,
                    totalBytes: 0,
                    reclaimableBytes: 0,
                    note: "No local shader caches found."
                ),
                suggestion: nil
            )
        }

        let hostKeyLower = hostCacheKey.lowercased()
        let quarantineName = ShaderCacheVerifier.quarantineFolderName
        let children = sortedDirectoryChildren(of: shaderCacheRoot)

        var entryCount = 0
        var totalBytes: UInt64 = 0
        var reclaimableBytes: UInt64 = 0
        var staleEntryNames: [String] = []

        for child in children {
            let name = child.lastPathComponent
            if name == quarantineName {
                continue
            }

            var st = Darwin.stat()
            guard Darwin.lstat(child.path, &st) == 0 else { continue }
            let fileType = st.st_mode & S_IFMT

            if fileType == S_IFLNK {
                continue
            }
            if fileType == S_IFDIR {
                let stats = measureDirectoryTree(at: child)
                entryCount += 1
                totalBytes &+= stats.totalBytes

                let isKeyed = ShaderCacheManager.containsGpuCacheKeyMarker(name)
                let matchesHost = !isKeyed || (!hostKeyLower.isEmpty && name.lowercased().contains(hostKeyLower))
                if isKeyed && !matchesHost {
                    staleEntryNames.append(name)
                    reclaimableBytes &+= stats.totalBytes
                }
            } else if fileType == S_IFREG, name != ".DS_Store" {
                let sizeBytes: UInt64 = st.st_size > 0 ? UInt64(st.st_size) : 0
                entryCount += 1
                totalBytes &+= sizeBytes
            }
        }

        let note: String
        if entryCount == 0 {
            note = "No local shader caches found."
        } else {
            let entryNoun = entryCount == 1 ? "entry" : "entries"
            let keyLabel = hostCacheKey.isEmpty ? "current host" : hostCacheKey
            if staleEntryNames.isEmpty {
                note = "\(entryCount) cache \(entryNoun) (all compatible with \(keyLabel))"
            } else {
                note = "\(entryCount) cache \(entryNoun); \(staleEntryNames.count) stale for \(keyLabel) (\(formatBytes(reclaimableBytes)) reclaimable)"
            }
        }

        let category = StorageCategoryBreakdown(
            id: "shader_caches",
            label: "Shader Caches",
            path: rootPath,
            itemCount: entryCount,
            totalBytes: totalBytes,
            reclaimableBytes: reclaimableBytes,
            note: note
        )

        let suggestion: StorageReclamationSuggestion?
        if reclaimableBytes > 0 {
            let staleNoun = staleEntryNames.count == 1 ? "entry" : "entries"
            let preview = summarizeNames(staleEntryNames)
            let keyLabel = hostCacheKey.isEmpty ? "current host" : hostCacheKey
            suggestion = StorageReclamationSuggestion(
                id: "shader_caches",
                title: "Prune \(staleEntryNames.count) stale shader cache \(staleNoun)",
                reclaimableBytes: reclaimableBytes,
                commandHint: "DirectMetal cache prune",
                detail: "Stale GPU/macOS cache \(staleNoun) (\(preview)) do not match host key '\(keyLabel)'."
            )
        } else {
            suggestion = nil
        }

        return CategoryAnalysis(category: category, suggestion: suggestion)
    }

    private static func analyzeQuarantinedShaders(shaderCacheRoot: URL) -> CategoryAnalysis {
        let quarantineURL = shaderCacheRoot
            .appendingPathComponent(ShaderCacheVerifier.quarantineFolderName, isDirectory: true)
            .standardizedFileURL
        let quarantinePath = quarantineURL.path

        guard isRealDirectory(atPath: quarantinePath) else {
            return CategoryAnalysis(
                category: StorageCategoryBreakdown(
                    id: "quarantined_shaders",
                    label: "Quarantined Shaders",
                    path: quarantinePath,
                    itemCount: 0,
                    totalBytes: 0,
                    reclaimableBytes: 0,
                    note: "No quarantined shader files."
                ),
                suggestion: nil
            )
        }

        let stats = measureDirectoryTree(at: quarantineURL)
        let reclaimableBytes = stats.totalBytes

        let note: String
        if stats.fileCount == 0 {
            note = "Quarantine directory is empty."
        } else if reclaimableBytes > 0 {
            let fileNoun = stats.fileCount == 1 ? "file" : "files"
            note = "\(stats.fileCount) quarantined \(fileNoun) (100% reclaimable)"
        } else {
            let fileNoun = stats.fileCount == 1 ? "file" : "files"
            note = "\(stats.fileCount) zero-byte quarantined \(fileNoun)"
        }

        let category = StorageCategoryBreakdown(
            id: "quarantined_shaders",
            label: "Quarantined Shaders",
            path: quarantinePath,
            itemCount: stats.fileCount,
            totalBytes: stats.totalBytes,
            reclaimableBytes: reclaimableBytes,
            note: note
        )

        let suggestion: StorageReclamationSuggestion?
        if reclaimableBytes > 0 {
            let fileNoun = stats.fileCount == 1 ? "file" : "files"
            suggestion = StorageReclamationSuggestion(
                id: "quarantined_shaders",
                title: "Remove \(stats.fileCount) quarantined shader \(fileNoun)",
                reclaimableBytes: reclaimableBytes,
                commandHint: "rm -rf \"\(quarantinePath)\"",
                detail: "Corrupt shader artifacts previously isolated in \(quarantinePath) can be deleted safely."
            )
        } else {
            suggestion = nil
        }

        return CategoryAnalysis(category: category, suggestion: suggestion)
    }

    private static func analyzeSaveBackups(supportRoot: URL) -> StorageCategoryBreakdown {
        let backupsURL = supportRoot
            .appendingPathComponent(saveBackupsFolderName, isDirectory: true)
            .standardizedFileURL
        let backupsPath = backupsURL.path

        guard isRealDirectory(atPath: backupsPath) else {
            return StorageCategoryBreakdown(
                id: "save_backups",
                label: "Save Backups",
                path: backupsPath,
                itemCount: 0,
                totalBytes: 0,
                reclaimableBytes: 0,
                note: "No save backups found."
            )
        }

        let stats = measureDirectoryTree(at: backupsURL)
        let note: String
        if stats.fileCount == 0 {
            note = "No save backups found."
        } else {
            let fileNoun = stats.fileCount == 1 ? "file" : "files"
            note = "\(stats.fileCount) backup \(fileNoun) (preserved; user backups are not auto-reclaimed)"
        }

        return StorageCategoryBreakdown(
            id: "save_backups",
            label: "Save Backups",
            path: backupsPath,
            itemCount: stats.fileCount,
            totalBytes: stats.totalBytes,
            reclaimableBytes: 0,
            note: note
        )
    }

    private static func analyzeUserRuntimes(supportRoot: URL) -> StorageCategoryBreakdown {
        let supportPath = supportRoot.standardizedFileURL.path
        guard isRealDirectory(atPath: supportPath) else {
            return StorageCategoryBreakdown(
                id: "user_runtimes",
                label: "User Runtimes",
                path: supportPath,
                itemCount: 0,
                totalBytes: 0,
                reclaimableBytes: 0,
                note: "No user-installed runtimes found."
            )
        }

        struct FileIdentity: Hashable {
            let dev: dev_t
            let ino: ino_t
        }

        var seenDirs = Set<FileIdentity>()
        var presentDirs: [(name: String, url: URL)] = []
        var runtimeCount = 0
        var totalBytes: UInt64 = 0

        for candidateName in userRuntimeCandidateNames {
            let candidateURL = supportRoot
                .appendingPathComponent(candidateName, isDirectory: true)
                .standardizedFileURL
            var st = Darwin.stat()
            guard Darwin.lstat(candidateURL.path, &st) == 0,
                  (st.st_mode & S_IFMT) == S_IFDIR else {
                continue
            }
            let identity = FileIdentity(dev: st.st_dev, ino: st.st_ino)
            guard seenDirs.insert(identity).inserted else { continue }

            presentDirs.append((name: candidateName, url: candidateURL))
            let stats = measureDirectoryTree(at: candidateURL)
            totalBytes &+= stats.totalBytes

            if candidateName == "Runtimes" {
                let subDirs = sortedDirectoryChildren(of: candidateURL).filter {
                    isRealDirectory(atPath: $0.path)
                }
                if !subDirs.isEmpty {
                    runtimeCount += subDirs.count
                } else if stats.fileCount > 0 {
                    runtimeCount += 1
                }
            } else {
                runtimeCount += 1
            }
        }

        let displayPath = presentDirs.count == 1 ? presentDirs[0].url.path : supportPath
        let note: String
        if presentDirs.isEmpty {
            note = "No user-installed runtimes found."
        } else {
            let dirNames = presentDirs.map(\.name).joined(separator: ", ")
            let runtimeNoun = runtimeCount == 1 ? "runtime" : "runtimes"
            note = "\(runtimeCount) \(runtimeNoun) detected (\(dirNames))"
        }

        return StorageCategoryBreakdown(
            id: "user_runtimes",
            label: "User Runtimes",
            path: displayPath,
            itemCount: runtimeCount,
            totalBytes: totalBytes,
            reclaimableBytes: 0,
            note: note
        )
    }

    private static func analyzeMetadata(supportRoot: URL) -> StorageCategoryBreakdown {
        let supportPath = supportRoot.standardizedFileURL.path
        guard isRealDirectory(atPath: supportPath) else {
            return StorageCategoryBreakdown(
                id: "metadata",
                label: "App Metadata & Config",
                path: supportPath,
                itemCount: 0,
                totalBytes: 0,
                reclaimableBytes: 0,
                note: "No metadata files found."
            )
        }

        var fileNames: [String] = []
        var totalBytes: UInt64 = 0

        for child in sortedDirectoryChildren(of: supportRoot) {
            let name = child.lastPathComponent
            if name == ".DS_Store" {
                continue
            }
            var st = Darwin.stat()
            guard Darwin.lstat(child.path, &st) == 0 else { continue }
            guard (st.st_mode & S_IFMT) == S_IFREG else { continue }

            let sizeBytes: UInt64 = st.st_size > 0 ? UInt64(st.st_size) : 0
            fileNames.append(name)
            totalBytes &+= sizeBytes
        }

        let note: String
        if fileNames.isEmpty {
            note = "No metadata files found."
        } else {
            let fileNoun = fileNames.count == 1 ? "file" : "files"
            note = "\(fileNames.count) metadata \(fileNoun) (\(summarizeNames(fileNames)))"
        }

        return StorageCategoryBreakdown(
            id: "metadata",
            label: "App Metadata & Config",
            path: supportPath,
            itemCount: fileNames.count,
            totalBytes: totalBytes,
            reclaimableBytes: 0,
            note: note
        )
    }

    // MARK: - Symlink-Safe Filesystem Helpers

    private struct DirectorySizeStats {
        let fileCount: Int
        let totalBytes: UInt64
    }

    /// Returns `true` only when `path` exists and is a real directory (not a symlink).
    private static func isRealDirectory(atPath path: String) -> Bool {
        var st = Darwin.stat()
        guard Darwin.lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    private static func sortedDirectoryChildren(of directory: URL) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return []
        }
        return items.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Recursively measures regular files under `directory` using `Darwin.lstat`, never following
    /// symlinks and skipping FIFOs, sockets, and device nodes.
    private static func measureDirectoryTree(at directory: URL) -> DirectorySizeStats {
        let rootURL = directory.standardizedFileURL
        guard isRealDirectory(atPath: rootURL.path) else {
            return DirectorySizeStats(fileCount: 0, totalBytes: 0)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return DirectorySizeStats(fileCount: 0, totalBytes: 0)
        }

        var fileCount = 0
        var totalBytes: UInt64 = 0

        for case let entryURL as URL in enumerator {
            let entryPath = trimTrailingSlashes(entryURL.path)
            var st = Darwin.stat()
            guard Darwin.lstat(entryPath, &st) == 0 else {
                continue
            }

            let fileType = st.st_mode & S_IFMT
            if fileType == S_IFLNK || fileType == S_IFDIR {
                continue
            }
            guard fileType == S_IFREG else {
                continue
            }
            if entryURL.lastPathComponent == ".DS_Store" {
                continue
            }

            let sizeBytes: UInt64 = st.st_size > 0 ? UInt64(st.st_size) : 0
            fileCount += 1
            totalBytes &+= sizeBytes
        }

        return DirectorySizeStats(fileCount: fileCount, totalBytes: totalBytes)
    }

    private static func trimTrailingSlashes(_ path: String) -> String {
        var out = path
        while out.count > 1 && out.hasSuffix("/") {
            out.removeLast()
        }
        return out
    }

    // MARK: - Formatting & Timestamp Helpers

    private static func normalizeHome(_ home: String) -> String {
        if home.count > 1 && home.hasSuffix("/") {
            return trimTrailingSlashes(home)
        }
        return home
    }

    private static func summarizeNames(_ names: [String], maxShown: Int = 4) -> String {
        let sorted = names.sorted()
        guard sorted.count > maxShown else {
            return sorted.joined(separator: ", ")
        }
        let prefix = sorted.prefix(maxShown).joined(separator: ", ")
        return "\(prefix), +\(sorted.count - maxShown) more"
    }

    private static func pad(_ text: String, to width: Int) -> String {
        guard text.count < width else { return text }
        return text + String(repeating: " ", count: width - text.count)
    }

    private static func formatTableRow(
        _ columns: [String],
        widths: [Int],
        rightAligned: Set<Int>
    ) -> String {
        var parts: [String] = []
        parts.reserveCapacity(columns.count)
        for (index, value) in columns.enumerated() {
            let width = index < widths.count ? widths[index] : value.count
            let padding = max(0, width - value.count)
            if rightAligned.contains(index) {
                parts.append(String(repeating: " ", count: padding) + value)
            } else if index == columns.count - 1 {
                parts.append(value)
            } else {
                parts.append(value + String(repeating: " ", count: padding))
            }
        }
        return parts.joined(separator: "  ")
    }

    private static func currentUtcTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date())
    }
}
