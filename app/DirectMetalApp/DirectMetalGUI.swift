import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Presentation helpers

struct LauncherBadge: Identifiable, Hashable {
    let text: String
    let color: Color
    var id: String { text }
}

enum LauncherStyle {
    static let metalFXOptions: [(tag: String, label: String)] = [
        ("off", "Off"),
        ("quality", "Quality 1.5x"),
        ("balanced", "Balanced 1.7x"),
        ("performance", "Perf 2.0x"),
        ("ultra_performance", "Ultra Perf 2.5x"),
    ]

    static func apiBadges(for entry: GameLibraryEntry) -> [LauncherBadge] {
        var out: [LauncherBadge] = []
        let apis = Set(entry.detectedAPIs)
        if apis.contains("D3D12") { out.append(LauncherBadge(text: "DX12", color: .purple)) }
        if apis.contains("D3D11") { out.append(LauncherBadge(text: "DX11", color: .blue)) }
        if apis.contains("D3D10") { out.append(LauncherBadge(text: "DX10", color: .teal)) }
        if apis.contains("D3D9") { out.append(LauncherBadge(text: "DX9", color: .orange)) }
        if !entry.detectedUpscalers.isEmpty || entry.launchUpscaleMode != nil {
            out.append(LauncherBadge(text: "MetalFX", color: .green))
        }
        return out
    }

    static func accent(for title: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .red, .mint, .cyan]
        let sum = title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
        return palette[sum % palette.count]
    }

    static func initials(for title: String) -> String {
        let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.prefix(2).compactMap { $0.first.map { String($0).uppercased() } }
        return letters.isEmpty ? "?" : letters.joined()
    }

    static func lastPlayedText(_ iso: String?) -> String {
        guard let iso, let date = GameLibraryManager.isoFormatter.date(from: iso) else { return "Never played" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "Played " + f.localizedString(for: date, relativeTo: Date())
    }
}

struct BadgeView: View {
    let badge: LauncherBadge
    var body: some View {
        Text(badge.text)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .foregroundStyle(badge.color)
            .background(badge.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct ArchPill: View {
    let architecture: String
    var body: some View {
        Text(architecture)
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .foregroundStyle(.secondary)
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.45), lineWidth: 0.8))
    }
}

struct GameMonogram: View {
    let title: String
    var size: CGFloat = 34
    var body: some View {
        let color = LauncherStyle.accent(for: title)
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.55)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(
                Text(LauncherStyle.initials(for: title))
                    .font(.system(size: size * 0.38, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            )
            .shadow(color: color.opacity(0.25), radius: size * 0.08, y: size * 0.04)
    }
}

struct StatusPill: View {
    let title: String
    let value: String
    let ok: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.callout.weight(.semibold))
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - View model

@MainActor
final class DirectMetalViewModel: ObservableObject {
    @Published var gpuInfo: MetalHardwareInfo = RuntimeLauncher.queryHardwareInfo()
    @Published var runtimePaths: RuntimePaths? = try? RuntimeLauncher.resolveRuntimePaths()
    @Published var library: [GameLibraryEntry] = []
    @Published var selectedID: String?
    @Published var searchText: String = ""
    @Published var prefixes: [String] = []
    @Published var cacheSummary: ShaderCacheSummary = RuntimeLauncher.queryShaderCache()
    @Published var attestationStatus: AttestationStatus?
    @Published var attestationKeyId: String = ""
    @Published var attestationVerified: Bool = false
    @Published var attestationRunning: Bool = false
    @Published var statusMessage: String = "Ready — scan your library or drop a DirectX 9/10/11/12 .exe anywhere."
    @Published var runningGameID: String?
    @Published var isScanning: Bool = false
    @Published var isCacheBusy: Bool = false
    @Published var showImportSheet: Bool = false
    @Published var importSource: String = ""
    @Published var importAllowCrossBuild: Bool = false
    @Published var showRemoveConfirm: Bool = false

    private let manager = GameLibraryManager()

    init() {
        library = manager.load()
        selectedID = library.max(by: { ($0.lastPlayedUtc ?? "") < ($1.lastPlayedUtc ?? "") })?.id ?? library.first?.id
        refreshPrefixes()
        runAttestationCheck()
        if library.isEmpty {
            scanLibrary()
        }
    }

    // MARK: Derived state

    var gpuSummary: String {
        "\(gpuInfo.gpuName) • \(gpuInfo.supportsMetal4 ? "Metal 4" : (gpuInfo.supportsMetal3 ? "Metal 3" : "Metal"))"
    }

    var filteredLibrary: [GameLibraryEntry] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return library }
        return library.filter { e in
            e.title.localizedCaseInsensitiveContains(q)
                || e.exePath.localizedCaseInsensitiveContains(q)
                || e.detectedAPIs.contains(where: { $0.localizedCaseInsensitiveContains(q) })
                || LauncherStyle.apiBadges(for: e).contains(where: { $0.text.localizedCaseInsensitiveContains(q) })
        }
    }

    var selectedEntry: GameLibraryEntry? {
        guard let id = selectedID else { return nil }
        return library.first(where: { $0.id == id })
    }

    var isRunning: Bool { runningGameID != nil }

    // MARK: Per-game settings (auto-persisted)

    func binding<T>(_ entry: GameLibraryEntry, _ keyPath: WritableKeyPath<GameLibraryEntry, T>) -> Binding<T> {
        Binding(
            get: { self.library.first(where: { $0.id == entry.id })?[keyPath: keyPath] ?? entry[keyPath: keyPath] },
            set: { newValue in self.update(entry.id) { $0[keyPath: keyPath] = newValue } }
        )
    }

    func update(_ id: String, _ mutate: (inout GameLibraryEntry) -> Void) {
        guard let idx = library.firstIndex(where: { $0.id == id }) else { return }
        var e = library[idx]
        mutate(&e)
        guard e != library[idx] else { return }
        library[idx] = e
        manager.save(library)
    }

    // MARK: Library actions

    func reloadLibrary(select id: String? = nil) {
        library = manager.load()
        if let id { selectedID = id }
        if let sel = selectedID, !library.contains(where: { $0.id == sel }) {
            selectedID = library.first?.id
        }
    }

    func refreshPrefixes() {
        prefixes = PrefixManager().listPrefixes()
        cacheSummary = RuntimeLauncher.queryShaderCache()
    }

    func scanLibrary(extraDirs: [String] = []) {
        guard !isScanning else { return }
        isScanning = true
        statusMessage = extraDirs.isEmpty
            ? "Scanning prefixes, Steam libraries and game folders…"
            : "Scanning \(extraDirs.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))…"
        let before = Set(library.map(\.id))
        DispatchQueue.global(qos: .userInitiated).async {
            let result = GameLibraryManager().scanKnownLocations(extraDirs: extraDirs)
            DispatchQueue.main.async {
                self.isScanning = false
                self.library = result
                let added = result.filter { !before.contains($0.id) }
                if let first = added.first, !extraDirs.isEmpty || self.selectedID == nil {
                    self.selectedID = first.id
                } else if self.selectedID == nil {
                    self.selectedID = result.first?.id
                }
                self.statusMessage = "Library scan complete — \(added.count) new, \(result.count) game\(result.count == 1 ? "" : "s") total."
            }
        }
    }

    func addExe(path: String) {
        do {
            let entry = try manager.addOrUpdate(exePath: path)
            reloadLibrary(select: entry.id)
            searchText = ""
            let apis = entry.detectedAPIs.isEmpty ? "Win32" : entry.detectedAPIs.joined(separator: " + ")
            statusMessage = "Added \(entry.title) — \(entry.architecture) (\(apis)); zero-config Metal pipeline ready."
        } catch {
            statusMessage = "Could not add \(URL(fileURLWithPath: path).lastPathComponent): \(error)"
        }
    }

    func openAddPanel() {
        let panel = NSOpenPanel()
        panel.title = "Add Windows Games"
        panel.message = "Choose a game .exe, or a game folder to scan."
        panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .data, .folder]
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        ingest(urls: panel.urls)
    }

    func ingest(urls: [URL]) {
        var dirs: [String] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                dirs.append(url.path)
            } else if url.pathExtension.lowercased() == "exe" {
                addExe(path: url.path)
            } else {
                statusMessage = "Ignored \(url.lastPathComponent) — drop a Windows .exe or a game folder."
            }
        }
        if !dirs.isEmpty { scanLibrary(extraDirs: dirs) }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let usable = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !usable.isEmpty else { return false }
        for provider in usable {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    self.ingest(urls: [url])
                }
            }
        }
        return true
    }

    func removeSelected() {
        guard let entry = selectedEntry else { return }
        let ordered = filteredLibrary
        let nextID: String? = {
            guard let i = ordered.firstIndex(where: { $0.id == entry.id }) else { return nil }
            if i + 1 < ordered.count { return ordered[i + 1].id }
            return i > 0 ? ordered[i - 1].id : nil
        }()
        if manager.remove(idOrTitle: entry.id) {
            library = manager.load()
            selectedID = nextID
            statusMessage = "Removed \(entry.title) from the library (prefix and shader cache kept)."
        }
    }

    func reinspect(_ entry: GameLibraryEntry) {
        do {
            let updated = try manager.addOrUpdate(exePath: entry.exePath)
            reloadLibrary(select: updated.id)
            statusMessage = "Re-inspected \(updated.title): \(updated.architecture) \(updated.detectedAPIs.joined(separator: " + "))."
        } catch {
            statusMessage = "Inspect error: \(error)"
        }
    }

    func revealInFinder(_ entry: GameLibraryEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.exePath)])
    }

    // MARK: Launch

    func play(_ entry: GameLibraryEntry) {
        guard runningGameID == nil else { return }
        guard let current = library.first(where: { $0.id == entry.id }) else { return }
        guard FileManager.default.fileExists(atPath: current.exePath) else {
            statusMessage = "Executable missing: \(current.exePath)"
            return
        }
        manager.recordLaunch(id: current.id)
        reloadLibrary()
        runningGameID = current.id
        statusMessage = "Launching \(current.title) — cloning APFS prefix “\(current.launchPrefixName)” & starting DirectMetal…"

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try RuntimeLauncher.runExecutable(
                    exePath: current.exePath,
                    prefixName: current.launchPrefixName,
                    extraArgs: current.extraArgList,
                    enableHUD: current.enableHUD,
                    upscaleMode: current.launchUpscaleMode,
                    engine: current.engine,
                    dx9Backend: current.dx9Backend,
                    perfProfile: current.perfProfile,
                    retinaMode: current.retinaMode,
                    sandboxed: current.enableSandbox
                )
                DispatchQueue.main.async {
                    self.runningGameID = nil
                    self.refreshPrefixes()
                    self.statusMessage = String(
                        format: "%@ finished (exit=%d) in %.1f s [engine=%@, CoW=%.2f ms%@]",
                        current.title, result.exitCode, result.elapsedSeconds, result.activeEngine, result.cloneMs,
                        result.sandboxed ? ", seatbelt" : ""
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    self.runningGameID = nil
                    self.statusMessage = "Launch failed: \(error)"
                }
            }
        }
    }

    // MARK: Shader cache

    func clearShaderCache() {
        try? RuntimeLauncher.clearShaderCache()
        cacheSummary = RuntimeLauncher.queryShaderCache()
        statusMessage = "Cleared pre-compiled shader cache."
    }

    func exportShaderCache() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "directmetal-shaders-\(gpuInfo.cacheKey).dmcache.tar.gz"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isCacheBusy = true
        statusMessage = "Exporting shader cache…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let res = try ShaderCacheManager.exportArchive(to: url.path)
                let mb = Double(res.archiveBytes) / (1024.0 * 1024.0)
                let msg = String(format: "Exported %d shader files (%.2f MiB, SHA-256: %@…)",
                                 res.fileCount, mb, String(res.manifestSha256.prefix(12)))
                DispatchQueue.main.async {
                    self.isCacheBusy = false
                    self.statusMessage = msg
                }
            } catch {
                let msg = "Cache export failed: \(error)"
                DispatchQueue.main.async {
                    self.isCacheBusy = false
                    self.statusMessage = msg
                }
            }
        }
    }

    func chooseImportFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a DirectMetal shader cache archive (.dmcache.tar.gz)"
        if panel.runModal() == .OK, let url = panel.url {
            importSource = url.path
        }
    }

    func importShaderCache(from rawSource: String) {
        let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        let lower = source.lowercased()
        if lower.hasPrefix("http://") {
            statusMessage = "Refusing insecure http:// cache URL — use https://."
            return
        }
        let resolved = lower.hasPrefix("https://") ? source : (source as NSString).expandingTildeInPath
        if !lower.hasPrefix("https://") && !FileManager.default.fileExists(atPath: resolved) {
            statusMessage = "Cache archive not found: \(resolved)"
            return
        }
        let allowCross = importAllowCrossBuild
        isCacheBusy = true
        statusMessage = lower.hasPrefix("https://") ? "Downloading & verifying shader cache…" : "Verifying & importing shader cache…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let res = try ShaderCacheManager.importArchive(from: resolved, allowCrossBuild: allowCross)
                let msg = "Imported & verified \(res.verifiedFiles) shader files (\(res.gpuFamily)/\(res.macosBuild))."
                DispatchQueue.main.async {
                    self.isCacheBusy = false
                    self.cacheSummary = RuntimeLauncher.queryShaderCache()
                    self.statusMessage = msg
                }
            } catch {
                let msg = "Cache import failed: \(error)"
                DispatchQueue.main.async {
                    self.isCacheBusy = false
                    self.statusMessage = msg
                }
            }
        }
    }

    // MARK: Attestation

    func runAttestationCheck() {
        guard !attestationRunning else { return }
        attestationRunning = true
        let sandbox = selectedEntry?.enableSandbox ?? false
        DispatchQueue.global(qos: .userInitiated).async {
            let st = DirectMetalAttestation.collectStatus(sandboxActive: sandbox)
            let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let bundleResult = try? DirectMetalAttestation.generateSignedBundle(status: st, nonceHex: nonce)
            var keyId = ""
            if let json = bundleResult?.json,
               let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let k = obj["key_id_sha256"] as? String {
                keyId = k
            }
            let ok = bundleResult?.verified ?? false
            DispatchQueue.main.async {
                self.attestationStatus = st
                self.attestationKeyId = keyId
                self.attestationVerified = ok
                self.attestationRunning = false
            }
        }
    }
}

// MARK: - Root view

struct DirectMetalContentView: View {
    @StateObject private var vm = DirectMetalViewModel()
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                LibrarySidebar(vm: vm)
                    .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 400)
            } detail: {
                if let entry = vm.selectedEntry {
                    GameDetailView(vm: vm, entry: entry)
                        .id(entry.id)
                } else {
                    WelcomeView(vm: vm)
                }
            }
            Divider()
            LauncherStatusBar(vm: vm)
        }
        .frame(minWidth: 920, minHeight: 600)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        Label("Drop .exe or game folder to add", systemImage: "plus.circle.fill")
                            .font(.title2.bold())
                            .padding(14)
                            .background(.regularMaterial, in: Capsule())
                    )
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            vm.handleDrop(providers)
        }
        .sheet(isPresented: $vm.showImportSheet) {
            CacheImportSheet(vm: vm)
        }
        .confirmationDialog(
            "Remove \(vm.selectedEntry?.title ?? "game") from the library?",
            isPresented: $vm.showRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { vm.removeSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The game files, prefix and shader cache stay on disk. Auto-scan will not re-add it.")
        }
    }
}

// MARK: - Sidebar

struct LibrarySidebar: View {
    @ObservedObject var vm: DirectMetalViewModel

    var body: some View {
        List(selection: $vm.selectedID) {
            Section {
                ForEach(vm.filteredLibrary) { entry in
                    GameRow(entry: entry, isRunning: vm.runningGameID == entry.id)
                        .tag(entry.id as String?)
                        .contextMenu {
                            Button("Play") { vm.play(entry) }
                                .disabled(vm.isRunning || vm.runtimePaths == nil)
                            Button("Show in Finder") { vm.revealInFinder(entry) }
                            Button("Re-inspect Executable") { vm.reinspect(entry) }
                            Divider()
                            Button("Remove from Library…", role: .destructive) {
                                vm.selectedID = entry.id
                                vm.showRemoveConfirm = true
                            }
                        }
                }
            } header: {
                Text(vm.searchText.isEmpty ? "Library — \(vm.library.count)" : "Results — \(vm.filteredLibrary.count)")
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $vm.searchText, placement: .sidebar, prompt: "Search games")
        .overlay {
            if vm.library.isEmpty {
                VStack(spacing: 8) {
                    if vm.isScanning {
                        ProgressView().controlSize(.small)
                        Text("Scanning…").font(.callout).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "tray").font(.title).foregroundStyle(.tertiary)
                        Text("No games yet").font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else if vm.filteredLibrary.isEmpty {
                Text("No matches for “\(vm.searchText)”").font(.callout).foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 6) {
                    Button {
                        vm.scanLibrary()
                    } label: {
                        if vm.isScanning {
                            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Scanning") }
                        } else {
                            Label("Scan Library", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(vm.isScanning)
                    .help("Scan prefixes, Steam libraries and game folders")

                    Button {
                        vm.openAddPanel()
                    } label: {
                        Label("Add .exe…", systemImage: "plus")
                    }
                    .help("Add a Windows .exe or scan a game folder")

                    Spacer(minLength: 0)

                    Button {
                        vm.showRemoveConfirm = true
                    } label: {
                        Label("Remove", systemImage: "minus")
                    }
                    .disabled(vm.selectedEntry == nil)
                    .help("Remove the selected game from the library")
                }
                .labelStyle(.titleAndIcon)
                .controlSize(.small)
                .buttonStyle(.borderless)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(.bar)
        }
    }
}

struct GameRow: View {
    let entry: GameLibraryEntry
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 10) {
            GameMonogram(title: entry.title, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.system(.body, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    ForEach(LauncherStyle.apiBadges(for: entry)) { BadgeView(badge: $0) }
                    ArchPill(architecture: entry.architecture)
                }
            }
            Spacer(minLength: 0)
            if isRunning {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 3)
        .help(entry.exePath)
    }
}

// MARK: - Detail

struct GameDetailView: View {
    @ObservedObject var vm: DirectMetalViewModel
    let entry: GameLibraryEntry

    private var live: GameLibraryEntry { vm.library.first(where: { $0.id == entry.id }) ?? entry }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                peProfileCard
                settingsPanel
                shaderCachePanel
                securityCard
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle(live.title)
        .navigationSubtitle(vm.gpuSummary)
    }

    // Header

    private var header: some View {
        let e = live
        let running = vm.runningGameID == e.id
        return HStack(alignment: .center, spacing: 18) {
            GameMonogram(title: e.title, size: 76)
            VStack(alignment: .leading, spacing: 6) {
                Text(e.title)
                    .font(.system(size: 28, weight: .bold))
                    .lineLimit(1)
                Text(e.exePath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 12) {
                    Label("\(e.playCount) play\(e.playCount == 1 ? "" : "s")", systemImage: "gamecontroller")
                    Label(LauncherStyle.lastPlayedText(e.lastPlayedUtc), systemImage: "clock")
                    Label(vm.gpuSummary, systemImage: "cpu")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(spacing: 6) {
                Button {
                    vm.play(e)
                } label: {
                    HStack(spacing: 8) {
                        if running {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text(running ? "Running…" : "Play")
                    }
                    .font(.title2.bold())
                    .frame(minWidth: 130, minHeight: 38)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(vm.isRunning || vm.runtimePaths == nil)
                if vm.runtimePaths == nil {
                    Text("Runtime not installed").font(.caption2).foregroundStyle(.red)
                } else if vm.isRunning && !running {
                    Text("Another game is running").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("⌘↩ to play").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(18)
        .background(
            LinearGradient(colors: [LauncherStyle.accent(for: e.title).opacity(0.18), Color.clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.secondary.opacity(0.15)))
    }

    // PE profile

    private var peProfileCard: some View {
        let e = live
        return GroupBox {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("Architecture").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    HStack(spacing: 6) {
                        ArchPill(architecture: e.architecture)
                        Text(e.architecture == "x86" ? "32-bit" : (e.architecture == "unknown" ? "" : "64-bit"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("APIs").foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        if e.detectedAPIs.isEmpty {
                            Text("None detected (Win32)").font(.callout)
                        } else {
                            ForEach(LauncherStyle.apiBadges(for: e).filter { $0.text != "MetalFX" }) { BadgeView(badge: $0) }
                            Text(e.detectedAPIs.joined(separator: " + ")).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                GridRow {
                    Text("Upscaler Bridge").foregroundStyle(.secondary)
                    Text(e.detectedUpscalers.isEmpty
                         ? "None detected — MetalFX spatial available"
                         : "\(e.detectedUpscalers.joined(separator: ", ")) → MetalFX")
                        .font(.callout)
                        .foregroundStyle(e.detectedUpscalers.isEmpty ? Color.primary : Color.blue)
                }
                GridRow {
                    Text("Build Cache Key").foregroundStyle(.secondary)
                    Text("\(e.buildHash)_\(vm.gpuInfo.cacheKey)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            HStack {
                Label("Auto-Detected PE Profile", systemImage: "doc.viewfinder")
                Spacer()
                Button("Re-inspect") { vm.reinspect(e) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    // Per-game settings

    private var settingsPanel: some View {
        let e = live
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        Text("Prefix").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        HStack(spacing: 6) {
                            TextField("default", text: vm.binding(e, \.prefixName))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 260)
                            Menu {
                                if vm.prefixes.isEmpty {
                                    Text("No prefixes yet")
                                } else {
                                    ForEach(vm.prefixes, id: \.self) { name in
                                        Button(name) { vm.update(e.id) { $0.prefixName = name } }
                                    }
                                }
                            } label: {
                                Image(systemName: "folder")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Use an existing APFS CoW prefix")
                        }
                    }
                    GridRow {
                        Text("Engine").foregroundStyle(.secondary)
                        Picker("Engine", selection: vm.binding(e, \.engine)) {
                            Text("Auto").tag(ExecutionEngine.auto)
                            Text("ARM64EC+FEX").tag(ExecutionEngine.arm64ec)
                            Text("Rosetta 2").tag(ExecutionEngine.rosetta)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 360)
                    }
                    GridRow {
                        Text("Perf Mode").foregroundStyle(.secondary)
                        Picker("Perf Mode", selection: vm.binding(e, \.perfProfile)) {
                            Text("Balanced").tag(PerfProfile.balanced)
                            Text("Ultra").tag(PerfProfile.ultra)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 240)
                    }
                    GridRow {
                        Text("DX9 Backend").foregroundStyle(.secondary)
                        Picker("DX9 Backend", selection: vm.binding(e, \.dx9Backend)) {
                            Text("Auto").tag(DX9Backend.auto)
                            Text("WineD3D").tag(DX9Backend.wined3d)
                            Text("DXVK").tag(DX9Backend.dxvk)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 300)
                    }
                    GridRow {
                        Text("MetalFX").foregroundStyle(.secondary)
                        Picker("MetalFX", selection: vm.binding(e, \.upscaleMode)) {
                            ForEach(LauncherStyle.metalFXOptions, id: \.tag) { opt in
                                Text(opt.label).tag(opt.tag)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 200)
                    }
                    GridRow {
                        Text("Extra Args").foregroundStyle(.secondary)
                        TextField("e.g. -windowed -dx11 \"-name=With Spaces\"", text: vm.binding(e, \.extraArgs))
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                    }
                    GridRow {
                        Text("Options").foregroundStyle(.secondary)
                        HStack(spacing: 18) {
                            Toggle("Retina PPI", isOn: vm.binding(e, \.retinaMode))
                                .help("Native Retina resolution with 192 DPI LogPixels")
                            Toggle("Metal HUD", isOn: vm.binding(e, \.enableHUD))
                                .help("Show the Metal / DXVK performance HUD")
                            Toggle("Seatbelt Sandbox", isOn: vm.binding(e, \.enableSandbox))
                                .help("Run the game inside a macOS Seatbelt sandbox profile")
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.icloud")
                    Text("Changes save automatically to library.json")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Label("Per-Game Settings", systemImage: "slider.horizontal.3")
        }
    }

    // Shader cache

    private var shaderCachePanel: some View {
        let e = live
        let mb = Double(vm.cacheSummary.totalBytes) / (1024.0 * 1024.0)
        let warm = !e.buildHash.isEmpty && vm.cacheSummary.entries.contains(where: { $0.hasPrefix(e.buildHash) })
        return GroupBox {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(vm.cacheSummary.entryCount) titles • \(vm.cacheSummary.fileCount) files • \(String(format: "%.2f", mb)) MiB")
                        .font(.callout.weight(.semibold))
                    HStack(spacing: 5) {
                        Circle().fill(warm ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                        Text(warm ? "Warm cache for this game" : "No cached shaders for this game yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(vm.cacheSummary.rootPath)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 6) {
                        if vm.isCacheBusy { ProgressView().controlSize(.small) }
                        Button("Export Cache…") { vm.exportShaderCache() }
                        Button("Import Cache / URL…") {
                            vm.importSource = ""
                            vm.showImportSheet = true
                        }
                    }
                    Button("Clear Cache", role: .destructive) { vm.clearShaderCache() }
                }
                .disabled(vm.isCacheBusy)
            }
            .padding(6)
        } label: {
            Label("Shader Cache", systemImage: "square.stack.3d.up")
        }
    }

    // Security

    private var securityCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let st = vm.attestationStatus {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                        StatusPill(title: "Secure Enclave", value: st.secureEnclaveAvailable ? "Active" : "Unavailable", ok: st.secureEnclaveAvailable)
                        StatusPill(title: "SIP", value: st.sipEnabled ? "Enabled" : "Disabled", ok: st.sipEnabled)
                        StatusPill(title: "SSV", value: st.ssvSealed ? "Sealed" : "Open", ok: st.ssvSealed)
                        StatusPill(title: "Hardened Runtime", value: st.hardenedRuntime ? "On" : "Off", ok: st.hardenedRuntime)
                        StatusPill(title: "DCAppAttest", value: st.dcAppAttestSupported ? "Supported" : "Unsupported", ok: st.dcAppAttestSupported)
                        StatusPill(title: "DCDevice", value: st.dcDeviceSupported ? "Supported" : "Unsupported", ok: st.dcDeviceSupported)
                    }
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow {
                            Text("key_id_sha256").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            HStack(spacing: 6) {
                                Text(vm.attestationKeyId.isEmpty ? "—" : vm.attestationKeyId)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                Text(vm.attestationVerified ? "SELF-VERIFY PASS" : "PENDING")
                                    .font(.caption2.bold())
                                    .foregroundStyle(vm.attestationVerified ? .green : .orange)
                            }
                        }
                        GridRow {
                            Text("CS Flags").foregroundStyle(.secondary)
                            Text("\(st.csStatusFlagsHex)  (valid=\(st.csValid ? "1" : "0") runtime=\(st.csRuntime ? "1" : "0") debugged=\(st.csDebugged ? "1" : "0"))")
                        }
                    }
                    .font(.caption.monospaced())
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Collecting hardware attestation telemetry…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            HStack {
                Label("Hardware Security & Secure Enclave Attestation", systemImage: "lock.shield")
                Spacer()
                if vm.attestationRunning { ProgressView().controlSize(.mini) }
                Button("Run Attestation") { vm.runAttestationCheck() }
                    .controlSize(.small)
                    .disabled(vm.attestationRunning)
            }
        }
    }
}

// MARK: - Welcome / empty state

struct WelcomeView: View {
    @ObservedObject var vm: DirectMetalViewModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 64))
                .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(vm.library.isEmpty ? "Welcome to DirectMetal" : "Select a Game")
                .font(.largeTitle.bold())
            Text(vm.library.isEmpty
                 ? "Apple Silicon–first DirectX 9/10/11/12 runtime. Scan your prefixes and Steam libraries, or add a Windows game to get started."
                 : "Choose a game from the sidebar to view its profile, tweak per-game settings and play.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            HStack(spacing: 12) {
                Button {
                    vm.scanLibrary()
                } label: {
                    Label(vm.isScanning ? "Scanning…" : "Scan Library", systemImage: "arrow.clockwise")
                        .frame(minWidth: 130)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(vm.isScanning)
                Button {
                    vm.openAddPanel()
                } label: {
                    Label("Add .exe…", systemImage: "plus").frame(minWidth: 110)
                }
                .controlSize(.large)
            }
            Text("Tip: drop a Windows .exe or a game folder anywhere on this window.")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Label(vm.gpuSummary, systemImage: "cpu")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.14), in: Capsule())
                .foregroundStyle(Color.accentColor)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("DirectMetal")
    }
}

// MARK: - Status bar

struct LauncherStatusBar: View {
    @ObservedObject var vm: DirectMetalViewModel

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(vm.isRunning ? Color.orange : (vm.isScanning || vm.isCacheBusy ? Color.blue : Color.green))
                .frame(width: 8, height: 8)
            Text(vm.statusMessage)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
            Spacer(minLength: 12)
            Text("\(vm.library.count) game\(vm.library.count == 1 ? "" : "s")")
            Divider().frame(height: 12)
            Label(vm.runtimePaths == nil ? "Runtime missing" : "Runtime ready",
                  systemImage: vm.runtimePaths == nil ? "xmark.octagon" : "checkmark.circle")
                .foregroundStyle(vm.runtimePaths == nil ? Color.red : Color.secondary)
            Divider().frame(height: 12)
            Text(vm.gpuSummary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - Cache import sheet

struct CacheImportSheet: View {
    @ObservedObject var vm: DirectMetalViewModel
    @Environment(\.dismiss) private var dismiss

    private var trimmed: String { vm.importSource.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Import Shader Cache", systemImage: "square.and.arrow.down")
                .font(.title2.bold())
            Text("Paste an https:// URL to a .dmcache.tar.gz archive, or choose a local file. Every archive is SHA-256 verified against its manifest before it is installed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("https://example.com/shaders.dmcache.tar.gz  or  /path/to/cache.dmcache.tar.gz",
                          text: $vm.importSource)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                Button("Choose File…") { vm.chooseImportFile() }
            }
            Toggle("Allow archives from a different macOS build", isOn: $vm.importAllowCrossBuild)
                .toggleStyle(.checkbox)
                .font(.callout)
            if trimmed.lowercased().hasPrefix("http://") {
                Label("Only https:// URLs are allowed.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || trimmed.lowercased().hasPrefix("http://"))
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        vm.importShaderCache(from: trimmed)
        dismiss()
    }
}

// MARK: - App

struct DirectMetalDesktopApp: App {
    var body: some Scene {
        WindowGroup("DirectMetal") {
            DirectMetalContentView()
        }
        .defaultSize(width: 1120, height: 760)
        .windowToolbarStyle(.unified(showsTitle: true))
    }
}
