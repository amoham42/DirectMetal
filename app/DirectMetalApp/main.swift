import Foundation

private func printUsage() {
    print("""
    DirectMetal — Apple Silicon DirectX 9/10/11/12 Runtime

    Usage:
      DirectMetal                        Launch desktop GUI (game library launcher)
      DirectMetal info                   Show Apple Silicon GPU, Metal 4, and runtime info
      DirectMetal doctor [--json]        Run 9-point Apple Silicon, runtime, guard & security health check
      DirectMetal completions zsh|bash   Print native shell completion script for zsh or bash
      DirectMetal inspect <exe>          Inspect PE headers, architecture, and DirectX/upscaler APIs
      DirectMetal prefix list            List APFS CoW game prefixes
      DirectMetal prefix create <name>   Create an APFS CoW prefix immediately
      DirectMetal prefix reset <name>    Reset an existing APFS CoW prefix
      DirectMetal prefix delete <name>   Delete an APFS CoW prefix
      DirectMetal cache status           Show pre-compiled shader cache stats
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
                                         upscale, retina, hud, sandbox, args, store, store-id)
      DirectMetal library play <id_or_title> [--warm-server [secs]|--no-warm-server] [-- <args...>]
                                         Launch a saved game with its per-game settings + controller profile
      DirectMetal profiles list [--json] List community game profiles (auto-applied to newly added games)
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
        guard args.count >= 2 else {
            fputs("error: prefix requires subcommand (list|stats|create|reset|delete)\n", stderr)
            return 1
        }
        let mgr = PrefixManager()
        let sub = args[1]
        switch sub {
        case "list":
            for p in mgr.listPrefixes() {
                print(p)
            }
            return 0

        case "stats":
            let stats = mgr.prefixStats()
            if args.dropFirst(2).contains("--json") {
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? enc.encode(stats), let str = String(data: data, encoding: .utf8) {
                    print(str)
                }
                return 0
            }
            if stats.isEmpty {
                print("No managed prefixes found in \(mgr.prefixRoot.path).")
                return 0
            }
            print("Managed Prefixes (\(mgr.prefixRoot.path))")
            print("------------------------------------------------------------------------")
            var totalBytes: UInt64 = 0
            for s in stats {
                totalBytes += s.sizeBytes
                let mib = String(format: "%7.1f MiB", Double(s.sizeBytes) / (1024.0 * 1024.0))
                let clone = s.cowCloneMs.map { String(format: "CoW %.2f ms", $0) } ?? "CoW —"
                let exe = s.gameExe.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "—"
                print("\(s.name.padding(toLength: 24, withPad: " ", startingAt: 0))  \(mib)  (\(String(format: "%5d", s.fileCount)) files)  \(clone)  \(exe)")
            }
            let totalGiB = String(format: "%.2f", Double(totalBytes) / (1024.0 * 1024.0 * 1024.0))
            print("------------------------------------------------------------------------")
            print("Total: \(stats.count) prefix(es), \(totalGiB) GiB logical size (APFS CoW shares common blocks)")
            return 0

        case "create", "reset":
            guard args.count >= 3 else {
                fputs("error: prefix \(sub) requires <name>\n", stderr)
                return 1
            }
            do {
                let paths = try RuntimeLauncher.resolveRuntimePaths()
                guard let base = paths.arm64ecBasePrefix ?? paths.basePrefix else {
                    throw LauncherError.runtimeNotFound("No base-prefix available in DirectMetal runtime")
                }
                let hw = RuntimeLauncher.queryHardwareInfo()
                let res = try mgr.createOrEnsure(
                    name: args[2],
                    basePrefix: base,
                    shaderCacheKey: hw.cacheKey,
                    forceReset: (sub == "reset")
                )
                let msStr = String(format: "%.3f", res.cloneMs)
                print("prefix=\(args[2]) cloned=\(res.clonedNow ? "true" : "false") clone_ms=\(msStr) path=\(res.url.path)")
                return 0
            } catch {
                fputs("prefix \(sub) failed: \(error)\n", stderr)
                return 1
            }

        case "delete":
            guard args.count >= 3 else {
                fputs("error: prefix delete requires <name>\n", stderr)
                return 1
            }
            do {
                try mgr.deletePrefix(named: args[2])
                print("deleted \(args[2])")
                return 0
            } catch {
                fputs("prefix delete failed: \(error)\n", stderr)
                return 1
            }

        default:
            fputs("unknown prefix subcommand: \(sub)\n", stderr)
            return 1
        }

    case "cache":
        guard args.count >= 2 else {
            fputs("error: cache requires subcommand (status|list|prune|export|import|sync|clear)\n", stderr)
            return 1
        }
        let sub = args[1]
        switch sub {
        case "status":
            let summary = RuntimeLauncher.queryShaderCache()
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(summary), let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            return 0
        case "list", "ls":
            let entries = ShaderCacheManager.listLocalCaches()
            let asJSON = args.dropFirst(2).contains("--json")
            if asJSON {
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? enc.encode(entries), let str = String(data: data, encoding: .utf8) {
                    print(str)
                }
                return 0
            }
            if entries.isEmpty {
                print("No local shader caches found.")
                return 0
            }
            let hostKey = RuntimeLauncher.queryHardwareInfo().cacheKey
            print("Local Shader Caches (host key: \(hostKey))")
            print("------------------------------------------------------------------------")
            for e in entries {
                let mib = String(format: "%7.2f MiB", Double(e.totalBytes) / (1024.0 * 1024.0))
                let tag = !e.isKnownKeyedEntry ? "generic" : (e.matchesHostCacheKey ? "current" : "stale  ")
                print("[\(tag)] \(mib)  (\(String(format: "%4d", e.fileCount)) files)  \(e.name)")
            }
            return 0
        case "prune":
            let rest = Array(args.dropFirst(2))
            let dryRun = rest.contains("--dry-run") || rest.contains("-n")
            let asJSON = rest.contains("--json")
            do {
                let res = try ShaderCacheManager.pruneStaleCaches(dryRun: dryRun)
                if asJSON {
                    let enc = JSONEncoder()
                    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                    if let data = try? enc.encode(res), let str = String(data: data, encoding: .utf8) {
                        print(str)
                    }
                    return 0
                }
                let mib = String(format: "%.2f", Double(res.reclaimedBytes) / (1024.0 * 1024.0))
                let verb = dryRun ? "Would reclaim" : "Reclaimed"
                print("\(verb) \(mib) MiB across \(res.removedEntries.count) stale cache(s) (\(res.reclaimedFiles) files); kept \(res.keptEntries.count) entry/entries for host key \(res.currentCacheKey).")
                for name in res.removedEntries {
                    print("  \(dryRun ? "would remove" : "removed"): \(name)")
                }
                return 0
            } catch {
                fputs("cache prune failed: \(error)\n", stderr)
                return 1
            }
        case "export":
            guard args.count >= 3 else {
                fputs("error: cache export requires <output.dmcache.tar.gz>\n", stderr)
                return 1
            }
            let outPath = args[2]
            var filter: String? = nil
            var idx = 3
            while idx < args.count {
                if args[idx] == "--filter", idx + 1 < args.count {
                    filter = args[idx + 1]
                    idx += 2
                } else {
                    idx += 1
                }
            }
            do {
                let res = try ShaderCacheManager.exportArchive(to: outPath, filterEntry: filter)
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? enc.encode(res), let str = String(data: data, encoding: .utf8) {
                    print(str)
                }
                return 0
            } catch {
                fputs("cache export failed: \(error)\n", stderr)
                return 1
            }
        case "import":
            guard args.count >= 3 else {
                fputs("error: cache import requires <archive_path_or_https_url>\n", stderr)
                return 1
            }
            let src = args[2]
            let force = args.dropFirst(3).contains("--force")
            do {
                let res = try ShaderCacheManager.importArchive(from: src, allowCrossBuild: force)
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? enc.encode(res), let str = String(data: data, encoding: .utf8) {
                    print(str)
                }
                return 0
            } catch {
                fputs("cache import failed: \(error)\n", stderr)
                return 1
            }
        case "sync":
            guard args.count >= 3 else {
                fputs("error: cache sync requires <index_url_or_path> (--build-hash <hash> | --exe <path>) [--force]\n", stderr)
                return 1
            }
            let indexSrc = args[2]
            var buildHash: String? = nil
            var exePath: String? = nil
            var force = false
            var idx = 3
            while idx < args.count {
                if args[idx] == "--build-hash", idx + 1 < args.count {
                    buildHash = args[idx + 1]
                    idx += 2
                } else if args[idx] == "--exe", idx + 1 < args.count {
                    exePath = args[idx + 1]
                    idx += 2
                } else if args[idx] == "--force" {
                    force = true
                    idx += 1
                } else {
                    idx += 1
                }
            }
            do {
                let resolvedHash: String
                if let h = buildHash, !h.isEmpty {
                    resolvedHash = h
                } else if let exe = exePath {
                    resolvedHash = try PEInspector.inspect(exePath: exe).buildHash
                } else {
                    fputs("error: cache sync requires either --build-hash <hash> or --exe <path>\n", stderr)
                    return 1
                }
                let res = try ShaderCacheManager.syncFromIndex(
                    indexSource: indexSrc,
                    buildHash: resolvedHash,
                    allowCrossBuild: force
                )
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? enc.encode(res), let str = String(data: data, encoding: .utf8) {
                    print(str)
                }
                return 0
            } catch {
                fputs("cache sync failed: \(error)\n", stderr)
                return 1
            }
        case "clear":
            do {
                try RuntimeLauncher.clearShaderCache()
                print("cleared shader cache")
                return 0
            } catch {
                fputs("cache clear failed: \(error)\n", stderr)
                return 1
            }
        default:
            fputs("unknown cache subcommand: \(sub)\n", stderr)
            return 1
        }

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
                warmServerSeconds: warmServerSeconds
            )
            let elapsedStr = String(format: "%.3f", res.elapsedSeconds)
            let cloneStr = String(format: "%.2f", res.cloneMs)
            fputs("[DirectMetal] engine=\(res.activeEngine) sandbox=\(res.sandboxed ? "seatbelt" : "off") exit=\(res.exitCode) elapsed=\(elapsedStr)s prefix=\(res.prefixPath) (clone_ms=\(cloneStr)) cache=\(res.shaderCacheDir)\n", stderr)
            return res.exitCode
        } catch {
            fputs("run failed: \(error)\n", stderr)
            return 1
        }

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
