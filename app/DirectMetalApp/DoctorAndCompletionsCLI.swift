import Foundation

// MARK: - Doctor CLI

struct DoctorCheck: Codable {
    let id: String
    let status: String   // "ok" | "warn" | "fail"
    let summary: String
    let remediation: String?
}

struct DoctorReport: Codable {
    let appVersion: String
    let overallStatus: String
    let passed: Int
    let warnings: Int
    let failures: Int
    let checks: [DoctorCheck]
}

func runDoctorCLI(args: [String]) -> Int32 {
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

// MARK: - Shell Completions CLI

func runCompletionsCLI(args: [String]) -> Int32 {
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
    'bench:Run built-in Apple Silicon UMA, APFS CoW, SHA-256 and PE benchmarks'
    'inspect:Inspect Windows PE headers, architecture and DirectX/upscaler APIs'
    'run:Launch a Windows DirectX executable via DirectMetal'
    'library:Manage saved games, auto-scanner, artwork and per-game settings'
    'history:View, export as Markdown/JSON, or clear recent game launch history'
    'diagnose-log:Analyze a Wine/DirectX/Metal log file for crashes, missing DLLs & fixes'
    'support-bundle:Export a privacy-redacted diagnostics .tar.gz bundle for bug reports'
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
      local -a sub=(list scan add remove show artwork set play explain shortcut export import)
      _values 'library subcommand' $sub
      ;;
    runtime)
      local -a sub=(status install update remove warm stop-servers)
      _values 'runtime subcommand' $sub
      ;;
    prefix)
      local -a sub=(list stats prune create reset delete export-saves import-saves)
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
      _values 'profiles subcommand' list match
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
        '--fps-cap[Frame-rate cap in FPS (0=uncapped)]:fps:(0 30 40 60 90 120 144)' \
        '*--env[Custom environment override KEY=VAL]:env:' \
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
    COMPREPLY=( $(compgen -W "info doctor bench inspect run library history diagnose-log support-bundle runtime prefix cache controller profiles update attest verify-attest completions help" -- "${cur}") )
    return 0
  fi

  case "${cmd}" in
    library)
      COMPREPLY=( $(compgen -W "list scan add remove show artwork set play explain shortcut export import" -- "${cur}") )
      ;;
    runtime)
      COMPREPLY=( $(compgen -W "status install update remove warm stop-servers" -- "${cur}") )
      ;;
    prefix)
      COMPREPLY=( $(compgen -W "list stats prune create reset delete export-saves import-saves" -- "${cur}") )
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
      COMPREPLY=( $(compgen -W "list match" -- "${cur}") )
      ;;
    completions)
      COMPREPLY=( $(compgen -W "zsh bash" -- "${cur}") )
      ;;
    run)
      COMPREPLY=( $(compgen -W "--prefix --engine --dx9-backend --perf-mode --upscale --fps-cap --env --retina --no-retina --desktop --fex-tso --sandbox --sandbox-offline --sandbox-out --hud --reset-prefix --warm-server --no-warm-server" -- "${cur}") )
      ;;
  esac
}

complete -F _directmetal_completions DirectMetal directmetal
"""#)
    }
    return 0
}
