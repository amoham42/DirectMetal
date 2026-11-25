import Foundation
import Metal
import MetalFX

struct MetalHardwareInfo: Codable {
    let gpuName: String
    let gpuFamily: String
    let macosVersion: String
    let macosBuild: String
    let cacheKey: String
    let workingSetGiB: Double
    let hasUnifiedMemory: Bool
    let supportsMetal3: Bool
    let supportsMetal4: Bool
    let supportsRaytracing: Bool
    let supportsMetalFXSpatial: Bool
    let supportsMetalFXTemporal: Bool
    let supportsMetal4FX: Bool
}

struct ShaderCacheSummary: Codable {
    let rootPath: String
    let entryCount: Int
    let fileCount: Int
    let totalBytes: UInt64
    let entries: [String]
}

enum ExecutionEngine: String, Codable {
    case auto
    case arm64ec
    case rosetta
}

struct RuntimePaths {
    let runtimeRoot: URL
    let wineBin: URL
    let wineserverBin: URL
    let basePrefix: URL
    let mullionConfig: URL?
    let arm64ecRoot: URL?
    let arm64ecWineBin: URL?
    let arm64ecWineserverBin: URL?
    let arm64ecBasePrefix: URL?
}

struct LaunchResult {
    let exitCode: Int32
    let elapsedSeconds: Double
    let prefixPath: String
    let cloneMs: Double
    let shaderCacheDir: String
    let activeEngine: String
}

enum LauncherError: Error, CustomStringConvertible {
    case runtimeNotFound(String)
    case executableNotFound(String)

    var description: String {
        switch self {
        case .runtimeNotFound(let m), .executableNotFound(let m):
            return m
        }
    }
}

enum RuntimeLauncher {
    private static func sysctlString(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buf)
    }

    static func queryHardwareInfo() -> MetalHardwareInfo {
        let osVer = ProcessInfo.processInfo.operatingSystemVersion
        let osStr = "\(osVer.majorVersion).\(osVer.minorVersion).\(osVer.patchVersion)"
        let buildStr = sysctlString("kern.osversion")

        guard let dev = MTLCreateSystemDefaultDevice() else {
            return MetalHardwareInfo(
                gpuName: "Unavailable",
                gpuFamily: "Unknown",
                macosVersion: osStr,
                macosBuild: buildStr,
                cacheKey: "unknown_\(buildStr)",
                workingSetGiB: 0.0,
                hasUnifiedMemory: false,
                supportsMetal3: false,
                supportsMetal4: false,
                supportsRaytracing: false,
                supportsMetalFXSpatial: false,
                supportsMetalFXTemporal: false,
                supportsMetal4FX: false
            )
        }

        let family: String
        if dev.supportsFamily(.apple10) {
            family = "Apple10"
        } else if dev.supportsFamily(.apple9) {
            family = "Apple9"
        } else if dev.supportsFamily(.apple8) {
            family = "Apple8"
        } else if dev.supportsFamily(.apple7) {
            family = "Apple7"
        } else {
            family = "Mac2"
        }

        let m3 = dev.supportsFamily(.metal3)
        var m4 = false
        var m4fx = false
        if #available(macOS 26.0, *) {
            m4 = dev.supportsFamily(.metal4)
            m4fx = MTLFXSpatialScalerDescriptor.supportsMetal4FX(dev) &&
                   MTLFXTemporalScalerDescriptor.supportsMetal4FX(dev)
        }

        let cacheKey = "\(family.lowercased())_\(buildStr)"
        let workingGiB = Double(dev.recommendedMaxWorkingSetSize) / (1024.0 * 1024.0 * 1024.0)

        return MetalHardwareInfo(
            gpuName: dev.name,
            gpuFamily: family,
            macosVersion: osStr,
            macosBuild: buildStr,
            cacheKey: cacheKey,
            workingSetGiB: workingGiB,
            hasUnifiedMemory: dev.hasUnifiedMemory,
            supportsMetal3: m3,
            supportsMetal4: m4,
            supportsRaytracing: dev.supportsRaytracing,
            supportsMetalFXSpatial: MTLFXSpatialScalerDescriptor.supportsDevice(dev),
            supportsMetalFXTemporal: MTLFXTemporalScalerDescriptor.supportsDevice(dev),
            supportsMetal4FX: m4fx
        )
    }

    static func resolveARM64ECRuntime() -> (root: URL, wine: URL, wineserver: URL, basePrefix: URL)? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["DIRECTMETAL_ARM64EC_RUNTIME_DIR"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env, isDirectory: true))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Runtime-ARM64EC", isDirectory: true))
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        candidates.append(cwd.appendingPathComponent("build/runtime-arm64ec", isDirectory: true))
        var probe = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<5 {
            candidates.append(probe.appendingPathComponent("build/runtime-arm64ec", isDirectory: true))
            candidates.append(probe.appendingPathComponent("Contents/Runtime-ARM64EC", isDirectory: true))
            probe = probe.deletingLastPathComponent()
        }

        for root in candidates {
            let wine = root.appendingPathComponent("bin/wine")
            let ws = root.appendingPathComponent("bin/wineserver")
            let basePrefix = root.appendingPathComponent("base-prefix", isDirectory: true)
            if fm.isExecutableFile(atPath: wine.path) &&
               fm.fileExists(atPath: basePrefix.appendingPathComponent("system.reg").path) {
                return (root, wine, ws, basePrefix)
            }
        }
        return nil
    }

    static func resolveRuntimePaths() throws -> RuntimePaths {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let env = ProcessInfo.processInfo.environment["DIRECTMETAL_RUNTIME_DIR"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env, isDirectory: true))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Runtime", isDirectory: true))

        // Walk up from current executable / CWD to support dev builds inside build/runtime
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        candidates.append(cwd.appendingPathComponent("build/runtime", isDirectory: true))
        let execDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        var probe = execDir
        for _ in 0..<5 {
            candidates.append(probe.appendingPathComponent("build/runtime", isDirectory: true))
            candidates.append(probe.appendingPathComponent("Contents/Runtime", isDirectory: true))
            probe = probe.deletingLastPathComponent()
        }

        let arm64ec = resolveARM64ECRuntime()

        for root in candidates {
            let wine = root.appendingPathComponent("wine/bin/wine")
            let wineserver = root.appendingPathComponent("wine/bin/wineserver")
            let basePrefix = root.appendingPathComponent("base-prefix", isDirectory: true)
            if fm.isExecutableFile(atPath: wine.path) &&
               fm.fileExists(atPath: basePrefix.appendingPathComponent("system.reg").path) {
                var conf: URL? = nil
                let bundleConf = Bundle.main.resourceURL?.appendingPathComponent("mullion.conf")
                let runtimeConf = root.appendingPathComponent("mullion.conf")
                let repoConf = cwd.appendingPathComponent("runtime/config/mullion.conf")
                if let bc = bundleConf, fm.fileExists(atPath: bc.path) {
                    conf = bc
                } else if fm.fileExists(atPath: runtimeConf.path) {
                    conf = runtimeConf
                } else if fm.fileExists(atPath: repoConf.path) {
                    conf = repoConf
                }
                return RuntimePaths(
                    runtimeRoot: root,
                    wineBin: wine,
                    wineserverBin: wineserver,
                    basePrefix: basePrefix,
                    mullionConfig: conf,
                    arm64ecRoot: arm64ec?.root,
                    arm64ecWineBin: arm64ec?.wine,
                    arm64ecWineserverBin: arm64ec?.wineserver,
                    arm64ecBasePrefix: arm64ec?.basePrefix
                )
            }
        }

        throw LauncherError.runtimeNotFound(
            "DirectMetal Wine+Mullion runtime not found. Run scripts/setup_runtime.sh or package DirectMetal.app."
        )
    }

    static func shaderCacheRoot() -> URL {
        let fm = FileManager.default
        let cachesDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cachesDir.appendingPathComponent("DirectMetal/Shaders", isDirectory: true)
    }

    static func queryShaderCache() -> ShaderCacheSummary {
        let fm = FileManager.default
        let root = shaderCacheRoot()
        guard let top = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return ShaderCacheSummary(rootPath: root.path, entryCount: 0, fileCount: 0, totalBytes: 0, entries: [])
        }
        var entries: [String] = []
        var fileCount = 0
        var totalBytes: UInt64 = 0
        for item in top {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { entries.append(item.lastPathComponent) }
        }
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for case let url as URL in enumerator {
                let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if vals?.isRegularFile == true {
                    fileCount += 1
                    totalBytes += UInt64(vals?.fileSize ?? 0)
                }
            }
        }
        return ShaderCacheSummary(
            rootPath: root.path,
            entryCount: entries.count,
            fileCount: fileCount,
            totalBytes: totalBytes,
            entries: entries.sorted()
        )
    }

    static func clearShaderCache() throws {
        let fm = FileManager.default
        let root = shaderCacheRoot()
        if fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
    }

    static func runExecutable(
        exePath: String,
        prefixName: String,
        extraArgs: [String],
        enableHUD: Bool = false,
        resetPrefix: Bool = false,
        upscaleMode: String? = nil,
        engine: ExecutionEngine = .auto,
        fexTSO: Bool = true
    ) throws -> LaunchResult {
        let fm = FileManager.default
        let exeURL = URL(fileURLWithPath: exePath)
        guard fm.fileExists(atPath: exeURL.path) else {
            throw LauncherError.executableNotFound("Windows executable not found: \(exeURL.path)")
        }

        let paths = try resolveRuntimePaths()
        let hw = queryHardwareInfo()
        let profile = try? PEInspector.inspect(exePath: exeURL.path)
        let dxApi = profile?.detectedAPIs.joined(separator: "+") ?? "auto"
        let buildHash = profile?.buildHash ?? "unknown"

        let hasARM64EC = (paths.arm64ecWineBin != nil && paths.arm64ecBasePrefix != nil)
        let useARM64EC: Bool
        switch engine {
        case .arm64ec:
            guard hasARM64EC else {
                throw LauncherError.runtimeNotFound("ARM64EC+FEX runtime not found. Run scripts/setup_runtime_arm64ec.sh first.")
            }
            useARM64EC = true
        case .rosetta:
            useARM64EC = false
        case .auto:
            useARM64EC = hasARM64EC && (profile?.is64Bit ?? true)
        }

        let selectedWine = useARM64EC ? paths.arm64ecWineBin! : paths.wineBin
        let selectedBasePrefix = useARM64EC ? paths.arm64ecBasePrefix! : paths.basePrefix
        let activeEngine = useARM64EC ? "arm64ec-fex" : "rosetta2"

        let shaderCacheDir = shaderCacheRoot()
            .appendingPathComponent("\(buildHash)_\(hw.cacheKey)", isDirectory: true)
        try fm.createDirectory(at: shaderCacheDir, withIntermediateDirectories: true)

        let prefixMgr = PrefixManager()
        let (prefixURL, _, cloneMs) = try prefixMgr.createOrEnsure(
            name: prefixName,
            basePrefix: selectedBasePrefix,
            gameExe: exeURL.path,
            dxApi: dxApi,
            shaderCacheKey: "\(buildHash)_\(hw.cacheKey)",
            forceReset: resetPrefix
        )

        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefixURL.path
        env["WINEMSYNC"] = "1"
        if useARM64EC {
            env["FEX_TSOENABLED"] = fexTSO ? "1" : "0"
        }
        if env["DIRECTMETAL_VERBOSE_WINE"] != "1" {
            env["WINEDEBUG"] = "-all"
        }
        env["MULLION_SHADER_CACHE_PATH"] = shaderCacheDir.path
        if let conf = paths.mullionConfig {
            env["MULLION_CONFIG_FILE"] = conf.path
        }
        // Keep standard Metal 4/3 pipelines by default; MULLION_D3D12_FLEXIBLE=1
        // in v0.5-alpha.4 breaks blend state updates across PSO transitions (d3d12_06).
        if let mode = upscaleMode?.lowercased(), !mode.isEmpty, mode != "off" {
            let factor: String
            switch mode {
            case "quality": factor = "1.5"
            case "balanced": factor = "1.7"
            case "performance": factor = "2.0"
            default: factor = "1.5"
            }
            env["MULLION_METALFX_SPATIAL_SWAPCHAIN"] = "1"
            let extraCfg = "d3d11.metalSpatialUpscale=True;d3d11.metalSpatialUpscaleFactor=\(factor)"
            if let existing = env["MULLION_CONFIG"], !existing.isEmpty {
                env["MULLION_CONFIG"] = "\(existing);\(extraCfg)"
            } else {
                env["MULLION_CONFIG"] = extraCfg
            }
        }
        if enableHUD {
            env["MTL_HUD_ENABLED"] = "1"
        }

        let proc = Process()
        proc.executableURL = selectedWine
        proc.arguments = [exeURL.path] + extraArgs
        proc.currentDirectoryURL = exeURL.deletingLastPathComponent()
        proc.environment = env

        let t0 = DispatchTime.now().uptimeNanoseconds
        try proc.run()
        proc.waitUntilExit()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000_000.0

        return LaunchResult(
            exitCode: proc.terminationStatus,
            elapsedSeconds: elapsed,
            prefixPath: prefixURL.path,
            cloneMs: cloneMs,
            shaderCacheDir: shaderCacheDir.path,
            activeEngine: activeEngine
        )
    }
}
