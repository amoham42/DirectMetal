import Foundation

private func printUsage() {
    print("""
    DirectMetal — Apple Silicon DirectX 10/11/12 Runtime

    Usage:
      DirectMetal                        Launch desktop GUI
      DirectMetal info                   Show Apple Silicon GPU, Metal 4, and runtime info
      DirectMetal inspect <exe>          Inspect PE headers, architecture, and DirectX/upscaler APIs
      DirectMetal prefix list            List APFS CoW game prefixes
      DirectMetal prefix create <name>   Create an APFS CoW prefix immediately
      DirectMetal prefix reset <name>    Reset an existing APFS CoW prefix
      DirectMetal prefix delete <name>   Delete an APFS CoW prefix
      DirectMetal run <exe> [--prefix <name>] [--hud] [--reset-prefix] [-- <args...>]
    """)
}

private func runCLI(args: [String]) -> Int32 {
    guard let cmd = args.first else { return 1 }

    switch cmd {
    case "help", "--help", "-h":
        printUsage()
        return 0

    case "info":
        let hw = RuntimeLauncher.queryHardwareInfo()
        let runtimeStatus: String
        if let rp = try? RuntimeLauncher.resolveRuntimePaths() {
            runtimeStatus = "ready (\(rp.runtimeRoot.path))"
        } else {
            runtimeStatus = "uninitialized"
        }
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
            "runtime": runtimeStatus,
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
                let hw = RuntimeLauncher.queryHardwareInfo()
                let res = try mgr.createOrEnsure(
                    name: args[2],
                    basePrefix: paths.basePrefix,
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
            } else if a == "--hud" {
                enableHUD = true
                i += 1
            } else if a == "--reset-prefix" {
                resetPrefix = true
                i += 1
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
                resetPrefix: resetPrefix
            )
            let elapsedStr = String(format: "%.3f", res.elapsedSeconds)
            let cloneStr = String(format: "%.2f", res.cloneMs)
            fputs("[DirectMetal] exit=\(res.exitCode) elapsed=\(elapsedStr)s prefix=\(res.prefixPath) (clone_ms=\(cloneStr)) cache=\(res.shaderCacheDir)\n", stderr)
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
