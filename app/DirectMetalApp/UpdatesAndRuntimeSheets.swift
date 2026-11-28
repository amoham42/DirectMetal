import AppKit
import SwiftUI

// Software updates (DirectMetal .dmg self-update + MetalSharp-Wine runtime), the Lite first-run
// runtime installer card, and the verified shader-cache import sheet.

// MARK: - View model: updates & Lite runtime install

extension DirectMetalViewModel {
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

    // MARK: Lite first-run runtime install

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
}

// MARK: - Toolbar update button

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

// MARK: - View model: shader cache export / verified import

extension DirectMetalViewModel {
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
}
