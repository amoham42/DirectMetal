import Foundation

// Per-game configuration diff and baseline reset engine.
// Compares a `GameLibraryEntry`'s 10 configurable launch settings against its matching
// community `GameProfile` (or DirectMetal's zero-config defaults when no profile matches),
// formats a CLI diff table, and resets launch settings without touching user identity,
// playtime/favorite state, storefront metadata, or PE inspection fields.

// MARK: - Data model

struct ConfigDiffRow: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let currentValue: String
    let baselineValue: String
    let isModified: Bool
}

struct ConfigDiffReport: Codable, Equatable, Sendable {
    let gameID: String
    let title: String
    let baselineName: String
    let profileID: String?
    let modifiedCount: Int
    let rows: [ConfigDiffRow]

    var hasCustomizations: Bool { modifiedCount > 0 }
}

// MARK: - Diff & baseline reset engine

enum ConfigDiffEngine {
    static let defaultBaselineName = "DirectMetal Zero-Config Defaults"

    /// Resolves the 10 baseline launch settings for a community `GameProfile`,
    /// falling back to `GameLibraryEntry`'s zero-config defaults for unset fields
    /// or when `profile` is `nil`.
    static func baselineSettings(
        for profile: GameProfile?
    ) -> (
        engine: ExecutionEngine,
        perfProfile: PerfProfile,
        dx9Backend: DX9Backend,
        upscaleMode: String,
        fpsCap: Int,
        retinaMode: Bool,
        enableHUD: Bool,
        enableSandbox: Bool,
        extraArgs: String,
        customEnv: String
    ) {
        (
            engine: .auto,
            perfProfile: profile?.perfProfile ?? .balanced,
            dx9Backend: profile?.dx9Backend ?? .auto,
            upscaleMode: normalizeUpscaleMode(profile?.upscaleMode),
            fpsCap: 0,
            retinaMode: profile?.retinaMode ?? true,
            enableHUD: profile?.enableHUD ?? true,
            enableSandbox: profile?.enableSandbox ?? false,
            extraArgs: "",
            customEnv: ""
        )
    }

    /// Compares all 10 configurable launch settings of `entry` against `baselineSettings(for: profile)`.
    static func diff(entry: GameLibraryEntry, profile: GameProfile?) -> ConfigDiffReport {
        let base = baselineSettings(for: profile)

        let currentUpscale = normalizeUpscaleMode(entry.upscaleMode)
        let currentFPSCap = clampFPSCap(entry.fpsCap)
        let currentExtraArgs = normalizeFreeform(entry.extraArgs)
        let currentCustomEnv = normalizeFreeform(entry.customEnv)

        let rows: [ConfigDiffRow] = [
            ConfigDiffRow(
                id: "engine",
                label: "Execution Engine",
                currentValue: entry.engine.rawValue,
                baselineValue: base.engine.rawValue,
                isModified: entry.engine != base.engine
            ),
            ConfigDiffRow(
                id: "perfProfile",
                label: "Performance Profile",
                currentValue: entry.perfProfile.rawValue,
                baselineValue: base.perfProfile.rawValue,
                isModified: entry.perfProfile != base.perfProfile
            ),
            ConfigDiffRow(
                id: "dx9Backend",
                label: "DX9 Backend",
                currentValue: entry.dx9Backend.rawValue,
                baselineValue: base.dx9Backend.rawValue,
                isModified: entry.dx9Backend != base.dx9Backend
            ),
            ConfigDiffRow(
                id: "upscaleMode",
                label: "MetalFX Upscaling",
                currentValue: currentUpscale,
                baselineValue: base.upscaleMode,
                isModified: currentUpscale != base.upscaleMode
            ),
            ConfigDiffRow(
                id: "fpsCap",
                label: "FPS Cap",
                currentValue: formatFPSCap(currentFPSCap),
                baselineValue: formatFPSCap(base.fpsCap),
                isModified: currentFPSCap != base.fpsCap
            ),
            ConfigDiffRow(
                id: "retinaMode",
                label: "Retina HiDPI",
                currentValue: formatBool(entry.retinaMode),
                baselineValue: formatBool(base.retinaMode),
                isModified: entry.retinaMode != base.retinaMode
            ),
            ConfigDiffRow(
                id: "enableHUD",
                label: "Metal HUD",
                currentValue: formatBool(entry.enableHUD),
                baselineValue: formatBool(base.enableHUD),
                isModified: entry.enableHUD != base.enableHUD
            ),
            ConfigDiffRow(
                id: "enableSandbox",
                label: "Seatbelt Sandbox",
                currentValue: formatBool(entry.enableSandbox),
                baselineValue: formatBool(base.enableSandbox),
                isModified: entry.enableSandbox != base.enableSandbox
            ),
            ConfigDiffRow(
                id: "extraArgs",
                label: "Extra Launch Args",
                currentValue: formatFreeform(currentExtraArgs),
                baselineValue: formatFreeform(base.extraArgs),
                isModified: currentExtraArgs != base.extraArgs
            ),
            ConfigDiffRow(
                id: "customEnv",
                label: "Custom Env Vars",
                currentValue: formatFreeform(currentCustomEnv),
                baselineValue: formatFreeform(base.customEnv),
                isModified: currentCustomEnv != base.customEnv
            ),
        ]

        let baselineName: String
        if let profile {
            baselineName = "Community Preset: \(profile.title)"
        } else {
            baselineName = defaultBaselineName
        }

        let modifiedCount = rows.reduce(0) { $0 + ($1.isModified ? 1 : 0) }

        return ConfigDiffReport(
            gameID: entry.id,
            title: entry.title,
            baselineName: baselineName,
            profileID: profile?.id,
            modifiedCount: modifiedCount,
            rows: rows
        )
    }

    /// Restores the 10 configurable launch settings of `entry` to `baselineSettings(for: profile)`
    /// while strictly preserving user identity, prefix assignment, play stats, favorites,
    /// storefront identifiers, and PE auto-detection fields.
    static func resetSettings(of entry: inout GameLibraryEntry, using profile: GameProfile?) {
        let base = baselineSettings(for: profile)
        entry.engine = base.engine
        entry.perfProfile = base.perfProfile
        entry.dx9Backend = base.dx9Backend
        entry.upscaleMode = base.upscaleMode
        entry.fpsCap = base.fpsCap
        entry.retinaMode = base.retinaMode
        entry.enableHUD = base.enableHUD
        entry.enableSandbox = base.enableSandbox
        entry.extraArgs = base.extraArgs
        entry.customEnv = base.customEnv
        if let profile {
            entry.profileID = profile.id
            entry.profileNote = profile.notes ?? "Community preset: \(profile.title)"
        } else {
            entry.profileID = nil
            entry.profileNote = nil
        }
    }

    /// Renders a crisp CLI diff table with `*` on customized rows and ` ` on baseline rows.
    static func formatText(_ report: ConfigDiffReport) -> String {
        let labelHeader = "SETTING"
        let currentHeader = "CURRENT"
        let baselineHeader = "BASELINE"

        let labelWidth = max(labelHeader.count, report.rows.map(\.label.count).max() ?? 0)
        let currentWidth = min(max(currentHeader.count, report.rows.map(\.currentValue.count).max() ?? 0), 40)
        let baselineWidth = min(max(baselineHeader.count, report.rows.map(\.baselineValue.count).max() ?? 0), 40)

        var lines: [String] = []
        lines.append("DirectMetal Config Diff — \(report.title) (\(report.gameID))")
        if let profileID = report.profileID, !profileID.isEmpty {
            lines.append("Baseline: \(report.baselineName) [\(profileID)]")
        } else {
            lines.append("Baseline: \(report.baselineName)")
        }
        if report.hasCustomizations {
            let noun = report.rows.count == 1 ? "setting" : "settings"
            lines.append("Status:   \(report.modifiedCount) of \(report.rows.count) \(noun) customized")
        } else {
            lines.append("Status:   matches baseline (0 customized)")
        }
        lines.append("")
        lines.append(
            "  \(pad(labelHeader, to: labelWidth))  \(pad(currentHeader, to: currentWidth))  \(baselineHeader)"
        )
        lines.append(
            "  \(String(repeating: "-", count: labelWidth))  \(String(repeating: "-", count: currentWidth))  \(String(repeating: "-", count: baselineWidth))"
        )

        for row in report.rows {
            let marker = row.isModified ? "*" : " "
            lines.append(
                "\(marker) \(pad(row.label, to: labelWidth))  \(pad(row.currentValue, to: currentWidth))  \(row.baselineValue)"
            )
        }

        if report.hasCustomizations {
            lines.append("")
            lines.append("Legend: * customized from baseline")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Normalization & formatting helpers

    private static func normalizeUpscaleMode(_ raw: String?) -> String {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else {
            return "off"
        }
        return trimmed
    }

    private static func clampFPSCap(_ value: Int) -> Int {
        max(0, min(value, 360))
    }

    private static func normalizeFreeform(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatFPSCap(_ cap: Int) -> String {
        cap > 0 ? "\(cap) FPS" : "Uncapped"
    }

    private static func formatBool(_ value: Bool) -> String {
        value ? "on" : "off"
    }

    private static func formatFreeform(_ value: String) -> String {
        value.isEmpty ? "(none)" : value
    }

    private static func pad(_ text: String, to width: Int) -> String {
        guard text.count < width else { return text }
        return text + String(repeating: " ", count: width - text.count)
    }
}
