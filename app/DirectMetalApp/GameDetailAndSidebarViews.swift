import SwiftUI

// Sidebar, per-game detail inspector, and empty/welcome state views.
// Shell & view model: DirectMetalGUI.swift · Components: LauncherComponents.swift

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
                            Button(entry.isFavorite ? "Remove from Favorites" : "Pin to Favorites") {
                                vm.toggleFavorite(entry)
                            }
                            Divider()
                            Button("Inspect Launch Plan…") {
                                vm.selectedID = entry.id
                                vm.openLaunchPlan()
                            }
                            Button("Create Spotlight / Dock Shortcut") { vm.createGameShortcut(entry) }
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
                    Button {
                        vm.toggleFavorite(e)
                    } label: {
                        Image(systemName: e.isFavorite ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundStyle(e.isFavorite ? Color.yellow : Color.secondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help(e.isFavorite ? "Remove from Favorites" : "Pin to Favorites")
                    .accessibilityLabel(e.isFavorite ? "Remove \(e.title) from Favorites" : "Pin \(e.title) to Favorites")
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
                    if let pt = LauncherStyle.playtimeText(e.totalPlaySeconds) {
                        Label(pt, systemImage: "timer")
                    }
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
                        Text("FPS Cap").foregroundStyle(.secondary)
                        Picker("FPS Cap", selection: vm.binding(e, \.fpsCap)) {
                            ForEach(LauncherStyle.fpsCapOptions, id: \.cap) { opt in
                                Text(opt.label).tag(opt.cap)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 200)
                        .help("Frame-rate limiter for Mullion (dxgi.maxFrameRate), DXMT & DXVK; 40 FPS paces cleanly 3:1 on 120 Hz ProMotion")
                    }
                    GridRow {
                        Text("Extra Args").foregroundStyle(.secondary)
                        TextField("e.g. -windowed -dx11 \"-name=With Spaces\"", text: vm.binding(e, \.extraArgs))
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                    }
                    GridRow {
                        Text("Env Vars").foregroundStyle(.secondary)
                        TextField("e.g. WINEDLLOVERRIDES=\"version=n,b\" LC_ALL=ja_JP.UTF-8", text: vm.binding(e, \.customEnv))
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                            .help("Space-separated KEY=VAL overrides (quotes supported; WINEDLLOVERRIDES appends safely; WINEPREFIX/DYLD_* blocked)")
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
                if !e.customEnv.isEmpty || !e.extraArgs.isEmpty {
                    let lintReport = LaunchEnvValidator.validate(entry: e)
                    if !lintReport.isClean {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(lintReport.issues.prefix(4)) { issue in
                                let tint: Color = {
                                    switch issue.severity {
                                    case .error: return .red
                                    case .warning: return .orange
                                    case .info: return .blue
                                    }
                                }()
                                let icon: String = {
                                    switch issue.severity {
                                    case .error: return "xmark.octagon.fill"
                                    case .warning: return "exclamationmark.triangle.fill"
                                    case .info: return "info.circle.fill"
                                    }
                                }()
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: icon)
                                        .font(.caption)
                                        .foregroundStyle(tint)
                                        .padding(.top, 1)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("\(issue.keyOrToken): \(issue.message)")
                                            .font(.caption.weight(.medium))
                                        Text(issue.suggestion)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            if lintReport.issues.count > 4 {
                                Text("+\(lintReport.issues.count - 4) more advisories — run `DirectMetal library lint` for full details.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background((lintReport.hasErrors ? Color.red : Color.orange).opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder((lintReport.hasErrors ? Color.red : Color.orange).opacity(0.25))
                        )
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
            let matchedProfile = vm.profile(for: e)
            let diff = ConfigDiffEngine.diff(entry: e, profile: matchedProfile)
            HStack(spacing: 8) {
                Label("Per-Game Settings", systemImage: "slider.horizontal.3")
                if diff.hasCustomizations {
                    Text("\(diff.modifiedCount) customized")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .foregroundStyle(.blue)
                        .background(Color.blue.opacity(0.14), in: Capsule())
                }
                Spacer()
                if diff.hasCustomizations {
                    Button(matchedProfile != nil ? "Reset to Preset" : "Reset to Defaults") {
                        vm.update(e.id) { ConfigDiffEngine.resetSettings(of: &$0, using: matchedProfile) }
                        vm.statusMessage = "Reset \(e.title) settings to \(diff.baselineName)."
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Restore per-game settings to \(diff.baselineName) (playtime, favorites, and prefix stay untouched)")
                }
            }
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
