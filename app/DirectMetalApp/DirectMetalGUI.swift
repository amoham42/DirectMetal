import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Launcher shell: view model, root split view, library sidebar, game detail, welcome screen and app.
// Components: LauncherComponents.swift · Updates/runtime: UpdatesAndRuntimeSheets.swift ·
// Controllers: ControllerMappingSheet.swift

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
        showImportSheet || showUpdatesSheet || showControllerSheet || showRemoveConfirm
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
                    controllerProfileKey: current.id
                )
                let diagnostics = LaunchDiagnostics.capture(entry: current, startedAt: startedAt, result: result,
                                                            failure: nil, gpuSummary: gpu)
                DispatchQueue.main.async {
                    self.runningGameID = nil
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
                if let entry = vm.selectedEntry {
                    GameDetailView(vm: vm, peripherals: peripherals, entry: entry)
                        .id(entry.id)
                } else {
                    WelcomeView(vm: vm, peripherals: peripherals)
                }
            }
            .toolbar {
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
    @FocusState private var searchFocused: Bool

    private var headerText: String {
        let shown = vm.filteredLibrary.count
        return vm.isFiltering ? "Showing \(shown) of \(vm.library.count)" : "Library — \(vm.library.count)"
    }

    private var emptyText: String {
        let q = vm.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = vm.libraryFilter == .all ? "" : " in \(vm.libraryFilter.rawValue)"
        return q.isEmpty ? "No \(vm.libraryFilter.rawValue) games in your library" : "No matches for “\(q)”\(scope)"
    }

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
                HStack {
                    Text(headerText)
                    Spacer()
                    Label(vm.librarySort.rawValue, systemImage: vm.librarySort.systemImage)
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $vm.searchText, placement: .sidebar, prompt: "Search games (⌘F)")
        .searchFocused($searchFocused)
        .onChange(of: vm.searchFocusRequest) {
            searchFocused = true
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !vm.library.isEmpty {
                filterBar
            }
        }
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
                VStack(spacing: 6) {
                    Text(emptyText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Clear Filters") { vm.clearFilters() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
                .padding(.horizontal, 16)
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

    /// Quick filter chips (with live counts) + sort menu.
    private var filterBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(LibraryFilter.allCases) { filter in
                        FilterChip(title: filter.rawValue, count: vm.filterCount(filter), tint: filter.tint,
                                   isSelected: vm.libraryFilter == filter) {
                            vm.libraryFilter = (vm.libraryFilter == filter && filter != .all) ? .all : filter
                        }
                        .help(filter.help)
                    }
                }
                .padding(.vertical, 1)
            }
            Menu {
                Picker("Sort By", selection: $vm.librarySort) {
                    ForEach(LibrarySort.allCases) { sort in
                        Label(sort.rawValue, systemImage: sort.systemImage).tag(sort)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort library: \(vm.librarySort.rawValue)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

// MARK: - Detail

struct GameDetailView: View {
    @ObservedObject var vm: DirectMetalViewModel
    @ObservedObject var peripherals: PeripheralMonitor
    let entry: GameLibraryEntry

    private var live: GameLibraryEntry { vm.library.first(where: { $0.id == entry.id }) ?? entry }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if vm.runtimePaths == nil {
                    RuntimeSetupCard(vm: vm)
                }
                header
                PeripheralStrip(monitor: peripherals, onControllers: { vm.showControllerSheet = true })
                peProfileCard
                settingsPanel
                LaunchDiagnosticsDrawer(diagnostics: vm.lastLaunches[entry.id]) { vm.copyLaunchReport($0) }
                shaderCachePanel
                AttestationSecurityCard(vm: vm)
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
            GameArtworkView(entry: e, style: .banner, size: 76, wideWidth: 163)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(e.title)
                        .font(.system(size: 28, weight: .bold))
                        .lineLimit(1)
                    StorePill(source: e.storeSource, gameID: e.storeGameID)
                }
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
                if e.profileNote != nil || e.profileID != nil {
                    ProfilePresetPill(entry: e, profile: vm.profile(for: e))
                }
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
                if let info = StorePill.info(e.storeSource) {
                    GridRow {
                        Text("Storefront").foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            StorePill(source: e.storeSource, gameID: e.storeGameID)
                            Text(e.storeGameID.map { "\(info.label) ID \($0)" }
                                 ?? e.steamAppID.map { "Steam app \($0)" } ?? info.label)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
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
}

// MARK: - Welcome / empty state

struct WelcomeView: View {
    @ObservedObject var vm: DirectMetalViewModel
    @ObservedObject var peripherals: PeripheralMonitor

    var body: some View {
        VStack(spacing: 18) {
            if vm.runtimePaths == nil {
                RuntimeSetupCard(vm: vm)
                    .frame(maxWidth: 620)
                    .padding(.bottom, 6)
            }
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
            PeripheralStrip(monitor: peripherals, onControllers: { vm.showControllerSheet = true })
                .fixedSize()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("DirectMetal")
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
        }
        CommandMenu("Library") {
            Button(vm?.selectedEntry.map { "Play \($0.title)" } ?? "Play Selected Game") { vm?.playSelected() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(modal || !(vm?.canPlaySelected ?? false))
            Button("Find Game…") { vm?.requestSearchFocus() }
                .keyboardShortcut("f", modifiers: .command)
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
