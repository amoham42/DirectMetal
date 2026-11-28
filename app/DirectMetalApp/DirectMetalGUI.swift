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

/// Compact storefront pill (Steam / GOG / Epic); renders nothing for standalone / unknown games.
struct StorePill: View {
    let source: String?
    var gameID: String? = nil

    static func info(_ source: String?) -> (label: String, color: Color)? {
        switch source?.lowercased() {
        case "steam": return ("Steam", Color(red: 0.10, green: 0.27, blue: 0.47))
        case "gog": return ("GOG", Color(red: 0.49, green: 0.18, blue: 0.62))
        case "epic": return ("Epic", Color(white: 0.22))
        default: return nil
        }
    }

    var body: some View {
        if let info = StorePill.info(source) {
            Text(info.label)
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .foregroundStyle(.white)
                .background(info.color, in: Capsule())
                .help(gameID.map { "\(info.label) game ID \($0)" } ?? "Installed by \(info.label)")
        }
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

/// Real game artwork (Steam library art or the `.exe`'s embedded icon) with a `GameMonogram` fallback.
/// Artwork is decoded on a background queue and cached, so list scrolling never touches the disk.
struct GameArtworkView: View {
    let entry: GameLibraryEntry
    var style: ArtworkStyle = .icon
    var size: CGFloat = 34
    /// Frame width for wide art (Steam header banners); `nil` keeps every artwork square.
    var wideWidth: CGFloat? = nil
    @State private var image: NSImage?

    init(entry: GameLibraryEntry, style: ArtworkStyle = .icon, size: CGFloat = 34, wideWidth: CGFloat? = nil) {
        self.entry = entry
        self.style = style
        self.size = size
        self.wideWidth = wideWidth
        _image = State(initialValue: GameArtworkManager.shared.cachedArtwork(for: entry, style: style))
    }

    private var loadKey: String { GameArtworkManager.artworkKey(entry, style) }

    var body: some View {
        Group {
            if let image {
                let wide = image.size.width > image.size.height * 1.3
                let width = wide ? (wideWidth ?? size) : size
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * (wide ? 0.14 : 0.2), style: .continuous))
                    .shadow(color: .black.opacity(wide ? 0.22 : 0.12), radius: size * 0.06, y: size * 0.03)
            } else {
                GameMonogram(title: entry.title, size: size)
            }
        }
        .task(id: loadKey) { await load() }
    }

    private func load() async {
        let e = entry
        let s = style
        if let cached = GameArtworkManager.shared.cachedArtwork(for: e, style: s) {
            image = cached
            return
        }
        let box = await withCheckedContinuation { (cont: CheckedContinuation<ArtworkBox, Never>) in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: ArtworkBox(image: GameArtworkManager.shared.loadArtwork(for: e, style: s)))
            }
        }
        if !Task.isCancelled { image = box.image }
    }
}

private struct ArtworkBox: @unchecked Sendable {
    let image: NSImage?
}

/// "Community preset" pill + note for entries seeded from `game_profiles.json`.
struct ProfilePresetPill: View {
    let entry: GameLibraryEntry
    let profile: GameProfile?

    var body: some View {
        let verified = profile?.isVerified ?? false
        let tint: Color = verified ? .green : .orange
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Label("Community preset · \(profile?.title ?? entry.profileID ?? "Custom")",
                      systemImage: verified ? "checkmark.seal.fill" : "sparkles")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .foregroundStyle(tint)
                    .background(tint.opacity(0.14), in: Capsule())
                if let profile {
                    Text(profile.verificationLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let note = entry.profileNote, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(note)
            }
        }
    }
}

struct PeripheralChip: View {
    let icon: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.10), in: Capsule())
    }
}

/// Display (Retina / ProMotion / HDR-EDR) and game controller strip, live-updated by `PeripheralMonitor`.
struct PeripheralStrip: View {
    @ObservedObject var monitor: PeripheralMonitor
    /// Opens the controller remapping / dead zone sheet when set.
    var onControllers: (() -> Void)? = nil

    var body: some View {
        let d = monitor.display
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                PeripheralChip(icon: "display", text: d.resolutionLabel, tint: d.isRetina ? .blue : .secondary)
                    .help("\(d.displayName): \(d.pixelWidth)×\(d.pixelHeight) px, \(d.dpi) DPI LogPixels with Retina mode")
                PeripheralChip(icon: "gauge.with.dots.needle.67percent", text: d.refreshLabel,
                               tint: d.isProMotion ? .purple : .secondary)
                    .help(d.variableRefresh ? "Variable refresh (ProMotion / Adaptive-Sync)" : "Fixed refresh rate")
                PeripheralChip(icon: d.supportsHDR ? "sun.max.fill" : "sun.min", text: d.hdrLabel,
                               tint: d.supportsHDR ? .orange : .secondary)
                    .help(String(format: "EDR headroom now %.2fx, maximum %.2fx", d.edrHeadroom, d.potentialEDRHeadroom))
                Divider().frame(height: 14)
                if monitor.controllers.isEmpty {
                    PeripheralChip(icon: "gamecontroller", text: "No controller")
                        .help("Connect a Bluetooth or USB game controller; it appears here automatically.")
                } else {
                    ForEach(monitor.controllers) { c in
                        PeripheralChip(icon: "gamecontroller.fill", text: c.summary, tint: .green)
                            .help("\(c.productCategory)\(c.batteryState.map { " · \($0)" } ?? "")")
                    }
                }
                if let onControllers {
                    Button {
                        onControllers()
                    } label: {
                        Label("Controllers…", systemImage: "slider.horizontal.3")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Remap buttons, tune stick dead zones and haptics, and test controller input live")
                }
            }
            .padding(.vertical, 1)
        }
        .onAppear { monitor.refresh() }
    }
}

/// Toolbar pill: opens the Updates sheet (DirectMetal app + MetalSharp-Wine runtime) and reflects the last check.
struct UpdateToolbarButton: View {
    @ObservedObject var vm: DirectMetalViewModel

    var body: some View {
        Group {
            if vm.updateChecking {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text("Checking…").font(.callout)
                }
            } else if let s = vm.dualStatus, s.anyUpdateAvailable {
                Button {
                    vm.showUpdatesSheet = true
                } label: {
                    Label(s.app.updateAvailable ? "Update \(s.app.latestVersion ?? "")" : "Runtime \(s.runtime.latestVersion ?? "")",
                          systemImage: "arrow.down.circle.fill")
                }
                .tint(.green)
                .help(s.app.updateAvailable
                      ? "DirectMetal \(s.app.latestVersion ?? "") is available (you have \(s.app.currentVersion))"
                      : "MetalSharp-Wine \(s.runtime.latestVersion ?? "") is available (you have \(s.runtime.currentVersion))")
            } else if let r = vm.updateResult, r.error == nil, !r.disabled {
                Button {
                    vm.showUpdatesSheet = true
                } label: {
                    Label("Updates", systemImage: "checkmark.circle")
                }
                .help("DirectMetal \(r.currentVersion) is the latest release — open Updates")
            } else {
                Button {
                    vm.showUpdatesSheet = true
                } label: {
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                }
                .help(vm.updateResult?.error ?? "Check GitHub Releases for DirectMetal and MetalSharp-Wine runtime updates")
            }
        }
        .labelStyle(.titleAndIcon)
    }
}

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

    private let manager = GameLibraryManager()

    /// Community profile that seeded `entry` (for the preset pill), if any.
    func profile(for entry: GameLibraryEntry) -> GameProfile? {
        manager.profileRegistry.profile(id: entry.profileID)
    }

    /// Checks DirectMetal + MetalSharp-Wine releases concurrently (never blocks the main thread).
    func checkForUpdates() {
        guard !updateChecking else { return }
        updateChecking = true
        AppUpdater.checkAllAsync { [weak self] status in
            guard let self else { return }
            self.updateChecking = false
            self.dualStatus = status
            let result = status.app
            self.updateResult = result
            if result.disabled {
                self.statusMessage = "Update check disabled (DIRECTMETAL_DISABLE_UPDATE_CHECK=1)."
            } else if let err = result.error {
                self.statusMessage = "Update check failed: \(err)"
            } else if result.updateAvailable {
                self.statusMessage = "DirectMetal \(result.latestVersion ?? "") is available (installed: \(result.currentVersion))."
            } else if status.runtime.updateAvailable {
                self.statusMessage = "MetalSharp-Wine \(status.runtime.latestVersion ?? "") runtime is available (installed: \(status.runtime.currentVersion))."
            } else {
                self.statusMessage = "DirectMetal \(result.currentVersion) is up to date."
            }
        }
    }

    /// Downloads the release DMG, verifies SHA-256 + code signature, and atomically replaces this `.app`.
    func installAppUpdate() {
        guard !appUpdateRunning else { return }
        guard runningGameID == nil else {
            appUpdateError = "Quit the running game before updating DirectMetal."
            return
        }
        guard let app = dualStatus?.app ?? updateResult, let dmg = app.dmgURL, let dmgURL = URL(string: dmg) else {
            appUpdateError = "This release has no \(AppUpdater.runningEdition().assetName) download."
            return
        }
        let shaURL = app.sha256URL.flatMap { URL(string: $0) }
        let version = app.latestVersion ?? "?"
        appUpdateRunning = true
        appUpdateError = nil
        appUpdateInstalledURL = nil
        appUpdatePhase = "Preparing…"
        appUpdateFraction = -1
        appUpdateBytes = 0
        appUpdateTotal = app.assetSize ?? -1
        statusMessage = "Downloading DirectMetal \(version)…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let installed = try AppUpdater.applyAppUpdate(dmgURL: dmgURL, expectedSHA256: nil, sha256URL: shaURL) { p in
                    DispatchQueue.main.async {
                        self.appUpdatePhase = p.message
                        self.appUpdateFraction = p.fraction
                        if p.phase == .downloading, p.bytesReceived > 0 {
                            self.appUpdateBytes = p.bytesReceived
                            self.appUpdateTotal = p.totalBytes
                        }
                    }
                }
                DispatchQueue.main.async {
                    self.appUpdateRunning = false
                    self.appUpdateInstalledURL = installed
                    self.appUpdatePhase = "Installed — relaunch to finish."
                    self.statusMessage = "DirectMetal \(version) installed at \(installed.path) — relaunch to finish."
                }
            } catch {
                let msg = "\(error)"
                DispatchQueue.main.async {
                    self.appUpdateRunning = false
                    self.appUpdateError = msg
                    self.statusMessage = "DirectMetal update failed: \(msg)"
                }
            }
        }
    }

    /// Starts the freshly installed bundle, then quits this (old) process.
    func relaunchAfterUpdate() {
        guard let url = appUpdateInstalledURL else { return }
        AppUpdater.relaunchApp(at: url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }

    /// Installs the latest MetalSharp-Wine release (SHA256SUMS + codesign verified) through RuntimeManager.
    func updateRuntimeToLatest() {
        guard !runtimeUpdateRunning, !runtimeInstallRunning else { return }
        guard runningGameID == nil else {
            runtimeUpdateError = "Quit the running game before updating the runtime."
            return
        }
        runtimeUpdateRunning = true
        runtimeUpdateError = nil
        runtimeUpdateDone = nil
        runtimeUpdatePhase = "Preparing…"
        runtimeUpdateFraction = -1
        statusMessage = "Updating MetalSharp-Wine runtime…"
        WineserverPool.stopAll()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let root = try AppUpdater.updateRuntime { p in
                    DispatchQueue.main.async {
                        self.runtimeUpdatePhase = p.message
                        self.runtimeUpdateFraction = p.fraction
                    }
                }
                let paths = try? RuntimeLauncher.resolveRuntimePaths()
                let version = AppUpdater.installedRuntimeVersion()
                DispatchQueue.main.async {
                    self.runtimeUpdateRunning = false
                    self.runtimePaths = paths
                    self.runtimeUpdateDone = "MetalSharp-Wine \(version) ready at \(root.path)"
                    self.statusMessage = "MetalSharp-Wine \(version) runtime ready."
                    self.checkForUpdates()
                }
            } catch {
                let msg = "\(error)"
                DispatchQueue.main.async {
                    self.runtimeUpdateRunning = false
                    self.runtimeUpdateError = msg
                    self.statusMessage = "Runtime update failed: \(msg)"
                }
            }
        }
    }

    func openReleasePage() {
        let fallback = "https://github.com/amoham42/DirectMetal/releases/latest"
        guard let url = URL(string: updateResult?.releaseURL ?? fallback), url.scheme?.lowercased() == "https" else { return }
        NSWorkspace.shared.open(url)
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

    var filteredLibrary: [GameLibraryEntry] {
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

    // MARK: Runtime install + warm launch pool

    /// One-click DirectMetal-Lite runtime install: streaming download, SHA-256, ditto, codesign, atomic install.
    func installRuntime() {
        guard !runtimeInstallRunning else { return }
        runtimeInstallRunning = true
        runtimeInstallError = nil
        runtimeInstallPhase = "Preparing…"
        runtimeInstallFraction = -1
        runtimeInstallBytes = 0
        runtimeInstallTotal = -1
        statusMessage = "Installing DirectMetal runtime \(RuntimeManager.arm64ecVersion)…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let root = try RuntimeManager.installARM64ECRuntime { p in
                    DispatchQueue.main.async {
                        self.runtimeInstallPhase = p.message
                        self.runtimeInstallFraction = p.fraction
                        if p.bytesReceived > 0 || p.phase == .downloading {
                            self.runtimeInstallBytes = p.bytesReceived
                            self.runtimeInstallTotal = p.totalBytes
                        }
                    }
                }
                let paths = try? RuntimeLauncher.resolveRuntimePaths()
                DispatchQueue.main.async {
                    self.runtimeInstallRunning = false
                    self.runtimePaths = paths
                    self.statusMessage = paths != nil
                        ? "DirectMetal runtime installed at \(root.path) — Play is ready."
                        : "Runtime installed at \(root.path), but it could not be resolved."
                    self.prewarmSelectedPrefix()
                }
            } catch {
                let msg = "\(error)"
                DispatchQueue.main.async {
                    self.runtimeInstallRunning = false
                    self.runtimeInstallError = msg
                    self.statusMessage = "Runtime install failed: \(msg)"
                }
            }
        }
    }

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
        let selectedHash = selectedEntry?.buildHash ?? ""
        let isIndex = lower.hasSuffix(".json")
        isCacheBusy = true
        statusMessage = isIndex
            ? "Syncing matching GPU/OS shader cache from index…"
            : (lower.hasPrefix("https://") ? "Downloading & verifying shader cache…" : "Verifying & importing shader cache…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let res: ShaderCacheImportResult
                if isIndex, !selectedHash.isEmpty {
                    res = try ShaderCacheManager.syncFromIndex(
                        indexSource: resolved,
                        buildHash: selectedHash,
                        allowCrossBuild: allowCross
                    )
                } else {
                    res = try ShaderCacheManager.importArchive(from: resolved, allowCrossBuild: allowCross)
                }
                let msg = "Synced & verified \(res.verifiedFiles) shader files (\(res.gpuFamily)/\(res.macosBuild))."
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
            GameArtworkView(entry: entry, style: .icon, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.system(.body, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    StorePill(source: entry.storeSource, gameID: entry.storeGameID)
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
                        StatusPill(
                            title: "DCAppAttest",
                            value: st.appAttestProvisioned ? "Provisioned" : (st.dcAppAttestSupported ? "OS Ready (Dev ID)" : "Unsupported"),
                            ok: st.dcAppAttestSupported
                        )
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
            Divider().frame(height: 12)
            Text("v\(RuntimeLauncher.appVersion())")
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
            Text("Paste an https:// URL to a cloud index.json or .dmcache.tar.gz archive, or choose a local file. Archives and every individual shader file are SHA-256 verified before installation.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("https://example.com/index.json  or  /path/to/cache.dmcache.tar.gz",
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

// MARK: - Lite runtime setup card

struct RuntimeSetupCard: View {
    @ObservedObject var vm: DirectMetalViewModel

    private func mb(_ bytes: Int64) -> String {
        String(format: "%.0f MB", Double(max(bytes, 0)) / 1_000_000.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "shippingbox.and.arrow.backward.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set up the DirectMetal Runtime")
                        .font(.title3.bold())
                    Text("DirectMetal Lite downloads the notarized MetalSharp-Wine \(RuntimeManager.arm64ecVersion) ARM64EC + FEX runtime once. Every byte is SHA-256 verified and its Apple Developer ID signature checked before install.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if vm.runtimeInstallRunning {
                VStack(alignment: .leading, spacing: 6) {
                    if vm.runtimeInstallFraction >= 0 {
                        ProgressView(value: min(max(vm.runtimeInstallFraction, 0), 1))
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    HStack {
                        Text(vm.runtimeInstallPhase)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        if vm.runtimeInstallBytes > 0 {
                            Text(vm.runtimeInstallTotal > 0
                                 ? "\(mb(vm.runtimeInstallBytes)) / \(mb(vm.runtimeInstallTotal))"
                                 : mb(vm.runtimeInstallBytes))
                                .monospacedDigit()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 10) {
                    Button {
                        vm.installRuntime()
                    } label: {
                        Label("Install DirectMetal Runtime (\(RuntimeManager.archiveSizeLabel), SHA-256 & Apple Notarized)",
                              systemImage: "arrow.down.circle.fill")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Spacer(minLength: 0)
                }
                if let err = vm.runtimeInstallError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }

            Text("Installs to \(RuntimeManager.userARM64ECRuntimeDir().path)")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color.blue.opacity(0.16), Color.purple.opacity(0.10)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor.opacity(0.35)))
    }
}

// MARK: - Updates sheet (DirectMetal app + MetalSharp-Wine runtime)

struct UpdatesSheet: View {
    @ObservedObject var vm: DirectMetalViewModel
    @Environment(\.dismiss) private var dismiss

    private var busy: Bool { vm.appUpdateRunning || vm.runtimeUpdateRunning }

    private func mb(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(max(bytes, 0)) / 1_000_000.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Label("Software Updates", systemImage: "arrow.down.circle")
                    .font(.title2.bold())
                Spacer()
                if vm.updateChecking { ProgressView().controlSize(.small) }
                Button("Check Again") { vm.checkForUpdates() }
                    .disabled(vm.updateChecking || busy)
            }
            appCard
            runtimeCard
            HStack(alignment: .top) {
                Text("Downloads come from GitHub Releases over HTTPS. Every update is SHA-256 verified and code-signature checked before anything on disk is replaced; the app swap is atomic and rolls back on failure.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(busy)
            }
        }
        .padding(22)
        .frame(width: 620)
        .onAppear {
            if vm.dualStatus == nil && !vm.updateChecking { vm.checkForUpdates() }
        }
    }

    private func versionRow(current: String, latest: String?, available: Bool) -> some View {
        HStack(spacing: 8) {
            Text(current).font(.system(.title3, design: .monospaced).weight(.semibold))
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            Text(latest ?? "—")
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundStyle(available ? Color.green : Color.primary)
            if available {
                Text("NEW")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .foregroundStyle(.white)
                    .background(Color.green, in: Capsule())
            }
        }
    }

    private func progressBlock(fraction: Double, phase: String, bytes: Int64, total: Int64) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if fraction >= 0 {
                ProgressView(value: min(max(fraction, 0), 1))
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Text(phase).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if bytes > 0 {
                    Text(total > 0 ? "\(mb(bytes)) / \(mb(total))" : mb(bytes)).monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var appCard: some View {
        let app = vm.dualStatus?.app ?? vm.updateResult
        let edition = AppUpdater.runningEdition()
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                versionRow(current: app?.currentVersion ?? RuntimeLauncher.appVersion(), latest: app?.latestVersion,
                           available: app?.updateAvailable ?? false)
                if let app {
                    if app.disabled {
                        Text("Update checks are disabled (DIRECTMETAL_DISABLE_UPDATE_CHECK=1).").font(.callout).foregroundStyle(.secondary)
                    } else if let err = app.error {
                        Label(err, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    } else if !app.updateAvailable && vm.appUpdateInstalledURL == nil {
                        Label("DirectMetal is up to date.", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                    }
                } else if vm.updateChecking {
                    Text("Checking GitHub Releases…").font(.callout).foregroundStyle(.secondary)
                }

                if vm.appUpdateRunning {
                    progressBlock(fraction: vm.appUpdateFraction, phase: vm.appUpdatePhase,
                                  bytes: vm.appUpdateBytes, total: vm.appUpdateTotal)
                } else if let installed = vm.appUpdateInstalledURL {
                    HStack(spacing: 10) {
                        Label("Installed \(installed.lastPathComponent) — relaunch to finish.", systemImage: "checkmark.seal.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                        Spacer(minLength: 8)
                        Button {
                            vm.relaunchAfterUpdate()
                        } label: {
                            Label("Relaunch DirectMetal", systemImage: "arrow.clockwise.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if let app, app.updateAvailable {
                    HStack(spacing: 10) {
                        Button {
                            vm.installAppUpdate()
                        } label: {
                            Label("Download & Install Update" + (app.assetSize.map { " (\(mb($0)))" } ?? ""),
                                  systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(app.dmgURL == nil || vm.isRunning || vm.runtimeUpdateRunning)
                        Button("Release Notes") { vm.openReleasePage() }
                            .buttonStyle(.link)
                        Spacer(minLength: 0)
                    }
                    if app.dmgURL == nil {
                        Text("This release has no \(edition.assetName) download yet.").font(.caption).foregroundStyle(.orange)
                    } else if app.sha256URL == nil {
                        Text("This release publishes no .sha256 checksum, so in-app install is refused for safety.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if let err = vm.appUpdateError {
                    Label(err, systemImage: "xmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Label("\(edition.displayName) App", systemImage: "app.badge")
        }
    }

    private var runtimeCard: some View {
        let rt = vm.dualStatus?.runtime
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                versionRow(current: rt?.currentVersion ?? RuntimeManager.arm64ecVersion, latest: rt?.latestVersion,
                           available: rt?.updateAvailable ?? false)
                if let rt {
                    if let err = rt.error, !rt.disabled {
                        Label(err, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    } else if !rt.installed {
                        Text("No runtime installed yet — use “Install DirectMetal Runtime”, or install the latest release below.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if !rt.updateAvailable && !rt.disabled {
                        Label("MetalSharp-Wine runtime is up to date.", systemImage: "checkmark.circle.fill")
                            .font(.callout).foregroundStyle(.green)
                    }
                }
                if vm.runtimeUpdateRunning {
                    progressBlock(fraction: vm.runtimeUpdateFraction, phase: vm.runtimeUpdatePhase, bytes: 0, total: -1)
                } else if let rt, rt.updateAvailable || (!rt.installed && rt.zipURL != nil) {
                    HStack(spacing: 10) {
                        Button {
                            vm.updateRuntimeToLatest()
                        } label: {
                            Label("Update Runtime" + (rt.assetSize.map { " (\(mb($0)))" } ?? ""), systemImage: "shippingbox.and.arrow.backward.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(rt.zipURL == nil || vm.isRunning || vm.appUpdateRunning)
                        if let page = rt.releaseURL, let url = URL(string: page), url.scheme == "https" {
                            Button("Release Notes") { NSWorkspace.shared.open(url) }.buttonStyle(.link)
                        }
                        Spacer(minLength: 0)
                    }
                }
                if let done = vm.runtimeUpdateDone {
                    Label(done, systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green).textSelection(.enabled)
                }
                if let err = vm.runtimeUpdateError {
                    Label(err, systemImage: "xmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Label("MetalSharp-Wine Runtime (ARM64EC + FEX)", systemImage: "shippingbox")
        }
    }
}

// MARK: - Controller mapping, dead zones + live tester

struct ControllerMappingSheet: View {
    let entry: GameLibraryEntry?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var tester = ControllerLiveTester()
    @State private var perGame: Bool
    @State private var draft: ControllerMappingProfile
    @State private var source: String
    @State private var saveError: String?
    @State private var showEnv = false

    init(entry: GameLibraryEntry?) {
        self.entry = entry
        let hasGameProfile = entry.map { ControllerMappingManager.storedProfile(for: $0.id) != nil } ?? false
        let resolved = ControllerMappingManager.resolvedProfile(for: hasGameProfile ? entry?.id : nil)
        _perGame = State(initialValue: hasGameProfile)
        _draft = State(initialValue: resolved.profile)
        _source = State(initialValue: resolved.source)
    }

    private var scopeKey: String {
        perGame ? (entry?.id ?? ControllerMappingManager.defaultKey) : ControllerMappingManager.defaultKey
    }

    private func reload() {
        let r = ControllerMappingManager.resolvedProfile(for: perGame ? entry?.id : nil)
        draft = r.profile
        source = r.source
    }

    private func persist() {
        do {
            try ControllerMappingManager.setProfile(draft, for: scopeKey)
            saveError = nil
        } catch {
            saveError = "Could not save controller profile: \(error.localizedDescription)"
        }
        source = ControllerMappingManager.resolvedProfile(for: perGame ? entry?.id : nil).source
    }

    /// Edits that save immediately.
    private func binding<T>(_ kp: WritableKeyPath<ControllerMappingProfile, T>) -> Binding<T> {
        Binding(get: { draft[keyPath: kp] }, set: { draft[keyPath: kp] = $0; persist() })
    }

    private var sourceText: String {
        switch source {
        case "game": return "Custom profile for this game"
        case "global": return perGame ? "Inherits the global profile until you change something" : "Global profile (all games without their own)"
        default: return "Stock behavior — no controller environment is added at launch"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Label("Controller Mapping & Dead Zones", systemImage: "gamecontroller.fill")
                    .font(.title2.bold())
                Spacer()
                Label(tester.activeControllerName ?? "No controller", systemImage: tester.activeControllerName == nil ? "gamecontroller" : "dot.radiowaves.left.and.right")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(tester.activeControllerName == nil ? Color.secondary : Color.green)
            }
            .padding([.horizontal, .top], 22)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    scopeAndPreset
                    HStack(alignment: .top, spacing: 16) {
                        remapGrid
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        VStack(alignment: .leading, spacing: 14) {
                            sticksAndOptions
                            GroupBox {
                                ControllerTesterView(tester: tester, profile: draft)
                                    .padding(4)
                            } label: {
                                Label("Live Input Tester", systemImage: "waveform.path.ecg")
                            }
                        }
                        .frame(width: 330)
                    }
                    envPreview
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 12)
            }

            Divider()
            HStack(spacing: 10) {
                Button(role: .destructive) {
                    do {
                        try ControllerMappingManager.resetProfile(for: scopeKey)
                        saveError = nil
                    } catch {
                        saveError = "Could not reset: \(error.localizedDescription)"
                    }
                    reload()
                } label: {
                    Label(perGame ? "Reset Game Profile" : "Reset Global Profile", systemImage: "arrow.counterclockwise")
                }
                if let saveError {
                    Text(saveError).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else {
                    Text("Changes save automatically to \(ControllerMappingManager.profilesURL.lastPathComponent) and apply on the next launch.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .frame(width: 820, height: 680)
        .onAppear { tester.start() }
        .onDisappear { tester.stop() }
    }

    private var scopeAndPreset: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Scope", selection: Binding(get: { perGame }, set: { perGame = $0; reload() })) {
                    Text("Global (all games)").tag(false)
                    Text(entry.map { "This game: \($0.title)" } ?? "This game").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(entry == nil)
                Text(sourceText).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Text("Preset").foregroundStyle(.secondary)
                    Picker("Preset", selection: Binding(get: { draft.preset }, set: { draft.applyPreset($0); persist() })) {
                        ForEach(ControllerPreset.allCases) { p in Text(p.displayName).tag(p) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 300)
                    Text(draft.preset.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Label("Profile", systemImage: "person.crop.circle")
        }
    }

    private var remapGrid: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                GridRow {
                    Text("Press").font(.caption.bold()).foregroundStyle(.secondary)
                    Text("Game receives").font(.caption.bold()).foregroundStyle(.secondary)
                }
                ForEach(ControllerMappingProfile.canonicalButtons, id: \.self) { b in
                    GridRow {
                        Text(ControllerMappingProfile.label(for: b))
                            .font(.callout)
                            .foregroundStyle(tester.pressedButtons.contains(b) ? Color.green : Color.primary)
                        Picker(ControllerMappingProfile.label(for: b), selection: Binding(
                            get: { draft.buttonMap[b] ?? b },
                            set: { draft.buttonMap[b] = $0; draft.preset = .custom; persist() }
                        )) {
                            ForEach(ControllerMappingProfile.canonicalButtons, id: \.self) { t in
                                Text(ControllerMappingProfile.label(for: t)).tag(t)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                    }
                }
            }
            .padding(6)
        } label: {
            Label("Button Remapping", systemImage: "arrow.left.arrow.right")
        }
    }

    private var sticksAndOptions: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                deadzoneSlider("Left stick", \.leftDeadzone)
                deadzoneSlider("Right stick", \.rightDeadzone)
                Toggle("Invert right stick Y (look)", isOn: binding(\.invertRightY))
                Toggle("Haptics / rumble", isOn: binding(\.enableHaptics))
            }
            .toggleStyle(.checkbox)
            .padding(6)
        } label: {
            Label("Sticks & Feedback", systemImage: "dial.medium")
        }
    }

    private func deadzoneSlider(_ title: String, _ kp: WritableKeyPath<ControllerMappingProfile, Double>) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 78, alignment: .leading)
            Slider(value: Binding(get: { draft[keyPath: kp] }, set: { draft[keyPath: kp] = ControllerMappingProfile.clampDeadzone($0) }),
                   in: ControllerMappingProfile.deadzoneRange, step: 0.01) { editing in
                if !editing { persist() }
            }
            Text(String(format: "%2.0f%%", draft[keyPath: kp] * 100))
                .font(.callout.monospacedDigit())
                .frame(width: 38, alignment: .trailing)
        }
    }

    private var envPreview: some View {
        let env = ControllerMappingManager.environmentOverrides(profile: draft, key: scopeKey)
        return DisclosureGroup(isExpanded: $showEnv) {
            ScrollView(.horizontal) {
                Text(env.isEmpty ? "No variables (stock profile)."
                     : env.keys.sorted().map { "\($0)=\(env[$0]!.split(separator: "\n").first.map(String.init) ?? "")" }.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        } label: {
            Text("Launch environment (\(env.count) variable\(env.count == 1 ? "" : "s"); SDL_GAMECONTROLLERCONFIG shows its first mapping)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Visualizes live stick, trigger and button state; buttons show their remapped output.
struct ControllerTesterView: View {
    @ObservedObject var tester: ControllerLiveTester
    let profile: ControllerMappingProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if tester.activeControllerName == nil {
                Text("Connect a Bluetooth or USB controller and press any button.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .center, spacing: 14) {
                StickIndicator(label: "L", point: tester.leftStick, deadzone: profile.leftDeadzone, invertY: false)
                StickIndicator(label: "R", point: tester.rightStick, deadzone: profile.rightDeadzone, invertY: profile.invertRightY)
                VStack(spacing: 8) {
                    TriggerIndicator(label: "LT", value: tester.leftTrigger)
                    TriggerIndicator(label: "RT", value: tester.rightTrigger)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 4) {
                ForEach(ControllerMappingProfile.canonicalButtons, id: \.self) { b in
                    let pressed = tester.pressedButtons.contains(b)
                    let out = profile.buttonMap[b] ?? b
                    VStack(spacing: 0) {
                        Text(ControllerMappingProfile.shortLabel(for: b))
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                        if out != b {
                            Text("→\(ControllerMappingProfile.shortLabel(for: out))")
                                .font(.system(size: 8, weight: .semibold, design: .rounded))
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .foregroundStyle(pressed ? Color.white : Color.primary)
                    .background(pressed ? Color.green.opacity(0.85) : Color.secondary.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
        }
    }
}

struct StickIndicator: View {
    let label: String
    let point: CGPoint
    let deadzone: Double
    let invertY: Bool
    private let size: CGFloat = 78

    var body: some View {
        let magnitude = sqrt(point.x * point.x + point.y * point.y)
        let inDeadzone = magnitude <= CGFloat(deadzone)
        let r = size / 2
        VStack(spacing: 3) {
            ZStack {
                Circle().fill(Color.secondary.opacity(0.08))
                Circle().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
                Circle()
                    .fill(Color.orange.opacity(0.18))
                    .frame(width: size * CGFloat(deadzone), height: size * CGFloat(deadzone))
                Circle()
                    .fill(inDeadzone ? Color.secondary : Color.accentColor)
                    .frame(width: 10, height: 10)
                    .offset(x: max(-1, min(1, point.x)) * (r - 6), y: -max(-1, min(1, point.y)) * (r - 6))
            }
            .frame(width: size, height: size)
            Text("\(label) · DZ \(Int((deadzone * 100).rounded()))%\(invertY ? " · Y inv" : "")")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

struct TriggerIndicator: View {
    let label: String
    let value: Float

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10, weight: .bold, design: .rounded)).frame(width: 18)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.12))
                Capsule().fill(Color.accentColor).frame(width: 90 * CGFloat(max(0, min(1, value))))
            }
            .frame(width: 90, height: 8)
            Text(String(format: "%3.0f%%", value * 100)).font(.system(size: 9.5).monospacedDigit()).frame(width: 34, alignment: .trailing)
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
    }
}
