import Darwin
import Foundation

// Privacy-safe diagnostics support bundle exporter for DirectMetal.
// Collects hardware capabilities, redacted library metadata, recent launch history,
// prefix stats, shader cache entries, and a GitHub-issue-ready SUMMARY.md into a
// deterministic, atomically written .tar.gz archive with zero user paths or secret values.

// MARK: - Models & Errors

struct RedactedGameSummary: Codable, Equatable {
    let id: String
    let title: String
    let architecture: String
    let detectedAPIs: [String]
    let detectedUpscalers: [String]
    let engine: ExecutionEngine
    let perfProfile: PerfProfile
    let dx9Backend: DX9Backend
    let upscaleMode: String
    let fpsCap: Int
    let retinaMode: Bool
    let enableHUD: Bool
    let enableSandbox: Bool
    let isFavorite: Bool
    let storeSource: String?
    let profileID: String?
    let playCount: Int
    let totalPlaySeconds: Double
    /// ONLY custom environment variable key names — never values (prevents leaking tokens/keys).
    let customEnvKeyNames: [String]
}

extension RedactedGameSummary {
    init(
        entry: GameLibraryEntry,
        home: String = NSHomeDirectory(),
        username: String = NSUserName()
    ) {
        let envKeys = GameLibraryManager.parseCustomEnv(entry.customEnv).keys.sorted()
        self.init(
            id: entry.id,
            title: SupportBundleExporter.redactPaths(in: entry.title, home: home, username: username),
            architecture: entry.architecture,
            detectedAPIs: entry.detectedAPIs,
            detectedUpscalers: entry.detectedUpscalers,
            engine: entry.engine,
            perfProfile: entry.perfProfile,
            dx9Backend: entry.dx9Backend,
            upscaleMode: entry.upscaleMode,
            fpsCap: entry.fpsCap,
            retinaMode: entry.retinaMode,
            enableHUD: entry.enableHUD,
            enableSandbox: entry.enableSandbox,
            isFavorite: entry.isFavorite,
            storeSource: entry.storeSource,
            profileID: entry.profileID,
            playCount: entry.playCount,
            totalPlaySeconds: entry.totalPlaySeconds,
            customEnvKeyNames: envKeys
        )
    }
}

struct SupportBundleExportResult: Codable, Equatable {
    let schema: String
    let archivePath: String
    let archiveBytes: UInt64
    let createdUtc: String
    let includedFiles: [String]
    let gameCount: Int
    let historyEntryCount: Int
    let prefixCount: Int
    let shaderCacheEntryCount: Int
}

enum SupportBundleError: Error, CustomStringConvertible, Equatable {
    case writeFailed(String)
    case archiveFailed(String)

    var description: String {
        switch self {
        case .writeFailed(let message), .archiveFailed(let message):
            return message
        }
    }
}

// MARK: - Exporter

enum SupportBundleExporter {
    static let schemaID = "directmetal.support_bundle.v1"
    static let maxHistoryEntries = 50

    private static let includedFileNames: [String] = [
        "SUMMARY.md",
        "hardware.json",
        "launch_history.json",
        "library_summary.json",
        "prefixes.json",
        "shader_caches.json",
    ]

    /// Redacts the user's home directory via `LaunchDiagnostics.redactHome` and replaces
    /// `/Users/<username>` path prefixes with `~` so macOS account names never leak.
    static func redactPaths(
        in text: String,
        home: String = NSHomeDirectory(),
        username: String = NSUserName()
    ) -> String {
        guard !text.isEmpty else { return text }

        let normalizedHome = normalizeHomePath(home)
        var redacted = LaunchDiagnostics.redactHome(text, home: normalizedHome)

        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty, !trimmedUser.contains("/") else {
            return redacted
        }

        let userHomePrefix = "/Users/\(trimmedUser)"
        redacted = replaceUserPathPrefix(userHomePrefix, with: "~", in: redacted)
        return redacted
    }

    /// Formats a clean, GitHub-issue-ready Markdown summary of version, Metal capabilities,
    /// library counts, and recent launches with all paths home-redacted.
    static func buildSummaryMarkdown(
        appVersion: String,
        hardware: MetalHardwareInfo,
        games: [RedactedGameSummary],
        history: [LaunchHistoryEntry],
        prefixCount: Int,
        shaderCacheCount: Int,
        home: String = NSHomeDirectory()
    ) -> String {
        let yn: (Bool) -> String = { $0 ? "Yes" : "No" }
        let versionLabel = appVersion.hasPrefix("v") ? appVersion : "v\(appVersion)"

        var lines: [String] = [
            "# DirectMetal Support Bundle Summary",
            "",
            "- **DirectMetal Version:** `\(escapeInlineCode(versionLabel))`",
            "- **Bundle Schema:** `\(schemaID)`",
            "",
            "## Hardware & Metal Capabilities",
            "",
            "| Capability | Value |",
            "| --- | --- |",
            "| GPU | \(escapeMarkdownCell(hardware.gpuName)) (`\(escapeInlineCode(hardware.gpuFamily))`) |",
            "| macOS | `\(escapeInlineCode(hardware.macosVersion))` (build `\(escapeInlineCode(hardware.macosBuild))`) |",
            "| Shader Cache Key | `\(escapeInlineCode(hardware.cacheKey))` |",
            String(format: "| Recommended Working Set | %.1f GiB |", hardware.workingSetGiB),
            "| Unified Memory | \(yn(hardware.hasUnifiedMemory)) |",
            "| Metal 3 | \(yn(hardware.supportsMetal3)) |",
            "| Metal 4 | \(yn(hardware.supportsMetal4)) |",
            "| Hardware Raytracing | \(yn(hardware.supportsRaytracing)) |",
            "| MetalFX Spatial | \(yn(hardware.supportsMetalFXSpatial)) |",
            "| MetalFX Temporal | \(yn(hardware.supportsMetalFXTemporal)) |",
            "| Metal 4 FX | \(yn(hardware.supportsMetal4FX)) |",
            "",
            "## Library & Storage Overview",
            "",
        ]

        let favoriteCount = games.reduce(0) { $0 + ($1.isFavorite ? 1 : 0) }
        let totalPlays = games.reduce(0) { $0 + $1.playCount }
        let totalPlaySeconds = games.reduce(0.0) { $0 + $1.totalPlaySeconds }
        let succeededLaunches = history.reduce(0) { $0 + ($1.succeeded ? 1 : 0) }
        let failedLaunches = history.count - succeededLaunches

        lines.append("- **Registered Games:** \(games.count) (\(favoriteCount) favorite\(favoriteCount == 1 ? "" : "s"))")
        lines.append("- **Total Library Launches / Playtime:** \(totalPlays) launch\(totalPlays == 1 ? "" : "es") · \(LaunchHistoryEntry.formatDuration(totalPlaySeconds))")
        lines.append("- **Managed Wine Prefixes:** \(prefixCount)")
        lines.append("- **Local Shader Cache Entries:** \(shaderCacheCount)")
        lines.append("- **Recent Launch History Included:** \(history.count) (\(succeededLaunches) succeeded, \(failedLaunches) failed)")

        if !games.isEmpty {
            lines.append("")
            lines.append("### Redacted Game Library")
            lines.append("")
            lines.append("| Game | Arch | APIs | Engine | Perf | MetalFX | FPS Cap | Plays | Custom Env Keys |")
            lines.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
            for game in games {
                let title = escapeMarkdownCell(redactPaths(in: game.title, home: home))
                let apis = game.detectedAPIs.isEmpty ? "—" : escapeMarkdownCell(game.detectedAPIs.joined(separator: ", "))
                let fpsText = game.fpsCap > 0 ? "\(game.fpsCap)" : "Uncapped"
                let envKeysText = game.customEnvKeyNames.isEmpty
                    ? "—"
                    : game.customEnvKeyNames.map { "`\(escapeInlineCode($0))`" }.joined(separator: ", ")
                let row = [
                    title,
                    "`\(escapeInlineCode(game.architecture))`",
                    apis,
                    "`\(escapeInlineCode(game.engine.rawValue))`",
                    "`\(escapeInlineCode(game.perfProfile.rawValue))`",
                    "`\(escapeInlineCode(game.upscaleMode))`",
                    fpsText,
                    "\(game.playCount)",
                    envKeysText,
                ].joined(separator: " | ")
                lines.append("| \(row) |")
            }
        }

        lines.append("")
        lines.append("## Recent Launch Summary")
        lines.append("")

        if history.isEmpty {
            lines.append("_No recent launches recorded._")
        } else {
            let launchWord = history.count == 1 ? "launch" : "launches"
            let historyDuration = history.reduce(0.0) { $0 + $1.elapsedSeconds }
            lines.append(
                "Showing \(history.count) recent \(launchWord) · \(succeededLaunches) succeeded, \(failedLaunches) failed · \(LaunchHistoryEntry.formatDuration(historyDuration)) total"
            )
            lines.append("")
            lines.append("| Time (UTC) | Game | Status | Duration | Engine | Prefix | Executable |")
            lines.append("| --- | --- | --- | --- | --- | --- | --- |")

            for entry in history {
                let statusText: String
                if entry.succeeded {
                    statusText = "Succeeded (exit 0)"
                } else if let failure = entry.failure?.trimmingCharacters(in: .whitespacesAndNewlines), !failure.isEmpty {
                    let redactedFailure = redactPaths(in: failure, home: home)
                    statusText = "Failed: \(redactedFailure)"
                } else if let code = entry.exitCode {
                    statusText = "Failed (exit \(code))"
                } else {
                    statusText = "Failed"
                }

                let redactedTitle = redactPaths(in: entry.title, home: home)
                let redactedPrefix = redactPaths(in: entry.prefixName, home: home)
                let redactedExe = redactPaths(in: entry.exePath, home: home)
                let row = [
                    "`\(escapeInlineCode(entry.timestampUtc))`",
                    escapeMarkdownCell(redactedTitle),
                    escapeMarkdownCell(statusText),
                    escapeMarkdownCell(entry.durationLabel),
                    "`\(escapeInlineCode(entry.activeEngine))`",
                    "`\(escapeInlineCode(redactedPrefix))`",
                    "`\(escapeInlineCode(redactedExe))`",
                ].joined(separator: " | ")
                lines.append("| \(row) |")
            }
        }

        lines.append("")
        lines.append("---")
        lines.append("_Privacy notice: Home directories and macOS account paths are redacted to `~`. Raw game paths, extra launch arguments, and custom environment variable values are omitted._")

        return lines.joined(separator: "\n") + "\n"
    }

    /// Exports a privacy-safe support bundle `.tar.gz` archive containing hardware capabilities,
    /// redacted game library summaries, recent launch history, prefix stats, shader cache entries,
    /// and a Markdown overview (`SUMMARY.md`). Writes atomically into `archivePath`.
    static func exportBundle(
        to archivePath: String,
        libraryManager: GameLibraryManager = GameLibraryManager(),
        prefixManager: PrefixManager = PrefixManager(),
        historyStore: LaunchHistoryStore = LaunchHistoryStore(),
        home: String = NSHomeDirectory()
    ) throws -> SupportBundleExportResult {
        let trimmedArchivePath = archivePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArchivePath.isEmpty else {
            throw SupportBundleError.writeFailed("Archive path must not be empty.")
        }

        let fm = FileManager.default
        let expandedArchivePath = (trimmedArchivePath as NSString).expandingTildeInPath
        let outURL = URL(fileURLWithPath: expandedArchivePath).standardizedFileURL

        var existingIsDir: ObjCBool = false
        if fm.fileExists(atPath: outURL.path, isDirectory: &existingIsDir), existingIsDir.boolValue {
            throw SupportBundleError.writeFailed("Output archive path is a directory: \(outURL.path)")
        }

        let hardware = RuntimeLauncher.queryHardwareInfo()
        let redactedGames = libraryManager.load().map { entry in
            RedactedGameSummary(entry: entry, home: home)
        }
        let redactedHistory = historyStore.load(limit: maxHistoryEntries).map { entry in
            redactHistoryEntry(entry, home: home)
        }
        let redactedPrefixes = prefixManager.prefixStats().map { stat in
            redactPrefixStat(stat, home: home)
        }
        let redactedCaches = ShaderCacheManager.listLocalCaches().map { cache in
            redactShaderCacheEntry(cache, home: home)
        }
        let summaryMarkdown = buildSummaryMarkdown(
            appVersion: RuntimeLauncher.appVersion(),
            hardware: hardware,
            games: redactedGames,
            history: redactedHistory,
            prefixCount: redactedPrefixes.count,
            shaderCacheCount: redactedCaches.count,
            home: home
        )

        let staging = fm.temporaryDirectory.appendingPathComponent(
            "dm_support_bundle_\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw SupportBundleError.writeFailed("Failed to create staging directory: \(error)")
        }
        defer { try? fm.removeItem(at: staging) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        try writeJSON(hardware, to: staging.appendingPathComponent("hardware.json"), encoder: encoder)
        try writeJSON(redactedGames, to: staging.appendingPathComponent("library_summary.json"), encoder: encoder)
        try writeJSON(redactedHistory, to: staging.appendingPathComponent("launch_history.json"), encoder: encoder)
        try writeJSON(redactedPrefixes, to: staging.appendingPathComponent("prefixes.json"), encoder: encoder)
        try writeJSON(redactedCaches, to: staging.appendingPathComponent("shader_caches.json"), encoder: encoder)
        try writeUTF8Text(summaryMarkdown, to: staging.appendingPathComponent("SUMMARY.md"))

        let outParent = outURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: outParent, withIntermediateDirectories: true)
        } catch {
            throw SupportBundleError.writeFailed(
                "Failed to create archive parent directory \(outParent.path): \(error)"
            )
        }

        let tmpArchiveURL = outParent.appendingPathComponent(
            ".\(outURL.lastPathComponent).tmp.\(UUID().uuidString)"
        )
        defer { try? fm.removeItem(at: tmpArchiveURL) }

        try runTar(["-czf", tmpArchiveURL.path, "-C", staging.path] + includedFileNames)

        if Darwin.rename(tmpArchiveURL.path, outURL.path) != 0 {
            let err = errno
            throw SupportBundleError.archiveFailed(
                "Failed to move archive into place at \(outURL.path): \(String(cString: strerror(err)))"
            )
        }

        let archiveBytes: UInt64
        do {
            let attrs = try fm.attributesOfItem(atPath: outURL.path)
            archiveBytes = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        } catch {
            throw SupportBundleError.archiveFailed("Failed to stat output archive \(outURL.path): \(error)")
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let createdUtc = iso.string(from: Date())

        return SupportBundleExportResult(
            schema: schemaID,
            archivePath: outURL.path,
            archiveBytes: archiveBytes,
            createdUtc: createdUtc,
            includedFiles: includedFileNames,
            gameCount: redactedGames.count,
            historyEntryCount: redactedHistory.count,
            prefixCount: redactedPrefixes.count,
            shaderCacheEntryCount: redactedCaches.count
        )
    }

    // MARK: - Private Redaction Helpers

    private static func normalizeHomePath(_ home: String) -> String {
        var trimmed = home.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.count > 1 && trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    private static func isUsernameContinuationScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        let isAlphaNum = (v >= 0x30 && v <= 0x39)
            || (v >= 0x41 && v <= 0x5A)
            || (v >= 0x61 && v <= 0x7A)
        return isAlphaNum || scalar == "_" || scalar == "-" || scalar == "."
    }

    /// Replaces `/Users/<username>` occurrences with `~` while respecting path boundaries so
    /// unrelated accounts with shared prefixes (e.g. `/Users/alice2`) are not corrupted.
    private static func replaceUserPathPrefix(
        _ target: String,
        with replacement: String,
        in text: String
    ) -> String {
        guard !target.isEmpty else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var searchStart = text.startIndex

        while searchStart < text.endIndex,
              let match = text.range(of: target, range: searchStart..<text.endIndex) {
            let hasValidLeadingBoundary: Bool
            if match.lowerBound == text.startIndex {
                hasValidLeadingBoundary = true
            } else {
                let prevIndex = text.index(before: match.lowerBound)
                if let prevScalar = text[prevIndex].unicodeScalars.last {
                    hasValidLeadingBoundary = !isUsernameContinuationScalar(prevScalar)
                } else {
                    hasValidLeadingBoundary = true
                }
            }

            let hasValidTrailingBoundary: Bool
            if match.upperBound == text.endIndex {
                hasValidTrailingBoundary = true
            } else if let nextScalar = text[match.upperBound].unicodeScalars.first {
                hasValidTrailingBoundary = !isUsernameContinuationScalar(nextScalar)
            } else {
                hasValidTrailingBoundary = true
            }

            if hasValidLeadingBoundary && hasValidTrailingBoundary {
                result.append(contentsOf: text[searchStart..<match.lowerBound])
                result.append(replacement)
            } else {
                result.append(contentsOf: text[searchStart..<match.upperBound])
            }
            searchStart = match.upperBound
        }

        if searchStart < text.endIndex {
            result.append(contentsOf: text[searchStart..<text.endIndex])
        }
        return result
    }

    private static func redactHistoryEntry(_ entry: LaunchHistoryEntry, home: String) -> LaunchHistoryEntry {
        LaunchHistoryEntry(
            id: entry.id,
            timestampUtc: entry.timestampUtc,
            gameID: entry.gameID,
            title: redactPaths(in: entry.title, home: home),
            exePath: redactPaths(in: entry.exePath, home: home),
            prefixName: redactPaths(in: entry.prefixName, home: home),
            requestedEngine: entry.requestedEngine,
            activeEngine: entry.activeEngine,
            exitCode: entry.exitCode,
            elapsedSeconds: entry.elapsedSeconds,
            sandboxed: entry.sandboxed,
            cowCloneMs: entry.cowCloneMs,
            fpsCap: entry.fpsCap,
            upscaleMode: entry.upscaleMode,
            failure: entry.failure.map { redactPaths(in: $0, home: home) }
        )
    }

    private static func redactPrefixStat(_ stat: PrefixManager.PrefixStat, home: String) -> PrefixManager.PrefixStat {
        PrefixManager.PrefixStat(
            name: redactPaths(in: stat.name, home: home),
            path: redactPaths(in: stat.path, home: home),
            sizeBytes: stat.sizeBytes,
            fileCount: stat.fileCount,
            createdUtc: stat.createdUtc,
            gameExe: stat.gameExe.map { redactPaths(in: $0, home: home) },
            dxApi: stat.dxApi,
            cowCloneMs: stat.cowCloneMs
        )
    }

    private static func redactShaderCacheEntry(_ entry: ShaderCacheLocalEntry, home: String) -> ShaderCacheLocalEntry {
        ShaderCacheLocalEntry(
            name: redactPaths(in: entry.name, home: home),
            path: redactPaths(in: entry.path, home: home),
            fileCount: entry.fileCount,
            totalBytes: entry.totalBytes,
            matchesHostCacheKey: entry.matchesHostCacheKey,
            isKnownKeyedEntry: entry.isKnownKeyedEntry
        )
    }

    // MARK: - Private I/O & Markdown Helpers

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder) throws {
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw SupportBundleError.writeFailed("Failed to encode \(url.lastPathComponent): \(error)")
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw SupportBundleError.writeFailed("Failed to write \(url.lastPathComponent): \(error)")
        }
    }

    private static func writeUTF8Text(_ text: String, to url: URL) throws {
        let data = Data(text.utf8)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw SupportBundleError.writeFailed("Failed to write \(url.lastPathComponent): \(error)")
        }
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
            throw SupportBundleError.archiveFailed("Failed to launch /usr/bin/tar: \(error)")
        }

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            let errText = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = errText.isEmpty ? "tar exited with status \(proc.terminationStatus)" : errText
            throw SupportBundleError.archiveFailed(detail)
        }
    }

    private static func escapeMarkdownCell(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "|", with: "\\|")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func escapeInlineCode(_ text: String) -> String {
        escapeMarkdownCell(text).replacingOccurrences(of: "`", with: "'")
    }
}
