import Foundation

// Custom Local Game Profile Overlay Manager & Community PR Snippet Exporter.
// Manages the user's local `~/Library/Application Support/DirectMetal/game_profiles.json`
// overlay (`directmetal.game_profiles.v1`), drafts valid profiles from tuned
// `GameLibraryEntry` records, enforces the same schema and hygiene rules as
// `scripts/validate_profiles.py`, and exports clean JSON snippets ready for
// community PRs against `runtime/profiles/game_profiles.json`.

// MARK: - GameProfile memberwise initializer

extension GameProfile {
    /// Memberwise initializer for constructing and editing `GameProfile` values directly in Swift
    /// (the struct's custom `init(from:)` decoder suppresses the compiler-synthesized initializer).
    init(
        id: String,
        title: String,
        matchTitles: [String] = [],
        matchExeNames: [String] = [],
        steamAppIds: [String] = [],
        perfProfile: PerfProfile? = nil,
        dx9Backend: DX9Backend? = nil,
        upscaleMode: String? = nil,
        retinaMode: Bool? = nil,
        enableHUD: Bool? = nil,
        enableSandbox: Bool? = nil,
        status: String? = nil,
        notes: String? = nil,
        verifiedOn: [String] = ["preset"],
        gameEngine: String? = nil,
        stores: [String] = [],
        gogGameIds: [String] = [],
        epicAppNames: [String] = []
    ) {
        self.id = id
        self.title = title
        self.matchTitles = matchTitles
        self.matchExeNames = matchExeNames
        self.steamAppIds = steamAppIds
        self.perfProfile = perfProfile
        self.dx9Backend = dx9Backend
        self.upscaleMode = upscaleMode
        self.retinaMode = retinaMode
        self.enableHUD = enableHUD
        self.enableSandbox = enableSandbox
        self.status = status
        self.notes = notes
        self.verifiedOn = verifiedOn
        self.gameEngine = gameEngine
        self.stores = stores
        self.gogGameIds = gogGameIds
        self.epicAppNames = epicAppNames
    }
}

// MARK: - Errors & Document Model

/// Errors thrown while validating, loading, mutating, or exporting local user game profile overlays.
enum UserProfileOverlayError: Error, LocalizedError, Equatable, Sendable {
    case validationFailed([String])
    case profileNotFound(String)
    case invalidOverlayFile(String)

    var errorDescription: String? {
        switch self {
        case .validationFailed(let issues):
            return "Game profile validation failed: \(issues.joined(separator: "; "))"
        case .profileNotFound(let id):
            return "User game profile not found: '\(id)'"
        case .invalidOverlayFile(let detail):
            return "Invalid user game profile overlay file: \(detail)"
        }
    }
}

/// On-disk representation of `<supportRoot>/game_profiles.json` (`directmetal.game_profiles.v1`).
struct UserProfileOverlayDocument: Codable, Equatable, Sendable {
    let schema: String
    var profiles: [GameProfile]

    init(schema: String = GameProfileRegistry.schemaID, profiles: [GameProfile] = []) {
        self.schema = schema
        self.profiles = profiles
    }
}

// MARK: - User Profile Overlay Manager

enum UserProfileOverlayManager {
    static let schemaID = GameProfileRegistry.schemaID
    static let maxSlugLength = 64
    static let minimumNotesLength = 10
    static let fallbackSlug = "custom-game"

    /// Allowed `status` values, matching `scripts/validate_profiles.py`.
    static let validStatuses: Set<String> = [
        "playable",
        "preset",
        "needs-steam-login",
    ]

    /// Allowed `stores` entries, matching `scripts/validate_profiles.py`.
    static let validStores: Set<String> = [
        "steam",
        "gog",
        "epic",
    ]

    /// Generic launcher, installer, anti-cheat, and boilerplate executable names rejected
    /// from `matchExeNames` so a profile never collides with unrelated titles.
    static let genericExecutableNames: Set<String> = [
        "game.exe",
        "launcher.exe",
        "setup.exe",
        "start.exe",
        "shipping.exe",
        "start_protected_game.exe",
        "unins000.exe",
        "steam.exe",
        "dxsetup.exe",
        "vcredist_x64.exe",
    ]

    /// Resolves `~/Library/Application Support/DirectMetal/game_profiles.json`
    /// using the exact same `$HOME` / `DIRECTMETAL_LIBRARY_DIR` logic as `GameProfileRegistry`.
    static func defaultOverlayURL() -> URL {
        GameLibraryManager.defaultSupportRoot()
            .appendingPathComponent(GameProfileRegistry.fileName)
    }

    /// Converts an arbitrary display title into a deterministic lowercase kebab-case slug
    /// matching `^[a-z0-9]+(?:-[a-z0-9]+)*$` and capped at `maxSlugLength` (64) characters.
    static func slugify(_ title: String) -> String {
        let folded = title
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()

        // Drop apostrophes before splitting so "Baldur's Gate 3" becomes "baldurs-gate-3".
        let apostrophes: Set<Unicode.Scalar> = ["'", "\u{2018}", "\u{2019}", "`"]
        var result = ""
        result.reserveCapacity(min(folded.count, maxSlugLength))

        var pendingHyphen = false
        for scalar in folded.unicodeScalars {
            if apostrophes.contains(scalar) {
                continue
            }
            let v = scalar.value
            let isLowerAlpha = v >= 97 && v <= 122 // 'a'...'z'
            let isDigit = v >= 48 && v <= 57       // '0'...'9'
            if isLowerAlpha || isDigit {
                if pendingHyphen && !result.isEmpty {
                    result.append("-")
                }
                pendingHyphen = false
                result.append(Character(scalar))
            } else if !result.isEmpty {
                pendingHyphen = true
            }
        }

        if result.count > maxSlugLength {
            result = String(result.prefix(maxSlugLength))
            while result.hasSuffix("-") {
                result.removeLast()
            }
        }

        return result.isEmpty ? fallbackSlug : result
    }

    /// Builds a schema-valid `GameProfile` seeded from a tuned `GameLibraryEntry`.
    ///
    /// Honest verification rule:
    /// - Sets `status: "playable"` and `verifiedOn: ["<gpuName> (macOS <macosVersion>)"]`
    ///   ONLY when `markVerifiedOnCurrentHardware == true` AND `hardware` supplies non-empty
    ///   GPU and macOS version metadata.
    /// - Otherwise sets `status: "preset"` and `verifiedOn: ["preset"]`.
    static func draftProfile(
        from entry: GameLibraryEntry,
        hardware: MetalHardwareInfo? = nil,
        notes: String? = nil,
        markVerifiedOnCurrentHardware: Bool = false
    ) -> GameProfile {
        let trimmedTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let derivedTitle = GameLibraryManager.deriveTitle(exePath: entry.exePath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = !trimmedTitle.isEmpty ? trimmedTitle : (!derivedTitle.isEmpty ? derivedTitle : "Custom Game")

        let profileID: String
        if let existingID = entry.profileID?.trimmingCharacters(in: .whitespacesAndNewlines),
           isValidSlug(existingID)
        {
            profileID = existingID
        } else {
            profileID = slugify(title)
        }

        // Include executable name only when it is a concrete, non-generic `.exe` file name.
        let exeName = URL(fileURLWithPath: entry.exePath)
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let matchExeNames: [String]
        if !exeName.isEmpty,
           exeName.lowercased().hasSuffix(".exe"),
           !genericExecutableNames.contains(exeName.lowercased())
        {
            matchExeNames = [exeName]
        } else {
            matchExeNames = []
        }

        // Normalize storefront identifiers.
        let steamID = entry.steamAppID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let steamAppIds = (!steamID.isEmpty && isASCIIUnsignedInteger(steamID)) ? [steamID] : []

        let storeSource = entry.storeSource?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let storeGameID = entry.storeGameID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let gogGameIds: [String]
        if storeSource == "gog", !storeGameID.isEmpty, isASCIIUnsignedInteger(storeGameID) {
            gogGameIds = [storeGameID]
        } else {
            gogGameIds = []
        }

        let epicAppNames: [String]
        if storeSource == "epic", !storeGameID.isEmpty {
            epicAppNames = [storeGameID]
        } else {
            epicAppNames = []
        }

        var stores: [String] = []
        if !steamAppIds.isEmpty || storeSource == "steam" {
            stores.append("steam")
        }
        if !gogGameIds.isEmpty || storeSource == "gog" {
            stores.append("gog")
        }
        if !epicAppNames.isEmpty || storeSource == "epic" {
            stores.append("epic")
        }

        let normalizedUpscale = entry.upscaleMode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let upscaleMode = GameProfile.upscaleModes.contains(normalizedUpscale) ? normalizedUpscale : "off"

        // Honest status / verification metadata.
        let status: String
        let verifiedOn: [String]
        if markVerifiedOnCurrentHardware, let hw = hardware {
            let gpu = hw.gpuName.trimmingCharacters(in: .whitespacesAndNewlines)
            let osVersion = hw.macosVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            if !gpu.isEmpty && !osVersion.isEmpty {
                status = "playable"
                verifiedOn = ["\(gpu) (macOS \(osVersion))"]
            } else {
                status = "preset"
                verifiedOn = ["preset"]
            }
        } else {
            status = "preset"
            verifiedOn = ["preset"]
        }

        let resolvedNotes: String
        if let customNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !customNotes.isEmpty {
            resolvedNotes = customNotes
        } else {
            let apiSummary = entry.detectedAPIs.isEmpty
                ? ""
                : " Detected APIs: \(entry.detectedAPIs.joined(separator: ", "))."
            let settingsSummary = "perf=\(entry.perfProfile.rawValue), dx9=\(entry.dx9Backend.rawValue), upscale=\(upscaleMode), retina=\(entry.retinaMode ? "on" : "off"), sandbox=\(entry.enableSandbox ? "on" : "off")."
            if status == "playable", let hwLabel = verifiedOn.first {
                resolvedNotes = "User-verified on \(hwLabel): \(settingsSummary)\(apiSummary)"
            } else {
                resolvedNotes = "User starter preset (untested): \(settingsSummary)\(apiSummary)"
            }
        }

        return GameProfile(
            id: profileID,
            title: title,
            matchTitles: [title],
            matchExeNames: matchExeNames,
            steamAppIds: steamAppIds,
            perfProfile: entry.perfProfile,
            dx9Backend: entry.dx9Backend,
            upscaleMode: upscaleMode,
            retinaMode: entry.retinaMode,
            enableHUD: entry.enableHUD,
            enableSandbox: entry.enableSandbox,
            status: status,
            notes: resolvedNotes,
            verifiedOn: verifiedOn,
            gameEngine: nil,
            stores: stores,
            gogGameIds: gogGameIds,
            epicAppNames: epicAppNames
        )
    }

    /// Validates a `GameProfile` against the `directmetal.game_profiles.v1` schema and hygiene rules
    /// enforced by `scripts/validate_profiles.py`. Returns an empty array when valid.
    static func validate(_ profile: GameProfile) -> [String] {
        var errors: [String] = []

        if !isValidSlug(profile.id) {
            errors.append("Invalid id '\(profile.id)' (expected lowercase kebab-case matching ^[a-z0-9]+(?:-[a-z0-9]+)*$, max \(maxSlugLength) chars)")
        }

        if profile.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Missing non-empty title")
        }

        // Validate matcher lists have no blank entries and at least one matcher exists.
        let matcherFields: [(String, [String])] = [
            ("matchTitles", profile.matchTitles),
            ("matchExeNames", profile.matchExeNames),
            ("steamAppIds", profile.steamAppIds),
            ("gogGameIds", profile.gogGameIds),
            ("epicAppNames", profile.epicAppNames),
        ]
        var totalMatchers = 0
        for (fieldName, values) in matcherFields {
            totalMatchers += values.count
            if values.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                errors.append("\(fieldName) must contain only non-empty strings")
            }
        }
        if totalMatchers == 0 {
            errors.append("Profile must define at least one matcher (matchTitles, matchExeNames, steamAppIds, gogGameIds, or epicAppNames)")
        }

        for exe in profile.matchExeNames {
            let trimmed = exe.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.contains("/") || trimmed.contains("\\") {
                errors.append("matchExeNames entry '\(exe)' must be a bare executable file name without path separators")
            }
            let lower = trimmed.lowercased()
            if genericExecutableNames.contains(lower) {
                errors.append("Generic executable '\(exe)' must not be used in matchExeNames")
            }
            if !lower.hasSuffix(".exe") {
                errors.append("matchExeNames entry '\(exe)' must end with .exe")
            }
        }

        for steamID in profile.steamAppIds {
            let trimmed = steamID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !isASCIIUnsignedInteger(trimmed) {
                errors.append("steamAppIds entry '\(steamID)' must be numeric")
            }
        }

        for gogID in profile.gogGameIds {
            let trimmed = gogID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !isASCIIUnsignedInteger(trimmed) {
                errors.append("gogGameIds entry '\(gogID)' must be numeric")
            }
        }

        if profile.perfProfile == nil {
            errors.append("perfProfile must be specified ('balanced' or 'ultra')")
        }

        if profile.dx9Backend == nil {
            errors.append("dx9Backend must be specified ('auto', 'dxvk', or 'wined3d')")
        }

        if let mode = profile.upscaleMode {
            if !GameProfile.upscaleModes.contains(mode) {
                errors.append("Invalid upscaleMode '\(mode)' (expected one of: off, quality, balanced, performance, ultra_performance)")
            }
        } else {
            errors.append("upscaleMode must be specified (off, quality, balanced, performance, or ultra_performance)")
        }

        if profile.retinaMode == nil {
            errors.append("retinaMode must be a boolean")
        }
        if profile.enableHUD == nil {
            errors.append("enableHUD must be a boolean")
        }
        if profile.enableSandbox == nil {
            errors.append("enableSandbox must be a boolean")
        }

        for store in profile.stores {
            if !validStores.contains(store) {
                errors.append("Invalid store '\(store)' (expected one of: epic, gog, steam)")
            }
        }

        let validStatus: String?
        if let status = profile.status, validStatuses.contains(status) {
            validStatus = status
        } else {
            let shown = profile.status ?? "nil"
            errors.append("Invalid status '\(shown)' (expected one of: playable, preset, needs-steam-login)")
            validStatus = nil
        }

        let hasEmptyVerified = profile.verifiedOn.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if profile.verifiedOn.isEmpty || hasEmptyVerified {
            errors.append("verifiedOn must be a non-empty list of non-empty strings")
        } else if let status = validStatus {
            if status == "preset" {
                if profile.verifiedOn != ["preset"] {
                    errors.append("Untested preset (status 'preset') must use verifiedOn=[\"preset\"]")
                }
            } else {
                let containsPresetToken = profile.verifiedOn.contains {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "preset"
                }
                if containsPresetToken {
                    errors.append("Status '\(status)' must specify tested hardware/OS in verifiedOn rather than \"preset\"")
                }
            }
        }

        if let notes = profile.notes {
            if notes.trimmingCharacters(in: .whitespacesAndNewlines).count < minimumNotesLength {
                errors.append("notes must be a descriptive string of at least \(minimumNotesLength) characters")
            }
        } else {
            errors.append("notes must be a descriptive string of at least \(minimumNotesLength) characters")
        }

        return errors
    }

    /// Loads the user overlay document at `url`, returning an empty `directmetal.game_profiles.v1`
    /// document if the file does not yet exist.
    static func loadOverlay(from url: URL = defaultOverlayURL()) throws -> UserProfileOverlayDocument {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return UserProfileOverlayDocument(schema: schemaID, profiles: [])
        }
        if isDir.boolValue {
            throw UserProfileOverlayError.invalidOverlayFile("Expected a JSON file but found a directory at \(url.path)")
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw UserProfileOverlayError.invalidOverlayFile("Could not read \(url.path): \(error.localizedDescription)")
        }

        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw UserProfileOverlayError.invalidOverlayFile("Malformed JSON in \(url.path): \(error.localizedDescription)")
        }

        guard let root = jsonObject as? [String: Any] else {
            throw UserProfileOverlayError.invalidOverlayFile("Root JSON value must be an object")
        }

        guard let schema = root["schema"] as? String else {
            throw UserProfileOverlayError.invalidOverlayFile("Missing or non-string 'schema' field")
        }
        guard schema == schemaID else {
            throw UserProfileOverlayError.invalidOverlayFile("Unexpected schema '\(schema)' (expected '\(schemaID)')")
        }
        guard root["profiles"] is [Any] else {
            throw UserProfileOverlayError.invalidOverlayFile("Missing or non-array 'profiles' field")
        }

        let document: UserProfileOverlayDocument
        do {
            document = try JSONDecoder().decode(UserProfileOverlayDocument.self, from: data)
        } catch {
            throw UserProfileOverlayError.invalidOverlayFile("Failed to decode profiles: \(error.localizedDescription)")
        }

        var seenIDs = Set<String>()
        for profile in document.profiles {
            if !seenIDs.insert(profile.id).inserted {
                throw UserProfileOverlayError.invalidOverlayFile("Duplicate profile id '\(profile.id)'")
            }
        }

        return document
    }

    /// Validates `profile`, replaces any existing profile with the same `id` (or appends cleanly),
    /// and atomically writes pretty-printed sorted JSON to `url`.
    @discardableResult
    static func upsert(
        _ profile: GameProfile,
        at url: URL = defaultOverlayURL()
    ) throws -> UserProfileOverlayDocument {
        let issues = validate(profile)
        if !issues.isEmpty {
            throw UserProfileOverlayError.validationFailed(issues)
        }

        var document = try loadOverlay(from: url)
        if let existingIndex = document.profiles.firstIndex(where: { $0.id == profile.id }) {
            document.profiles[existingIndex] = profile
        } else {
            document.profiles.append(profile)
        }

        try writeOverlay(document, to: url)
        return document
    }

    /// Removes the profile matching `id` from the overlay document at `url` and atomically writes
    /// the updated document. Throws `UserProfileOverlayError.profileNotFound` if `id` is absent.
    @discardableResult
    static func remove(
        id: String,
        at url: URL = defaultOverlayURL()
    ) throws -> UserProfileOverlayDocument {
        let targetID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        var document = try loadOverlay(from: url)
        guard let existingIndex = document.profiles.firstIndex(where: { $0.id == targetID }) else {
            throw UserProfileOverlayError.profileNotFound(targetID)
        }
        document.profiles.remove(at: existingIndex)
        try writeOverlay(document, to: url)
        return document
    }

    /// Validates `profile` and formats clean, pretty-printed, key-sorted JSON ready to paste
    /// into a GitHub PR targeting `runtime/profiles/game_profiles.json`.
    static func exportPRSnippet(_ profile: GameProfile) throws -> String {
        let issues = validate(profile)
        if !issues.isEmpty {
            throw UserProfileOverlayError.validationFailed(issues)
        }
        let data = try makeEncoder().encode(profile)
        guard let json = String(data: data, encoding: .utf8) else {
            throw UserProfileOverlayError.invalidOverlayFile("Failed to encode profile snippet as UTF-8")
        }
        return json
    }

    // MARK: - Private helpers

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func writeOverlay(_ document: UserProfileOverlayDocument, to url: URL) throws {
        var data = try makeEncoder().encode(document)
        if data.last != 0x0A {
            data.append(0x0A)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    /// Checks `^[a-z0-9]+(?:-[a-z0-9]+)*$` with length `1...maxSlugLength`.
    private static func isValidSlug(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= maxSlugLength else { return false }

        var previousWasHyphen = true // forbids leading hyphen
        for scalar in scalars {
            let v = scalar.value
            let isLowerAlpha = v >= 97 && v <= 122
            let isDigit = v >= 48 && v <= 57
            if isLowerAlpha || isDigit {
                previousWasHyphen = false
            } else if v == 45 { // '-'
                if previousWasHyphen {
                    return false
                }
                previousWasHyphen = true
            } else {
                return false
            }
        }
        return !previousWasHyphen // forbids trailing hyphen
    }

    private static func isASCIIUnsignedInteger(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }
}
