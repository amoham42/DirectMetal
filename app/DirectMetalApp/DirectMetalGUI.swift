import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DirectMetalViewModel: ObservableObject {
    @Published var gpuInfo: MetalHardwareInfo = RuntimeLauncher.queryHardwareInfo()
    @Published var runtimePaths: RuntimePaths? = try? RuntimeLauncher.resolveRuntimePaths()
    @Published var exePath: String = ""
    @Published var peProfile: PEProfile?
    @Published var prefixName: String = "default"
    @Published var prefixes: [String] = []
    @Published var enableMetalHUD: Bool = true
    @Published var enableRetinaHiDPI: Bool = true
    @Published var enableSandbox: Bool = false
    @Published var upscaleMode: String = "off"
    @Published var selectedEngine: ExecutionEngine = .auto
    @Published var selectedPerfProfile: PerfProfile = .balanced
    @Published var selectedDX9Backend: DX9Backend = .auto
    @Published var cacheSummary: ShaderCacheSummary = RuntimeLauncher.queryShaderCache()
    @Published var attestationStatus: AttestationStatus?
    @Published var attestationKeyId: String = ""
    @Published var attestationVerified: Bool = false
    @Published var statusMessage: String = "Ready — drop a DirectX 9/10/11/12 .exe to inspect and launch."
    @Published var isRunning: Bool = false

    private let prefixManager = PrefixManager()

    init() {
        refreshPrefixes()
        runAttestationCheck()
    }

    func refreshPrefixes() {
        prefixes = prefixManager.listPrefixes()
        cacheSummary = RuntimeLauncher.queryShaderCache()
    }

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
        do {
            let res = try ShaderCacheManager.exportArchive(to: url.path)
            let mb = Double(res.archiveBytes) / (1024.0 * 1024.0)
            statusMessage = String(
                format: "Exported %d shader files (%.2f MiB, SHA-256: %@…)",
                res.fileCount, mb, String(res.manifestSha256.prefix(12))
            )
        } catch {
            statusMessage = "Cache export failed: \(error)"
        }
    }

    func importShaderCache() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let res = try ShaderCacheManager.importArchive(from: url.path)
            cacheSummary = RuntimeLauncher.queryShaderCache()
            statusMessage = "Imported & verified \(res.verifiedFiles) shader files (\(res.gpuFamily)/\(res.macosBuild))."
        } catch {
            statusMessage = "Cache import failed: \(error)"
        }
    }

    func runAttestationCheck() {
        let sandbox = enableSandbox
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
            }
        }
    }

    func selectExe(path: String) {
        exePath = path
        do {
            let profile = try PEInspector.inspect(exePath: path)
            peProfile = profile
            let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            if !stem.isEmpty {
                prefixName = stem
            }
            let apis = profile.detectedAPIs.isEmpty ? "Win32" : profile.detectedAPIs.joined(separator: ", ")
            statusMessage = "Detected \(profile.architecture) (\(apis)) — zero-config Metal 4/3 pipeline ready."
        } catch {
            peProfile = nil
            statusMessage = "Inspect error: \(error)"
        }
    }

    func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .data]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            selectExe(path: url.path)
        }
    }

    func launchSelected() {
        guard !exePath.isEmpty else { return }
        isRunning = true
        statusMessage = "Cloning APFS prefix & launching via DirectMetal..."
        let targetExe = exePath
        let targetPrefix = prefixName
        let hud = enableMetalHUD
        let retina = enableRetinaHiDPI
        let sandbox = enableSandbox
        let upscale = upscaleMode
        let engine = selectedEngine
        let perf = selectedPerfProfile
        let dx9 = selectedDX9Backend

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try RuntimeLauncher.runExecutable(
                    exePath: targetExe,
                    prefixName: targetPrefix,
                    extraArgs: [],
                    enableHUD: hud,
                    upscaleMode: upscale,
                    engine: engine,
                    dx9Backend: dx9,
                    perfProfile: perf,
                    retinaMode: retina,
                    sandboxed: sandbox
                )
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.refreshPrefixes()
                    self.statusMessage = String(
                        format: "Finished (exit=%d) in %.2f s [engine=%@, CoW=%.2f ms]",
                        result.exitCode, result.elapsedSeconds, result.activeEngine, result.cloneMs
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.statusMessage = "Launch failed: \(error)"
                }
            }
        }
    }
}

struct DirectMetalContentView: View {
    @StateObject private var vm = DirectMetalViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("DirectMetal")
                        .font(.largeTitle.bold())
                    Text("Apple Silicon–First DirectX 9/10/11/12 Runtime")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(vm.gpuInfo.gpuName)
                        .font(.headline)
                    Text("\(vm.gpuInfo.gpuFamily) • UMA \(vm.gpuInfo.workingSetGiB, specifier: "%.1f") GiB • \(vm.gpuInfo.supportsMetal4 ? "Metal 4" : "Metal 3")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Select a Windows .exe or drop here...", text: $vm.exePath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse…") {
                        vm.openFilePicker()
                    }
                }

                if let prof = vm.peProfile {
                    GroupBox("Auto-Detected PE Profile (Zero-Config)") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(prof.architecture, systemImage: "cpu")
                                Spacer()
                                Text("APIs: \(prof.detectedAPIs.isEmpty ? "None" : prof.detectedAPIs.joined(separator: " + "))")
                                    .fontWeight(.semibold)
                            }
                            if !prof.detectedUpscalers.isEmpty {
                                Text("Upscaling Bridge: \(prof.detectedUpscalers.joined(separator: ", ")) → MetalFX")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                            }
                            Text("Build Cache Key: \(prof.buildHash)_\(vm.gpuInfo.cacheKey)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }
                }
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url {
                        DispatchQueue.main.async {
                            vm.selectExe(path: url.path)
                        }
                    }
                }
                return true
            }

            HStack(spacing: 10) {
                Text("Prefix:")
                TextField("Prefix name", text: $vm.prefixName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                Picker("Engine:", selection: $vm.selectedEngine) {
                    Text("Auto").tag(ExecutionEngine.auto)
                    Text("ARM64EC+FEX").tag(ExecutionEngine.arm64ec)
                    Text("Rosetta 2").tag(ExecutionEngine.rosetta)
                }
                .frame(width: 165)
                Picker("Perf:", selection: $vm.selectedPerfProfile) {
                    Text("Balanced").tag(PerfProfile.balanced)
                    Text("Ultra").tag(PerfProfile.ultra)
                }
                .frame(width: 135)
                Picker("DX9:", selection: $vm.selectedDX9Backend) {
                    Text("Auto").tag(DX9Backend.auto)
                    Text("DXVK").tag(DX9Backend.dxvk)
                    Text("WineD3D").tag(DX9Backend.wined3d)
                }
                .frame(width: 130)
                Spacer()
            }

            HStack(spacing: 12) {
                Picker("MetalFX:", selection: $vm.upscaleMode) {
                    Text("Off").tag("off")
                    Text("Quality (1.5x)").tag("quality")
                    Text("Balanced (1.7x)").tag("balanced")
                    Text("Perf (2.0x)").tag("performance")
                    Text("Ultra Perf (2.5x)").tag("ultra_performance")
                }
                .frame(width: 210)
                Toggle("Retina PPI", isOn: $vm.enableRetinaHiDPI)
                Toggle("Metal HUD", isOn: $vm.enableMetalHUD)
                Toggle("Seatbelt Sandbox", isOn: $vm.enableSandbox)
                Spacer()
                Button(vm.isRunning ? "Running…" : "Launch") {
                    vm.launchSelected()
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.exePath.isEmpty || vm.isRunning || vm.runtimePaths == nil)
            }

            GroupBox("Hardware Security & Secure Enclave Attestation") {
                HStack {
                    if let st = vm.attestationStatus {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("SE: \(st.secureEnclaveAvailable ? "Active" : "Unavailable") • SIP: \(st.sipEnabled ? "ON" : "OFF") • SSV: \(st.ssvSealed ? "Sealed" : "Open") • Hardened: \(st.hardenedRuntime ? "ON" : "OFF") • DCDevice: \(st.dcDeviceSupported ? "Yes" : "No")")
                                .font(.caption)
                            Text("Key ID: \(vm.attestationKeyId.isEmpty ? "—" : String(vm.attestationKeyId.prefix(24)) + "…") • Self-Verify: \(vm.attestationVerified ? "PASS" : "PENDING") • CS Flags: \(st.csStatusFlagsHex)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Collecting hardware attestation telemetry…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Run Attestation") {
                        vm.runAttestationCheck()
                    }
                    .font(.caption)
                }
                .padding(4)
            }

            HStack {
                let mb = Double(vm.cacheSummary.totalBytes) / (1024.0 * 1024.0)
                Text("Shader Cache: \(vm.cacheSummary.entryCount) titles, \(vm.cacheSummary.fileCount) files (\(mb, specifier: "%.2f") MiB)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Export Cache…") {
                    vm.exportShaderCache()
                }
                .font(.caption)
                Button("Import Cache…") {
                    vm.importShaderCache()
                }
                .font(.caption)
                Button("Clear Cache") {
                    vm.clearShaderCache()
                }
                .font(.caption)
            }

            Text(vm.statusMessage)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 740, minHeight: 460)
    }
}

struct DirectMetalDesktopApp: App {
    var body: some Scene {
        WindowGroup("DirectMetal") {
            DirectMetalContentView()
        }
    }
}
