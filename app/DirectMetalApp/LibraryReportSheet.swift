import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// Native macOS 15 SwiftUI Library Playtime & Compatibility Report Sheet.
// Renders Table, GitHub-Flavored Markdown, and CSV views powered by LibraryReportExporter.

private enum LibraryReportViewMode: String, CaseIterable, Identifiable {
    case table = "Table"
    case markdown = "Markdown"
    case csv = "CSV"

    var id: String { rawValue }
    var exportFormat: LibraryReportFormat { self == .csv ? .csv : .markdown }
}

// MARK: - Library Report Sheet

struct LibraryReportSheet: View {
    @ObservedObject var vm: DirectMetalViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var history: [LaunchHistoryEntry] = []
    @State private var report: LibraryReport?
    @State private var selectedSort: LibraryReportSort = .mostPlayed
    @State private var viewMode: LibraryReportViewMode = .table
    @State private var hasLoaded = false
    @State private var isLoading = false
    @State private var loadGeneration = 0
    @State private var copiedFormat: LibraryReportFormat?
    @State private var copyGeneration = 0
    @State private var exportError: String?

    init(vm: DirectMetalViewModel) {
        self._vm = ObservedObject(wrappedValue: vm)
    }

    private var activeReport: LibraryReport {
        report ?? LibraryReportExporter.buildReport(library: vm.library, history: history, sort: selectedSort)
    }

    var body: some View {
        let currentReport = activeReport
        VStack(alignment: .leading, spacing: 0) {
            titleBar(currentReport)
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                summaryStrip(currentReport)
                    .padding(.horizontal, 18)
                    .padding(.top, 14)

                controlsToolbar
                    .padding(.horizontal, 18)

                if let errorMessage = exportError {
                    errorBanner(errorMessage)
                        .padding(.horizontal, 18)
                }

                contentArea(currentReport)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footerBar(currentReport)
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 520, idealHeight: 600)
        .onAppear {
            if !hasLoaded && !isLoading { loadReport() }
        }
        .onChange(of: selectedSort) { _, newSort in rebuildReport(sort: newSort) }
        .onChange(of: vm.library) { _, _ in rebuildReport(sort: selectedSort) }
    }

    // MARK: Title & Footer

    private func titleBar(_ currentReport: LibraryReport) -> some View {
        HStack(spacing: 12) {
            Label("Library Playtime & Compatibility Report", systemImage: "doc.text.magnifyingglass")
                .font(.title3.bold())
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("v\(currentReport.appVersion)").font(.caption.monospaced()).foregroundStyle(.secondary)
            Button { loadReport() } label: {
                if isLoading {
                    HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Refreshing…") }
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .controlSize(.small)
            .disabled(isLoading)
            .help("Reload launch history from disk and rebuild report")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func footerBar(_ currentReport: LibraryReport) -> some View {
        let saveFormat = viewMode.exportFormat
        return HStack(spacing: 10) {
            Button { copyReport(currentReport, format: .markdown) } label: {
                Label(copiedFormat == .markdown ? "Copied!" : "Copy Markdown",
                      systemImage: copiedFormat == .markdown ? "checkmark" : "doc.on.doc")
            }
            .disabled(isLoading && !hasLoaded)
            .help("Copy privacy-safe GitHub-Flavored Markdown report")

            Button { copyReport(currentReport, format: .csv) } label: {
                Label(copiedFormat == .csv ? "Copied!" : "Copy CSV",
                      systemImage: copiedFormat == .csv ? "checkmark" : "tablecells")
            }
            .disabled(isLoading && !hasLoaded)
            .help("Copy RFC 4180 CSV report")

            Spacer(minLength: 12)

            Button { saveReport(currentReport, format: saveFormat) } label: {
                Label("Save File…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoading && !hasLoaded)
            .help("Save DirectMetal-Library-Report.\(saveFormat.fileExtension)")

            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: KPI Summary Strip & Toolbar

    private func summaryStrip(_ currentReport: LibraryReport) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 0) {
                    kpiMetric("Total Games", "\(currentReport.totalGames)", "gamecontroller.fill", .accentColor)
                    Divider().frame(height: 28)
                    kpiMetric("Favorites", "\(currentReport.favoriteCount)", "star.fill", .yellow)
                    Divider().frame(height: 28)
                    kpiMetric("Profiled Games", "\(currentReport.profiledCount)", "checkmark.seal.fill", .green)
                    Divider().frame(height: 28)
                    kpiMetric("Total Playtime", LaunchHistoryEntry.formatDuration(currentReport.totalPlaySeconds), "clock.fill", .blue)
                    Divider().frame(height: 28)
                    kpiMetric("Total Launches", "\(currentReport.totalLaunches)", "play.circle.fill", .purple)
                }

                Divider()

                HStack(spacing: 6) {
                    Image(systemName: "lock.shield.fill").font(.caption).foregroundStyle(.teal)
                    Text("Privacy-Safe: local file paths & custom env secrets omitted")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(isLoading && !hasLoaded
                         ? "Loading launch history…"
                         : "\(history.count) history \(history.count == 1 ? "entry" : "entries") analyzed")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(4)
        }
    }

    private func kpiMetric(_ title: String, _ value: String, _ icon: String, _ tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.callout).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.headline.bold().monospacedDigit()).lineLimit(1)
                Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
    }

    private var controlsToolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text("Sort:").font(.callout).foregroundStyle(.secondary)
                Picker("Sort", selection: $selectedSort) {
                    ForEach(LibraryReportSort.allCases, id: \.self) { sort in
                        Text(Self.sortMenuLabel(for: sort)).tag(sort)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 155)
            }

            Spacer(minLength: 12)

            Picker("View Mode", selection: $viewMode) {
                ForEach(LibraryReportViewMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
            Spacer(minLength: 8)
            Button { exportError = nil } label: {
                Image(systemName: "xmark").font(.caption2.bold()).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss error")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.red.opacity(0.24)))
    }

    // MARK: Content Area

    @ViewBuilder
    private func contentArea(_ currentReport: LibraryReport) -> some View {
        if isLoading && !hasLoaded {
            VStack(spacing: 10) {
                ProgressView()
                Text("Analyzing library and launch history…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch viewMode {
            case .table:
                tableContent(currentReport)
            case .markdown:
                codePreview(
                    text: LibraryReportExporter.formatMarkdown(currentReport),
                    subtitle: "GitHub-Flavored Markdown · \(currentReport.totalGames) \(currentReport.totalGames == 1 ? "game" : "games")"
                )
            case .csv:
                codePreview(
                    text: LibraryReportExporter.formatCSV(currentReport),
                    subtitle: "RFC 4180 CSV · \(currentReport.totalGames) \(currentReport.totalGames == 1 ? "row" : "rows")"
                )
            }
        }
    }

    @ViewBuilder
    private func tableContent(_ currentReport: LibraryReport) -> some View {
        if currentReport.rows.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 34)).foregroundStyle(.tertiary)
                Text("No Games in Library").font(.headline)
                Text("Scan your library or drop a Windows .exe into DirectMetal to generate a playtime and compatibility report.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill").font(.system(size: 9)).frame(width: 16)
                    Text("Title").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Store").frame(width: 66, alignment: .leading)
                    Text("APIs").frame(width: 92, alignment: .leading)
                    Text("Profile").frame(width: 88, alignment: .leading)
                    Text("Playtime").frame(width: 62, alignment: .trailing)
                    Text("Launches").frame(width: 54, alignment: .trailing)
                    Text("Stability").frame(width: 106, alignment: .trailing)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.08))

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(currentReport.rows.enumerated()), id: \.element.id) { index, row in
                            LibraryReportTableRow(row: row, isAlternate: index % 2 == 1)
                            if index + 1 < currentReport.rows.count { Divider().opacity(0.45) }
                        }
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.secondary.opacity(0.18)))
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        }
    }

    private func codePreview(text: String, subtitle: String) -> some View {
        let lineCount = max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count - 1)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(subtitle).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(lineCount) lines").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08))
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.secondary.opacity(0.18)))
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    // MARK: Actions

    private func loadReport() {
        loadGeneration &+= 1
        let gen = loadGeneration
        let librarySnapshot = vm.library
        let sortSnapshot = selectedSort
        isLoading = true

        DispatchQueue.global(qos: .userInitiated).async {
            let loadedHistory = LaunchHistoryStore().load(limit: LaunchHistoryStore.maxEntries)
            let builtReport = LibraryReportExporter.buildReport(
                library: librarySnapshot, history: loadedHistory, sort: sortSnapshot
            )
            DispatchQueue.main.async {
                guard gen == self.loadGeneration else { return }
                self.history = loadedHistory
                self.report = builtReport
                self.hasLoaded = true
                self.isLoading = false
            }
        }
    }

    private func rebuildReport(sort: LibraryReportSort) {
        report = LibraryReportExporter.buildReport(library: vm.library, history: history, sort: sort)
    }

    private func copyReport(_ currentReport: LibraryReport, format: LibraryReportFormat) {
        let payload = format == .csv
            ? LibraryReportExporter.formatCSV(currentReport)
            : LibraryReportExporter.formatMarkdown(currentReport)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(payload, forType: .string)

        exportError = nil
        vm.statusMessage = "Copied privacy-safe library report (\(currentReport.totalGames) \(currentReport.totalGames == 1 ? "game" : "games")) as \(format.displayLabel)."

        copyGeneration &+= 1
        let gen = copyGeneration
        withAnimation(.easeInOut(duration: 0.15)) { copiedFormat = format }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard gen == copyGeneration else { return }
            withAnimation(.easeInOut(duration: 0.15)) { copiedFormat = nil }
        }
    }

    private func saveReport(_ currentReport: LibraryReport, format: LibraryReportFormat) {
        let panel = NSSavePanel()
        panel.title = "Save Library Report (\(format.displayLabel))"
        panel.message = "Export a privacy-safe \(format.displayLabel) summary of your DirectMetal game library."
        panel.nameFieldStringValue = "DirectMetal-Library-Report.\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = format == .csv
            ? [.commaSeparatedText]
            : [UTType(filenameExtension: "md") ?? .plainText]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let writtenURL = try LibraryReportExporter.writeReport(currentReport, format: format, to: url.path)
            exportError = nil
            vm.statusMessage = "Saved library \(format.displayLabel) report (\(currentReport.totalGames) \(currentReport.totalGames == 1 ? "game" : "games")) to \(writtenURL.lastPathComponent)."
        } catch {
            let msg = "Failed to save \(format.displayLabel) report: \(error)"
            exportError = msg
            vm.statusMessage = msg
        }
    }

    private static func sortMenuLabel(for sort: LibraryReportSort) -> String {
        switch sort {
        case .mostPlayed: return "Most Played"
        case .title: return "Title"
        case .recent: return "Recent"
        case .favoritesFirst: return "Favorites First"
        }
    }
}

// MARK: - Table Row Subview

private struct LibraryReportTableRow: View {
    let row: LibraryReportRow
    let isAlternate: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: row.favorite ? "star.fill" : "star")
                .font(.system(size: 11))
                .foregroundStyle(row.favorite ? Color.yellow : Color.secondary.opacity(0.25))
                .frame(width: 16)
                .help(row.favorite ? "Favorite game" : "Not favorited")

            Text(row.title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(titleTooltip)

            storeBadge.frame(width: 66, alignment: .leading)
            apiBadgesView.frame(width: 92, alignment: .leading)
            profileBadgeView.frame(width: 88, alignment: .leading)

            Text(row.playtimeFormatted)
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(row.totalPlaySeconds > 0 ? .primary : .tertiary)
                .lineLimit(1)
                .frame(width: 62, alignment: .trailing)

            Text("\(row.playCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(row.playCount > 0 ? .primary : .tertiary)
                .lineLimit(1)
                .frame(width: 54, alignment: .trailing)

            stabilityCapsule.frame(width: 106, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isAlternate ? Color.secondary.opacity(0.045) : Color.clear)
    }

    private var titleTooltip: String {
        var details = "\(row.title) · \(row.architecture) · \(row.engine) · \(row.perfProfile)"
        if row.fpsCap > 0 { details += " · \(row.fpsCap) FPS" }
        if row.sandboxed { details += " · Seatbelt" }
        return details
    }

    private var storeBadge: some View {
        let info = StorePill.info(row.storeSource)
        let label = info?.label ?? (row.storeSource.lowercased() == "standalone" ? "Standalone" : row.storeSource)
        return Text(label)
            .font(.system(size: 9.5, weight: info == nil ? .semibold : .bold, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(info == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
            .background(info?.color ?? Color.secondary.opacity(0.14), in: Capsule())
    }

    @ViewBuilder
    private var apiBadgesView: some View {
        let badges = Self.apiBadges(from: row.detectedAPIs)
        if badges.isEmpty {
            Text("—").font(.caption).foregroundStyle(.tertiary)
        } else {
            HStack(spacing: 4) {
                ForEach(Array(badges.prefix(2))) { BadgeView(badge: $0) }
                if badges.count > 2 {
                    Text("+\(badges.count - 2)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .help(row.detectedAPIs.joined(separator: ", "))
        }
    }

    @ViewBuilder
    private var profileBadgeView: some View {
        if let profileID = row.profileID {
            HStack(spacing: 3) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 8.5))
                Text(profileID).lineLimit(1).truncationMode(.tail)
            }
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(.indigo)
            .background(Color.indigo.opacity(0.14), in: Capsule())
            .help("Community profile: \(profileID)")
        } else {
            Text("—").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var stabilityCapsule: some View {
        let color = stabilityColor
        let tooltip = row.successRatePercent.flatMap { $0.isFinite ? $0 : nil }.map { rate in
            "\(row.stabilityTier) (\(String(format: "%.1f%%", min(100.0, max(0.0, rate)))) launch success)"
        } ?? row.stabilityTier
        return Text(row.stabilityTier)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
            .help(tooltip)
    }

    private var stabilityColor: Color {
        switch row.stabilityTier {
        case GameStabilityTier.rockSolid.displayLabel: return .green
        case GameStabilityTier.mostlyStable.displayLabel: return .blue
        case GameStabilityTier.needsAttention.displayLabel:
            if let rate = row.successRatePercent, rate.isFinite, rate < 50.0 { return .red }
            return .orange
        default: return .gray
        }
    }

    private static func apiBadges(from apis: [String]) -> [LauncherBadge] {
        var out: [LauncherBadge] = []
        var seen = Set<String>()
        for raw in apis {
            let badge: LauncherBadge = switch raw.uppercased() {
            case "D3D12", "DX12": LauncherBadge(text: "DX12", color: .purple)
            case "D3D11", "DX11": LauncherBadge(text: "DX11", color: .blue)
            case "D3D10", "DX10": LauncherBadge(text: "DX10", color: .teal)
            case "D3D9", "DX9": LauncherBadge(text: "DX9", color: .orange)
            case "VULKAN": LauncherBadge(text: "Vulkan", color: .red)
            case "OPENGL": LauncherBadge(text: "OpenGL", color: .cyan)
            default: LauncherBadge(text: raw, color: .secondary)
            }
            if seen.insert(badge.text).inserted { out.append(badge) }
        }
        return out
    }
}
