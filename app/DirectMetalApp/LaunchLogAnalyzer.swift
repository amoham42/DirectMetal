import Foundation

// Wine / DirectX / Metal Launch Log Analyzer & Crash Triage Engine.
// Pure, single-pass scanner that classifies DirectMetal launch logs into deduplicated,
// severity-ranked findings with home-redacted sample lines and DirectMetal-specific remediations.

// MARK: - Severity & Category Models

enum LogFindingSeverity: String, Codable, Comparable, CaseIterable, Hashable, Sendable {
    case info
    case warning
    case error

    private var rank: Int {
        switch self {
        case .info: return 0
        case .warning: return 1
        case .error: return 2
        }
    }

    static func < (lhs: LogFindingSeverity, rhs: LogFindingSeverity) -> Bool {
        lhs.rank < rhs.rank
    }

    var displayLabel: String {
        switch self {
        case .info: return "INFO"
        case .warning: return "WARNING"
        case .error: return "ERROR"
        }
    }
}

enum LogFindingCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case antiCheat
    case missingDLL
    case sandboxDenied
    case gpuMemory
    case d3d12Alignment
    case shaderCompile
    case architecture
    case crash
    case general

    var displayName: String {
        switch self {
        case .antiCheat: return "Anti-Cheat"
        case .missingDLL: return "Missing DLL"
        case .sandboxDenied: return "Sandbox / Permissions"
        case .gpuMemory: return "GPU Memory / Device"
        case .d3d12Alignment: return "D3D12 Alignment"
        case .shaderCompile: return "Shader Compilation"
        case .architecture: return "CPU Architecture"
        case .crash: return "Crash / Exception"
        case .general: return "General"
        }
    }
}

// MARK: - Analysis Result Models

struct LaunchLogFinding: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let severity: LogFindingSeverity
    let category: LogFindingCategory
    let title: String
    let sampleLine: String
    let occurrences: Int
    let remediation: String
}

struct LaunchLogAnalysis: Codable, Equatable, Sendable {
    let totalLines: Int
    let errorLineCount: Int
    let warningLineCount: Int
    let highestSeverity: LogFindingSeverity
    let findings: [LaunchLogFinding]
    let summary: String
}

enum LaunchLogAnalyzerError: Error, LocalizedError, Equatable, Sendable {
    case fileNotFound(String)
    case pathIsDirectory(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Launch log not found at \(LaunchDiagnostics.redactHome(path))."
        case .pathIsDirectory(let path):
            return "Expected a log file, but path is a directory: \(LaunchDiagnostics.redactHome(path))."
        }
    }
}

// MARK: - Analyzer Engine

enum LaunchLogAnalyzer {
    private static let maxSampleLineLength = 240

    private struct FindingAccumulator {
        let id: String
        let severity: LogFindingSeverity
        let category: LogFindingCategory
        let title: String
        let sampleLine: String
        var occurrences: Int
        let remediation: String
    }

    private struct MatchedRule {
        let id: String
        let severity: LogFindingSeverity
        let category: LogFindingCategory
        let title: String
        let remediation: String
    }

    // Pre-allocated static pattern tables (zero per-line heap allocation).
    private static let eacPatterns: [StaticString] = [
        "easy anti-cheat", "easyanticheat", "eac_launcher", "eac_server", "eos-eac",
    ]
    private static let battlEyePatterns: [StaticString] = [
        "battleye", "beclient", "bedaisy", "beservice",
    ]
    private static let vanguardPatterns: [StaticString] = [
        "riot vanguard", "vanguard anti-cheat", "vanguard not initialized", "vgk.sys", "vgc.exe",
    ]
    private static let ricochetPatterns: [StaticString] = [
        "ricochet", "randgrid.sys",
    ]
    private static let gameGuardPatterns: [StaticString] = [
        "gameguard", "nprotect", "npggnt", "gamemon.des",
    ]
    private static let otherAntiCheatPatterns: [StaticString] = [
        "xigncode", "mhyprot", "denuvo anti-cheat",
    ]
    private static let antiCheatContextPatterns: [StaticString] = [
        "fail", "error", "block", "denied", "unsupported", "driver", "incompatible",
    ]

    private static let dllFailurePatterns: [StaticString] = [
        "not found", "missing", "failed to load", "could not load",
        "cannot find", "unable to load", "err:module",
    ]
    private static let genericFailureContextPatterns: [StaticString] = [
        "not found", "missing", "err:", "error", "failed", "cannot", "could not", "unable",
    ]
    private static let vcRuntimeDLLPatterns: [StaticString] = [
        "vcruntime140", "msvcp140", "msvcr100", "msvcr110",
        "msvcr120", "msvcp120", "concrt140", "vcomp140",
    ]
    private static let d3dxDLLPatterns: [StaticString] = [
        "d3dx9", "d3dx10", "d3dx11", "d3dcompiler_43", "d3dcompiler_47",
    ]
    private static let xaudioDLLPatterns: [StaticString] = [
        "xaudio2", "x3daudio", "xapofx",
    ]
    private static let mfplatDLLPatterns: [StaticString] = [
        "mfplat", "mfreadwrite", "wmvcore",
    ]

    private static let seatbeltContextPatterns: [StaticString] = [
        "deny", "denied", "violation", "blocked",
    ]

    private static let gpuOOMPatterns: [StaticString] = [
        "vk_error_out_of_device_memory", "vk_error_out_of_host_memory",
        "out of video memory", "out of gpu memory", "out of vram",
        "insufficient video memory", "mtlcommandbuffererroroutofmemory",
    ]
    private static let gpuDeviceRemovedPatterns: [StaticString] = [
        "dxgi_error_device_removed", "dxgi_error_device_hung",
        "dxgi_error_device_reset", "vk_error_device_lost", "gpu hang",
    ]
    private static let gpuCommandBufferPatterns: [StaticString] = [
        "mtlcommandbuffererror", "mtlcommandbufferstatuserror",
        "command buffer execution failed", "caused gpu address fault",
        "kiogpucommandbuffercallbackerror",
    ]

    private static let d3d12AlignmentContextPatterns: [StaticString] = [
        "64kb", "64 kb", "65536", "d3d12", "placed", "mullion", "heap",
    ]
    private static let d3d12SizePatterns: [StaticString] = [
        "64kb", "64 kb",
    ]
    private static let d3d12ResourceContextPatterns: [StaticString] = [
        "d3d12", "placed", "heap", "mullion",
    ]

    private static let shaderFailureWords: [StaticString] = [
        "fail", "error", "err:", "invalid", "unsupported", "corrupt",
        "mismatch", "unable", "could not", "cannot", "warn",
    ]
    private static let shaderCompileDirectPatterns: [StaticString] = [
        "shader compilation failed", "failed to compile shader", "shader compile error",
    ]
    private static let airShaderContextPatterns: [StaticString] = [
        "shader", "metal", "llvm", "dxil", "dxbc", "bitcode",
        "compile", "convert", "pipeline", "library",
    ]

    private static let badCPUPatterns: [StaticString] = [
        "bad cpu type", "exec format error", "enoexec",
    ]
    private static let rosettaErrorPatterns: [StaticString] = [
        "not installed", "missing", "unavailable", "failed", "error",
        "required", "omitted", "crash", "abort",
    ]
    private static let wow64ErrorPatterns: [StaticString] = [
        "err:", "error", "fail", "unsupported", "cannot", "crash",
        "missing", "not supported", "not available", "unavailable",
    ]

    private static let unhandledExceptionPatterns: [StaticString] = [
        "unhandled exception", "wine: unhandled", "0xc0000005", "access violation",
    ]
    private static let crashSignalPatterns: [StaticString] = [
        "sigsegv", "sigbus", "sigabrt", "sigill",
        "segmentation fault", "bus error", "exc_bad_access",
    ]
    private static let fatalErrorPatterns: [StaticString] = [
        "fatal error!", "fatal error:", "lowlevelfatalerror",
    ]
    private static let assertionPatterns: [StaticString] = [
        "assertion failed", "assert failed",
    ]

    private static let diskFullPatterns: [StaticString] = [
        "no space left on device", "enospc",
    ]
    private static let wineserverErrorPatterns: [StaticString] = [
        "error", "fail", "could not", "mismatch", "not found",
    ]
    private static let wineStartupPatterns: [StaticString] = [
        "wine: cannot find", "wine: failed to start",
    ]
    private static let displayInitPatterns: [StaticString] = [
        "failed to create swapchain", "nodrv_createwindow", "could not initialize display",
    ]

    /// Scans `logText` in a single pass, deduplicating recurring issues by deterministic finding ID,
    /// redacting `home` paths in sample lines, and ranking findings by severity, occurrences, and title.
    static func analyze(_ logText: String, home: String = NSHomeDirectory()) -> LaunchLogAnalysis {
        guard !logText.isEmpty else {
            return LaunchLogAnalysis(
                totalLines: 0,
                errorLineCount: 0,
                warningLineCount: 0,
                highestSeverity: .info,
                findings: [],
                summary: "Log is empty (0 lines)."
            )
        }

        var totalLines = 0
        var errorLineCount = 0
        var warningLineCount = 0
        var accumulators: [String: FindingAccumulator] = [:]
        accumulators.reserveCapacity(16)

        var firstUnmatchedErrorSample: String?
        var firstUnmatchedWarningSample: String?

        // Reusable ASCII-lowercased byte buffer to avoid per-line heap allocations on large logs.
        var lowerBuf: [UInt8] = []
        lowerBuf.reserveCapacity(512)

        let utf8 = logText.utf8
        var lineStart = utf8.startIndex
        let endIndex = utf8.endIndex

        while lineStart < endIndex {
            var lineEnd = lineStart
            while lineEnd < endIndex && utf8[lineEnd] != 0x0A {
                lineEnd = utf8.index(after: lineEnd)
            }

            let nextStart = lineEnd < endIndex ? utf8.index(after: lineEnd) : endIndex

            // Trim trailing CR (\r) for Windows CRLF logs.
            var contentEnd = lineEnd
            if contentEnd > lineStart {
                let prev = utf8.index(before: contentEnd)
                if utf8[prev] == 0x0D {
                    contentEnd = prev
                }
            }

            totalLines += 1

            // Build trimmed ASCII-lowercased byte slice for this line.
            lowerBuf.removeAll(keepingCapacity: true)
            var trimStart = lineStart
            while trimStart < contentEnd && isASCIIWhitespace(utf8[trimStart]) {
                trimStart = utf8.index(after: trimStart)
            }
            var trimEnd = contentEnd
            while trimEnd > trimStart {
                let prev = utf8.index(before: trimEnd)
                if isASCIIWhitespace(utf8[prev]) {
                    trimEnd = prev
                } else {
                    break
                }
            }

            if trimStart < trimEnd {
                var idx = trimStart
                while idx < trimEnd {
                    let b = utf8[idx]
                    lowerBuf.append((b >= 0x41 && b <= 0x5A) ? (b + 32) : b)
                    idx = utf8.index(after: idx)
                }

                var matchedAny = false
                var lineHighestSeverity: LogFindingSeverity?

                // Evaluate each specialized category (at most one match per category per line
                // to avoid noisy double-counting of overlapping patterns).
                func record(_ match: MatchedRule) {
                    matchedAny = true
                    if let current = lineHighestSeverity {
                        if match.severity > current {
                            lineHighestSeverity = match.severity
                        }
                    } else {
                        lineHighestSeverity = match.severity
                    }

                    if var existing = accumulators[match.id] {
                        existing.occurrences += 1
                        accumulators[match.id] = existing
                    } else {
                        let sample = formatSampleLine(
                            rawSlice: logText[trimStart..<trimEnd],
                            home: home
                        )
                        accumulators[match.id] = FindingAccumulator(
                            id: match.id,
                            severity: match.severity,
                            category: match.category,
                            title: match.title,
                            sampleLine: sample,
                            occurrences: 1,
                            remediation: match.remediation
                        )
                    }
                }

                lowerBuf.withUnsafeBufferPointer { bytes in
                    if let m = matchAntiCheat(bytes) { record(m) }
                    if let m = matchMissingDLL(bytes) { record(m) }
                    if let m = matchSandboxDenied(bytes) { record(m) }
                    if let m = matchGPUMemory(bytes) { record(m) }
                    if let m = matchD3D12Alignment(bytes) { record(m) }
                    if let m = matchShaderCompile(bytes) { record(m) }
                    if let m = matchArchitecture(bytes) { record(m) }
                    if let m = matchCrash(bytes) { record(m) }
                    if let m = matchGeneral(bytes) { record(m) }

                    let isErrorLine = (lineHighestSeverity == .error) || hasGenericErrorMarker(bytes)
                    if isErrorLine {
                        errorLineCount += 1
                        if !matchedAny && firstUnmatchedErrorSample == nil {
                            firstUnmatchedErrorSample = formatSampleLine(
                                rawSlice: logText[trimStart..<trimEnd],
                                home: home
                            )
                        }
                    } else if (lineHighestSeverity == .warning) || hasGenericWarningMarker(bytes) {
                        warningLineCount += 1
                        if !matchedAny && firstUnmatchedWarningSample == nil {
                            firstUnmatchedWarningSample = formatSampleLine(
                                rawSlice: logText[trimStart..<trimEnd],
                                home: home
                            )
                        }
                    }
                }
            }

            lineStart = nextStart
        }

        // If no specialized rule matched but generic error/warning lines appeared, emit a general finding.
        if accumulators.isEmpty {
            if errorLineCount > 0, let sample = firstUnmatchedErrorSample {
                accumulators["general-unclassified-errors"] = FindingAccumulator(
                    id: "general-unclassified-errors",
                    severity: .error,
                    category: .general,
                    title: "Unclassified Runtime Errors",
                    sampleLine: sample,
                    occurrences: errorLineCount,
                    remediation: "Review the error lines in the full log, run `DirectMetal doctor` to verify runtime health, and test with `--perf-mode balanced` or `--fex-tso on`."
                )
            } else if warningLineCount > 0, let sample = firstUnmatchedWarningSample {
                accumulators["general-unclassified-warnings"] = FindingAccumulator(
                    id: "general-unclassified-warnings",
                    severity: .warning,
                    category: .general,
                    title: "Unclassified Runtime Warnings",
                    sampleLine: sample,
                    occurrences: warningLineCount,
                    remediation: "Warnings alone may be benign in Wine/DirectX logs; if gameplay issues occur, check `DirectMetal doctor` and test `--perf-mode balanced`."
                )
            }
        }

        var findings = accumulators.values.map { acc in
            LaunchLogFinding(
                id: acc.id,
                severity: acc.severity,
                category: acc.category,
                title: acc.title,
                sampleLine: acc.sampleLine,
                occurrences: acc.occurrences,
                remediation: acc.remediation
            )
        }

        findings.sort { lhs, rhs in
            if lhs.severity != rhs.severity {
                return lhs.severity > rhs.severity
            }
            if lhs.occurrences != rhs.occurrences {
                return lhs.occurrences > rhs.occurrences
            }
            if lhs.title != rhs.title {
                return lhs.title < rhs.title
            }
            return lhs.id < rhs.id
        }

        let highestSeverity = findings.first?.severity ?? .info
        let summary = buildSummary(
            totalLines: totalLines,
            errorLineCount: errorLineCount,
            warningLineCount: warningLineCount,
            highestSeverity: highestSeverity,
            findings: findings
        )

        return LaunchLogAnalysis(
            totalLines: totalLines,
            errorLineCount: errorLineCount,
            warningLineCount: warningLineCount,
            highestSeverity: highestSeverity,
            findings: findings,
            summary: summary
        )
    }

    /// Reads and analyzes a log file on disk, safely reading only the tail up to `maxBytes`
    /// so multi-gigabyte game logs never exhaust memory.
    static func analyzeFile(at path: String, maxBytes: Int = 4 * 1024 * 1024) throws -> LaunchLogAnalysis {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            throw LaunchLogAnalyzerError.fileNotFound(path)
        }
        if isDir.boolValue {
            throw LaunchLogAnalyzerError.pathIsDirectory(path)
        }

        guard maxBytes > 0 else {
            return analyze("")
        }

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        guard fileSize > 0 else {
            return analyze("")
        }

        let limit = UInt64(maxBytes)
        let truncated = fileSize > limit
        let startOffset: UInt64 = truncated ? (fileSize - limit) : 0
        try handle.seek(toOffset: startOffset)

        let bytesToRead = Int(min(fileSize, limit))
        let data = try handle.read(upToCount: bytesToRead) ?? Data()
        guard !data.isEmpty else {
            return analyze("")
        }

        // When reading the tail of a larger file, skip the partial leading line (and any split UTF-8
        // sequence) if a newline exists before the end of the buffer.
        let slice: Data
        if truncated, let firstNewline = data.firstIndex(of: 0x0A), firstNewline + 1 < data.endIndex {
            slice = data[(firstNewline + 1)...]
        } else {
            slice = data
        }

        // Lossy UTF-8 decoding handles occasional Windows-1252 or garbled Wine output cleanly.
        let text = String(decoding: slice, as: UTF8.self)
        return analyze(text)
    }

    // MARK: - Formatters

    static func formatText(_ analysis: LaunchLogAnalysis) -> String {
        var sections: [String] = []
        sections.append("DirectMetal Launch Log Analysis")

        let metaRows: [(String, String)] = [
            ("Highest Severity", analysis.highestSeverity.displayLabel),
            ("Lines Scanned", "\(analysis.totalLines)"),
            ("Error Lines", "\(analysis.errorLineCount)"),
            ("Warning Lines", "\(analysis.warningLineCount)"),
            ("Findings", "\(analysis.findings.count)"),
            ("Summary", analysis.summary),
        ]
        let labelWidth = max((metaRows.map { $0.0.count }.max() ?? 0) + 2, 18)
        var overviewLines = ["[Overview]"]
        for (label, value) in metaRows {
            let padded = (label + ":").padding(toLength: labelWidth, withPad: " ", startingAt: 0)
            overviewLines.append("  \(padded)\(value)")
        }
        sections.append(overviewLines.joined(separator: "\n"))

        if analysis.findings.isEmpty {
            sections.append("[Findings]\n  No actionable issues detected.")
        } else {
            var findingLines = ["[Findings (\(analysis.findings.count))]"]
            for (index, finding) in analysis.findings.enumerated() {
                let countLabel = finding.occurrences == 1 ? "1 occurrence" : "\(finding.occurrences) occurrences"
                findingLines.append(
                    "  \(index + 1). [\(finding.severity.displayLabel)] [\(finding.category.rawValue)] \(finding.title) (\(countLabel))"
                )
                findingLines.append("     ID:     \(finding.id)")
                findingLines.append("     Sample: \(finding.sampleLine)")
                findingLines.append("     Fix:    \(finding.remediation)")
            }
            sections.append(findingLines.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n") + "\n"
    }

    static func formatMarkdown(_ analysis: LaunchLogAnalysis) -> String {
        func severityIcon(_ severity: LogFindingSeverity) -> String {
            switch severity {
            case .error: return "🔴"
            case .warning: return "🟡"
            case .info: return "🔵"
            }
        }

        var lines: [String] = [
            "### DirectMetal Launch Log Analysis",
            "",
            "| Metric | Value |",
            "| :--- | :--- |",
            "| **Highest Severity** | \(severityIcon(analysis.highestSeverity)) `\(analysis.highestSeverity.rawValue)` |",
            "| **Lines Scanned** | \(analysis.totalLines) |",
            "| **Error Lines** | \(analysis.errorLineCount) |",
            "| **Warning Lines** | \(analysis.warningLineCount) |",
            "| **Findings** | \(analysis.findings.count) |",
            "",
            "> \(analysis.summary)",
        ]

        if !analysis.findings.isEmpty {
            lines.append("")
            lines.append("#### Findings")
            for (index, finding) in analysis.findings.enumerated() {
                let countText = finding.occurrences == 1 ? "1 occurrence" : "\(finding.occurrences) occurrences"
                lines.append("")
                lines.append(
                    "##### \(index + 1). \(severityIcon(finding.severity)) \(finding.title) (`\(finding.category.rawValue)` · `\(finding.severity.rawValue)` · \(countText))"
                )
                lines.append("")
                lines.append("- **ID:** `\(finding.id)`")
                lines.append("- **Sample:** \(markdownInlineCode(finding.sampleLine))")
                lines.append("- **Remediation:** \(finding.remediation)")
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: - Category Matchers (ASCII-lowercased UTF-8 byte slices)

    private static func matchAntiCheat(_ line: UnsafeBufferPointer<UInt8>) -> MatchedRule? {
        if containsAny(line, eacPatterns) {
            return MatchedRule(
                id: "anticheat-eac",
                severity: .error,
                category: .antiCheat,
                title: "Easy Anti-Cheat (EAC) Blocked or Failed",
                remediation: "Kernel-mode Easy Anti-Cheat is unsupported under macOS Wine/ARM64EC. Check whether the game offers an offline or single-player launch mode (for example launching the game binary directly instead of the EAC bootstrapper) or a non-EAC build."
            )
        }

        if containsAny(line, battlEyePatterns) {
            return MatchedRule(
                id: "anticheat-battleye",
                severity: .error,
                category: .antiCheat,
                title: "BattlEye Anti-Cheat Blocked or Failed",
                remediation: "BattlEye relies on the Windows kernel driver (BEDaisy.sys), which cannot load on macOS. Use an offline/single-player mode or non-BattlEye server option if the title supports it."
            )
        }

        if containsAny(line, vanguardPatterns) {
            return MatchedRule(
                id: "anticheat-vanguard",
                severity: .error,
                category: .antiCheat,
                title: "Riot Vanguard Anti-Cheat Incompatible",
                remediation: "Riot Vanguard requires a boot-time Windows kernel driver (vgk.sys) and cannot run under Wine or DirectMetal on macOS."
            )
        }

        if containsAny(line, ricochetPatterns) {
            return MatchedRule(
                id: "anticheat-ricochet",
                severity: .error,
                category: .antiCheat,
                title: "Ricochet Anti-Cheat Incompatible",
                remediation: "Ricochet kernel anti-cheat (randgrid.sys) is unsupported under macOS Wine/ARM64EC. Titles enforcing Ricochet cannot play online through DirectMetal."
            )
        }

        if containsAny(line, gameGuardPatterns) {
            return MatchedRule(
                id: "anticheat-gameguard",
                severity: .error,
                category: .antiCheat,
                title: "nProtect GameGuard Anti-Cheat Blocked",
                remediation: "nProtect GameGuard depends on Windows kernel hooks unsupported on macOS. Online titles enforcing GameGuard cannot run under DirectMetal; check if an offline build is available."
            )
        }

        if containsAny(line, otherAntiCheatPatterns)
            || (contains(line, "anti-cheat") && containsAny(line, antiCheatContextPatterns))
        {
            return MatchedRule(
                id: "anticheat-generic",
                severity: .error,
                category: .antiCheat,
                title: "Kernel Anti-Cheat Driver Incompatible",
                remediation: "Windows kernel-mode anti-cheat drivers cannot load under macOS Wine/ARM64EC. Check whether the title provides an offline or single-player mode without anti-cheat."
            )
        }

        return nil
    }

    private static func matchMissingDLL(_ line: UnsafeBufferPointer<UInt8>) -> MatchedRule? {
        let isImportFailure = contains(line, "import_dll")
            || contains(line, "load_so_dll")
            || (contains(line, "library ") && contains(line, "not found"))
            || (contains(line, ".dll") && containsAny(line, dllFailurePatterns))

        let hasFailureContext = isImportFailure || containsAny(line, genericFailureContextPatterns)

        // Check well-known Windows runtime DLL families first so each gets targeted remediation.
        if hasFailureContext && containsAny(line, vcRuntimeDLLPatterns) {
            return MatchedRule(
                id: "missing-dll-vcruntime",
                severity: .error,
                category: .missingDLL,
                title: "Missing Visual C++ Redistributable DLL",
                remediation: "Install the Microsoft Visual C++ Redistributable (vc_redist.x64.exe / x86) into this game's Wine prefix, or run `DirectMetal prefix reset <name>` if the prefix system32 folder is incomplete."
            )
        }

        if hasFailureContext && containsAny(line, d3dxDLLPatterns) {
            return MatchedRule(
                id: "missing-dll-d3dx",
                severity: .error,
                category: .missingDLL,
                title: "Missing Legacy DirectX (D3DX) DLL",
                remediation: "Install the legacy DirectX End-User Runtime (June 2010) into the game's prefix. For DirectX 9 games, also test switching `--dx9-backend wined3d` vs `--dx9-backend dxvk`."
            )
        }

        if hasFailureContext && containsAny(line, xaudioDLLPatterns) {
            return MatchedRule(
                id: "missing-dll-xaudio2",
                severity: .error,
                category: .missingDLL,
                title: "Missing XAudio2 / FAudio Library",
                remediation: "Restore FAudio/XAudio2 DLLs in the prefix via `DirectMetal prefix reset <name>`, or install the DirectX redistributable into the game's prefix."
            )
        }

        if hasFailureContext && containsAny(line, mfplatDLLPatterns) {
            return MatchedRule(
                id: "missing-dll-mfplat",
                severity: .error,
                category: .missingDLL,
                title: "Missing Windows Media Foundation DLL (mfplat)",
                remediation: "Media Foundation (`mfplat.dll`) is required for in-game H.264/WMV video cutscenes. Update the runtime via `DirectMetal runtime update`, or pass a game launch argument to skip intro videos if cutscenes stall."
            )
        }

        if isImportFailure {
            if let dllName = extractDLLName(from: line) {
                let slugPart = sanitizeSlug(dllName.replacingOccurrences(of: ".dll", with: ""))
                let id = slugPart.isEmpty ? "missing-dll-generic" : "missing-dll-\(slugPart)"
                return MatchedRule(
                    id: id,
                    severity: .error,
                    category: .missingDLL,
                    title: "Missing DLL: \(dllName)",
                    remediation: "Install or restore `\(dllName)` into the game directory or prefix `drive_c/windows/system32`, verify game files in your storefront, or run `DirectMetal prefix reset <name>`."
                )
            }
            return MatchedRule(
                id: "missing-dll-generic",
                severity: .error,
                category: .missingDLL,
                title: "Missing Windows DLL Dependency",
                remediation: "Verify the game's installation files, install any bundled `_CommonRedist` installers into the prefix, or run `DirectMetal prefix reset <name>`."
            )
        }

        return nil
    }

    private static func matchSandboxDenied(_ line: UnsafeBufferPointer<UInt8>) -> MatchedRule? {
        let isSeatbelt = (contains(line, "sandbox:") && contains(line, "deny"))
            || (contains(line, "seatbelt") && containsAny(line, seatbeltContextPatterns))

        if isSeatbelt {
            return MatchedRule(
                id: "sandbox-seatbelt-deny",
                severity: .error,
                category: .sandboxDenied,
                title: "macOS Seatbelt Sandbox Denied Access",
                remediation: "DirectMetal's Seatbelt sandbox blocked a file, Mach port, or network call. Disable sandbox for this title (omit `--sandbox` or set `sandbox=false` via `DirectMetal library set`), or whitelist a write directory with `--sandbox-out <dir>`."
            )
        }

        if contains(line, "operation not permitted") || containsToken(line, "eperm") {
            return MatchedRule(
                id: "sandbox-eperm",
                severity: .error,
                category: .sandboxDenied,
                title: "Operation Not Permitted (EPERM / Sandbox)",
                remediation: "macOS refused a syscall or file operation (EPERM). Disable Seatbelt sandbox for this title (omit `--sandbox`) or add `--sandbox-out <dir>`, and check macOS Privacy & Security folder permissions."
            )
        }

        return nil
    }

    private static func matchGPUMemory(_ line: UnsafeBufferPointer<UInt8>) -> MatchedRule? {
        if containsAny(line, gpuOOMPatterns) {
            return MatchedRule(
                id: "gpu-oom",
                severity: .error,
                category: .gpuMemory,
                title: "GPU / Unified Memory Exhausted (Out of Video Memory)",
                remediation: "The game exceeded Apple Silicon's GPU UMA working set. Enable MetalFX upscaling (`--upscale performance` or `--upscale balanced`), disable Retina HiDPI (`--no-retina`), lower in-game texture/shadow quality, and close memory-heavy macOS apps."
            )
        }

        if containsAny(line, gpuDeviceRemovedPatterns) {
            return MatchedRule(
                id: "gpu-device-removed",
                severity: .error,
                category: .gpuMemory,
                title: "GPU Device Removed or Hung (DXGI / Vulkan)",
                remediation: "The Metal/DXGI graphics device timed out or reset. Lower graphics settings, enable MetalFX upscaling (`--upscale balanced`) to reduce GPU load, switch to `--perf-mode balanced`, or clear shaders with `DirectMetal cache clear`."
            )
        }

        if containsAny(line, gpuCommandBufferPatterns) {
            return MatchedRule(
                id: "gpu-mtl-command-buffer",
                severity: .error,
                category: .gpuMemory,
                title: "Metal Command Buffer Execution Error",
                remediation: "A Metal command buffer failed on the Apple Silicon GPU (timeout, UMA pressure, or invalid GPU resource). Try `--perf-mode balanced`, `--no-retina`, `--upscale balanced`, and `DirectMetal cache clear`."
            )
        }

        return nil
    }

    private static func matchD3D12Alignment(_ line: UnsafeBufferPointer<UInt8>) -> MatchedRule? {
        let isExplicitD3D12Alignment = contains(line, "d3d12_default_resource_placement_alignment")
            || contains(line, "createplacedresource")
            || (contains(line, "alignment") && containsAny(line, d3d12AlignmentContextPatterns))
            || (containsAny(line, d3d12SizePatterns) && containsAny(line, d3d12ResourceContextPatterns))

        guard isExplicitD3D12Alignment else { return nil }

        return MatchedRule(
            id: "d3d12-placed-resource-alignment",
            severity: .error,
            category: .d3d12Alignment,
            title: "D3D12 Placed Resource 64KB Alignment Violation",
            remediation: "Apple Silicon / Mullion requires 64 KB placement alignment for D3D12 placed resources. Ensure DirectMetal's D3D12 alignment guard (`d3d12_mullion.dll`) is active — unset `DIRECTMETAL_DISABLE_D3D12_GUARD` if set, verify guard status with `DirectMetal doctor`, or run `DirectMetal prefix reset <name>`."
        )
    }

    private static func matchShaderCompile(_ line: UnsafeBufferPointer<UInt8>) -> MatchedRule? {
        let hasFailureWord = containsAny(line, shaderFailureWords)

        if contains(line, "mtlbinaryarchive") && hasFailureWord {
            return MatchedRule(
                id: "shader-binary-archive",
                severity: .warning,
                category: .shaderCompile,
                title: "Metal Binary Shader Archive Cache Error",
                remediation: "The pre-compiled `MTLBinaryArchive` shader cache could not be read or updated, which causes shader recompilation stutter. Run `DirectMetal cache clear` to rebuild a clean cache for your current macOS and GPU."
            )
        }

        let isShaderCompileError = containsAny(line, shaderCompileDirectPatterns)
            || (contains(line, "mtllibrary") && hasFailureWord)
            || (contains(line, "dxbc") && hasFailureWord)
            || (contains(line, "dxil") && hasFailureWord)
            || (contains(line, "metalshaderconverter") && hasFailureWord)
            || (containsToken(line, "air")
                && hasFailureWord
                && containsAny(line, airShaderContextPatterns))

        guard isShaderCompileError else { return nil }

        return MatchedRule(
            id: "shader-compile-failed",
            severity: .error,
            category: .shaderCompile,
            title: "Shader Compilation / Translation Failed (DXBC/DXIL → AIR)",
            remediation: "A DirectX shader failed to translate to Metal AIR/`MTLLibrary`. Clear stale caches with `DirectMetal cache clear`, update the runtime with `DirectMetal runtime update`, and for DirectX 9 titles test switching `--dx9-backend wined3d` vs `--dx9-backend dxvk`."
        )
    }

    private static func matchArchitecture(_ line: UnsafeBufferPointer<UInt8>) -> MatchedRule? {
        if containsAny(line, badCPUPatterns) {
            return MatchedRule(
                id: "arch-bad-cpu-type",
                severity: .error,
                category: .architecture,
                title: "Incompatible CPU Architecture (Bad CPU Type / Exec Format Error)",
                remediation: "macOS could not execute the binary for the selected CPU architecture. Run `DirectMetal inspect <exe>` to check 32-bit vs 64-bit architecture, install Rosetta 2 (`softwareupdate --install-rosetta`) if using `--engine rosetta`, or use `--engine arm64ec`."
            )
        }

        if contains(line, "rosetta") && containsAny(line, rosettaErrorPatterns) {
            return MatchedRule(
                id: "arch-rosetta-unavailable",
                severity: .error,
                category: .architecture,
                title: "Rosetta 2 Translation Error or Missing Runtime",
                remediation: "Rosetta 2 failed or is not installed. Install Rosetta 2 with `softwareupdate --install-rosetta --agree-to-license`, or switch the title to native ARM64EC+FEX using `--engine arm64ec`."
            )
        }

        if contains(line, "wow64") {
            if containsAny(line, wow64ErrorPatterns) {
                return MatchedRule(
                    id: "arch-wow64-failure",
                    severity: .error,
                    category: .architecture,
                    title: "32-Bit WoW64 Execution Failure",
                    remediation: "32-bit x86 (WoW64) titles on ARM64EC+FEX require macOS 26.4+ cross-arch support or a legacy Rosetta 2 runtime. Try `--engine rosetta` if installed, and inspect the executable with `DirectMetal inspect <exe>`."
                )
            }
            if contains(line, "warn") {
                return MatchedRule(
                    id: "arch-wow64-warning",
                    severity: .warning,
                    category: .architecture,
                    title: "32-Bit WoW64 Compatibility Warning",
                    remediation: "32-bit x86 (WoW64) titles on ARM64EC+FEX require macOS 26.4+ cross-arch support or a legacy Rosetta 2 runtime. Try `--engine rosetta` if installed, and inspect the executable with `DirectMetal inspect <exe>`."
                )
            }
        }

        return nil
    }

    private static func matchCrash(_ line: UnsafeBufferPointer<UInt8>) -> MatchedRule? {
        if contains(line, "page fault") {
            return MatchedRule(
                id: "crash-page-fault",
                severity: .error,
                category: .crash,
                title: "Memory Page Fault in Wine Process",
                remediation: "The process faulted on an invalid memory access. Enable FEX TSO (`--fex-tso on`) to guard against ARM64 weak memory-ordering races, try `--perf-mode balanced`, or reset the prefix with `DirectMetal prefix reset <name>`."
            )
        }

        if containsAny(line, unhandledExceptionPatterns) {
            return MatchedRule(
                id: "crash-unhandled-exception",
                severity: .error,
                category: .crash,
                title: "Unhandled Windows Exception / Access Violation",
                remediation: "The game crashed with an unhandled Windows exception. Check any missing DLL findings above, enable strong x86 memory ordering (`--fex-tso on`), or switch `--perf-mode balanced`."
            )
        }

        if containsAny(line, crashSignalPatterns) {
            return MatchedRule(
                id: "crash-signal",
                severity: .error,
                category: .crash,
                title: "Native Process Crash Signal (SIGSEGV / SIGBUS)",
                remediation: "The Wine/FEX or graphics process terminated with a native macOS crash signal. Try `--fex-tso on`, `--perf-mode balanced`, `DirectMetal cache clear`, and `DirectMetal runtime update`."
            )
        }

        if containsAny(line, fatalErrorPatterns) {
            return MatchedRule(
                id: "crash-fatal-error",
                severity: .error,
                category: .crash,
                title: "Application Fatal Error",
                remediation: "The game aborted with a fatal error. Resolve any GPU memory, shader, or missing DLL findings above, verify game file integrity, and retry with `--perf-mode balanced` or `--upscale balanced`."
            )
        }

        if containsAny(line, assertionPatterns) {
            return MatchedRule(
                id: "crash-assertion-failed",
                severity: .error,
                category: .crash,
                title: "Runtime Assertion Failure",
                remediation: "An internal assertion failed in Wine, the translation layer, or the game. Try `--fex-tso on`, `DirectMetal cache clear`, or `DirectMetal prefix reset <name>`."
            )
        }

        return nil
    }

    private static func matchGeneral(_ line: UnsafeBufferPointer<UInt8>) -> MatchedRule? {
        if containsAny(line, diskFullPatterns) {
            return MatchedRule(
                id: "general-disk-full",
                severity: .error,
                category: .general,
                title: "Insufficient Disk Space (ENOSPC)",
                remediation: "Free disk space on your APFS volume, clear pre-compiled shader caches with `DirectMetal cache clear`, and remove unused game prefixes via `DirectMetal prefix delete <name>`."
            )
        }

        if (contains(line, "wineserver") && containsAny(line, wineserverErrorPatterns))
            || containsAny(line, wineStartupPatterns)
        {
            return MatchedRule(
                id: "general-wineserver-startup",
                severity: .error,
                category: .general,
                title: "Wine / Wineserver Startup Failure",
                remediation: "Stop stale background wineservers with `DirectMetal runtime stop-servers`, run `DirectMetal doctor` to check runtime integrity, or reset the prefix with `DirectMetal prefix reset <name>`."
            )
        }

        if containsAny(line, displayInitPatterns) {
            return MatchedRule(
                id: "general-display-init",
                severity: .warning,
                category: .general,
                title: "Display / Swapchain Initialization Issue",
                remediation: "Try launching inside a virtual desktop (`--desktop 1920x1080`) or disabling Retina HiDPI (`--no-retina`) to stabilize swapchain creation."
            )
        }

        return nil
    }

    // MARK: - Generic Line Severity Classifiers

    private static func hasGenericErrorMarker(_ line: UnsafeBufferPointer<UInt8>) -> Bool {
        containsMarkerWithBoundary(line, "err:")
            || containsMarkerWithBoundary(line, "error:")
            || contains(line, "[error]")
            || contains(line, "[err]")
            || containsMarkerWithBoundary(line, "fatal:")
            || containsMarkerWithBoundary(line, "critical:")
    }

    private static func hasGenericWarningMarker(_ line: UnsafeBufferPointer<UInt8>) -> Bool {
        containsMarkerWithBoundary(line, "warn:")
            || containsMarkerWithBoundary(line, "warning:")
            || contains(line, "[warn]")
            || contains(line, "[warning]")
    }

    // MARK: - Formatting & Extraction Helpers

    private static func formatSampleLine(rawSlice: Substring, home: String) -> String {
        let trimmed = String(rawSlice).trimmingCharacters(in: .whitespacesAndNewlines)
        let redacted = LaunchDiagnostics.redactHome(trimmed, home: home)
        guard redacted.count > maxSampleLineLength else { return redacted }
        let cutoff = redacted.index(redacted.startIndex, offsetBy: maxSampleLineLength - 1)
        return String(redacted[..<cutoff]) + "…"
    }

    private static func buildSummary(
        totalLines: Int,
        errorLineCount: Int,
        warningLineCount: Int,
        highestSeverity: LogFindingSeverity,
        findings: [LaunchLogFinding]
    ) -> String {
        let lineWord = totalLines == 1 ? "line" : "lines"
        guard let top = findings.first else {
            return "No known crash, anti-cheat, sandbox, DLL, GPU, or shader issues detected across \(totalLines) \(lineWord)."
        }

        let issueWord = findings.count == 1 ? "issue" : "issues"
        let errWord = errorLineCount == 1 ? "error line" : "error lines"
        let warnWord = warningLineCount == 1 ? "warning line" : "warning lines"
        return "Detected \(findings.count) \(issueWord) (highest: \(highestSeverity.rawValue); \(errorLineCount) \(errWord), \(warningLineCount) \(warnWord)) across \(totalLines) \(lineWord). Top finding: \(top.title)."
    }

    private static func markdownInlineCode(_ text: String) -> String {
        var maxRun = 0
        var currentRun = 0
        for ch in text {
            if ch == "`" {
                currentRun += 1
                if currentRun > maxRun { maxRun = currentRun }
            } else {
                currentRun = 0
            }
        }
        let fence = String(repeating: "`", count: maxRun + 1)
        let needsPadding = text.hasPrefix("`") || text.hasSuffix("`")
        if needsPadding {
            return "\(fence) \(text) \(fence)"
        }
        return "\(fence)\(text)\(fence)"
    }

    /// Extracts a `<name>.dll` token from a lowercased log line (e.g. `err:module:import_dll Library foo.dll ... not found`).
    private static func extractDLLName(from line: UnsafeBufferPointer<UInt8>) -> String? {
        let suffix: StaticString = ".dll"
        let suffixLen = suffix.utf8CodeUnitCount
        let n = line.count
        guard n >= suffixLen else { return nil }

        var searchStart = 0
        while searchStart <= n - suffixLen {
            guard let dotIdx = findBytes(in: line, needle: suffix, from: searchStart) else {
                return nil
            }
            let tokenEnd = dotIdx + suffixLen
            // Ensure `.dll` is not followed by another identifier character.
            if tokenEnd == n || !isASCIIIdentifierChar(line[tokenEnd]) {
                var tokenStart = dotIdx
                while tokenStart > 0 && isDLLNameChar(line[tokenStart - 1]) {
                    tokenStart -= 1
                }
                if tokenStart < dotIdx {
                    let bytes = Array(line[tokenStart..<tokenEnd])
                    return String(decoding: bytes, as: UTF8.self)
                }
            }
            searchStart = dotIdx + 1
        }
        return nil
    }

    private static func sanitizeSlug(_ raw: String) -> String {
        var result = ""
        result.reserveCapacity(raw.count)
        var lastWasDash = false
        for scalar in raw.unicodeScalars {
            let v = scalar.value
            if (v >= 0x61 && v <= 0x7A) || (v >= 0x30 && v <= 0x39) {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash && !result.isEmpty {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasSuffix("-") {
            result.removeLast()
        }
        return result
    }

    // MARK: - Fast Zero-Allocation Byte-Level Matching Primitives

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A
    }

    private static func isASCIIAlpha(_ byte: UInt8) -> Bool {
        (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x41 && byte <= 0x5A)
    }

    private static func isASCIIIdentifierChar(_ byte: UInt8) -> Bool {
        isASCIIAlpha(byte) || (byte >= 0x30 && byte <= 0x39) || byte == 0x5F
    }

    private static func isDLLNameChar(_ byte: UInt8) -> Bool {
        isASCIIIdentifierChar(byte) || byte == 0x2D || byte == 0x2E
    }

    private static func findBytes(
        in haystack: UnsafeBufferPointer<UInt8>,
        needle: StaticString,
        from start: Int = 0
    ) -> Int? {
        needle.withUTF8Buffer { needleBuf in
            let hCount = haystack.count
            let nCount = needleBuf.count
            guard nCount > 0, hCount >= start + nCount else { return nil }
            let first = needleBuf[0]
            let limit = hCount - nCount
            var i = start
            while i <= limit {
                if haystack[i] == first {
                    var matched = true
                    var j = 1
                    while j < nCount {
                        if haystack[i + j] != needleBuf[j] {
                            matched = false
                            break
                        }
                        j += 1
                    }
                    if matched { return i }
                }
                i += 1
            }
            return nil
        }
    }

    private static func contains(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: StaticString) -> Bool {
        findBytes(in: haystack, needle: needle) != nil
    }

    private static func containsAny(_ haystack: UnsafeBufferPointer<UInt8>, _ needles: [StaticString]) -> Bool {
        for needle in needles where contains(haystack, needle) {
            return true
        }
        return false
    }

    /// Matches a token bounded on both sides by non-identifier ASCII bytes (e.g. `eperm`, `air`).
    private static func containsToken(_ haystack: UnsafeBufferPointer<UInt8>, _ token: StaticString) -> Bool {
        let tokenLen = token.utf8CodeUnitCount
        var offset = 0
        while let idx = findBytes(in: haystack, needle: token, from: offset) {
            let leftOK = (idx == 0) || !isASCIIIdentifierChar(haystack[idx - 1])
            let rightIdx = idx + tokenLen
            let rightOK = (rightIdx == haystack.count) || !isASCIIIdentifierChar(haystack[rightIdx])
            if leftOK && rightOK {
                return true
            }
            offset = idx + 1
        }
        return false
    }

    /// Matches a marker like `err:` or `warn:` only when not preceded by an ASCII letter
    /// (matches `0024:err:`, `err:`, `[error:]`, skips `stderr:` or `bewarn:`).
    private static func containsMarkerWithBoundary(
        _ haystack: UnsafeBufferPointer<UInt8>,
        _ marker: StaticString
    ) -> Bool {
        var offset = 0
        while let idx = findBytes(in: haystack, needle: marker, from: offset) {
            if idx == 0 || !isASCIIAlpha(haystack[idx - 1]) {
                return true
            }
            offset = idx + 1
        }
        return false
    }
}
