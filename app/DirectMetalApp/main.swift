import Foundation

private func printUsage() {
    print("""
    DirectMetal — Apple Silicon DirectX 9/10/11/12 Runtime

    Usage:
      DirectMetal                        Launch desktop GUI (game library launcher)
      DirectMetal info                   Show Apple Silicon GPU, Metal 4, and runtime info
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
      DirectMetal run <exe> [--prefix <name>] [--engine auto|arm64ec|rosetta] [--dx9-backend auto|wined3d|dxvk] [--perf-mode balanced|ultra] [--retina|--no-retina] [--desktop <WxH>|off] [--fex-tso on|off] [--sandbox] [--sandbox-offline] [--sandbox-out <dir>] [--hud] [--reset-prefix] [--upscale quality|balanced|performance|ultra_performance] [-- <args...>]
      DirectMetal library list [--json]  List saved games and their per-game settings
      DirectMetal library scan [dir...]  Auto-scan prefixes, Steam libraries, DIRECTMETAL_SCAN_DIR,
                                         ./.directmetal_cache/games and the given folders
      DirectMetal library add <exe> [--title <name>]
                                         Add (or refresh) a game in the library
      DirectMetal library remove <id_or_title>
                                         Remove a game (scans will not re-add it)
      DirectMetal library show <id_or_title>
                                         Print a saved game entry as JSON
      DirectMetal library set <id_or_title> <key>=<value>...
                                         Update per-game settings (title, prefix, engine, perf, dx9,
                                         upscale, retina, hud, sandbox, args)
      DirectMetal library play <id_or_title> [-- <args...>]
                                         Launch a saved game with its per-game settings
    """)
}

private func printLibraryJSON<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? enc.encode(value), let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

private func printLibraryTable(_ entries: [GameLibraryEntry]) {
    guard !entries.isEmpty else {
        print("Library is empty. Run `DirectMetal library scan` or `DirectMetal library add <exe>`.")
        return
    }
    func col(_ s: String, _ width: Int) -> String {
        let t = s.count > width - 1 ? String(s.prefix(width - 2)) + "…" : s
        return t.padding(toLength: width, withPad: " ", startingAt: 0)
    }
    print(col("ID", 14) + col("TITLE", 34) + col("ARCH", 9) + col("APIS", 26) + col("ENGINE", 9) + col("PLAYS", 7) + "LAST PLAYED")
    for e in entries {
        let apis = e.detectedAPIs.isEmpty ? "-" : e.detectedAPIs.joined(separator: "+")
        print(col(e.id, 14) + col(e.title, 34) + col(e.architecture, 9) + col(apis, 26)
            + col(e.engine.rawValue, 9) + col(String(e.playCount), 7) + (e.lastPlayedUtc ?? "never"))
    }
    print("\n\(entries.count) game(s) • \(GameLibraryManager().libraryURL.path)")
}

private func parseBool(_ s: String) -> Bool? {
    switch s.lowercased() {
    case "1", "true", "yes", "on", "y": return true
    case "0", "false", "no", "off", "n": return false
    default: return nil
    }
}

private func runLibraryCLI(args: [String]) -> Int32 {
    let mgr = GameLibraryManager()
    guard let sub = args.first else {
        fputs("error: library requires subcommand (list|scan|add|remove|show|set|play)\n", stderr)
        return 1
    }
    let rest = Array(args.dropFirst())

    switch sub {
    case "list", "ls":
        let entries = mgr.load()
        if rest.contains("--json") {
            printLibraryJSON(entries)
        } else {
            printLibraryTable(entries)
        }
        return 0

    case "scan":
        let before = Set(mgr.load().map(\.id))
        let entries = mgr.scanKnownLocations(extraDirs: rest.filter { $0 != "--json" })
        if rest.contains("--json") {
            printLibraryJSON(entries)
        } else {
            let added = entries.filter { !before.contains($0.id) }
            for e in added {
                print("+ \(e.title)  [\(e.architecture) \(e.detectedAPIs.joined(separator: "+"))]  \(e.exePath)")
            }
            print("scan complete: \(added.count) new, \(entries.count) total\n")
            printLibraryTable(entries)
        }
        return 0

    case "add":
        guard let exe = rest.first, !exe.hasPrefix("--") else {
            fputs("error: library add requires <exe> [--title <name>]\n", stderr)
            return 1
        }
        var title: String? = nil
        if let i = rest.firstIndex(of: "--title"), i + 1 < rest.count {
            title = rest[i + 1]
        }
        do {
            let entry = try mgr.addOrUpdate(exePath: exe, customTitle: title)
            print("added id=\(entry.id) title=\"\(entry.title)\" arch=\(entry.architecture) apis=\(entry.detectedAPIs.joined(separator: "+")) prefix=\(entry.prefixName)")
            return 0
        } catch {
            fputs("library add failed: \(error)\n", stderr)
            return 1
        }

    case "remove", "rm":
        guard !rest.isEmpty else {
            fputs("error: library remove requires <id_or_title>\n", stderr)
            return 1
        }
        let key = rest.joined(separator: " ")
        guard let entry = mgr.entry(idOrTitle: key), mgr.remove(idOrTitle: entry.id) else {
            fputs("library remove failed: no unique game matches \"\(key)\"\n", stderr)
            return 1
        }
        print("removed id=\(entry.id) title=\"\(entry.title)\"")
        return 0

    case "show":
        let key = rest.joined(separator: " ")
        guard let entry = mgr.entry(idOrTitle: key) else {
            fputs("library show failed: no unique game matches \"\(key)\"\n", stderr)
            return 1
        }
        printLibraryJSON(entry)
        return 0

    case "set":
        guard rest.count >= 2 else {
            fputs("error: library set requires <id_or_title> <key>=<value>...\n", stderr)
            return 1
        }
        var entries = mgr.load()
        guard let target = GameLibraryManager.find(rest[0], in: entries),
              let idx = entries.firstIndex(where: { $0.id == target.id }) else {
            fputs("library set failed: no unique game matches \"\(rest[0])\"\n", stderr)
            return 1
        }
        for pair in rest.dropFirst() {
            guard let eq = pair.firstIndex(of: "=") else {
                fputs("error: expected <key>=<value>, got \"\(pair)\"\n", stderr)
                return 1
            }
            let key = pair[..<eq].lowercased()
            let value = String(pair[pair.index(after: eq)...])
            var ok = true
            switch key {
            case "title": entries[idx].title = value
            case "prefix", "prefixname": entries[idx].prefixName = value
            case "engine":
                if let v = ExecutionEngine(rawValue: value.lowercased()) { entries[idx].engine = v } else { ok = false }
            case "perf", "perf-mode", "perfprofile":
                if let v = PerfProfile(rawValue: value.lowercased()) { entries[idx].perfProfile = v } else { ok = false }
            case "dx9", "dx9-backend", "dx9backend":
                if let v = DX9Backend(rawValue: value.lowercased()) { entries[idx].dx9Backend = v } else { ok = false }
            case "upscale", "metalfx", "upscalemode":
                let v = value.lowercased()
                if ["off", "quality", "balanced", "performance", "ultra_performance"].contains(v) {
                    entries[idx].upscaleMode = v
                } else { ok = false }
            case "retina":
                if let v = parseBool(value) { entries[idx].retinaMode = v } else { ok = false }
            case "hud":
                if let v = parseBool(value) { entries[idx].enableHUD = v } else { ok = false }
            case "sandbox":
                if let v = parseBool(value) { entries[idx].enableSandbox = v } else { ok = false }
            case "args", "extra-args", "extraargs": entries[idx].extraArgs = value
            default:
                fputs("error: unknown setting \"\(key)\"\n", stderr)
                return 1
            }
            if !ok {
                fputs("error: invalid value \"\(value)\" for \(key)\n", stderr)
                return 1
            }
        }
        mgr.save(entries)
        printLibraryJSON(entries[idx])
        return 0

    case "play", "run":
        var keyParts: [String] = []
        var passthrough: [String] = []
        if let dd = rest.firstIndex(of: "--") {
            keyParts = Array(rest[..<dd])
            passthrough = Array(rest[(dd + 1)...])
        } else {
            keyParts = rest
        }
        let key = keyParts.joined(separator: " ")
        guard !key.isEmpty, let entry = mgr.entry(idOrTitle: key) else {
            fputs("library play failed: no unique game matches \"\(key)\"\n", stderr)
            return 1
        }
        guard FileManager.default.fileExists(atPath: entry.exePath) else {
            fputs("library play failed: executable missing at \(entry.exePath)\n", stderr)
            return 1
        }
        mgr.recordLaunch(id: entry.id)
        fputs("[DirectMetal] playing \"\(entry.title)\" (id=\(entry.id) prefix=\(entry.launchPrefixName) engine=\(entry.engine.rawValue) perf=\(entry.perfProfile.rawValue) dx9=\(entry.dx9Backend.rawValue) metalfx=\(entry.upscaleMode) retina=\(entry.retinaMode) hud=\(entry.enableHUD) sandbox=\(entry.enableSandbox))\n", stderr)
        do {
            let res = try RuntimeLauncher.runExecutable(
                exePath: entry.exePath,
                prefixName: entry.launchPrefixName,
                extraArgs: entry.extraArgList + passthrough,
                enableHUD: entry.enableHUD,
                upscaleMode: entry.launchUpscaleMode,
                engine: entry.engine,
                dx9Backend: entry.dx9Backend,
                perfProfile: entry.perfProfile,
                retinaMode: entry.retinaMode,
                sandboxed: entry.enableSandbox
            )
            let elapsedStr = String(format: "%.3f", res.elapsedSeconds)
            fputs("[DirectMetal] engine=\(res.activeEngine) sandbox=\(res.sandboxed ? "seatbelt" : "off") exit=\(res.exitCode) elapsed=\(elapsedStr)s prefix=\(res.prefixPath)\n", stderr)
            return res.exitCode
        } catch {
            fputs("library play failed: \(error)\n", stderr)
            return 1
        }

    default:
        fputs("unknown library subcommand: \(sub)\n", stderr)
        return 1
    }
}

private func runCLI(args: [String]) -> Int32 {
    guard let cmd = args.first else { return 1 }

    switch cmd {
    case "help", "--help", "-h":
        printUsage()
        return 0

    case "info":
        let hw = RuntimeLauncher.queryHardwareInfo()
        let resolved = try? RuntimeLauncher.resolveRuntimePaths()
        let rosettaStatus = resolved?.wineBin != nil ? "ready (\(resolved!.runtimeRoot.path))" : "omitted (slim arm64ec-only)"
        let arm64ecStatus = resolved?.arm64ecRoot != nil ? "ready (\(resolved!.arm64ecRoot!.path))" : "uninitialized"
        let infoPayload: [String: Any] = [
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
            "vk_compat_layer": resolved?.vkCompatLayerDir?.path ?? "unavailable",
            "kosmickrisp_icd": resolved?.arm64ecKosmicKrispICD?.path ?? "unavailable",
        ]
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
            fputs("error: prefix requires subcommand (list|create|reset|delete)\n", stderr)
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
            fputs("error: cache requires subcommand (status|export|import|sync|clear)\n", stderr)
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
        var childArgs: [String] = []

        var i = 2
        while i < args.count {
            let a = args[i]
            if a == "--" {
                childArgs.append(contentsOf: args[(i + 1)...])
                break
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
                fexTSOOverride: fexTSOOverride
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
