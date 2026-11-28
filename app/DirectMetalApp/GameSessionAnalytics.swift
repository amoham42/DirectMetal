import Foundation

// Per-game launch stability and performance telemetry aggregator.
// Consumes `LaunchHistoryEntry` records from `LaunchHistoryStore`, computes per-game and
// library-wide stability tiers, session durations, APFS CoW clone medians, and engine
// breakdowns, and renders deterministic CLI text and home-redacted Markdown reports.

// MARK: - Data models

enum GameStabilityTier: String, Codable, CaseIterable, Hashable, Sendable {
    case rockSolid
    case mostlyStable
    case needsAttention
    case untested

    var displayLabel: String {
        switch self {
        case .rockSolid: return "Rock Solid"
        case .mostlyStable: return "Mostly Stable"
        case .needsAttention: return "Needs Attention"
        case .untested: return "Untested"
        }
    }

    static func classify(totalLaunches: Int, successCount: Int, failureCount: Int) -> GameStabilityTier {
        guard totalLaunches > 0 else { return .untested }
        let clampedSuccess = max(0, min(successCount, totalLaunches))
        let clampedFailure = max(0, failureCount)

        if totalLaunches == 1 {
            return clampedSuccess == 1 ? .rockSolid : .needsAttention
        }
        if clampedSuccess * 100 >= totalLaunches * 95 {
            return .rockSolid
        }
        if clampedSuccess * 100 >= totalLaunches * 70 {
            return .mostlyStable
        }
        if clampedFailure >= 1 {
            return .needsAttention
        }
        return .untested
    }
}

struct GameLaunchStats: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let gameID: String?
    let title: String
    let totalLaunches: Int
    let successCount: Int
    let failureCount: Int
    let successRatePercent: Double
    let totalSessionSeconds: Double
    let averageSessionSeconds: Double
    let medianCowCloneMs: Double?
    let arm64ecLaunches: Int
    let rosettaLaunches: Int
    let lastEngine: String
    let lastLaunchUtc: String
    let lastFailure: String?
    let stabilityTier: GameStabilityTier
}

struct LibraryAnalyticsSummary: Codable, Equatable, Sendable {
    let totalLaunches: Int
    let uniqueGames: Int
    let successCount: Int
    let failureCount: Int
    let overallSuccessRatePercent: Double
    let totalTrackedSeconds: Double
    let medianCowCloneMs: Double?
    let arm64ecLaunches: Int
    let rosettaLaunches: Int
    let sandboxedLaunches: Int
    let topGames: [GameLaunchStats]
    let gamesNeedingAttention: [GameLaunchStats]
}

// MARK: - Aggregation & reporting engine

enum GameSessionAnalytics {

    /// Aggregates per-game stability and performance telemetry from launch history entries.
    static func summarize(
        entries: [LaunchHistoryEntry],
        home: String = NSHomeDirectory()
    ) -> LibraryAnalyticsSummary {
        guard !entries.isEmpty else {
            return LibraryAnalyticsSummary(
                totalLaunches: 0,
                uniqueGames: 0,
                successCount: 0,
                failureCount: 0,
                overallSuccessRatePercent: 0.0,
                totalTrackedSeconds: 0.0,
                medianCowCloneMs: nil,
                arm64ecLaunches: 0,
                rosettaLaunches: 0,
                sandboxedLaunches: 0,
                topGames: [],
                gamesNeedingAttention: []
            )
        }

        var grouped: [String: [LaunchHistoryEntry]] = [:]
        grouped.reserveCapacity(entries.count)

        var totalSuccess = 0
        var totalFailure = 0
        var totalTrackedSeconds = 0.0
        var allCowValues: [Double] = []
        var totalArm64ec = 0
        var totalRosetta = 0
        var totalSandboxed = 0

        for entry in entries {
            let key = groupKey(for: entry)
            grouped[key, default: []].append(entry)

            if entry.succeeded {
                totalSuccess += 1
            } else {
                totalFailure += 1
            }

            totalTrackedSeconds += sanitizedDuration(entry.elapsedSeconds)

            if let cowMs = sanitizedPositiveFinite(entry.cowCloneMs) {
                allCowValues.append(cowMs)
            }

            let engineClass = classifyEngine(entry.activeEngine)
            switch engineClass {
            case .arm64ec:
                totalArm64ec += 1
            case .rosetta:
                totalRosetta += 1
            case .other:
                break
            }

            if entry.sandboxed {
                totalSandboxed += 1
            }
        }

        var perGameStats: [GameLaunchStats] = []
        perGameStats.reserveCapacity(grouped.count)

        for (key, groupEntries) in grouped {
            let stats = buildGameStats(key: key, entries: groupEntries, home: home)
            perGameStats.append(stats)
        }

        let topGames = perGameStats.sorted { lhs, rhs in
            if lhs.totalLaunches != rhs.totalLaunches {
                return lhs.totalLaunches > rhs.totalLaunches
            }
            if lhs.totalSessionSeconds != rhs.totalSessionSeconds {
                return lhs.totalSessionSeconds > rhs.totalSessionSeconds
            }
            return compareTitlesAscending(lhs, rhs)
        }

        let gamesNeedingAttention = perGameStats
            .filter { $0.failureCount > 0 }
            .sorted { lhs, rhs in
                if lhs.failureCount != rhs.failureCount {
                    return lhs.failureCount > rhs.failureCount
                }
                if lhs.successRatePercent != rhs.successRatePercent {
                    return lhs.successRatePercent < rhs.successRatePercent
                }
                return compareTitlesAscending(lhs, rhs)
            }

        let totalLaunches = entries.count
        let overallSuccessRate = computeSuccessRatePercent(successCount: totalSuccess, totalLaunches: totalLaunches)

        return LibraryAnalyticsSummary(
            totalLaunches: totalLaunches,
            uniqueGames: perGameStats.count,
            successCount: totalSuccess,
            failureCount: totalFailure,
            overallSuccessRatePercent: overallSuccessRate,
            totalTrackedSeconds: totalTrackedSeconds,
            medianCowCloneMs: computeMedian(allCowValues),
            arm64ecLaunches: totalArm64ec,
            rosettaLaunches: totalRosetta,
            sandboxedLaunches: totalSandboxed,
            topGames: topGames,
            gamesNeedingAttention: gamesNeedingAttention
        )
    }

    // MARK: Text formatter (CLI)

    static func formatText(
        _ summary: LibraryAnalyticsSummary,
        home: String = NSHomeDirectory()
    ) -> String {
        let redact: (String) -> String = { LaunchDiagnostics.redactHome($0, home: home) }

        var lines: [String] = ["DirectMetal Game Session Analytics"]
        guard summary.totalLaunches > 0 else {
            lines.append("")
            lines.append("No launches recorded yet.")
            return lines.joined(separator: "\n") + "\n"
        }

        let otherEngines = max(0, summary.totalLaunches - summary.arm64ecLaunches - summary.rosettaLaunches)
        var engineParts: [String] = [
            "ARM64EC \(summary.arm64ecLaunches)",
            "Rosetta 2 \(summary.rosettaLaunches)",
        ]
        if otherEngines > 0 {
            engineParts.append("Other \(otherEngines)")
        }

        let overviewRows: [(String, String)] = [
            (
                "Launches",
                "\(summary.totalLaunches) total (\(summary.successCount) succeeded, \(summary.failureCount) failed, \(formatPercent(summary.overallSuccessRatePercent)))"
            ),
            ("Unique Games", "\(summary.uniqueGames)"),
            ("Tracked Playtime", LaunchHistoryEntry.formatDuration(summary.totalTrackedSeconds)),
            ("Median CoW Clone", formatCowMs(summary.medianCowCloneMs)),
            ("Engines", engineParts.joined(separator: ", ")),
            ("Sandboxed", "\(summary.sandboxedLaunches) of \(summary.totalLaunches)"),
        ]

        let labelWidth = max((overviewRows.map { $0.0.count }.max() ?? 0) + 2, 18)
        lines.append("")
        lines.append("[Overview]")
        for (label, value) in overviewRows {
            lines.append("  \(pad(label + ":", to: labelWidth))\(value)")
        }

        if !summary.topGames.isEmpty {
            lines.append("")
            lines.append("[Per-Game Stability & Telemetry]")

            let headers = ["GAME", "TIER", "LAUNCHES", "SUCCESS", "PLAYTIME", "MEDIAN COW", "LAST ENGINE"]
            let rows: [[String]] = summary.topGames.map { stats in
                [
                    redact(stats.title),
                    stats.stabilityTier.displayLabel,
                    "\(stats.totalLaunches)",
                    "\(stats.successCount)/\(stats.totalLaunches) (\(formatPercent(stats.successRatePercent)))",
                    LaunchHistoryEntry.formatDuration(stats.totalSessionSeconds),
                    formatCowMs(stats.medianCowCloneMs),
                    redact(stats.lastEngine.isEmpty ? "—" : stats.lastEngine),
                ]
            }

            var widths = headers.map(\.count)
            for row in rows {
                for (index, value) in row.enumerated() where index < widths.count {
                    widths[index] = max(widths[index], value.count)
                }
            }

            lines.append("  " + formatTableRow(headers, widths: widths))
            lines.append("  " + widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
            for row in rows {
                lines.append("  " + formatTableRow(row, widths: widths))
            }
        }

        if !summary.gamesNeedingAttention.isEmpty {
            lines.append("")
            lines.append("[Games Needing Attention (\(summary.gamesNeedingAttention.count))]")
            for stats in summary.gamesNeedingAttention {
                let title = redact(stats.title)
                let failureNoun = stats.failureCount == 1 ? "failure" : "failures"
                var detail = "  ! \(title) — \(stats.failureCount) \(failureNoun), \(formatPercent(stats.successRatePercent)) success [\(stats.stabilityTier.displayLabel)]"
                if let failure = stats.lastFailure, !failure.isEmpty {
                    detail += " | Last failure: \(sanitizeSingleLine(redact(failure)))"
                }
                lines.append(detail)
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Markdown formatter

    static func formatMarkdown(
        _ summary: LibraryAnalyticsSummary,
        home: String = NSHomeDirectory()
    ) -> String {
        let redact: (String) -> String = { LaunchDiagnostics.redactHome($0, home: home) }
        func cell(_ raw: String) -> String {
            escapeMarkdownCell(redact(raw))
        }

        var lines: [String] = ["# DirectMetal Game Session Analytics", ""]
        guard summary.totalLaunches > 0 else {
            lines.append("_No launches recorded yet._")
            return lines.joined(separator: "\n") + "\n"
        }

        let launchWord = summary.totalLaunches == 1 ? "launch" : "launches"
        let gameWord = summary.uniqueGames == 1 ? "game" : "games"
        lines.append(
            "\(summary.totalLaunches) \(launchWord) across \(summary.uniqueGames) \(gameWord) · \(summary.successCount) succeeded, \(summary.failureCount) failed (\(formatPercent(summary.overallSuccessRatePercent))) · \(LaunchHistoryEntry.formatDuration(summary.totalTrackedSeconds)) tracked"
        )
        lines.append("")
        lines.append("| Metric | Value |")
        lines.append("| :--- | :--- |")
        lines.append("| **Total Launches** | \(summary.totalLaunches) |")
        lines.append("| **Unique Games** | \(summary.uniqueGames) |")
        lines.append("| **Success Rate** | \(formatPercent(summary.overallSuccessRatePercent)) (\(summary.successCount) succeeded, \(summary.failureCount) failed) |")
        lines.append("| **Tracked Playtime** | \(LaunchHistoryEntry.formatDuration(summary.totalTrackedSeconds)) |")
        lines.append("| **Median APFS CoW Clone** | \(formatCowMs(summary.medianCowCloneMs)) |")
        lines.append("| **ARM64EC / Rosetta 2** | \(summary.arm64ecLaunches) / \(summary.rosettaLaunches) |")
        lines.append("| **Seatbelt Sandboxed** | \(summary.sandboxedLaunches) |")

        if !summary.topGames.isEmpty {
            lines.append("")
            lines.append("## Per-Game Stability & Performance")
            lines.append("")
            lines.append("| Game | Tier | Launches | Success Rate | Playtime | Avg Session | Median CoW | Last Engine | Last Launch (UTC) |")
            lines.append("| :--- | :--- | ---: | ---: | ---: | ---: | ---: | :--- | :--- |")

            for stats in summary.topGames {
                let engineCell = stats.lastEngine.isEmpty ? "—" : "`\(cell(stats.lastEngine))`"
                let utcCell = stats.lastLaunchUtc.isEmpty ? "—" : "`\(cell(stats.lastLaunchUtc))`"
                let row = [
                    cell(stats.title),
                    cell(stats.stabilityTier.displayLabel),
                    "\(stats.totalLaunches)",
                    "\(formatPercent(stats.successRatePercent)) (\(stats.successCount)/\(stats.totalLaunches))",
                    cell(LaunchHistoryEntry.formatDuration(stats.totalSessionSeconds)),
                    cell(LaunchHistoryEntry.formatDuration(stats.averageSessionSeconds)),
                    cell(formatCowMs(stats.medianCowCloneMs)),
                    engineCell,
                    utcCell,
                ].joined(separator: " | ")
                lines.append("| \(row) |")
            }
        }

        if !summary.gamesNeedingAttention.isEmpty {
            lines.append("")
            lines.append("## Games Needing Attention")
            lines.append("")
            lines.append("| Game | Tier | Failures | Success Rate | Last Engine | Last Failure |")
            lines.append("| :--- | :--- | ---: | ---: | :--- | :--- |")

            for stats in summary.gamesNeedingAttention {
                let engineCell = stats.lastEngine.isEmpty ? "—" : "`\(cell(stats.lastEngine))`"
                let failureCell: String
                if let failure = stats.lastFailure, !failure.isEmpty {
                    failureCell = cell(failure)
                } else {
                    failureCell = "—"
                }
                let row = [
                    cell(stats.title),
                    cell(stats.stabilityTier.displayLabel),
                    "\(stats.failureCount)",
                    formatPercent(stats.successRatePercent),
                    engineCell,
                    failureCell,
                ].joined(separator: " | ")
                lines.append("| \(row) |")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Private helpers

    private enum EngineBucket {
        case arm64ec
        case rosetta
        case other
    }

    private static func classifyEngine(_ activeEngine: String) -> EngineBucket {
        let lower = activeEngine.lowercased()
        if lower.contains("arm64ec") {
            return .arm64ec
        }
        if lower.contains("rosetta") {
            return .rosetta
        }
        return .other
    }

    private static func groupKey(for entry: LaunchHistoryEntry) -> String {
        if let rawGameID = entry.gameID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawGameID.isEmpty {
            return rawGameID
        }
        let normalizedPath = normalizeExePath(entry.exePath)
        if !normalizedPath.isEmpty {
            return normalizedPath
        }
        let normalizedTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalizedTitle.isEmpty {
            return normalizedTitle
        }
        return "unknown"
    }

    private static func normalizeExePath(_ raw: String) -> String {
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

    private static func buildGameStats(
        key: String,
        entries: [LaunchHistoryEntry],
        home: String
    ) -> GameLaunchStats {
        let ordered = entries.sorted { lhs, rhs in
            if lhs.timestampUtc != rhs.timestampUtc {
                return lhs.timestampUtc < rhs.timestampUtc
            }
            return lhs.id < rhs.id
        }

        var successCount = 0
        var failureCount = 0
        var totalSeconds = 0.0
        var cowValues: [Double] = []
        var arm64ecCount = 0
        var rosettaCount = 0

        for entry in ordered {
            if entry.succeeded {
                successCount += 1
            } else {
                failureCount += 1
            }
            totalSeconds += sanitizedDuration(entry.elapsedSeconds)
            if let cowMs = sanitizedPositiveFinite(entry.cowCloneMs) {
                cowValues.append(cowMs)
            }
            switch classifyEngine(entry.activeEngine) {
            case .arm64ec:
                arm64ecCount += 1
            case .rosetta:
                rosettaCount += 1
            case .other:
                break
            }
        }

        let totalLaunches = ordered.count
        let averageSeconds = totalLaunches > 0 ? totalSeconds / Double(totalLaunches) : 0.0
        let successRate = computeSuccessRatePercent(successCount: successCount, totalLaunches: totalLaunches)
        let tier = GameStabilityTier.classify(
            totalLaunches: totalLaunches,
            successCount: successCount,
            failureCount: failureCount
        )

        let latest = ordered.last
        let resolvedTitle: String = {
            for entry in ordered.reversed() {
                let candidate = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty {
                    return candidate
                }
            }
            return "Untitled Game"
        }()

        let resolvedGameID: String? = {
            for entry in ordered.reversed() {
                if let gid = entry.gameID?.trimmingCharacters(in: .whitespacesAndNewlines), !gid.isEmpty {
                    return gid
                }
            }
            return nil
        }()

        let resolvedLastFailure: String? = {
            for entry in ordered.reversed() {
                if let failure = entry.failure?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !failure.isEmpty {
                    return LaunchDiagnostics.redactHome(failure, home: home)
                }
            }
            return nil
        }()

        return GameLaunchStats(
            id: key,
            gameID: resolvedGameID,
            title: resolvedTitle,
            totalLaunches: totalLaunches,
            successCount: successCount,
            failureCount: failureCount,
            successRatePercent: successRate,
            totalSessionSeconds: totalSeconds,
            averageSessionSeconds: averageSeconds,
            medianCowCloneMs: computeMedian(cowValues),
            arm64ecLaunches: arm64ecCount,
            rosettaLaunches: rosettaCount,
            lastEngine: latest?.activeEngine.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            lastLaunchUtc: latest?.timestampUtc ?? "",
            lastFailure: resolvedLastFailure,
            stabilityTier: tier
        )
    }

    private static func sanitizedDuration(_ value: Double) -> Double {
        (value.isFinite && value > 0) ? value : 0.0
    }

    private static func sanitizedPositiveFinite(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func computeSuccessRatePercent(successCount: Int, totalLaunches: Int) -> Double {
        guard totalLaunches > 0 else { return 0.0 }
        let clamped = max(0, min(successCount, totalLaunches))
        let raw = (Double(clamped) / Double(totalLaunches)) * 100.0
        let rounded = (raw * 100.0).rounded() / 100.0
        guard rounded.isFinite else { return 0.0 }
        return min(100.0, max(0.0, rounded))
    }

    private static func computeMedian(_ values: [Double]) -> Double? {
        let valid = values.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !valid.isEmpty else { return nil }
        let mid = valid.count / 2
        if valid.count % 2 == 1 {
            return valid[mid]
        }
        return (valid[mid - 1] + valid[mid]) / 2.0
    }

    private static func compareTitlesAscending(_ lhs: GameLaunchStats, _ rhs: GameLaunchStats) -> Bool {
        let cmp = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if cmp != .orderedSame {
            return cmp == .orderedAscending
        }
        if lhs.title != rhs.title {
            return lhs.title < rhs.title
        }
        return lhs.id < rhs.id
    }

    private static func formatPercent(_ value: Double) -> String {
        let safe = value.isFinite ? min(100.0, max(0.0, value)) : 0.0
        return String(format: "%.1f%%", safe)
    }

    private static func formatCowMs(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0 else { return "—" }
        return String(format: "%.2f ms", value)
    }

    private static func sanitizeSingleLine(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func escapeMarkdownCell(_ text: String) -> String {
        sanitizeSingleLine(text)
            .replacingOccurrences(of: "|", with: "\\|")
    }

    private static func pad(_ text: String, to width: Int) -> String {
        guard text.count < width else { return text }
        return text + String(repeating: " ", count: width - text.count)
    }

    private static func formatTableRow(_ columns: [String], widths: [Int]) -> String {
        columns.enumerated().map { index, value in
            if index == columns.count - 1 {
                return value
            }
            return pad(value, to: widths[index])
        }.joined(separator: "  ")
    }
}
