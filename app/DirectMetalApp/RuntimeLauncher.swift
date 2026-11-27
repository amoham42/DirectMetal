import CoreGraphics
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

enum DX9Backend: String, Codable {
    case auto
    case dxvk
    case wined3d
}

enum PerfProfile: String, Codable {
    case balanced
    case ultra
}

struct RuntimePaths {
    let runtimeRoot: URL
    let wineBin: URL?
    let wineserverBin: URL?
    let basePrefix: URL?
    let mullionConfig: URL?
    let vkCompatLayerDir: URL?
    let arm64ecRoot: URL?
    let arm64ecWineBin: URL?
    let arm64ecWineserverBin: URL?
    let arm64ecBasePrefix: URL?
    let arm64ecKosmicKrispICD: URL?
}

struct LaunchResult {
    let exitCode: Int32
    let elapsedSeconds: Double
    let prefixPath: String
    let cloneMs: Double
    let shaderCacheDir: String
    let activeEngine: String
    let sandboxed: Bool
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

    static func resolveARM64ECRuntime() -> (root: URL, wine: URL, wineserver: URL, basePrefix: URL, kosmicICD: URL?)? {
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
            let wineLauncher = root.appendingPathComponent("bin/wine-launcher")
            let wine = fm.isExecutableFile(atPath: wineLauncher.path)
                ? wineLauncher
                : root.appendingPathComponent("bin/wine")
            let ws = root.appendingPathComponent("bin/wineserver")
            let basePrefix = root.appendingPathComponent("base-prefix", isDirectory: true)
            if fm.isExecutableFile(atPath: wine.path) &&
               fm.fileExists(atPath: basePrefix.appendingPathComponent("system.reg").path) {
                let icdCandidate = wine.resolvingSymlinksInPath()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("share/vulkan/icd.d/kosmickrisp_icd.json")
                let kkICD = fm.fileExists(atPath: icdCandidate.path) ? icdCandidate : nil
                return (root, wine, ws, basePrefix, kkICD)
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

        func resolveSharedResources(runtimeRoot: URL?) -> (conf: URL?, vkCompatDir: URL?) {
            var conf: URL? = nil
            let bundleConf = Bundle.main.resourceURL?.appendingPathComponent("mullion.conf")
            let runtimeConf = runtimeRoot?.appendingPathComponent("mullion.conf")
            let repoConf = cwd.appendingPathComponent("runtime/config/mullion.conf")
            if let bc = bundleConf, fm.fileExists(atPath: bc.path) {
                conf = bc
            } else if let rc = runtimeConf, fm.fileExists(atPath: rc.path) {
                conf = rc
            } else if fm.fileExists(atPath: repoConf.path) {
                conf = repoConf
            }
            var vkCompatDir: URL? = nil
            let bundleVK = Bundle.main.resourceURL?.appendingPathComponent("vulkan-layers", isDirectory: true)
            let buildVK = cwd.appendingPathComponent("build/dm_vk_compat", isDirectory: true)
            if let bvk = bundleVK, fm.fileExists(atPath: bvk.appendingPathComponent("libdm_vk_compat_layer.dylib").path) {
                vkCompatDir = bvk
            } else if fm.fileExists(atPath: buildVK.appendingPathComponent("libdm_vk_compat_layer.dylib").path) {
                vkCompatDir = buildVK
            }
            return (conf, vkCompatDir)
        }

        for root in candidates {
            let wine = root.appendingPathComponent("wine/bin/wine")
            let wineserver = root.appendingPathComponent("wine/bin/wineserver")
            let basePrefix = root.appendingPathComponent("base-prefix", isDirectory: true)
            if fm.isExecutableFile(atPath: wine.path) &&
               fm.fileExists(atPath: basePrefix.appendingPathComponent("system.reg").path) {
                let res = resolveSharedResources(runtimeRoot: root)
                return RuntimePaths(
                    runtimeRoot: root,
                    wineBin: wine,
                    wineserverBin: wineserver,
                    basePrefix: basePrefix,
                    mullionConfig: res.conf,
                    vkCompatLayerDir: res.vkCompatDir,
                    arm64ecRoot: arm64ec?.root,
                    arm64ecWineBin: arm64ec?.wine,
                    arm64ecWineserverBin: arm64ec?.wineserver,
                    arm64ecBasePrefix: arm64ec?.basePrefix,
                    arm64ecKosmicKrispICD: arm64ec?.kosmicICD
                )
            }
        }

        // Slim 100% post-Rosetta ARM64EC-only bundle support (Contents/Runtime omitted)
        if let arm = arm64ec {
            let res = resolveSharedResources(runtimeRoot: arm.root)
            return RuntimePaths(
                runtimeRoot: arm.root,
                wineBin: nil,
                wineserverBin: nil,
                basePrefix: nil,
                mullionConfig: res.conf,
                vkCompatLayerDir: res.vkCompatDir,
                arm64ecRoot: arm.root,
                arm64ecWineBin: arm.wine,
                arm64ecWineserverBin: arm.wineserver,
                arm64ecBasePrefix: arm.basePrefix,
                arm64ecKosmicKrispICD: arm.kosmicICD
            )
        }

        throw LauncherError.runtimeNotFound(
            "DirectMetal Wine+Mullion runtime not found. Run scripts/setup_runtime_arm64ec.sh or package DirectMetal.app."
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

    static func queryDisplayMetrics() -> (logicalW: Int, logicalH: Int, pixelW: Int, pixelH: Int, scale: Double, dpi: Int) {
        let mainId = CGMainDisplayID()
        if let mode = CGDisplayCopyDisplayMode(mainId) {
            let lw = max(mode.width, 1)
            let lh = max(mode.height, 1)
            let pw = max(mode.pixelWidth, lw)
            let ph = max(mode.pixelHeight, lh)
            let scale = max(Double(pw) / Double(lw), 1.0)
            let dpi = max(96, Int((96.0 * scale).rounded()))
            return (lw, lh, pw, ph, scale, dpi)
        }
        return (1512, 982, 1512, 982, 1.0, 96)
    }

    private static func upsertRegSectionValue(
        in content: inout String,
        sectionEscapedRegex: String,
        sectionLiteral: String,
        key: String,
        valueExpr: String,
        unixTs: Int
    ) {
        let headerPattern = "\\[\(sectionEscapedRegex)\\][^\\n]*"
        if let headerRegex = try? NSRegularExpression(pattern: headerPattern),
           let match = headerRegex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
           let matchRange = Range(match.range, in: content) {
            let afterHeader = content[matchRange.upperBound...]
            let nextSectionIdx = afterHeader.range(of: "\n[")?.lowerBound ?? content.endIndex
            let sectionBody = String(content[matchRange.upperBound..<nextSectionIdx])
            let keyPattern = "\"\(NSRegularExpression.escapedPattern(for: key))\"=[^\\n]*"
            let updatedBody: String
            if let keyRegex = try? NSRegularExpression(pattern: keyPattern),
               keyRegex.firstMatch(in: sectionBody, range: NSRange(sectionBody.startIndex..., in: sectionBody)) != nil {
                updatedBody = keyRegex.stringByReplacingMatches(
                    in: sectionBody,
                    range: NSRange(sectionBody.startIndex..., in: sectionBody),
                    withTemplate: "\"\(key)\"=\(valueExpr)"
                )
            } else {
                updatedBody = "\n\"\(key)\"=\(valueExpr)" + sectionBody
            }
            content.replaceSubrange(matchRange.upperBound..<nextSectionIdx, with: updatedBody)
        } else {
            content += "\n[\(sectionLiteral)] \(unixTs)\n\"\(key)\"=\(valueExpr)\n"
        }
    }

    /// Configures Wine's Mac Driver Retina backing scale (`RetinaMode=y|n`) and Windows system PPI (`LogPixels`)
    /// directly in the prefix's `user.reg` (~0.2 ms) so games respect macOS Retina PPI.
    static func configurePrefixRetinaPPI(prefixURL: URL, enableRetina: Bool, dpi: Int) {
        let userRegURL = prefixURL.appendingPathComponent("user.reg")
        guard var content = try? String(contentsOf: userRegURL, encoding: .utf8) else { return }

        let targetDpi = enableRetina ? dpi : 96
        let dpiHex = String(format: "%08x", targetDpi)
        let retinaVal = enableRetina ? "y" : "n"
        let unixTs = Int(Date().timeIntervalSince1970)

        upsertRegSectionValue(
            in: &content,
            sectionEscapedRegex: #"Control Panel\\\\Desktop"#,
            sectionLiteral: #"Control Panel\\Desktop"#,
            key: "LogPixels",
            valueExpr: "dword:\(dpiHex)",
            unixTs: unixTs
        )
        upsertRegSectionValue(
            in: &content,
            sectionEscapedRegex: #"Software\\\\Wine\\\\Mac Driver"#,
            sectionLiteral: #"Software\\Wine\\Mac Driver"#,
            key: "RetinaMode",
            valueExpr: "\"\(retinaVal)\"",
            unixTs: unixTs
        )

        try? content.write(to: userRegURL, atomically: true, encoding: .utf8)
    }

    static func runExecutable(
        exePath: String,
        prefixName: String,
        extraArgs: [String],
        enableHUD: Bool = false,
        resetPrefix: Bool = false,
        upscaleMode: String? = nil,
        engine: ExecutionEngine = .auto,
        fexTSO: Bool = true,
        dx9Backend: DX9Backend = .auto,
        perfProfile: PerfProfile = .balanced,
        retinaMode: Bool? = nil,
        virtualDesktop: String? = nil,
        sandboxed: Bool = false,
        sandboxOffline: Bool = false,
        sandboxOutputDir: String? = nil
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
        let osVer = ProcessInfo.processInfo.operatingSystemVersion
        let isMacOS26_4Plus = (osVer.majorVersion > 26) || (osVer.majorVersion == 26 && osVer.minorVersion >= 4)
        let hasCrossArchProfile: Bool = {
            guard let wineBin = paths.arm64ecWineBin else { return false }
            let appContents = wineBin.resolvingSymlinksInPath()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return fm.fileExists(atPath: appContents.appendingPathComponent("embedded.provisionprofile").path)
        }()
        let arm64ecSupports32Bit = hasARM64EC && isMacOS26_4Plus && hasCrossArchProfile

        let hasRosetta = (paths.wineBin != nil && paths.basePrefix != nil)
        let useARM64EC: Bool
        switch engine {
        case .arm64ec:
            guard hasARM64EC else {
                throw LauncherError.runtimeNotFound("ARM64EC+FEX runtime not found. Run scripts/setup_runtime_arm64ec.sh first.")
            }
            useARM64EC = true
        case .rosetta:
            guard hasRosetta else {
                throw LauncherError.runtimeNotFound("Legacy Rosetta 2 runtime is not bundled in this slim DirectMetal.app. Re-package with --include-rosetta or use --engine arm64ec.")
            }
            useARM64EC = false
        case .auto:
            let is64 = profile?.is64Bit ?? true
            if hasARM64EC && (is64 || arm64ecSupports32Bit || !hasRosetta) {
                useARM64EC = true
            } else if hasRosetta {
                useARM64EC = false
            } else {
                throw LauncherError.runtimeNotFound("No compatible DirectMetal runtime found.")
            }
        }

        let selectedWine = useARM64EC ? paths.arm64ecWineBin! : paths.wineBin!
        let selectedBasePrefix = useARM64EC ? paths.arm64ecBasePrefix! : paths.basePrefix!
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

        // Apply native macOS Retina PPI & HiDPI scaling to the prefix before launch
        let display = queryDisplayMetrics()
        let useRetina = retinaMode ?? (display.scale > 1.0)
        configurePrefixRetinaPPI(prefixURL: prefixURL, enableRetina: useRetina, dpi: display.dpi)

        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefixURL.path
        env["WINEMSYNC"] = "1"
        if useARM64EC {
            env["FEX_TSOENABLED"] = fexTSO ? "1" : "0"
            if env["FEX_PROFILESTATS"] == nil {
                env["FEX_PROFILESTATS"] = "0"
            }
            if env["FEX_SILENTLOG"] == nil {
                env["FEX_SILENTLOG"] = "1"
            }
            let wineHome = selectedWine.resolvingSymlinksInPath()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            if env["GST_PLUGIN_SYSTEM_PATH_1_0"] == nil {
                env["GST_PLUGIN_SYSTEM_PATH_1_0"] = wineHome.appendingPathComponent("lib/gstreamer-1.0").path
            }
            if env["GST_PLUGIN_SCANNER_1_0"] == nil {
                env["GST_PLUGIN_SCANNER_1_0"] = wineHome.appendingPathComponent("libexec/gstreamer-1.0/gst-plugin-scanner").path
            }
        }
        if env["DIRECTMETAL_VERBOSE_WINE"] != "1" {
            env["WINEDEBUG"] = "-all"
        }
        env["MULLION_SHADER_CACHE_PATH"] = shaderCacheDir.path
        if let conf = paths.mullionConfig {
            env["MULLION_CONFIG_FILE"] = conf.path
        }

        let isD3D12 = profile?.detectedAPIs.contains("D3D12") ?? false
        let isD3D11 = profile?.detectedAPIs.contains("D3D11") ?? false
        let isD3D9 = profile?.detectedAPIs.contains("D3D9") ?? false
        let isPureD3D9 = isD3D9 && !isD3D11 && !isD3D12
        let hasDLSS = profile?.detectedUpscalers.contains("DLSS") ?? false

        // Keep placed-texture unoptimized layout fallback + our D3D12 Placed-Resource Alignment Guard active
        // for both direct D3D12 EXEs and launcher bootstrappers (e.g., UE5 -> *-Win64-Shipping.exe).
        if env["MULLION_D3D12_PLACED_UNOPTIMIZED"] == nil {
            env["MULLION_D3D12_PLACED_UNOPTIMIZED"] = "1"
        }

        var extraMullionCfg: [String] = []
        if perfProfile == .ultra {
            // Skip per-frame GPU counter/timestamp passes for peak FPS & 1%-lows
            // (Keep single-queue command encoding on Mullion 2702d6e1+: MULLION_D3D12_PARALLEL_COMMANDS=1 adds thread-dispatch overhead on sub-ms frames)
            extraMullionCfg.append("d3d11.timestampQueries=False")
            extraMullionCfg.append("d3d12.timestampQueries=False")
        }
        // Enable our D3D12 Placed-Resource Alignment Guard when bundled in prefix (guards UE5 32KB offsets with 0% overhead on valid calls)
        if env["DIRECTMETAL_DISABLE_D3D12_GUARD"] != "1" {
            let guardReal = prefixURL.appendingPathComponent("drive_c/windows/system32/d3d12_mullion.dll")
            if fm.fileExists(atPath: guardReal.path) {
                if let existing = env["WINEDLLOVERRIDES"], !existing.isEmpty {
                    env["WINEDLLOVERRIDES"] = "\(existing);d3d12=n"
                } else {
                    env["WINEDLLOVERRIDES"] = "d3d12=n"
                }
            }
        }
        // Auto-expose NVIDIA PCI vendor ID when DLSS is detected so Mullion's nvngx.dll routes DLSS -> Metal 4 MetalFX Temporal.
        if hasDLSS && env["DIRECTMETAL_DISABLE_NVNGX_BRIDGE"] != "1" {
            extraMullionCfg.append("dxgi.customVendorId=10de")
            extraMullionCfg.append("dxgi.customDeviceId=2684")
        }
        // Keep standard Metal 4/3 pipelines by default; MULLION_D3D12_FLEXIBLE=1
        // in v0.5-alpha.4 breaks blend state updates across PSO transitions (d3d12_06).
        if let mode = upscaleMode?.lowercased(), !mode.isEmpty, mode != "off" {
            let factor: String
            let lodBias: String
            let dlssScale: String
            switch mode {
            case "quality":
                factor = "1.5"
                lodBias = "-0.58"
                dlssScale = "quality"
            case "balanced":
                factor = "1.7"
                lodBias = "-0.76"
                dlssScale = "balanced"
            case "performance":
                factor = "2.0"
                lodBias = "-1.0"
                dlssScale = "performance"
            case "ultra_performance":
                factor = "2.5"
                lodBias = "-1.32"
                dlssScale = "ultra_performance"
            default:
                factor = "1.5"
                lodBias = "-0.58"
                dlssScale = "quality"
            }
            if hasDLSS {
                if env["METALSHARP_DLSS_SCALE"] == nil {
                    env["METALSHARP_DLSS_SCALE"] = dlssScale
                }
            }
            env["MULLION_METALFX_SPATIAL_SWAPCHAIN"] = "1"
            extraMullionCfg.append("d3d11.metalSpatialUpscale=True")
            extraMullionCfg.append("d3d11.metalSpatialUpscaleFactor=\(factor)")
            if !hasDLSS {
                extraMullionCfg.append("d3d12.metalSpatialUpscale=True")
                extraMullionCfg.append("d3d12.metalSpatialUpscaleFactor=\(factor)")
                extraMullionCfg.append("d3d12.samplerLodBias=\(lodBias)")
            }
        }
        if !extraMullionCfg.isEmpty {
            let joined = extraMullionCfg.joined(separator: ";")
            if let existing = env["MULLION_CONFIG"], !existing.isEmpty {
                env["MULLION_CONFIG"] = "\(existing);\(joined)"
            } else {
                env["MULLION_CONFIG"] = joined
            }
        }
        let is64BitExe = profile?.is64Bit ?? true
        let useDXVKForD3D9: Bool = {
            guard isPureD3D9 || dx9Backend != .auto else { return false }
            switch dx9Backend {
            case .dxvk: return true
            case .wined3d: return false
            // 64-bit D3D9 (e.g. TF2) runs native ARM64X DXVK 3.1.1 + KosmicKrisp.
            // 32-bit D3D9 (e.g. NFS11) defaults to native ARM64EC WineMetalGL 4.6 (wined3d):
            // avoids MetalVulkan d7vk ddraw hangs and KosmicKrisp YUV video green tint while staying 100% post-Rosetta.
            case .auto: return useARM64EC && is64BitExe
            }
        }()
        // On 32-bit DXVK+KosmicKrisp swapchains, macOS 27.2's libMTLHud throws NSInvalidArgumentException;
        // use DXVK's native Vulkan HUD instead of MTL_HUD_ENABLED on that path.
        if enableHUD && !(useDXVKForD3D9 && useARM64EC && !is64BitExe) {
            env["MTL_HUD_ENABLED"] = "1"
        }

        if isPureD3D9 || dx9Backend != .auto {
            // 64-bit D3D9 on ARM64EC+FEX runs MetalVulkan 7.0 DXVK 3.1.1 -> Mesa KosmicKrisp -> Metal.
            // 32-bit D3D9 on ARM64EC+FEX (macOS 26.4+) defaults to WineMetalGL 4.6 (wined3d on Metal)
            // for full YUV video color accuracy and zero d7vk/ddraw freezes; --dx9-backend dxvk/wined3d always overrides.
            let useDXVK = useDXVKForD3D9
            if !(useDXVK && useARM64EC) {
                let overrideEntry = useDXVK ? "d3d9=n,b" : "d3d9=b"
                if let existing = env["WINEDLLOVERRIDES"], !existing.isEmpty {
                    env["WINEDLLOVERRIDES"] = "\(existing);\(overrideEntry)"
                } else {
                    env["WINEDLLOVERRIDES"] = overrideEntry
                }
            }
            if useDXVK {
                env["DXVK_ASYNC"] = "1"
                env["DXVK_STATE_CACHE_PATH"] = shaderCacheDir.path
                if env["DXVK_LOG_PATH"] == nil {
                    env["DXVK_LOG_PATH"] = "none"
                }
                if useARM64EC {
                    // Use MetalVulkan 7.0 DXVK 3.1.1 + Mesa KosmicKrisp Vulkan 1.4
                    env["GRAPHICS_BACKEND"] = "dxvk"
                    env["SharpVK_Switch"] = "1"
                    if let kkICD = paths.arm64ecKosmicKrispICD {
                        env["VK_DRIVER_FILES"] = kkICD.path
                        env["VK_ICD_FILENAMES"] = kkICD.path
                    }
                } else {
                    env["WINE_LARGE_ADDRESS_AWARE"] = "1"
                }
                if let vkDir = paths.vkCompatLayerDir {
                    env["VK_ADD_LAYER_PATH"] = vkDir.path
                    env["VK_LAYER_PATH"] = vkDir.path
                    env["VK_INSTANCE_LAYERS"] = "VK_LAYER_DIRECTMETAL_mvk_compat"
                    env["DM_VK_COMPAT_ENABLE"] = "1"
                    env["DM_VK_COMPAT_HOST_IMPORT"] = "1"
                    if useARM64EC {
                        env["DM_VK_COMPAT_ADVERTISE_FILLMODE"] = "1"
                    }
                }
                if enableHUD && env["DXVK_HUD"] == nil {
                    env["DXVK_HUD"] = "fps,frametimes,devinfo,api"
                }
            } else {
                if env["WINE_D3D_CONFIG"] == nil {
                    env["WINE_D3D_CONFIG"] = "renderer=gl"
                }
            }
        }

        // Legacy 32-bit DX9 games under Rosetta 2 calling ChangeDisplaySettings hit DISP_CHANGE_BADMODE;
        // on native ARM64EC+FEX (WineMetalGL 4.6), run natively at full Retina PPI unless --desktop is explicitly set.
        let effectiveDesktop: String?
        if let vd = virtualDesktop?.lowercased() {
            effectiveDesktop = (vd == "off" || vd == "none" || vd.isEmpty) ? nil : vd
        } else if isPureD3D9 && !is64BitExe && !useARM64EC {
            effectiveDesktop = useRetina
                ? "\(display.pixelW)x\(display.pixelH)"
                : "\(display.logicalW)x\(display.logicalH)"
        } else {
            effectiveDesktop = nil
        }

        let wineArgs: [String]
        if let vd = effectiveDesktop {
            let winExe = "Z:" + exeURL.path.replacingOccurrences(of: "/", with: "\\")
            wineArgs = ["explorer", "/desktop=DirectMetal,\(vd)", winExe] + extraArgs
        } else {
            wineArgs = [exeURL.path] + extraArgs
        }

        let proc = Process()
        if sandboxed {
            let resolvedOutDir = DirectMetalSandbox.inferOutputDir(
                from: extraArgs,
                explicit: sandboxOutputDir,
                targetPrefix: prefixURL.path
            )
            let profileURL = try DirectMetalSandbox.writeProfile(
                prefixesRoot: prefixMgr.prefixRoot.path,
                targetPrefix: prefixURL.path,
                gameDir: exeURL.deletingLastPathComponent().path,
                shaderCacheDir: shaderCacheDir.path,
                outputDir: resolvedOutDir,
                allowNetwork: !sandboxOffline
            )
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            proc.arguments = ["-f", profileURL.path, selectedWine.path] + wineArgs
        } else {
            proc.executableURL = selectedWine
            proc.arguments = wineArgs
        }
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
            activeEngine: activeEngine,
            sandboxed: sandboxed
        )
    }
}
