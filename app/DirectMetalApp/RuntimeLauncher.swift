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

    /// GPU family, Metal 4 / MetalFX capabilities and the macOS build never change during a process
    /// lifetime: probe once (MTLDevice creation + sysctl) and reuse everywhere (GUI, CLI, shader cache, launch).
    static let cachedHardwareInfo: MetalHardwareInfo = probeHardwareInfo()

    static func queryHardwareInfo() -> MetalHardwareInfo {
        return cachedHardwareInfo
    }

    private static func queryMetal4FXSupport(_ descriptorClass: AnyClass, device: MTLDevice) -> Bool {
        let sel = NSSelectorFromString("supportsMetal4FX:")
        guard let method = class_getClassMethod(descriptorClass, sel) else { return false }
        typealias SupportsM4FXFn = @convention(c) (AnyClass, Selector, MTLDevice) -> ObjCBool
        let fn = unsafeBitCast(method_getImplementation(method), to: SupportsM4FXFn.self)
        return fn(descriptorClass, sel, device).boolValue
    }

    private static func probeHardwareInfo() -> MetalHardwareInfo {
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

        let apple10Family = MTLGPUFamily(rawValue: 1010)
        let metal4Family = MTLGPUFamily(rawValue: 5002)

        let family: String
        if let f10 = apple10Family, dev.supportsFamily(f10) {
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
            if let fm4 = metal4Family {
                m4 = dev.supportsFamily(fm4)
            }
            m4fx = Self.queryMetal4FXSupport(MTLFXSpatialScalerDescriptor.self, device: dev) &&
                   Self.queryMetal4FXSupport(MTLFXTemporalScalerDescriptor.self, device: dev)
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

    /// Resolves the ARM64EC runtime without hydrating anything (keeps `DirectMetal info` instant).
    /// `basePrefix` is either the unpacked `base-prefix/` or the slim `base-prefix-dehydrated/` bundle;
    /// call `ensureBasePrefix(paths:)` / `BasePrefixHydrator.resolveOrHydrate` before cloning from it.
    static func resolveARM64ECRuntime() -> (root: URL, wine: URL, wineserver: URL, basePrefix: URL, kosmicICD: URL?)? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["DIRECTMETAL_ARM64EC_RUNTIME_DIR"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env, isDirectory: true))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Runtime-ARM64EC", isDirectory: true))
        // DirectMetal-Lite: on-demand, SHA-256 + codesign verified runtime under Application Support.
        if let userRuntime = RuntimeManager.installedARM64ECRuntimeRoot() {
            candidates.append(userRuntime)
        }
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
            let unpacked = root.appendingPathComponent(BasePrefixHydrator.unpackedDirName, isDirectory: true)
            let dehydrated = root.appendingPathComponent(BasePrefixHydrator.dehydratedDirName, isDirectory: true)
            let basePrefix: URL
            if fm.fileExists(atPath: unpacked.appendingPathComponent("system.reg").path) {
                basePrefix = unpacked
            } else if BasePrefixHydrator.isDehydratedBundle(dehydrated) {
                basePrefix = dehydrated
            } else {
                continue
            }
            if fm.isExecutableFile(atPath: wine.path) {
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

    /// Marketing version of the running app (`CFBundleShortVersionString`), `1.0.0` for bare CLI builds.
    static func appVersion() -> String {
        let v = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty == false) ? v! : "1.0.0"
    }

    /// Resources that ship with DirectMetal itself rather than with a Wine runtime: `mullion.conf` and the
    /// `vk_compat_layer`. Resolvable before any runtime is installed (`DirectMetal info` on a fresh Mac).
    /// Order: app bundle `Resources/` -> `runtimeRoot` (mullion.conf only) -> `<cwd>` repo/build tree ->
    /// repo/build tree next to the executable.
    static func resolveBundledResources(runtimeRoot: URL? = nil) -> (mullionConfig: URL?, vkCompatLayerDir: URL?) {
        let fm = FileManager.default
        let vkDylib = "libdm_vk_compat_layer.dylib"
        var roots: [URL] = [URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)]
        var probe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<5 {
            roots.append(probe)
            probe = probe.deletingLastPathComponent()
        }

        var confCandidates: [URL] = []
        if let res = Bundle.main.resourceURL { confCandidates.append(res.appendingPathComponent("mullion.conf")) }
        if let rr = runtimeRoot { confCandidates.append(rr.appendingPathComponent("mullion.conf")) }
        confCandidates += roots.map { $0.appendingPathComponent("runtime/config/mullion.conf") }
        let conf = confCandidates.first { fm.fileExists(atPath: $0.path) }

        var vkCandidates: [URL] = []
        if let res = Bundle.main.resourceURL { vkCandidates.append(res.appendingPathComponent("vulkan-layers", isDirectory: true)) }
        vkCandidates += roots.map { $0.appendingPathComponent("build/dm_vk_compat", isDirectory: true) }
        let vk = vkCandidates.first { fm.fileExists(atPath: $0.appendingPathComponent(vkDylib).path) }
        return (conf, vk)
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
                let res = resolveBundledResources(runtimeRoot: root)
                return RuntimePaths(
                    runtimeRoot: root,
                    wineBin: wine,
                    wineserverBin: wineserver,
                    basePrefix: basePrefix,
                    mullionConfig: res.mullionConfig,
                    vkCompatLayerDir: res.vkCompatLayerDir,
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
            let res = resolveBundledResources(runtimeRoot: arm.root)
            return RuntimePaths(
                runtimeRoot: arm.root,
                wineBin: nil,
                wineserverBin: nil,
                basePrefix: nil,
                mullionConfig: res.mullionConfig,
                vkCompatLayerDir: res.vkCompatLayerDir,
                arm64ecRoot: arm.root,
                arm64ecWineBin: arm.wine,
                arm64ecWineserverBin: arm.wineserver,
                arm64ecBasePrefix: arm.basePrefix,
                arm64ecKosmicKrispICD: arm.kosmicICD
            )
        }

        throw LauncherError.runtimeNotFound(
            "DirectMetal Wine+Mullion runtime not found. Run `DirectMetal runtime install` (or scripts/setup_runtime_arm64ec.sh / package DirectMetal.app)."
        )
    }

    /// Returns a ready-to-clone ARM64EC golden prefix, hydrating the slim `base-prefix-dehydrated/` bundle
    /// on first use (once per runtime fingerprint, APFS clonefile => ~zero extra disk). `nil` without ARM64EC.
    static func ensureBasePrefix(paths: RuntimePaths) throws -> URL? {
        guard let root = paths.arm64ecRoot, let wine = paths.arm64ecWineBin, paths.arm64ecBasePrefix != nil else {
            return nil
        }
        let res = try BasePrefixHydrator.resolveOrHydrate(runtimeRoot: root, wineBin: wine)
        if res.hydratedNow {
            fputs(String(format: "DirectMetal: hydrated ARM64EC base prefix in %.1f ms -> %@\n",
                         res.hydrateMs, res.basePrefix.path), stderr)
        }
        return res.basePrefix
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
    /// Dirty-checked: when both values are already current, the (multi-MB) hive is not rewritten at all.
    static func configurePrefixRetinaPPI(prefixURL: URL, enableRetina: Bool, dpi: Int) {
        let userRegURL = prefixURL.appendingPathComponent("user.reg")
        guard let original = try? String(contentsOf: userRegURL, encoding: .utf8) else { return }
        var content = original

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

        guard content != original else { return }
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
        sandboxOutputDir: String? = nil,
        fexTSOOverride: Bool? = nil,
        warmServerSeconds: Int? = nil
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
                throw LauncherError.runtimeNotFound("ARM64EC+FEX runtime not found. Run `DirectMetal runtime install` (or scripts/setup_runtime_arm64ec.sh) first.")
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
        // Slim bundles ship `base-prefix-dehydrated/`: hydrate lazily here (once per runtime fingerprint).
        let selectedBasePrefix = useARM64EC ? (try ensureBasePrefix(paths: paths))! : paths.basePrefix!
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
            // TSO emulation: `fexTSOOverride` always wins.
            // `ultra` defaults TSO off unless FEX_TSOENABLED is set explicitly in the environment
            // (+4-7% 1%-lows on D3D11/D3D12/Deferred PBR, M1 Pro / Mullion 2702d6e1);
            // `balanced` keeps the `fexTSO` choice (default on) for thread-safety on titles like RDR2.
            if let forced = fexTSOOverride {
                env["FEX_TSOENABLED"] = forced ? "1" : "0"
            } else if perfProfile == .ultra {
                if env["FEX_TSOENABLED"] == nil {
                    env["FEX_TSOENABLED"] = "0"
                }
            } else {
                env["FEX_TSOENABLED"] = fexTSO ? "1" : "0"
            }
            if env["FEX_PROFILESTATS"] == nil {
                env["FEX_PROFILESTATS"] = "0"
            }
            if env["FEX_SILENTLOG"] == nil {
                env["FEX_SILENTLOG"] = "1"
            }
            // Measured on M1 Pro (MetalSharp-Wine 10.5): D3D12 Deferred PBR 1,554 FPS / 1,387 FPS 1%-low,
            // better D3D11 1%-lows, zero regressions.
            if env["FEX_DISABLETELEMETRY"] == nil {
                env["FEX_DISABLETELEMETRY"] = "1"
            }
            // D3D11 1%-low +17.8% (2,760 -> 3,253 FPS). FEX_DYNAMICL1CACHE / FEX_DISKCACHE stay off (regressed / no-op in 10.5).
            if perfProfile == .ultra && env["FEX_EXTENDEDVOLATILEMETADATA"] == nil {
                env["FEX_EXTENDEDVOLATILEMETADATA"] = "1"
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
            // Measured on M1 Pro (macOS 27.2.1, Mullion 2702d6e1): SM 6.0 Deferred PBR 1%-low 919 -> 1,353 FPS (+47.2%).
            if env["MULLION_D3D12_GPU_ERRORS"] == nil {
                env["MULLION_D3D12_GPU_ERRORS"] = "0"
            }
            if env["MULLION_D3D12_NATIVE16"] == nil {
                env["MULLION_D3D12_NATIVE16"] = "1"
            }
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
        // Start Wine / FEX / Mullion on Apple Silicon Performance cores.
        proc.qualityOfService = .userInteractive

        // Persistent warm wineserver: pure Wine startup 0.853 s -> 0.222 s on repeat launches and for
        // multi-process bootstrappers. Not used for Seatbelt launches: a server started outside the sandbox
        // would be shared by (and act on behalf of) the sandboxed clients.
        if !sandboxed, let seconds = WineserverPool.effectiveWarmSeconds(warmServerSeconds), seconds > 0,
           let ws = useARM64EC ? paths.arm64ecWineserverBin : paths.wineserverBin,
           fm.isExecutableFile(atPath: ws.path) {
            WineserverPool.warm(prefixURL: prefixURL, wineserverBin: ws, persistSeconds: seconds, environment: env)
        }

        // Keep macOS App Nap / timer coalescing away from the game for its whole lifetime.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "DirectMetal DirectX-to-Metal Execution"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

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

// MARK: - Warm wineserver pool

/// Keeps a persistent `wineserver -p<seconds>` alive per prefix so repeat launches and multi-process game
/// bootstrappers skip wineserver startup (measured M1 Pro / MetalSharp-Wine 10.5: pure Wine startup
/// 0.853 s -> 0.222 s, D3D11/D3D12 conformance suite 1.65 s -> 0.73 s).
///
/// Servers are started with raw `posix_spawn` (stdin/stdout/stderr = `/dev/null`, every other fd closed via
/// `POSIX_SPAWN_CLOEXEC_DEFAULT`), never Foundation `Process` pipes, so the daemon can't keep a caller's pipe open.
enum WineserverPool {
    static let defaultPersistSeconds = 120

    private static let lock = NSLock()
    nonisolated(unsafe) private static var tracked: [String: String] = [:] // prefixPath -> wineserverPath

    /// Resolves the warm-server duration: an explicit value wins (`<= 0` disables, e.g. `--no-warm-server`);
    /// otherwise `DIRECTMETAL_WARM_SERVER` (`"1"` -> 120 s, `N > 1` -> N s). `nil` => no warm server.
    static func effectiveWarmSeconds(_ explicit: Int?) -> Int? {
        if let explicit { return explicit > 0 ? explicit : nil }
        guard let raw = ProcessInfo.processInfo.environment["DIRECTMETAL_WARM_SERVER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return nil }
        if raw == "1" || raw == "true" || raw == "yes" || raw == "on" { return defaultPersistSeconds }
        if let n = Int(raw), n > 0 { return n }
        return nil
    }

    /// Environment for wineserver control commands. Wine sync mode (msync/esync/fsync) must match the clients'.
    private static func serverEnvironment(prefixURL: URL, base: [String: String]?) -> [String: String] {
        var env = base ?? ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefixURL.path
        if base == nil {
            env["WINEMSYNC"] = "1" // matches RuntimeLauncher.runExecutable
        }
        if env["WINEDEBUG"] == nil {
            env["WINEDEBUG"] = "-all"
        }
        return env
    }

    /// PID of the wineserver currently serving `prefixURL` (holder of its `server-<dev>-<ino>/lock`), or `nil`.
    static func runningPID(prefixURL: URL) -> pid_t? {
        var st = stat()
        guard stat(prefixURL.path, &st) == 0 else { return nil }
        let dir = String(format: "/tmp/.wine-%u/server-%llx-%llx", getuid(), UInt64(UInt32(bitPattern: st.st_dev)), UInt64(st.st_ino))
        let fd = open(dir + "/lock", O_RDWR)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var fl = flock()
        fl.l_type = Int16(F_WRLCK)
        fl.l_whence = Int16(SEEK_SET)
        fl.l_start = 0
        fl.l_len = 0
        guard fcntl(fd, F_GETLK, &fl) == 0, fl.l_type != Int16(F_UNLCK), fl.l_pid > 0 else { return nil }
        return fl.l_pid
    }

    /// Starts (or reuses) a persistent wineserver for `prefixURL`. Returns `true` when a server is running afterwards.
    @discardableResult
    static func warm(prefixURL: URL, wineserverBin: URL, persistSeconds: Int = 120,
                     environment: [String: String]? = nil) -> Bool {
        guard persistSeconds > 0, access(prefixURL.path, F_OK) == 0 else { return false }
        lock.lock()
        tracked[prefixURL.path] = wineserverBin.path
        lock.unlock()
        if runningPID(prefixURL: prefixURL) != nil { return true }
        // The forking parent exits as soon as the daemon holds the server lock (0 = started, 2 = already running).
        let res = RuntimeManager.spawnAndWait(
            [wineserverBin.path, "-p\(persistSeconds)"],
            environment: serverEnvironment(prefixURL: prefixURL, base: environment)
        )
        return res.status == 0 || runningPID(prefixURL: prefixURL) != nil
    }

    /// `wineserver -k` for `prefixURL` (waits until the server released its lock).
    static func stop(prefixURL: URL, wineserverBin: URL) {
        lock.lock()
        tracked.removeValue(forKey: prefixURL.path)
        lock.unlock()
        guard access(prefixURL.path, F_OK) == 0 else { return }
        RuntimeManager.spawnAndWait(
            [wineserverBin.path, "-k"],
            environment: serverEnvironment(prefixURL: prefixURL, base: nil)
        )
    }

    /// Stops every server warmed by this process (GUI quit => zero orphan wineserver daemons).
    static func stopAll() {
        lock.lock()
        let snapshot = tracked
        tracked.removeAll()
        lock.unlock()
        guard !snapshot.isEmpty else { return }
        DispatchQueue.concurrentPerform(iterations: snapshot.count) { i in
            let item = snapshot[snapshot.index(snapshot.startIndex, offsetBy: i)]
            stop(prefixURL: URL(fileURLWithPath: item.key, isDirectory: true),
                 wineserverBin: URL(fileURLWithPath: item.value))
        }
    }

    static func trackedPrefixes() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return tracked.keys.sorted()
    }
}
