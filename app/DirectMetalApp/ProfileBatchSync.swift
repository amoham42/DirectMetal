import Foundation

// Batch Community Profile Sync Engine.
// Scans a `[GameLibraryEntry]` library against `GameProfileRegistry`, detects user
// customizations via `ConfigDiffEngine.diff`, applies matching community presets while
// protecting customized games unless `overwriteCustomized` is enabled, supports non-mutating
// `dryRun` previews, and formats both CLI text and Markdown reports.

// MARK: - Data model

/// Outcome recorded for each game processed by `ProfileBatchSync.sync`.
enum ProfileSyncAction: String, Codable, Equatable, CaseIterable, Sendable {
    /// A community profile matched and updated (or would update in dry-run) the entry.
    case applied
    /// The entry already matched the community profile with identical settings.
    case alreadyMatched
    /// The entry had user customizations differing from its current baseline and `overwriteCustomized == false`.
    case skippedCustomized
    /// No community profile matched the entry.
    case noMatch
}

/// Per-game outcome entry in a `ProfileBatchSyncReport`.
struct ProfileSyncItem: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let gameID: String
    let title: String
    let profileID: String?
    let profileTitle: String?
    let action: ProfileSyncAction
    let changedFields: [String]
    let reason: String
}

/// Summary report returned by `ProfileBatchSync.sync`.
struct ProfileBatchSyncReport: Codable, Equatable, Sendable {
    let scannedCount: Int
    let appliedCount: Int
    let alreadyMatchedCount: Int
    let skippedCustomizedCount: Int
    let unmatchedCount: Int
    let dryRun: Bool
    let overwriteCustomized: Bool
    let items: [ProfileSyncItem]
}

// MARK: - Batch profile sync engine

enum ProfileBatchSync {
    /// Synchronizes every entry in `library` against community profiles from `registry`.
    ///
    /// For each game:
    /// 1. Resolves its matching `GameProfile` using `registry.match(title:exePath:steamAppID:storeSource:storeGameID:)`.
    /// 2. If no profile matches, records `.noMatch` and leaves the entry untouched.
    /// 3. Resolves the entry's previous baseline profile via `entry.profileID.flatMap { registry.profile(id: $0) }`
    ///    and checks for user customizations with `ConfigDiffEngine.diff(entry:profile:).hasCustomizations`.
    /// 4. Computes exact `changedFields` against `ConfigDiffEngine.baselineSettings(for: matchedProfile)` and
    ///    `matchedProfile.id`:
    ///    - Always compares `profileID`, `perfProfile`, `dx9Backend`, `upscaleMode`, `retinaMode`,
    ///      `enableHUD`, and `enableSandbox`.
    ///    - When `overwriteCustomized == true`, also compares `engine`, `fpsCap`, `extraArgs`, and
    ///      `customEnv` because all 10 configurable launch settings are reset to the matched profile's
    ///      clean baseline via `ConfigDiffEngine.resetSettings(of:using:)`.
    /// 5. If `entry.profileID == matchedProfile.id` and `changedFields.isEmpty`, records `.alreadyMatched`.
    /// 6. Else if the entry has user customizations against its previous baseline and `!overwriteCustomized`,
    ///    records `.skippedCustomized` (naming the modified fields in `reason`) and leaves the entry untouched.
    /// 7. Else records `.applied` with the exact `changedFields` list. When `!dryRun`:
    ///    - If `overwriteCustomized == true`, resets all 10 launch settings plus `profileID`/`profileNote`
    ///      via `ConfigDiffEngine.resetSettings(of:using:)`.
    ///    - If `overwriteCustomized == false`, applies the matched profile's baseline values for
    ///      `perfProfile`, `dx9Backend`, `upscaleMode`, `retinaMode`, `enableHUD`, `enableSandbox`,
    ///      `profileID`, and `profileNote` while keeping `engine`, `fpsCap`, `extraArgs`, and `customEnv` untouched.
    ///
    /// Never overwrites `id`, `title`, `exePath`, `prefixName`, `playCount`, `totalPlaySeconds`,
    /// `lastPlayedUtc`, `isFavorite`, `storeSource`, `storeGameID`, `steamAppID`, `architecture`,
    /// `detectedAPIs`, `detectedUpscalers`, or `buildHash`.
    static func sync(
        library: inout [GameLibraryEntry],
        registry: GameProfileRegistry = .shared,
        overwriteCustomized: Bool = false,
        dryRun: Bool = false
    ) -> ProfileBatchSyncReport {
        var items: [ProfileSyncItem] = []
        items.reserveCapacity(library.count)

        var appliedCount = 0
        var alreadyMatchedCount = 0
        var skippedCustomizedCount = 0
        var unmatchedCount = 0

        for idx in library.indices {
            let entry = library[idx]

            guard let matchedProfile = registry.match(
                title: entry.title,
                exePath: entry.exePath,
                steamAppID: entry.steamAppID,
                storeSource: entry.storeSource,
                storeGameID: entry.storeGameID
            ) else {
                unmatchedCount += 1
                items.append(ProfileSyncItem(
                    id: entry.id,
                    gameID: entry.id,
                    title: entry.title,
                    profileID: nil,
                    profileTitle: nil,
                    action: .noMatch,
                    changedFields: [],
                    reason: "No matching community profile found"
                ))
                continue
            }

            let previousProfile = entry.profileID.flatMap { registry.profile(id: $0) }
            let previousDiff = ConfigDiffEngine.diff(entry: entry, profile: previousProfile)
            let targetBaseline = ConfigDiffEngine.baselineSettings(for: matchedProfile)
            let changedFields = computeChangedFields(
                entry: entry,
                matchedProfile: matchedProfile,
                targetBaseline: targetBaseline,
                includeResetFields: overwriteCustomized
            )

            if entry.profileID == matchedProfile.id && changedFields.isEmpty {
                alreadyMatchedCount += 1
                items.append(ProfileSyncItem(
                    id: entry.id,
                    gameID: entry.id,
                    title: entry.title,
                    profileID: matchedProfile.id,
                    profileTitle: matchedProfile.title,
                    action: .alreadyMatched,
                    changedFields: [],
                    reason: "Already matched community profile \"\(matchedProfile.title)\" [\(matchedProfile.id)]"
                ))
                continue
            }

            if previousDiff.hasCustomizations && !overwriteCustomized {
                skippedCustomizedCount += 1
                let customizedFieldIDs = previousDiff.rows.filter(\.isModified).map(\.id)
                let fieldsText = customizedFieldIDs.joined(separator: ", ")
                items.append(ProfileSyncItem(
                    id: entry.id,
                    gameID: entry.id,
                    title: entry.title,
                    profileID: matchedProfile.id,
                    profileTitle: matchedProfile.title,
                    action: .skippedCustomized,
                    changedFields: [],
                    reason: "Skipped: user customized \(fieldsText) (enable overwriteCustomized to apply \"\(matchedProfile.title)\")"
                ))
                continue
            }

            appliedCount += 1
            if !dryRun {
                if overwriteCustomized {
                    ConfigDiffEngine.resetSettings(of: &library[idx], using: matchedProfile)
                } else {
                    applyProfileBaseline(
                        to: &library[idx],
                        profile: matchedProfile,
                        baseline: targetBaseline
                    )
                }
            }

            let fieldsText = changedFields.joined(separator: ", ")
            let reason: String
            if dryRun {
                if overwriteCustomized && previousDiff.hasCustomizations {
                    reason = "Dry run: would overwrite user customizations and apply \"\(matchedProfile.title)\" (\(fieldsText))"
                } else {
                    reason = "Dry run: would apply \"\(matchedProfile.title)\" (\(fieldsText))"
                }
            } else if overwriteCustomized && previousDiff.hasCustomizations {
                reason = "Overwrote user customizations and applied \"\(matchedProfile.title)\" (\(fieldsText))"
            } else {
                reason = "Applied \"\(matchedProfile.title)\" (\(fieldsText))"
            }

            items.append(ProfileSyncItem(
                id: entry.id,
                gameID: entry.id,
                title: entry.title,
                profileID: matchedProfile.id,
                profileTitle: matchedProfile.title,
                action: .applied,
                changedFields: changedFields,
                reason: reason
            ))
        }

        return ProfileBatchSyncReport(
            scannedCount: library.count,
            appliedCount: appliedCount,
            alreadyMatchedCount: alreadyMatchedCount,
            skippedCustomizedCount: skippedCustomizedCount,
            unmatchedCount: unmatchedCount,
            dryRun: dryRun,
            overwriteCustomized: overwriteCustomized,
            items: items
        )
    }

    /// Formats a `ProfileBatchSyncReport` as an aligned plain-text CLI table.
    static func formatText(_ report: ProfileBatchSyncReport) -> String {
        var lines: [String] = []
        let headerSuffix = report.dryRun ? " (Dry Run)" : ""
        lines.append("DirectMetal Community Profile Batch Sync\(headerSuffix)")
        lines.append(
            "Mode:     \(report.dryRun ? "dry-run" : "apply") | Overwrite customized: \(report.overwriteCustomized ? "yes" : "no")"
        )
        lines.append(
            "Summary:  \(report.scannedCount) scanned, \(report.appliedCount) applied, \(report.alreadyMatchedCount) already matched, \(report.skippedCustomizedCount) skipped (customized), \(report.unmatchedCount) unmatched"
        )

        guard !report.items.isEmpty else {
            lines.append("")
            lines.append("No games in library.")
            return lines.joined(separator: "\n") + "\n"
        }

        let actionHeader = "ACTION"
        let titleHeader = "GAME"
        let profileHeader = "PROFILE"
        let detailsHeader = "DETAILS"

        let actionLabels = report.items.map { textActionLabel($0.action) }
        let profileLabels = report.items.map { item -> String in
            if let profileID = item.profileID, let profileTitle = item.profileTitle {
                return "\(profileTitle) [\(profileID)]"
            }
            return item.profileID ?? "-"
        }

        let actionWidth = max(actionHeader.count, actionLabels.map(\.count).max() ?? 0)
        let titleWidth = min(max(titleHeader.count, report.items.map(\.title.count).max() ?? 0), 36)
        let profileWidth = min(max(profileHeader.count, profileLabels.map(\.count).max() ?? 0), 36)

        lines.append("")
        lines.append(
            "  \(pad(actionHeader, to: actionWidth))  \(pad(titleHeader, to: titleWidth))  \(pad(profileHeader, to: profileWidth))  \(detailsHeader)"
        )
        lines.append(
            "  \(String(repeating: "-", count: actionWidth))  \(String(repeating: "-", count: titleWidth))  \(String(repeating: "-", count: profileWidth))  \(String(repeating: "-", count: detailsHeader.count))"
        )

        for (index, item) in report.items.enumerated() {
            let marker = textActionMarker(item.action)
            let actionCol = pad(actionLabels[index], to: actionWidth)
            let titleCol = pad(truncate(item.title, maxLength: titleWidth), to: titleWidth)
            let profileCol = pad(truncate(profileLabels[index], maxLength: profileWidth), to: profileWidth)
            lines.append("\(marker) \(actionCol)  \(titleCol)  \(profileCol)  \(item.reason)")
        }

        lines.append("")
        lines.append("Legend: + applied, = already matched, ! skipped (customized), - no match")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Formats a `ProfileBatchSyncReport` as a GitHub-Flavored Markdown report.
    static func formatMarkdown(_ report: ProfileBatchSyncReport) -> String {
        var lines: [String] = []
        let headerSuffix = report.dryRun ? " (Dry Run)" : ""
        lines.append("## DirectMetal Community Profile Batch Sync\(headerSuffix)")
        lines.append("")
        lines.append("- **Mode:** \(report.dryRun ? "Dry Run" : "Apply")")
        lines.append("- **Overwrite Customized:** \(report.overwriteCustomized ? "Yes" : "No")")
        lines.append("- **Scanned:** \(report.scannedCount)")
        lines.append("- **Applied:** \(report.appliedCount)")
        lines.append("- **Already Matched:** \(report.alreadyMatchedCount)")
        lines.append("- **Skipped (Customized):** \(report.skippedCustomizedCount)")
        lines.append("- **Unmatched:** \(report.unmatchedCount)")

        guard !report.items.isEmpty else {
            lines.append("")
            lines.append("_No games in library._")
            return lines.joined(separator: "\n") + "\n"
        }

        lines.append("")
        lines.append("| Action | Game | Profile | Changed Fields | Reason |")
        lines.append("| --- | --- | --- | --- | --- |")

        for item in report.items {
            let actionCell = "`\(item.action.rawValue)`"
            let gameCell = escapeMarkdownCell(item.title)
            let profileCell: String
            if let profileID = item.profileID, let profileTitle = item.profileTitle {
                profileCell = "\(escapeMarkdownCell(profileTitle)) (`\(escapeMarkdownCell(profileID))`)"
            } else if let profileID = item.profileID {
                profileCell = "`\(escapeMarkdownCell(profileID))`"
            } else {
                profileCell = "—"
            }
            let changedCell = item.changedFields.isEmpty
                ? "—"
                : item.changedFields.map { "`\(escapeMarkdownCell($0))`" }.joined(separator: ", ")
            let reasonCell = escapeMarkdownCell(item.reason)
            lines.append("| \(actionCell) | \(gameCell) | \(profileCell) | \(changedCell) | \(reasonCell) |")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Internal comparison & application helpers

    private static func computeChangedFields(
        entry: GameLibraryEntry,
        matchedProfile: GameProfile,
        targetBaseline: (
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
        ),
        includeResetFields: Bool
    ) -> [String] {
        var changed: [String] = []
        if entry.profileID != matchedProfile.id {
            changed.append("profileID")
        }
        if includeResetFields && entry.engine != targetBaseline.engine {
            changed.append("engine")
        }
        if entry.perfProfile != targetBaseline.perfProfile {
            changed.append("perfProfile")
        }
        if entry.dx9Backend != targetBaseline.dx9Backend {
            changed.append("dx9Backend")
        }
        if normalizeUpscaleMode(entry.upscaleMode) != targetBaseline.upscaleMode {
            changed.append("upscaleMode")
        }
        if includeResetFields && clampFPSCap(entry.fpsCap) != targetBaseline.fpsCap {
            changed.append("fpsCap")
        }
        if entry.retinaMode != targetBaseline.retinaMode {
            changed.append("retinaMode")
        }
        if entry.enableHUD != targetBaseline.enableHUD {
            changed.append("enableHUD")
        }
        if entry.enableSandbox != targetBaseline.enableSandbox {
            changed.append("enableSandbox")
        }
        if includeResetFields && normalizeFreeform(entry.extraArgs) != targetBaseline.extraArgs {
            changed.append("extraArgs")
        }
        if includeResetFields && normalizeFreeform(entry.customEnv) != targetBaseline.customEnv {
            changed.append("customEnv")
        }
        return changed
    }

    private static func applyProfileBaseline(
        to entry: inout GameLibraryEntry,
        profile: GameProfile,
        baseline: (
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
        )
    ) {
        entry.perfProfile = baseline.perfProfile
        entry.dx9Backend = baseline.dx9Backend
        entry.upscaleMode = baseline.upscaleMode
        entry.retinaMode = baseline.retinaMode
        entry.enableHUD = baseline.enableHUD
        entry.enableSandbox = baseline.enableSandbox
        entry.profileID = profile.id
        entry.profileNote = profile.notes ?? "Community preset: \(profile.title)"
    }

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

    private static func textActionMarker(_ action: ProfileSyncAction) -> String {
        switch action {
        case .applied: return "+"
        case .alreadyMatched: return "="
        case .skippedCustomized: return "!"
        case .noMatch: return "-"
        }
    }

    private static func textActionLabel(_ action: ProfileSyncAction) -> String {
        switch action {
        case .applied: return "APPLIED"
        case .alreadyMatched: return "MATCHED"
        case .skippedCustomized: return "SKIPPED"
        case .noMatch: return "NO_MATCH"
        }
    }

    private static func truncate(_ text: String, maxLength: Int) -> String {
        guard maxLength >= 2, text.count > maxLength else { return text }
        return String(text.prefix(maxLength - 1)) + "…"
    }

    private static func pad(_ text: String, to width: Int) -> String {
        guard text.count < width else { return text }
        return text + String(repeating: " ", count: width - text.count)
    }

    private static func escapeMarkdownCell(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
