import Foundation

private func printUsage() {
    print("""
    DirectMetal — Apple Silicon DirectX 9/10/11/12 Runtime

    Usage:
      DirectMetal                        Launch desktop GUI (game library launcher)
      DirectMetal info                   Show Apple Silicon GPU, Metal 4, and runtime info
      DirectMetal doctor [--json]        Run 9-point Apple Silicon, runtime, guard & security health check
      DirectMetal bench [--json|--markdown]
                                         Run built-in Apple Silicon UMA, APFS CoW, SHA-256 & PE microbenchmarks
      DirectMetal completions zsh|bash   Print native shell completion script for zsh or bash
      DirectMetal inspect <exe>          Inspect PE headers, architecture, and DirectX/upscaler APIs
      DirectMetal prefix list            List APFS CoW game prefixes
      DirectMetal prefix stats [--json]  Show disk usage and metadata for all prefixes
      DirectMetal prefix prune [--dry-run] [--json]
                                         Remove unreferenced prefixes while preserving default & active prefixes
      DirectMetal prefix create <name>   Create an APFS CoW prefix immediately
      DirectMetal prefix reset <name>    Reset an existing APFS CoW prefix
      DirectMetal prefix delete <name>   Delete an APFS CoW prefix
      DirectMetal prefix export-saves <name> <out.tar.gz>
                                         Export SHA-256 verified Windows save data from a prefix
      DirectMetal prefix import-saves <archive.tar.gz> <name>
                                         Verify SHA-256 and restore save data into a prefix
      DirectMetal cache status           Show pre-compiled shader cache stats
      DirectMetal cache list [--json]    List local shader cache directories and host-key match status
      DirectMetal cache prune [--dry-run] [--json]
                                         Remove stale macOS build shader caches while keeping current caches
      DirectMetal cache verify [--quarantine|--repair] [--dry-run] [--json|--markdown]
                                         Verify local shader cache integrity and safely quarantine corrupt files
      DirectMetal cache export <file.tar.gz> [--filter <key>]
                                         Export portable SHA-256 verified shader cache archive
      DirectMetal cache import <path_or_url> [--force]
                                         Import local or cloud HTTPS shader cache archive with SHA-256 verification
      DirectMetal cache sync <index_url_or_path> (--build-hash <hash> | --exe <path>) [--force]
                                         Sync matching GPU/OS shader cache from a cloud or local index.json (double SHA-256 verified)
      DirectMetal cache clear            Clear pre-compiled shader cache
      DirectMetal attest [--nonce <hex>] [--sandbox] [--target <path>] [--pid <pid>]
                                         Collect hardware Secure Enclave attestation v2 JSON (opt-in)
      DirectMetal verify-attest <bundle.json> [--nonce <hex>]
                                         Verify a signed DirectMetal attestation bundle JSON (v1/v2)
      DirectMetal run <exe> [--prefix <name>] [--engine auto|arm64ec|rosetta] [--dx9-backend auto|wined3d|dxvk] [--perf-mode balanced|ultra] [--retina|--no-retina] [--desktop <WxH>|off] [--fex-tso on|off] [--sandbox] [--sandbox-offline] [--sandbox-out <dir>] [--hud] [--reset-prefix] [--upscale quality|balanced|performance|ultra_performance] [--warm-server [secs]|--no-warm-server] [-- <args...>]
      DirectMetal runtime status [--json] [--fast]
                                         Show ARM64EC runtime source (bundled|user-installed|dev-build|missing)
      DirectMetal runtime install [--url <url>] [--sha256 <hex>] [--force]
                                         Download/copy, SHA-256 + codesign verify, and install the notarized runtime
      DirectMetal runtime update [--url <url>] [--sha256 <hex>]
                                         Install the latest upstream MetalSharp-Wine release (SHA256SUMS verified)
                                         (DIRECTMETAL_RUNTIME_UPDATE_URL overrides the release endpoint)
      DirectMetal runtime remove         Remove the user-installed runtime
      DirectMetal runtime warm <prefix> [--seconds <N>]
                                         Start a persistent warm wineserver (default 120 s, ~220 ms launches)
      DirectMetal runtime stop-servers [<prefix>]
                                         Stop warm wineservers (all DirectMetal prefixes when omitted)
      DirectMetal library list [--json]  List saved games and their per-game settings
      DirectMetal library scan [dir...]  Auto-scan prefixes, Steam libraries, GOG Galaxy + Epic Games installs
                                         (prefixes, ~/Games, Heroic), DIRECTMETAL_SCAN_DIR,
                                         ./.directmetal_cache/games and the given folders
      DirectMetal library add <exe> [--title <name>]
                                         Add (or refresh) a game in the library
      DirectMetal library remove <id_or_title>
                                         Remove a game (scans will not re-add it)
      DirectMetal library show <id_or_title>
                                         Print a saved game entry as JSON
      DirectMetal library artwork <id_or_title>
                                         Show which artwork (GOG / Epic / Steam / .exe icon) resolves for a game
      DirectMetal library set <id_or_title> <key>=<value>...
                                         Update per-game settings (title, prefix, engine, perf, dx9,
                                         upscale, fps, retina, hud, sandbox, favorite, args, env, store, store-id)
      DirectMetal library diff <id_or_title> [--json]
                                         Compare per-game settings against community preset or defaults
      DirectMetal library reset-settings <id_or_title> [--json]
                                         Reset per-game settings to baseline while keeping playtime & favorites
      DirectMetal library sync-profiles [--dry-run] [--overwrite] [--json|--markdown]
                                         Apply newly matched community profiles across the library safely
      DirectMetal library explain <id_or_title> [--json|--markdown]
                                         Preview full dry-run launch plan without spawning Wine
      DirectMetal library lint <id_or_title> [--json|--markdown]
                                         Lint customEnv & extraArgs for blocked keys, Proton vars & syntax issues
      DirectMetal library preflight <id_or_title> [--json|--markdown]
                                         Run 7-point launch readiness & kernel anti-cheat pre-flight check
      DirectMetal library shortcut <id_or_title> [--format app|command] [--dir <path>]
                                         Export a native macOS Spotlight/Dock .app or .command launcher
      DirectMetal library play <id_or_title> [--warm-server [secs]|--no-warm-server] [-- <args...>]
                                         Launch a saved game with its per-game settings + controller profile
      DirectMetal profiles list [--json] List community game profiles (auto-applied to newly added games)
      DirectMetal profiles match <exe> [--title <name>] [--steam-id <id>] [--json]
                                         Test which community game profile matches an executable
      DirectMetal history [--limit N] [--json|--markdown] [--clear]
                                         Inspect or export structured launch history
      DirectMetal history stats [--json|--markdown]
                                         Aggregate per-game stability tiers, engine mix & median APFS CoW speed
      DirectMetal diagnose-log <logfile> [--json|--markdown]
                                         Scan a Wine/DirectX/Metal log for crashes, missing DLLs & anti-cheat
      DirectMetal support-bundle [<out.tar.gz>] [--json]
                                         Export a privacy-redacted diagnostics archive for GitHub bug reports
      DirectMetal storage [--json|--markdown]
                                         Audit disk usage across prefixes, caches, backups & runtimes with reclaim tips
      DirectMetal hud show|set|reset [--json]
                                         Inspect or customize the live Metal Performance HUD overlay
      DirectMetal controller list [--json]
                                         List saved controller profiles, presets and connected controllers
      DirectMetal controller show [<default|id_or_title>] [--json]
                                         Show the effective profile and its SDL_GAMECONTROLLERCONFIG launch env
      DirectMetal controller set <default|id_or_title> <key>=<value>...
                                         preset=xboxStandard|nintendoSwap|playstationDualSense|invertedLookY|custom,
                                         left-deadzone=<0-35%>, right-deadzone=<0-35%>, invert-y=<bool>,
                                         haptics=<bool>, <button>=<button> (a b x y leftshoulder rightshoulder
                                         lefttrigger righttrigger leftstick rightstick start back dpup dpdown
                                         dpleft dpright)  (DIRECTMETAL_CONTROLLER_PROFILES overrides the file)
      DirectMetal controller reset [<default|id_or_title>|--all]
                                         Remove a controller profile (stock behavior)
      DirectMetal update check [--json]  Check GitHub Releases for a newer DirectMetal app and MetalSharp-Wine runtime
                                         (DIRECTMETAL_UPDATE_URL overrides, DIRECTMETAL_DISABLE_UPDATE_CHECK=1 disables)
      DirectMetal update apply [--url <dmg_url>] [--sha256 <hex>|--sha256-url <url>] [--target-app <path.app>] [--force]
                                         Download, SHA-256 verify, mount, codesign verify and atomically install
                                         the DirectMetal .dmg (latest release when --url is omitted)
    """)
}

private func runCLI(args: [String]) -> Int32 {
    guard let cmd = args.first else { return 1 }

    switch cmd {
    case "help", "--help", "-h":
        printUsage()
        return 0

    case "doctor":
        return runDoctorCLI(args: Array(args.dropFirst()))

    case "bench", "benchmark":
        return runBenchmarkCLI(args: Array(args.dropFirst()))

    case "completions":
        return runCompletionsCLI(args: Array(args.dropFirst()))

    case "info":
        let hw = RuntimeLauncher.queryHardwareInfo()
        let resolved = try? RuntimeLauncher.resolveRuntimePaths()
        let rosettaStatus = resolved?.wineBin != nil ? "ready (\(resolved!.runtimeRoot.path))" : "omitted (slim arm64ec-only)"
        let arm64ecStatus = resolved?.arm64ecRoot != nil ? "ready (\(resolved!.arm64ecRoot!.path))" : "uninitialized"
        // DirectMetal-owned resources resolve even before a Wine runtime is installed.
        let bundled = RuntimeLauncher.resolveBundledResources(runtimeRoot: resolved?.runtimeRoot)
        let vkCompat = bundled.vkCompatLayerDir ?? resolved?.vkCompatLayerDir
        let mullionConf = bundled.mullionConfig ?? resolved?.mullionConfig
        let display = DisplayCapabilities.current()
        let controllers: [[String: Any]] = ConnectedControllerInfo.snapshot(discoveryWait: 0.25).map { c in
            [
                "vendor_name": c.vendorName,
                "product_category": c.productCategory,
                "supports_haptics": c.supportsHaptics,
                "battery_level": c.batteryLevel.map { $0 as Any } ?? NSNull(),
                "is_attached_to_device": c.isAttachedToDevice,
            ]
        }
        var infoPayload: [String: Any] = [
            "gpu_name": hw.gpuName,
            "gpu_family": hw.gpuFamily,
            "macos_version": hw.macosVersion,
            "macos_build": hw.macosBuild,
            "cache_key": hw.cacheKey,
            "working_set_gib": hw.workingSetGiB,
            "has_unified_memory": hw.hasUnifiedMemory,
            "supports_metal3": hw.supportsMetal3,
            "supports_metal4": hw.supportsMetal4,
            "supports_raytracing": hw.supportsRaytracing,
            "supports_metalfx_spatial": hw.supportsMetalFXSpatial,
            "supports_metalfx_temporal": hw.supportsMetalFXTemporal,
            "supports_metal4fx": hw.supportsMetal4FX,
            "runtime": rosettaStatus,
            "arm64ec_fex_runtime": arm64ecStatus,
            "arm64ec_runtime_source": RuntimeManager.status(checkCodesign: false, measureDisk: false).source.rawValue,
            "vk_compat_layer": vkCompat?.path ?? "unavailable",
            "kosmickrisp_icd": resolved?.arm64ecKosmicKrispICD?.path ?? "unavailable",
        ]
        infoPayload["app_version"] = RuntimeLauncher.appVersion()
        infoPayload["mullion_config"] = mullionConf?.path ?? "unavailable"
        infoPayload["display_available"] = display.displayAvailable
        infoPayload["display_resolution"] = display.displayAvailable
            ? "\(display.logicalWidth)x\(display.logicalHeight) (\(display.pixelWidth)x\(display.pixelHeight) px)" : "unavailable"
        infoPayload["display_scale"] = display.scaleFactor
        infoPayload["display_dpi"] = display.dpi
        infoPayload["display_refresh_hz"] = display.refreshRateHz
        infoPayload["display_hdr_edr"] = display.supportsHDR
        infoPayload["display_edr_headroom"] = display.edrHeadroom
        infoPayload["display_potential_edr_headroom"] = display.potentialEDRHeadroom
        infoPayload["connected_controllers"] = controllers
        if let data = try? JSONSerialization.data(withJSONObject: infoPayload, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            print(json)
        }
        return 0

    case "inspect":
        guard args.count >= 2 else {
            fputs("error: missing <exe> argument\n", stderr)
            return 1
        }
        do {
            let prof = try PEInspector.inspect(exePath: args[1])
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(prof)
            if let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            return 0
        } catch {
            fputs("inspect failed: \(error)\n", stderr)
            return 1
        }

    case "prefix":
        return runPrefixCLI(args: Array(args.dropFirst()))

    case "cache":
        return runCacheCLI(args: Array(args.dropFirst()))

    case "library":
        return runLibraryCLI(args: Array(args.dropFirst()))

    case "runtime":
        return runRuntimeCLI(args: Array(args.dropFirst()))

    case "profiles", "profile":
        return runProfilesCLI(args: Array(args.dropFirst()))

    case "update", "updates":
        return runUpdateCLI(args: Array(args.dropFirst()))

    case "controller", "controllers", "gamepad":
        return runControllerCLI(args: Array(args.dropFirst()))

    case "verify-attest":
        guard args.count >= 2 else {
            fputs("error: verify-attest requires <bundle.json> [--nonce <hex>]\n", stderr)
            return 1
        }
        let bundlePath = args[1]
        var expectedNonce: String? = nil
        var idx = 2
        while idx < args.count {
            if args[idx] == "--nonce", idx + 1 < args.count {
                expectedNonce = args[idx + 1]
                idx += 2
            } else {
                idx += 1
            }
        }
        guard let jsonStr = try? String(contentsOfFile: bundlePath, encoding: .utf8) else {
            fputs("error: could not read attestation bundle at \(bundlePath)\n", stderr)
            return 1
        }
        let valid = DirectMetalAttestation.verify(bundleJSON: jsonStr, expectedNonce: expectedNonce)
        let verdict: [String: Any] = [
            "bundle_path": bundlePath,
            "expected_nonce": expectedNonce ?? "",
            "valid": valid,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: verdict, options: [.prettyPrinted, .sortedKeys]),
           let out = String(data: data, encoding: .utf8) {
            print(out)
        }
        return valid ? 0 : 1

    case "attest":
        var nonceHex = String(format: "%016llx", UInt64.random(in: 0...UInt64.max))
        var sandboxActive = false
        var targetPath: String? = nil
        var targetPid: Int32? = nil
        var idx = 1
        while idx < args.count {
            let a = args[idx]
            if a == "--nonce", idx + 1 < args.count {
                nonceHex = args[idx + 1]
                idx += 2
            } else if a == "--target", idx + 1 < args.count {
                targetPath = args[idx + 1]
                idx += 2
            } else if a == "--pid", idx + 1 < args.count {
                targetPid = Int32(args[idx + 1])
                idx += 2
            } else if a == "--sandbox" {
                sandboxActive = true
                idx += 1
            } else {
                idx += 1
            }
        }
        let status = DirectMetalAttestation.collectStatus(targetBinaryPath: targetPath, sandboxActive: sandboxActive)
        do {
            let (json, verified) = try DirectMetalAttestation.generateSignedBundle(
                status: status,
                nonceHex: nonceHex,
                targetPid: targetPid
            )
            print(json)
            if !verified {
                fputs("error: self-verification of ECDSA attestation failed\n", stderr)
                return 1
            }
            return 0
        } catch {
            fputs("attest failed: \(error)\n", stderr)
            return 1
        }

    case "run":
        guard args.count >= 2 else {
            fputs("error: run requires <exe>\n", stderr)
            return 1
        }
        let exePath = args[1]
        var prefixName = URL(fileURLWithPath: exePath).deletingPathExtension().lastPathComponent
        if prefixName.isEmpty { prefixName = "default" }
        var enableHUD = false
        var resetPrefix = false
        var sandboxed = false
        var sandboxOffline = false
        var sandboxOutDir: String? = nil
        var upscaleMode: String? = nil
        var engine: ExecutionEngine = .auto
        var fexTSO = true
        var fexTSOOverride: Bool? = nil
        var dx9Backend: DX9Backend = .auto
        var perfProfile: PerfProfile = .balanced
        var retinaMode: Bool? = nil
        var virtualDesktop: String? = nil
        var warmServerSeconds: Int? = nil
        var fpsCap = 0
        var customEnvPairs: [String: String] = [:]
        var childArgs: [String] = []

        var i = 2
        while i < args.count {
            let a = args[i]
            if a == "--" {
                childArgs.append(contentsOf: args[(i + 1)...])
                break
            } else if let w = parseWarmServerFlag(args, at: i) {
                guard w.seconds >= 0 else {
                    fputs("error: invalid --warm-server value \"\(a)\"\n", stderr)
                    return 1
                }
                warmServerSeconds = w.seconds
                i += w.consumed
            } else if a == "--prefix", i + 1 < args.count {
                prefixName = args[i + 1]
                i += 2
            } else if a == "--upscale", i + 1 < args.count {
                upscaleMode = args[i + 1]
                i += 2
            } else if a == "--fps-cap", i + 1 < args.count {
                fpsCap = max(0, min(Int(args[i + 1]) ?? 0, 360))
                i += 2
            } else if a == "--env", i + 1 < args.count {
                for (k, v) in GameLibraryManager.parseCustomEnv(args[i + 1]) {
                    customEnvPairs[k] = v
                }
                i += 2
            } else if a == "--engine", i + 1 < args.count {
                engine = ExecutionEngine(rawValue: args[i + 1].lowercased()) ?? .auto
                i += 2
            } else if a == "--fex-tso", i + 1 < args.count {
                let parsed = (args[i + 1].lowercased() != "off" && args[i + 1] != "0")
                fexTSO = parsed
                fexTSOOverride = parsed
                i += 2
            } else if a == "--dx9-backend", i + 1 < args.count {
                dx9Backend = DX9Backend(rawValue: args[i + 1].lowercased()) ?? .auto
                i += 2
            } else if a == "--perf-mode", i + 1 < args.count {
                perfProfile = PerfProfile(rawValue: args[i + 1].lowercased()) ?? .balanced
                i += 2
            } else if a == "--retina" {
                retinaMode = true
                i += 1
            } else if a == "--no-retina" {
                retinaMode = false
                i += 1
            } else if a == "--desktop", i + 1 < args.count {
                virtualDesktop = args[i + 1]
                i += 2
            } else if a == "--hud" {
                enableHUD = true
                i += 1
            } else if a == "--reset-prefix" {
                resetPrefix = true
                i += 1
            } else if a == "--sandbox" {
                sandboxed = true
                i += 1
            } else if a == "--sandbox-offline" {
                sandboxed = true
                sandboxOffline = true
                i += 1
            } else if a == "--sandbox-out", i + 1 < args.count {
                sandboxOutDir = args[i + 1]
                i += 2
            } else {
                childArgs.append(a)
                i += 1
            }
        }

        do {
            let res = try RuntimeLauncher.runExecutable(
                exePath: exePath,
                prefixName: prefixName,
                extraArgs: childArgs,
                enableHUD: enableHUD,
                resetPrefix: resetPrefix,
                upscaleMode: upscaleMode,
                engine: engine,
                fexTSO: fexTSO,
                dx9Backend: dx9Backend,
                perfProfile: perfProfile,
                retinaMode: retinaMode,
                virtualDesktop: virtualDesktop,
                sandboxed: sandboxed,
                sandboxOffline: sandboxOffline,
                sandboxOutputDir: sandboxOutDir,
                fexTSOOverride: fexTSOOverride,
                warmServerSeconds: warmServerSeconds,
                fpsCap: fpsCap,
                customEnv: customEnvPairs
            )
            LaunchHistoryStore().append(LaunchHistoryEntry(
                gameID: nil,
                title: GameLibraryManager.deriveTitle(exePath: exePath),
                exePath: GameLibraryManager.canonicalPath(exePath),
                prefixName: prefixName,
                requestedEngine: engine.rawValue,
                activeEngine: res.activeEngine,
                exitCode: res.exitCode,
                elapsedSeconds: res.elapsedSeconds,
                sandboxed: res.sandboxed,
                cowCloneMs: res.cloneMs > 0 ? res.cloneMs : nil,
                fpsCap: fpsCap,
                upscaleMode: upscaleMode ?? "off",
                failure: nil
            ))
            let elapsedStr = String(format: "%.3f", res.elapsedSeconds)
            let cloneStr = String(format: "%.2f", res.cloneMs)
            fputs("[DirectMetal] engine=\(res.activeEngine) sandbox=\(res.sandboxed ? "seatbelt" : "off") exit=\(res.exitCode) elapsed=\(elapsedStr)s prefix=\(res.prefixPath) (clone_ms=\(cloneStr)) cache=\(res.shaderCacheDir)\n", stderr)
            return res.exitCode
        } catch {
            LaunchHistoryStore().append(LaunchHistoryEntry(
                gameID: nil,
                title: GameLibraryManager.deriveTitle(exePath: exePath),
                exePath: GameLibraryManager.canonicalPath(exePath),
                prefixName: prefixName,
                requestedEngine: engine.rawValue,
                activeEngine: engine.rawValue,
                exitCode: nil,
                elapsedSeconds: 0,
                sandboxed: sandboxed,
                cowCloneMs: nil,
                fpsCap: fpsCap,
                upscaleMode: upscaleMode ?? "off",
                failure: "\(error)"
            ))
            fputs("run failed: \(error)\n", stderr)
            return 1
        }

    case "history":
        return runHistoryCLI(args: Array(args.dropFirst()))

    case "diagnose-log", "triage":
        return runDiagnoseLogCLI(args: Array(args.dropFirst()))

    case "support-bundle":
        return runSupportBundleCLI(args: Array(args.dropFirst()))

    case "storage", "disk":
        return runStorageCLI(args: Array(args.dropFirst()))

    case "hud":
        return runHUDCLI(args: Array(args.dropFirst()))

    default:
        fputs("unknown command: \(cmd)\n", stderr)
        printUsage()
        return 1
    }
}

let rawArgs = Array(CommandLine.arguments.dropFirst())
let isCLISubcommand: Bool = {
    guard let first = rawArgs.first else { return false }
    // Ignore macOS LaunchServices -psn_* arguments when launched from Finder
    return !first.hasPrefix("-psn_")
}()

if isCLISubcommand {
    let code = runCLI(args: rawArgs)
    Foundation.exit(code)
} else {
    DirectMetalDesktopApp.main()
}
