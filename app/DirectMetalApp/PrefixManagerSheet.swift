import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// APFS Prefix Manager & Storage Inspector Sheet.
// Inspects managed Wine prefixes asynchronously off the main thread, reports logical
// footprint vs. APFS Copy-on-Write block sharing, and offers Finder reveal, CoW reset,
// and deletion with confirmation alerts.

// MARK: - Supporting models

private struct PrefixStatusBanner: Equatable {
    let message: String
    let isError: Bool
}

private enum PrefixDisplayFormat {
    static func logicalSize(_ bytes: UInt64) -> String {
        let mib = Double(bytes) / (1024.0 * 1024.0)
        if mib >= 1024.0 {
            return String(format: "%.2f GiB", mib / 1024.0)
        }
        if mib >= 10.0 {
            return String(format: "%.1f MiB", mib)
        }
        return String(format: "%.2f MiB", mib)
    }

    static func cowTime(_ ms: Double) -> String {
        String(format: "CoW %.2f ms", ms)
    }

    static func fileCount(_ count: Int) -> String {
        let formatted = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
        return "\(formatted) file\(count == 1 ? "" : "s")"
    }

    static func executableBasename(_ gameExe: String?) -> String? {
        guard let raw = gameExe?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let name = URL(fileURLWithPath: raw).lastPathComponent
        return name.isEmpty ? nil : name
    }

    static func dxApiPill(_ raw: String?) -> (label: String, color: Color)? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        switch trimmed.lowercased() {
        case "d3d12", "dx12":
            return ("DX12", .purple)
        case "d3d11", "dx11":
            return ("DX11", .blue)
        case "d3d10", "dx10":
            return ("DX10", .teal)
        case "d3d9", "dx9":
            return ("DX9", .orange)
        case "vulkan", "vk":
            return ("Vulkan", .red)
        case "opengl", "gl":
            return ("OpenGL", .cyan)
        case "auto":
            return ("Auto", .secondary)
        default:
            return (trimmed.uppercased(), .indigo)
        }
    }
}

// MARK: - Sheet view

struct PrefixManagerSheet: View {
    @ObservedObject var vm: DirectMetalViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var stats: [PrefixManager.PrefixStat] = []
    @State private var hasLoaded: Bool = false
    @State private var isLoading: Bool = false
    @State private var loadGeneration: Int = 0
    @State private var busyPrefixName: String?
    @State private var busyActionLabel: String = ""
    @State private var searchText: String = ""
    @State private var statusBanner: PrefixStatusBanner?
    @State private var pendingReset: PrefixManager.PrefixStat?
    @State private var pendingDelete: PrefixManager.PrefixStat?
    @State private var showPruneConfirm: Bool = false

    private var isMutating: Bool { busyPrefixName != nil }

    private var referencedPrefixNames: Set<String> {
        var names = Set(vm.library.map { $0.launchPrefixName.replacingOccurrences(of: "/", with: "_") })
        names.insert("default")
        return names
    }

    private var orphanedStats: [PrefixManager.PrefixStat] {
        let refs = referencedPrefixNames
        return stats.filter { !refs.contains($0.name) }
    }

    private var orphanedLogicalBytes: UInt64 {
        orphanedStats.reduce(0) { $0 &+ $1.sizeBytes }
    }

    private var totalLogicalBytes: UInt64 {
        stats.reduce(0) { $0 &+ $1.sizeBytes }
    }

    private var totalFileCount: Int {
        stats.reduce(0) { $0 + $1.fileCount }
    }

    private var showSearchField: Bool {
        stats.count >= 4
    }

    private var filteredStats: [PrefixManager.PrefixStat] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard showSearchField, !query.isEmpty else { return stats }
        return stats.filter { stat in
            if stat.name.localizedCaseInsensitiveContains(query) { return true }
            if let exe = stat.gameExe, exe.localizedCaseInsensitiveContains(query) { return true }
            if let api = stat.dxApi, api.localizedCaseInsensitiveContains(query) { return true }
            if let pill = PrefixDisplayFormat.dxApiPill(stat.dxApi),
               pill.label.localizedCaseInsensitiveContains(query) { return true }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                summaryHeader
                    .padding(.horizontal, 22)
                    .padding(.top, 14)

                if let banner = statusBanner {
                    statusBannerView(banner)
                        .padding(.horizontal, 22)
                }

                if showSearchField {
                    searchBar
                        .padding(.horizontal, 22)
                }

                contentArea
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footerBar
        }
        .frame(minWidth: 660, idealWidth: 740, minHeight: 480, idealHeight: 560)
        .onAppear {
            if !hasLoaded && !isLoading {
                loadStats()
            }
        }
        .alert(
            "Reset Prefix “\(pendingReset?.name ?? "")”?",
            isPresented: Binding(
                get: { pendingReset != nil },
                set: { if !$0 { pendingReset = nil } }
            ),
            presenting: pendingReset
        ) { stat in
            Button("Reset Prefix", role: .destructive) {
                resetPrefix(stat)
            }
            Button("Cancel", role: .cancel) {}
        } message: { stat in
            Text("This wipes “\(stat.name)” (\(PrefixDisplayFormat.logicalSize(stat.sizeBytes))) and re-clones a clean copy from the golden base prefix via APFS Copy-on-Write. Any Windows registry entries or local save files inside this prefix will be lost.")
        }
        .alert(
            "Delete Prefix “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { stat in
            Button("Delete Prefix", role: .destructive) {
                deletePrefix(stat)
            }
            Button("Cancel", role: .cancel) {}
        } message: { stat in
            Text("This permanently removes “\(stat.name)” (\(PrefixDisplayFormat.logicalSize(stat.sizeBytes)), \(PrefixDisplayFormat.fileCount(stat.fileCount))) from disk, including any game saves or configuration stored inside its drive_c folder. Your game executable stays untouched.")
        }
        .alert("Prune \(orphanedStats.count) Orphaned Prefix\(orphanedStats.count == 1 ? "" : "es")?", isPresented: $showPruneConfirm) {
            Button("Prune Orphaned", role: .destructive) {
                pruneOrphanedPrefixes()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes \(orphanedStats.count) prefix\(orphanedStats.count == 1 ? "" : "es") (\(PrefixDisplayFormat.logicalSize(orphanedLogicalBytes)) logical) not referenced by any game in your library. The “default” prefix and any prefix with a running wineserver are always preserved.")
        }
    }

    // MARK: Title & footer

    private var titleBar: some View {
        HStack(spacing: 12) {
            Label("APFS Prefix Manager & Storage Inspector", systemImage: "internaldrive")
                .font(.title2.bold())
                .lineLimit(1)
            Spacer(minLength: 8)
            if vm.isRunning {
                Label("Game Running", systemImage: "play.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(Color.orange.opacity(0.14), in: Capsule())
                    .help("Reset and Delete are disabled while a game is running.")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var footerBar: some View {
        HStack(spacing: 10) {
            Text(LaunchDiagnostics.redactHome(PrefixManager().prefixRoot.path))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 12)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isMutating)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    // MARK: Summary header, banner & search

    private var summaryHeader: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(stats.count) managed prefix\(stats.count == 1 ? "" : "es")")
                                .font(.title3.bold().monospacedDigit())
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text("\(PrefixDisplayFormat.logicalSize(totalLogicalBytes)) logical")
                                .font(.callout.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.primary)
                            if totalFileCount > 0 {
                                Text("(\(PrefixDisplayFormat.fileCount(totalFileCount)))")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Label(
                            "APFS Copy-on-Write shares base blocks on disk — actual physical footprint is much smaller than logical size.",
                            systemImage: "square.on.square"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 8) {
                        Button {
                            loadStats()
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
                        .disabled(isLoading || isMutating)
                        .help("Rescan managed APFS prefixes and recompute logical sizes")

                        if !orphanedStats.isEmpty {
                            Button(role: .destructive) {
                                showPruneConfirm = true
                            } label: {
                                Label("Prune Orphaned (\(orphanedStats.count))", systemImage: "trash")
                            }
                            .controlSize(.small)
                            .disabled(vm.isRunning || isLoading || isMutating)
                            .help("Remove prefixes not referenced by any game in your library (preserves default and active prefixes)")
                        }

                        Button {
                            revealPrefixesFolder()
                        } label: {
                            Label("Reveal Prefixes Folder", systemImage: "folder")
                        }
                        .controlSize(.small)
                        .help("Open \(PrefixManager().prefixRoot.path) in Finder")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func statusBannerView(_ banner: PrefixStatusBanner) -> some View {
        HStack(spacing: 8) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.isError ? Color.orange : Color.green)
            Text(banner.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                statusBanner = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss status message")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            (banner.isError ? Color.orange : Color.green).opacity(0.12),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder((banner.isError ? Color.orange : Color.green).opacity(0.3))
        )
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.callout)
            TextField("Filter prefixes by name, executable, or DX API…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)
            if !searchText.isEmpty {
                Text("\(filteredStats.count) of \(stats.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18))
        )
    }

    // MARK: Content list

    @ViewBuilder
    private var contentArea: some View {
        if isLoading && !hasLoaded {
            VStack(spacing: 10) {
                ProgressView()
                Text("Inspecting managed APFS prefixes…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if stats.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 34))
                    .foregroundStyle(.tertiary)
                Text("No Managed Prefixes Yet")
                    .font(.headline)
                Text("DirectMetal clones an isolated APFS Copy-on-Write prefix automatically in under a millisecond the first time you launch a Windows game.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredStats.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text("No prefixes match “\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Clear Filter") {
                    searchText = ""
                }
                .buttonStyle(.link)
                .font(.callout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    let refs = referencedPrefixNames
                    ForEach(filteredStats) { stat in
                        PrefixStatRow(
                            stat: stat,
                            isOrphaned: !refs.contains(stat.name),
                            isBusy: busyPrefixName == stat.name,
                            busyLabel: busyActionLabel,
                            mutationsDisabled: vm.isRunning || isMutating,
                            gameRunning: vm.isRunning,
                            onReveal: { revealPrefixInFinder(stat) },
                            onExportSaves: { exportPrefixSaves(stat) },
                            onImportSaves: { importPrefixSaves(stat) },
                            onReset: { pendingReset = stat },
                            onDelete: { pendingDelete = stat }
                        )
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: Actions

    private func loadStats() {
        loadGeneration &+= 1
        let gen = loadGeneration
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = PrefixManager().prefixStats()
            DispatchQueue.main.async {
                guard gen == self.loadGeneration else { return }
                self.stats = loaded
                self.hasLoaded = true
                self.isLoading = false
                if loaded.count < 4 {
                    self.searchText = ""
                }
                self.vm.refreshPrefixes()
            }
        }
    }

    private func revealPrefixesFolder() {
        let root = PrefixManager().prefixRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private func revealPrefixInFinder(_ stat: PrefixManager.PrefixStat) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: stat.path)])
    }

    private func exportPrefixSaves(_ stat: PrefixManager.PrefixStat) {
        guard !vm.isRunning, busyPrefixName == nil else { return }
        let panel = NSSavePanel()
        panel.title = "Export Save Data — \(stat.name)"
        panel.message = "Save a SHA-256 verified .tar.gz archive of Windows Documents, Saved Games & AppData saves from prefix “\(stat.name)”."
        panel.allowedContentTypes = [UTType.gzip]
        panel.nameFieldStringValue = "\(stat.name)-saves.tar.gz"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destURL = panel.url else { return }

        busyPrefixName = stat.name
        busyActionLabel = "Exporting saves…"
        statusBanner = nil
        let name = stat.name
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let res = try SaveBackupManager.exportSaves(prefixName: name, to: destURL.path)
                let msg = "Backed up \(res.fileCount) save file\(res.fileCount == 1 ? "" : "s") from “\(name)” to \(destURL.lastPathComponent)."
                DispatchQueue.main.async {
                    self.busyPrefixName = nil
                    self.busyActionLabel = ""
                    self.statusBanner = PrefixStatusBanner(message: msg, isError: false)
                    self.vm.statusMessage = msg
                }
            } catch {
                let msg = "Save backup failed for “\(name)”: \(error)"
                DispatchQueue.main.async {
                    self.busyPrefixName = nil
                    self.busyActionLabel = ""
                    self.statusBanner = PrefixStatusBanner(message: msg, isError: true)
                    self.vm.statusMessage = msg
                }
            }
        }
    }

    private func importPrefixSaves(_ stat: PrefixManager.PrefixStat) {
        guard !vm.isRunning, busyPrefixName == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Restore Save Data — \(stat.name)"
        panel.message = "Choose a DirectMetal .tar.gz save backup to SHA-256 verify and restore into prefix “\(stat.name)”."
        panel.allowedContentTypes = [UTType.gzip]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let srcURL = panel.url else { return }

        busyPrefixName = stat.name
        busyActionLabel = "Restoring saves…"
        statusBanner = nil
        let name = stat.name
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let res = try SaveBackupManager.importSaves(from: srcURL.path, into: name)
                let updated = PrefixManager().prefixStats()
                let msg = "Restored \(res.restoredFiles) verified save file\(res.restoredFiles == 1 ? "" : "s") into “\(name)”."
                DispatchQueue.main.async {
                    self.stats = updated
                    self.hasLoaded = true
                    self.busyPrefixName = nil
                    self.busyActionLabel = ""
                    self.statusBanner = PrefixStatusBanner(message: msg, isError: false)
                    self.vm.statusMessage = msg
                }
            } catch {
                let msg = "Save restore failed for “\(name)”: \(error)"
                DispatchQueue.main.async {
                    self.busyPrefixName = nil
                    self.busyActionLabel = ""
                    self.statusBanner = PrefixStatusBanner(message: msg, isError: true)
                    self.vm.statusMessage = msg
                }
            }
        }
    }

    private func resetPrefix(_ stat: PrefixManager.PrefixStat) {
        guard !vm.isRunning, busyPrefixName == nil else { return }
        busyPrefixName = stat.name
        busyActionLabel = "Resetting…"
        statusBanner = nil

        let cachedPaths = vm.runtimePaths
        let name = stat.name
        let path = stat.path
        let gameExe = stat.gameExe ?? ""
        let dxApi = stat.dxApi ?? "auto"

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let paths: RuntimePaths
                if let live = try? RuntimeLauncher.resolveRuntimePaths() {
                    paths = live
                } else if let cached = cachedPaths {
                    paths = cached
                } else {
                    throw LauncherError.runtimeNotFound("DirectMetal runtime not found. Install the runtime before resetting prefixes.")
                }
                guard let base = paths.arm64ecBasePrefix ?? paths.basePrefix else {
                    throw PrefixError.missingBasePrefix("No golden base prefix is available in the DirectMetal runtime.")
                }
                if let ws = paths.arm64ecWineserverBin ?? paths.wineserverBin {
                    WineserverPool.stop(prefixURL: URL(fileURLWithPath: path, isDirectory: true), wineserverBin: ws)
                }
                let hw = RuntimeLauncher.queryHardwareInfo()
                let mgr = PrefixManager()
                let res = try mgr.createOrEnsure(
                    name: name,
                    basePrefix: base,
                    gameExe: gameExe,
                    dxApi: dxApi,
                    shaderCacheKey: hw.cacheKey,
                    forceReset: true
                )
                let updated = mgr.prefixStats()
                let msg = String(format: "Reset prefix “%@” from golden base in %.2f ms (APFS CoW).", name, res.cloneMs)
                DispatchQueue.main.async {
                    self.stats = updated
                    self.hasLoaded = true
                    self.busyPrefixName = nil
                    self.busyActionLabel = ""
                    self.statusBanner = PrefixStatusBanner(message: msg, isError: false)
                    self.vm.refreshPrefixes()
                    self.vm.statusMessage = msg
                }
            } catch {
                let updated = PrefixManager().prefixStats()
                let msg = "Failed to reset prefix “\(name)”: \(error)"
                DispatchQueue.main.async {
                    self.stats = updated
                    self.hasLoaded = true
                    self.busyPrefixName = nil
                    self.busyActionLabel = ""
                    self.statusBanner = PrefixStatusBanner(message: msg, isError: true)
                    self.vm.refreshPrefixes()
                    self.vm.statusMessage = msg
                }
            }
        }
    }

    private func deletePrefix(_ stat: PrefixManager.PrefixStat) {
        guard !vm.isRunning, busyPrefixName == nil else { return }
        busyPrefixName = stat.name
        busyActionLabel = "Deleting…"
        statusBanner = nil

        let cachedPaths = vm.runtimePaths
        let name = stat.name
        let path = stat.path

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let resolvedPaths = (try? RuntimeLauncher.resolveRuntimePaths()) ?? cachedPaths
                if let ws = resolvedPaths?.arm64ecWineserverBin ?? resolvedPaths?.wineserverBin {
                    WineserverPool.stop(prefixURL: URL(fileURLWithPath: path, isDirectory: true), wineserverBin: ws)
                }
                let mgr = PrefixManager()
                try mgr.deletePrefix(named: name)
                let updated = mgr.prefixStats()
                let msg = "Deleted prefix “\(name)” from disk."
                DispatchQueue.main.async {
                    self.stats = updated
                    self.hasLoaded = true
                    self.busyPrefixName = nil
                    self.busyActionLabel = ""
                    if updated.count < 4 {
                        self.searchText = ""
                    }
                    self.statusBanner = PrefixStatusBanner(message: msg, isError: false)
                    self.vm.refreshPrefixes()
                    self.vm.statusMessage = msg
                }
            } catch {
                let updated = PrefixManager().prefixStats()
                let msg = "Failed to delete prefix “\(name)”: \(error.localizedDescription)"
                DispatchQueue.main.async {
                    self.stats = updated
                    self.hasLoaded = true
                    self.busyPrefixName = nil
                    self.busyActionLabel = ""
                    self.statusBanner = PrefixStatusBanner(message: msg, isError: true)
                    self.vm.refreshPrefixes()
                    self.vm.statusMessage = msg
                }
            }
        }
    }

    private func pruneOrphanedPrefixes() {
        guard !vm.isRunning, busyPrefixName == nil else { return }
        busyPrefixName = "__prune__"
        busyActionLabel = "Pruning…"
        statusBanner = nil
        let referenced = referencedPrefixNames

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let mgr = PrefixManager()
                let res = try mgr.pruneOrphanedPrefixes(referencedNames: referenced, dryRun: false)
                let updated = mgr.prefixStats()
                let msg = "Pruned \(res.removedPrefixes.count) orphaned prefix\(res.removedPrefixes.count == 1 ? "" : "es") (\(PrefixDisplayFormat.logicalSize(res.reclaimedBytes)) logical)."
                DispatchQueue.main.async {
                    self.stats = updated
                    self.hasLoaded = true
                    self.busyPrefixName = nil
                    self.busyActionLabel = ""
                    if updated.count < 4 { self.searchText = "" }
                    self.statusBanner = PrefixStatusBanner(message: msg, isError: false)
                    self.vm.refreshPrefixes()
                    self.vm.statusMessage = msg
                }
            } catch {
                let updated = PrefixManager().prefixStats()
                let msg = "Failed to prune orphaned prefixes: \(error.localizedDescription)"
                DispatchQueue.main.async {
                    self.stats = updated
                    self.hasLoaded = true
                    self.busyPrefixName = nil
                    self.busyActionLabel = ""
                    self.statusBanner = PrefixStatusBanner(message: msg, isError: true)
                    self.vm.refreshPrefixes()
                    self.vm.statusMessage = msg
                }
            }
        }
    }
}

// MARK: - Prefix row subview

private struct PrefixStatRow: View {
    let stat: PrefixManager.PrefixStat
    let isOrphaned: Bool
    let isBusy: Bool
    let busyLabel: String
    let mutationsDisabled: Bool
    let gameRunning: Bool
    let onReveal: () -> Void
    let onExportSaves: () -> Void
    let onImportSaves: () -> Void
    let onReset: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let exeName = PrefixDisplayFormat.executableBasename(stat.gameExe)
        let apiPill = PrefixDisplayFormat.dxApiPill(stat.dxApi)

        HStack(alignment: .center, spacing: 12) {
            Image(systemName: exeName == nil ? "folder" : "folder.fill")
                .font(.system(size: 16))
                .foregroundStyle(exeName == nil ? Color.secondary : Color.accentColor.opacity(0.9))
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(stat.name)
                        .font(.callout.monospaced().bold())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    if let apiPill {
                        Text(apiPill.label)
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .foregroundStyle(apiPill.color)
                            .background(apiPill.color.opacity(0.15), in: Capsule())
                    }

                    if let cowMs = stat.cowCloneMs {
                        Text(PrefixDisplayFormat.cowTime(cowMs))
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .foregroundStyle(.secondary)
                            .background(Color.secondary.opacity(0.11), in: Capsule())
                            .help("APFS Copy-on-Write clone duration when this prefix was created")
                    }

                    if isOrphaned {
                        Text("Orphaned")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .foregroundStyle(.orange)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                            .help("Not referenced by any game currently in your library")
                    }
                }

                HStack(spacing: 6) {
                    Text(exeName ?? "Unassigned")
                        .font(.caption)
                        .foregroundStyle(exeName == nil ? .tertiary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(stat.gameExe ?? "No game executable recorded in directmetal_prefix.json")

                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.quaternary)

                    Text(PrefixDisplayFormat.fileCount(stat.fileCount))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(PrefixDisplayFormat.logicalSize(stat.sizeBytes))
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
                .frame(minWidth: 82, alignment: .trailing)
                .help("Logical size of files in this prefix (APFS CoW shares unchanged base blocks on disk)")

            if isBusy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(busyLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 160, alignment: .trailing)
            } else {
                HStack(spacing: 6) {
                    Button {
                        onReveal()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .controlSize(.small)
                    .help("Reveal “\(stat.name)” in Finder")

                    Menu {
                        Button {
                            onExportSaves()
                        } label: {
                            Label("Backup Saves (.tar.gz)…", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            onImportSaves()
                        } label: {
                            Label("Restore Saves (.tar.gz)…", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "externaldrive.badge.checkmark")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(mutationsDisabled)
                    .help(gameRunning
                          ? "Quit the running game before backing up or restoring saves"
                          : "Backup or restore SHA-256 verified Windows save files for “\(stat.name)”")

                    Button {
                        onReset()
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .controlSize(.small)
                    .disabled(mutationsDisabled)
                    .help(gameRunning
                          ? "Quit the running game before resetting a prefix"
                          : "Wipe and re-clone “\(stat.name)” from the golden base prefix")

                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .controlSize(.small)
                    .disabled(mutationsDisabled)
                    .help(gameRunning
                          ? "Quit the running game before deleting a prefix"
                          : "Permanently delete “\(stat.name)” from disk")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.12))
        )
        .help(stat.path)
    }
}
