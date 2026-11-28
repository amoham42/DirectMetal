import Foundation

// Models, error types, and plain-text/Markdown formatters for LaunchLogAnalyzer.
// Single-pass byte-level scanner lives in LaunchLogAnalyzer.swift.

// MARK: - Severity & Category Models

enum LogFindingSeverity: String, Codable, Comparable, CaseIterable, Hashable, Sendable {
    case info
    case warning
    case error

    private var rank: Int {
        switch self {
        case .info: return 0
        case .warning: return 1
        case .error: return 2
        }
    }

    static func < (lhs: LogFindingSeverity, rhs: LogFindingSeverity) -> Bool {
        lhs.rank < rhs.rank
    }

    var displayLabel: String {
        switch self {
        case .info: return "INFO"
        case .warning: return "WARNING"
        case .error: return "ERROR"
        }
    }
}

enum LogFindingCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case antiCheat
    case missingDLL
    case sandboxDenied
    case gpuMemory
    case d3d12Alignment
    case shaderCompile
    case architecture
    case crash
    case general

    var displayName: String {
        switch self {
        case .antiCheat: return "Anti-Cheat"
        case .missingDLL: return "Missing DLL"
        case .sandboxDenied: return "Sandbox / Permissions"
        case .gpuMemory: return "GPU Memory / Device"
        case .d3d12Alignment: return "D3D12 Alignment"
        case .shaderCompile: return "Shader Compilation"
        case .architecture: return "CPU Architecture"
        case .crash: return "Crash / Exception"
        case .general: return "General"
        }
    }
}

// MARK: - Analysis Result Models

struct LaunchLogFinding: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let severity: LogFindingSeverity
    let category: LogFindingCategory
    let title: String
    let sampleLine: String
    let occurrences: Int
    let remediation: String
}

struct LaunchLogAnalysis: Codable, Equatable, Sendable {
    let totalLines: Int
    let errorLineCount: Int
    let warningLineCount: Int
    let highestSeverity: LogFindingSeverity
    let findings: [LaunchLogFinding]
    let summary: String
}

enum LaunchLogAnalyzerError: Error, LocalizedError, Equatable, Sendable {
    case fileNotFound(String)
    case pathIsDirectory(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Launch log not found at \(LaunchDiagnostics.redactHome(path))."
        case .pathIsDirectory(let path):
            return "Expected a log file, but path is a directory: \(LaunchDiagnostics.redactHome(path))."
        }
    }
}

// MARK: - Report Formatters

extension LaunchLogAnalyzer {
    // MARK: - Formatters

    static func formatText(_ analysis: LaunchLogAnalysis) -> String {
        var sections: [String] = []
        sections.append("DirectMetal Launch Log Analysis")

        let metaRows: [(String, String)] = [
            ("Highest Severity", analysis.highestSeverity.displayLabel),
            ("Lines Scanned", "\(analysis.totalLines)"),
            ("Error Lines", "\(analysis.errorLineCount)"),
            ("Warning Lines", "\(analysis.warningLineCount)"),
            ("Findings", "\(analysis.findings.count)"),
            ("Summary", analysis.summary),
        ]
        let labelWidth = max((metaRows.map { $0.0.count }.max() ?? 0) + 2, 18)
        var overviewLines = ["[Overview]"]
        for (label, value) in metaRows {
            let padded = (label + ":").padding(toLength: labelWidth, withPad: " ", startingAt: 0)
            overviewLines.append("  \(padded)\(value)")
        }
        sections.append(overviewLines.joined(separator: "\n"))

        if analysis.findings.isEmpty {
            sections.append("[Findings]\n  No actionable issues detected.")
        } else {
            var findingLines = ["[Findings (\(analysis.findings.count))]"]
            for (index, finding) in analysis.findings.enumerated() {
                let countLabel = finding.occurrences == 1 ? "1 occurrence" : "\(finding.occurrences) occurrences"
                findingLines.append(
                    "  \(index + 1). [\(finding.severity.displayLabel)] [\(finding.category.rawValue)] \(finding.title) (\(countLabel))"
                )
                findingLines.append("     ID:     \(finding.id)")
                findingLines.append("     Sample: \(finding.sampleLine)")
                findingLines.append("     Fix:    \(finding.remediation)")
            }
            sections.append(findingLines.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n") + "\n"
    }

    static func formatMarkdown(_ analysis: LaunchLogAnalysis) -> String {
        func severityIcon(_ severity: LogFindingSeverity) -> String {
            switch severity {
            case .error: return "🔴"
            case .warning: return "🟡"
            case .info: return "🔵"
            }
        }

        var lines: [String] = [
            "### DirectMetal Launch Log Analysis",
            "",
            "| Metric | Value |",
            "| :--- | :--- |",
            "| **Highest Severity** | \(severityIcon(analysis.highestSeverity)) `\(analysis.highestSeverity.rawValue)` |",
            "| **Lines Scanned** | \(analysis.totalLines) |",
            "| **Error Lines** | \(analysis.errorLineCount) |",
            "| **Warning Lines** | \(analysis.warningLineCount) |",
            "| **Findings** | \(analysis.findings.count) |",
            "",
            "> \(analysis.summary)",
        ]

        if !analysis.findings.isEmpty {
            lines.append("")
            lines.append("#### Findings")
            for (index, finding) in analysis.findings.enumerated() {
                let countText = finding.occurrences == 1 ? "1 occurrence" : "\(finding.occurrences) occurrences"
                lines.append("")
                lines.append(
                    "##### \(index + 1). \(severityIcon(finding.severity)) \(finding.title) (`\(finding.category.rawValue)` · `\(finding.severity.rawValue)` · \(countText))"
                )
                lines.append("")
                lines.append("- **ID:** `\(finding.id)`")
                lines.append("- **Sample:** \(markdownInlineCode(finding.sampleLine))")
                lines.append("- **Remediation:** \(finding.remediation)")
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func markdownInlineCode(_ text: String) -> String {
        var maxRun = 0
        var currentRun = 0
        for ch in text {
            if ch == "`" {
                currentRun += 1
                if currentRun > maxRun { maxRun = currentRun }
            } else {
                currentRun = 0
            }
        }
        let fence = String(repeating: "`", count: maxRun + 1)
        let needsPadding = text.hasPrefix("`") || text.hasSuffix("`")
        if needsPadding {
            return "\(fence) \(text) \(fence)"
        }
        return "\(fence)\(text)\(fence)"
    }
}
