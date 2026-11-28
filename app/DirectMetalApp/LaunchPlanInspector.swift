import Foundation


// Launch Plan Dry-Run Inspector (pure Foundation engine & formatters).
// SwiftUI sheet lives in LaunchPlanSheet.swift.
// Pure, side-effect-free resolver that previews exactly how DirectMetal will execute a library
// game (engine, graphics pipeline, MetalFX/DLSS upscaling, FPS cap env, prefix & warm wineserver,
// shader cache, Seatbelt sandbox, controller profile, sanitized/blocked env, and advisories)
// without spawning any process or mutating prefixes/caches on disk.

// MARK: - Data model

struct GameLaunchPlan: Codable, Equatable, Sendable {
    let gameID: String
    let title: String
    let exePath: String
    let exeExists: Bool
    let architecture: String
    let detectedAPIs: [String]
    let detectedUpscalers: [String]
    let requestedEngine: String
    let resolvedEngine: String
    let engineReason: String
    let graphicsPipelineSummary: String
    let upscalingPlan: String
    let fpsCap: Int
    let fpsCapEnvPreview: [String: String]
    let prefixName: String
    let prefixPath: String
    let prefixExists: Bool
    let wineserverWarm: Bool
    let shaderCacheKey: String
    let shaderCacheDir: String
    let shaderCacheExists: Bool
    let sandboxEnabled: Bool
    let sandboxSummary: String
    let retinaEnabled: Bool
    let hudEnabled: Bool
    let perfProfile: String
    let dx9Backend: String
    let controllerProfileKey: String
    let controllerPreset: String
    let controllerHasOverrides: Bool
    let extraArgs: [String]
    let sanitizedCustomEnv: [String: String]
    let blockedCustomEnvKeys: [String]
    let warnings: [String]
}

// MARK: - Pure dry-run inspector & formatters

enum LaunchPlanInspector {
    /// Inspects how `entry` will be launched without spawning processes, hydrating base prefixes,
    /// creating prefix/cache directories, or writing sandbox profiles.
    static func inspect(
        entry: GameLibraryEntry,
        hardware: MetalHardwareInfo = RuntimeLauncher.queryHardwareInfo(),
        prefixManager: PrefixManager = PrefixManager()
    ) -> GameLaunchPlan {
        let fm = FileManager.default
        let exeURL = URL(fileURLWithPath: entry.exePath)
        var exeIsDir: ObjCBool = false
        let exeExists = !entry.exePath.isEmpty
            && fm.fileExists(atPath: exeURL.path, isDirectory: &exeIsDir)
            && !exeIsDir.boolValue

        // Use stored PE metadata from `entry`; only fall back to inspecting the file if the entry
        // has no populated PE fields yet and the executable exists on disk.
        let needsPEFallback = exeExists
            && entry.architecture == "unknown"
            && entry.detectedAPIs.isEmpty
            && entry.buildHash.isEmpty
        let inspectedProfile = needsPEFallback ? (try? PEInspector.inspect(exePath: exeURL.path)) : nil

        let architecture = inspectedProfile?.architecture ?? entry.architecture
        let detectedAPIs = inspectedProfile?.detectedAPIs ?? entry.detectedAPIs
        let detectedUpscalers = inspectedProfile?.detectedUpscalers ?? entry.detectedUpscalers
        let rawBuildHash = inspectedProfile?.buildHash ?? entry.buildHash
        let buildHash = rawBuildHash.isEmpty ? "unknown" : rawBuildHash
        let is64Bit = inspectedProfile?.is64Bit ?? is64BitArchitecture(architecture)

        // Resolve runtime availability (read-only: never hydrates base prefixes).
        let paths = try? RuntimeLauncher.resolveRuntimePaths()
        let hasARM64EC = (paths?.arm64ecWineBin != nil && paths?.arm64ecBasePrefix != nil)
        let hasRosetta = (paths?.wineBin != nil && paths?.basePrefix != nil)

        let osVer = ProcessInfo.processInfo.operatingSystemVersion
        let isMacOS26_4Plus = (osVer.majorVersion > 26)
            || (osVer.majorVersion == 26 && osVer.minorVersion >= 4)
        let hasCrossArchProfile: Bool = {
            guard let wineBin = paths?.arm64ecWineBin else { return false }
            let appContents = wineBin.resolvingSymlinksInPath()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return fm.fileExists(atPath: appContents.appendingPathComponent("embedded.provisionprofile").path)
        }()
        let arm64ecSupports32Bit = hasARM64EC && isMacOS26_4Plus && hasCrossArchProfile

        let engineResolution = resolveEngine(
            requested: entry.engine,
            is64Bit: is64Bit,
            hasARM64EC: hasARM64EC,
            hasRosetta: hasRosetta,
            arm64ecSupports32Bit: arm64ecSupports32Bit
        )
        // For pipeline preview even when no runtime is installed yet, reflect the intended backend.
        let plannedARM64EC = (engineResolution.resolved == "arm64ec-fex")
            || (engineResolution.resolved == "unavailable" && entry.engine != .rosetta)

        // Prefix & warm wineserver check (stat/fcntl read-only).
        let prefixName = entry.launchPrefixName
        let prefixURL = prefixManager.prefixURL(named: prefixName)
        var prefixIsDir: ObjCBool = false
        let prefixExists = fm.fileExists(atPath: prefixURL.path, isDirectory: &prefixIsDir) && prefixIsDir.boolValue
        let wineserverWarm = prefixExists && (WineserverPool.runningPID(prefixURL: prefixURL) != nil)

        // Shader cache path (matches RuntimeLauncher.runExecutable).
        let shaderCacheKey = "\(buildHash)_\(hardware.cacheKey)"
        let shaderCacheURL = RuntimeLauncher.shaderCacheRoot()
            .appendingPathComponent(shaderCacheKey, isDirectory: true)
        var cacheIsDir: ObjCBool = false
        let shaderCacheExists = fm.fileExists(atPath: shaderCacheURL.path, isDirectory: &cacheIsDir) && cacheIsDir.boolValue

        // Graphics pipeline & DX9 backend resolution (matches RuntimeLauncher.runExecutable).
        let apis = Set(detectedAPIs)
        let isD3D12 = apis.contains("D3D12")
        let isD3D11 = apis.contains("D3D11")
        let isD3D10 = apis.contains("D3D10")
        let isD3D9 = apis.contains("D3D9")
        let isVulkan = apis.contains("Vulkan")
        let isOpenGL = apis.contains("OpenGL")
        let isPureD3D9 = isD3D9 && !isD3D11 && !isD3D12
        let useDXVKForD3D9: Bool = {
            guard isPureD3D9 || entry.dx9Backend != .auto else { return false }
            switch entry.dx9Backend {
            case .dxvk: return true
            case .wined3d: return false
            case .auto: return plannedARM64EC && is64Bit
            }
        }()

        let guardDllPath = prefixURL.appendingPathComponent("drive_c/windows/system32/d3d12_mullion.dll").path
        let guardDisabledByEnv = ProcessInfo.processInfo.environment["DIRECTMETAL_DISABLE_D3D12_GUARD"] == "1"
        let guardPresentInPrefix = prefixExists && fm.fileExists(atPath: guardDllPath)

        let graphicsPipelineSummary = buildGraphicsPipelineSummary(
            isD3D12: isD3D12,
            isD3D11: isD3D11,
            isD3D10: isD3D10,
            isD3D9: isD3D9,
            isPureD3D9: isPureD3D9,
            isVulkan: isVulkan,
            isOpenGL: isOpenGL,
            dx9Backend: entry.dx9Backend,
            useDXVKForD3D9: useDXVKForD3D9,
            useARM64EC: plannedARM64EC,
            perfProfile: entry.perfProfile,
            hardware: hardware,
            guardDisabledByEnv: guardDisabledByEnv,
            guardPresentInPrefix: guardPresentInPrefix,
            prefixExists: prefixExists,
            hasVkCompatLayer: paths?.vkCompatLayerDir != nil
        )

        // Upscaling plan (DLSS -> MetalFX Temporal bridge + MetalFX Spatial swapchain).
        let hasDLSS = detectedUpscalers.contains("DLSS")
        let nvngxDisabledByEnv = ProcessInfo.processInfo.environment["DIRECTMETAL_DISABLE_NVNGX_BRIDGE"] == "1"
        let upscalingPlan = buildUpscalingPlan(
            upscaleMode: entry.launchUpscaleMode,
            detectedUpscalers: detectedUpscalers,
            hasDLSS: hasDLSS,
            nvngxDisabledByEnv: nvngxDisabledByEnv,
            hardware: hardware
        )

        // FPS cap environment preview (reuses RuntimeLauncher's exact logic).
        let clampedFpsCap = max(0, min(entry.fpsCap, 360))
        let fpsApply = RuntimeLauncher.fpsCapEnvironmentAndConfig(fpsCap: clampedFpsCap, existingEnv: [:])
        var fpsCapEnvPreview = fpsApply.env
        if !fpsApply.mullionConfig.isEmpty {
            fpsCapEnvPreview["MULLION_CONFIG"] = fpsApply.mullionConfig.joined(separator: ";")
        }

        // Extra arguments & custom environment sanitization / blocked-key audit.
        let extraArgs = entry.extraArgList
        let sanitizedCustomEnv = entry.customEnvDictionary
        let envAudit = auditCustomEnv(entry.customEnv)

        // Sandbox summary (pure preview; never writes .directmetal_sandbox.sb).
        let sandboxEnabled = entry.enableSandbox
        let sandboxSummary = buildSandboxSummary(
            enabled: sandboxEnabled,
            extraArgs: extraArgs,
            prefixPath: prefixURL.path
        )

        // Controller profile resolution (read-only).
        let resolvedController = ControllerMappingManager.resolvedProfile(for: entry.id)
        let controllerOverrides = ControllerMappingManager.environmentOverrides(
            profile: resolvedController.profile,
            key: resolvedController.key
        )
        let controllerPreset = "\(resolvedController.profile.preset.displayName) (\(resolvedController.source))"

        // Actionable warnings.
        var warnings: [String] = []
        if !exeExists {
            warnings.append(
                "Executable not found at \(LaunchDiagnostics.redactHome(entry.exePath)) — verify the install path or external drive mount."
            )
        }
        if engineResolution.resolved == "unavailable" {
            if entry.engine == .rosetta {
                warnings.append(
                    "Legacy Rosetta 2 runtime is not bundled or installed. Switch Engine to Auto/ARM64EC or package with --include-rosetta."
                )
            } else {
                warnings.append(
                    "DirectMetal Wine+Mullion runtime not found. Run `DirectMetal runtime install` before launching."
                )
            }
        }
        if !envAudit.blockedKeys.isEmpty {
            warnings.append(
                "Blocked custom environment key(s) stripped for host isolation: \(envAudit.blockedKeys.joined(separator: ", "))."
            )
        }
        if !envAudit.invalidTokens.isEmpty {
            warnings.append(
                "Ignored invalid custom environment token(s) (expected KEY=VALUE): \(envAudit.invalidTokens.joined(separator: ", "))."
            )
        }
        if !is64Bit {
            if engineResolution.resolved == "rosetta2" {
                warnings.append(
                    "32-bit x86 executable will run under legacy Rosetta 2 (macOS 26.4+ with cross-arch provisioning enables 32-bit ARM64EC+FEX)."
                )
            } else if engineResolution.resolved == "arm64ec-fex" && !arm64ecSupports32Bit {
                warnings.append(
                    "32-bit x86 executable on ARM64EC+FEX without macOS 26.4+ cross-arch support may not start; Rosetta 2 fallback is not installed."
                )
            }
        }
        if entry.enableHUD && useDXVKForD3D9 && plannedARM64EC && !is64Bit {
            warnings.append(
                "Metal Performance HUD is suppressed on 32-bit DXVK+KosmicKrisp to avoid libMTLHud exceptions; DXVK_HUD will be shown instead."
            )
        }
        if !hardware.supportsMetal3 {
            warnings.append(
                "GPU (\(hardware.gpuName)) does not report Metal 3 support — Mullion requires Apple Silicon with Metal 3+."
            )
        }
        if let mode = entry.launchUpscaleMode, !hasDLSS, !hardware.supportsMetalFXSpatial {
            warnings.append(
                "MetalFX Spatial upscaling (\(mode)) is enabled, but \(hardware.gpuName) does not report MetalFX Spatial support."
            )
        }

        return GameLaunchPlan(
            gameID: entry.id,
            title: entry.title,
            exePath: entry.exePath,
            exeExists: exeExists,
            architecture: architecture,
            detectedAPIs: detectedAPIs,
            detectedUpscalers: detectedUpscalers,
            requestedEngine: entry.engine.rawValue,
            resolvedEngine: engineResolution.resolved,
            engineReason: engineResolution.reason,
            graphicsPipelineSummary: graphicsPipelineSummary,
            upscalingPlan: upscalingPlan,
            fpsCap: clampedFpsCap,
            fpsCapEnvPreview: fpsCapEnvPreview,
            prefixName: prefixName,
            prefixPath: prefixURL.path,
            prefixExists: prefixExists,
            wineserverWarm: wineserverWarm,
            shaderCacheKey: shaderCacheKey,
            shaderCacheDir: shaderCacheURL.path,
            shaderCacheExists: shaderCacheExists,
            sandboxEnabled: sandboxEnabled,
            sandboxSummary: sandboxSummary,
            retinaEnabled: entry.retinaMode,
            hudEnabled: entry.enableHUD,
            perfProfile: entry.perfProfile.rawValue,
            dx9Backend: entry.dx9Backend.rawValue,
            controllerProfileKey: resolvedController.key,
            controllerPreset: controllerPreset,
            controllerHasOverrides: !controllerOverrides.isEmpty,
            extraArgs: extraArgs,
            sanitizedCustomEnv: sanitizedCustomEnv,
            blockedCustomEnvKeys: envAudit.blockedKeys,
            warnings: warnings
        )
    }

    // MARK: Text formatter (CLI)

    static func formatText(_ plan: GameLaunchPlan, home: String = NSHomeDirectory()) -> String {
        let r: (String) -> String = { LaunchDiagnostics.redactHome($0, home: home) }
        var sections: [String] = []

        func formatSection(_ heading: String, _ rows: [(String, String)]) -> String {
            let labelWidth = max((rows.map { $0.0.count }.max() ?? 0) + 2, 18)
            var out = ["[\(heading)]"]
            for (label, value) in rows {
                let padded = (label + ":").padding(toLength: labelWidth, withPad: " ", startingAt: 0)
                out.append("  \(padded)\(value)")
            }
            return out.joined(separator: "\n")
        }

        let apisText = plan.detectedAPIs.isEmpty ? "Win32 / auto-detect" : plan.detectedAPIs.joined(separator: ", ")
        let upscalersText = plan.detectedUpscalers.isEmpty ? "none detected" : plan.detectedUpscalers.joined(separator: ", ")
        let exeStatus = plan.exeExists ? "found" : "MISSING"

        sections.append("DirectMetal Launch Plan (Dry-Run) — \(plan.title)")
        sections.append(formatSection("Execution & Graphics Pipeline", [
            ("Game ID", plan.gameID),
            ("Executable", "\(r(plan.exePath)) [\(exeStatus)]"),
            ("Architecture", plan.architecture),
            ("Detected APIs", apisText),
            ("Engine", "\(plan.resolvedEngine) (requested: \(plan.requestedEngine))"),
            ("Engine Reason", plan.engineReason),
            ("Perf Profile", plan.perfProfile),
            ("DX9 Backend", plan.dx9Backend),
            ("Graphics Pipeline", plan.graphicsPipelineSummary),
        ]))

        let fpsLabel = plan.fpsCap > 0 ? "\(plan.fpsCap) FPS" : "Uncapped"
        let fpsEnvText: String = plan.fpsCapEnvPreview.isEmpty
            ? "(none)"
            : plan.fpsCapEnvPreview.keys.sorted().map { "\($0)=\(plan.fpsCapEnvPreview[$0] ?? "")" }.joined(separator: " ")

        sections.append(formatSection("Frame Pacing & Upscaling", [
            ("Upscaling Plan", plan.upscalingPlan),
            ("Detected Upscalers", upscalersText),
            ("FPS Cap", fpsLabel),
            ("FPS Cap Env", fpsEnvText),
            ("Retina HiDPI", plan.retinaEnabled ? "on" : "off"),
            ("Metal HUD", plan.hudEnabled ? "on" : "off"),
        ]))

        sections.append(formatSection("Prefix & Shader Cache", [
            ("Prefix Name", plan.prefixName),
            ("Prefix Path", "\(r(plan.prefixPath)) [\(plan.prefixExists ? "exists" : "will APFS-clone on launch")]"),
            ("Wineserver", plan.wineserverWarm ? "warm (running)" : "cold"),
            ("Shader Cache Key", plan.shaderCacheKey),
            ("Shader Cache Dir", "\(r(plan.shaderCacheDir)) [\(plan.shaderCacheExists ? "exists" : "will create on launch")]"),
        ]))

        let extraArgsText = plan.extraArgs.isEmpty ? "(none)" : plan.extraArgs.joined(separator: " ")
        let customEnvText: String = plan.sanitizedCustomEnv.isEmpty
            ? "(none)"
            : plan.sanitizedCustomEnv.keys.sorted().map { "\($0)=\(plan.sanitizedCustomEnv[$0] ?? "")" }.joined(separator: " ")
        var envRows: [(String, String)] = [
            ("Sandbox", "\(plan.sandboxEnabled ? "enabled" : "disabled") — \(plan.sandboxSummary)"),
            ("Controller", "\(plan.controllerPreset) [key=\(plan.controllerProfileKey), overrides=\(plan.controllerHasOverrides ? "active" : "none")]"),
            ("Extra Args", extraArgsText),
            ("Custom Env", customEnvText),
        ]
        if !plan.blockedCustomEnvKeys.isEmpty {
            envRows.append(("Blocked Env Keys", "\(plan.blockedCustomEnvKeys.joined(separator: ", ")) (stripped)"))
        }
        sections.append(formatSection("Sandbox, Controller & Environment", envRows))

        if !plan.warnings.isEmpty {
            var warnLines = ["[Warnings (\(plan.warnings.count))]"]
            for warning in plan.warnings {
                warnLines.append("  ! \(r(warning))")
            }
            sections.append(warnLines.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n") + "\n"
    }

    // MARK: Markdown formatter (GitHub-issue-ready)

    static func formatMarkdown(_ plan: GameLaunchPlan, home: String = NSHomeDirectory()) -> String {
        let r: (String) -> String = { LaunchDiagnostics.redactHome($0, home: home) }
        func cell(_ raw: String) -> String {
            r(raw)
                .replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\n", with: " ")
        }

        let apisText = plan.detectedAPIs.isEmpty ? "Win32 / auto-detect" : plan.detectedAPIs.joined(separator: ", ")
        let upscalersText = plan.detectedUpscalers.isEmpty ? "None detected" : plan.detectedUpscalers.joined(separator: ", ")
        let fpsLabel = plan.fpsCap > 0 ? "`\(plan.fpsCap) FPS`" : "Uncapped"

        var lines: [String] = [
            "### DirectMetal Launch Plan (Dry-Run) — \(plan.title)",
            "",
            "| Field | Value |",
            "| :--- | :--- |",
            "| **Game ID** | `\(cell(plan.gameID))` |",
            "| **Executable** | `\(cell(plan.exePath))` (\(plan.exeExists ? "found" : "**MISSING**")) |",
            "| **Architecture** | `\(cell(plan.architecture))` |",
            "| **Detected APIs** | \(cell(apisText)) |",
            "| **Detected Upscalers** | \(cell(upscalersText)) |",
            "| **Engine** | `\(cell(plan.resolvedEngine))` (requested: `\(cell(plan.requestedEngine))`) — \(cell(plan.engineReason)) |",
            "| **Graphics Pipeline** | \(cell(plan.graphicsPipelineSummary)) |",
            "| **Performance Profile** | `\(cell(plan.perfProfile))` · DX9 backend: `\(cell(plan.dx9Backend))` |",
            "| **Upscaling** | \(cell(plan.upscalingPlan)) |",
            "| **FPS Cap** | \(fpsLabel) |",
            "| **Display / HUD** | Retina HiDPI: `\(plan.retinaEnabled ? "on" : "off")` · Metal HUD: `\(plan.hudEnabled ? "on" : "off")` |",
            "| **Prefix** | `\(cell(plan.prefixName))` → `\(cell(plan.prefixPath))` (\(plan.prefixExists ? "exists" : "will clone on launch")) |",
            "| **Wineserver** | \(plan.wineserverWarm ? "Warm (running)" : "Cold") |",
            "| **Shader Cache** | `\(cell(plan.shaderCacheKey))` → `\(cell(plan.shaderCacheDir))` (\(plan.shaderCacheExists ? "exists" : "will create on launch")) |",
            "| **Sandbox** | \(plan.sandboxEnabled ? "**Enabled**" : "Disabled") — \(cell(plan.sandboxSummary)) |",
            "| **Controller** | \(cell(plan.controllerPreset)) (`\(cell(plan.controllerProfileKey))`, \(plan.controllerHasOverrides ? "overrides active" : "stock")) |",
            "",
            "#### Arguments & Environment",
            "",
        ]

        if plan.extraArgs.isEmpty {
            lines.append("- **Extra Args:** _None_")
        } else {
            let joined = plan.extraArgs.map { "`\(r($0))`" }.joined(separator: " ")
            lines.append("- **Extra Args:** \(joined)")
        }

        if plan.fpsCapEnvPreview.isEmpty {
            lines.append("- **FPS Cap Env:** _None (uncapped)_")
        } else {
            let pairs = plan.fpsCapEnvPreview.keys.sorted()
                .map { "`\($0)=\(plan.fpsCapEnvPreview[$0] ?? "")`" }
                .joined(separator: ", ")
            lines.append("- **FPS Cap Env:** \(pairs)")
        }

        if plan.sanitizedCustomEnv.isEmpty {
            lines.append("- **Custom Env:** _None_")
        } else {
            let pairs = plan.sanitizedCustomEnv.keys.sorted()
                .map { "`\($0)=\(r(plan.sanitizedCustomEnv[$0] ?? ""))`" }
                .joined(separator: ", ")
            lines.append("- **Custom Env:** \(pairs)")
        }

        if !plan.blockedCustomEnvKeys.isEmpty {
            let blocked = plan.blockedCustomEnvKeys.map { "`\($0)`" }.joined(separator: ", ")
            lines.append("- **Blocked Env Keys (stripped):** \(blocked)")
        }

        if !plan.warnings.isEmpty {
            lines.append("")
            lines.append("#### Warnings")
            lines.append("")
            for warning in plan.warnings {
                lines.append("- ⚠️ \(r(warning))")
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: Private resolution helpers

    private static func is64BitArchitecture(_ arch: String) -> Bool {
        switch arch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "x86", "i386", "i686", "win32", "32-bit", "x86_32":
            return false
        default:
            return true
        }
    }

    private static func resolveEngine(
        requested: ExecutionEngine,
        is64Bit: Bool,
        hasARM64EC: Bool,
        hasRosetta: Bool,
        arm64ecSupports32Bit: Bool
    ) -> (resolved: String, reason: String) {
        switch requested {
        case .arm64ec:
            if hasARM64EC {
                let note: String
                if is64Bit {
                    note = "Explicitly requested native ARM64EC+FEX runtime"
                } else if arm64ecSupports32Bit {
                    note = "Explicitly requested native ARM64EC+FEX (32-bit WoW64 cross-arch enabled)"
                } else {
                    note = "Explicitly requested ARM64EC+FEX (32-bit cross-arch requires macOS 26.4+ and profile)"
                }
                return ("arm64ec-fex", note)
            }
            return ("unavailable", "Requested ARM64EC+FEX runtime is not installed")

        case .rosetta:
            if hasRosetta {
                return ("rosetta2", "Explicitly requested legacy Rosetta 2 runtime")
            }
            return ("unavailable", "Requested Rosetta 2 runtime is not bundled or installed")

        case .auto:
            if hasARM64EC && (is64Bit || arm64ecSupports32Bit || !hasRosetta) {
                let reason: String
                if is64Bit {
                    reason = "Auto-selected native ARM64EC+FEX for 64-bit executable"
                } else if arm64ecSupports32Bit {
                    reason = "Auto-selected native ARM64EC+FEX for 32-bit executable (macOS 26.4+ cross-arch WoW64)"
                } else {
                    reason = "Auto-selected ARM64EC+FEX for 32-bit executable (no Rosetta 2 runtime bundled)"
                }
                return ("arm64ec-fex", reason)
            }
            if hasRosetta {
                let reason = is64Bit
                    ? "Auto-selected Rosetta 2 fallback (ARM64EC+FEX runtime unavailable)"
                    : "Auto-selected Rosetta 2 for 32-bit executable (ARM64EC 32-bit cross-arch unavailable)"
                return ("rosetta2", reason)
            }
            return ("unavailable", "No compatible DirectMetal Wine runtime found")
        }
    }

    private static func buildGraphicsPipelineSummary(
        isD3D12: Bool,
        isD3D11: Bool,
        isD3D10: Bool,
        isD3D9: Bool,
        isPureD3D9: Bool,
        isVulkan: Bool,
        isOpenGL: Bool,
        dx9Backend: DX9Backend,
        useDXVKForD3D9: Bool,
        useARM64EC: Bool,
        perfProfile: PerfProfile,
        hardware: MetalHardwareInfo,
        guardDisabledByEnv: Bool,
        guardPresentInPrefix: Bool,
        prefixExists: Bool,
        hasVkCompatLayer: Bool
    ) -> String {
        let metalTier = hardware.supportsMetal4 ? "Metal 4" : (hardware.supportsMetal3 ? "Metal 3" : "Metal")
        var stages: [String] = []

        if isD3D12 {
            let guardText: String
            if guardDisabledByEnv {
                guardText = "Placed-Resource Guard disabled via env"
            } else if guardPresentInPrefix {
                guardText = "Placed-Resource Guard active"
            } else if !prefixExists {
                guardText = "Placed-Resource Guard (when bundled in prefix)"
            } else {
                guardText = "Placed-Resource Unoptimized fallback"
            }
            stages.append("D3D12 → Mullion \(metalTier) + \(guardText)")
        }

        if isD3D11 || isD3D10 {
            let apiLabel = (isD3D11 && isD3D10) ? "D3D11/D3D10" : (isD3D11 ? "D3D11" : "D3D10")
            stages.append("\(apiLabel) → Mullion \(metalTier)")
        }

        if isPureD3D9 || dx9Backend != .auto {
            if useDXVKForD3D9 {
                let compatNote = hasVkCompatLayer ? " + vk_compat" : ""
                if useARM64EC {
                    stages.append("D3D9 → DXVK 3.1.1 (ARM64X) → Mesa KosmicKrisp\(compatNote) → \(metalTier)")
                } else {
                    stages.append("D3D9 → DXVK → MoltenVK\(compatNote) → \(metalTier)")
                }
            } else {
                stages.append("D3D9 → WineMetalGL 4.6 (wined3d → \(metalTier))")
            }
        } else if isD3D9 {
            stages.append("D3D9 → WineMetalGL 4.6 (wined3d)")
        }

        if isVulkan {
            if useARM64EC {
                stages.append("Vulkan → Mesa KosmicKrisp (Vulkan 1.4) → \(metalTier)")
            } else {
                stages.append("Vulkan → MoltenVK → \(metalTier)")
            }
        }

        if isOpenGL {
            stages.append("OpenGL → WineMetalGL → \(metalTier)")
        }

        if stages.isEmpty {
            stages.append("Win32 / Auto-detect → Mullion \(metalTier) + Placed-Resource Guard (bootstrapper-safe)")
        }

        if perfProfile == .ultra {
            let fexNote = useARM64EC ? "FEX TSO off, extended volatile metadata, " : ""
            stages.append("Ultra (\(fexNote)native16, timestamps & GPU error checks off)")
        } else if useARM64EC {
            stages.append("Balanced (FEX TSO on)")
        }

        return stages.joined(separator: " · ")
    }

    private static func buildUpscalingPlan(
        upscaleMode: String?,
        detectedUpscalers: [String],
        hasDLSS: Bool,
        nvngxDisabledByEnv: Bool,
        hardware: MetalHardwareInfo
    ) -> String {
        let modeDetail: String? = upscaleMode.map { mode in
            switch mode {
            case "quality": return "Quality (1.5×, LOD -0.58)"
            case "balanced": return "Balanced (1.7×, LOD -0.76)"
            case "performance": return "Performance (2.0×, LOD -1.0)"
            case "ultra_performance": return "Ultra Performance (2.5×, LOD -1.32)"
            default: return "Quality (1.5×, LOD -0.58)"
            }
        }

        let otherUpscalers = detectedUpscalers.filter { $0 != "DLSS" }
        let otherSuffix = otherUpscalers.isEmpty
            ? ""
            : " · In-game \(otherUpscalers.joined(separator: "/")) detected"

        if hasDLSS && !nvngxDisabledByEnv {
            let temporalTier = hardware.supportsMetal4FX
                ? "Metal 4 MetalFX Temporal"
                : (hardware.supportsMetalFXTemporal ? "MetalFX Temporal" : "MetalFX")
            if let detail = modeDetail, let rawMode = upscaleMode {
                return "\(temporalTier) via Mullion nvngx.dll DLSS bridge (PCI 10de:2684, scale=\(rawMode)); D3D11 MetalFX Spatial \(detail)\(otherSuffix)"
            }
            return "\(temporalTier) via Mullion nvngx.dll DLSS bridge (PCI 10de:2684); forced MetalFX Spatial swapchain Off\(otherSuffix)"
        }

        if let detail = modeDetail {
            let spatialTier = hardware.supportsMetal4FX ? "Metal 4 MetalFX Spatial" : "MetalFX Spatial"
            return "\(spatialTier) — \(detail) (D3D11 + D3D12 swapchain)\(otherSuffix)"
        }

        if !detectedUpscalers.isEmpty {
            return "Off (native resolution; in-game \(detectedUpscalers.joined(separator: "/")) available)"
        }
        return "Off (native resolution)"
    }

    private static func buildSandboxSummary(
        enabled: Bool,
        extraArgs: [String],
        prefixPath: String
    ) -> String {
        guard enabled else {
            return "Off (standard unsandboxed Wine launch; warm wineserver eligible)"
        }
        let inferredOut = DirectMetalSandbox.inferOutputDir(
            from: extraArgs,
            explicit: nil,
            targetPrefix: prefixPath
        )
        let extraOutNote = inferredOut != prefixPath ? ", inferred output dir" : ""
        return "macOS Seatbelt (sandbox-exec): blocks ~/.ssh, ~/.gnupg, Keychains & browser data; isolates prefix and restricts writes to target prefix, shader cache, ~/Library/Caches\(extraOutNote); warm wineserver disabled"
    }

    private static func auditCustomEnv(_ raw: String) -> (blockedKeys: [String], invalidTokens: [String]) {
        var blocked: [String] = []
        var seenBlocked = Set<String>()
        var invalid: [String] = []

        for token in GameLibraryManager.splitArguments(raw) {
            guard let eq = token.firstIndex(of: "=") else {
                let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { invalid.append(trimmed) }
                continue
            }
            let key = String(token[..<eq]).trimmingCharacters(in: .whitespaces)
            let upper = key.uppercased()
            if !GameLibraryManager.isValidEnvKey(key) {
                invalid.append(token)
            } else if GameLibraryManager.blockedCustomEnvKeys.contains(upper) {
                if seenBlocked.insert(upper).inserted {
                    blocked.append(key)
                }
            }
        }
        return (blocked.sorted(), invalid)
    }
}

