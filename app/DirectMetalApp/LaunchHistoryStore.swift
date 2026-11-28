import AppKit
import Foundation
import SwiftUI

// Structured Launch History Store (append-only JSONL) and native macOS 15 SwiftUI
// Launch History Sheet for DirectMetal.

// MARK: - Data model

struct LaunchHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var timestampUtc: String
    var gameID: String?
    var title: String
    var exePath: String
    var prefixName: String
    var requestedEngine: String
    var activeEngine: String
    var exitCode: Int32?
    var elapsedSeconds: Double
    var sandboxed: Bool
    var cowCloneMs: Double?
    var fpsCap: Int
    var upscaleMode: String
    var failure: String?

    init(
        id: String = UUID().uuidString,
        timestampUtc: String = GameLibraryManager.isoFormatter.string(from: Date()),
        gameID: String? = nil,
        title: String,
        exePath: String,
        prefixName: String,
        requestedEngine: String = "auto",
        activeEngine: String = "arm64ec-fex",
        exitCode: Int32? = nil,
        elapsedSeconds: Double = 0,
        sandboxed: Bool = false,
        cowCloneMs: Double? = nil,
        fpsCap: Int = 0,
        upscaleMode: String = "off",
        failure: String? = nil
    ) {
        self.id = id
        self.timestampUtc = timestampUtc
        self.gameID = gameID
        self.title = title
        self.exePath = exePath
        self.prefixName = prefixName
        self.requestedEngine = requestedEngine
        self.activeEngine = activeEngine
        self.exitCode = exitCode
        self.elapsedSeconds = (elapsedSeconds.isFinite && elapsedSeconds > 0) ? elapsedSeconds : 0
        self.sandboxed = sandboxed
        self.cowCloneMs = cowCloneMs
        self.fpsCap = max(0, min(fpsCap, 360))
        let normalizedUpscale = upscaleMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.upscaleMode = normalizedUpscale.isEmpty ? "off" : normalizedUpscale
        self.failure = failure
    }

    init(from diagnostics: LaunchDiagnostics, fpsCap: Int = 0, upscaleMode: String = "off") {
        self.init(
            id: UUID().uuidString,
            timestampUtc: GameLibraryManager.isoFormatter.string(from: diagnostics.startedAt),
            gameID: diagnostics.gameID.isEmpty ? nil : diagnostics.gameID,
            title: diagnostics.title,
            exePath: diagnostics.exePath,
            prefixName: diagnostics.prefixName,
            requestedEngine: diagnostics.requestedEngine,
            activeEngine: diagnostics.activeEngine,
            exitCode: diagnostics.exitCode,
            elapsedSeconds: diagnostics.elapsedSeconds,
            sandboxed: diagnostics.sandboxed,
            cowCloneMs: diagnostics.cloneMs,
            fpsCap: fpsCap,
            upscaleMode: upscaleMode,
            failure: diagnostics.failure
        )
    }

    var succeeded: Bool { failure == nil && exitCode == 0 }

    var durationLabel: String {
        Self.formatDuration(elapsedSeconds)
    }

    var hasActiveUpscale: Bool {
        let mode = upscaleMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !mode.isEmpty && mode != "off"
    }

    var upscaleDisplayLabel: String {
        switch upscaleMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "quality": return "MetalFX Quality"
        case "balanced": return "MetalFX Balanced"
        case "performance": return "MetalFX Perf"
        case "ultra_performance": return "MetalFX Ultra Perf"
        default: return "MetalFX \(upscaleMode)"
        }
    }

    static func formatDuration(_ seconds: Double) -> String {
        let s = (seconds.isFinite && seconds > 0) ? seconds : 0
        if s < 60.0 {
            return String(format: "%.1f s", s)
        }
        if s < 3600.0 {
            let total = Int(s.rounded(.down))
            let mins = total / 60
            let rem = total % 60
            return "\(mins)m \(rem)s"
        }
        let hrs = s / 3600.0
        return String(format: "%.1f hrs", hrs)
    }
}

// MARK: - JSONL persistence store

final class LaunchHistoryStore: Sendable {
    static let maxEntries = 200
    private static let ioLock = NSLock()

    let historyURL: URL

    init(supportRoot: URL? = nil) {
        let root = supportRoot ?? GameLibraryManager.defaultSupportRoot()
        self.historyURL = root.appendingPathComponent("launch_history.jsonl")
    }

    /// Appends one compact JSONL line, creating parent directories as needed, and atomically trims
    /// the file to the newest `maxEntries` lines whenever the line count exceeds `maxEntries`.
    func append(_ entry: LaunchHistoryEntry) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var lineData = try? enc.encode(entry) else { return }
        let newline = UInt8(ascii: "\n")
        lineData.append(newline)

        Self.ioLock.lock()
        defer { Self.ioLock.unlock() }

        let fm = FileManager.default
        let parentDir = historyURL.deletingLastPathComponent()
        try? fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

        if !fm.fileExists(atPath: historyURL.path) {
            try? lineData.write(to: historyURL, options: .atomic)
            return
        }

        if let handle = try? FileHandle(forUpdating: historyURL) {
            var appended = false
            do {
                let endOffset = try handle.seekToEnd()
                if endOffset > 0 {
                    try handle.seek(toOffset: endOffset - 1)
                    if let lastByte = try handle.read(upToCount: 1)?.first, lastByte != newline {
                        try handle.seekToEnd()
                        try handle.write(contentsOf: Data([newline]))
                    } else {
                        try handle.seekToEnd()
                    }
                }
                try handle.write(contentsOf: lineData)
                appended = true
            } catch {
                appended = false
            }
            try? handle.close()
            if !appended {
                var combined = (try? Data(contentsOf: historyURL)) ?? Data()
                if let last = combined.last, last != newline {
                    combined.append(newline)
                }
                combined.append(lineData)
                try? combined.write(to: historyURL, options: .atomic)
            }
        } else {
            var combined = (try? Data(contentsOf: historyURL)) ?? Data()
            if let last = combined.last, last != newline {
                combined.append(newline)
            }
            combined.append(lineData)
            try? combined.write(to: historyURL, options: .atomic)
        }

        trimIfNeededLocked()
    }

    /// Reads JSONL line-by-line tolerantly (skipping blank and malformed lines), returning newest
    /// entries first, capped to `limit`.
    func load(limit: Int = 200) -> [LaunchHistoryEntry] {
        guard limit > 0 else { return [] }

        Self.ioLock.lock()
        let rawData = try? Data(contentsOf: historyURL)
        Self.ioLock.unlock()

        guard let data = rawData, !data.isEmpty else { return [] }

        let newline = UInt8(ascii: "\n")
        let lines = data.split(separator: newline, omittingEmptySubsequences: true)
        let decoder = JSONDecoder()
        var entries: [LaunchHistoryEntry] = []
        entries.reserveCapacity(min(limit, lines.count))

        for slice in lines.reversed() {
            guard !Self.isWhitespaceOnly(slice) else { continue }
            if let entry = try? decoder.decode(LaunchHistoryEntry.self, from: Data(slice)) {
                entries.append(entry)
                if entries.count >= limit {
                    break
                }
            }
        }
        return entries
    }

    /// Removes `historyURL` cleanly if present.
    func clear() {
        Self.ioLock.lock()
        defer { Self.ioLock.unlock() }

        let fm = FileManager.default
        if fm.fileExists(atPath: historyURL.path) {
            try? fm.removeItem(at: historyURL)
        }
    }

    /// Formats a clean GitHub-ready Markdown table of recent launches with home-redacted paths.
    func markdownReport(limit: Int = 50, home: String = NSHomeDirectory()) -> String {
        Self.markdownReport(entries: load(limit: limit), home: home)
    }

    static func markdownReport(entries: [LaunchHistoryEntry], home: String = NSHomeDirectory()) -> String {
        var lines: [String] = ["# DirectMetal Launch History", ""]
        guard !entries.isEmpty else {
            lines.append("_No launches recorded yet._")
            return lines.joined(separator: "\n") + "\n"
        }

        let succeededCount = entries.reduce(0) { $0 + ($1.succeeded ? 1 : 0) }
        let failedCount = entries.count - succeededCount
        let totalDuration = entries.reduce(0.0) { $0 + $1.elapsedSeconds }
        let launchWord = entries.count == 1 ? "launch" : "launches"
        lines.append(
            "Showing \(entries.count) recent \(launchWord) · \(succeededCount) succeeded, \(failedCount) failed · \(LaunchHistoryEntry.formatDuration(totalDuration)) total"
        )
        lines.append("")
        lines.append("| Time (UTC) | Game | Status | Duration | Engine | Prefix | Options | Executable |")
        lines.append("| --- | --- | --- | --- | --- | --- | --- | --- |")

        for entry in entries {
            let statusText: String
            if entry.succeeded {
                statusText = "Succeeded (exit 0)"
            } else if let failure = entry.failure?.trimmingCharacters(in: .whitespacesAndNewlines), !failure.isEmpty {
                let redactedFailure = LaunchDiagnostics.redactHome(failure, home: home)
                statusText = "Failed: \(redactedFailure)"
            } else if let code = entry.exitCode {
                statusText = "Failed (exit \(code))"
            } else {
                statusText = "Failed"
            }

            var options: [String] = []
            if entry.sandboxed {
                options.append("Seatbelt")
            }
            if let cowMs = entry.cowCloneMs {
                options.append(String(format: "CoW %.2f ms", cowMs))
            }
            if entry.fpsCap > 0 {
                options.append("\(entry.fpsCap) FPS")
            }
            if entry.hasActiveUpscale {
                options.append(entry.upscaleDisplayLabel)
            }
            let optionsCell = options.isEmpty ? "—" : options.joined(separator: ", ")

            let redactedExe = LaunchDiagnostics.redactHome(entry.exePath, home: home)
            let row = [
                "`\(escapeMarkdownCell(entry.timestampUtc))`",
                escapeMarkdownCell(entry.title),
                escapeMarkdownCell(statusText),
                escapeMarkdownCell(entry.durationLabel),
                "`\(escapeMarkdownCell(entry.activeEngine))`",
                "`\(escapeMarkdownCell(entry.prefixName))`",
                escapeMarkdownCell(optionsCell),
                "`\(escapeMarkdownCell(redactedExe))`",
            ].joined(separator: " | ")
            lines.append("| \(row) |")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Private helpers

    private func trimIfNeededLocked() {
        guard let fileData = try? Data(contentsOf: historyURL), !fileData.isEmpty else { return }
        let newline = UInt8(ascii: "\n")
        let nonBlankLines = fileData
            .split(separator: newline, omittingEmptySubsequences: true)
            .filter { !Self.isWhitespaceOnly($0) }

        guard nonBlankLines.count > Self.maxEntries else { return }
        let kept = nonBlankLines.suffix(Self.maxEntries)
        var trimmed = Data()
        trimmed.reserveCapacity(kept.reduce(0) { $0 + $1.count + 1 })
        for slice in kept {
            trimmed.append(contentsOf: slice)
            trimmed.append(newline)
        }
        try? trimmed.write(to: historyURL, options: .atomic)
    }

    private static func isWhitespaceOnly(_ slice: Data.SubSequence) -> Bool {
        slice.allSatisfy { byte in
            byte == 0x20 || byte == 0x09 || byte == 0x0D
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
}

// MARK: - SwiftUI Sheet

private enum LaunchHistoryStatusFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case succeeded = "Succeeded"
    case failed = "Failed"

    var id: String { rawValue }

    var tint: Color {
        switch self {
        case .all: return .accentColor
        case .succeeded: return .green
        case .failed: return .red
        }
    }

    func matches(_ entry: LaunchHistoryEntry) -> Bool {
        switch self {
        case .all: return true
        case .succeeded: return entry.succeeded
        case .failed: return !entry.succeeded
        }
    }
}

struct LaunchHistorySheet: View {
    @ObservedObject var vm: DirectMetalViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [LaunchHistoryEntry] = []
    @State private var hasLoaded: Bool = false
    @State private var isLoading: Bool = false
    @State private var loadGeneration: Int = 0
    @State private var searchText: String = ""
    @State private var statusFilter: LaunchHistoryStatusFilter = .all
    @State private var showClearConfirm: Bool = false
    @State private var copiedMarkdown: Bool = false

    private var succeededCount: Int {
        entries.reduce(0) { $0 + ($1.succeeded ? 1 : 0) }
    }

    private var failedCount: Int {
        entries.count - succeededCount
    }

    private var successRateText: String {
        guard !entries.isEmpty else { return "—" }
        let pct = Int(((Double(succeededCount) / Double(entries.count)) * 100.0).rounded())
        return "\(pct)% success"
    }

    private var successRateColor: Color {
        guard !entries.isEmpty else { return .secondary }
        let rate = Double(succeededCount) / Double(entries.count)
        if rate >= 0.85 { return .green }
        if rate >= 0.50 { return .orange }
        return .red
    }

    private var totalRecordedSeconds: Double {
        entries.reduce(0.0) { $0 + $1.elapsedSeconds }
    }

    private var searchMatches: [LaunchHistoryEntry] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return entries }
        return entries.filter { entry in
            entry.title.localizedCaseInsensitiveContains(q)
                || entry.exePath.localizedCaseInsensitiveContains(q)
                || entry.activeEngine.localizedCaseInsensitiveContains(q)
                || entry.prefixName.localizedCaseInsensitiveContains(q)
                || (entry.failure?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private var filteredEntries: [LaunchHistoryEntry] {
        searchMatches.filter(statusFilter.matches)
    }

    private var isFiltering: Bool {
        statusFilter != .all || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func filterCount(_ filter: LaunchHistoryStatusFilter) -> Int {
        searchMatches.reduce(0) { $0 + (filter.matches($1) ? 1 : 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                summaryHeader
                    .padding(.horizontal, 22)
                    .padding(.top, 14)

                filterToolbar
                    .padding(.horizontal, 22)

                contentArea
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footerBar
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 480, idealHeight: 560)
        .onAppear {
            if !hasLoaded && !isLoading {
                loadHistory()
            }
        }
        .alert("Clear Launch History?", isPresented: $showClearConfirm) {
            Button("Clear History", role: .destructive) {
                clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all \(entries.count) recorded launch \(entries.count == 1 ? "entry" : "entries") from launch_history.jsonl. Your game library and prefixes will not be affected.")
        }
    }

    // MARK: Title & footer

    private var titleBar: some View {
        HStack(spacing: 12) {
            Label("Launch History", systemImage: "clock.arrow.circlepath")
                .font(.title2.bold())
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("Last \(LaunchHistoryStore.maxEntries) launches")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var footerBar: some View {
        HStack(spacing: 10) {
            Button {
                copyMarkdown()
            } label: {
                Label(copiedMarkdown ? "Copied" : "Copy Markdown", systemImage: copiedMarkdown ? "checkmark" : "doc.on.doc")
            }
            .disabled(entries.isEmpty)
            .help("Copy recent launch history as a home-redacted Markdown table")

            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label("Clear History", systemImage: "trash")
            }
            .disabled(entries.isEmpty || isLoading)
            .help("Delete all recorded launch history entries")

            Spacer(minLength: 12)

            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    // MARK: Summary header & filter bar

    private var summaryHeader: some View {
        GroupBox {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(entries.count) launch\(entries.count == 1 ? "" : "es")")
                            .font(.title3.bold().monospacedDigit())

                        Text("·")
                            .foregroundStyle(.tertiary)

                        Text(successRateText)
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(successRateColor)

                        Text("·")
                            .foregroundStyle(.tertiary)

                        Text("\(LaunchHistoryEntry.formatDuration(totalRecordedSeconds)) recorded")
                            .font(.callout.weight(.medium).monospacedDigit())
                            .foregroundStyle(.primary)
                    }

                    if !entries.isEmpty {
                        Text("\(succeededCount) succeeded · \(failedCount) failed · stored at \(LaunchDiagnostics.redactHome(LaunchHistoryStore().historyURL.path))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("Every DirectMetal launch records timing, engine, Seatbelt sandbox, CoW clone time, FPS cap, MetalFX mode, and exit status.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                Button {
                    loadHistory()
                } label: {
                    if isLoading {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text("Refreshing…")
                        }
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .controlSize(.small)
                .disabled(isLoading)
                .help("Reload launch history from disk")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var filterToolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                TextField("Search title, path, engine, prefix, or failure…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !searchText.isEmpty {
                    Text("\(filteredEntries.count) of \(entries.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.18))
            )

            HStack(spacing: 6) {
                ForEach(LaunchHistoryStatusFilter.allCases) { filter in
                    let count = filterCount(filter)
                    let selected = statusFilter == filter
                    Button {
                        statusFilter = filter
                    } label: {
                        HStack(spacing: 4) {
                            Text(filter.rawValue)
                                .font(.caption.weight(.semibold))
                            Text("\(count)")
                                .font(.caption2.weight(.medium).monospacedDigit())
                                .opacity(selected ? 0.9 : 0.75)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(selected ? Color.white : (count == 0 ? Color.secondary : filter.tint))
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
        }
    }

    // MARK: Content area

    @ViewBuilder
    private var contentArea: some View {
        if isLoading && !hasLoaded {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading launch history…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 34))
                    .foregroundStyle(.tertiary)
                Text("No Launch History Yet")
                    .font(.headline)
                Text("Launch any Windows game through DirectMetal to see structured session timings, engine choices, sandbox status, and failure diagnostics here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredEntries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text("No launches match the current filter")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if isFiltering {
                    Button("Clear Filters") {
                        searchText = ""
                        statusFilter = .all
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(filteredEntries) { entry in
                        LaunchHistoryRow(entry: entry)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: Actions

    private func loadHistory() {
        loadGeneration &+= 1
        let gen = loadGeneration
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = LaunchHistoryStore().load()
            DispatchQueue.main.async {
                guard gen == self.loadGeneration else { return }
                self.entries = loaded
                self.hasLoaded = true
                self.isLoading = false
            }
        }
    }

    private func copyMarkdown() {
        let source = isFiltering ? Array(filteredEntries.prefix(50)) : Array(entries.prefix(50))
        let report = LaunchHistoryStore.markdownReport(entries: source)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(report, forType: .string)
        vm.statusMessage = "Copied \(source.count) launch history \(source.count == 1 ? "entry" : "entries") as Markdown."
        withAnimation { copiedMarkdown = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation { copiedMarkdown = false }
        }
    }

    private func clearHistory() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            LaunchHistoryStore().clear()
            DispatchQueue.main.async {
                self.entries = []
                self.searchText = ""
                self.statusFilter = .all
                self.hasLoaded = true
                self.isLoading = false
                self.vm.statusMessage = "Cleared DirectMetal launch history."
            }
        }
    }
}

// MARK: - History row subview

private struct LaunchHistoryRow: View {
    let entry: LaunchHistoryEntry

    private var engineBadge: (label: String, color: Color) {
        switch entry.activeEngine.lowercased() {
        case "arm64ec-fex":
            return ("ARM64EC+FEX", .purple)
        case "rosetta2":
            return ("Rosetta 2", .orange)
        case "not started":
            return ("Not Started", .secondary)
        default:
            return (entry.activeEngine, .blue)
        }
    }

    private var relativeTimestamp: String {
        guard let date = GameLibraryManager.isoFormatter.date(from: entry.timestampUtc) else {
            return entry.timestampUtc
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var exitCodeLabel: String {
        if let code = entry.exitCode {
            return "exit \(code)"
        }
        return entry.failure != nil ? "aborted" : "exit —"
    }

    var body: some View {
        let engine = engineBadge
        let redactedPath = LaunchDiagnostics.redactHome(entry.exePath)

        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(entry.succeeded ? Color.green : Color.red)
                .padding(.top, 2)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    historyPill(engine.label, color: engine.color)
                        .help("Active engine: \(entry.activeEngine) (requested: \(entry.requestedEngine))")

                    if entry.sandboxed {
                        HStack(spacing: 3) {
                            Image(systemName: "shield.lefthalf.filled")
                                .font(.system(size: 8.5, weight: .bold))
                            Text("Seatbelt")
                        }
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(.teal)
                        .background(Color.teal.opacity(0.15), in: Capsule())
                        .help("Executed inside macOS Seatbelt sandbox")
                    }

                    if let cowMs = entry.cowCloneMs {
                        Text(String(format: "CoW %.2f ms", cowMs))
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundStyle(.secondary)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                            .help("APFS Copy-on-Write prefix clone time")
                    }

                    if entry.fpsCap > 0 {
                        historyPill("\(entry.fpsCap) FPS", color: .indigo)
                            .help("Frame rate cap active")
                    }

                    if entry.hasActiveUpscale {
                        historyPill(entry.upscaleDisplayLabel, color: .green)
                            .help("MetalFX upscaling mode: \(entry.upscaleMode)")
                    }
                }

                HStack(spacing: 6) {
                    Label(entry.prefixName, systemImage: "folder")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.quaternary)

                    Text(redactedPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(redactedPath)
                }

                if let failure = entry.failure?.trimmingCharacters(in: .whitespacesAndNewlines), !failure.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.top, 1)
                        Text(LaunchDiagnostics.redactHome(failure))
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 3) {
                Text(entry.durationLabel)
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)

                Text(exitCodeLabel)
                    .font(.caption2.monospaced())
                    .foregroundStyle(entry.succeeded ? Color.secondary : Color.red)

                Text(relativeTimestamp)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help(entry.timestampUtc)
            }
            .frame(minWidth: 96, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (entry.succeeded ? Color.secondary : Color.red).opacity(entry.succeeded ? 0.06 : 0.045),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder((entry.succeeded ? Color.secondary : Color.red).opacity(entry.succeeded ? 0.12 : 0.22))
        )
    }

    private func historyPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}
