import Foundation

// Privacy-safe Game Library & Playtime Report Exporter (CSV & GitHub-Flavored Markdown).
// Builds a deterministic, path-redacted snapshot of the user's game library joined with
// stability metrics from `GameSessionAnalytics`, without ever emitting raw `exePath`,
// `customEnv`, or `$HOME` user paths.

// MARK: - Options & Errors

enum LibraryReportFormat: String, Codable, CaseIterable, Hashable, Sendable {
    case markdown
    case csv

    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .csv: return "csv"
        }
    }

    var displayLabel: String {
        switch self {
        case .markdown: return "Markdown"
        case .csv: return "CSV"
        }
    }
}

enum LibraryReportSort: String, Codable, CaseIterable, Hashable, Sendable {
    case mostPlayed
    case title
    case recent
    case favoritesFirst

    var displayLabel: String {
        switch self {
        case .mostPlayed: return "Most Played"
        case .title: return "Title (A-Z)"
        case .recent: return "Recently Played"
        case .favoritesFirst: return "Favorites First"
        }
    }
}

enum LibraryReportError: Error, CustomStringConvertible, Equatable, Sendable {
    case invalidOutputPath(String)

    var description: String {
        switch self {
        case .invalidOutputPath(let message):
            return message
        }
    }
}

// MARK: - Report Models

struct LibraryReportRow: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let favorite: Bool
    let storeSource: String
    let architecture: String
    let detectedAPIs: [String]
    let engine: String
    let perfProfile: String
    let upscaleMode: String
    let fpsCap: Int
    let sandboxed: Bool
    let profileID: String?
    let playCount: Int
    let totalPlaySeconds: Double
    let playtimeFormatted: String
    let stabilityTier: String
    let successRatePercent: Double?
    let lastPlayedUtc: String?
}

struct LibraryReport: Codable, Equatable, Sendable {
    let generatedAtUtc: String
    let appVersion: String
    let totalGames: Int
    let favoriteCount: Int
    let profiledCount: Int
    let totalPlaySeconds: Double
    let totalLaunches: Int
    let rows: [LibraryReportRow]
}

// MARK: - Exporter

enum LibraryReportExporter {

    private static let csvHeaders: [String] = [
        "id",
        "title",
        "favorite",
        "store_source",
        "architecture",
        "detected_apis",
        "engine",
        "perf_profile",
        "upscale_mode",
        "fps_cap",
        "sandboxed",
        "profile_id",
        "play_count",
        "total_play_seconds",
        "playtime",
        "stability_tier",
        "success_rate_percent",
        "last_played_utc",
    ]

    /// Builds a privacy-safe `LibraryReport` from saved library entries and optional launch history.
    /// Raw `exePath`, `customEnv`, and `$HOME` / `/Users/<username>` paths are never exported.
    static func buildReport(
        library: [GameLibraryEntry],
        history: [LaunchHistoryEntry] = [],
        sort: LibraryReportSort = .mostPlayed
    ) -> LibraryReport {
        let redaction = RedactionContext.current()
        let analyticsLookup = AnalyticsLookup(history: history, home: redaction.primaryHome)

        var rows: [LibraryReportRow] = []
        rows.reserveCapacity(library.count)

        var favoriteCount = 0
        var profiledCount = 0
        var totalPlaySeconds = 0.0
        var totalLaunches = 0

        for entry in library {
            let cleanTitle = sanitizeTitle(entry.title, redaction: redaction)
            let storeSource = sanitizeStoreSource(entry.storeSource, redaction: redaction)
            let architecture = sanitizeToken(entry.architecture, fallback: "unknown", redaction: redaction)
            let detectedAPIs = entry.detectedAPIs.compactMap { raw -> String? in
                let cleaned = redaction.redact(raw.trimmingCharacters(in: .whitespacesAndNewlines))
                return cleaned.isEmpty ? nil : cleaned
            }
            let upscaleMode = normalizeUpscaleMode(entry.upscaleMode, redaction: redaction)
            let fpsCap = max(0, min(entry.fpsCap, 360))
            let profileID: String? = {
                guard let raw = entry.profileID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty
                else { return nil }
                let redacted = redaction.redact(raw)
                return redacted.isEmpty ? nil : redacted
            }()

            let playCount = max(0, entry.playCount)
            let playSeconds = sanitizedDuration(entry.totalPlaySeconds)
            let lastPlayedUtc: String? = {
                guard let raw = entry.lastPlayedUtc?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty
                else { return nil }
                return redaction.redact(raw)
            }()

            let matchedStats = analyticsLookup.match(for: entry)
            let stabilityTier = matchedStats?.stabilityTier.displayLabel ?? GameStabilityTier.untested.displayLabel
            let successRatePercent = matchedStats?.successRatePercent

            if entry.isFavorite { favoriteCount += 1 }
            if profileID != nil { profiledCount += 1 }
            totalPlaySeconds += playSeconds
            totalLaunches += playCount

            rows.append(
                LibraryReportRow(
                    id: redaction.redact(entry.id),
                    title: cleanTitle,
                    favorite: entry.isFavorite,
                    storeSource: storeSource,
                    architecture: architecture,
                    detectedAPIs: detectedAPIs,
                    engine: entry.engine.rawValue,
                    perfProfile: entry.perfProfile.rawValue,
                    upscaleMode: upscaleMode,
                    fpsCap: fpsCap,
                    sandboxed: entry.enableSandbox,
                    profileID: profileID,
                    playCount: playCount,
                    totalPlaySeconds: playSeconds,
                    playtimeFormatted: LaunchHistoryEntry.formatDuration(playSeconds),
                    stabilityTier: stabilityTier,
                    successRatePercent: successRatePercent,
                    lastPlayedUtc: lastPlayedUtc
                )
            )
        }

        let sortedRows = sortRows(rows, by: sort)

        return LibraryReport(
            generatedAtUtc: makeISO8601Formatter().string(from: Date()),
            appVersion: RuntimeLauncher.appVersion(),
            totalGames: sortedRows.count,
            favoriteCount: favoriteCount,
            profiledCount: profiledCount,
            totalPlaySeconds: totalPlaySeconds,
            totalLaunches: totalLaunches,
            rows: sortedRows
        )
    }

    // MARK: CSV Formatter (RFC 4180 + Spreadsheet Formula Injection Guard)

    /// Formats the report as strict RFC 4180 CSV with spreadsheet formula-injection protection
    /// on untrusted text fields.
    static func formatCSV(_ report: LibraryReport) -> String {
        let redaction = RedactionContext.current()
        var lines: [String] = [csvHeaders.map { escapeCSVField($0, guardFormula: false) }.joined(separator: ",")]
        lines.reserveCapacity(report.rows.count + 1)

        for row in report.rows {
            let safeSeconds = sanitizedDuration(row.totalPlaySeconds)
            let successRateStr: String
            if let rate = row.successRatePercent, rate.isFinite {
                let clamped = min(100.0, max(0.0, rate))
                successRateStr = String(format: "%.1f", clamped)
            } else {
                successRateStr = ""
            }

            let fields: [String] = [
                escapeCSVField(redaction.redact(row.id), guardFormula: true),
                escapeCSVField(redaction.redact(row.title), guardFormula: true),
                row.favorite ? "true" : "false",
                escapeCSVField(redaction.redact(row.storeSource), guardFormula: true),
                escapeCSVField(redaction.redact(row.architecture), guardFormula: true),
                escapeCSVField(redaction.redact(row.detectedAPIs.joined(separator: ";")), guardFormula: true),
                escapeCSVField(redaction.redact(row.engine), guardFormula: true),
                escapeCSVField(redaction.redact(row.perfProfile), guardFormula: true),
                escapeCSVField(redaction.redact(row.upscaleMode), guardFormula: true),
                "\(max(0, row.fpsCap))",
                row.sandboxed ? "true" : "false",
                escapeCSVField(row.profileID.map(redaction.redact) ?? "", guardFormula: true),
                "\(max(0, row.playCount))",
                String(format: "%.1f", safeSeconds),
                escapeCSVField(row.playtimeFormatted, guardFormula: false),
                escapeCSVField(redaction.redact(row.stabilityTier), guardFormula: true),
                successRateStr,
                escapeCSVField(row.lastPlayedUtc.map(redaction.redact) ?? "", guardFormula: true),
            ]
            lines.append(fields.joined(separator: ","))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: GitHub-Flavored Markdown Formatter

    /// Formats the report as GitHub-Flavored Markdown with a KPI summary table and a properly
    /// escaped per-game library table.
    static func formatMarkdown(_ report: LibraryReport) -> String {
        let redaction = RedactionContext.current()
        func cell(_ raw: String) -> String {
            escapeMarkdownCell(redaction.redact(raw))
        }
        func codeCell(_ raw: String) -> String {
            let escaped = escapeMarkdownCell(redaction.redact(raw)).replacingOccurrences(of: "`", with: "'")
            return escaped.isEmpty ? "—" : "`\(escaped)`"
        }

        let safeTotalSeconds = sanitizedDuration(report.totalPlaySeconds)
        var lines: [String] = [
            "# DirectMetal Game Library & Playtime Report",
            "",
            "Generated `\(escapeMarkdownCell(report.generatedAtUtc))` · DirectMetal v\(escapeMarkdownCell(report.appVersion))",
            "",
            "| Metric | Value |",
            "| :--- | :--- |",
            "| **Total Games** | \(report.totalGames) |",
            "| **Favorites** | \(report.favoriteCount) |",
            "| **Community Profiled** | \(report.profiledCount) |",
            "| **Total Launches** | \(report.totalLaunches) |",
            "| **Total Playtime** | \(LaunchHistoryEntry.formatDuration(safeTotalSeconds)) |",
        ]

        guard !report.rows.isEmpty else {
            lines.append("")
            lines.append("_No games in library._")
            return lines.joined(separator: "\n") + "\n"
        }

        lines.append("")
        lines.append("## Library")
        lines.append("")
        lines.append("| Game | Store | Arch | APIs | Engine | Profile | Settings | Launches | Playtime | Stability | Last Played (UTC) |")
        lines.append("| :--- | :--- | :--- | :--- | :--- | :--- | :--- | ---: | ---: | :--- | :--- |")

        for row in report.rows {
            let titleText = row.favorite ? "★ \(cell(row.title))" : cell(row.title)
            let storeText = cell(formatStoreDisplay(row.storeSource))
            let archText = codeCell(row.architecture)
            let apisText = row.detectedAPIs.isEmpty ? "—" : cell(row.detectedAPIs.joined(separator: ", "))
            let engineText = codeCell(row.engine)
            let profileText = row.profileID.map(codeCell) ?? "—"
            let settingsText = cell(formatSettingsSummary(row))
            let launchesText = "\(max(0, row.playCount))"
            let playtimeText = cell(row.playtimeFormatted)
            let stabilityText: String = {
                let tier = cell(row.stabilityTier)
                if let rate = row.successRatePercent, rate.isFinite {
                    return "\(tier) (\(formatPercent(rate)))"
                }
                return tier
            }()
            let lastPlayedText = row.lastPlayedUtc.map(codeCell) ?? "—"

            let columns = [
                titleText,
                storeText,
                archText,
                apisText,
                engineText,
                profileText,
                settingsText,
                launchesText,
                playtimeText,
                stabilityText,
                lastPlayedText,
            ].joined(separator: " | ")
            lines.append("| \(columns) |")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Atomic File Writer

    /// Atomically writes a UTF-8 CSV or Markdown report to `outputPath`, creating parent
    /// directories as needed, and returns the resolved destination file URL.
    @discardableResult
    static func writeReport(
        _ report: LibraryReport,
        format: LibraryReportFormat,
        to outputPath: String
    ) throws -> URL {
        let trimmed = outputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LibraryReportError.invalidOutputPath("Output path must not be empty.")
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let destinationURL = URL(fileURLWithPath: expanded).standardizedFileURL

        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw LibraryReportError.invalidOutputPath(
                "Output path points to an existing directory: \(destinationURL.path)"
            )
        }

        let content: String
        switch format {
        case .markdown:
            content = formatMarkdown(report)
        case .csv:
            content = formatCSV(report)
        }

        let parentDir = destinationURL.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: destinationURL, options: .atomic)
        return destinationURL
    }

    // MARK: Private Helpers

    private struct RedactionContext {
        let homeCandidates: [String]
        let username: String
        let primaryHome: String

        static func current() -> RedactionContext {
            let envHome = ProcessInfo.processInfo.environment["HOME"] ?? ""
            let nsHome = NSHomeDirectory()
            let username = NSUserName().trimmingCharacters(in: .whitespacesAndNewlines)

            var rawCandidates: [String] = []
            for candidate in [envHome, nsHome] {
                let normalized = normalizeHomePath(candidate)
                if !normalized.isEmpty, normalized != "/", !rawCandidates.contains(normalized) {
                    rawCandidates.append(normalized)
                }
            }
            // Longer prefixes first so a nested custom $HOME is redacted before a shorter prefix.
            rawCandidates.sort { $0.count > $1.count }

            let primaryHome = rawCandidates.first ?? nsHome
            return RedactionContext(
                homeCandidates: rawCandidates,
                username: username,
                primaryHome: primaryHome
            )
        }

        func redact(_ text: String) -> String {
            guard !text.isEmpty else { return text }
            var result = text
            for home in homeCandidates {
                result = LaunchDiagnostics.redactHome(result, home: home)
            }
            if !username.isEmpty, !username.contains("/") {
                let userPrefix = "/Users/\(username)"
                if result.contains(userPrefix) {
                    result = result.replacingOccurrences(of: userPrefix, with: "~")
                }
            }
            return result
        }

        private static func normalizeHomePath(_ raw: String) -> String {
            var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            while trimmed.count > 1 && trimmed.hasSuffix("/") {
                trimmed.removeLast()
            }
            return trimmed
        }
    }

    private struct AnalyticsLookup {
        let byGameID: [String: GameLaunchStats]
        let byKey: [String: GameLaunchStats]
        let byTitle: [String: GameLaunchStats]

        init(history: [LaunchHistoryEntry], home: String) {
            guard !history.isEmpty else {
                self.byGameID = [:]
                self.byKey = [:]
                self.byTitle = [:]
                return
            }

            let summary = GameSessionAnalytics.summarize(entries: history, home: home)
            var gameIDMap: [String: GameLaunchStats] = [:]
            var keyMap: [String: GameLaunchStats] = [:]
            var titleMap: [String: GameLaunchStats] = [:]
            gameIDMap.reserveCapacity(summary.topGames.count)
            keyMap.reserveCapacity(summary.topGames.count)
            titleMap.reserveCapacity(summary.topGames.count)

            for stats in summary.topGames {
                if let gid = stats.gameID?.trimmingCharacters(in: .whitespacesAndNewlines), !gid.isEmpty {
                    if gameIDMap[gid] == nil {
                        gameIDMap[gid] = stats
                    }
                }
                if keyMap[stats.id] == nil {
                    keyMap[stats.id] = stats
                }
                let lowerTitle = stats.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !lowerTitle.isEmpty, titleMap[lowerTitle] == nil {
                    titleMap[lowerTitle] = stats
                }
            }

            self.byGameID = gameIDMap
            self.byKey = keyMap
            self.byTitle = titleMap
        }

        func match(for entry: GameLibraryEntry) -> GameLaunchStats? {
            if let stats = byGameID[entry.id] ?? byKey[entry.id] {
                return stats
            }
            let rawNormalized = normalizeExePath(entry.exePath)
            if !rawNormalized.isEmpty, let stats = byKey[rawNormalized] {
                return stats
            }
            let canonicalNormalized = normalizeExePath(GameLibraryManager.canonicalPath(entry.exePath))
            if !canonicalNormalized.isEmpty, let stats = byKey[canonicalNormalized] {
                return stats
            }
            let lowerTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !lowerTitle.isEmpty, let stats = byTitle[lowerTitle] {
                return stats
            }
            return nil
        }

        private func normalizeExePath(_ raw: String) -> String {
            var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "" }
            while trimmed.contains("//") {
                trimmed = trimmed.replacingOccurrences(of: "//", with: "/")
            }
            while trimmed.count > 1 && trimmed.hasSuffix("/") {
                trimmed.removeLast()
            }
            return trimmed.lowercased()
        }
    }

    private static func sortRows(_ rows: [LibraryReportRow], by sort: LibraryReportSort) -> [LibraryReportRow] {
        switch sort {
        case .mostPlayed:
            return rows.sorted(by: compareMostPlayed)
        case .title:
            return rows.sorted(by: compareTitleAscending)
        case .recent:
            let baseFormatter = makeISO8601Formatter()
            let fractionalFormatter = makeISO8601Formatter(withFractionalSeconds: true)
            var timestampsByUTC: [String: Date] = [:]
            timestampsByUTC.reserveCapacity(rows.count)
            for row in rows {
                guard let utc = row.lastPlayedUtc, timestampsByUTC[utc] == nil else { continue }
                if let date = parseISO8601Date(utc, base: baseFormatter, fractional: fractionalFormatter) {
                    timestampsByUTC[utc] = date
                }
            }
            return rows.sorted { lhs, rhs in
                let lhsHasUTC = lhs.lastPlayedUtc != nil
                let rhsHasUTC = rhs.lastPlayedUtc != nil
                if lhsHasUTC != rhsHasUTC {
                    return lhsHasUTC && !rhsHasUTC
                }
                if let lStr = lhs.lastPlayedUtc, let rStr = rhs.lastPlayedUtc {
                    if let lDate = timestampsByUTC[lStr], let rDate = timestampsByUTC[rStr], lDate != rDate {
                        return lDate > rDate
                    }
                    if lStr != rStr {
                        return lStr > rStr
                    }
                }
                return compareMostPlayed(lhs, rhs)
            }
        case .favoritesFirst:
            return rows.sorted { lhs, rhs in
                if lhs.favorite != rhs.favorite {
                    return lhs.favorite && !rhs.favorite
                }
                return compareMostPlayed(lhs, rhs)
            }
        }
    }

    private static func compareMostPlayed(_ lhs: LibraryReportRow, _ rhs: LibraryReportRow) -> Bool {
        if lhs.totalPlaySeconds != rhs.totalPlaySeconds {
            return lhs.totalPlaySeconds > rhs.totalPlaySeconds
        }
        if lhs.playCount != rhs.playCount {
            return lhs.playCount > rhs.playCount
        }
        return compareTitleAscending(lhs, rhs)
    }

    private static func compareTitleAscending(_ lhs: LibraryReportRow, _ rhs: LibraryReportRow) -> Bool {
        let cmp = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if cmp != .orderedSame {
            return cmp == .orderedAscending
        }
        if lhs.title != rhs.title {
            return lhs.title < rhs.title
        }
        return lhs.id < rhs.id
    }

    private static func makeISO8601Formatter(withFractionalSeconds: Bool = false) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = withFractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }

    private static func parseISO8601Date(
        _ value: String,
        base: ISO8601DateFormatter,
        fractional: ISO8601DateFormatter
    ) -> Date? {
        base.date(from: value) ?? fractional.date(from: value)
    }

    private static func sanitizedDuration(_ value: Double) -> Double {
        (value.isFinite && value > 0) ? value : 0.0
    }

    private static func sanitizeTitle(_ raw: String, redaction: RedactionContext) -> String {
        let cleaned = redaction.redact(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        return cleaned.isEmpty ? "Untitled Game" : cleaned
    }

    private static func sanitizeStoreSource(_ raw: String?, redaction: RedactionContext) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !trimmed.isEmpty else { return "standalone" }
        let redacted = redaction.redact(trimmed)
        return redacted.isEmpty ? "standalone" : redacted
    }

    private static func sanitizeToken(_ raw: String, fallback: String, redaction: RedactionContext) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let redacted = redaction.redact(trimmed)
        return redacted.isEmpty ? fallback : redacted
    }

    private static func normalizeUpscaleMode(_ raw: String, redaction: RedactionContext) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "off" }
        let redacted = redaction.redact(trimmed)
        return redacted.isEmpty ? "off" : redacted
    }

    private static func escapeCSVField(_ raw: String, guardFormula: Bool) -> String {
        let safe = guardFormula ? guardFormulaInjection(raw) : raw
        let needsQuoting = safe.contains(",") || safe.contains("\"") || safe.contains("\n") || safe.contains("\r")
        guard needsQuoting else { return safe }
        let doubled = safe.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(doubled)\""
    }

    /// Defends against CSV formula injection (CWE-1236) in Excel / LibreOffice / Google Sheets
    /// by prefixing untrusted values starting with `=`, `+`, `-`, `@` (or leading whitespace/tab
    /// before them) with a leading single quote `'`.
    private static func guardFormulaInjection(_ value: String) -> String {
        guard let first = value.first else { return value }
        if first == "=" || first == "+" || first == "-" || first == "@" || first == "\t" || first == "\r" {
            return "'" + value
        }
        if let firstNonSpace = value.first(where: { $0 != " " }),
           firstNonSpace == "=" || firstNonSpace == "+" || firstNonSpace == "-" || firstNonSpace == "@" {
            return "'" + value
        }
        return value
    }

    private static func escapeMarkdownCell(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "|", with: "\\|")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func formatPercent(_ value: Double) -> String {
        let safe = value.isFinite ? min(100.0, max(0.0, value)) : 0.0
        return String(format: "%.1f%%", safe)
    }

    private static func formatStoreDisplay(_ store: String) -> String {
        switch store.lowercased() {
        case "steam": return "Steam"
        case "gog": return "GOG"
        case "epic": return "Epic"
        case "standalone": return "Standalone"
        default: return store
        }
    }

    private static func formatSettingsSummary(_ row: LibraryReportRow) -> String {
        var parts: [String] = [row.perfProfile]
        let upscale = row.upscaleMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !upscale.isEmpty && upscale != "off" {
            parts.append("MetalFX \(upscale)")
        }
        if row.fpsCap > 0 {
            parts.append("\(row.fpsCap) FPS")
        }
        if row.sandboxed {
            parts.append("Seatbelt")
        }
        return parts.joined(separator: ", ")
    }
}
