import Foundation

// MARK: - Shared CLI JSON & Parsing Helpers

func printLibraryJSON<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? enc.encode(value), let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

func parseBool(_ s: String) -> Bool? {
    switch s.lowercased() {
    case "1", "true", "yes", "on", "y": return true
    case "0", "false", "no", "off", "n": return false
    default: return nil
    }
}

// MARK: - Library CLI

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
        let displayTitle = e.isFavorite ? "★ \(e.title)" : e.title
        print(col(e.id, 14) + col(displayTitle, 34) + col(e.architecture, 9) + col(apis, 26)
            + col(e.engine.rawValue, 9) + col(String(e.playCount), 7) + (e.lastPlayedUtc ?? "never"))
    }
    print("\n\(entries.count) game(s) • \(GameLibraryManager().libraryURL.path)")
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

func runLibraryCLI(args: [String]) -> Int32 {
    let mgr = GameLibraryManager()
    guard let sub = args.first else {
        fputs("error: library requires subcommand (list|scan|add|remove|show|artwork|set|diff|reset-settings|sync-profiles|lint|preflight|play|explain|shortcut|export|import)\n", stderr)
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
            case "fps-cap", "fpscap", "fps":
                let v = value.lowercased()
                if v == "off" || v == "uncapped" || v == "none" {
                    entries[idx].fpsCap = 0
                } else if let n = Int(v), (0...360).contains(n) {
                    entries[idx].fpsCap = n
                } else { ok = false }
            case "retina":
                if let v = parseBool(value) { entries[idx].retinaMode = v } else { ok = false }
            case "hud":
                if let v = parseBool(value) { entries[idx].enableHUD = v } else { ok = false }
            case "sandbox":
                if let v = parseBool(value) { entries[idx].enableSandbox = v } else { ok = false }
            case "args", "extra-args", "extraargs": entries[idx].extraArgs = value
            case "env", "custom-env", "customenv": entries[idx].customEnv = value
            case "store", "storesource":
                let v = value.lowercased()
                if ["steam", "gog", "epic", "standalone"].contains(v) { entries[idx].storeSource = v } else { ok = false }
            case "store-id", "storeid", "storegameid":
                entries[idx].storeGameID = value.isEmpty ? nil : value
            case "favorite", "fav", "pinned", "isfavorite":
                if let v = parseBool(value) { entries[idx].isFavorite = v } else { ok = false }
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
                controllerProfileKey: entry.id,
                fpsCap: entry.fpsCap,
                customEnv: entry.customEnvDictionary
            )
            mgr.recordSessionDuration(id: entry.id, seconds: res.elapsedSeconds)
            LaunchHistoryStore().append(LaunchHistoryEntry(
                gameID: entry.id,
                title: entry.title,
                exePath: entry.exePath,
                prefixName: entry.launchPrefixName,
                requestedEngine: entry.engine.rawValue,
                activeEngine: res.activeEngine,
                exitCode: res.exitCode,
                elapsedSeconds: res.elapsedSeconds,
                sandboxed: res.sandboxed,
                cowCloneMs: res.cloneMs > 0 ? res.cloneMs : nil,
                fpsCap: entry.fpsCap,
                upscaleMode: entry.upscaleMode,
                failure: nil
            ))
            let elapsedStr = String(format: "%.3f", res.elapsedSeconds)
            fputs("[DirectMetal] engine=\(res.activeEngine) sandbox=\(res.sandboxed ? "seatbelt" : "off") exit=\(res.exitCode) elapsed=\(elapsedStr)s prefix=\(res.prefixPath)\n", stderr)
            return res.exitCode
        } catch {
            LaunchHistoryStore().append(LaunchHistoryEntry(
                gameID: entry.id,
                title: entry.title,
                exePath: entry.exePath,
                prefixName: entry.launchPrefixName,
                requestedEngine: entry.engine.rawValue,
                activeEngine: entry.engine.rawValue,
                exitCode: nil,
                elapsedSeconds: 0,
                sandboxed: entry.enableSandbox,
                cowCloneMs: nil,
                fpsCap: entry.fpsCap,
                upscaleMode: entry.upscaleMode,
                failure: "\(error)"
            ))
            fputs("library play failed: \(error)\n", stderr)
            return 1
        }

    case "diff":
        let asJSON = rest.contains("--json")
        let key = rest.filter { $0 != "--json" }.joined(separator: " ")
        guard !key.isEmpty, let entry = mgr.entry(idOrTitle: key) else {
            fputs("library diff failed: no unique game matches \"\(key)\"\n", stderr)
            return 1
        }
        let profile = mgr.profileRegistry.profile(id: entry.profileID)
            ?? mgr.profileRegistry.match(title: entry.title, exePath: entry.exePath,
                                         steamAppID: entry.steamAppID, storeSource: entry.storeSource,
                                         storeGameID: entry.storeGameID)
        let report = ConfigDiffEngine.diff(entry: entry, profile: profile)
        if asJSON {
            printLibraryJSON(report)
        } else {
            print(ConfigDiffEngine.formatText(report))
        }
        return 0

    case "reset-settings":
        let asJSON = rest.contains("--json")
        let key = rest.filter { $0 != "--json" }.joined(separator: " ")
        var entries = mgr.load()
        guard !key.isEmpty,
              let target = GameLibraryManager.find(key, in: entries),
              let idx = entries.firstIndex(where: { $0.id == target.id }) else {
            fputs("library reset-settings failed: no unique game matches \"\(key)\"\n", stderr)
            return 1
        }
        let profile = mgr.profileRegistry.profile(id: entries[idx].profileID)
            ?? mgr.profileRegistry.match(title: entries[idx].title, exePath: entries[idx].exePath,
                                         steamAppID: entries[idx].steamAppID, storeSource: entries[idx].storeSource,
                                         storeGameID: entries[idx].storeGameID)
        ConfigDiffEngine.resetSettings(of: &entries[idx], using: profile)
        mgr.save(entries)
        if asJSON {
            printLibraryJSON(entries[idx])
        } else {
            let baseline = profile.map { "Community Preset: \($0.title)" } ?? "DirectMetal Zero-Config Defaults"
            print("Reset settings for \"\(entries[idx].title)\" to \(baseline).")
        }
        return 0

    case "sync-profiles", "apply-profiles":
        let dryRun = rest.contains("--dry-run") || rest.contains("-n")
        let overwrite = rest.contains("--overwrite") || rest.contains("--force")
        let asJSON = rest.contains("--json")
        let asMarkdown = rest.contains("--markdown") || rest.contains("--md")

        var entries = mgr.load()
        let report = ProfileBatchSync.sync(
            library: &entries,
            registry: mgr.profileRegistry,
            overwriteCustomized: overwrite,
            dryRun: dryRun
        )
        if !dryRun && report.appliedCount > 0 {
            mgr.save(entries)
        }
        if asJSON {
            printLibraryJSON(report)
        } else if asMarkdown {
            print(ProfileBatchSync.formatMarkdown(report))
        } else {
            print(ProfileBatchSync.formatText(report))
        }
        return 0

    case "explain", "plan":
        let asJSON = rest.contains("--json")
        let asMarkdown = rest.contains("--markdown")
        let key = rest.filter { $0 != "--json" && $0 != "--markdown" }.joined(separator: " ")
        guard !key.isEmpty, let entry = mgr.entry(idOrTitle: key) else {
            fputs("library explain failed: no unique game matches \"\(key)\"\n", stderr)
            return 1
        }
        let plan = LaunchPlanInspector.inspect(entry: entry)
        if asJSON {
            printLibraryJSON(plan)
        } else if asMarkdown {
            print(LaunchPlanInspector.formatMarkdown(plan))
        } else {
            print(LaunchPlanInspector.formatText(plan))
        }
        return 0

    case "lint", "validate-env":
        let asJSON = rest.contains("--json")
        let asMarkdown = rest.contains("--markdown") || rest.contains("--md")
        let key = rest.filter { $0 != "--json" && $0 != "--markdown" && $0 != "--md" }.joined(separator: " ")
        guard !key.isEmpty, let entry = mgr.entry(idOrTitle: key) else {
            fputs("library lint failed: no unique game matches \"\(key)\"\n", stderr)
            return 1
        }
        let report = LaunchEnvValidator.validate(entry: entry)
        if asJSON {
            printLibraryJSON(report)
        } else if asMarkdown {
            print(LaunchEnvValidator.formatMarkdown(report))
        } else {
            print(LaunchEnvValidator.formatText(report))
        }
        return report.hasErrors ? 2 : 0

    case "preflight", "ready":
        let asJSON = rest.contains("--json")
        let asMarkdown = rest.contains("--markdown") || rest.contains("--md")
        let key = rest.filter { $0 != "--json" && $0 != "--markdown" && $0 != "--md" }.joined(separator: " ")
        guard !key.isEmpty, let entry = mgr.entry(idOrTitle: key) else {
            fputs("library preflight failed: no unique game matches \"\(key)\"\n", stderr)
            return 1
        }
        let report = PreflightChecker.check(entry: entry)
        if asJSON {
            printLibraryJSON(report)
        } else if asMarkdown {
            print(PreflightChecker.formatMarkdown(report))
        } else {
            print(PreflightChecker.formatText(report))
        }
        return report.canLaunch ? 0 : 2

    case "shortcut":
        var format: ShortcutFormat = .app
        var outDir = ShortcutExporter.defaultShortcutsDirectory()
        var overwrite = true
        let asJSON = rest.contains("--json")
        var keyParts: [String] = []
        var idx = 0
        while idx < rest.count {
            let a = rest[idx]
            if a == "--format", idx + 1 < rest.count {
                guard let parsed = ShortcutFormat(rawValue: rest[idx + 1].lowercased()) else {
                    fputs("error: --format must be 'app' or 'command'\n", stderr)
                    return 1
                }
                format = parsed
                idx += 2
            } else if a == "--dir", idx + 1 < rest.count {
                let expanded = (rest[idx + 1] as NSString).expandingTildeInPath
                outDir = URL(fileURLWithPath: expanded, isDirectory: true)
                idx += 2
            } else if a == "--no-overwrite" {
                overwrite = false
                idx += 1
            } else if a == "--json" {
                idx += 1
            } else {
                keyParts.append(a)
                idx += 1
            }
        }
        let key = keyParts.joined(separator: " ")
        guard !key.isEmpty, let entry = mgr.entry(idOrTitle: key) else {
            fputs("library shortcut failed: no unique game matches \"\(key)\"\n", stderr)
            return 1
        }
        do {
            let res = try ShortcutExporter.export(
                for: entry,
                format: format,
                into: outDir,
                overwrite: overwrite
            )
            if asJSON {
                printLibraryJSON(res)
            } else {
                let iconNote = res.hasCustomIcon ? " (with game icon)" : ""
                print("Created \(res.format.rawValue) shortcut\(iconNote): \(res.outputPath)")
            }
            return 0
        } catch {
            fputs("library shortcut failed: \(error)\n", stderr)
            return 1
        }

    case "export":
        guard let outPath = rest.first, !outPath.isEmpty else {
            fputs("error: library export requires <backup.json>\n", stderr)
            return 1
        }
        do {
            let outURL = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
            let backup = try mgr.exportBackup(to: outURL)
            if rest.contains("--json") {
                printLibraryJSON(backup)
            } else {
                print("Exported \(backup.games.count) game(s) and \(backup.controllerProfiles.count) controller profile(s) to \(outURL.path)")
            }
            return 0
        } catch {
            fputs("library export failed: \(error)\n", stderr)
            return 1
        }

    case "import":
        let positional = rest.filter { !$0.hasPrefix("--") }
        guard let inPath = positional.first, !inPath.isEmpty else {
            fputs("error: library import requires <backup.json> [--overwrite]\n", stderr)
            return 1
        }
        let overwrite = rest.contains("--overwrite")
        do {
            let inURL = URL(fileURLWithPath: (inPath as NSString).expandingTildeInPath)
            let summary = try mgr.importBackup(from: inURL, overwriteExisting: overwrite)
            if rest.contains("--json") {
                printLibraryJSON(summary)
            } else {
                print("Imported backup: added=\(summary.added) updated=\(summary.updated) skipped=\(summary.skipped) controller_profiles=\(summary.controllerProfilesRestored)")
            }
            return 0
        } catch {
            fputs("library import failed: \(error)\n", stderr)
            return 1
        }

    default:
        fputs("unknown library subcommand: \(sub)\n", stderr)
        return 1
    }
}

// MARK: - Profiles CLI

private struct ProfilesListing: Encodable {
    let schema: String
    let source: String
    let userOverlay: String?
    let profiles: [GameProfile]
}

func runProfilesCLI(args: [String]) -> Int32 {
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

    case "match":
        let asJSON = rest.contains("--json")
        let positional = rest.filter { !$0.hasPrefix("--") }
        guard let rawExe = positional.first, !rawExe.isEmpty else {
            fputs("error: profiles match requires <exe_path> [--json]\n", stderr)
            return 1
        }
        let canonical = GameLibraryManager.canonicalPath(rawExe)
        let title = GameLibraryManager.deriveTitle(exePath: canonical)
        let registry = GameProfileRegistry.load()
        let matched = registry.match(title: title, exePath: canonical, steamAppID: nil)
        struct ProfileMatchOutput: Encodable {
            let exePath: String
            let derivedTitle: String
            let matched: Bool
            let profile: GameProfile?
        }
        if asJSON {
            printLibraryJSON(ProfileMatchOutput(exePath: canonical, derivedTitle: title,
                                                matched: matched != nil, profile: matched))
            return matched != nil ? 0 : 1
        }
        if let p = matched {
            print("Matched profile: \(p.id) — \(p.title)")
            print("  status:   \(p.status ?? "-") (\(p.verificationLabel))")
            print("  engine:   \(p.gameEngine ?? "-")")
            print("  settings: perf=\(p.perfProfile?.rawValue ?? "-") dx9=\(p.dx9Backend?.rawValue ?? "-") metalfx=\(p.upscaleMode ?? "-") retina=\(p.retinaMode.map(String.init) ?? "-") sandbox=\(p.enableSandbox.map(String.init) ?? "-")")
            if let notes = p.notes, !notes.isEmpty {
                print("  notes:    \(notes)")
            }
            return 0
        } else {
            print("No community profile matched \"\(title)\" (\(canonical)). DirectMetal will use automatic zero-config PE detection.")
            return 1
        }

    default:
        fputs("unknown profiles subcommand: \(sub) (expected: list [--json] | match <exe> [--json])\n", stderr)
        return 1
    }
}
