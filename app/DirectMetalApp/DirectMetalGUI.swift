import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Launcher shell: view model, root split view, menu commands, and app delegate.
// Sidebar/detail/welcome: GameDetailAndSidebarViews.swift · Components: LauncherComponents.swift ·
// Updates/runtime/cache: UpdatesAndRuntimeSheets.swift · Controllers: ControllerMappingSheet.swift

// MARK: - View model

@MainActor
final class DirectMetalViewModel: ObservableObject {
    @Published var gpuInfo: MetalHardwareInfo = RuntimeLauncher.queryHardwareInfo()
    @Published var runtimePaths: RuntimePaths? = try? RuntimeLauncher.resolveRuntimePaths()
    @Published var library: [GameLibraryEntry] = []
    @Published var selectedID: String? {
        didSet {
            if selectedID != oldValue { prewarmSelectedPrefix() }
        }
    }
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
    // Lite first-run runtime installation
    @Published var runtimeInstallRunning: Bool = false
    @Published var runtimeInstallPhase: String = ""
    @Published var runtimeInstallFraction: Double = -1
    @Published var runtimeInstallBytes: Int64 = 0
    @Published var runtimeInstallTotal: Int64 = -1
    @Published var runtimeInstallError: String?
    // GitHub Releases update check (user-triggered)
    @Published var updateChecking: Bool = false
    @Published var updateResult: UpdateCheckResult?
    // Updates sheet: DirectMetal app (.dmg self-update) + MetalSharp-Wine runtime
    @Published var showUpdatesSheet: Bool = false
    @Published var dualStatus: DualUpdateStatus?
    @Published var appUpdateRunning: Bool = false
    @Published var appUpdatePhase: String = ""
    @Published var appUpdateFraction: Double = -1
    @Published var appUpdateBytes: Int64 = 0
    @Published var appUpdateTotal: Int64 = -1
    @Published var appUpdateError: String?
    @Published var appUpdateInstalledURL: URL?
    @Published var runtimeUpdateRunning: Bool = false
    @Published var runtimeUpdatePhase: String = ""
    @Published var runtimeUpdateFraction: Double = -1
    @Published var runtimeUpdateError: String?
    @Published var runtimeUpdateDone: String?
    // Controller remapping sheet
    @Published var showControllerSheet: Bool = false
    // System health & shader cache maintenance sheet
    @Published var showSystemHealthSheet: Bool = false
    // APFS prefix manager & storage inspector sheet
    @Published var showPrefixManagerSheet: Bool = false
    // Quick-Launch Command Palette (⌘K)
    @Published var showCommandPalette: Bool = false
    // Structured Launch History sheet (⇧⌘H)
    @Published var showLaunchHistorySheet: Bool = false
    // Detail vs Poster Gallery toggle
    @Published var showGalleryView: Bool = false
    // Sidebar quick filter + sort (sort order persists across launches)
    @Published var libraryFilter: LibraryFilter = .all
    @Published var librarySort: LibrarySort =
        LibrarySort(rawValue: UserDefaults.standard.string(forKey: LibrarySort.defaultsKey) ?? "") ?? .recent {
        didSet { UserDefaults.standard.set(librarySort.rawValue, forKey: LibrarySort.defaultsKey) }
    }
    /// Bumped by ⌘F; the sidebar focuses its search field on change.
    @Published var searchFocusRequest: Int = 0
    /// Most recent launch per game ID, for the "Last Launch Diagnostics" drawer.
    @Published var lastLaunches: [String: LaunchDiagnostics] = [:]

    private let manager = GameLibraryManager()

    /// Community profile that seeded `entry` (for the preset pill), if any.
    func profile(for entry: GameLibraryEntry) -> GameProfile? {
        manager.profileRegistry.profile(id: entry.profileID)
    }

    init() {
        library = manager.load()
        selectedID = library.max(by: { ($0.lastPlayedUtc ?? "") < ($1.lastPlayedUtc ?? "") })?.id ?? library.first?.id
        refreshPrefixes()
        // Let the window appear first: attestation spawns subprocesses / Secure Enclave work.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.runAttestationCheck()
        }
        if library.isEmpty {
            scanLibrary()
        }
        prewarmSelectedPrefix()
    }

    // MARK: Derived state

    var gpuSummary: String {
        "\(gpuInfo.gpuName) • \(gpuInfo.supportsMetal4 ? "Metal 4" : (gpuInfo.supportsMetal3 ? "Metal 3" : "Metal"))"
    }

    /// Library entries matching the search text (before the quick filter), in stored order.
    var searchMatches: [GameLibraryEntry] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return library }
        return library.filter { e in
            e.title.localizedCaseInsensitiveContains(q)
                || e.exePath.localizedCaseInsensitiveContains(q)
                || (e.storeSource?.localizedCaseInsensitiveContains(q) ?? false)
                || e.detectedAPIs.contains(where: { $0.localizedCaseInsensitiveContains(q) })
                || LauncherStyle.apiBadges(for: e).contains(where: { $0.text.localizedCaseInsensitiveContains(q) })
        }
    }

    /// What the sidebar shows: search, then quick filter, then the chosen sort order.
    var filteredLibrary: [GameLibraryEntry] {
        librarySort.sorted(searchMatches.filter(libraryFilter.matches))
    }

    /// Chip counts reflect the current search so they always match what a click would show.
    func filterCount(_ filter: LibraryFilter) -> Int {
        searchMatches.reduce(0) { $0 + (filter.matches($1) ? 1 : 0) }
    }

    var isFiltering: Bool {
        libraryFilter != .all || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func clearFilters() {
        libraryFilter = .all
        searchText = ""
    }

    var selectedEntry: GameLibraryEntry? {
        guard let id = selectedID else { return nil }
        return library.first(where: { $0.id == id })
    }

    var isRunning: Bool { runningGameID != nil }

    var isPresentingModal: Bool {
        showImportSheet || showUpdatesSheet || showControllerSheet || showSystemHealthSheet
            || showPrefixManagerSheet || showCommandPalette || showLaunchHistorySheet || showRemoveConfirm
    }

    var canPlaySelected: Bool {
        selectedEntry != nil && !isRunning && runtimePaths != nil
    }

    // MARK: Menu commands

    func playSelected() {
        guard canPlaySelected, let entry = selectedEntry else { return }
        play(entry)
    }

    func requestSearchFocus() {
        searchFocusRequest &+= 1
    }

    func openControllers() {
        guard !isPresentingModal else { return }
        showControllerSheet = true
    }

    /// ⌘D: open the System Health & Shader Cache sheet.
    func openSystemHealth() {
        guard !isPresentingModal || showSystemHealthSheet else { return }
        showSystemHealthSheet = true
    }

    /// ⇧⌘P: open the APFS Prefix Manager & Storage Inspector sheet.
    func openPrefixManager() {
        guard !isPresentingModal || showPrefixManagerSheet else { return }
        showPrefixManagerSheet = true
    }

    /// ⌘K: open (or toggle) the Quick-Launch Command Palette.
    func openCommandPalette() {
        if showCommandPalette {
            showCommandPalette = false
            return
        }
        guard !isPresentingModal else { return }
        showCommandPalette = true
    }

    /// ⇧⌘H: open the Launch History sheet.
    func openLaunchHistory() {
        guard !isPresentingModal || showLaunchHistorySheet else { return }
        showLaunchHistorySheet = true
    }

    /// ⌘U: open the Updates sheet and re-check GitHub Releases.
    func openUpdates() {
        guard !isPresentingModal || showUpdatesSheet else { return }
        showUpdatesSheet = true
        checkForUpdates()
    }

    func copyLaunchReport(_ diagnostics: LaunchDiagnostics) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(diagnostics.markdownReport, forType: .string)
        statusMessage = "Copied \(diagnostics.title) launch diagnostics — paste it into a GitHub issue."
    }

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

    func toggleFavorite(_ entry: GameLibraryEntry) {
        let nowFav = !(library.first(where: { $0.id == entry.id })?.isFavorite ?? entry.isFavorite)
        update(entry.id) { $0.isFavorite = nowFav }
        statusMessage = nowFav ? "Pinned \(entry.title) to Favorites." : "Removed \(entry.title) from Favorites."
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
        refreshShaderCache()
    }

    func refreshShaderCache() {
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
                GameArtworkManager.shared.invalidate()
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

    func createGameShortcut(_ entry: GameLibraryEntry) {
        let targetDir = ShortcutExporter.defaultShortcutsDirectory()
        do {
            let res = try ShortcutExporter.exportAppBundle(for: entry, into: targetDir, overwrite: true)
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: res.outputPath)])
            statusMessage = "Created Spotlight/Dock shortcut for \(entry.title) in ~/Applications/DirectMetal Games."
        } catch {
            statusMessage = "Could not create shortcut for \(entry.title): \(error)"
        }
    }

    func exportLibraryBackup() {
        let panel = NSSavePanel()
        panel.title = "Export Library Backup"
        panel.message = "Save a portable JSON snapshot of your game settings and controller profiles."
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "DirectMetal-Library-Backup.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let backup = try manager.exportBackup(to: url)
            let gameCount = backup.games.count
            let profileCount = backup.controllerProfiles.count
            statusMessage = "Exported library backup (\(gameCount) game\(gameCount == 1 ? "" : "s"), \(profileCount) controller profile\(profileCount == 1 ? "" : "s")) to \(url.lastPathComponent)."
        } catch {
            statusMessage = "Library backup export failed: \(error)"
        }
    }

    func importLibraryBackup() {
        let panel = NSOpenPanel()
        panel.title = "Import Library Backup"
        panel.message = "Choose a DirectMetal library backup (.json). Existing games and controller profiles are preserved."
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let summary = try manager.importBackup(from: url, overwriteExisting: false)
            reloadLibrary()
            let controllerCount = summary.controllerProfilesRestored
            statusMessage = "Imported backup from \(url.lastPathComponent) — \(summary.added) added, \(summary.skipped) skipped, \(controllerCount) controller profile\(controllerCount == 1 ? "" : "s") restored."
        } catch {
            statusMessage = "Library backup import failed: \(error)"
        }
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
        let startedAt = Date()
        let gpu = gpuSummary

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
                    sandboxed: current.enableSandbox,
                    warmServerSeconds: 180,
                    controllerProfileKey: current.id,
                    fpsCap: current.fpsCap,
                    customEnv: current.customEnvDictionary
                )
                let diagnostics = LaunchDiagnostics.capture(entry: current, startedAt: startedAt, result: result,
                                                            failure: nil, gpuSummary: gpu)
                LaunchHistoryStore().append(LaunchHistoryEntry(from: diagnostics, fpsCap: current.fpsCap,
                                                               upscaleMode: current.upscaleMode))
                DispatchQueue.main.async {
                    self.runningGameID = nil
                    self.manager.recordSessionDuration(id: current.id, seconds: result.elapsedSeconds)
                    self.reloadLibrary()
                    self.lastLaunches[current.id] = diagnostics
                    self.refreshPrefixes()
                    self.statusMessage = String(
                        format: "%@ finished (exit=%d) in %.1f s [engine=%@, CoW=%.2f ms%@]",
                        current.title, result.exitCode, result.elapsedSeconds, result.activeEngine, result.cloneMs,
                        result.sandboxed ? ", seatbelt" : ""
                    )
                }
            } catch {
                let diagnostics = LaunchDiagnostics.capture(entry: current, startedAt: startedAt, result: nil,
                                                            failure: "\(error)", gpuSummary: gpu)
                LaunchHistoryStore().append(LaunchHistoryEntry(from: diagnostics, fpsCap: current.fpsCap,
                                                               upscaleMode: current.upscaleMode))
                DispatchQueue.main.async {
                    self.runningGameID = nil
                    self.lastLaunches[current.id] = diagnostics
                    self.statusMessage = "Launch failed: \(error)"
                }
            }
        }
    }

    // MARK: Warm launch pool

    /// Fire-and-forget warm wineserver for the selected game's existing prefix => Play starts in ~220 ms.
    func prewarmSelectedPrefix() {
        guard runningGameID == nil,
              let entry = selectedEntry,
              entry.engine != .rosetta,
              !entry.enableSandbox,
              let ws = runtimePaths?.arm64ecWineserverBin else { return }
        let prefix = PrefixManager().prefixURL(named: entry.launchPrefixName)
        DispatchQueue.global(qos: .utility).async {
            guard FileManager.default.fileExists(atPath: prefix.path) else { return }
            WineserverPool.warm(prefixURL: prefix, wineserverBin: ws, persistSeconds: 180)
        }
    }

    // MARK: Attestation

    func runAttestationCheck() {
        guard !attestationRunning else { return }
        attestationRunning = true
        let sandbox = selectedEntry?.enableSandbox ?? false
        DispatchQueue.global(qos: .utility).async {
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
    @StateObject private var peripherals = PeripheralMonitor()
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                LibrarySidebar(vm: vm)
                    .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 400)
            } detail: {
                if vm.showGalleryView {
                    GamePosterGridView(vm: vm) { picked in
                        vm.selectedID = picked.id
                        vm.showGalleryView = false
                    }
                } else if let entry = vm.selectedEntry {
                    GameDetailView(vm: vm, peripherals: peripherals, entry: entry)
                        .id(entry.id)
                } else {
                    WelcomeView(vm: vm, peripherals: peripherals)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Picker("View", selection: $vm.showGalleryView) {
                        Image(systemName: "sidebar.left").tag(false).help("Detail Inspector (⌘1)")
                        Image(systemName: "square.grid.2x2").tag(true).help("Poster Gallery (⌘2)")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 72)
                    .help("Switch between Detail Inspector (⌘1) and Poster Gallery (⌘2)")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        vm.openCommandPalette()
                    } label: {
                        Image(systemName: "command")
                    }
                    .help("Quick-Launch Command Palette (⌘K)")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        vm.showPrefixManagerSheet = true
                    } label: {
                        Label("Prefixes", systemImage: "externaldrive.badge.timemachine")
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Inspect, reset, or delete APFS Copy-on-Write prefixes (⇧⌘P)")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        vm.showSystemHealthSheet = true
                    } label: {
                        Label("Health", systemImage: "stethoscope")
                    }
                    .labelStyle(.titleAndIcon)
                    .help("System health diagnostics and shader cache maintenance (⌘D)")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        vm.showControllerSheet = true
                    } label: {
                        Label("Controllers", systemImage: "gamecontroller")
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Controller remapping, dead zones, haptics and live input tester")
                }
                ToolbarItem(placement: .primaryAction) {
                    UpdateToolbarButton(vm: vm)
                }
            }
            Divider()
            LauncherStatusBar(vm: vm)
        }
        .frame(minWidth: 920, minHeight: 600)
        .focusedSceneObject(vm)
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
        .sheet(isPresented: $vm.showUpdatesSheet) {
            UpdatesSheet(vm: vm)
        }
        .sheet(isPresented: $vm.showControllerSheet) {
            ControllerMappingSheet(entry: vm.selectedEntry)
        }
        .sheet(isPresented: $vm.showSystemHealthSheet) {
            SystemHealthSheet(vm: vm)
        }
        .sheet(isPresented: $vm.showPrefixManagerSheet) {
            PrefixManagerSheet(vm: vm)
        }
        .sheet(isPresented: $vm.showCommandPalette) {
            CommandPaletteSheet(vm: vm)
        }
        .sheet(isPresented: $vm.showLaunchHistorySheet) {
            LaunchHistorySheet(vm: vm)
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

// MARK: - App

/// Stops every warm wineserver this GUI started, so quitting leaves zero orphan daemons.
final class DirectMetalAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        WineserverPool.stopAll()
    }
}

struct DirectMetalDesktopApp: App {
    @NSApplicationDelegateAdaptor(DirectMetalAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("DirectMetal") {
            DirectMetalContentView()
        }
        .defaultSize(width: 1120, height: 760)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands { DirectMetalCommands() }
    }
}

/// Native menu bar commands + keyboard shortcuts, routed to the key window's view model.
struct DirectMetalCommands: Commands {
    @FocusedObject private var vm: DirectMetalViewModel?

    private var modal: Bool { vm?.isPresentingModal ?? true }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { vm?.openUpdates() }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(vm == nil || (modal && vm?.showUpdatesSheet != true))
            Button("System Health & Cache…") { vm?.openSystemHealth() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(vm == nil || (modal && vm?.showSystemHealthSheet != true))
            Button("APFS Prefixes & Storage…") { vm?.openPrefixManager() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(vm == nil || (modal && vm?.showPrefixManagerSheet != true))
            Button("Launch History…") { vm?.openLaunchHistory() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(vm == nil || (modal && vm?.showLaunchHistorySheet != true))
        }
        CommandGroup(replacing: .appSettings) {
            Button("Controllers…") { vm?.openControllers() }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(modal)
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Add .exe or Game Folder…") { vm?.openAddPanel() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(modal)
            Button("Scan Library") { vm?.scanLibrary() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(vm == nil || vm?.isScanning == true)
            Divider()
            Button("Export Library Backup…") { vm?.exportLibraryBackup() }
                .disabled(modal)
            Button("Import Library Backup…") { vm?.importLibraryBackup() }
                .disabled(modal)
        }
        CommandMenu("Library") {
            Button("Quick Launch…") { vm?.openCommandPalette() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(vm == nil || (modal && vm?.showCommandPalette != true))
            Button(vm?.selectedEntry.map { "Play \($0.title)" } ?? "Play Selected Game") { vm?.playSelected() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(modal || !(vm?.canPlaySelected ?? false))
            Button("Find Game…") { vm?.requestSearchFocus() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(vm == nil)
            Divider()
            Button("Detail Inspector") { vm?.showGalleryView = false }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(vm == nil)
            Button("Poster Gallery") { vm?.showGalleryView = true }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(vm == nil)
            Divider()
            Picker("Filter", selection: Binding(get: { vm?.libraryFilter ?? .all },
                                                set: { vm?.libraryFilter = $0 })) {
                ForEach(LibraryFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .disabled(vm == nil)
            Picker("Sort By", selection: Binding(get: { vm?.librarySort ?? .recent },
                                                 set: { vm?.librarySort = $0 })) {
                ForEach(LibrarySort.allCases) { Text($0.rawValue).tag($0) }
            }
            .disabled(vm == nil)
            Divider()
            Button("Show in Finder") {
                if let vm, let e = vm.selectedEntry { vm.revealInFinder(e) }
            }
            .disabled(vm?.selectedEntry == nil)
            Button("Create Spotlight / Dock Shortcut") {
                if let vm, let e = vm.selectedEntry { vm.createGameShortcut(e) }
            }
            .disabled(vm?.selectedEntry == nil)
            Button("Re-inspect Executable") {
                if let vm, let e = vm.selectedEntry { vm.reinspect(e) }
            }
            .disabled(vm?.selectedEntry == nil)
            Button("Copy Last Launch Report") {
                if let vm, let id = vm.selectedID, let d = vm.lastLaunches[id] { vm.copyLaunchReport(d) }
            }
            .disabled(vm?.selectedID.flatMap { vm?.lastLaunches[$0] } == nil)
            Divider()
            Button("Remove from Library…") { vm?.showRemoveConfirm = true }
                .disabled(modal || vm?.selectedEntry == nil)
        }
    }
}
