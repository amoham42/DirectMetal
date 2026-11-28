import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// Native macOS 15 SwiftUI Launch Log Triage & Crash Diagnostics Sheet.
// Backed by LaunchLogAnalyzer, supports loading .log/.txt files via NSOpenPanel,
// drag-and-drop (.fileURL and .plainText), collapsible raw log pasting, off-main-thread
// scanning for multi-megabyte logs, KPI summary strip, interactive severity/category/search
// filtering, per-finding sample & remediation copy controls, and full report export.

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
                LaunchLogOverviewKPIStrip(analysis: currentAnalysis)
                    .padding(.horizontal, 22)
                    .padding(.top, (showPastePanel || errorMessage != nil) ? 0 : 14)

                if !currentAnalysis.findings.isEmpty {
                    LaunchLogFilterBar(
                        totalCount: currentAnalysis.findings.count,
                        filteredCount: filteredFindings.count,
                        isFiltering: isFiltering,
                        searchText: $searchText,
                        severityFilter: $severityFilter,
                        severityCount: severityCount,
                        availableCategories: availableCategories,
                        selectedCategory: $selectedCategory,
                        categoryCount: categoryCount,
                        onResetFilters: resetFilters
                    )
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
