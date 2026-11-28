import Foundation

// Per-Game Pre-Flight Readiness Checker (pure Foundation engine & formatters).
// Fast, read-only evaluator that verifies executable integrity, resolved Wine/FEX runtime,
// kernel anti-cheat presence, prefix volume headroom, APFS prefix & warm wineserver state,
// graphics pipeline / MetalFX compatibility, and custom environment sanitization without
// spawning any process or mutating disk.

// MARK: - Data model

enum PreflightStatus: String, Codable, Comparable, CaseIterable, Hashable, Sendable {
    case pass
    case warn
    case fail

    private var severityRank: Int {
        switch self {
        case .pass: return 0
        case .warn: return 1
        case .fail: return 2
        }
    }

    static func < (lhs: PreflightStatus, rhs: PreflightStatus) -> Bool {
        lhs.severityRank < rhs.severityRank
    }

    var displayLabel: String {
        switch self {
        case .pass: return "PASS"
        case .warn: return "WARN"
        case .fail: return "FAIL"
        }
    }
}

struct PreflightCheckItem: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let status: PreflightStatus
    let summary: String
    let remediation: String?
}

struct PreflightReport: Codable, Equatable, Sendable {
    let gameID: String
    let title: String
    let overallStatus: PreflightStatus
    let canLaunch: Bool
    let passCount: Int
    let warnCount: Int
    let failCount: Int
    let checks: [PreflightCheckItem]
}

// MARK: - Pure pre-flight checker & formatters

enum PreflightChecker {
    private static let oneGiB: UInt64 = 1_073_741_824
    private static let fiveGiB: UInt64 = 5 * 1_073_741_824

    private static let antiCheatSubfolders: Set<String> = [
        "easyanticheat",
        "easyanticheat_eos",
        "battleye",
        "anticheat",
    ]

    private static let antiCheatSignatures: [String] = [
        "easyanticheat",
        "beservice",
        "bedaisy",
        "vgk.sys",
        "vgc.exe",
        "gamemon.des",
        "randgrid.sys",
    ]

    /// Runs 7 fast, side-effect-free readiness checks for `entry` without spawning any process
    /// or writing to disk.
    static func check(
        entry: GameLibraryEntry,
        hardware: MetalHardwareInfo = RuntimeLauncher.queryHardwareInfo(),
        prefixManager: PrefixManager = PrefixManager(),
        freeDiskBytesOverride: UInt64? = nil
    ) -> PreflightReport {
        let plan = LaunchPlanInspector.inspect(
            entry: entry,
            hardware: hardware,
            prefixManager: prefixManager
        )

        let checks: [PreflightCheckItem] = [
            checkExecutable(entry: entry, plan: plan),
            checkRuntime(entry: entry, plan: plan),
            checkAntiCheat(entry: entry),
            checkDiskSpace(prefixRoot: prefixManager.prefixRoot, freeDiskBytesOverride: freeDiskBytesOverride),
            checkPrefix(plan: plan),
            checkGraphicsPipeline(entry: entry, plan: plan, hardware: hardware),
            checkCustomEnv(plan: plan),
        ]

        let passCount = checks.filter { $0.status == .pass }.count
        let warnCount = checks.filter { $0.status == .warn }.count
        let failCount = checks.filter { $0.status == .fail }.count
        let overallStatus = checks.map(\.status).max() ?? .pass

        return PreflightReport(
            gameID: entry.id,
            title: entry.title,
            overallStatus: overallStatus,
            canLaunch: overallStatus != .fail,
            passCount: passCount,
            warnCount: warnCount,
            failCount: failCount,
            checks: checks
        )
    }

    // MARK: Text formatter (CLI)

    static func formatText(_ report: PreflightReport, home: String = NSHomeDirectory()) -> String {
        let redact: (String) -> String = { LaunchDiagnostics.redactHome($0, home: home) }
        var lines: [String] = [
            "DirectMetal Pre-Flight Readiness — \(redact(report.title))",
            "  Game ID:  \(redact(report.gameID))",
            "  Overall:  \(report.overallStatus.displayLabel) (\(report.canLaunch ? "ready to launch" : "launch blocked"))",
            "  Checks:   \(report.passCount) pass, \(report.warnCount) warn, \(report.failCount) fail (\(report.checks.count) total)",
            "",
        ]

        for item in report.checks {
            lines.append("  [\(item.status.displayLabel)] \(redact(item.title)) (\(item.id))")
            lines.append("         \(redact(item.summary))")
            if let remediation = item.remediation, !remediation.isEmpty {
                lines.append("         Fix: \(redact(remediation))")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Markdown formatter (GitHub-issue-ready)

    static func formatMarkdown(_ report: PreflightReport, home: String = NSHomeDirectory()) -> String {
        let redact: (String) -> String = { LaunchDiagnostics.redactHome($0, home: home) }
        func cell(_ raw: String) -> String {
            redact(raw)
                .replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
        }

        var lines: [String] = [
            "### DirectMetal Pre-Flight Readiness — \(redact(report.title))",
            "",
            "- **Game ID:** `\(cell(report.gameID))`",
            "- **Overall:** `\(report.overallStatus.displayLabel)` (\(report.canLaunch ? "Ready to launch" : "**Launch blocked**"))",
            "- **Summary:** \(report.passCount) pass, \(report.warnCount) warn, \(report.failCount) fail",
            "",
            "| Status | Check | Details |",
            "| :--- | :--- | :--- |",
        ]

        for item in report.checks {
            var details = cell(item.summary)
            if let remediation = item.remediation, !remediation.isEmpty {
                details += "<br>_Fix: \(cell(remediation))_"
            }
            lines.append("| `\(item.status.displayLabel)` | **\(cell(item.title))** (`\(cell(item.id))`) | \(details) |")
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: Individual checks

    private static func checkExecutable(entry: GameLibraryEntry, plan: GameLaunchPlan) -> PreflightCheckItem {
        let id = "executable"
        let title = "Executable"
        let trimmed = entry.exePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return PreflightCheckItem(
                id: id,
                title: title,
                status: .fail,
                summary: "Executable path is empty.",
                remediation: "Set a valid Windows .exe path for this game in the library."
            )
        }

        let fm = FileManager.default
        let exeURL = URL(fileURLWithPath: trimmed)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: exeURL.path, isDirectory: &isDir) else {
            return PreflightCheckItem(
                id: id,
                title: title,
                status: .fail,
                summary: "Executable not found at \(exeURL.path) — file may have moved or its external drive is unmounted.",
                remediation: "Verify the file exists, reconnect any external drive, or update the game's executable path."
            )
        }

        if isDir.boolValue {
            return PreflightCheckItem(
                id: id,
                title: title,
                status: .fail,
                summary: "Executable path points to a directory instead of a file: \(exeURL.path).",
                remediation: "Select the game's Windows .exe file inside that directory."
            )
        }

        let resolvedURL = exeURL.resolvingSymlinksInPath()
        let resourceValues = try? resolvedURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        if resourceValues?.isRegularFile == false {
            return PreflightCheckItem(
                id: id,
                title: title,
                status: .fail,
                summary: "Executable path is not a regular file: \(exeURL.path).",
                remediation: "Point the library entry to a standard Windows .exe file."
            )
        }

        guard fm.isReadableFile(atPath: exeURL.path) else {
            return PreflightCheckItem(
                id: id,
                title: title,
                status: .fail,
                summary: "Executable is not readable at \(exeURL.path).",
                remediation: "Grant read permissions to the file or allow DirectMetal folder access in System Settings > Privacy & Security."
            )
        }

        let sizeSuffix: String
        if let fileSize = resourceValues?.fileSize, fileSize >= 0 {
            sizeSuffix = ", \(formatBytes(UInt64(fileSize)))"
        } else {
            sizeSuffix = ""
        }

        return PreflightCheckItem(
            id: id,
            title: title,
            status: .pass,
            summary: "Executable found and readable (\(plan.architecture)\(sizeSuffix)) at \(exeURL.path).",
            remediation: nil
        )
    }

    private static func checkRuntime(entry: GameLibraryEntry, plan: GameLaunchPlan) -> PreflightCheckItem {
        let id = "runtime"
        let title = "Runtime Engine"

        if plan.resolvedEngine == "unavailable" {
            let remediation: String
            if entry.engine == .rosetta {
                remediation = "Switch Engine to Auto or ARM64EC, or re-package DirectMetal with --include-rosetta."
            } else {
                remediation = "Install the DirectMetal Wine+Mullion runtime via `DirectMetal runtime install`."
            }
            return PreflightCheckItem(
                id: id,
                title: title,
                status: .fail,
                summary: "No compatible runtime resolved (requested: \(plan.requestedEngine)) — \(plan.engineReason).",
                remediation: remediation
            )
        }

        if let caveat = plan.warnings.first(where: { $0.localizedCaseInsensitiveContains("32-bit") }) {
            let remediation: String
            if plan.resolvedEngine == "rosetta2" {
                remediation = "Upgrade to macOS 26.4+ with cross-arch provisioning to run 32-bit games natively under ARM64EC+FEX."
            } else {
                remediation = "Install the legacy Rosetta 2 runtime (--include-rosetta) or run on macOS 26.4+ with cross-arch provisioning for 32-bit support."
            }
            return PreflightCheckItem(
                id: id,
                title: title,
                status: .warn,
                summary: "Resolved \(plan.resolvedEngine) with 32-bit caveat — \(caveat)",
                remediation: remediation
            )
        }

        return PreflightCheckItem(
            id: id,
            title: title,
            status: .pass,
            summary: "Resolved \(plan.resolvedEngine) (requested: \(plan.requestedEngine)) — \(plan.engineReason).",
            remediation: nil
        )
    }

    private static func checkAntiCheat(entry: GameLibraryEntry) -> PreflightCheckItem {
        let id = "anti_cheat"
        let title = "Anti-Cheat Compatibility"
        let trimmed = entry.exePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return PreflightCheckItem(
                id: id,
                title: title,
                status: .pass,
                summary: "No game folder available to inspect for kernel anti-cheat signatures.",
                remediation: nil
            )
        }

        let fm = FileManager.default
        let gameDir = URL(fileURLWithPath: trimmed).deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: gameDir.path, isDirectory: &isDir), isDir.boolValue else {
            return PreflightCheckItem(
                id: id,
                title: title,
                status: .pass,
                summary: "Game folder unavailable; skipped kernel anti-cheat signature check.",
                remediation: nil
            )
        }

        let detected = scanAntiCheatSignatures(in: gameDir)
        if detected.isEmpty {
            return PreflightCheckItem(
                id: id,
                title: title,
                status: .pass,
                summary: "No known kernel-mode anti-cheat signatures detected in the game folder.",
                remediation: nil
            )
        }

        return PreflightCheckItem(
            id: id,
            title: title,
            status: .warn,
            summary: "Detected kernel anti-cheat signature(s): \(detected.joined(separator: ", ")). Kernel-mode anti-cheat typically blocks online multiplayer on macOS, while single-player or offline launches may still work.",
            remediation: "Try launching in offline or single-player mode if supported by the game."
        )
    }

    private static func checkDiskSpace(
        prefixRoot: URL,
        freeDiskBytesOverride: UInt64?
    ) -> PreflightCheckItem {
        let id = "disk_space"
        let title = "Available Disk Space"

        guard let freeBytes = freeDiskBytesOverride ?? availableVolumeBytes(for: prefixRoot) else {
            return PreflightCheckItem(
                id: id,
                title: title,
                status: .warn,
                summary: "Unable to query available disk space for prefix root \(prefixRoot.path).",
                remediation: "Verify the volume hosting \(prefixRoot.path) is mounted and has at least 5 GiB free."
            )
        }

        let formatted = formatBytes(freeBytes)
        if freeBytes < oneGiB {
            return PreflightCheckItem(
                id: id,
                title: title,
                status: .fail,
                summary: "Only \(formatted) available on prefix volume (< 1 GiB minimum required for prefix and shader cache writes).",
                remediation: "Free at least 5 GiB on the volume hosting \(prefixRoot.path), or prune unused prefixes and shader caches."
            )
        }

        if freeBytes < fiveGiB {
            return PreflightCheckItem(
                id: id,
                title: title,
                status: .warn,
                summary: "\(formatted) available on prefix volume (< 5 GiB recommended; shader compilation and prefix writes need headroom).",
                remediation: "Free additional space on the volume hosting \(prefixRoot.path) to avoid shader cache or save-write stalls."
            )
        }

        return PreflightCheckItem(
            id: id,
            title: title,
            status: .pass,
            summary: "\(formatted) available on prefix volume (\(prefixRoot.path)).",
            remediation: nil
        )
    }

    private static func checkPrefix(plan: GameLaunchPlan) -> PreflightCheckItem {
        let id = "prefix"
        let title = "APFS Wine Prefix"

        if plan.prefixExists {
            let serverState = plan.wineserverWarm
                ? "warm wineserver active (fast repeat launch)"
                : "wineserver cold (starts on launch)"
            return PreflightCheckItem(
                id: id,
                title: title,
                status: .pass,
                summary: "Prefix '\(plan.prefixName)' exists at \(plan.prefixPath) — \(serverState).",
                remediation: nil
            )
        }

        return PreflightCheckItem(
            id: id,
            title: title,
            status: .pass,
            summary: "Prefix '\(plan.prefixName)' not yet created at \(plan.prefixPath) — APFS CoW will clone it in < 1 ms on first launch (wineserver cold).",
            remediation: nil
        )
    }

    private static func checkGraphicsPipeline(
        entry: GameLibraryEntry,
        plan: GameLaunchPlan,
        hardware: MetalHardwareInfo
    ) -> PreflightCheckItem {
        let id = "graphics_pipeline"
        let title = "Graphics Pipeline & Upscaling"

        let metalTier = hardware.supportsMetal4
            ? "Metal 4"
            : (hardware.supportsMetal3 ? "Metal 3" : "pre-Metal 3")
        let apisText = plan.detectedAPIs.isEmpty
            ? "Win32 / auto-detect"
            : plan.detectedAPIs.joined(separator: ", ")

        var caveats: [String] = []
        var remediations: [String] = []

        if !hardware.supportsMetal3 {
            caveats.append("GPU (\(hardware.gpuName)) does not report Metal 3 support (Mullion requires Apple Silicon with Metal 3+)")
            remediations.append("Run DirectMetal on an Apple Silicon Mac (M1 or newer) with Metal 3+ support.")
        }

        if let mode = entry.launchUpscaleMode {
            let hasDLSS = plan.detectedUpscalers.contains("DLSS")
            if hasDLSS {
                if !hardware.supportsMetalFXTemporal && !hardware.supportsMetal4FX {
                    caveats.append("MetalFX Temporal upscaling (\(mode) via DLSS bridge) requested, but \(hardware.gpuName) does not report MetalFX Temporal support")
                    remediations.append("Set Upscaling to Off on GPUs without MetalFX Temporal support.")
                }
            } else if !hardware.supportsMetalFXSpatial && !hardware.supportsMetal4FX {
                caveats.append("MetalFX Spatial upscaling (\(mode)) requested, but \(hardware.gpuName) does not report MetalFX Spatial support")
                remediations.append("Set Upscaling to Off on GPUs without MetalFX Spatial support.")
            }
        }

        if entry.enableHUD,
           let hudWarning = plan.warnings.first(where: { $0.contains("Metal Performance HUD") }) {
            caveats.append(hudWarning)
            remediations.append("Leave HUD enabled for automatic DXVK_HUD fallback, or switch DX9 backend to WineMetalGL (wined3d) for Metal HUD.")
        }

        if !caveats.isEmpty {
            return PreflightCheckItem(
                id: id,
                title: title,
                status: .warn,
                summary: "\(apisText) on \(hardware.gpuName) (\(metalTier)) — \(caveats.joined(separator: "; ")).",
                remediation: remediations.joined(separator: " ")
            )
        }

        let upscaleSummary = entry.launchUpscaleMode != nil
            ? plan.upscalingPlan
            : "Upscaling off (native resolution)"
        let hudNote = entry.enableHUD ? "Metal HUD on" : "Metal HUD off"

        return PreflightCheckItem(
            id: id,
            title: title,
            status: .pass,
            summary: "\(apisText) on \(hardware.gpuName) (\(metalTier)) — \(plan.graphicsPipelineSummary); \(upscaleSummary); \(hudNote).",
            remediation: nil
        )
    }

    private static func checkCustomEnv(plan: GameLaunchPlan) -> PreflightCheckItem {
        let id = "custom_env"
        let title = "Custom Environment"

        let blockedKeys = plan.blockedCustomEnvKeys
        let invalidWarnings = plan.warnings.filter {
            $0.localizedCaseInsensitiveContains("invalid custom environment")
        }

        if !blockedKeys.isEmpty || !invalidWarnings.isEmpty {
            var issues: [String] = []
            if !blockedKeys.isEmpty {
                issues.append("Blocked security env key(s) stripped: \(blockedKeys.joined(separator: ", "))")
            }
            for warning in invalidWarnings {
                let cleaned = warning.hasSuffix(".") ? String(warning.dropLast()) : warning
                issues.append(cleaned)
            }
            let keptSuffix = plan.sanitizedCustomEnv.isEmpty
                ? ""
                : " (\(plan.sanitizedCustomEnv.count) valid override\(plan.sanitizedCustomEnv.count == 1 ? "" : "s") kept)"
            return PreflightCheckItem(
                id: id,
                title: title,
                status: .warn,
                summary: "\(issues.joined(separator: "; "))\(keptSuffix).",
                remediation: "Remove blocked host-isolation variables (WINEPREFIX, DYLD_*, LD_PRELOAD) and format overrides as KEY=VALUE."
            )
        }

        if plan.sanitizedCustomEnv.isEmpty {
            return PreflightCheckItem(
                id: id,
                title: title,
                status: .pass,
                summary: "No custom environment overrides configured.",
                remediation: nil
            )
        }

        let keys = plan.sanitizedCustomEnv.keys.sorted().joined(separator: ", ")
        return PreflightCheckItem(
            id: id,
            title: title,
            status: .pass,
            summary: "\(plan.sanitizedCustomEnv.count) custom environment override\(plan.sanitizedCustomEnv.count == 1 ? "" : "s") validated (\(keys)).",
            remediation: nil
        )
    }

    // MARK: Private helpers

    /// Non-recursive scan of the immediate game folder and one-level known anti-cheat subfolders.
    private static func scanAntiCheatSignatures(in gameDir: URL) -> [String] {
        let fm = FileManager.default
        guard let topItems = try? fm.contentsOfDirectory(
            at: gameDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return []
        }

        var detected: [String] = []
        var seen = Set<String>()

        func record(_ label: String) {
            if seen.insert(label).inserted {
                detected.append(label)
            }
        }

        for item in topItems.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = item.lastPathComponent
            let lower = name.lowercased()
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

            if isDir && antiCheatSubfolders.contains(lower) {
                var matchedInside = false
                if let children = try? fm.contentsOfDirectory(
                    at: item,
                    includingPropertiesForKeys: nil,
                    options: []
                ) {
                    for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                        if matchesAntiCheatSignature(child.lastPathComponent) {
                            record("\(name)/\(child.lastPathComponent)")
                            matchedInside = true
                        }
                    }
                }
                if !matchedInside && matchesAntiCheatSignature(name) {
                    record("\(name)/")
                }
            } else if matchesAntiCheatSignature(name) {
                record(isDir ? "\(name)/" : name)
            }
        }

        return detected
    }

    private static func matchesAntiCheatSignature(_ name: String) -> Bool {
        let lower = name.lowercased()
        return antiCheatSignatures.contains { lower.contains($0) }
    }

    private static func availableVolumeBytes(for url: URL) -> UInt64? {
        let fm = FileManager.default
        var probe = url.standardizedFileURL
        while !fm.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { break }
            probe = parent
        }

        if let values = try? probe.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]) {
            if let important = values.volumeAvailableCapacityForImportantUsage, important >= 0 {
                return UInt64(important)
            }
            if let available = values.volumeAvailableCapacity, available >= 0 {
                return UInt64(available)
            }
        }

        if let attrs = try? fm.attributesOfFileSystem(forPath: probe.path),
           let freeNum = attrs[.systemFreeSize] as? NSNumber {
            let value = freeNum.int64Value
            if value >= 0 { return UInt64(value) }
        }
        return nil
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / Double(oneGiB)
        if bytes >= oneGiB {
            return String(format: "%.2f GiB", gib)
        }
        let mib = Double(bytes) / 1_048_576.0
        if mib >= 1.0 {
            return String(format: "%.1f MiB", mib)
        }
        let kib = Double(bytes) / 1024.0
        if kib >= 1.0 {
            return String(format: "%.1f KiB", kib)
        }
        return "\(bytes) B"
    }
}
