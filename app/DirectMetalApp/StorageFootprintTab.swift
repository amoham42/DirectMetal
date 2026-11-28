import AppKit
import Darwin
import Foundation
import SwiftUI

// Storage Footprint & Space Reclamation tab for SystemHealthSheet.
// Audits DirectMetal's 6 managed storage categories off the main thread, renders a
// proportional stacked bar with legend pills, provides 1-click space reclamation cards
// with symlink-safe quarantine removal, Finder reveal buttons, and Markdown audit export.

// MARK: - Supporting Models & Visual Style

private struct StorageFootprintBanner: Equatable {
    let message: String
    let isError: Bool
}

private struct StorageCategoryVisualStyle {
    let icon: String
    let color: Color
    let singular: String
    let plural: String

    static func style(for id: String) -> StorageCategoryVisualStyle {
        switch id {
        case "prefixes": return .init(icon: "internaldrive.fill", color: .blue, singular: "prefix", plural: "prefixes")
        case "shader_caches": return .init(icon: "square.stack.3d.up.fill", color: .purple, singular: "entry", plural: "entries")
        case "quarantined_shaders": return .init(icon: "bandage.fill", color: .orange, singular: "file", plural: "files")
        case "save_backups": return .init(icon: "archivebox.fill", color: .green, singular: "file", plural: "files")
        case "user_runtimes": return .init(icon: "shippingbox.fill", color: .teal, singular: "runtime", plural: "runtimes")
        case "metadata": return .init(icon: "doc.text.fill", color: .indigo, singular: "file", plural: "files")
        default: return .init(icon: "folder.fill", color: .secondary, singular: "item", plural: "items")
        }
    }

    func itemCountLabel(_ count: Int) -> String { "\(count) \(count == 1 ? singular : plural)" }
}

// MARK: - Symlink-Safe Directory & Quarantine Helpers

private enum StorageQuarantineError: Error, LocalizedError {
    case rootNotDirectory(String)
    case symlinkRefused(String)
    case notDirectory(String)
    case inspectFailed(String)

    var errorDescription: String? {
        switch self {
        case .rootNotDirectory(let path):
            return "Refused to touch quarantine because shader cache root is not a real directory: \(LaunchDiagnostics.redactHome(path))"
        case .symlinkRefused(let path):
            return "Refused to delete \(LaunchDiagnostics.redactHome(path)) because it is a symbolic link, not a directory."
        case .notDirectory(let path):
            return "Refused to delete \(LaunchDiagnostics.redactHome(path)) because it is not a directory."
        case .inspectFailed(let reason):
            return "Could not inspect shader quarantine directory: \(reason)"
        }
    }
}

private enum StorageDirectoryInspector {
    /// Returns `true` only when `path` exists and is a real directory (never follows symlinks).
    static func isRealDirectory(atPath path: String) -> Bool {
        var st = Darwin.stat()
        guard Darwin.lstat(trimTrailingSlashes(path), &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// Safely deletes ONLY `<shaderCacheRoot>/_quarantine` after verifying via `lstat(2)` that
    /// both the shader cache root and `_quarantine` itself are real directories (not symlinks).
    static func removeQuarantineDirectory() throws -> (removedFiles: Int, reclaimedBytes: UInt64, existed: Bool) {
        let cacheRoot = RuntimeLauncher.shaderCacheRoot().standardizedFileURL
        let rootPath = trimTrailingSlashes(cacheRoot.path)
        var rootStat = Darwin.stat()
        if Darwin.lstat(rootPath, &rootStat) != 0 {
            if errno == ENOENT { return (0, 0, false) }
            throw StorageQuarantineError.inspectFailed(String(cString: strerror(errno)))
        }
        guard (rootStat.st_mode & S_IFMT) == S_IFDIR else { throw StorageQuarantineError.rootNotDirectory(rootPath) }

        let quarantineName = ShaderCacheVerifier.quarantineFolderName
        let quarantineURL = cacheRoot.appendingPathComponent(quarantineName, isDirectory: true).standardizedFileURL
        let quarantinePath = trimTrailingSlashes(quarantineURL.path)
        guard quarantineURL.lastPathComponent == quarantineName,
              trimTrailingSlashes(quarantineURL.deletingLastPathComponent().standardizedFileURL.path) == rootPath else {
            throw StorageQuarantineError.notDirectory(quarantinePath)
        }

        var st = Darwin.stat()
        if Darwin.lstat(quarantinePath, &st) != 0 {
            if errno == ENOENT { return (0, 0, false) }
            throw StorageQuarantineError.inspectFailed(String(cString: strerror(errno)))
        }
        let fileType = st.st_mode & S_IFMT
        if fileType == S_IFLNK { throw StorageQuarantineError.symlinkRefused(quarantinePath) }
        guard fileType == S_IFDIR else { throw StorageQuarantineError.notDirectory(quarantinePath) }

        let measured = measureRegularFiles(in: quarantineURL)
        try FileManager.default.removeItem(at: quarantineURL)
        return (measured.fileCount, measured.totalBytes, true)
    }

    private static func measureRegularFiles(in directory: URL) -> (fileCount: Int, totalBytes: UInt64) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: []
        ) else { return (0, 0) }
        var fileCount = 0
        var totalBytes: UInt64 = 0
        for case let entryURL as URL in enumerator {
            var st = Darwin.stat()
            guard Darwin.lstat(trimTrailingSlashes(entryURL.path), &st) == 0,
                  (st.st_mode & S_IFMT) == S_IFREG,
                  entryURL.lastPathComponent != ".DS_Store" else { continue }
            fileCount += 1
            if st.st_size > 0 { totalBytes &+= UInt64(st.st_size) }
        }
        return (fileCount, totalBytes)
    }

    private static func trimTrailingSlashes(_ path: String) -> String {
        var out = path
        while out.count > 1 && out.hasSuffix("/") { out.removeLast() }
        return out
    }
}

// MARK: - Storage Footprint Tab

struct StorageFootprintTab: View {
    @ObservedObject var vm: DirectMetalViewModel
    @Binding var report: StorageFootprintReport?
    @Binding var isLoading: Bool

    @State private var copiedMarkdown: Bool = false
    @State private var activeActionID: String? = nil
    @State private var banner: StorageFootprintBanner? = nil

    init(vm: DirectMetalViewModel, report: Binding<StorageFootprintReport?>, isLoading: Binding<Bool>) {
        self._vm = ObservedObject(wrappedValue: vm)
        self._report = report
        self._isLoading = isLoading
    }

    private var isBusy: Bool { isLoading || activeActionID != nil }

    var body: some View {
        Group {
            if isLoading && report == nil {
                ProgressView("Auditing DirectMetal storage footprint…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let current = report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        summaryHeaderCard(current)
                        if let notice = banner { statusBannerView(notice) }
                        if !current.suggestions.isEmpty { reclamationSection(current.suggestions) }
                        categoryBreakdownSection(current)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "internaldrive").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("Storage Footprint Audit").font(.headline)
                    Button { refreshReport() } label: { Label("Audit Storage", systemImage: "arrow.clockwise") }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if report == nil && !isLoading { refreshReport() }
        }
    }

    // MARK: Summary Header Card

    private func summaryHeaderCard(_ current: StorageFootprintReport) -> some View {
        let hasReclaimable = current.totalReclaimableBytes > 0
        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    HStack(alignment: .top, spacing: 22) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Total Footprint").font(.caption).foregroundStyle(.secondary)
                            Text(StorageFootprintAnalyzer.formatBytes(current.totalBytes))
                                .font(.title3.bold().monospacedDigit())
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Reclaimable").font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 7) {
                                Text(StorageFootprintAnalyzer.formatBytes(current.totalReclaimableBytes))
                                    .font(.title3.bold().monospacedDigit())
                                    .foregroundStyle(hasReclaimable ? .orange : .primary)
                                if hasReclaimable {
                                    StoragePillBadge(text: reclaimablePercentLabel(current), tint: .orange)
                                } else {
                                    Label("Clean", systemImage: "checkmark.circle.fill")
                                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .foregroundStyle(.green)
                                        .background(Color.green.opacity(0.14), in: Capsule())
                                }
                            }
                        }
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 8) {
                        Button { refreshReport() } label: {
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
                        .disabled(isBusy)
                        .help("Re-audit all 6 managed DirectMetal storage categories")

                        Button { copyMarkdownAudit(current) } label: {
                            Label(
                                copiedMarkdown ? "Copied!" : "Copy Markdown Audit",
                                systemImage: copiedMarkdown ? "checkmark" : "doc.on.doc"
                            )
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .disabled(isLoading)
                        .help("Copy a GitHub-ready Markdown storage audit with your home path redacted to ~")
                    }
                }

                StorageStackedBarView(categories: current.categories, totalBytes: current.totalBytes)
            }
            .padding(6)
        }
    }

    // MARK: Status Banner & Sections

    private func statusBannerView(_ notice: StorageFootprintBanner) -> some View {
        let tint: Color = notice.isError ? .orange : .green
        return HStack(spacing: 8) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(tint)
            Text(notice.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { banner = nil } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint.opacity(0.3)))
    }

    private func reclamationSection(_ suggestions: [StorageReclamationSuggestion]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("Actionable Reclamation", systemImage: "sparkles").font(.callout.weight(.semibold))
                StoragePillBadge(text: "\(suggestions.count)", tint: .orange)
            }
            ForEach(suggestions) { suggestion in
                StorageReclamationCard(
                    suggestion: suggestion,
                    isRunningThisAction: activeActionID == suggestion.id,
                    isAnyActionBusy: isBusy,
                    onRunAction: { runReclamation(for: suggestion) }
                )
            }
        }
    }

    private func categoryBreakdownSection(_ current: StorageFootprintReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Storage Categories", systemImage: "chart.bar.doc.horizontal").font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                Text("Audited \(current.generatedAtUtc)")
                    .font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
            }
            ForEach(current.categories) { category in
                StorageCategoryRow(category: category, onRevealInFinder: { revealInFinder(path: category.path) })
            }
        }
    }

    // MARK: Actions

    private func refreshReport() {
        guard !isLoading else { return }
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let fresh = StorageFootprintAnalyzer.analyze()
            DispatchQueue.main.async {
                self.report = fresh
                self.isLoading = false
            }
        }
    }

    private func copyMarkdownAudit(_ current: StorageFootprintReport) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(StorageFootprintAnalyzer.formatMarkdown(current), forType: .string)
        vm.statusMessage = "Copied storage footprint Markdown audit (home path redacted to ~)."
        withAnimation { copiedMarkdown = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation { copiedMarkdown = false }
        }
    }

    private func revealInFinder(path: String) {
        guard StorageDirectoryInspector.isRealDirectory(atPath: path) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    private func runReclamation(for suggestion: StorageReclamationSuggestion) {
        guard !isBusy else { return }
        activeActionID = suggestion.id
        banner = nil

        switch suggestion.id {
        case "shader_caches":
            runBackgroundReclamation(errorPrefix: "Failed to prune stale shader caches") {
                let res = try ShaderCacheManager.pruneStaleCaches(dryRun: false)
                let count = res.removedEntries.count
                let bytes = StorageFootprintAnalyzer.formatBytes(res.reclaimedBytes)
                return count > 0
                    ? "Pruned \(count) stale shader cache \(count == 1 ? "entry" : "entries") (\(res.reclaimedFiles) \(res.reclaimedFiles == 1 ? "file" : "files")), reclaiming \(bytes)."
                    : "No stale shader caches needed pruning (0 B reclaimed)."
            }

        case "prefixes":
            let referencedNames = Set(vm.library.map(\.launchPrefixName))
            runBackgroundReclamation(errorPrefix: "Failed to prune orphaned prefixes") {
                let res = try PrefixManager().pruneOrphanedPrefixes(referencedNames: referencedNames, dryRun: false)
                let count = res.removedPrefixes.count
                let bytes = StorageFootprintAnalyzer.formatBytes(res.reclaimedBytes)
                let runningNote = res.skippedRunningPrefixes.isEmpty ? "" : " (\(res.skippedRunningPrefixes.count) running preserved)"
                return count > 0
                    ? "Pruned \(count) orphaned Wine \(count == 1 ? "prefix" : "prefixes"), reclaiming \(bytes)\(runningNote)."
                    : "No orphaned Wine prefixes were pruned (0 B reclaimed)\(runningNote)."
            }

        case "quarantined_shaders":
            runBackgroundReclamation(errorPrefix: "Failed to delete quarantined shaders") {
                let res = try StorageDirectoryInspector.removeQuarantineDirectory()
                let bytes = StorageFootprintAnalyzer.formatBytes(res.reclaimedBytes)
                return res.existed
                    ? "Deleted _quarantine (\(res.removedFiles) \(res.removedFiles == 1 ? "file" : "files")), reclaiming \(bytes)."
                    : "Quarantine directory was already empty (0 B reclaimed)."
            }

        default:
            activeActionID = nil
        }
    }

    private func runBackgroundReclamation(errorPrefix: String, work: @escaping () throws -> String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let message: String
            let isError: Bool
            do {
                message = try work()
                isError = false
            } catch {
                message = "\(errorPrefix): \(error.localizedDescription)"
                isError = true
            }
            let updated = StorageFootprintAnalyzer.analyze()
            DispatchQueue.main.async {
                self.report = updated
                self.activeActionID = nil
                self.banner = StorageFootprintBanner(message: message, isError: isError)
                self.vm.statusMessage = message
                self.vm.refreshPrefixes()
                self.vm.refreshShaderCache()
            }
        }
    }

    private func reclaimablePercentLabel(_ current: StorageFootprintReport) -> String {
        guard current.totalBytes > 0 else { return "0%" }
        let pct = min(100.0, Double(current.totalReclaimableBytes) * 100.0 / Double(current.totalBytes))
        return String(format: "%.1f%%", locale: Locale(identifier: "en_US_POSIX"), pct)
    }
}

// MARK: - Stacked Bar & Legend Subview

private struct StorageStackedBarView: View {
    let categories: [StorageCategoryBreakdown]
    let totalBytes: UInt64

    var body: some View {
        let items = categories.filter { $0.totalBytes > 0 }
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                if totalBytes > 0 && !items.isEmpty {
                    let spacing: CGFloat = items.count > 1 ? 2 : 0
                    let widths = segmentWidths(for: items, totalWidth: geo.size.width, spacing: spacing)
                    HStack(spacing: spacing) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, category in
                            let style = StorageCategoryVisualStyle.style(for: category.id)
                            let pct = Double(category.totalBytes) * 100.0 / Double(totalBytes)
                            let pctText = String(format: "%.1f%%", locale: Locale(identifier: "en_US_POSIX"), pct)
                            Rectangle()
                                .fill(style.color.gradient)
                                .frame(width: widths[index], height: 10)
                                .help("\(category.label): \(StorageFootprintAnalyzer.formatBytes(category.totalBytes)) (\(pctText))")
                        }
                    }
                    .clipShape(Capsule())
                } else {
                    Capsule().fill(Color.secondary.opacity(0.14)).frame(width: geo.size.width, height: 10)
                }
            }
            .frame(height: 10)

            if items.isEmpty {
                Text("No managed DirectMetal storage on disk yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                StorageFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(items) { category in
                        let style = StorageCategoryVisualStyle.style(for: category.id)
                        HStack(spacing: 5) {
                            Circle().fill(style.color).frame(width: 7, height: 7)
                            Text(category.label).font(.caption2.weight(.medium))
                            Text(StorageFootprintAnalyzer.formatBytes(category.totalBytes))
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(style.color.opacity(0.10), in: Capsule())
                        .overlay(Capsule().strokeBorder(style.color.opacity(0.22)))
                    }
                }
            }
        }
    }

    private func segmentWidths(for items: [StorageCategoryBreakdown], totalWidth: CGFloat, spacing: CGFloat) -> [CGFloat] {
        guard !items.isEmpty, totalWidth > 0 else { return [] }
        let usable = max(0, totalWidth - spacing * CGFloat(max(0, items.count - 1)))
        let sumBytes = Double(items.reduce(UInt64(0)) { $0 &+ $1.totalBytes })
        guard sumBytes > 0 else { return Array(repeating: usable / CGFloat(items.count), count: items.count) }

        let minWidth: CGFloat = usable >= CGFloat(items.count) * 6 ? 4 : 0
        var widths = items.map { max(minWidth, usable * CGFloat(Double($0.totalBytes) / sumBytes)) }
        let sum = widths.reduce(0, +)
        if sum > usable && sum > 0 {
            let excess = sum - usable
            let shrinkable = widths.reduce(CGFloat(0)) { $0 + max(0, $1 - minWidth) }
            widths = shrinkable > 0
                ? widths.map { $0 - excess * (max(0, $0 - minWidth) / shrinkable) }
                : widths.map { $0 * (usable / sum) }
        }
        return widths
    }
}

// MARK: - Reusable Badges, Reclamation Card & Category Row

private struct StoragePillBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

private struct StorageIconBox: View {
    let icon: String
    let tint: Color

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct StorageReclamationCard: View {
    let suggestion: StorageReclamationSuggestion
    let isRunningThisAction: Bool
    let isAnyActionBusy: Bool
    let onRunAction: () -> Void

    private var actionConfig: (label: String, busyLabel: String)? {
        switch suggestion.id {
        case "shader_caches": return ("Prune Stale Caches", "Pruning…")
        case "prefixes": return ("Prune Orphaned", "Pruning…")
        case "quarantined_shaders": return ("Delete Quarantine", "Deleting…")
        default: return nil
        }
    }

    var body: some View {
        let style = StorageCategoryVisualStyle.style(for: suggestion.id)
        HStack(alignment: .center, spacing: 12) {
            StorageIconBox(icon: style.icon, tint: .orange)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(suggestion.title).font(.callout.weight(.semibold))
                    StoragePillBadge(text: StorageFootprintAnalyzer.formatBytes(suggestion.reclaimableBytes), tint: .orange)
                }
                Text(LaunchDiagnostics.redactHome(suggestion.detail))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Spacer(minLength: 10)
            if let action = actionConfig {
                Button(action: onRunAction) {
                    if isRunningThisAction {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text(action.busyLabel)
                        }
                    } else {
                        Label(action.label, systemImage: "trash")
                    }
                }
                .controlSize(.small).buttonStyle(.borderedProminent).tint(.orange)
                .disabled(isAnyActionBusy)
                .help(LaunchDiagnostics.redactHome(suggestion.commandHint))
            } else {
                Text(LaunchDiagnostics.redactHome(suggestion.commandHint))
                    .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.24)))
    }
}

private struct StorageCategoryRow: View {
    let category: StorageCategoryBreakdown
    let onRevealInFinder: () -> Void

    var body: some View {
        let style = StorageCategoryVisualStyle.style(for: category.id)
        let redactedPath = LaunchDiagnostics.redactHome(category.path)
        let directoryExists = StorageDirectoryInspector.isRealDirectory(atPath: category.path)

        HStack(alignment: .center, spacing: 12) {
            StorageIconBox(icon: style.icon, tint: style.color)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(category.label).font(.callout.weight(.semibold))
                    StoragePillBadge(text: style.itemCountLabel(category.itemCount), tint: .secondary)
                }
                Text(redactedPath)
                    .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                if !category.note.isEmpty {
                    Text(LaunchDiagnostics.redactHome(category.note))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 2) {
                Text(StorageFootprintAnalyzer.formatBytes(category.totalBytes))
                    .font(.callout.weight(.semibold).monospacedDigit())
                if category.reclaimableBytes > 0 {
                    Text("\(StorageFootprintAnalyzer.formatBytes(category.reclaimableBytes)) reclaimable")
                        .font(.caption2.weight(.medium).monospacedDigit()).foregroundStyle(.orange)
                }
            }
            Button(action: onRevealInFinder) {
                Image(systemName: "folder").font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(directoryExists ? Color.secondary : Color.secondary.opacity(0.35))
            .disabled(!directoryExists)
            .help(directoryExists ? "Reveal \(redactedPath) in Finder" : "Directory does not exist on disk yet")
            .accessibilityLabel("Reveal \(category.label) in Finder")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.secondary.opacity(0.12)))
    }
}

// MARK: - Wrapping Flow Layout for Legend Pills

private struct StorageFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxRow: CGFloat = 0
        for subview in subviews {
            let s = subview.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxWidth { y += rowH + verticalSpacing; x = 0; rowH = 0 }
            x += s.width; maxRow = max(maxRow, x); x += horizontalSpacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: proposal.width ?? maxRow, height: subviews.isEmpty ? 0 : y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for subview in subviews {
            let s = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += rowH + verticalSpacing; x = bounds.minX; rowH = 0 }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(s))
            x += s.width + horizontalSpacing; rowH = max(rowH, s.height)
        }
    }
}
