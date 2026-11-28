import Foundation

// Maintenance, prefix, shader cache, launch history, crash-log triage,
// support bundle, and Metal HUD CLI handlers split cleanly out of main.swift.

func runPrefixCLI(args: [String]) -> Int32 {
    guard let sub = args.first else {
        fputs("error: prefix requires subcommand (list|stats|prune|create|reset|delete|export-saves|import-saves)\n", stderr)
        return 1
    }
    let rest = Array(args.dropFirst())
    let mgr = PrefixManager()
    switch sub {
    case "list":
        for p in mgr.listPrefixes() {
            print(p)
        }
        return 0

    case "stats":
        let stats = mgr.prefixStats()
        if rest.contains("--json") {
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
        guard let name = rest.first, !name.isEmpty else {
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
                name: name,
                basePrefix: base,
                shaderCacheKey: hw.cacheKey,
                forceReset: (sub == "reset")
            )
            let msStr = String(format: "%.3f", res.cloneMs)
            print("prefix=\(name) cloned=\(res.clonedNow ? "true" : "false") clone_ms=\(msStr) path=\(res.url.path)")
            return 0
        } catch {
            fputs("prefix \(sub) failed: \(error)\n", stderr)
            return 1
        }

    case "prune":
        let dryRun = rest.contains("--dry-run") || rest.contains("-n")
        let asJSON = rest.contains("--json")
        let referenced = Set(GameLibraryManager().load().map(\.launchPrefixName))
        do {
            let res = try mgr.pruneOrphanedPrefixes(referencedNames: referenced, dryRun: dryRun)
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
            print("\(verb) \(mib) MiB logical across \(res.removedPrefixes.count) orphaned prefix(es) (\(res.reclaimedFiles) files); kept \(res.keptPrefixes.count) referenced/default prefix(es).")
            for name in res.removedPrefixes {
                print("  \(dryRun ? "would remove" : "removed"): \(name)")
            }
            if !res.skippedRunningPrefixes.isEmpty {
                print("  skipped active wineserver: \(res.skippedRunningPrefixes.joined(separator: ", "))")
            }
            return 0
        } catch {
            fputs("prefix prune failed: \(error)\n", stderr)
            return 1
        }

    case "delete":
        guard let name = rest.first, !name.isEmpty else {
            fputs("error: prefix delete requires <name>\n", stderr)
            return 1
        }
        do {
            try mgr.deletePrefix(named: name)
            print("deleted \(name)")
            return 0
        } catch {
            fputs("prefix delete failed: \(error)\n", stderr)
            return 1
        }

    case "export-saves":
        let asJSON = rest.contains("--json")
        let positional = rest.filter { !$0.hasPrefix("--") }
        guard positional.count >= 2 else {
            fputs("error: prefix export-saves requires <prefix_name> <output.tar.gz> [--json]\n", stderr)
            return 1
        }
        do {
            let res = try SaveBackupManager.exportSaves(prefixName: positional[0], to: positional[1], prefixManager: mgr)
            if asJSON {
                printLibraryJSON(res)
            } else {
                let kib = String(format: "%.1f", Double(res.totalPayloadBytes) / 1024.0)
                print("Exported \(res.fileCount) save file(s) (\(kib) KiB) from prefix \"\(res.prefixName)\" to \(res.archivePath) (manifest_sha256=\(res.manifestSha256.prefix(16))…)")
            }
            return 0
        } catch {
            fputs("prefix export-saves failed: \(error)\n", stderr)
            return 1
        }

    case "import-saves":
        let asJSON = rest.contains("--json")
        let positional = rest.filter { !$0.hasPrefix("--") }
        guard positional.count >= 2 else {
            fputs("error: prefix import-saves requires <prefix_name> <backup.tar.gz> [--json]\n", stderr)
            return 1
        }
        do {
            let res = try SaveBackupManager.importSaves(from: positional[1], into: positional[0], prefixManager: mgr)
            if asJSON {
                printLibraryJSON(res)
            } else {
                let kib = String(format: "%.1f", Double(res.totalBytes) / 1024.0)
                print("Restored \(res.restoredFiles) SHA-256 verified save file(s) (\(kib) KiB) into prefix \"\(res.prefixName)\".")
            }
            return 0
        } catch {
            fputs("prefix import-saves failed: \(error)\n", stderr)
            return 1
        }

    default:
        fputs("unknown prefix subcommand: \(sub)\n", stderr)
        return 1
    }
}

func runCacheCLI(args: [String]) -> Int32 {
    guard let sub = args.first else {
        fputs("error: cache requires subcommand (status|list|verify|prune|export|import|sync|clear)\n", stderr)
        return 1
    }
    let rest = Array(args.dropFirst())
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
        if rest.contains("--json") {
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

    case "verify", "check":
        let doQuarantine = rest.contains("--quarantine") || rest.contains("--repair")
        let dryRun = rest.contains("--dry-run") || rest.contains("-n")
        let asJSON = rest.contains("--json")
        let asMarkdown = rest.contains("--markdown") || rest.contains("--md")

        let report = ShaderCacheVerifier.verify()
        if doQuarantine {
            do {
                let quarantine = try ShaderCacheVerifier.quarantineCorruptFiles(
                    report: report,
                    dryRun: dryRun
                )
                if asJSON {
                    struct CacheVerifyQuarantinePayload: Codable {
                        let verification: ShaderCacheVerificationReport
                        let quarantine: ShaderCacheQuarantineResult
                    }
                    let enc = JSONEncoder()
                    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let payload = CacheVerifyQuarantinePayload(verification: report, quarantine: quarantine)
                    if let data = try? enc.encode(payload), let str = String(data: data, encoding: .utf8) {
                        print(str)
                    }
                    return 0
                }
                print(asMarkdown ? ShaderCacheVerifier.formatMarkdown(report) : ShaderCacheVerifier.formatText(report))
                let verb = dryRun ? "Would quarantine" : "Quarantined"
                let qDir = LaunchDiagnostics.redactHome(quarantine.quarantineDirectory)
                print("\(verb) \(quarantine.movedCount) corrupt file(s) (\(quarantine.movedBytes) bytes) into \(qDir).")
                if !quarantine.skippedPaths.isEmpty {
                    print("Skipped \(quarantine.skippedPaths.count) path(s): \(quarantine.skippedPaths.joined(separator: ", "))")
                }
                return 0
            } catch {
                fputs("cache verify quarantine failed: \(error.localizedDescription)\n", stderr)
                return 1
            }
        }

        if asJSON {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(report), let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            return 0
        }
        print(asMarkdown ? ShaderCacheVerifier.formatMarkdown(report) : ShaderCacheVerifier.formatText(report))
        return 0

    case "prune":
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
        guard let outPath = rest.first, !outPath.isEmpty else {
            fputs("error: cache export requires <output.dmcache.tar.gz>\n", stderr)
            return 1
        }
        var filter: String? = nil
        var idx = 1
        while idx < rest.count {
            if rest[idx] == "--filter", idx + 1 < rest.count {
                filter = rest[idx + 1]
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
        guard let src = rest.first, !src.isEmpty else {
            fputs("error: cache import requires <archive_path_or_https_url>\n", stderr)
            return 1
        }
        let force = rest.dropFirst().contains("--force")
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
        guard let indexSrc = rest.first, !indexSrc.isEmpty else {
            fputs("error: cache sync requires <index_url_or_path> (--build-hash <hash> | --exe <path>) [--force]\n", stderr)
            return 1
        }
        var buildHash: String? = nil
        var exePath: String? = nil
        var force = false
        var idx = 1
        while idx < rest.count {
            if rest[idx] == "--build-hash", idx + 1 < rest.count {
                buildHash = rest[idx + 1]
                idx += 2
            } else if rest[idx] == "--exe", idx + 1 < rest.count {
                exePath = rest[idx + 1]
                idx += 2
            } else if rest[idx] == "--force" {
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
}

func runHistoryCLI(args: [String]) -> Int32 {
    let store = LaunchHistoryStore()
    if args.first == "stats" || args.first == "analytics" || args.contains("--stats") {
        let entries = store.load(limit: LaunchHistoryStore.maxEntries)
        let summary = GameSessionAnalytics.summarize(entries: entries)
        if args.contains("--json") {
            printLibraryJSON(summary)
        } else if args.contains("--markdown") || args.contains("--md") {
            print(GameSessionAnalytics.formatMarkdown(summary))
        } else {
            print(GameSessionAnalytics.formatText(summary))
        }
        return 0
    }
    if args.contains("--clear") {
        store.clear()
        print("Cleared launch history (\(store.historyURL.path)).")
        return 0
    }
    var limit = 25
    if let idx = args.firstIndex(of: "--limit"), idx + 1 < args.count, let n = Int(args[idx + 1]), n > 0 {
        limit = min(n, LaunchHistoryStore.maxEntries)
    }
    if args.contains("--markdown") {
        print(store.markdownReport(limit: limit))
        return 0
    }
    let entries = store.load(limit: limit)
    if args.contains("--json") {
        printLibraryJSON(entries)
        return 0
    }
    if entries.isEmpty {
        print("No launch history recorded yet (\(store.historyURL.path)).")
        return 0
    }
    print("DirectMetal Launch History (latest \(entries.count))")
    print("--------------------------------------------------------------------------------")
    for e in entries {
        let status = e.succeeded ? "[OK]  " : "[FAIL]"
        let code = e.exitCode.map { "exit=\($0)" } ?? "error"
        let sb = e.sandboxed ? " seatbelt" : ""
        print("\(status) \(e.timestampUtc)  \(e.title.padding(toLength: 26, withPad: " ", startingAt: 0))  \(e.durationLabel.padding(toLength: 9, withPad: " ", startingAt: 0))  \(code)  [\(e.activeEngine)\(sb)]")
        if let fail = e.failure, !fail.isEmpty {
            print("       -> \(fail)")
        }
    }
    return 0
}

func runDiagnoseLogCLI(args: [String]) -> Int32 {
    let asJSON = args.contains("--json")
    let asMarkdown = args.contains("--markdown")
    let positional = args.filter { !$0.hasPrefix("--") }
    guard let logPath = positional.first, !logPath.isEmpty else {
        fputs("error: diagnose-log requires <logfile_path> [--json|--markdown]\n", stderr)
        return 1
    }
    let expanded = (logPath as NSString).expandingTildeInPath
    do {
        let analysis = try LaunchLogAnalyzer.analyzeFile(at: expanded)
        if asJSON {
            printLibraryJSON(analysis)
        } else if asMarkdown {
            print(LaunchLogAnalyzer.formatMarkdown(analysis))
        } else {
            print(LaunchLogAnalyzer.formatText(analysis))
        }
        return analysis.highestSeverity == .error ? 2 : 0
    } catch {
        fputs("diagnose-log failed: \(error)\n", stderr)
        return 1
    }
}

func runSupportBundleCLI(args: [String]) -> Int32 {
    let asJSON = args.contains("--json")
    let positional = args.filter { !$0.hasPrefix("--") }
    let outPath: String
    if let explicit = positional.first, !explicit.isEmpty {
        outPath = (explicit as NSString).expandingTildeInPath
    } else {
        let desktop = (("~/Desktop" as NSString).expandingTildeInPath)
        outPath = "\(desktop)/DirectMetal-Support-Bundle.tar.gz"
    }
    do {
        let res = try SupportBundleExporter.exportBundle(to: outPath)
        if asJSON {
            printLibraryJSON(res)
        } else {
            let kib = String(format: "%.1f", Double(res.archiveBytes) / 1024.0)
            print("Exported redacted diagnostics bundle (\(kib) KiB, \(res.includedFiles.count) files) to \(res.archivePath)")
            print("  games=\(res.gameCount) history=\(res.historyEntryCount) prefixes=\(res.prefixCount) shader_caches=\(res.shaderCacheEntryCount)")
        }
        return 0
    } catch {
        fputs("support-bundle failed: \(error)\n", stderr)
        return 1
    }
}

func runHUDCLI(args: [String]) -> Int32 {
    let sub = args.first ?? "show"
    let tail = Array(args.dropFirst())
    let asJSON = args.contains("--json")
    switch sub {
    case "show", "status", "--json":
        let cfg = MetalHUDConfigManager.load()
        if asJSON || sub == "--json" {
            struct HUDStatusJSON: Encodable {
                let config: MetalHUDConfiguration
                let environment: [String: String]
            }
            printLibraryJSON(HUDStatusJSON(config: cfg, environment: cfg.environmentVariables(hudEnabled: true)))
        } else {
            print("Metal Performance HUD Configuration")
            print("  preset:    \(cfg.preset.rawValue) (\(cfg.preset.displayName))")
            print("  alignment: \(cfg.alignment.rawValue) (\(cfg.alignment.displayName))")
            print(String(format: "  scale:     %.2fx", cfg.scale))
            print(String(format: "  opacity:   %.0f%%", cfg.opacity * 100))
            print("  dxvk_hud:  \(cfg.showDXVKHudOnDX9)")
        }
        return 0
    case "set":
        let pairs = tail.filter { !$0.hasPrefix("--") }
        guard !pairs.isEmpty else {
            fputs("error: hud set requires <key>=<value> (preset|alignment|scale|opacity|dxvk-hud)\n", stderr)
            return 1
        }
        var cfg = MetalHUDConfigManager.load()
        for pair in pairs {
            guard let eq = pair.firstIndex(of: "=") else {
                fputs("error: expected <key>=<value>, got \"\(pair)\"\n", stderr)
                return 1
            }
            let k = pair[..<eq].lowercased()
            let v = String(pair[pair.index(after: eq)...])
            var ok = true
            switch k {
            case "preset":
                if let p = MetalHUDPreset.parse(v) { cfg.preset = p } else { ok = false }
            case "alignment", "corner", "position":
                if let a = MetalHUDAlignment.parse(v) { cfg.alignment = a } else { ok = false }
            case "scale":
                if let d = Double(v) { cfg.scale = d } else { ok = false }
            case "opacity":
                if let d = Double(v) { cfg.opacity = d > 1.0 ? d / 100.0 : d } else { ok = false }
            case "dxvk-hud", "dxvk":
                if let b = parseBool(v) { cfg.showDXVKHudOnDX9 = b } else { ok = false }
            default:
                fputs("error: unknown hud setting \"\(k)\"\n", stderr)
                return 1
            }
            if !ok {
                fputs("error: invalid value \"\(v)\" for \(k)\n", stderr)
                return 1
            }
        }
        cfg = cfg.normalized()
        do {
            try MetalHUDConfigManager.save(cfg)
            printLibraryJSON(cfg)
            return 0
        } catch {
            fputs("hud set failed: \(error)\n", stderr)
            return 1
        }
    case "reset":
        do {
            try MetalHUDConfigManager.reset()
            print("Reset Metal Performance HUD configuration to defaults.")
            return 0
        } catch {
            fputs("hud reset failed: \(error)\n", stderr)
            return 1
        }
    default:
        fputs("unknown hud subcommand: \(sub) (expected: show|set|reset)\n", stderr)
        return 1
    }
}

func runStorageCLI(args: [String]) -> Int32 {
    let asJSON = args.contains("--json")
    let asMarkdown = args.contains("--markdown") || args.contains("--md")
    let report = StorageFootprintAnalyzer.analyze()
    if asJSON {
        printLibraryJSON(report)
    } else if asMarkdown {
        print(StorageFootprintAnalyzer.formatMarkdown(report))
    } else {
        print(StorageFootprintAnalyzer.formatText(report))
    }
    return 0
}
