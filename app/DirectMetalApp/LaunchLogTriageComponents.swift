import AppKit
import Foundation
import SwiftUI

// Supporting models, styling helpers, and reusable subviews for LaunchLogTriageSheet.

// MARK: - Supporting Models & Styling

enum TriageSeverityFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case error = "Errors"
    case warning = "Warnings"
    case info = "Info"

    var id: String { rawValue }

    var tint: Color {
        switch self {
        case .all: return .accentColor
        case .error: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }

    func matches(_ finding: LaunchLogFinding) -> Bool {
        switch self {
        case .all: return true
        case .error: return finding.severity == .error
        case .warning: return finding.severity == .warning
        case .info: return finding.severity == .info
        }
    }
}

enum TriageLogSource: Equatable {
    case file(path: String, title: String?)
    case pasted(title: String?)

    var icon: String {
        switch self {
        case .file: return "doc.text"
        case .pasted: return "doc.on.clipboard"
        }
    }

    var displayLabel: String {
        switch self {
        case .file(let path, let title):
            let redacted = LaunchDiagnostics.redactHome(path)
            if let title = trimmedNonEmpty(title) {
                return "\(title) · \(redacted)"
            }
            return redacted
        case .pasted(let title):
            if let title = trimmedNonEmpty(title) {
                return "\(title) · Pasted Log"
            }
            return "Pasted Log"
        }
    }

    var filePath: String? {
        if case .file(let path, _) = self {
            return path
        }
        return nil
    }

    private func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

enum TriageStyle {
    static func tint(for severity: LogFindingSeverity) -> Color {
        switch severity {
        case .error: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }

    static func icon(for severity: LogFindingSeverity) -> String {
        switch severity {
        case .error: return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    static func icon(for category: LogFindingCategory) -> String {
        switch category {
        case .antiCheat: return "shield.lefthalf.filled.slash"
        case .missingDLL: return "puzzlepiece.extension"
        case .sandboxDenied: return "lock.shield"
        case .gpuMemory: return "memorychip"
        case .d3d12Alignment: return "square.grid.3x3"
        case .shaderCompile: return "sparkles"
        case .architecture: return "cpu"
        case .crash: return "bolt.trianglebadge.exclamationmark"
        case .general: return "wrench.and.screwdriver"
        }
    }

    static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

// MARK: - Overview KPI Strip

struct LaunchLogOverviewKPIStrip: View {
    let analysis: LaunchLogAnalysis

    var body: some View {
        let highestColor = TriageStyle.tint(for: analysis.highestSeverity)
        let highestIcon = TriageStyle.icon(for: analysis.highestSeverity)

        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    // Highest Severity badge tile
                    HStack(spacing: 8) {
                        Image(systemName: highestIcon)
                            .font(.title3)
                            .foregroundStyle(highestColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Highest Severity")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(analysis.highestSeverity.displayLabel)
                                .font(.callout.bold())
                                .foregroundStyle(highestColor)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        highestColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(highestColor.opacity(0.28))
                    )

                    kpiTile(
                        title: "Lines Scanned",
                        value: analysis.totalLines.formatted(),
                        tint: .primary
                    )

                    kpiTile(
                        title: "Error Lines",
                        value: analysis.errorLineCount.formatted(),
                        tint: analysis.errorLineCount > 0 ? .red : .secondary
                    )

                    kpiTile(
                        title: "Warning Lines",
                        value: analysis.warningLineCount.formatted(),
                        tint: analysis.warningLineCount > 0 ? .orange : .secondary
                    )

                    kpiTile(
                        title: "Findings",
                        value: analysis.findings.count.formatted(),
                        tint: analysis.findings.isEmpty ? .green : highestColor
                    )
                }

                Divider()

                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: analysis.findings.isEmpty ? "checkmark.seal.fill" : "text.badge.checkmark")
                        .font(.caption)
                        .foregroundStyle(analysis.findings.isEmpty ? Color.green : Color.secondary)
                        .padding(.top, 2)
                    Text(analysis.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func kpiTile(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.callout.bold().monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }
}

// MARK: - Interactive Filtering Bar

struct LaunchLogFilterBar: View {
    let totalCount: Int
    let filteredCount: Int
    let isFiltering: Bool
    @Binding var searchText: String
    @Binding var severityFilter: TriageSeverityFilter
    let severityCount: (TriageSeverityFilter) -> Int
    let availableCategories: [LogFindingCategory]
    @Binding var selectedCategory: LogFindingCategory?
    let categoryCount: (LogFindingCategory) -> Int
    let onResetFilters: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.callout)

                TextField("Search finding title, sample line, remediation, or category…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)

                if isFiltering {
                    Text("\(filteredCount) of \(totalCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search text")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.18))
            )

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(TriageSeverityFilter.allCases) { filter in
                        let count = severityCount(filter)
                        let selected = severityFilter == filter
                        Button {
                            severityFilter = filter
                        } label: {
                            HStack(spacing: 4) {
                                Text(filter.rawValue)
                                    .font(.caption.weight(.semibold))
                                Text("\(count)")
                                    .font(.caption2.weight(.medium).monospacedDigit())
                                    .opacity(selected ? 0.92 : 0.78)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .foregroundStyle(
                                selected ? Color.white : (count == 0 ? Color.secondary : filter.tint)
                            )
                            .background(
                                selected ? filter.tint : filter.tint.opacity(count == 0 ? 0.06 : 0.13),
                                in: Capsule()
                            )
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }

                Spacer(minLength: 8)

                if !availableCategories.isEmpty {
                    HStack(spacing: 6) {
                        Text("Category")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Category", selection: $selectedCategory) {
                            Text("All Categories").tag(Optional<LogFindingCategory>.none)
                            Divider()
                            ForEach(availableCategories, id: \.self) { category in
                                Text("\(category.displayName) (\(categoryCount(category)))")
                                    .tag(Optional(category))
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 220)
                        .help("Filter findings by diagnostic category")
                    }
                }

                if isFiltering {
                    Button("Reset Filters") {
                        onResetFilters()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Reset severity, category, and search filters")
                }
            }
        }
    }
}

// MARK: - Finding Card Subview

struct LaunchLogFindingCard: View {
    let finding: LaunchLogFinding

    @State private var copiedLine: Bool = false
    @State private var copiedFix: Bool = false
    @State private var lineCopyGeneration: Int = 0
    @State private var fixCopyGeneration: Int = 0

    private var severityTint: Color {
        TriageStyle.tint(for: finding.severity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader
            sampleLineBlock
            remediationCallout
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(severityTint.opacity(0.24), lineWidth: 1)
        )
    }

    private var cardHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 7) {
                Label(finding.severity.displayLabel, systemImage: TriageStyle.icon(for: finding.severity))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .foregroundStyle(severityTint)
                    .background(severityTint.opacity(0.14), in: Capsule())

                Label(finding.category.displayName, systemImage: TriageStyle.icon(for: finding.category))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .foregroundStyle(.secondary)
                    .background(Color.secondary.opacity(0.12), in: Capsule())

                Spacer(minLength: 8)

                Text("×\(finding.occurrences)")
                    .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2.5)
                    .foregroundStyle(severityTint)
                    .background(severityTint.opacity(0.12), in: Capsule())
                    .help(
                        finding.occurrences == 1
                            ? "Matched 1 time in this log"
                            : "Matched \(finding.occurrences) times in this log"
                    )
            }

            Text(finding.title)
                .font(.headline)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sampleLineBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("Sample Log Line")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    copySampleLine()
                } label: {
                    Label(
                        copiedLine ? "Copied!" : "Copy Line",
                        systemImage: copiedLine ? "checkmark" : "doc.on.doc"
                    )
                    .font(.caption2.weight(.medium))
                }
                .controlSize(.mini)
                .buttonStyle(.bordered)
                .help("Copy the redacted sample log line to the clipboard")
            }

            Text(finding.sampleLine)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.16))
                )
        }
    }

    private var remediationCallout: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("DirectMetal Remediation", systemImage: "wrench.and.screwdriver")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)

                Spacer(minLength: 8)

                Button {
                    copyRemediation()
                } label: {
                    Label(
                        copiedFix ? "Copied!" : "Copy Fix",
                        systemImage: copiedFix ? "checkmark" : "lightbulb"
                    )
                    .font(.caption2.weight(.medium))
                }
                .controlSize(.mini)
                .buttonStyle(.bordered)
                .help("Copy the remediation guidance to the clipboard")
            }

            Text(finding.remediation)
                .font(.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Color.accentColor.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.24))
        )
    }

    private func copySampleLine() {
        TriageStyle.copyToPasteboard(finding.sampleLine)
        lineCopyGeneration &+= 1
        let generation = lineCopyGeneration
        withAnimation(.snappy(duration: 0.15)) {
            copiedLine = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard generation == lineCopyGeneration else { return }
            withAnimation(.snappy(duration: 0.15)) {
                copiedLine = false
            }
        }
    }

    private func copyRemediation() {
        TriageStyle.copyToPasteboard(finding.remediation)
        fixCopyGeneration &+= 1
        let generation = fixCopyGeneration
        withAnimation(.snappy(duration: 0.15)) {
            copiedFix = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard generation == fixCopyGeneration else { return }
            withAnimation(.snappy(duration: 0.15)) {
                copiedFix = false
            }
        }
    }
}
