import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// Native macOS 15 SwiftUI Launch Log Triage & Crash Diagnostics Sheet.
// Backed by LaunchLogAnalyzer, supports loading .log/.txt files via NSOpenPanel,
// drag-and-drop (.fileURL and .plainText), collapsible raw log pasting, off-main-thread
// scanning for multi-megabyte logs, KPI summary strip, interactive severity/category/search
// filtering, per-finding sample & remediation copy controls, and full report export.

// MARK: - Supporting Models & Styling

private enum TriageSeverityFilter: String, CaseIterable, Identifiable {
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

private enum TriageLogSource: Equatable {
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

private enum TriageStyle {
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

// MARK: - Launch Log Triage Sheet

struct LaunchLogTriageSheet: View {
    private let initialFilePath: String?
    private let initialLogText: String?
    private let initialTitle: String?

    @Environment(\.dismiss) private var dismiss

    @State private var source: TriageLogSource?
    @State private var analysis: LaunchLogAnalysis?
    @State private var isScanning: Bool = false
    @State private var scanGeneration: Int = 0
    @State private var scanTask: Task<Void, Never>?
    @State private var errorMessage: String?

    @State private var showPastePanel: Bool = false
    @State private var pastedLogText: String = ""
    @State private var isDropTargeted: Bool = false
    @State private var hasLoadedInitial: Bool = false

    @State private var severityFilter: TriageSeverityFilter = .all
    @State private var selectedCategory: LogFindingCategory? = nil
    @State private var searchText: String = ""

    @State private var copiedMarkdown: Bool = false
    @State private var copiedPlainText: Bool = false
    @State private var markdownCopyGeneration: Int = 0
    @State private var plainTextCopyGeneration: Int = 0

    init(
        initialFilePath: String? = nil,
        initialLogText: String? = nil,
        initialTitle: String? = nil
    ) {
        self.initialFilePath = initialFilePath
        self.initialLogText = initialLogText
        self.initialTitle = initialTitle
    }

    // MARK: Derived State

    private var allFindings: [LaunchLogFinding] {
        analysis?.findings ?? []
    }

    private var availableCategories: [LogFindingCategory] {
        let present = Set(allFindings.map(\.category))
        return LogFindingCategory.allCases.filter { present.contains($0) }
    }

    private var categoryAndSearchMatches: [LaunchLogFinding] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return allFindings.filter { finding in
            if let category = selectedCategory, finding.category != category {
                return false
            }
            guard !query.isEmpty else { return true }
            return finding.title.localizedCaseInsensitiveContains(query)
                || finding.sampleLine.localizedCaseInsensitiveContains(query)
                || finding.remediation.localizedCaseInsensitiveContains(query)
                || finding.category.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    private var filteredFindings: [LaunchLogFinding] {
        categoryAndSearchMatches.filter(severityFilter.matches)
    }

    private var isFiltering: Bool {
        severityFilter != .all
            || selectedCategory != nil
            || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasLoadedLog: Bool {
        source != nil || analysis != nil || errorMessage != nil || isScanning
    }

    private func severityCount(_ filter: TriageSeverityFilter) -> Int {
        categoryAndSearchMatches.reduce(0) { $0 + (filter.matches($1) ? 1 : 0) }
    }

    private func categoryCount(_ category: LogFindingCategory) -> Int {
        allFindings.reduce(0) { $0 + ($1.category == category ? 1 : 0) }
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                if showPastePanel {
                    pasteLogPanel
                        .padding(.horizontal, 22)
                        .padding(.top, 14)
                }

                if let error = errorMessage {
                    errorBanner(error)
                        .padding(.horizontal, 22)
                        .padding(.top, showPastePanel ? 0 : 14)
                }

                mainContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()
            footerBar
        }
        .frame(minWidth: 740, idealWidth: 840, minHeight: 540, idealHeight: 620)
        .overlay {
            if isDropTargeted {
                dropHighlightOverlay
            }
        }
        .onDrop(of: [.fileURL, .plainText], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .onAppear {
            loadInitialIfNeeded()
        }
        .onDisappear {
            scanTask?.cancel()
            scanTask = nil
        }
    }

    // MARK: Header & Footer

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Launch Log Crash Triage", systemImage: "stethoscope")
                    .font(.title2.bold())
                    .lineLimit(1)

                if let source {
                    HStack(spacing: 6) {
                        Image(systemName: source.icon)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(source.displayLabel)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                } else {
                    Text("Open a Wine/DirectMetal .log file, paste log text, or drop a file anywhere in this window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 10)

            HStack(spacing: 8) {
                Button {
                    openLogPanel()
                } label: {
                    Label("Open Log…", systemImage: "folder")
                }
                .controlSize(.small)
                .help("Choose a .log, .txt, or other readable log file to scan")

                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        showPastePanel.toggle()
                    }
                } label: {
                    Label("Paste Log", systemImage: showPastePanel ? "chevron.up" : "doc.on.clipboard")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(showPastePanel ? .accentColor : nil)
                .help(showPastePanel ? "Collapse raw log paste panel" : "Paste raw Wine or DirectMetal log text to scan")

                if hasLoadedLog {
                    Button {
                        clearLoadedLog()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                    .controlSize(.small)
                    .help("Clear the current log analysis and reset filters")
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var footerBar: some View {
        HStack(spacing: 10) {
            Button {
                copyMarkdownReport()
            } label: {
                Label(
                    copiedMarkdown ? "Copied!" : "Copy Markdown Report",
                    systemImage: copiedMarkdown ? "checkmark" : "doc.on.doc"
                )
            }
            .disabled(analysis == nil || isScanning)
            .help("Copy a GitHub-issue-ready Markdown crash triage report with home paths redacted")

            Button {
                copyPlainTextReport()
            } label: {
                Label(
                    copiedPlainText ? "Copied!" : "Copy Plain Text",
                    systemImage: copiedPlainText ? "checkmark" : "doc.plaintext"
                )
            }
            .disabled(analysis == nil || isScanning)
            .help("Copy a plain-text crash triage report with home paths redacted")

            Spacer(minLength: 12)

            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    // MARK: Paste Panel & Error Banner

    private var pasteLogPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label("Raw Log Input", systemImage: "text.alignleft")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if !pastedLogText.isEmpty {
                        let lineCount = pastedLogText.split(
                            omittingEmptySubsequences: false,
                            whereSeparator: \.isNewline
                        ).count
                        Text("\(lineCount) line\(lineCount == 1 ? "" : "s")")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }

                    Spacer(minLength: 8)

                    Button {
                        pasteFromClipboard()
                    } label: {
                        Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                    }
                    .controlSize(.small)
                    .help("Replace the editor contents with plain text from the clipboard")

                    Button {
                        scanPastedText(pastedLogText, title: nil)
                    } label: {
                        Label("Scan Pasted Log", systemImage: "magnifyingglass")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(pastedLogText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isScanning)
                    .help("Analyze the pasted log text for crashes, missing DLLs, and GPU/sandbox issues")
                }

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $pastedLogText)
                        .font(.system(.caption, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 108, maxHeight: 136)
                        .background(
                            Color.secondary.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color.secondary.opacity(0.20))
                        )

                    if pastedLogText.isEmpty {
                        Text("Paste Wine, DXVK, Mullion, or DirectMetal launch log output here…")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                }
            }
            .padding(4)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text("Unable to Scan Launch Log")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    errorMessage = nil
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss error banner")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Color.red.opacity(0.11),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.red.opacity(0.30))
        )
    }

    // MARK: Main Content States

    @ViewBuilder
    private var mainContent: some View {
        if isScanning {
            VStack(spacing: 12) {
                ProgressView("Scanning launch log…")
                    .controlSize(.regular)
                if let source {
                    Text(source.displayLabel)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 540)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else if let currentAnalysis = analysis {
            VStack(alignment: .leading, spacing: 12) {
                overviewKPIStrip(currentAnalysis)
                    .padding(.horizontal, 22)
                    .padding(.top, (showPastePanel || errorMessage != nil) ? 0 : 14)

                if !currentAnalysis.findings.isEmpty {
                    filterBar(currentAnalysis)
                        .padding(.horizontal, 22)
                }

                findingsListArea(currentAnalysis)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            emptyWelcomeState
        }
    }

    private var emptyWelcomeState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 38))
                .foregroundStyle(.tertiary)

            VStack(spacing: 5) {
                Text("Inspect a DirectMetal Launch Log")
                    .font(.headline)
                Text("Drag and drop any Wine, Mullion, or DirectMetal .log file here to classify crashes, missing DLLs, anti-cheat blocks, Seatbelt sandbox denials, GPU OOM, and shader errors.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }

            HStack(spacing: 10) {
                Button {
                    openLogPanel()
                } label: {
                    Label("Open Log…", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        showPastePanel = true
                    }
                } label: {
                    Label("Paste Log Text", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    // MARK: Overview KPI Strip

    private func overviewKPIStrip(_ currentAnalysis: LaunchLogAnalysis) -> some View {
        let highestColor = TriageStyle.tint(for: currentAnalysis.highestSeverity)
        let highestIcon = TriageStyle.icon(for: currentAnalysis.highestSeverity)

        return GroupBox {
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
                            Text(currentAnalysis.highestSeverity.displayLabel)
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
                        value: currentAnalysis.totalLines.formatted(),
                        tint: .primary
                    )

                    kpiTile(
                        title: "Error Lines",
                        value: currentAnalysis.errorLineCount.formatted(),
                        tint: currentAnalysis.errorLineCount > 0 ? .red : .secondary
                    )

                    kpiTile(
                        title: "Warning Lines",
                        value: currentAnalysis.warningLineCount.formatted(),
                        tint: currentAnalysis.warningLineCount > 0 ? .orange : .secondary
                    )

                    kpiTile(
                        title: "Findings",
                        value: currentAnalysis.findings.count.formatted(),
                        tint: currentAnalysis.findings.isEmpty ? .green : highestColor
                    )
                }

                Divider()

                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: currentAnalysis.findings.isEmpty ? "checkmark.seal.fill" : "text.badge.checkmark")
                        .font(.caption)
                        .foregroundStyle(currentAnalysis.findings.isEmpty ? Color.green : Color.secondary)
                        .padding(.top, 2)
                    Text(currentAnalysis.summary)
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

    // MARK: Interactive Filtering Bar

    private func filterBar(_ currentAnalysis: LaunchLogAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.callout)

                TextField("Search finding title, sample line, remediation, or category…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)

                if isFiltering {
                    Text("\(filteredFindings.count) of \(currentAnalysis.findings.count)")
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
                        resetFilters()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Reset severity, category, and search filters")
                }
            }
        }
    }

    // MARK: Findings List

    @ViewBuilder
    private func findingsListArea(_ currentAnalysis: LaunchLogAnalysis) -> some View {
        if currentAnalysis.findings.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(.green)

                Text("No errors or compatibility warnings detected in this log")
                    .font(.headline)

                Text(currentAnalysis.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else if filteredFindings.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)

                Text("No findings match the current filters")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button("Reset Filters") {
                    resetFilters()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(filteredFindings) { finding in
                        LaunchLogFindingCard(finding: finding)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: Drag-and-Drop Overlay

    private var dropHighlightOverlay: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.accentColor.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 2.5, dash: [8, 5])
                    )
            )
            .overlay(
                Label("Drop Launch Log to Scan", systemImage: "arrow.down.doc.fill")
                    .font(.title3.bold())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
            )
            .padding(10)
            .allowsHitTesting(false)
    }

    // MARK: Actions

    private func loadInitialIfNeeded() {
        guard !hasLoadedInitial else { return }
        hasLoadedInitial = true

        if let path = initialFilePath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            scanFile(at: path, title: initialTitle)
        } else if let text = initialLogText, !text.isEmpty {
            pastedLogText = text
            scanPastedText(text, title: initialTitle)
        }
    }

    private func openLogPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Launch Log"
        panel.message = "Choose a Wine, Mullion, or DirectMetal .log or .txt file to analyze."
        panel.allowedContentTypes = [.log, .plainText, .text, .data]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        scanFile(at: url.path, title: nil)
    }

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        pastedLogText = text
    }

    private func clearLoadedLog() {
        scanTask?.cancel()
        scanTask = nil
        scanGeneration &+= 1
        isScanning = false
        source = nil
        analysis = nil
        errorMessage = nil
        pastedLogText = ""
        resetFilters()
    }

    private func resetFilters() {
        severityFilter = .all
        selectedCategory = nil
        searchText = ""
    }

    private func scanFile(at path: String, title: String?) {
        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)

        source = .file(path: trimmedPath, title: title)
        errorMessage = nil
        isScanning = true
        resetFilters()

        scanTask = Task.detached(priority: .userInitiated) {
            do {
                let result = try LaunchLogAnalyzer.analyzeFile(at: trimmedPath)
                await MainActor.run {
                    guard !Task.isCancelled, generation == scanGeneration else { return }
                    analysis = result
                    errorMessage = nil
                    isScanning = false
                    showPastePanel = false
                }
            } catch {
                let localized = error.localizedDescription
                await MainActor.run {
                    guard !Task.isCancelled, generation == scanGeneration else { return }
                    analysis = nil
                    errorMessage = localized
                    isScanning = false
                }
            }
        }
    }

    private func scanPastedText(_ text: String, title: String?) {
        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration

        source = .pasted(title: title)
        errorMessage = nil
        isScanning = true
        resetFilters()

        scanTask = Task.detached(priority: .userInitiated) {
            let result = LaunchLogAnalyzer.analyze(text)
            await MainActor.run {
                guard !Task.isCancelled, generation == scanGeneration else { return }
                analysis = result
                errorMessage = nil
                isScanning = false
                showPastePanel = false
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        if let fileProvider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) {
            _ = fileProvider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                let droppedPath = url.path
                Task { @MainActor in
                    scanFile(at: droppedPath, title: nil)
                }
            }
            return true
        }

        if let textProvider = providers.first(where: { $0.canLoadObject(ofClass: String.self) }) {
            _ = textProvider.loadObject(ofClass: String.self) { text, _ in
                guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                Task { @MainActor in
                    pastedLogText = text
                    scanPastedText(text, title: nil)
                }
            }
            return true
        }

        return false
    }

    private func copyMarkdownReport() {
        guard let currentAnalysis = analysis else { return }
        TriageStyle.copyToPasteboard(LaunchLogAnalyzer.formatMarkdown(currentAnalysis))
        markdownCopyGeneration &+= 1
        let generation = markdownCopyGeneration
        withAnimation(.snappy(duration: 0.15)) {
            copiedMarkdown = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard generation == markdownCopyGeneration else { return }
            withAnimation(.snappy(duration: 0.15)) {
                copiedMarkdown = false
            }
        }
    }

    private func copyPlainTextReport() {
        guard let currentAnalysis = analysis else { return }
        TriageStyle.copyToPasteboard(LaunchLogAnalyzer.formatText(currentAnalysis))
        plainTextCopyGeneration &+= 1
        let generation = plainTextCopyGeneration
        withAnimation(.snappy(duration: 0.15)) {
            copiedPlainText = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard generation == plainTextCopyGeneration else { return }
            withAnimation(.snappy(duration: 0.15)) {
                copiedPlainText = false
            }
        }
    }
}

// MARK: - Finding Card Subview

private struct LaunchLogFindingCard: View {
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
