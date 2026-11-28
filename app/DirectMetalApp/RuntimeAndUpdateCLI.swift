import Foundation

// MARK: - Progress & Flag Helpers

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
func parseWarmServerFlag(_ args: [String], at i: Int) -> (seconds: Int, consumed: Int)? {
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

// MARK: - Runtime CLI

func runRuntimeCLI(args: [String]) -> Int32 {
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

// MARK: - Update CLI

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

func runUpdateCLI(args: [String]) -> Int32 {
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

func runControllerCLI(args: [String]) -> Int32 {
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
            guard let p = ControllerPreset.parse(v) else {
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
