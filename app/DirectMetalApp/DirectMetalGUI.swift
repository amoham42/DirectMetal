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
    @Published var statusMessage: String = "Ready — drop a DirectX 10/11/12 .exe to inspect and launch."
    @Published var isRunning: Bool = false

    private let prefixManager = PrefixManager()

    init() {
        refreshPrefixes()
    }

    func refreshPrefixes() {
        prefixes = prefixManager.listPrefixes()
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

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try RuntimeLauncher.runExecutable(
                    exePath: targetExe,
                    prefixName: targetPrefix,
                    extraArgs: [],
                    enableHUD: hud
                )
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.refreshPrefixes()
                    self.statusMessage = String(
                        format: "Finished (exit=%d) in %.2f s [CoW clone: %.2f ms]",
                        result.exitCode, result.elapsedSeconds, result.cloneMs
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
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("DirectMetal")
                        .font(.largeTitle.bold())
                    Text("Apple Silicon–First DirectX 10/11/12 Runtime")
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

            HStack {
                Text("APFS CoW Prefix:")
                TextField("Prefix name", text: $vm.prefixName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Toggle("Metal HUD", isOn: $vm.enableMetalHUD)
                Spacer()
                Button(vm.isRunning ? "Running…" : "Launch") {
                    vm.launchSelected()
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.exePath.isEmpty || vm.isRunning || vm.runtimePaths == nil)
            }

            Text(vm.statusMessage)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 380)
    }
}

struct DirectMetalDesktopApp: App {
    var body: some Scene {
        WindowGroup("DirectMetal") {
            DirectMetalContentView()
        }
    }
}
