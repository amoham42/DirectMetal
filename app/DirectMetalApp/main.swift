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

/// Single-line (TTY) or per-phase/decile (pipe) progress reporting on stderr for long CLI operations.
private final class CLIProgressPrinter {
    let tag: String
    private let tty = isatty(STDERR_FILENO) != 0
    private var lastPhase = ""
    private var lastDecile = -1
    private var inlineActive = false

    init(tag: String) {
        self.tag = tag
    }

    func emit(phase: String, message: String, bytes: Int64, total: Int64, fraction: Double) {
        var line = "[\(tag)] \(phase): \(message)"
        if bytes > 0 {
            line += " \(formatMB(bytes))"
            if total > 0 { line += " / \(formatMB(total))" }
            if fraction >= 0 { line += String(format: " (%.0f%%)", fraction * 100) }
        }
        let decile = fraction >= 0 ? Int(fraction * 10) : -1
        if tty {
            if inlineActive && phase != lastPhase { fputs("\n", stderr) }
            fputs("\r\u{1B}[2K" + line, stderr)
            inlineActive = fraction >= 0 && fraction < 1
            if !inlineActive { fputs("\n", stderr) }
        } else if phase != lastPhase || decile != lastDecile {
            fputs(line + "\n", stderr)
        }
        lastPhase = phase
        lastDecile = decile
    }

    func finish() {
        if tty && inlineActive { fputs("\n", stderr) }
        inlineActive = false
    }
}

/// Parses `--warm-server [N]`, `--warm-server=N` and `--no-warm-server` at `args[i]`.
/// Returns `nil` when `args[i]` is not a warm-server flag; `seconds == 0` disables; `seconds < 0` = invalid value.
private func parseWarmServerFlag(_ args: [String], at i: Int) -> (seconds: Int, consumed: Int)? {
    let a = args[i]
    if a == "--no-warm-server" { return (0, 1) }
    if a.hasPrefix("--warm-server=") {
        guard let n = Int(a.dropFirst("--warm-server=".count)), n >= 0 else { return (-1, 1) }
        return (n, 1)
    }
    if a == "--warm-server" {
        if i + 1 < args.count, let n = Int(args[i + 1]), n >= 0 { return (n, 2) }
        return (WineserverPool.defaultPersistSeconds, 1)
    }
    return nil
}

private func formatMB(_ bytes: Int64) -> String {
    return String(format: "%.1f MB", Double(max(bytes, 0)) / 1_000_000.0)
}

private func runRuntimeCLI(args: [String]) -> Int32 {
    guard let sub = args.first else {
        fputs("error: runtime requires subcommand (status|install|update|remove|warm|stop-servers)\n", stderr)
        return 1
    }
    let rest = Array(args.dropFirst())

    func wineserverForPrefixes() -> URL? {
        guard let paths = try? RuntimeLauncher.resolveRuntimePaths() else { return nil }
        return paths.arm64ecWineserverBin ?? paths.wineserverBin
    }

    switch sub {
    case "status":
        let fast = rest.contains("--fast")
        let st = RuntimeManager.status(checkCodesign: !fast, measureDisk: !fast)
        if rest.contains("--json") {
            printLibraryJSON(st)
        } else {
            print("installed:       \(st.installed)")
            print("source:          \(st.source.rawValue)")
            print("version:         \(st.version)")
            print("runtime_root:    \(st.runtimeRoot ?? "-")")
            print("codesign_valid:  \(st.codesignValid.map { String($0) } ?? "not checked")")
            print("disk:            \(st.diskBytes.map { formatMB(Int64($0)) } ?? "not measured")")
            print("user_runtime:    \(st.userRuntimeDir)")
            print("archive_url:     \(st.archiveURL)")
            print("expected_sha256: \(st.expectedSHA256)")
            if !st.installed {
                print("\nRun `DirectMetal runtime install` to download the notarized runtime (\(RuntimeManager.archiveSizeLabel)).")
            }
        }
        return 0

    case "install":
        var sourceURL: URL? = nil
        var sha: String? = nil
        var force = false
        var i = 0
        while i < rest.count {
            let a = rest[i]
            if a == "--url", i + 1 < rest.count {
                guard let u = RuntimeManager.parseSourceURL(rest[i + 1]) else {
                    fputs("error: invalid --url \(rest[i + 1])\n", stderr)
                    return 1
                }
                sourceURL = u
                i += 2
            } else if a == "--sha256", i + 1 < rest.count {
                sha = rest[i + 1]
                i += 2
            } else if a == "--force" {
                force = true
                i += 1
            } else {
                fputs("error: unknown runtime install option \(a)\n", stderr)
                return 1
            }
        }
        let tty = isatty(STDERR_FILENO) != 0
        var lastPhase = ""
        var lastDecile = -1
        var inlineActive = false
        let t0 = DispatchTime.now().uptimeNanoseconds
        do {
            let root = try RuntimeManager.installARM64ECRuntime(
                sourceURL: sourceURL, expectedSHA256: sha, force: force
            ) { p in
                let phase = p.phase.rawValue
                var line = "[runtime] \(phase): \(p.message)"
                if p.bytesReceived > 0 {
                    line += " \(formatMB(p.bytesReceived))"
                    if p.totalBytes > 0 { line += " / \(formatMB(p.totalBytes))" }
                    if p.fraction >= 0 { line += String(format: " (%.0f%%)", p.fraction * 100) }
                }
                let decile = p.fraction >= 0 ? Int(p.fraction * 10) : -1
                if tty {
                    // Live single-line updates for byte progress; finished/indeterminate steps keep their own line.
                    if inlineActive && phase != lastPhase { fputs("\n", stderr) }
                    fputs("\r\u{1B}[2K" + line, stderr)
                    inlineActive = p.fraction >= 0 && p.fraction < 1
                    if !inlineActive { fputs("\n", stderr) }
                } else if phase != lastPhase || decile != lastDecile {
                    fputs(line + "\n", stderr)
                }
                lastPhase = phase
                lastDecile = decile
            }
            let secs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
            fputs(String(format: "[runtime] done in %.1f s\n", secs), stderr)
            print(root.path)
            return 0
        } catch {
            if tty { fputs("\n", stderr) }
            fputs("runtime install failed: \(error)\n", stderr)
            return 1
        }

    case "update", "upgrade":
        var sourceURL: URL? = nil
        var sha: String? = nil
        var i = 0
        while i < rest.count {
            let a = rest[i]
            if a == "--url", i + 1 < rest.count {
                guard let u = RuntimeManager.parseSourceURL(rest[i + 1]) else {
                    fputs("error: invalid --url \(rest[i + 1])\n", stderr)
                    return 1
                }
                sourceURL = u
                i += 2
            } else if a == "--sha256", i + 1 < rest.count {
                sha = rest[i + 1]
                i += 2
            } else {
                fputs("error: unknown runtime update option \(a)\n", stderr)
                return 1
            }
        }
        let printer = CLIProgressPrinter(tag: "runtime")
        let t0 = DispatchTime.now().uptimeNanoseconds
        do {
            let root = try AppUpdater.updateRuntime(zipURL: sourceURL, expectedSHA256: sha) { p in
                printer.emit(phase: p.phase.rawValue, message: p.message, bytes: p.bytesReceived,
                             total: p.totalBytes, fraction: p.fraction)
            }
            printer.finish()
            let secs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
            fputs(String(format: "[runtime] MetalSharp-Wine %@ ready in %.1f s\n", AppUpdater.installedRuntimeVersion(), secs), stderr)
            print(root.path)
            return 0
        } catch {
            printer.finish()
            fputs("runtime update failed: \(error)\n", stderr)
            return 1
        }

    case "remove", "uninstall":
        let dir = RuntimeManager.userARM64ECRuntimeDir()
        do {
            try RuntimeManager.removeUserRuntime()
            print("removed \(dir.path)")
            return 0
        } catch {
            fputs("runtime remove failed: \(error)\n", stderr)
            return 1
        }

    case "warm":
        guard let name = rest.first, !name.hasPrefix("--") else {
            fputs("error: runtime warm requires <prefix_name> [--seconds <N>]\n", stderr)
            return 1
        }
        var seconds = WineserverPool.defaultPersistSeconds
        if let i = rest.firstIndex(of: "--seconds") {
            guard i + 1 < rest.count, let n = Int(rest[i + 1]), n > 0 else {
                fputs("error: --seconds requires a positive integer\n", stderr)
                return 1
            }
            seconds = n
        }
        guard let ws = wineserverForPrefixes() else {
            fputs("runtime warm failed: no DirectMetal runtime installed (run `DirectMetal runtime install`)\n", stderr)
            return 1
        }
        let prefix = PrefixManager().prefixURL(named: name)
        guard FileManager.default.fileExists(atPath: prefix.path) else {
            fputs("runtime warm failed: prefix \"\(name)\" not found at \(prefix.path) (create it with `DirectMetal prefix create \(name)`)\n", stderr)
            return 1
        }
        let wasRunning = WineserverPool.runningPID(prefixURL: prefix)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let ok = WineserverPool.warm(prefixURL: prefix, wineserverBin: ws, persistSeconds: seconds)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        let pid = WineserverPool.runningPID(prefixURL: prefix)
        guard ok else {
            fputs("runtime warm failed: wineserver did not start for \(prefix.path)\n", stderr)
            return 1
        }
        print(String(format: "warm prefix=%@ pid=%@ %@ in %.1f ms", name, pid.map { String($0) } ?? "?",
                     wasRunning != nil ? "reused (existing server keeps its own lifetime)" : "started persist=\(seconds)s", ms))
        return 0

    case "stop-servers", "stop":
        guard let ws = wineserverForPrefixes() else {
            fputs("runtime stop-servers failed: no DirectMetal runtime installed\n", stderr)
            return 1
        }
        let mgr = PrefixManager()
        let names = rest.isEmpty ? mgr.listPrefixes() : rest
        var stopped = 0
        for name in names {
            let prefix = mgr.prefixURL(named: name)
            guard let pid = WineserverPool.runningPID(prefixURL: prefix) else {
                if !rest.isEmpty { print("prefix=\(name) no wineserver running") }
                continue
            }
            WineserverPool.stop(prefixURL: prefix, wineserverBin: ws)
            let still = WineserverPool.runningPID(prefixURL: prefix)
            print("prefix=\(name) pid=\(pid) \(still == nil ? "stopped" : "STILL RUNNING")")
            if still == nil { stopped += 1 }
        }
        print("stopped \(stopped) wineserver(s)")
        return 0

    default:
        fputs("unknown runtime subcommand: \(sub)\n", stderr)
        return 1
    }
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
                let store = e.storeSource.map { s in " {\(s)\(e.storeGameID.map { ":\($0)" } ?? "")}" } ?? ""
                print("+ \(e.title)  [\(e.architecture) \(e.detectedAPIs.joined(separator: "+"))]\(store)  \(e.exePath)")
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

    case "artwork", "art":
        let key = rest.filter { $0 != "--json" }.joined(separator: " ")
        guard let entry = mgr.entry(idOrTitle: key) else {
            fputs("library artwork failed: no unique game matches \"\(key)\"\n", stderr)
            return 1
        }
        func describe(_ style: ArtworkStyle) -> ArtworkInfo? {
            GameArtworkManager.shared.resolveArtwork(for: entry, style: style).map {
                ArtworkInfo(source: $0.source, path: $0.path, width: $0.pixelWidth, height: $0.pixelHeight)
            }
        }
        printLibraryJSON(ArtworkReport(id: entry.id, title: entry.title, exePath: entry.exePath,
                                       storeSource: entry.storeSource, storeGameID: entry.storeGameID,
                                       steamAppID: entry.steamAppID, banner: describe(.banner), icon: describe(.icon)))
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
            case "store", "storesource":
                let v = value.lowercased()
                if ["steam", "gog", "epic", "standalone"].contains(v) { entries[idx].storeSource = v } else { ok = false }
            case "store-id", "storeid", "storegameid":
                entries[idx].storeGameID = value.isEmpty ? nil : value
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
        var warmServerSeconds: Int? = nil
        var titleParts: [String] = []
        var k = 0
        while k < keyParts.count {
            if let w = parseWarmServerFlag(keyParts, at: k) {
                guard w.seconds >= 0 else {
                    fputs("error: invalid --warm-server value \"\(keyParts[k])\"\n", stderr)
                    return 1
                }
                warmServerSeconds = w.seconds
                k += w.consumed
            } else {
                titleParts.append(keyParts[k])
                k += 1
            }
        }
        let key = titleParts.joined(separator: " ")
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
                sandboxed: entry.enableSandbox,
                warmServerSeconds: warmServerSeconds,
                controllerProfileKey: entry.id
            )
            mgr.recordSessionDuration(id: entry.id, seconds: res.elapsedSeconds)
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

private struct ProfilesListing: Encodable {
    let schema: String
    let source: String
    let userOverlay: String?
    let profiles: [GameProfile]
}

private func runProfilesCLI(args: [String]) -> Int32 {
    let sub = args.first ?? "list"
    let rest = Array(args.dropFirst())
    switch sub {
    case "list", "ls", "--json":
        let registry = GameProfileRegistry.load()
        if sub == "--json" || rest.contains("--json") {
            printLibraryJSON(ProfilesListing(schema: GameProfileRegistry.schemaID, source: registry.source,
                                             userOverlay: registry.userOverlay, profiles: registry.profiles))
            return 0
        }
        func col(_ s: String, _ width: Int) -> String {
            let t = s.count > width - 1 ? String(s.prefix(width - 2)) + "…" : s
            return t.padding(toLength: width, withPad: " ", startingAt: 0)
        }
        print(col("ID", 38) + col("TITLE", 40) + col("STATUS", 19) + col("PERF", 10) + col("DX9", 9) + col("METALFX", 12) + "VERIFIED")
        for p in registry.profiles {
            print(col(p.id, 38) + col(p.title, 40) + col(p.status ?? "-", 19) + col(p.perfProfile?.rawValue ?? "-", 10)
                + col(p.dx9Backend?.rawValue ?? "-", 9) + col(p.upscaleMode ?? "-", 12) + p.verifiedOn.joined(separator: ", "))
        }
        let verified = registry.profiles.filter(\.isVerified).count
        print("\n\(registry.profiles.count) profile(s), \(verified) tested on real hardware • source: \(registry.source)"
            + (registry.userOverlay.map { " + overlay \($0)" } ?? ""))
        return 0
    default:
        fputs("unknown profiles subcommand: \(sub) (expected: list [--json])\n", stderr)
        return 1
    }
}

private struct ArtworkInfo: Encodable {
    let source: String
    let path: String
    let width: Int
    let height: Int
}

private struct ArtworkReport: Encodable {
    let id: String
    let title: String
    let exePath: String
    let storeSource: String?
    let storeGameID: String?
    let steamAppID: String?
    let banner: ArtworkInfo?
    let icon: ArtworkInfo?
}

/// `update check --json`: every pre-existing top-level `UpdateCheckResult` key, plus `appDmgURL`,
/// `appSha256URL` and the nested MetalSharp-Wine `runtime` status.
private func updateCheckJSON(_ status: DualUpdateStatus) -> String? {
    let enc = JSONEncoder()
    guard let appData = try? enc.encode(status.app),
          var obj = try? JSONSerialization.jsonObject(with: appData) as? [String: Any],
          let rtData = try? enc.encode(status.runtime),
          let runtime = try? JSONSerialization.jsonObject(with: rtData) else { return nil }
    obj["runtime"] = runtime
    obj["appDmgURL"] = status.app.dmgURL ?? NSNull()
    obj["appSha256URL"] = status.app.sha256URL ?? NSNull()
    guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    else { return nil }
    return String(data: out, encoding: .utf8)
}

private func runUpdateCLI(args: [String]) -> Int32 {
    let sub = args.first ?? "check"
    let rest = Array(args.dropFirst())
    switch sub {
    case "check", "--json":
        let status = AppUpdater.checkAll()
        let result = status.app
        let rt = status.runtime
        if sub == "--json" || rest.contains("--json") {
            if let json = updateCheckJSON(status) { print(json) }
            return (result.error == nil || result.disabled) ? 0 : 1
        }
        if result.disabled {
            print("Update check disabled (DIRECTMETAL_DISABLE_UPDATE_CHECK=1). Current version: \(result.currentVersion)")
            return 0
        }
        if let err = result.error {
            fputs("update check failed: \(err)\n", stderr)
        } else if result.updateAvailable {
            print("Update available: DirectMetal \(result.currentVersion) -> \(result.latestVersion ?? "?")"
                + (result.publishedAt.map { " (published \($0))" } ?? ""))
            if let url = result.releaseURL { print(url) }
            if let dmg = result.dmgURL {
                print("  \(result.assetName ?? "dmg"): \(dmg)" + (result.sha256URL == nil ? " (no .sha256 sidecar published)" : ""))
                print("  Install with: DirectMetal update apply")
            }
        } else {
            print("DirectMetal \(result.currentVersion) is up to date (latest release: \(result.latestVersion ?? "?")).")
        }
        let installedNote = rt.installed ? "" : " (not installed)"
        if let err = rt.error {
            print("MetalSharp-Wine runtime \(rt.currentVersion)\(installedNote): update check failed: \(err)")
        } else if rt.updateAvailable {
            print("Runtime update available: MetalSharp-Wine \(rt.currentVersion) -> \(rt.latestVersion ?? "?")\(installedNote)"
                + (rt.publishedAt.map { " (published \($0))" } ?? ""))
            if let zip = rt.zipURL { print("  \(rt.assetName ?? "zip"): \(zip)") }
            print("  Install with: DirectMetal runtime update")
        } else {
            print("MetalSharp-Wine runtime \(rt.currentVersion)\(installedNote) is up to date (latest release: \(rt.latestVersion ?? "?")).")
        }
        return (result.error == nil || result.disabled) ? 0 : 1

    case "apply", "install":
        var dmgURL: URL? = nil
        var sha: String? = nil
        var shaURL: URL? = nil
        var target: URL? = nil
        var force = false
        var i = 0
        while i < rest.count {
            let a = rest[i]
            if a == "--url", i + 1 < rest.count {
                guard let u = RuntimeManager.parseSourceURL(rest[i + 1]) else {
                    fputs("error: invalid --url \(rest[i + 1])\n", stderr)
                    return 1
                }
                dmgURL = u
                i += 2
            } else if a == "--sha256", i + 1 < rest.count {
                sha = rest[i + 1]
                i += 2
            } else if a == "--sha256-url", i + 1 < rest.count {
                guard let u = RuntimeManager.parseSourceURL(rest[i + 1]) else {
                    fputs("error: invalid --sha256-url \(rest[i + 1])\n", stderr)
                    return 1
                }
                shaURL = u
                i += 2
            } else if a == "--target-app", i + 1 < rest.count {
                target = URL(fileURLWithPath: (rest[i + 1] as NSString).expandingTildeInPath, isDirectory: true)
                i += 2
            } else if a == "--force" {
                force = true
                i += 1
            } else {
                fputs("error: unknown update apply option \(a)\n", stderr)
                return 1
            }
        }
        if dmgURL == nil {
            let r = UpdateChecker.check()
            if r.disabled {
                fputs("update apply failed: update checks are disabled (DIRECTMETAL_DISABLE_UPDATE_CHECK=1); pass --url\n", stderr)
                return 1
            }
            if let err = r.error {
                fputs("update apply failed: \(err)\n", stderr)
                return 1
            }
            guard r.updateAvailable || force else {
                print("DirectMetal \(r.currentVersion) is up to date (latest release: \(r.latestVersion ?? "?")).")
                return 0
            }
            guard let d = r.dmgURL, let u = URL(string: d) else {
                fputs("update apply failed: release \(r.latestVersion ?? "?") has no \(AppUpdater.runningEdition().assetName) asset\n", stderr)
                return 1
            }
            dmgURL = u
            if sha == nil && shaURL == nil { shaURL = r.sha256URL.flatMap { URL(string: $0) } }
            fputs("[update] DirectMetal \(r.currentVersion) -> \(r.latestVersion ?? "?") (\(r.assetName ?? u.lastPathComponent))\n", stderr)
        }
        guard let source = dmgURL else { return 1 }
        let printer = CLIProgressPrinter(tag: "update")
        let t0 = DispatchTime.now().uptimeNanoseconds
        do {
            let installed = try AppUpdater.applyAppUpdate(dmgURL: source, expectedSHA256: sha, sha256URL: shaURL,
                                                          targetAppURL: target) { p in
                printer.emit(phase: p.phase.rawValue, message: p.message, bytes: p.bytesReceived,
                             total: p.totalBytes, fraction: p.fraction)
            }
            printer.finish()
            fputs(String(format: "[update] done in %.1f s\n", Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9), stderr)
            print(installed.path)
            return 0
        } catch {
            printer.finish()
            fputs("update apply failed: \(error)\n", stderr)
            return 1
        }

    default:
        fputs("unknown update subcommand: \(sub) (expected: check [--json] | apply [--url <url>] [--sha256 <hex>] [--target-app <path>])\n", stderr)
        return 1
    }
}

// MARK: - Controller CLI

private struct ControllerShowOutput: Encodable {
    let requestedKey: String
    let resolvedKey: String
    let source: String
    let profilesFile: String
    let isStock: Bool
    let profile: ControllerMappingProfile
    let environment: [String: String]
}

private struct ControllerListOutput: Encodable {
    struct Connected: Encodable {
        let vendorName: String
        let productCategory: String
        let supportsHaptics: Bool
        let batteryLevel: Int?
    }

    let profilesFile: String
    let profiles: [String: ControllerMappingProfile]
    let presets: [String]
    let connectedControllers: [Connected]
}

/// `default` / `global` -> the global profile; otherwise a library id / title resolves to the entry id, else the raw key.
private func resolveControllerKey(_ raw: String) -> String {
    let k = ControllerMappingManager.normalizedKey(raw)
    if k == ControllerMappingManager.defaultKey || k.lowercased() == "global" { return ControllerMappingManager.defaultKey }
    return GameLibraryManager().entry(idOrTitle: k)?.id ?? k
}

private func parseDeadzone(_ raw: String) -> Double? {
    let t = raw.trimmingCharacters(in: .whitespaces)
    let isPercent = t.hasSuffix("%")
    guard let v = Double(t.trimmingCharacters(in: CharacterSet(charactersIn: "%"))), v.isFinite, v >= 0 else { return nil }
    return (isPercent || v >= 1) ? v / 100 : v
}

private func printControllerProfile(requested: String, resolvedKey: String, source: String,
                                    profile: ControllerMappingProfile, json: Bool) {
    let env = ControllerMappingManager.environmentOverrides(profile: profile, key: resolvedKey)
    if json {
        printLibraryJSON(ControllerShowOutput(requestedKey: requested, resolvedKey: resolvedKey, source: source,
                                              profilesFile: ControllerMappingManager.profilesURL.path,
                                              isStock: profile.isStock, profile: profile, environment: env))
        return
    }
    print("profile:        \(resolvedKey) (\(source))\(requested != resolvedKey ? " for \(requested)" : "")")
    print("preset:         \(profile.preset.rawValue) — \(profile.preset.displayName)")
    print(String(format: "dead zones:     left %.0f%%, right %.0f%%", profile.leftDeadzone * 100, profile.rightDeadzone * 100))
    print("invert right Y: \(profile.invertRightY)")
    print("haptics:        \(profile.enableHaptics)")
    let remaps = ControllerMappingProfile.canonicalButtons.compactMap { b -> String? in
        let to = profile.buttonMap[b] ?? b
        return to == b ? nil : "\(b)->\(to)"
    }
    print("remaps:         \(remaps.isEmpty ? "none" : remaps.joined(separator: ", "))")
    print("file:           \(ControllerMappingManager.profilesURL.path)")
    if env.isEmpty {
        print("launch env:     none (stock controller behavior)")
    } else {
        print("launch env:")
        for k in env.keys.sorted() where k != "SDL_GAMECONTROLLERCONFIG" { print("  \(k)=\(env[k]!)") }
        let lines = env["SDL_GAMECONTROLLERCONFIG"]?.split(separator: "\n") ?? []
        print("  SDL_GAMECONTROLLERCONFIG: \(lines.count) mapping(s), e.g.")
        if let first = lines.first { print("    \(first)") }
    }
}

private func runControllerCLI(args: [String]) -> Int32 {
    let sub = args.first ?? "list"
    let rest = Array(args.dropFirst())
    let json = rest.contains("--json")
    let positional = rest.filter { !$0.hasPrefix("--") }

    switch sub {
    case "list", "ls":
        let profiles = ControllerMappingManager.loadAll()
        let connected = ConnectedControllerInfo.snapshot(discoveryWait: json ? 0 : 0.25)
        if json {
            printLibraryJSON(ControllerListOutput(
                profilesFile: ControllerMappingManager.profilesURL.path, profiles: profiles,
                presets: ControllerPreset.allCases.map(\.rawValue),
                connectedControllers: connected.map {
                    .init(vendorName: $0.vendorName, productCategory: $0.productCategory,
                          supportsHaptics: $0.supportsHaptics, batteryLevel: $0.batteryLevel)
                }))
            return 0
        }
        func col(_ s: String, _ width: Int) -> String {
            let t = s.count > width - 1 ? String(s.prefix(width - 2)) + "…" : s
            return t.padding(toLength: width, withPad: " ", startingAt: 0)
        }
        if profiles.isEmpty {
            print("No controller profiles saved (stock behavior everywhere).")
        } else {
            let titles = Dictionary(GameLibraryManager().load().map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
            print(col("KEY", 16) + col("GAME", 28) + col("PRESET", 22) + col("DZ-L", 6) + col("DZ-R", 6) + col("INV-Y", 7) + col("HAPTICS", 9) + "REMAPS")
            for key in profiles.keys.sorted(by: { ($0 == "default" ? "" : $0) < ($1 == "default" ? "" : $1) }) {
                let p = profiles[key]!
                let remaps = ControllerMappingProfile.canonicalButtons.filter { (p.buttonMap[$0] ?? $0) != $0 }.count
                print(col(key, 16) + col(key == "default" ? "(global)" : (titles[key] ?? "-"), 28) + col(p.preset.rawValue, 22)
                    + col(String(format: "%.0f%%", p.leftDeadzone * 100), 6) + col(String(format: "%.0f%%", p.rightDeadzone * 100), 6)
                    + col(String(p.invertRightY), 7) + col(String(p.enableHaptics), 9) + String(remaps))
            }
        }
        print("\nPresets: " + ControllerPreset.allCases.map(\.rawValue).joined(separator: ", "))
        print("Connected: " + (connected.isEmpty ? "none" : connected.map(\.summary).joined(separator: "; ")))
        print("File: \(ControllerMappingManager.profilesURL.path)")
        return 0

    case "show", "get":
        let requested = positional.isEmpty ? ControllerMappingManager.defaultKey : resolveControllerKey(positional.joined(separator: " "))
        let r = ControllerMappingManager.resolvedProfile(for: requested)
        printControllerProfile(requested: requested, resolvedKey: r.key, source: r.source, profile: r.profile, json: json)
        return 0

    case "set":
        guard let rawKey = positional.first else {
            fputs("error: controller set requires <default|id_or_title> <key>=<value>...\n", stderr)
            return 1
        }
        let key = resolveControllerKey(rawKey)
        let pairs = Array(positional.dropFirst())
        guard !pairs.isEmpty else {
            fputs("error: controller set requires at least one <key>=<value>\n", stderr)
            return 1
        }
        // Start from the stored profile; a new per-game profile inherits the current global profile.
        var profile = ControllerMappingManager.storedProfile(for: key)
            ?? ControllerMappingManager.resolvedProfile(for: nil).profile
        var parsed: [(key: String, value: String)] = []
        for pair in pairs {
            guard let eq = pair.firstIndex(of: "=") else {
                fputs("error: expected <key>=<value>, got \"\(pair)\"\n", stderr)
                return 1
            }
            parsed.append((pair[..<eq].lowercased(), String(pair[pair.index(after: eq)...])))
        }
        // Presets first so explicit options in the same command refine them, whatever the argument order.
        for (k, v) in parsed where k == "preset" {
            guard let p = ControllerPreset.allCases.first(where: { $0.rawValue.lowercased() == v.lowercased() }) else {
                fputs("error: unknown preset \"\(v)\" (expected: \(ControllerPreset.allCases.map(\.rawValue).joined(separator: ", ")))\n", stderr)
                return 1
            }
            profile.applyPreset(p)
        }
        let buttons = Set(ControllerMappingProfile.canonicalButtons)
        for (k, v) in parsed where k != "preset" {
            var ok = true
            switch k {
            case "left-deadzone", "deadzone-left", "leftdeadzone", "ldz", "deadzone-l":
                if let d = parseDeadzone(v) { profile.leftDeadzone = d } else { ok = false }
            case "right-deadzone", "deadzone-right", "rightdeadzone", "rdz", "deadzone-r":
                if let d = parseDeadzone(v) { profile.rightDeadzone = d } else { ok = false }
            case "deadzone":
                if let d = parseDeadzone(v) { profile.leftDeadzone = d; profile.rightDeadzone = d } else { ok = false }
            case "invert-y", "invert-right-y", "inverty", "invertrighty", "invert":
                if let b = parseBool(v) { profile.invertRightY = b } else { ok = false }
            case "haptics", "rumble", "enablehaptics":
                if let b = parseBool(v) { profile.enableHaptics = b } else { ok = false }
            default:
                let button = k.hasPrefix("map.") ? String(k.dropFirst(4)) : k
                guard buttons.contains(button) else {
                    fputs("error: unknown setting \"\(k)\"\n", stderr)
                    return 1
                }
                let target = v.lowercased()
                if buttons.contains(target) {
                    profile.buttonMap[button] = target
                    profile.preset = .custom
                } else { ok = false }
            }
            if !ok {
                fputs("error: invalid value \"\(v)\" for \(k)\n", stderr)
                return 1
            }
        }
        for (name, d) in [("left", profile.leftDeadzone), ("right", profile.rightDeadzone)]
        where !ControllerMappingProfile.deadzoneRange.contains(d) {
            fputs(String(format: "warning: %@ dead zone %.0f%% clamped to 0-35%%\n", name, d * 100), stderr)
        }
        profile = profile.normalized()
        do {
            try ControllerMappingManager.setProfile(profile, for: key)
        } catch {
            fputs("controller set failed: \(error)\n", stderr)
            return 1
        }
        let r = ControllerMappingManager.resolvedProfile(for: key)
        printControllerProfile(requested: key, resolvedKey: r.key, source: r.source, profile: r.profile, json: json)
        return 0

    case "reset", "rm", "remove":
        do {
            if rest.contains("--all") {
                try ControllerMappingManager.resetAll()
                print("reset all controller profiles (\(ControllerMappingManager.profilesURL.path))")
                return 0
            }
            let key = positional.isEmpty ? ControllerMappingManager.defaultKey : resolveControllerKey(positional.joined(separator: " "))
            let existed = try ControllerMappingManager.resetProfile(for: key)
            print(existed ? "reset controller profile \(key) (stock behavior)" : "no controller profile stored for \(key) (already stock)")
            return 0
        } catch {
            fputs("controller reset failed: \(error)\n", stderr)
            return 1
        }

    default:
        fputs("unknown controller subcommand: \(sub) (expected: list|show|set|reset)\n", stderr)
        return 1
    }
}

private struct DoctorCheck: Codable {
    let id: String
    let status: String   // "ok" | "warn" | "fail"
    let summary: String
    let remediation: String?
}

private struct DoctorReport: Codable {
    let appVersion: String
    let overallStatus: String
    let passed: Int
    let warnings: Int
    let failures: Int
    let checks: [DoctorCheck]
}

private func runDoctorCLI(args: [String]) -> Int32 {
    let asJSON = args.contains("--json")
    let fm = FileManager.default
    var checks: [DoctorCheck] = []

    // 1. Apple Silicon & Metal capabilities
    let hw = RuntimeLauncher.queryHardwareInfo()
    if hw.hasUnifiedMemory && hw.supportsMetal3 {
        let m4Text = hw.supportsMetal4 ? "Metal 4 + MetalFX" : "Metal 3 + MetalFX"
        checks.append(DoctorCheck(
            id: "gpu_metal",
            status: "ok",
            summary: "\(hw.gpuName) (\(hw.gpuFamily), \(String(format: "%.1f", hw.workingSetGiB)) GiB UMA, \(m4Text))",
            remediation: nil
        ))
    } else {
        checks.append(DoctorCheck(
            id: "gpu_metal",
            status: "fail",
            summary: "Unsupported GPU (\(hw.gpuName) / \(hw.gpuFamily)) — Apple Silicon Metal 3+ required",
            remediation: "Run DirectMetal on an Apple Silicon Mac (M1 or newer)."
        ))
    }

    // 2. macOS version & 32-bit post-Rosetta tier
    let osVer = ProcessInfo.processInfo.operatingSystemVersion
    let is26_4Plus = (osVer.majorVersion > 26) || (osVer.majorVersion == 26 && osVer.minorVersion >= 4)
    if is26_4Plus {
        checks.append(DoctorCheck(
            id: "macos_tier",
            status: "ok",
            summary: "macOS \(hw.macosVersion) (\(hw.macosBuild)) — full 100% post-Rosetta 64-bit & 32-bit ARM64EC + FL 12_2",
            remediation: nil
        ))
    } else if osVer.majorVersion >= 15 {
        checks.append(DoctorCheck(
            id: "macos_tier",
            status: "warn",
            summary: "macOS \(hw.macosVersion) (\(hw.macosBuild)) — 64-bit ARM64EC ready; 32-bit titles need --include-rosetta",
            remediation: "Upgrade to macOS 26.4+ for native 32-bit ARM64EC + Metal 4, or package with ./scripts/package_app.sh --include-rosetta."
        ))
    } else {
        checks.append(DoctorCheck(
            id: "macos_tier",
            status: "fail",
            summary: "macOS \(hw.macosVersion) is below the macOS 15.0 Sequoia minimum",
            remediation: "Upgrade to macOS 15.0 Sequoia or newer."
        ))
    }

    // 3. ARM64EC runtime & code signature
    let rtStatus = RuntimeManager.status(checkCodesign: true, measureDisk: false)
    if rtStatus.installed {
        let sigOK = rtStatus.codesignValid ?? true
        checks.append(DoctorCheck(
            id: "arm64ec_runtime",
            status: sigOK ? "ok" : "warn",
            summary: "MetalSharp-Wine \(rtStatus.version) (\(rtStatus.source.rawValue), codesign=\(sigOK ? "valid" : "unverified"))",
            remediation: sigOK ? nil : "Reinstall runtime via `DirectMetal runtime install --force`."
        ))
    } else {
        checks.append(DoctorCheck(
            id: "arm64ec_runtime",
            status: "warn",
            summary: "ARM64EC runtime not installed yet (DirectMetal-Lite mode)",
            remediation: "Run `DirectMetal runtime install` or launch the GUI for one-click verified setup."
        ))
    }

    // 4. Bundled graphics layers & D3D12 guard
    let resolved = try? RuntimeLauncher.resolveRuntimePaths()
    let bundled = RuntimeLauncher.resolveBundledResources(runtimeRoot: resolved?.runtimeRoot)
    let vkLayer = bundled.vkCompatLayerDir ?? resolved?.vkCompatLayerDir
    let guardPaths: [URL] = [
        Bundle.main.resourceURL?.appendingPathComponent("guards/d3d12_x64.dll"),
        URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("build/dm_d3d12_placed_guard/d3d12_x64.dll"),
    ].compactMap { $0 }
    let hasGuard = guardPaths.contains { fm.fileExists(atPath: $0.path) }
    if vkLayer != nil && (hasGuard || is26_4Plus) {
        checks.append(DoctorCheck(
            id: "graphics_layers",
            status: "ok",
            summary: "VK compat layer ready; D3D12 placed-resource guard \(hasGuard ? "bundled" : "native on macOS \(hw.macosVersion)")",
            remediation: nil
        ))
    } else {
        checks.append(DoctorCheck(
            id: "graphics_layers",
            status: "warn",
            summary: "VK compat layer=\(vkLayer != nil ? "ready" : "missing"), D3D12 guard=\(hasGuard ? "bundled" : "missing")",
            remediation: "Run `make app-lite` or download the official release DMG."
        ))
    }

    // 5. Base prefix hydration
    if let root = resolved?.arm64ecRoot {
        let unpacked = root.appendingPathComponent("base-prefix/system.reg")
        if fm.fileExists(atPath: unpacked.path) {
            checks.append(DoctorCheck(
                id: "base_prefix",
                status: "ok",
                summary: "Golden ARM64EC base prefix ready (APFS CoW clones in ~0.4 ms)",
                remediation: nil
            ))
        } else if let fp = try? BasePrefixHydrator.readFingerprint(runtimeRoot: root) {
            let hydrated = BasePrefixHydrator.hydratedDestination(fingerprint: fp)
            let ready = fm.fileExists(atPath: hydrated.appendingPathComponent(".hydrated_ok").path)
            checks.append(DoctorCheck(
                id: "base_prefix",
                status: "ok",
                summary: ready
                    ? "Dehydrated base prefix hydrated (\(fp), zero-copy APFS ready)"
                    : "Dehydrated base prefix staged (\(fp); hydrates automatically in ~150 ms on first launch)",
                remediation: nil
            ))
        } else {
            checks.append(DoctorCheck(
                id: "base_prefix",
                status: "warn",
                summary: "Base prefix not initialized under \(root.path)",
                remediation: "Run `DirectMetal runtime install --force`."
            ))
        }
    } else {
        checks.append(DoctorCheck(
            id: "base_prefix",
            status: "warn",
            summary: "Skipped (waiting for runtime install)",
            remediation: "Run `DirectMetal runtime install`."
        ))
    }

    // 6. Display Retina PPI / ProMotion / HDR
    let disp = DisplayCapabilities.current()
    if disp.displayAvailable {
        let hdr = disp.supportsHDR ? "HDR/EDR \(String(format: "%.1fx", disp.potentialEDRHeadroom))" : "SDR"
        checks.append(DoctorCheck(
            id: "display",
            status: "ok",
            summary: "\(disp.pixelWidth)x\(disp.pixelHeight) px @ \(disp.dpi) DPI, \(Int(disp.refreshRateHz.rounded())) Hz, \(hdr)",
            remediation: nil
        ))
    } else {
        checks.append(DoctorCheck(
            id: "display",
            status: "warn",
            summary: "No active GUI display detected (headless / SSH session)",
            remediation: nil
        ))
    }

    // 7. Shader cache & community game profiles
    let cache = RuntimeLauncher.queryShaderCache()
    let profiles = GameProfileRegistry.load()
    let cacheMiB = Double(cache.totalBytes) / (1024.0 * 1024.0)
    checks.append(DoctorCheck(
        id: "cache_and_profiles",
        status: profiles.profiles.isEmpty ? "warn" : "ok",
        summary: String(format: "Shader cache: %d titles (%d files, %.1f MiB) · %d community game profiles loaded",
                        cache.entryCount, cache.fileCount, cacheMiB, profiles.profiles.count),
        remediation: profiles.profiles.isEmpty ? "Re-package DirectMetal to bundle runtime/profiles/game_profiles.json." : nil
    ))

    // 8. Controllers
    let controllers = ConnectedControllerInfo.snapshot(discoveryWait: 0.15)
    let ctrlSummary = controllers.isEmpty
        ? "No physical gamepads connected (SDL remapper ready)"
        : controllers.map { "\($0.vendorName) (\($0.supportsHaptics ? "haptics" : "standard"))" }.joined(separator: ", ")
    checks.append(DoctorCheck(
        id: "controllers",
        status: "ok",
        summary: ctrlSummary,
        remediation: nil
    ))

    // 9. Security & Hardware Attestation posture
    let att = DirectMetalAttestation.collectStatus()
    let secOK = att.sipEnabled && att.ssvSealed && att.secureEnclaveAvailable
    checks.append(DoctorCheck(
        id: "security",
        status: secOK ? "ok" : "warn",
        summary: "SIP=\(att.sipEnabled ? "on" : "off"), SSV=\(att.ssvSealed ? "sealed" : "unsealed"), HardenedRuntime=\(att.hardenedRuntime ? "on" : "off"), SecureEnclave=\(att.secureEnclaveAvailable ? "yes" : "no"), DCAppAttest=\(att.dcAppAttestSupported ? "yes" : "no")",
        remediation: secOK ? nil : "Ensure SIP and SSV remain enabled for hardware-backed attestation."
    ))

    let passed = checks.filter { $0.status == "ok" }.count
    let warns = checks.filter { $0.status == "warn" }.count
    let fails = checks.filter { $0.status == "fail" }.count
    let overall = fails > 0 ? "fail" : (warns > 0 ? "warn" : "ok")
    let report = DoctorReport(
        appVersion: RuntimeLauncher.appVersion(),
        overallStatus: overall,
        passed: passed,
        warnings: warns,
        failures: fails,
        checks: checks
    )

    if asJSON {
        printLibraryJSON(report)
    } else {
        print("DirectMetal Doctor (v\(report.appVersion))")
        print(String(repeating: "-", count: 56))
        for c in checks {
            let tag = c.status == "ok" ? "[OK]  " : (c.status == "warn" ? "[WARN]" : "[FAIL]")
            print("\(tag) \(c.id.padding(toLength: 19, withPad: " ", startingAt: 0)) \(c.summary)")
            if let rem = c.remediation {
                print("       -> \(rem)")
            }
        }
        print(String(repeating: "-", count: 56))
        print("Summary: \(passed) ok, \(warns) warning(s), \(fails) failure(s) (status=\(overall))")
    }
    return fails > 0 ? 1 : 0
}

private func runCompletionsCLI(args: [String]) -> Int32 {
    guard let shell = args.first?.lowercased(), shell == "zsh" || shell == "bash" else {
        fputs("usage: DirectMetal completions zsh|bash\n", stderr)
        return 1
    }
    if shell == "zsh" {
        print(#"""
#compdef DirectMetal directmetal
# DirectMetal zsh completion — install via:
#   eval "$(DirectMetal completions zsh)"

_directmetal() {
  local -a commands
  commands=(
    'info:Show Apple Silicon GPU, Metal 4, display HDR and runtime info'
    'doctor:Run 9-point Apple Silicon, runtime, guard and security health check'
    'inspect:Inspect Windows PE headers, architecture and DirectX/upscaler APIs'
    'run:Launch a Windows DirectX executable via DirectMetal'
    'library:Manage saved games, auto-scanner, artwork and per-game settings'
    'runtime:Install, update, verify or warm the ARM64EC+FEX runtime'
    'prefix:Create, list, reset or delete APFS CoW game prefixes'
    'cache:Inspect, export, import, sync or clear pre-compiled Metal shader caches'
    'controller:Configure global or per-game controller remapping and deadzones'
    'profiles:List bundled and custom community game profiles'
    'update:Check for or apply DirectMetal and MetalSharp-Wine updates'
    'attest:Collect Secure Enclave hardware attestation v2 JSON'
    'verify-attest:Verify a signed DirectMetal attestation bundle'
    'completions:Output shell completion script (zsh or bash)'
    'help:Show CLI usage'
  )

  if (( CURRENT == 2 )); then
    _describe -t commands 'DirectMetal command' commands
    return
  fi

  case "$words[2]" in
    library)
      local -a sub=(list scan add remove show artwork set play)
      _values 'library subcommand' $sub
      ;;
    runtime)
      local -a sub=(status install update remove warm stop-servers)
      _values 'runtime subcommand' $sub
      ;;
    prefix)
      local -a sub=(list stats create reset delete)
      _values 'prefix subcommand' $sub
      ;;
    cache)
      local -a sub=(status list prune export import sync clear)
      _values 'cache subcommand' $sub
      ;;
    controller)
      local -a sub=(list show set reset)
      _values 'controller subcommand' $sub
      ;;
    update)
      local -a sub=(check apply)
      _values 'update subcommand' $sub
      ;;
    profiles)
      _values 'profiles subcommand' list
      ;;
    completions)
      _values 'shell' zsh bash
      ;;
    run)
      _arguments \
        '--prefix[Prefix name]:name:' \
        '--engine[Execution engine]:engine:(auto arm64ec rosetta)' \
        '--dx9-backend[D3D9 backend]:backend:(auto wined3d dxvk)' \
        '--perf-mode[Performance profile]:mode:(balanced ultra)' \
        '--upscale[MetalFX upscaling mode]:upscale:(quality balanced performance ultra_performance)' \
        '--retina[Enable Retina backing scale and HiDPI]' \
        '--no-retina[Disable Retina scaling]' \
        '--sandbox[Run inside macOS Seatbelt sandbox]' \
        '--sandbox-offline[Disable network inside sandbox]' \
        '--hud[Enable Metal/DXVK performance HUD]' \
        '--warm-server[Keep persistent wineserver warm]:seconds:' \
        '--no-warm-server[Disable persistent wineserver]' \
        '--reset-prefix[Reset APFS CoW prefix before launch]' \
        '*:Windows executable:_files -g "*.exe"'
      ;;
    *)
      _files
      ;;
  esac
}

compdef _directmetal DirectMetal directmetal
"""#)
    } else {
        print(#"""
# DirectMetal bash completion — install via:
#   eval "$(DirectMetal completions bash)"

_directmetal_completions() {
  local cur prev cmd
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  cmd="${COMP_WORDS[1]}"

  if [[ ${COMP_CWORD} -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "info doctor inspect run library runtime prefix cache controller profiles update attest verify-attest completions help" -- "${cur}") )
    return 0
  fi

  case "${cmd}" in
    library)
      COMPREPLY=( $(compgen -W "list scan add remove show artwork set play" -- "${cur}") )
      ;;
    runtime)
      COMPREPLY=( $(compgen -W "status install update remove warm stop-servers" -- "${cur}") )
      ;;
    prefix)
      COMPREPLY=( $(compgen -W "list stats create reset delete" -- "${cur}") )
      ;;
    cache)
      COMPREPLY=( $(compgen -W "status list prune export import sync clear" -- "${cur}") )
      ;;
    controller)
      COMPREPLY=( $(compgen -W "list show set reset" -- "${cur}") )
      ;;
    update)
      COMPREPLY=( $(compgen -W "check apply" -- "${cur}") )
      ;;
    profiles)
      COMPREPLY=( $(compgen -W "list" -- "${cur}") )
      ;;
    completions)
      COMPREPLY=( $(compgen -W "zsh bash" -- "${cur}") )
      ;;
    run)
      COMPREPLY=( $(compgen -W "--prefix --engine --dx9-backend --perf-mode --upscale --retina --no-retina --desktop --fex-tso --sandbox --sandbox-offline --sandbox-out --hud --reset-prefix --warm-server --no-warm-server" -- "${cur}") )
      ;;
  esac
}

complete -F _directmetal_completions DirectMetal directmetal
"""#)
    }
    return 0
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
