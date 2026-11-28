import Foundation

// Per-Game Launch Environment & Arguments Validator / Linter (Foundation-only).
// Pure, side-effect-free validator for `GameLibraryEntry.customEnv` and `extraArgs` that catches
// syntax errors, DirectMetal host-isolation blocked keys, Linux/Steam Deck/Proton-only variables
// and wrapper commands, conflicts with saved per-game settings, and sensitive credential keys
// without ever echoing raw secret values.

// MARK: - Severity & Category Models

enum LaunchEnvIssueSeverity: String, Codable, Comparable, CaseIterable, Hashable, Sendable {
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

    static func < (lhs: LaunchEnvIssueSeverity, rhs: LaunchEnvIssueSeverity) -> Bool {
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

enum LaunchEnvIssueCategory: String, Codable, CaseIterable, Hashable, Sendable {
    /// Security or host-isolation environment variable stripped by DirectMetal.
    case blockedKey
    /// Malformed KEY=VALUE pair, invalid POSIX identifier, unclosed quote, or stray Steam `%command%`.
    case syntaxError
    /// Linux / Steam Deck / Proton-only environment variable or launch wrapper command.
    case linuxProtonOnly
    /// Custom environment variable contradicting a saved DirectMetal per-game setting.
    case conflict
    /// Environment variable name indicating a sensitive credential (value never echoed).
    case secretAdvisory

    var displayName: String {
        switch self {
        case .blockedKey: return "Blocked Key"
        case .syntaxError: return "Syntax Error"
        case .linuxProtonOnly: return "Linux / Proton Only"
        case .conflict: return "Setting Conflict"
        case .secretAdvisory: return "Secret Advisory"
        }
    }
}

// MARK: - Validation Report Models

struct LaunchEnvIssue: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let severity: LaunchEnvIssueSeverity
    let category: LaunchEnvIssueCategory
    let keyOrToken: String
    let message: String
    let suggestion: String
}

struct LaunchEnvValidationReport: Codable, Equatable, Sendable {
    let validEnvKeyCount: Int
    let blockedKeyCount: Int
    let argCount: Int
    let highestSeverity: LaunchEnvIssueSeverity
    let issues: [LaunchEnvIssue]

    var isClean: Bool { issues.isEmpty }
    var hasErrors: Bool { issues.contains { $0.severity == .error } }
}

// MARK: - Validator & Formatters

enum LaunchEnvValidator {

    /// Substrings in an environment variable key name that indicate a sensitive credential.
    private static let sensitiveKeyMarkers: [String] = [
        "TOKEN",
        "SECRET",
        "PASSWORD",
        "PASSWD",
        "API_KEY",
        "APIKEY",
        "AUTH",
        "CREDENTIAL",
        "PRIVATE_KEY",
        "ACCESS_KEY",
    ]

    /// Convenience overload validating an existing `GameLibraryEntry`.
    static func validate(entry: GameLibraryEntry) -> LaunchEnvValidationReport {
        validate(customEnv: entry.customEnv, extraArgs: entry.extraArgs, entry: entry)
    }

    /// Validates per-game custom environment variables (`KEY=VALUE` tokens) and extra launch arguments,
    /// optionally cross-checking against a `GameLibraryEntry`'s saved DirectMetal settings.
    /// Raw environment variable values for sensitive keys are never echoed in any report field.
    static func validate(
        customEnv: String,
        extraArgs: String,
        entry: GameLibraryEntry? = nil
    ) -> LaunchEnvValidationReport {
        var issuesByID: [String: LaunchEnvIssue] = [:]
        func addIssue(_ issue: LaunchEnvIssue) {
            if issuesByID[issue.id] == nil {
                issuesByID[issue.id] = issue
            }
        }

        // 1. Validate customEnv string.
        let envScan = tokenizeShell(customEnv)
        if let quote = envScan.unclosedQuote {
            let quoteKind = quote == "\"" ? "double" : "single"
            addIssue(LaunchEnvIssue(
                id: "syntax:env:unclosed_quote",
                severity: .error,
                category: .syntaxError,
                keyOrToken: "unclosed \(quote)",
                message: "Unclosed \(quoteKind) quote (\(quote)) in custom environment variables.",
                suggestion: "Add the closing \(quote) quote or escape literal quotes with \\\(quote) so KEY=VALUE tokens parse cleanly."
            ))
        }

        var validEnv: [String: String] = [:]
        var blockedKeys = Set<String>()
        var previousStandaloneWasSensitiveKey = false
        var redactNextStandaloneToken = false

        for (index, token) in envScan.tokens.enumerated() {
            if let eq = token.firstIndex(of: "=") {
                let rawKey = String(token[..<eq]).trimmingCharacters(in: .whitespaces)
                let value = String(token[token.index(after: eq)...])
                let upper = rawKey.uppercased()

                // Detect `SENSITIVE_KEY = secret_value` split across spaces around `=`.
                if token == "=" && previousStandaloneWasSensitiveKey {
                    redactNextStandaloneToken = true
                } else {
                    redactNextStandaloneToken = false
                }
                previousStandaloneWasSensitiveKey = false

                if !GameLibraryManager.isValidEnvKey(rawKey) {
                    let displayKey = rawKey.isEmpty ? "<empty>" : rawKey
                    let idComponent = rawKey.isEmpty ? "empty:\(index)" : rawKey
                    let message: String
                    let suggestion: String
                    if rawKey.isEmpty {
                        message = "Malformed environment entry with an empty variable name before '='; DirectMetal will ignore it."
                        suggestion = "Provide a valid POSIX identifier before '=' (for example, FOO=1) and avoid spaces around '='."
                    } else {
                        message = "Invalid environment variable name '\(displayKey)' (must match [A-Za-z_][A-Za-z0-9_]*); DirectMetal will ignore it."
                        let sanitizedExample = suggestValidIdentifier(from: rawKey)
                        suggestion = "Rename '\(displayKey)' to a valid POSIX identifier starting with a letter or underscore (for example, '\(sanitizedExample)')."
                    }
                    addIssue(LaunchEnvIssue(
                        id: "syntax:env:invalid_key:\(idComponent)",
                        severity: .error,
                        category: .syntaxError,
                        keyOrToken: displayKey,
                        message: message,
                        suggestion: suggestion
                    ))
                    continue
                }

                if GameLibraryManager.blockedCustomEnvKeys.contains(upper) {
                    blockedKeys.insert(upper)
                    let guidance = blockedKeyGuidance(for: rawKey, upperKey: upper)
                    addIssue(LaunchEnvIssue(
                        id: "blocked:\(upper)",
                        severity: .warning,
                        category: .blockedKey,
                        keyOrToken: rawKey,
                        message: guidance.message,
                        suggestion: guidance.suggestion
                    ))
                    if isSensitiveKeyName(upper) {
                        addIssue(makeSecretAdvisory(key: rawKey, upperKey: upper))
                    }
                    continue
                }

                // Valid, non-blocked key.
                validEnv[rawKey] = value

                if isSensitiveKeyName(upper) {
                    addIssue(makeSecretAdvisory(key: rawKey, upperKey: upper))
                }

                if let linuxIssue = checkLinuxProtonEnvVar(key: rawKey, upperKey: upper) {
                    addIssue(linuxIssue)
                }
            } else {
                let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                let shouldRedact = redactNextStandaloneToken
                redactNextStandaloneToken = false
                previousStandaloneWasSensitiveKey = !shouldRedact && isSensitiveKeyName(trimmed.uppercased())

                let lower = trimmed.lowercased()
                if lower == "%command%" {
                    addIssue(LaunchEnvIssue(
                        id: "syntax:env:steam_command_token",
                        severity: .error,
                        category: .syntaxError,
                        keyOrToken: "%command%",
                        message: "Found Steam launch-option placeholder '%command%' inside custom environment variables; DirectMetal will ignore it.",
                        suggestion: "Remove '%command%'. Keep only KEY=VALUE pairs in Custom Env Vars and place game flags in Extra Launch Arguments."
                    ))
                } else if let wrapperAdvice = linuxWrapperInEnvAdvice(forLowercasedToken: lower) {
                    addIssue(LaunchEnvIssue(
                        id: "syntax:env:missing_equals:\(lower)",
                        severity: .error,
                        category: .syntaxError,
                        keyOrToken: trimmed,
                        message: "Token '\(trimmed)' is missing '=' and is a Linux launch wrapper command that is not used on macOS.",
                        suggestion: wrapperAdvice
                    ))
                } else {
                    let displayToken = shouldRedact ? "<redacted>" : trimmed
                    let idToken = shouldRedact ? "redacted:\(index)" : trimmed
                    addIssue(LaunchEnvIssue(
                        id: "syntax:env:missing_equals:\(idToken)",
                        severity: .error,
                        category: .syntaxError,
                        keyOrToken: displayToken,
                        message: "Token '\(displayToken)' is missing '=' (expected KEY=VALUE) and will be ignored by DirectMetal.",
                        suggestion: "Format custom environment variables as KEY=VALUE with no spaces around '=', or move command-line flags to Extra Launch Arguments."
                    ))
                }
            }
        }

        // 2. Cross-check final effective customEnv values against GameLibraryEntry settings.
        if let entry {
            for conflictIssue in checkEntryConflicts(validEnv: validEnv, entry: entry) {
                addIssue(conflictIssue)
            }
        }

        // 3. Validate extraArgs string.
        let argsScan = tokenizeShell(extraArgs)
        if let quote = argsScan.unclosedQuote {
            let quoteKind = quote == "\"" ? "double" : "single"
            addIssue(LaunchEnvIssue(
                id: "syntax:args:unclosed_quote",
                severity: .error,
                category: .syntaxError,
                keyOrToken: "unclosed \(quote)",
                message: "Unclosed \(quoteKind) quote (\(quote)) in extra launch arguments.",
                suggestion: "Add the matching closing \(quote) quote or escape literal quotes with \\\(quote) so arguments split reliably."
            ))
        }

        for token in argsScan.tokens {
            if let argIssue = checkExtraArgToken(token) {
                addIssue(argIssue)
            }
        }

        // 4. Deterministic sort: (severity desc, category.rawValue asc, keyOrToken asc, id asc).
        let sortedIssues = issuesByID.values.sorted { lhs, rhs in
            if lhs.severity != rhs.severity {
                return lhs.severity > rhs.severity
            }
            if lhs.category.rawValue != rhs.category.rawValue {
                return lhs.category.rawValue < rhs.category.rawValue
            }
            if lhs.keyOrToken != rhs.keyOrToken {
                return lhs.keyOrToken < rhs.keyOrToken
            }
            return lhs.id < rhs.id
        }

        let highestSeverity = sortedIssues.first?.severity ?? .info

        return LaunchEnvValidationReport(
            validEnvKeyCount: validEnv.count,
            blockedKeyCount: blockedKeys.count,
            argCount: argsScan.tokens.count,
            highestSeverity: highestSeverity,
            issues: sortedIssues
        )
    }

    // MARK: - Text Formatter (CLI)

    static func formatText(_ report: LaunchEnvValidationReport) -> String {
        var sections: [String] = []
        sections.append("DirectMetal Launch Environment & Arguments Validation")

        let errorCount = report.issues.reduce(0) { $0 + ($1.severity == .error ? 1 : 0) }
        let warningCount = report.issues.reduce(0) { $0 + ($1.severity == .warning ? 1 : 0) }
        let infoCount = report.issues.reduce(0) { $0 + ($1.severity == .info ? 1 : 0) }

        let statusText: String
        if report.isClean {
            statusText = "Clean (no issues)"
        } else {
            let issueWord = report.issues.count == 1 ? "issue" : "issues"
            statusText = "\(report.issues.count) \(issueWord) (highest: \(report.highestSeverity.displayLabel); \(errorCount) error, \(warningCount) warning, \(infoCount) info)"
        }

        let summaryRows: [(String, String)] = [
            ("Status", statusText),
            ("Valid Env Keys", "\(report.validEnvKeyCount)"),
            ("Blocked Env Keys", "\(report.blockedKeyCount)"),
            ("Extra Args", "\(report.argCount)"),
            ("Issues", "\(report.issues.count)"),
        ]
        let labelWidth = max((summaryRows.map { $0.0.count }.max() ?? 0) + 2, 18)
        var summaryLines = ["[Summary]"]
        for (label, value) in summaryRows {
            let padded = (label + ":").padding(toLength: labelWidth, withPad: " ", startingAt: 0)
            summaryLines.append("  \(padded)\(value)")
        }
        sections.append(summaryLines.joined(separator: "\n"))

        if report.issues.isEmpty {
            sections.append("[Issues]\n  No issues detected.")
        } else {
            var issueLines = ["[Issues (\(report.issues.count))]"]
            for (index, issue) in report.issues.enumerated() {
                issueLines.append(
                    "  \(index + 1). [\(issue.severity.displayLabel)] [\(issue.category.rawValue)] \(issue.keyOrToken)"
                )
                issueLines.append("     ID:         \(issue.id)")
                issueLines.append("     Message:    \(issue.message)")
                issueLines.append("     Suggestion: \(issue.suggestion)")
            }
            sections.append(issueLines.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n") + "\n"
    }

    // MARK: - Markdown Formatter

    static func formatMarkdown(_ report: LaunchEnvValidationReport) -> String {
        func severityIcon(_ severity: LaunchEnvIssueSeverity) -> String {
            switch severity {
            case .error: return "🔴"
            case .warning: return "🟡"
            case .info: return "🔵"
            }
        }

        let statusCell: String
        if report.isClean {
            statusCell = "✅ Clean (0 issues)"
        } else {
            let issueWord = report.issues.count == 1 ? "issue" : "issues"
            statusCell = "\(severityIcon(report.highestSeverity)) `\(report.highestSeverity.rawValue)` (\(report.issues.count) \(issueWord))"
        }

        var lines: [String] = [
            "### DirectMetal Launch Environment & Arguments Validation",
            "",
            "| Metric | Value |",
            "| :--- | :--- |",
            "| **Status** | \(statusCell) |",
            "| **Valid Env Keys** | \(report.validEnvKeyCount) |",
            "| **Blocked Env Keys** | \(report.blockedKeyCount) |",
            "| **Extra Args** | \(report.argCount) |",
            "| **Issues** | \(report.issues.count) |",
        ]

        if report.issues.isEmpty {
            lines.append("")
            lines.append("_No environment variable or launch argument issues detected._")
        } else {
            lines.append("")
            lines.append("#### Issues")
            for (index, issue) in report.issues.enumerated() {
                lines.append("")
                lines.append(
                    "##### \(index + 1). \(severityIcon(issue.severity)) \(markdownInlineCode(issue.keyOrToken)) (`\(issue.category.rawValue)` · `\(issue.severity.rawValue)`)"
                )
                lines.append("")
                lines.append("- **ID:** `\(issue.id)`")
                lines.append("- **Message:** \(issue.message)")
                lines.append("- **Suggestion:** \(issue.suggestion)")
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: - Shell Tokenizer (aligned with GameLibraryManager.splitArguments)

    private struct ShellTokenizeResult {
        let tokens: [String]
        let unclosedQuote: Character?
    }

    /// Mirrors `GameLibraryManager.splitArguments(_:)` while additionally detecting unclosed quotes.
    private static func tokenizeShell(_ s: String) -> ShellTokenizeResult {
        var args: [String] = []
        var cur = ""
        var hasToken = false
        var quote: Character? = nil
        var escape = false

        for ch in s {
            if escape {
                cur.append(ch)
                escape = false
                hasToken = true
                continue
            }
            if ch == "\\" && quote != "'" {
                escape = true
                continue
            }
            if let q = quote {
                if ch == q {
                    quote = nil
                } else {
                    cur.append(ch)
                }
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                hasToken = true
                continue
            }
            if ch.isWhitespace {
                if hasToken {
                    args.append(cur)
                    cur = ""
                    hasToken = false
                }
                continue
            }
            cur.append(ch)
            hasToken = true
        }
        if hasToken {
            args.append(cur)
        }
        return ShellTokenizeResult(tokens: args, unclosedQuote: quote)
    }

    // MARK: - Rule Helpers

    private static func isSensitiveKeyName(_ upperKey: String) -> Bool {
        sensitiveKeyMarkers.contains { upperKey.contains($0) }
    }

    private static func makeSecretAdvisory(key: String, upperKey: String) -> LaunchEnvIssue {
        LaunchEnvIssue(
            id: "secret:\(upperKey)",
            severity: .info,
            category: .secretAdvisory,
            keyOrToken: key,
            message: "Environment variable '\(key)' appears to contain a sensitive credential (value redacted).",
            suggestion: "DirectMetal redacts custom environment variable values in exported support bundles (only key names are included), but values are still stored in your local library.json. Avoid persisting long-lived secrets in per-game launch configs when possible."
        )
    }

    private static func blockedKeyGuidance(for key: String, upperKey: String) -> (message: String, suggestion: String) {
        switch upperKey {
        case "WINEPREFIX":
            return (
                message: "'\(key)' is blocked in per-game custom environment variables to preserve DirectMetal prefix isolation.",
                suggestion: "Configure the game's Prefix Name in DirectMetal Library Settings (or pass --prefix <name> via CLI) instead of setting WINEPREFIX."
            )
        case "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH":
            return (
                message: "'\(key)' is stripped by DirectMetal for host isolation and dynamic-linker security on macOS.",
                suggestion: "Remove '\(key)'. To override Windows DLLs inside the Wine prefix, use WINEDLLOVERRIDES (for example, WINEDLLOVERRIDES=dinput8=n,b)."
            )
        case "LD_PRELOAD":
            return (
                message: "'\(key)' is stripped by DirectMetal for host isolation and is a Linux dynamic-linker variable not used by macOS dyld.",
                suggestion: "Remove '\(key)'. For Windows DLL overrides or mod loaders inside Wine, use WINEDLLOVERRIDES instead."
            )
        default:
            return (
                message: "'\(key)' is on DirectMetal's blocked host-isolation environment variable list and will be stripped at launch.",
                suggestion: "Remove '\(key)' from Custom Env Vars and use DirectMetal's built-in per-game settings instead."
            )
        }
    }

    private static func checkLinuxProtonEnvVar(key: String, upperKey: String) -> LaunchEnvIssue? {
        if upperKey == "MANGOHUD" || upperKey == "MANGOHUD_CONFIG" || upperKey.hasPrefix("MANGOHUD_") {
            return LaunchEnvIssue(
                id: "linux:env:\(upperKey)",
                severity: .warning,
                category: .linuxProtonOnly,
                keyOrToken: key,
                message: "'\(key)' configures Linux MangoHud and has no effect on macOS.",
                suggestion: "Remove '\(key)' and enable DirectMetal's native Metal Performance HUD (toggle Metal HUD in Library Settings or pass --hud; customize elements with `DirectMetal hud`)."
            )
        }

        if upperKey.hasPrefix("PROTON_") {
            let suggestion: String
            switch upperKey {
            case "PROTON_LOG", "PROTON_LOG_DIR":
                suggestion = "Remove '\(key)'. For verbose Wine diagnostics in DirectMetal, set DIRECTMETAL_VERBOSE_WINE=1 and inspect logs with `DirectMetal logs` / Launch Log Triage."
            case "PROTON_USE_WINED3D":
                suggestion = "Remove '\(key)'. Select the wined3d DX9 backend in DirectMetal Library Settings (or pass --dx9-backend wined3d) for DirectX 9 games; D3D11/D3D12 run natively on Metal via Mullion."
            case "PROTON_NO_ESYNC", "PROTON_NO_FSYNC":
                suggestion = "Remove '\(key)'. DirectMetal runs macOS Mach semaphore synchronization (WINEMSYNC=1) rather than Linux esync/fsync."
            case "PROTON_ENABLE_NVAPI", "PROTON_HIDE_NVIDIA_GPU", "PROTON_DLSS_UPGRADE", "PROTON_DLSS_INDICATOR":
                suggestion = "Remove '\(key)'. DirectMetal automatically exposes Mullion's nvngx.dll DLSS-to-MetalFX Temporal bridge when DLSS is detected (disable with DIRECTMETAL_DISABLE_NVNGX_BRIDGE=1 if needed)."
            default:
                if upperKey.hasPrefix("PROTON_FSR") {
                    suggestion = "Remove '\(key)' and use DirectMetal's native Apple MetalFX Upscaling (Quality/Balanced/Performance/Ultra Performance in Library Settings or --upscale)."
                } else {
                    suggestion = "Remove '\(key)'. DirectMetal uses Apple Silicon Wine + ARM64EC/FEX + Mullion on macOS rather than Steam Proton, so PROTON_* variables are ignored."
                }
            }
            return LaunchEnvIssue(
                id: "linux:env:\(upperKey)",
                severity: .warning,
                category: .linuxProtonOnly,
                keyOrToken: key,
                message: "'\(key)' is a Linux Steam Proton variable and is ignored by DirectMetal on macOS.",
                suggestion: suggestion
            )
        }

        if upperKey == "WINEESYNC" || upperKey == "WINEFSYNC" {
            return LaunchEnvIssue(
                id: "linux:env:\(upperKey)",
                severity: .info,
                category: .linuxProtonOnly,
                keyOrToken: key,
                message: "'\(key)' targets Linux kernel synchronization (eventfd esync / futex2 fsync) and is not used on macOS.",
                suggestion: "Remove '\(key)'. DirectMetal automatically enables native macOS Mach semaphore synchronization (WINEMSYNC=1)."
            )
        }

        if upperKey.hasPrefix("VKD3D_") {
            return LaunchEnvIssue(
                id: "linux:env:\(upperKey)",
                severity: .warning,
                category: .linuxProtonOnly,
                keyOrToken: key,
                message: "'\(key)' configures Linux vkd3d-proton (D3D12-to-Vulkan), which DirectMetal does not use.",
                suggestion: "Remove '\(key)'. DirectMetal translates D3D12 directly to Apple Metal 3/4 via Mullion; tune with DirectMetal's Performance Profile (balanced/ultra) or MULLION_CONFIG."
            )
        }

        if upperKey.hasPrefix("MESA_") {
            return LaunchEnvIssue(
                id: "linux:env:\(upperKey)",
                severity: .warning,
                category: .linuxProtonOnly,
                keyOrToken: key,
                message: "'\(key)' is a Linux Mesa driver variable; DirectMetal targets native Apple Metal via Mullion (and bundled KosmicKrisp/WineMetalGL).",
                suggestion: "Remove '\(key)'. DirectMetal manages Metal shader caching, Retina scaling, and KosmicKrisp Vulkan ICD routing automatically."
            )
        }

        if upperKey == "DXVK_ASYNC" {
            return LaunchEnvIssue(
                id: "linux:env:DXVK_ASYNC",
                severity: .info,
                category: .linuxProtonOnly,
                keyOrToken: key,
                message: "'\(key)' is a Linux/Steam Deck DXVK async shader toggle; DirectMetal uses Mullion for D3D11/D3D12 and enables DXVK_ASYNC=1 automatically for D3D9 DXVK.",
                suggestion: "Remove '\(key)' — DirectMetal configures shader compilation automatically for both Mullion and D3D9 DXVK."
            )
        }

        if upperKey == "GAMEMODERUN" || upperKey.hasPrefix("GAMEMODE_") {
            return LaunchEnvIssue(
                id: "linux:env:\(upperKey)",
                severity: .info,
                category: .linuxProtonOnly,
                keyOrToken: key,
                message: "'\(key)' targets Linux Feral GameMode, which does not exist on macOS.",
                suggestion: "Remove '\(key)'. DirectMetal automatically launches games on Apple Silicon Performance cores with userInteractive QoS and App Nap disabled."
            )
        }

        if upperKey == "ENABLE_VKBASALT" || upperKey.hasPrefix("VKBASALT_") {
            return LaunchEnvIssue(
                id: "linux:env:\(upperKey)",
                severity: .warning,
                category: .linuxProtonOnly,
                keyOrToken: key,
                message: "'\(key)' enables Linux vkBasalt Vulkan post-processing, which is unavailable on macOS.",
                suggestion: "Remove '\(key)' and use in-game post-processing or DirectMetal's MetalFX upscaling (--upscale) instead."
            )
        }

        if upperKey.hasPrefix("RADV_") {
            return LaunchEnvIssue(
                id: "linux:env:\(upperKey)",
                severity: .warning,
                category: .linuxProtonOnly,
                keyOrToken: key,
                message: "'\(key)' targets the Linux AMD RADV Vulkan driver and has no effect on Apple Silicon Metal GPUs.",
                suggestion: "Remove '\(key)' and use DirectMetal's Performance Profile (balanced/ultra) or MULLION_CONFIG for Apple Silicon GPU tuning."
            )
        }

        if upperKey == "AMD_VULKAN_ICD" {
            return LaunchEnvIssue(
                id: "linux:env:AMD_VULKAN_ICD",
                severity: .warning,
                category: .linuxProtonOnly,
                keyOrToken: key,
                message: "'\(key)' selects between Linux AMD Vulkan ICDs (RADV/AMDVLK) and has no effect on macOS.",
                suggestion: "Remove '\(key)'. DirectMetal automatically selects Mullion for D3D11/D3D12 and bundled Mesa KosmicKrisp for Vulkan/D3D9 DXVK."
            )
        }

        if upperKey == "__NV_PRIME_RENDER_OFFLOAD" || upperKey == "__GLX_VENDOR_LIBRARY_NAME" || upperKey == "DRI_PRIME" {
            return LaunchEnvIssue(
                id: "linux:env:\(upperKey)",
                severity: .info,
                category: .linuxProtonOnly,
                keyOrToken: key,
                message: "'\(key)' is a Linux hybrid-GPU offload variable and is unused on Apple Silicon macOS.",
                suggestion: "Remove '\(key)' — Apple Silicon Macs use a single unified Metal GPU automatically."
            )
        }

        if upperKey.hasPrefix("STEAM_COMPAT_") || upperKey.hasPrefix("PRESSURE_VESSEL_") {
            return LaunchEnvIssue(
                id: "linux:env:\(upperKey)",
                severity: .warning,
                category: .linuxProtonOnly,
                keyOrToken: key,
                message: "'\(key)' is a Linux Steam Runtime / Proton container variable and has no effect in DirectMetal.",
                suggestion: "Remove '\(key)'. Use DirectMetal's Prefix Name and Seatbelt Sandbox toggle in Library Settings for prefix and process isolation on macOS."
            )
        }

        return nil
    }

    private static func checkEntryConflicts(
        validEnv: [String: String],
        entry: GameLibraryEntry
    ) -> [LaunchEnvIssue] {
        var conflicts: [LaunchEnvIssue] = []

        // 1. MTL_HUD_ENABLED vs entry.enableHUD
        if let rawHUD = validEnv["MTL_HUD_ENABLED"] {
            if let enabled = parseEnvBool(rawHUD) {
                if entry.enableHUD && !enabled {
                    conflicts.append(LaunchEnvIssue(
                        id: "conflict:MTL_HUD_ENABLED",
                        severity: .warning,
                        category: .conflict,
                        keyOrToken: "MTL_HUD_ENABLED",
                        message: "MTL_HUD_ENABLED=\(rawHUD) disables the Metal Performance HUD, contradicting this game's Metal HUD setting (enabled).",
                        suggestion: "Remove MTL_HUD_ENABLED from Custom Env Vars or disable Metal HUD in this game's DirectMetal settings."
                    ))
                } else if !entry.enableHUD && enabled {
                    conflicts.append(LaunchEnvIssue(
                        id: "conflict:MTL_HUD_ENABLED",
                        severity: .warning,
                        category: .conflict,
                        keyOrToken: "MTL_HUD_ENABLED",
                        message: "MTL_HUD_ENABLED=\(rawHUD) forces the Metal Performance HUD on, contradicting this game's Metal HUD setting (disabled).",
                        suggestion: "Remove MTL_HUD_ENABLED from Custom Env Vars or enable Metal HUD in this game's DirectMetal settings."
                    ))
                }
            }
        }

        // 2. DXVK_FRAME_RATE / DXMT_FRAME_RATE_CAP vs entry.fpsCap > 0
        let effectiveCap = max(0, min(entry.fpsCap, 360))
        if effectiveCap > 0 {
            for capKey in ["DXVK_FRAME_RATE", "DXMT_FRAME_RATE_CAP"] {
                if let rawCap = validEnv[capKey] {
                    let trimmed = rawCap.trimmingCharacters(in: .whitespacesAndNewlines)
                    let detail: String
                    if let parsed = Int(trimmed), parsed != effectiveCap {
                        detail = "\(capKey)=\(trimmed) overrides DirectMetal's saved FPS Cap (\(effectiveCap) FPS) with a different limit."
                    } else if trimmed == String(effectiveCap) {
                        detail = "\(capKey)=\(trimmed) duplicates DirectMetal's saved FPS Cap (\(effectiveCap) FPS) and will override future FPS Cap changes."
                    } else {
                        detail = "\(capKey) conflicts with DirectMetal's saved FPS Cap (\(effectiveCap) FPS)."
                    }
                    conflicts.append(LaunchEnvIssue(
                        id: "conflict:\(capKey)",
                        severity: .warning,
                        category: .conflict,
                        keyOrToken: capKey,
                        message: detail,
                        suggestion: "Remove \(capKey) from Custom Env Vars and manage frame limiting through DirectMetal's FPS Cap setting (which sets DXMT_FRAME_RATE_CAP, DXVK_FRAME_RATE, and dxgi.maxFrameRate together)."
                    ))
                }
            }
        }

        // 3. FEX_TSOENABLED vs entry.perfProfile
        if let rawTSO = validEnv["FEX_TSOENABLED"], let tsoEnabled = parseEnvBool(rawTSO) {
            if entry.perfProfile == .ultra && tsoEnabled {
                conflicts.append(LaunchEnvIssue(
                    id: "conflict:FEX_TSOENABLED",
                    severity: .warning,
                    category: .conflict,
                    keyOrToken: "FEX_TSOENABLED",
                    message: "FEX_TSOENABLED=\(rawTSO) forces FEX TSO emulation on, contradicting the Ultra performance profile (which disables TSO for higher 1%-lows).",
                    suggestion: "Switch Performance Profile to Balanced if this game needs TSO thread-safety, or remove FEX_TSOENABLED to keep Ultra defaults."
                ))
            } else if entry.perfProfile == .balanced && !tsoEnabled {
                conflicts.append(LaunchEnvIssue(
                    id: "conflict:FEX_TSOENABLED",
                    severity: .warning,
                    category: .conflict,
                    keyOrToken: "FEX_TSOENABLED",
                    message: "FEX_TSOENABLED=\(rawTSO) disables FEX TSO emulation, contradicting the Balanced performance profile (which keeps TSO enabled for stability).",
                    suggestion: "Switch Performance Profile to Ultra to disable FEX TSO cleanly, or remove FEX_TSOENABLED to keep Balanced defaults."
                ))
            }
        }

        // 4. MULLION_METALFX_SPATIAL_SWAPCHAIN vs entry.launchUpscaleMode
        if let rawSpatial = validEnv["MULLION_METALFX_SPATIAL_SWAPCHAIN"], let spatialOn = parseEnvBool(rawSpatial) {
            let upscaleEnabled = entry.launchUpscaleMode != nil
            if upscaleEnabled && !spatialOn {
                conflicts.append(LaunchEnvIssue(
                    id: "conflict:MULLION_METALFX_SPATIAL_SWAPCHAIN",
                    severity: .warning,
                    category: .conflict,
                    keyOrToken: "MULLION_METALFX_SPATIAL_SWAPCHAIN",
                    message: "MULLION_METALFX_SPATIAL_SWAPCHAIN=\(rawSpatial) disables MetalFX Spatial swapchain upscaling, contradicting this game's Upscaling setting (\(entry.upscaleMode)).",
                    suggestion: "Remove MULLION_METALFX_SPATIAL_SWAPCHAIN or set MetalFX Upscaling to Off in Library Settings."
                ))
            } else if !upscaleEnabled && spatialOn {
                conflicts.append(LaunchEnvIssue(
                    id: "conflict:MULLION_METALFX_SPATIAL_SWAPCHAIN",
                    severity: .warning,
                    category: .conflict,
                    keyOrToken: "MULLION_METALFX_SPATIAL_SWAPCHAIN",
                    message: "MULLION_METALFX_SPATIAL_SWAPCHAIN=\(rawSpatial) forces MetalFX Spatial swapchain upscaling on while this game's Upscaling setting is Off.",
                    suggestion: "Remove MULLION_METALFX_SPATIAL_SWAPCHAIN or pick a MetalFX Upscaling preset (Quality/Balanced/Performance) in Library Settings."
                ))
            }
        }

        return conflicts
    }

    private static func checkExtraArgToken(_ token: String) -> LaunchEnvIssue? {
        let lower = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch lower {
        case "%command%":
            return LaunchEnvIssue(
                id: "syntax:args:steam_command_token",
                severity: .warning,
                category: .syntaxError,
                keyOrToken: "%command%",
                message: "Found leftover Steam launch-option placeholder '%command%' in extra launch arguments.",
                suggestion: "Remove '%command%' — DirectMetal passes Extra Launch Arguments directly to the Windows executable."
            )
        case "gamemoderun":
            return LaunchEnvIssue(
                id: "linux:args:gamemoderun",
                severity: .warning,
                category: .linuxProtonOnly,
                keyOrToken: "gamemoderun",
                message: "'gamemoderun' is a Linux Feral GameMode wrapper command and is not available on macOS.",
                suggestion: "Remove 'gamemoderun'. DirectMetal automatically launches games on Apple Silicon Performance cores with userInteractive QoS and App Nap disabled."
            )
        case "mangohud", "mangohud.x86", "mangohud.x64":
            return LaunchEnvIssue(
                id: "linux:args:mangohud",
                severity: .warning,
                category: .linuxProtonOnly,
                keyOrToken: lower,
                message: "'\(token)' is a Linux MangoHud overlay wrapper command and is not available on macOS.",
                suggestion: "Remove '\(token)' and enable DirectMetal's native Metal Performance HUD (--hud or Metal HUD toggle in Library Settings)."
            )
        case "gamescope":
            return LaunchEnvIssue(
                id: "linux:args:gamescope",
                severity: .warning,
                category: .linuxProtonOnly,
                keyOrToken: "gamescope",
                message: "'gamescope' is a Linux SteamOS micro-compositor wrapper and is not available on macOS.",
                suggestion: "Remove 'gamescope' and its compositor flags. Use DirectMetal's Retina HiDPI toggle, FPS Cap (--fps-cap), MetalFX Upscaling (--upscale), or Virtual Desktop (--desktop WxH) instead."
            )
        case "prime-run":
            return LaunchEnvIssue(
                id: "linux:args:prime-run",
                severity: .warning,
                category: .linuxProtonOnly,
                keyOrToken: "prime-run",
                message: "'prime-run' is a Linux NVIDIA PRIME GPU-offload wrapper and is not used on Apple Silicon macOS.",
                suggestion: "Remove 'prime-run' — Apple Silicon Macs use a unified Metal GPU automatically."
            )
        default:
            return nil
        }
    }

    private static func linuxWrapperInEnvAdvice(forLowercasedToken lower: String) -> String? {
        switch lower {
        case "gamemoderun":
            return "Remove 'gamemoderun'. DirectMetal automatically runs games on Apple Silicon Performance cores with App Nap disabled."
        case "mangohud", "mangohud.x86", "mangohud.x64":
            return "Remove '\(lower)' and enable DirectMetal's native Metal Performance HUD (--hud or Metal HUD toggle)."
        case "gamescope":
            return "Remove 'gamescope'. Use DirectMetal's Retina HiDPI, FPS Cap (--fps-cap), MetalFX Upscaling (--upscale), or Virtual Desktop (--desktop WxH) instead."
        case "prime-run":
            return "Remove 'prime-run' — Apple Silicon Macs use a unified Metal GPU automatically."
        default:
            return nil
        }
    }

    private static func parseEnvBool(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    private static func suggestValidIdentifier(from rawKey: String) -> String {
        var scalars: [UnicodeScalar] = []
        for s in rawKey.unicodeScalars {
            let isASCIIAlpha = (s >= "A" && s <= "Z") || (s >= "a" && s <= "z")
            let isASCIIDigit = (s >= "0" && s <= "9")
            if isASCIIAlpha || isASCIIDigit || s == "_" {
                scalars.append(s)
            } else {
                scalars.append("_")
            }
        }
        var candidate = String(String.UnicodeScalarView(scalars))
        if candidate.isEmpty {
            return "MY_VAR"
        }
        if let first = candidate.unicodeScalars.first, first >= "0" && first <= "9" {
            candidate = "_" + candidate
        }
        return candidate
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
        if text.hasPrefix("`") || text.hasSuffix("`") {
            return "\(fence) \(text) \(fence)"
        }
        return "\(fence)\(text)\(fence)"
    }
}
