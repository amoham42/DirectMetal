import CryptoKit
import Foundation

// MARK: - Library entry (per-game saved settings)

struct GameLibraryEntry: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var exePath: String
    var prefixName: String
    var engine: ExecutionEngine
    var perfProfile: PerfProfile
    var dx9Backend: DX9Backend
    var upscaleMode: String
    var retinaMode: Bool
    var enableHUD: Bool
    var enableSandbox: Bool
    var extraArgs: String
    var architecture: String
    var detectedAPIs: [String]
    var detectedUpscalers: [String]
    var buildHash: String
    var playCount: Int
    var lastPlayedUtc: String?
    /// Steam app ID discovered from the Steam library manifest / `steam_appid.txt` (artwork + profile matching).
    var steamAppID: String?
    /// Community game profile (`runtime/profiles/game_profiles.json`) that seeded this entry's settings.
    var profileID: String?
    var profileNote: String?
    /// Storefront that installed the game: `steam`, `gog`, `epic` or `standalone` (`nil` = not yet detected).
    var storeSource: String?
    /// Store-specific ID: GOG `gameId`, Epic `AppName` (Steam IDs live in `steamAppID`).
    var storeGameID: String?

    init(
        id: String? = nil,
        title: String,
        exePath: String,
        prefixName: String,
        engine: ExecutionEngine = .auto,
        perfProfile: PerfProfile = .balanced,
        dx9Backend: DX9Backend = .auto,
        upscaleMode: String = "off",
        retinaMode: Bool = true,
        enableHUD: Bool = true,
        enableSandbox: Bool = false,
        extraArgs: String = "",
        architecture: String = "unknown",
        detectedAPIs: [String] = [],
        detectedUpscalers: [String] = [],
        buildHash: String = "",
        playCount: Int = 0,
        lastPlayedUtc: String? = nil,
        steamAppID: String? = nil,
        profileID: String? = nil,
        profileNote: String? = nil,
        storeSource: String? = nil,
        storeGameID: String? = nil
    ) {
        let canonical = GameLibraryManager.canonicalPath(exePath)
        self.id = id ?? GameLibraryManager.stableID(forCanonicalPath: canonical)
        self.title = title
        self.exePath = canonical
        self.prefixName = prefixName
        self.engine = engine
        self.perfProfile = perfProfile
        self.dx9Backend = dx9Backend
        self.upscaleMode = upscaleMode
        self.retinaMode = retinaMode
        self.enableHUD = enableHUD
        self.enableSandbox = enableSandbox
        self.extraArgs = extraArgs
        self.architecture = architecture
        self.detectedAPIs = detectedAPIs
        self.detectedUpscalers = detectedUpscalers
        self.buildHash = buildHash
        self.playCount = playCount
        self.lastPlayedUtc = lastPlayedUtc
        self.steamAppID = steamAppID
        self.profileID = profileID
        self.profileNote = profileNote
        self.storeSource = storeSource
        self.storeGameID = storeGameID
    }

    enum CodingKeys: String, CodingKey {
        case id, title, exePath, prefixName, engine, perfProfile, dx9Backend, upscaleMode
        case retinaMode, enableHUD, enableSandbox, extraArgs, architecture, detectedAPIs
        case detectedUpscalers, buildHash, playCount, lastPlayedUtc
        case steamAppID, profileID, profileNote
        case storeSource, storeGameID
    }

    /// Tolerant decoder: missing or unknown values fall back to defaults so older/newer
    /// library.json files never wipe the user's library.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func opt<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? c.decodeIfPresent(type, forKey: key)) ?? nil
        }
        let path = opt(String.self, .exePath) ?? ""
        exePath = path
        id = opt(String.self, .id) ?? GameLibraryManager.stableID(forCanonicalPath: GameLibraryManager.canonicalPath(path))
        title = opt(String.self, .title) ?? GameLibraryManager.deriveTitle(exePath: path)
        prefixName = opt(String.self, .prefixName) ?? GameLibraryManager.defaultPrefixName(exePath: path)
        engine = opt(ExecutionEngine.self, .engine) ?? .auto
        perfProfile = opt(PerfProfile.self, .perfProfile) ?? .balanced
        dx9Backend = opt(DX9Backend.self, .dx9Backend) ?? .auto
        upscaleMode = opt(String.self, .upscaleMode) ?? "off"
        retinaMode = opt(Bool.self, .retinaMode) ?? true
        enableHUD = opt(Bool.self, .enableHUD) ?? true
        enableSandbox = opt(Bool.self, .enableSandbox) ?? false
        extraArgs = opt(String.self, .extraArgs) ?? ""
        architecture = opt(String.self, .architecture) ?? "unknown"
        detectedAPIs = opt([String].self, .detectedAPIs) ?? []
        detectedUpscalers = opt([String].self, .detectedUpscalers) ?? []
        buildHash = opt(String.self, .buildHash) ?? ""
        playCount = opt(Int.self, .playCount) ?? 0
        lastPlayedUtc = opt(String.self, .lastPlayedUtc)
        steamAppID = opt(String.self, .steamAppID) ?? opt(Int.self, .steamAppID).map(String.init)
        profileID = opt(String.self, .profileID)
        profileNote = opt(String.self, .profileNote)
        storeSource = opt(String.self, .storeSource).map { $0.lowercased() }
        storeGameID = opt(String.self, .storeGameID) ?? opt(Int.self, .storeGameID).map(String.init)
    }

    /// Seeds per-game settings from a community profile. Only used for brand-new library entries so a
    /// user-configured game is never overwritten.
    mutating func apply(gameProfile p: GameProfile) {
        if let v = p.perfProfile { perfProfile = v }
        if let v = p.dx9Backend { dx9Backend = v }
        if let v = p.upscaleMode { upscaleMode = v }
        if let v = p.retinaMode { retinaMode = v }
        if let v = p.enableHUD { enableHUD = v }
        if let v = p.enableSandbox { enableSandbox = v }
        profileID = p.id
        profileNote = p.notes ?? "Community preset: \(p.title)"
    }

    /// Refresh auto-detected fields from a fresh PE inspection (user settings untouched).
    mutating func apply(profile: PEProfile) {
        architecture = profile.architecture
        detectedAPIs = profile.detectedAPIs
        detectedUpscalers = profile.detectedUpscalers
        buildHash = profile.buildHash
    }

    /// Saved extra launch arguments, split shell-style.
    var extraArgList: [String] { GameLibraryManager.splitArguments(extraArgs) }

    /// Upscale mode suitable for `RuntimeLauncher.runExecutable` (nil == off).
    var launchUpscaleMode: String? {
        let m = upscaleMode.trimmingCharacters(in: .whitespaces).lowercased()
        return (m.isEmpty || m == "off") ? nil : m
    }

    var launchPrefixName: String {
        let p = prefixName.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? "default" : p
    }
}

enum GameLibraryError: Error, CustomStringConvertible {
    case executableNotFound(String)
    case notAnExecutable(String)

    var description: String {
        switch self {
        case .executableNotFound(let m), .notAnExecutable(let m):
            return m
        }
    }
}

// MARK: - Library manager

final class GameLibraryManager {
    let supportRoot: URL
    let libraryURL: URL
    let hiddenURL: URL
    let prefixRoot: URL
    /// Community profiles (bundled/repo/embedded + the user's `<supportRoot>/game_profiles.json` overlay).
    private(set) lazy var profileRegistry = GameProfileRegistry.load(supportRoot: supportRoot)

    init(supportRoot: URL? = nil, prefixRoot: URL? = nil) {
        let root = supportRoot ?? GameLibraryManager.defaultSupportRoot()
        self.supportRoot = root
        self.libraryURL = root.appendingPathComponent("library.json")
        self.hiddenURL = root.appendingPathComponent("library_hidden.json")
        self.prefixRoot = prefixRoot ?? PrefixManager().prefixRoot
    }

    /// `~/Library/Application Support/DirectMetal` ($HOME-aware so tests can use a temp HOME;
    /// `DIRECTMETAL_LIBRARY_DIR` overrides).
    static func defaultSupportRoot() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["DIRECTMETAL_LIBRARY_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        let home: URL
        if let h = env["HOME"], !h.isEmpty {
            home = URL(fileURLWithPath: h, isDirectory: true)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
        }
        return home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("DirectMetal", isDirectory: true)
    }

    // MARK: Persistence

    func load() -> [GameLibraryEntry] {
        guard let data = try? Data(contentsOf: libraryURL),
              let entries = try? JSONDecoder().decode([GameLibraryEntry].self, from: data)
        else { return [] }
        return GameLibraryManager.sorted(entries)
    }

    func save(_ entries: [GameLibraryEntry]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(GameLibraryManager.sorted(entries)) else { return }
        try? FileManager.default.createDirectory(at: supportRoot, withIntermediateDirectories: true)
        try? data.write(to: libraryURL, options: .atomic)
    }

    private func loadHidden() -> Set<String> {
        guard let data = try? Data(contentsOf: hiddenURL),
              let paths = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(paths)
    }

    private func saveHidden(_ paths: Set<String>) {
        if paths.isEmpty {
            try? FileManager.default.removeItem(at: hiddenURL)
            return
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? enc.encode(paths.sorted()) else { return }
        try? FileManager.default.createDirectory(at: supportRoot, withIntermediateDirectories: true)
        try? data.write(to: hiddenURL, options: .atomic)
    }

    // MARK: Mutations

    @discardableResult
    func addOrUpdate(exePath: String, customTitle: String? = nil) throws -> GameLibraryEntry {
        let canonical = GameLibraryManager.canonicalPath(exePath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDir), !isDir.boolValue else {
            throw GameLibraryError.executableNotFound("Windows executable not found: \(canonical)")
        }
        let profile: PEProfile
        do {
            profile = try PEInspector.inspect(exePath: canonical)
        } catch {
            throw GameLibraryError.notAnExecutable("Not a valid Windows PE executable (\(canonical)): \(error)")
        }

        var entries = load()
        let title = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: GameLibraryEntry
        if let idx = entries.firstIndex(where: { GameLibraryManager.canonicalPath($0.exePath) == canonical }) {
            entries[idx].apply(profile: profile)
            if let t = title, !t.isEmpty { entries[idx].title = t }
            if entries[idx].steamAppID == nil {
                entries[idx].steamAppID = SteamLibraryLocator.steamAppID(forExePath: canonical)
            }
            GameLibraryManager.refreshStoreMetadata(&entries[idx])
            result = entries[idx]
        } else {
            let prefixMap = previouslyUsedPrefixes()
            var entry = GameLibraryEntry(
                title: (title?.isEmpty == false) ? title! : GameLibraryManager.deriveTitle(exePath: canonical),
                exePath: canonical,
                prefixName: prefixMap[canonical] ?? GameLibraryManager.defaultPrefixName(exePath: canonical)
            )
            entry.apply(profile: profile)
            applyNewEntryDefaults(&entry)
            entries.append(entry)
            result = entry
        }
        // Explicitly adding a game always un-hides it.
        var hidden = loadHidden()
        if hidden.remove(canonical) != nil { saveHidden(hidden) }
        save(entries)
        return result
    }

    /// Brand-new entries only: discover the Steam app ID / storefront and seed settings from the matching
    /// community profile.
    private func applyNewEntryDefaults(_ entry: inout GameLibraryEntry) {
        if entry.steamAppID == nil {
            entry.steamAppID = SteamLibraryLocator.steamAppID(forExePath: entry.exePath)
        }
        GameLibraryManager.refreshStoreMetadata(&entry)
        if entry.storeSource == nil { entry.storeSource = "standalone" }
        if let p = profileRegistry.match(title: entry.title, exePath: entry.exePath, steamAppID: entry.steamAppID,
                                         storeSource: entry.storeSource, storeGameID: entry.storeGameID) {
            entry.apply(gameProfile: p)
        }
    }

    /// Fills `storeSource` / `storeGameID` from on-disk store markers when they are unknown (or only
    /// `standalone`). Metadata only: user settings are never touched.
    static func refreshStoreMetadata(_ entry: inout GameLibraryEntry) {
        guard entry.storeSource == nil || entry.storeSource == "standalone"
            || (entry.storeSource != "steam" && entry.storeGameID == nil) else { return }
        guard let found = StoreMetadataLocator.detectStore(forExePath: entry.exePath) else { return }
        if entry.storeSource == nil || entry.storeSource == "standalone" || entry.storeSource == found.source {
            entry.storeSource = found.source
            if entry.storeGameID == nil, found.source != "steam" { entry.storeGameID = found.gameID }
        }
    }

    /// Removes a game (by id, id prefix, title, or exe name). Removed games are remembered so a
    /// later auto-scan does not silently re-add them; `addOrUpdate` brings them back.
    @discardableResult
    func remove(idOrTitle: String) -> Bool {
        var entries = load()
        guard let target = GameLibraryManager.find(idOrTitle, in: entries) else { return false }
        entries.removeAll { $0.id == target.id }
        var hidden = loadHidden()
        hidden.insert(GameLibraryManager.canonicalPath(target.exePath))
        saveHidden(hidden)
        save(entries)
        return true
    }

    func recordLaunch(id: String) {
        var entries = load()
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].playCount += 1
        entries[idx].lastPlayedUtc = GameLibraryManager.isoFormatter.string(from: Date())
        save(entries)
    }

    func entry(idOrTitle: String) -> GameLibraryEntry? {
        GameLibraryManager.find(idOrTitle, in: load())
    }

    /// Resolution order: exact id → exact title → exe file name → unique id prefix → unique title prefix.
    static func find(_ key: String, in entries: [GameLibraryEntry]) -> GameLibraryEntry? {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return nil }
        let low = k.lowercased()
        if let e = entries.first(where: { $0.id == k }) { return e }
        if let e = entries.first(where: { $0.title.lowercased() == low }) { return e }
        let byExe = entries.filter {
            let name = URL(fileURLWithPath: $0.exePath).lastPathComponent.lowercased()
            return name == low || (name as NSString).deletingPathExtension == low
        }
        if byExe.count == 1 { return byExe[0] }
        if k.count >= 4 {
            let byID = entries.filter { $0.id.hasPrefix(low) }
            if byID.count == 1 { return byID[0] }
        }
        let byTitle = entries.filter { $0.title.lowercased().hasPrefix(low) }
        if byTitle.count == 1 { return byTitle[0] }
        return nil
    }

    // MARK: Auto-scanner

    private struct Discovery {
        let exePath: String
        let title: String
        let prefixName: String?
        var storeSource: String? = nil
        var storeGameID: String? = nil
    }

    /// Scans known locations, merges with the saved library (preserving user settings),
    /// re-inspects every executable, persists, and returns the full sorted library.
    @discardableResult
    func scanKnownLocations(extraDirs: [String] = []) -> [GameLibraryEntry] {
        let fm = FileManager.default
        let hidden = loadHidden()
        let prefixMap = previouslyUsedPrefixes()

        var discoveries: [Discovery] = []
        let roots = scanRoots(extraDirs: extraDirs)
        // 1. Explicit folders + DIRECTMETAL_SCAN_DIR + <cwd>/.directmetal_cache/games (GOG/Epic aware)
        for dir in roots {
            // A scanned folder that is itself a Wine prefix: read its GOG Galaxy + Epic manifests first.
            if fm.fileExists(atPath: dir.appendingPathComponent("drive_c").path) {
                discoveries.append(contentsOf: scanStorePrefix(dir, prefixName: nil))
            }
            discoveries.append(contentsOf: scanGameFolderRoot(dir))
        }
        // 2. Steam libraries inside DirectMetal prefixes
        discoveries.append(contentsOf: scanSteamLibraries())
        // 3. GOG Galaxy / Epic Games Store installs (prefixes, ~/Games, Heroic)
        discoveries.append(contentsOf: scanStoreLibraries())
        // 4. Previously launched executables recorded in prefix metadata
        discoveries.append(contentsOf: scanPrefixMetadata())

        var entries = load()
        var indexByPath: [String: Int] = [:]
        for (i, e) in entries.enumerated() {
            let c = GameLibraryManager.canonicalPath(e.exePath)
            entries[i].exePath = c
            if indexByPath[c] == nil { indexByPath[c] = i }
        }
        // Drop accidental duplicates in a hand-edited library.json
        if indexByPath.count != entries.count {
            var seen = Set<String>()
            entries = entries.filter { seen.insert($0.exePath).inserted }
            indexByPath = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($1.exePath, $0) })
        }

        // Refresh PE info for existing entries that still exist.
        for i in entries.indices where fm.fileExists(atPath: entries[i].exePath) {
            if let prof = try? PEInspector.inspect(exePath: entries[i].exePath) {
                entries[i].apply(profile: prof)
            }
            // Metadata only (artwork); user settings and profile choices are never touched on refresh.
            if entries[i].steamAppID == nil {
                entries[i].steamAppID = SteamLibraryLocator.steamAppID(forExePath: entries[i].exePath)
            }
            GameLibraryManager.refreshStoreMetadata(&entries[i])
        }

        for d in discoveries {
            let c = GameLibraryManager.canonicalPath(d.exePath)
            if let idx = indexByPath[c] {
                // Already known: only fill in missing storefront metadata.
                if let s = d.storeSource,
                   entries[idx].storeSource == nil || entries[idx].storeSource == "standalone" || entries[idx].storeSource == s {
                    entries[idx].storeSource = s
                    if entries[idx].storeGameID == nil { entries[idx].storeGameID = d.storeGameID }
                }
                continue
            }
            if hidden.contains(c) { continue }
            guard fm.fileExists(atPath: c), let prof = try? PEInspector.inspect(exePath: c) else { continue }
            var entry = GameLibraryEntry(
                title: d.title,
                exePath: c,
                prefixName: prefixMap[c] ?? d.prefixName ?? GameLibraryManager.defaultPrefixName(exePath: c),
                storeSource: d.storeSource,
                storeGameID: d.storeGameID
            )
            entry.apply(profile: prof)
            applyNewEntryDefaults(&entry)
            indexByPath[c] = entries.count
            entries.append(entry)
        }

        let result = GameLibraryManager.sorted(entries)
        save(result)
        return result
    }

    private func scanRoots(extraDirs: [String]) -> [URL] {
        let fm = FileManager.default
        var roots: [String] = extraDirs
        if let env = ProcessInfo.processInfo.environment["DIRECTMETAL_SCAN_DIR"], !env.isEmpty {
            roots.append(contentsOf: env.split(separator: ":").map(String.init))
        }
        roots.append(URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent(".directmetal_cache/games").path)

        var seen = Set<String>()
        var out: [URL] = []
        for r in roots {
            let expanded = (r as NSString).expandingTildeInPath
            let c = GameLibraryManager.canonicalPath(expanded)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: c, isDirectory: &isDir), isDir.boolValue, seen.insert(c).inserted else { continue }
            out.append(URL(fileURLWithPath: c, isDirectory: true))
        }
        return out
    }

    /// A scan root is either a folder of game folders, or a single game folder itself.
    private func scanGameFolderRoot(_ root: URL) -> [Discovery] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var dirs: [URL] = []
        var singleGame = false
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = item.lastPathComponent.lowercased()
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                // Architecture / engine sub-folders mean the root is itself one game ("Hades/x64", "REANIMAL/Engine").
                if GameLibraryManager.genericDirNames.contains(name) || name == "engine"
                    || name.hasPrefix("x64") || name.hasPrefix("x86") {
                    singleGame = true
                }
                if !GameLibraryManager.excludedDirNames.contains(name) { dirs.append(item) }
            } else if name.hasSuffix(".exe") && !GameLibraryManager.isExcludedExecutable(name) {
                singleGame = true
            }
        }

        if singleGame {
            if let rec = StoreMetadataLocator.storeRecord(forGameFolder: root), let d = discovery(from: rec, prefixName: nil) {
                return [d]
            }
            guard let exe = GameLibraryManager.primaryExecutable(inGameFolder: root, titleHint: root.lastPathComponent)
            else { return [] }
            return [Discovery(exePath: exe.path, title: root.lastPathComponent, prefixName: nil)]
        }
        return dirs.compactMap { dir in
            if let rec = StoreMetadataLocator.storeRecord(forGameFolder: dir), let d = discovery(from: rec, prefixName: nil) {
                return d
            }
            return GameLibraryManager.primaryExecutable(inGameFolder: dir, titleHint: dir.lastPathComponent).map {
                Discovery(exePath: $0.path, title: dir.lastPathComponent, prefixName: nil)
            }
        }
    }

    // MARK: GOG Galaxy / Epic Games Store

    /// Store record -> discovery: the store's own launch executable, else the folder heuristic.
    private func discovery(from rec: StoreGameRecord, prefixName: String?) -> Discovery? {
        let fm = FileManager.default
        var exe: URL? = nil
        if let e = rec.exeURL, fm.fileExists(atPath: e.path), !GameLibraryManager.isExcludedExecutable(e.lastPathComponent) {
            exe = e
        } else {
            exe = GameLibraryManager.primaryExecutable(inGameFolder: rec.installDir, titleHint: rec.title)
        }
        guard let exe else { return nil }
        return Discovery(exePath: exe.path, title: rec.title, prefixName: prefixName,
                         storeSource: rec.source, storeGameID: rec.gameID)
    }

    /// GOG Galaxy + Epic Games Launcher installs inside one Wine prefix.
    private func scanStorePrefix(_ prefix: URL, prefixName: String?) -> [Discovery] {
        var out: [Discovery] = []
        for rec in StoreMetadataLocator.storeRecords(inPrefix: prefix) {
            if let d = discovery(from: rec, prefixName: prefixName) { out.append(d) }
        }
        return out
    }

    /// Every DirectMetal prefix, `~/Games` (incl. Heroic's `~/Games/Heroic`) and Heroic's installed lists.
    private func scanStoreLibraries() -> [Discovery] {
        var out: [Discovery] = []
        for dir in prefixDirectories() {
            out.append(contentsOf: scanStorePrefix(dir, prefixName: dir.lastPathComponent))
        }
        for rec in StoreMetadataLocator.homeStoreRecords() {
            if let d = discovery(from: rec, prefixName: nil) { out.append(d) }
        }
        return out
    }

    private func prefixDirectories() -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: prefixRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return items.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private struct PrefixRecord {
        let prefixName: String
        let gameExe: String
        let createdUtc: String
    }

    /// Reads `directmetal_prefix.json` (and legacy `directmetal.prefix.json`) from every prefix.
    private func prefixRecords() -> [PrefixRecord] {
        var out: [PrefixRecord] = []
        for dir in prefixDirectories() {
            for name in ["directmetal_prefix.json", "directmetal.prefix.json"] {
                let url = dir.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                let exe = (obj["game_exe"] as? String) ?? (obj["gameExe"] as? String) ?? ""
                let created = (obj["created_utc"] as? String) ?? (obj["createdUtc"] as? String) ?? ""
                if !exe.isEmpty {
                    out.append(PrefixRecord(prefixName: dir.lastPathComponent, gameExe: exe, createdUtc: created))
                }
                break
            }
        }
        return out
    }

    /// canonical exe path -> most recently created prefix that launched it.
    func previouslyUsedPrefixes() -> [String: String] {
        var best: [String: PrefixRecord] = [:]
        for r in prefixRecords() {
            let c = GameLibraryManager.canonicalPath(r.gameExe)
            if let cur = best[c], cur.createdUtc >= r.createdUtc { continue }
            best[c] = r
        }
        return best.mapValues { $0.prefixName }
    }

    private func scanPrefixMetadata() -> [Discovery] {
        let fm = FileManager.default
        var out: [Discovery] = []
        var seen = Set<String>()
        for r in prefixRecords() {
            let c = GameLibraryManager.canonicalPath(r.gameExe)
            guard seen.insert(c).inserted, fm.fileExists(atPath: c) else { continue }
            let url = URL(fileURLWithPath: c)
            // Skip installers/redistributables and developer test harnesses.
            if GameLibraryManager.isExcludedExecutable(url.lastPathComponent) { continue }
            if GameLibraryManager.isDeveloperHarness(url) { continue }
            out.append(Discovery(exePath: c, title: GameLibraryManager.deriveTitle(exePath: c), prefixName: r.prefixName))
        }
        return out
    }

    private func scanSteamLibraries() -> [Discovery] {
        let fm = FileManager.default
        var out: [Discovery] = []
        for dir in prefixDirectories() {
            for programFiles in ["Program Files (x86)", "Program Files"] {
                let steamapps = dir
                    .appendingPathComponent("drive_c", isDirectory: true)
                    .appendingPathComponent(programFiles, isDirectory: true)
                    .appendingPathComponent("Steam/steamapps", isDirectory: true)
                guard let items = try? fm.contentsOfDirectory(atPath: steamapps.path) else { continue }
                for file in items.sorted() where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                    guard let text = try? String(contentsOf: steamapps.appendingPathComponent(file), encoding: .utf8)
                    else { continue }
                    let fields = GameLibraryManager.parseACF(text)
                    guard let installdir = fields["installdir"], !installdir.isEmpty else { continue }
                    let title = fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? installdir
                    let gameDir = steamapps.appendingPathComponent("common", isDirectory: true)
                        .appendingPathComponent(installdir, isDirectory: true)
                    if let exe = GameLibraryManager.primaryExecutable(inGameFolder: gameDir, titleHint: title) {
                        out.append(Discovery(exePath: exe.path, title: title, prefixName: dir.lastPathComponent,
                                             storeSource: "steam"))
                    }
                }
            }
        }
        return out
    }

    /// Minimal Valve KeyValues parser: returns top-level-ish `"key" "value"` string pairs.
    static func parseACF(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var tokens: [String] = []
            var cur = ""
            var inQuote = false
            var escape = false
            for ch in raw {
                if escape { cur.append(ch); escape = false; continue }
                if ch == "\\" && inQuote { escape = true; continue }
                if ch == "\"" {
                    if inQuote { tokens.append(cur); cur = "" }
                    inQuote.toggle()
                    continue
                }
                if inQuote { cur.append(ch) }
            }
            if tokens.count >= 2 {
                let key = tokens[0].lowercased()
                if out[key] == nil { out[key] = tokens[1] }
            }
        }
        return out
    }

    // MARK: Primary executable heuristics

    static let excludedDirNames: Set<String> = [
        "redist", "redists", "redistributable", "redistributables", "_commonredist", "commonredist",
        "directx", "dxsetup", "support", "installer", "installers", "__installer", "_installer",
        "vcredist", "prereq", "prereqs", "prerequisites", "ueprereqs", "engine", "tools", "sdk",
        "easyanticheat_setup", "crashpad", "crashreporter", "__macosx", "dotnet", "physx", "eadm",
    ]

    static func isExcludedExecutable(_ fileName: String) -> Bool {
        let n = fileName.lowercased()
        let stem = (n as NSString).deletingPathExtension
        if stem == "crashreportclient" || stem == "dxsetup" || stem == "dxwebsetup" { return true }
        let prefixes = ["unins", "uninstall", "ueprereqsetup", "vcredist", "vc_redist", "dotnetfx", "ndp4",
                        "oalinst", "physx", "directx", "eadm", "crashpad", "unitycrashhandler", "crashhandler",
                        "crashreport", "bugsplat", "setup", "install"]
        if prefixes.contains(where: { stem.hasPrefix($0) }) { return true }
        let contains = ["setup", "installer", "redist", "crashreport", "crash_report", "crashhandler"]
        return contains.contains(where: { stem.contains($0) })
    }

    static func isDeveloperHarness(_ url: URL) -> Bool {
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        let parent = url.deletingLastPathComponent().lastPathComponent.lowercased()
        return stem.contains("conformance") || stem.contains("selftest") || stem.hasPrefix("dm_bench")
            || parent == "conformance-bin"
    }

    private static func normalized(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    private static func acronym(_ s: String) -> String {
        let words = s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.map { w -> String in
            if w.allSatisfy(\.isNumber) { return String(w) }
            return String(w.first!)
        }.joined()
    }

    private static func leadingLetters(_ s: String) -> String {
        String(s.lowercased().prefix(while: { $0.isLetter }))
    }

    private static func cleanedStem(_ stem: String) -> String {
        var s = stem
        for suffix in ["-win64-shipping", "-wingdk-shipping", "-win32-shipping", "-shipping", "_dx12", "_dx11", "_dx9"] {
            if s.lowercased().hasSuffix(suffix) { s = String(s.dropLast(suffix.count)) }
        }
        return s
    }

    /// Picks the main game `.exe` inside a game folder, skipping crash reporters,
    /// uninstallers, redistributables, configuration tools and dev tools.
    static func primaryExecutable(inGameFolder folder: URL, titleHint: String) -> URL? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let en = fm.enumerator(at: folder, includingPropertiesForKeys: keys,
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }

        let title = titleHint.isEmpty ? folder.lastPathComponent : titleHint
        let normTitle = normalized(title)
        let normFolder = normalized(folder.lastPathComponent)
        let titleAcronym = acronym(title)
        let folderAcronym = acronym(folder.lastPathComponent)
        let utilityWords = ["config", "settings", "launcher", "browser", "tool", "editor", "server", "report",
                            "helper", "service", "overlay", "updater", "uplay", "ubisoft", "benchmark", "viewer",
                            "studio", "compiler", "converter", "dedicated", "patch", "register", "activation"]

        var scored: [(url: URL, score: Double)] = []
        var visited = 0
        let baseDepth = folder.standardizedFileURL.pathComponents.count

        while let obj = en.nextObject() {
            guard let url = obj as? URL else { continue }
            visited += 1
            if visited > 20_000 { break }
            let vals = try? url.resourceValues(forKeys: Set(keys))
            let depth = url.standardizedFileURL.pathComponents.count - baseDepth - 1
            if vals?.isDirectory == true {
                if depth >= 5 || excludedDirNames.contains(url.lastPathComponent.lowercased()) {
                    en.skipDescendants()
                }
                continue
            }
            guard vals?.isRegularFile == true, url.pathExtension.lowercased() == "exe" else { continue }
            if isExcludedExecutable(url.lastPathComponent) { continue }

            let stem = cleanedStem(url.deletingPathExtension().lastPathComponent)
            let normStem = normalized(stem)
            let lowStem = stem.lowercased()
            let parentComps = url.deletingLastPathComponent().standardizedFileURL.pathComponents
                .suffix(max(0, depth)).map { $0.lowercased() }

            var score = -15.0 * Double(depth)

            // Name affinity with the game title / folder.
            if !normStem.isEmpty && (normStem == normTitle || normStem == normFolder) {
                score += 100
            } else if normStem.count >= 3 && (normTitle.contains(normStem) || normFolder.contains(normStem)
                        || normStem.contains(normTitle) && normTitle.count >= 3) {
                score += 60
            } else {
                let lead = leadingLetters(stem)
                if lead.count >= 2 && (titleAcronym.hasPrefix(lead) || folderAcronym.hasPrefix(lead)) {
                    score += 40
                }
            }

            // Unreal Engine layout: <Root>/<Project>/Binaries/Win64/<Game>.exe
            if parentComps.count >= 2, ["win64", "wingdk"].contains(parentComps[parentComps.count - 1]),
               parentComps[parentComps.count - 2] == "binaries" {
                score += 40
            }

            // Architecture preferences: prefer 64-bit/default renderer builds.
            if parentComps.contains(where: { ["x64", "win64", "bin64", "x86_64", "amd64"].contains($0) })
                || lowStem.contains("64") {
                score += 10
            }
            if parentComps.contains(where: { ["x86", "win32", "bin32"].contains($0) }) { score -= 5 }
            if parentComps.contains(where: { $0.contains("vk") || $0.contains("vulkan") }) { score -= 8 }

            if utilityWords.contains(where: { lowStem.contains($0) }) { score -= 60 }

            let sizeMB = Double(vals?.fileSize ?? 0) / 1_048_576.0
            score += min(20.0, log2(sizeMB + 1.0) * 3.0)
            if sizeMB < 0.05 { score -= 30 }

            scored.append((url, score))
        }

        guard !scored.isEmpty else { return nil }
        // Inspect the strongest candidates: real PE images only; Direct3D importers get a boost.
        let top = scored.sorted { $0.score > $1.score }.prefix(8)
        var best: (url: URL, score: Double)?
        for cand in top {
            guard let prof = try? PEInspector.inspect(exePath: cand.url.path) else { continue }
            var s = cand.score
            if !prof.detectedAPIs.isEmpty { s += 15 }
            if best == nil || s > best!.score { best = (cand.url, s) }
        }
        return best?.url
    }

    // MARK: Helpers

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func canonicalPath(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func stableID(forCanonicalPath path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    static func sorted(_ entries: [GameLibraryEntry]) -> [GameLibraryEntry] {
        entries.sorted {
            let r = $0.title.localizedStandardCompare($1.title)
            return r == .orderedSame ? $0.exePath < $1.exePath : r == .orderedAscending
        }
    }

    static func defaultPrefixName(exePath: String) -> String {
        let stem = URL(fileURLWithPath: exePath).deletingPathExtension().lastPathComponent
        let cleaned = stem.replacingOccurrences(of: "/", with: "_")
        return cleaned.isEmpty ? "default" : cleaned
    }

    static let genericDirNames: Set<String> = [
        "bin", "bin32", "bin64", "binaries", "win64", "win32", "wingdk", "x64", "x86", "x64vk", "x86_64",
        "amd64", "game", "games", "retail", "release", "debug", "build", "builds", "out", "exe", "app",
        "program files", "program files (x86)", "common", "steamapps", "drive_c", "dist",
    ]

    /// Human-friendly title from an executable path.
    static func deriveTitle(exePath: String) -> String {
        let url = URL(fileURLWithPath: exePath)
        let comps = url.deletingLastPathComponent().pathComponents
        let lower = comps.map { $0.lowercased() }
        // <...>/games/<Title>/..., <...>/steamapps/common/<Title>/..., Program Files/<Title>/...
        for marker in ["common", "games", "program files", "program files (x86)"] {
            if let i = lower.lastIndex(of: marker), i + 1 < comps.count {
                return comps[i + 1]
            }
        }
        // Unreal: <Root>/<Project>/Binaries/Win64/<exe>
        if let bi = lower.lastIndex(of: "binaries"), bi >= 1 {
            let projectIdx = bi - 1
            let rootIdx = projectIdx - 1
            if rootIdx >= 1 {
                let root = URL(fileURLWithPath: NSString.path(withComponents: Array(comps[0...rootIdx])))
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("Engine").path) {
                    return comps[rootIdx]
                }
            }
            return comps[projectIdx]
        }
        // Walk up past generic folder names (max 3 levels).
        var idx = comps.count - 1
        var steps = 0
        while idx > 0 && steps < 3 {
            let name = lower[idx]
            let looksGeneric = genericDirNames.contains(name) || name.hasSuffix("-bin") || name.hasSuffix("_bin")
                || name.contains("cache") || name.hasPrefix(".") || name == NSUserName().lowercased()
            if !looksGeneric { return comps[idx] }
            idx -= 1
            steps += 1
        }
        let stem = cleanedStem(url.deletingPathExtension().lastPathComponent)
        return stem.replacingOccurrences(of: "_", with: " ")
    }

    /// Shell-style argument splitting (supports '…', "…" and backslash escapes).
    static func splitArguments(_ s: String) -> [String] {
        var args: [String] = []
        var cur = ""
        var hasToken = false
        var quote: Character? = nil
        var escape = false
        for ch in s {
            if escape { cur.append(ch); escape = false; hasToken = true; continue }
            if ch == "\\" && quote != "'" { escape = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; hasToken = true; continue }
            if ch.isWhitespace {
                if hasToken { args.append(cur); cur = ""; hasToken = false }
                continue
            }
            cur.append(ch)
            hasToken = true
        }
        if hasToken { args.append(cur) }
        return args
    }
}

// MARK: - Community game profiles

/// One community preset from `runtime/profiles/game_profiles.json` (schema `directmetal.game_profiles.v1`).
struct GameProfile: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var matchTitles: [String]
    var matchExeNames: [String]
    var steamAppIds: [String]
    var perfProfile: PerfProfile?
    var dx9Backend: DX9Backend?
    var upscaleMode: String?
    var retinaMode: Bool?
    var enableHUD: Bool?
    var enableSandbox: Bool?
    var status: String?
    var notes: String?
    var verifiedOn: [String]
    /// Engine tag (e.g. `Unreal Engine 5`, `Unity`, `RE Engine`, `Frostbite`, `REDengine 3`, `Source 2`).
    var gameEngine: String?
    /// Storefronts the game is sold on (`steam`, `gog`, `epic`).
    var stores: [String]
    /// GOG Galaxy `gameId`s (from `goggame-<id>.info`).
    var gogGameIds: [String]
    /// Epic Games Store `AppName`s (from launcher `.item` manifests / `.egstore`).
    var epicAppNames: [String]

    static let upscaleModes: Set<String> = ["off", "quality", "balanced", "performance", "ultra_performance"]

    enum CodingKeys: String, CodingKey {
        case id, title, matchTitles, matchExeNames, steamAppIds, perfProfile, dx9Backend, upscaleMode
        case retinaMode, enableHUD, enableSandbox, status, notes, verifiedOn
        case gameEngine, stores, gogGameIds, epicAppNames
    }

    /// Tolerant decoder: unknown enum values are ignored (field left unset) and app IDs may be numbers.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func opt<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? c.decodeIfPresent(type, forKey: key)) ?? nil
        }
        let rawID = (opt(String.self, .id) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawID.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "game profile requires an id")
        }
        id = rawID
        title = opt(String.self, .title) ?? rawID
        matchTitles = opt([String].self, .matchTitles) ?? []
        matchExeNames = opt([String].self, .matchExeNames) ?? []
        if let ids = opt([String].self, .steamAppIds) {
            steamAppIds = ids
        } else {
            steamAppIds = (opt([Int].self, .steamAppIds) ?? []).map(String.init)
        }
        perfProfile = opt(String.self, .perfProfile).flatMap { PerfProfile(rawValue: $0.lowercased()) }
        dx9Backend = opt(String.self, .dx9Backend).flatMap { DX9Backend(rawValue: $0.lowercased()) }
        upscaleMode = opt(String.self, .upscaleMode).map { $0.lowercased() }.flatMap { GameProfile.upscaleModes.contains($0) ? $0 : nil }
        retinaMode = opt(Bool.self, .retinaMode)
        enableHUD = opt(Bool.self, .enableHUD)
        enableSandbox = opt(Bool.self, .enableSandbox)
        status = opt(String.self, .status)
        notes = opt(String.self, .notes)
        verifiedOn = opt([String].self, .verifiedOn) ?? ["preset"]
        gameEngine = opt(String.self, .gameEngine)
        stores = (opt([String].self, .stores) ?? []).map { $0.lowercased() }
        if let ids = opt([String].self, .gogGameIds) {
            gogGameIds = ids
        } else {
            gogGameIds = (opt([Int].self, .gogGameIds) ?? []).map(String.init)
        }
        epicAppNames = opt([String].self, .epicAppNames) ?? []
    }

    /// `true` only when a maintainer actually ran the game (not a `["preset"]` starter template).
    var isVerified: Bool {
        verifiedOn.contains { !$0.isEmpty && $0.lowercased() != "preset" }
    }

    var verificationLabel: String {
        isVerified ? "Tested on \(verifiedOn.filter { $0.lowercased() != "preset" }.joined(separator: ", "))"
                   : "Community starter preset (untested)"
    }
}

private struct GameProfileDocument: Codable {
    var schema: String?
    var profiles: [GameProfile]
}

/// Loads community game profiles: `DIRECTMETAL_GAME_PROFILES` -> `Bundle.main.resourceURL/game_profiles.json`
/// -> `<cwd>/runtime/profiles/game_profiles.json` -> repo copy next to the executable -> embedded defaults,
/// then overlays `<supportRoot>/game_profiles.json` (user/community additions; same id replaces).
struct GameProfileRegistry {
    static let schemaID = "directmetal.game_profiles.v1"
    static let fileName = "game_profiles.json"

    let profiles: [GameProfile]
    /// Path of the base profile file, or `embedded`.
    let source: String
    /// Path of the user overlay when one was merged.
    let userOverlay: String?

    /// Process-wide registry for the GUI / CLI (default support root).
    static let shared = GameProfileRegistry.load()

    static func candidateURLs() -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        if let env = ProcessInfo.processInfo.environment["DIRECTMETAL_GAME_PROFILES"], !env.isEmpty {
            out.append(URL(fileURLWithPath: (env as NSString).expandingTildeInPath))
        }
        if let res = Bundle.main.resourceURL {
            out.append(res.appendingPathComponent(fileName))
        }
        out.append(URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("runtime/profiles/\(fileName)"))
        var probe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<5 {
            out.append(probe.appendingPathComponent("runtime/profiles/\(fileName)"))
            probe = probe.deletingLastPathComponent()
        }
        return out
    }

    static func load(supportRoot: URL? = nil) -> GameProfileRegistry {
        let fm = FileManager.default
        var base: [GameProfile]? = nil
        var source = "embedded"
        var seen = Set<String>()
        for url in candidateURLs() where seen.insert(url.standardizedFileURL.path).inserted {
            guard fm.fileExists(atPath: url.path), let data = try? Data(contentsOf: url),
                  let profiles = decode(data) else { continue }
            base = profiles
            source = url.standardizedFileURL.path
            break
        }
        var profiles = base ?? decode(Data(embeddedJSON.utf8)) ?? []

        let overlayURL = (supportRoot ?? GameLibraryManager.defaultSupportRoot()).appendingPathComponent(fileName)
        var overlayPath: String? = nil
        if fm.fileExists(atPath: overlayURL.path), let data = try? Data(contentsOf: overlayURL), let extra = decode(data) {
            let ids = Set(extra.map(\.id))
            profiles = extra + profiles.filter { !ids.contains($0.id) }
            overlayPath = overlayURL.path
        }
        return GameProfileRegistry(profiles: profiles, source: source, userOverlay: overlayPath)
    }

    /// Decodes a profile document; `nil` for a wrong schema or malformed JSON (bad individual profiles are skipped).
    static func decode(_ data: Data) -> [GameProfile]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["schema"] as? String) == schemaID,
              let rawProfiles = obj["profiles"] as? [Any] else { return nil }
        var out: [GameProfile] = []
        var ids = Set<String>()
        for raw in rawProfiles {
            guard JSONSerialization.isValidJSONObject(raw),
                  let d = try? JSONSerialization.data(withJSONObject: raw),
                  let p = try? JSONDecoder().decode(GameProfile.self, from: d),
                  ids.insert(p.id).inserted else { continue }
            out.append(p)
        }
        return out
    }

    func profile(id: String?) -> GameProfile? {
        guard let id, !id.isEmpty else { return nil }
        return profiles.first { $0.id == id }
    }

    /// Steam app ID match first, then GOG / Epic store IDs, then executable name, then normalized title.
    func match(title: String, exePath: String, steamAppID: String?,
               storeSource: String? = nil, storeGameID: String? = nil) -> GameProfile? {
        if let app = steamAppID, !app.isEmpty, let p = profiles.first(where: { $0.steamAppIds.contains(app) }) {
            return p
        }
        if let id = storeGameID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            switch storeSource?.lowercased() {
            case "gog":
                if let p = profiles.first(where: { $0.gogGameIds.contains(id) }) { return p }
            case "epic":
                if let p = profiles.first(where: { $0.epicAppNames.contains { $0.caseInsensitiveCompare(id) == .orderedSame } }) {
                    return p
                }
            default:
                break
            }
        }
        let exe = URL(fileURLWithPath: exePath).lastPathComponent.lowercased()
        if !exe.isEmpty, let p = profiles.first(where: { $0.matchExeNames.contains { $0.lowercased() == exe } }) {
            return p
        }
        let norm = GameProfileRegistry.normalizedTitle(title)
        guard !norm.isEmpty else { return nil }
        return profiles.first { p in
            (p.matchTitles + [p.title]).contains { GameProfileRegistry.normalizedTitle($0) == norm }
        }
    }

    /// "Need For Speed - Hot Pursuit" -> "needforspeedhotpursuit"
    static func normalizedTitle(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Fallback copy of `runtime/profiles/game_profiles.json` used when no profile file ships next to the binary.
    static let embeddedJSON = #"""
{
 "schema": "directmetal.game_profiles.v1",
 "profiles": [
  {"id": "hades", "title": "Hades", "matchTitles": ["Hades"], "matchExeNames": ["Hades.exe"], "steamAppIds": ["1145360"], "epicAppNames": ["Min"], "stores": ["steam", "epic"], "perfProfile": "balanced", "dx9Backend": "auto", "upscaleMode": "off", "retinaMode": true, "enableHUD": false, "enableSandbox": true, "status": "playable", "notes": "D3D11 via ARM64EC + FEX + Mullion. Measured 120 FPS locked (ProMotion) at native Retina 1512x982 with 0 Seatbelt denials inside the sandbox; MetalFX Quality also measured (111 FPS 1%-low).", "verifiedOn": ["M1 Pro (macOS 26.1)"]},
  {"id": "reanimal", "title": "REANIMAL", "matchTitles": ["REANIMAL"], "matchExeNames": ["REANIMAL.exe"], "steamAppIds": [], "gameEngine": "Unreal Engine 5", "perfProfile": "ultra", "dx9Backend": "auto", "upscaleMode": "off", "retinaMode": true, "enableHUD": false, "enableSandbox": true, "status": "playable", "notes": "Unreal Engine 5 D3D12 (FL 12_2) via ARM64EC + FEX + Mullion with the bundled D3D12 placed-resource guard. In-game DLSS is routed to Metal 4 MetalFX Temporal automatically; verified with --sandbox --perf-mode ultra.", "verifiedOn": ["M1 Pro (macOS 27.2.1)"]},
  {"id": "need-for-speed-hot-pursuit", "title": "Need for Speed: Hot Pursuit", "matchTitles": ["Need for Speed: Hot Pursuit", "Need For Speed - Hot Pursuit", "Need for Speed Hot Pursuit", "NFS Hot Pursuit"], "matchExeNames": ["NFS11.exe"], "steamAppIds": ["47870"], "stores": ["steam"], "perfProfile": "balanced", "dx9Backend": "wined3d", "upscaleMode": "off", "retinaMode": true, "enableHUD": false, "enableSandbox": false, "status": "playable", "notes": "32-bit D3D9 on native ARM64EC + FEX (macOS 26.4+) with WineMetalGL (wined3d -> Metal): avoids DXVK ddraw freezes and green-tinted FMVs. 22-minute live session, exit=0, zero Rosetta 2.", "verifiedOn": ["M1 Pro (macOS 27.2.1)"]},
  {"id": "team-fortress-2", "title": "Team Fortress 2", "matchTitles": ["Team Fortress 2", "TF2"], "matchExeNames": ["tf_win64.exe", "tf.exe"], "steamAppIds": ["440"], "stores": ["steam"], "gameEngine": "Source", "perfProfile": "balanced", "dx9Backend": "dxvk", "upscaleMode": "off", "retinaMode": true, "enableHUD": false, "enableSandbox": false, "status": "playable", "notes": "64-bit Source D3D9 via native ARM64X DXVK 3.1.1 (MetalVulkan) -> KosmicKrisp Vulkan -> Metal. Measured 14-19% GPU load (down from 68%), zero Rosetta 2. Online play requires a Steam login.", "verifiedOn": ["M1 Pro (macOS 27.2.1)"]},
  {"id": "prince-of-persia-the-forgotten-sands", "title": "Prince of Persia: The Forgotten Sands", "matchTitles": ["Prince of Persia: The Forgotten Sands", "Prince of Persia Forgotten Sands", "Prince of Persia - The Forgotten Sands", "Prince of Persia: Forgotten Sands"], "matchExeNames": [], "steamAppIds": ["33320"], "stores": ["steam"], "perfProfile": "balanced", "dx9Backend": "wined3d", "upscaleMode": "off", "retinaMode": true, "enableHUD": false, "enableSandbox": false, "status": "needs-steam-login", "notes": "32-bit D3D9 with SteamStub + Ubisoft DRM: launches, then shows a \"Steam Error\" dialog unless the Windows Steam client in the DirectMetal steam prefix is signed in (no DRM bypass). Not matched by exe name because \"Prince of Persia.exe\" is shared with other titles.", "verifiedOn": ["M1 Pro (macOS 26.1)"]},
  {"id": "cyberpunk-2077", "title": "Cyberpunk 2077", "matchTitles": ["Cyberpunk 2077"], "matchExeNames": ["Cyberpunk2077.exe"], "steamAppIds": ["1091500"], "gogGameIds": ["1423049311"], "stores": ["steam", "gog", "epic"], "gameEngine": "REDengine 4", "perfProfile": "ultra", "dx9Backend": "auto", "upscaleMode": "performance", "retinaMode": true, "enableHUD": true, "enableSandbox": false, "status": "preset", "notes": "Starter template (untested): REDengine 4 D3D12. Heavy title; begins with Ultra perf mode and MetalFX Performance, HUD on to judge frame pacing.", "verifiedOn": ["preset"]},
  {"id": "elden-ring", "title": "Elden Ring", "matchTitles": ["Elden Ring", "ELDEN RING"], "matchExeNames": ["eldenring.exe"], "steamAppIds": ["1245620"], "stores": ["steam"], "perfProfile": "balanced", "dx9Backend": "auto", "upscaleMode": "quality", "retinaMode": true, "enableHUD": true, "enableSandbox": false, "status": "preset", "notes": "Starter template (untested): D3D12. Easy Anti-Cheat is not supported, so only offline play via eldenring.exe can work; online features will not.", "verifiedOn": ["preset"]},
  {"id": "baldurs-gate-3", "title": "Baldur's Gate 3", "matchTitles": ["Baldur's Gate 3", "Baldurs Gate 3", "BG3"], "matchExeNames": ["bg3_dx11.exe", "bg3.exe"], "steamAppIds": ["1086940"], "gogGameIds": ["1456460669"], "stores": ["steam", "gog"], "gameEngine": "Divinity Engine 4.0", "perfProfile": "balanced", "dx9Backend": "auto", "upscaleMode": "quality", "retinaMode": true, "enableHUD": false, "enableSandbox": false, "status": "preset", "notes": "Starter template (untested): point the library at bin/bg3_dx11.exe (D3D11) - bg3.exe is the Vulkan renderer, which DirectMetal's DirectX path does not accelerate.", "verifiedOn": ["preset"]},
  {"id": "hollow-knight", "title": "Hollow Knight", "matchTitles": ["Hollow Knight"], "matchExeNames": ["hollow_knight.exe"], "steamAppIds": ["367520"], "stores": ["steam", "gog"], "gameEngine": "Unity", "perfProfile": "balanced", "dx9Backend": "auto", "upscaleMode": "off", "retinaMode": true, "enableHUD": false, "enableSandbox": true, "status": "preset", "notes": "Starter template (untested): lightweight Unity D3D11 2D title; native Retina without upscaling, sandboxed by default.", "verifiedOn": ["preset"]},
  {"id": "celeste", "title": "Celeste", "matchTitles": ["Celeste"], "matchExeNames": ["Celeste.exe"], "steamAppIds": ["504230"], "stores": ["steam", "epic"], "gameEngine": "XNA / FNA", "perfProfile": "balanced", "dx9Backend": "auto", "upscaleMode": "off", "retinaMode": true, "enableHUD": false, "enableSandbox": true, "status": "preset", "notes": "Starter template (untested): lightweight 2D pixel-art title; native Retina without upscaling, sandboxed by default.", "verifiedOn": ["preset"]},
  {"id": "black-myth-wukong", "title": "Black Myth: Wukong", "matchTitles": ["Black Myth: Wukong", "Black Myth Wukong"], "matchExeNames": ["b1-Win64-Shipping.exe"], "steamAppIds": ["2358720"], "gogGameIds": [], "epicAppNames": [], "stores": ["steam"], "gameEngine": "Unreal Engine 5", "perfProfile": "ultra", "dx9Backend": "auto", "upscaleMode": "performance", "retinaMode": true, "enableHUD": true, "enableSandbox": false, "status": "preset", "notes": "Starter template (untested): Unreal Engine 5 D3D12 (Lumen/Nanite) through ARM64EC + FEX + Mullion with the D3D12 placed-resource guard; heavy, so Ultra perf mode + MetalFX Performance with the HUD on to judge pacing. In-game DLSS is routed to MetalFX when detected.", "verifiedOn": ["preset"]},
  {"id": "remnant-2", "title": "Remnant II", "matchTitles": ["Remnant II", "Remnant 2"], "matchExeNames": ["Remnant2-Win64-Shipping.exe"], "steamAppIds": ["1282100"], "gogGameIds": [], "epicAppNames": [], "stores": ["steam"], "gameEngine": "Unreal Engine 5", "perfProfile": "ultra", "dx9Backend": "auto", "upscaleMode": "performance", "retinaMode": true, "enableHUD": true, "enableSandbox": false, "status": "preset", "notes": "Starter template (untested): Unreal Engine 5 D3D12 (Lumen/Nanite) through ARM64EC + FEX + Mullion with the D3D12 placed-resource guard; heavy, so Ultra perf mode + MetalFX Performance with the HUD on to judge pacing. In-game DLSS is routed to MetalFX when detected.", "verifiedOn": ["preset"]},
  {"id": "senuas-saga-hellblade-2", "title": "Senua's Saga: Hellblade II", "matchTitles": ["Senua's Saga: Hellblade II", "Senuas Saga Hellblade II", "Hellblade II", "Hellblade 2"], "matchExeNames": [], "steamAppIds": ["2461850"], "gogGameIds": [], "epicAppNames": [], "stores": ["steam"], "gameEngine": "Unreal Engine 5", "perfProfile": "ultra", "dx9Backend": "auto", "upscaleMode": "performance", "retinaMode": true, "enableHUD": true, "enableSandbox": false, "status": "preset", "notes": "Starter template (untested): Unreal Engine 5 D3D12 (Lumen/Nanite) through ARM64EC + FEX + Mullion with the D3D12 placed-resource guard; heavy, so Ultra perf mode + MetalFX Performance with the HUD on to judge pacing. In-game DLSS is routed to MetalFX when detected.", "verifiedOn": ["preset"]},
  {"id": "silent-hill-2-remake", "title": "SILENT HILL 2 (2024)", "matchTitles": ["Silent Hill 2 Remake", "SILENT HILL 2 (2024)"], "matchExeNames": ["SHProto-Win64-Shipping.exe"], "steamAppIds": ["2124490"], "gogGameIds": [], "epicAppNames": [], "stores": ["steam"], "gameEngine": "Unreal Engine 5", "perfProfile": "ultra", "dx9Backend": "auto", "upscaleMode": "performance", "retinaMode": true, "enableHUD": true, "enableSandbox": false, "status": "preset", "notes": "Starter template (untested): Unreal Engine 5 D3D12 (Lumen/Nanite) through ARM64EC + FEX + Mullion with the D3D12 placed-resource guard; heavy, so Ultra perf mode + MetalFX Performance with the HUD on to judge pacing. In-game DLSS is routed to MetalFX when detected. Not matched by the bare title so the 2001 original is never seeded with this preset.", "verifiedOn": ["preset"]},
  {"id": "stalker-2", "title": "S.T.A.L.K.E.R. 2: Heart of Chornobyl", "matchTitles": ["S.T.A.L.K.E.R. 2: Heart of Chornobyl", "STALKER 2", "Stalker 2 Heart of Chornobyl"], "matchExeNames": ["Stalker2-Win64-Shipping.exe"], "steamAppIds": ["1643320"], "gogGameIds": [], "epicAppNames": [], "stores": ["steam", "gog"], "gameEngine": "Unreal Engine 5", "perfProfile": "ultra", "dx9Backend": "auto", "upscaleMode": "performance", "retinaMode": true, "enableHUD": true, "enableSandbox": false, "status": "preset", "notes": "Starter template (untested): Unreal Engine 5 D3D12 (Lumen/Nanite) through ARM64EC + FEX + Mullion with the D3D12 placed-resource guard; heavy, so Ultra perf mode + MetalFX Performance with the HUD on to judge pacing. In-game DLSS is routed to MetalFX when detected.", "verifiedOn": ["preset"]},
  {"id": "the-talos-principle-2", "title": "The Talos Principle 2", "matchTitles": ["The Talos Principle 2", "Talos Principle 2"], "matchExeNames": [], "steamAppIds": ["835960"], "gogGameIds": [], "epicAppNames": [], "stores": ["steam"], "gameEngine": "Unreal Engine 5", "perfProfile": "ultra", "dx9Backend": "auto", "upscaleMode": "balanced", "retinaMode": true, "enableHUD": true, "enableSandbox": false, "status": "preset", "notes": "Starter template (untested): Unreal Engine 5 D3D12 (Lumen/Nanite) through ARM64EC + FEX + Mullion with the D3D12 placed-resource guard; heavy, so Ultra perf mode + MetalFX Performance with the HUD on to judge pacing. In-game DLSS is routed to MetalFX when detected.", "verifiedOn": ["preset"]},
  {"id": "satisfactory", "title": "Satisfactory", "matchTitles": ["Satisfactory"], "matchExeNames": [], "steamAppIds": ["526870"], "gogGameIds": [], "epicAppNames": [], "stores": ["steam", "epic"], "gameEngine": "Unreal Engine 5", "perfProfile": "ultra", "dx9Backend": "auto", "upscaleMode": "balanced", "retinaMode": true, "enableHUD": true, "enableSandbox": false, "status": "preset", "notes": "Starter template (untested): Unreal Engine 5 D3D12 (D3D11 selectable in-game) factory builder; Ultra perf mode + MetalFX Balanced. Steam and Epic builds ship different executables, so it is matched by title / Steam app ID.", "verifiedOn": ["preset"]},
  {"id": "cuphead", "title": "Cuphead", "matchTitles": ["Cuphead"], "matchExeNames": ["Cuphead.exe"], "steamAppIds": ["268910"], "gogGameIds": [], "epicAppNames": [], "stores": ["steam", "gog"], "gameEngine": "Unity", "perfProfile": "balanced", "dx9Backend": "auto", "upscaleMode": "off", "retinaMode": true, "enableHUD": false, "enableSandbox": true, "status": "preset", "notes": "Starter template (untested): Unity D3D11 hand-drawn 2D title; native Retina without upscaling, sandboxed by default.", "verifiedOn": ["preset"]},
  {"id": "subnautica", "title": "Subnautica", "matchTitles": ["Subnautica"], "matchExeNames": ["Subnautica.exe"], "steamAppIds": ["264710"], "gogGameIds": [], "epicAppNames": [], "stores": ["steam", "epic"], "gameEngine": "Unity", "perfProfile": "balanced", "dx9Backend": "auto", "upscaleMode": "quality", "retinaMode": true, "enableHUD": false, "enableSandbox": false, "status": "preset", "notes": "Starter template (untested): Unity D3D11 open-world title; MetalFX Quality keeps native-Retina frame times reasonable.", "verifiedOn": ["preset"]},
  {"id": "ori-and-the-will-of-the-wisps", "title": "Ori and the Will of the Wisps", "matchTitles": ["Ori and the Will of the Wisps"], "matchExeNames": ["oriwotw.exe"], "steamAppIds": ["1057090"], "gogGameIds": [], "epicAppNames": [], "stores": ["steam"], "gameEngine": "Unity", "perfProfile": "balanced", "dx9Backend": "auto", "upscaleMode": "off", "retinaMode": true, "enableHUD": false, "enableSandbox": false, "status": "preset", "notes": "Starter template (untested): Unity D3D11 2.5D platformer; native Retina without upscaling.", "verifiedOn": ["preset"]},
  {"id": "disco-elysium", "title": "Disco Elysium - The Final Cut", "matchTitles": ["Disco Elysium - The Final Cut", "Disco Elysium The Final Cut", "Disco Elysium"], "matchExeNames": ["disco.exe"], "steamAppIds": ["632470"], "gogGameIds": [], "epicAppNames": [], "stores": ["steam", "gog", "epic"], "gameEngine": "Unity", "perfProfile": "balanced", "dx9Backend": "auto", "upscaleMode": "off", "retinaMode": true, "enableHUD": false, "enableSandbox": true, "status": "preset", "notes": "Starter template (untested): Unity D3D11 isometric RPG; native Retina without upscaling, sandboxed by default.", "verifiedOn": ["preset"]},
  {"id": "outer-wilds", "title": "Outer Wilds", "matchTitles": ["Outer Wilds"], "matchExeNames": ["OuterWilds.exe"], "steamAppIds": ["753640"], "gogGameIds": [], "epicAppNames": [], "stores": ["steam", "epic"], "gameEngine": "Unity", "perfProfile": "balanced", "dx9Backend": "auto", "upscaleMode": "quality", "retinaMode": true, "enableHUD": false, "enableSandbox": false, "status": "preset", "notes": "Starter template (untested): Unity D3D11 3D exploration title; MetalFX Quality at native Retina.", "verifiedOn": ["preset"]},
  {"id": "cities-skylines", "title": "Cities: Skylines", "matchTitles": ["Cities: Skylines", "Cities Skylines"], "matchExeNames": ["Cities.exe"], "steamAppIds": ["255710"], "gogGameIds": [], "epicAppNames": [], "stores": ["steam", "epic"], "gameEngine": "Unity", "perfProfile": "balanced", "dx9Backend": "auto", "upscaleMode": "off", "retinaMode": true, "enableHUD": false, "enableSandbox": false, "status": "preset", "notes": "Starter template (untested): Unity D3D11 city builder (CPU-bound late game); balanced perf mode, no upscaling.", "verifiedOn": ["preset"]},
  {"id": "resident-evil-4-remake", "title": "Resident Evil 4 (2023)", "matchTitles": ["Resident Evil 4 Remake", "Resident Evil 4 (2023)"], "matchExeNames": ["re4.exe"], "steamAppIds": ["2050650"], "gogGameIds": [], "epicAppNames": [], "stores": ["steam"], "gameEngine": "RE Engine", "perfProfile": "ultra", "dx9Backend": "auto", "upscaleMode": "quality", "retinaMode": true, "enableHUD": true, "enableSandbox": false, "status": "preset", "notes": "Starter template (untested): RE Engine D3D12 with Capcom anti-tamper DRM; Ultra perf mode + MetalFX Quality. The 2005 release (bio4.exe) is not matched.", "verifiedOn": ["preset"]},
  {"id": "resident-evil-village", "title": "Resident Evil Village", "matchTitles": ["Resident Evil Village", "Resident Evil 8", "RE Village"], "matchExeNames": ["re8.exe"], "steamAppIds": ["1196590"], "gogGameIds": [], "epicAppNames": [], "stores": ["steam"], "gameEngine": "RE Engine", "perfProfile": "ultra", "dx9Backend": "auto", "upscaleMode": "quality", "retinaMode": true, "enableHUD": true, "enableSandbox": false, "status": "preset", "notes": "Starter template (untested): RE Engine D3D12 with Capcom anti-tamper DRM; Ultra perf mode + MetalFX Quality.", "verifiedOn": ["preset"]},
  {"id": "resident-evil-2-remake", "title": "Resident Evil 2 (2019)", "matchTitles": ["Resident Evil 2 Remake", "Resident Evil 2 (2019)"], "matchExeNames": ["re2.exe"], "steamAppIds": ["883710"], "gogGameIds": [], "epicAppNames": [], "stores": ["steam"], "gameEngine": "RE Engine", "perfProfile": "balanced", "dx9Backend": "auto", "upscaleMode": "quality", "retinaMode": true, "enableHUD": true, "enableSandbox": false, "status": "preset", "notes": "Starter template (untested): RE Engine D3D11 / D3D12 with Capcom anti-tamper DRM; MetalFX Quality at native Retina.", "verifiedOn": ["preset"]},
  {"id": "devil-may-cry-5", "title": "Devil May Cry 5", "matchTitles": ["Devil May Cry 5", "DMC5"], "matchExeNames": ["DevilMayCry5.exe"], "steamAppIds": ["601150"], "gogGameIds": [], "epicAppNames": [], "stores": ["steam"], "gameEngine": "RE Engine", "perfProfile": "balanced", "dx9Backend": "auto", "upscaleMode": "quality", "retinaMode": true, "enableHUD": true, "enableSandbox": false, "status": "preset", "notes": "Starter template (untested): RE Engine D3D11 / D3D12 action title; MetalFX Quality to hold high frame rates at native Retina.", "verifiedOn": ["preset"]},
  {"id": "monster-hunter-rise", "title": "Monster Hunter Rise", "matchTitles": ["Monster Hunter Rise"], "matchExeNames": ["MonsterHunterRise.exe"], "steamAppIds": ["1446780"], "gogGameIds": [], "epicAppNames": [], "stores": ["steam"], "gameEngine": "RE Engine", "perfProfile": "balanced", "dx9Backend": "auto", "upscaleMode": "quality", "retinaMode": true, "enableHUD": true, "enableSandbox": false, "status": "preset", "notes": "Starter template (untested): RE Engine D3D12; online hunts need the Steam client signed in.", "verifiedOn": ["preset"]},
  {"id": "street-fighter-6", "title": "Street Fighter 6", "matchTitles": ["Street Fighter 6"], "matchExeNames": ["StreetFighter6.exe"], "steamAppIds": ["1364780"], "gogGameIds": [], "epicAppNames": [], "stores": ["steam"], "gameEngine": "RE Engine", "perfProfile": "ultra", "dx9Backend": "auto", "upscaleMode": "quality", "retinaMode": true, "enableHUD": true, "enableSandbox": false, "status": "preset", "notes": "Starter template (untested): RE Engine D3D12 fighter; online play needs Steam + Capcom ID sign-in and may be affected by anti-cheat.", "verifiedOn": ["preset"]},
  {"id": "mass-effect-andromeda", "title": "Mass Effect: Andromeda", "matchTitles": ["Mass Effect: Andromeda", "Mass Effect Andromeda"], "matchExeNames": ["MassEffectAndromeda.exe"], "steamAppIds": ["1238000"], "gogGameIds": [], "epicAppNames": [], "stores": ["steam"], "gameEngine": "Frostbite 3", "perfProfile": "balanced", "dx9Backend": "auto", "upscaleMode": "quality", "retinaMode": true, "enableHUD": true, "enableSandbox": false, "status": "preset", "notes": "Starter template (untested): Frostbite 3 D3D11; requires the EA app (EA DRM) to be signed in inside the prefix.", "verifiedOn": ["preset"]},
  {"id": "dragon-age-inquisition", "title": "Dragon Age: Inquisition", "matchTitles": ["Dragon Age: Inquisition", "Dragon Age Inquisition"], "matchExeNames": ["DragonAgeInquisition.exe"], "steamAppIds": ["1222690"], "gogGameIds": [], "epicAppNames": [], "stores": ["steam"], "gameEngine": "Frostbite 3", "perfProfile": "balanced", "dx9Backend": "auto", "upscaleMode": "quality", "retinaMode": true, "enableHUD": true, "enableSandbox": false, "status": "preset", "notes": "Starter template (untested): Frostbite 3 D3D11; requires the EA app (EA DRM) to be signed in inside the prefix.", "verifiedOn": ["preset"]},
  {"id": "need-for-speed-heat", "title": "Need for Speed Heat", "matchTitles": ["Need for Speed Heat", "NFS Heat"], "matchExeNames": ["NeedForSpeedHeat.exe"], "steamAppIds": ["1222680"], "gogGameIds": [], "epicAppNames": [], "stores": ["steam"], "gameEngine": "Frostbite 3", "perfProfile": "ultra", "dx9Backend": "auto", "upscaleMode": "quality", "retinaMode": true, "enableHUD": true, "enableSandbox": false, "status": "preset", "notes": "Starter template (untested): Frostbite 3 racer; requires the EA app (EA DRM) to be signed in inside the prefix.", "verifiedOn": ["preset"]},
  {"id": "dead-space-remake", "title": "Dead Space (2023)", "matchTitles": ["Dead Space Remake", "Dead Space (2023)"], "matchExeNames": [], "steamAppIds": ["1693980"], "gogGameIds": [], "epicAppNames": [], "stores": ["steam"], "gameEngine": "Frostbite 3", "perfProfile": "ultra", "dx9Backend": "auto", "upscaleMode": "performance", "retinaMode": true, "enableHUD": true, "enableSandbox": false, "status": "preset", "notes": "Starter template (untested): Frostbite D3D12-only remake; requires the EA app (EA DRM). Matched by Steam app ID only, never the 2008 original's title or Dead Space.exe.", "verifiedOn": ["preset"]},
  {"id": "the-witcher-3", "title": "The Witcher 3: Wild Hunt", "matchTitles": ["The Witcher 3: Wild Hunt", "The Witcher 3", "Witcher 3", "The Witcher 3: Wild Hunt - Game of the Year Edition", "The Witcher 3: Wild Hunt - Complete Edition"], "matchExeNames": ["witcher3.exe"], "steamAppIds": ["292030", "499450"], "gogGameIds": ["1207664643", "1495134320"], "epicAppNames": [], "stores": ["steam", "gog", "epic"], "gameEngine": "REDengine 3", "perfProfile": "balanced", "dx9Backend": "auto", "upscaleMode": "quality", "retinaMode": true, "enableHUD": true, "enableSandbox": false, "status": "preset", "notes": "Starter template (untested): REDengine 3; the next-gen update ships bin/x64/witcher3.exe (D3D11) and bin/x64_dx12/witcher3.exe (D3D12). Start with the D3D11 executable and MetalFX Quality.", "verifiedOn": ["preset"]},
  {"id": "dota-2", "title": "Dota 2", "matchTitles": ["Dota 2"], "matchExeNames": ["dota2.exe"], "steamAppIds": ["570"], "gogGameIds": [], "epicAppNames": [], "stores": ["steam"], "gameEngine": "Source 2", "perfProfile": "balanced", "dx9Backend": "auto", "upscaleMode": "off", "retinaMode": true, "enableHUD": false, "enableSandbox": false, "status": "preset", "notes": "Starter template (untested): Source 2 with the D3D11 renderer (its Vulkan renderer is not accelerated by DirectMetal's DirectX path); online play needs the Steam client signed in.", "verifiedOn": ["preset"]},
  {"id": "counter-strike-2", "title": "Counter-Strike 2", "matchTitles": ["Counter-Strike 2", "CS2"], "matchExeNames": ["cs2.exe"], "steamAppIds": ["730"], "gogGameIds": [], "epicAppNames": [], "stores": ["steam"], "gameEngine": "Source 2", "perfProfile": "balanced", "dx9Backend": "auto", "upscaleMode": "off", "retinaMode": true, "enableHUD": false, "enableSandbox": false, "status": "preset", "notes": "Starter template (untested): Source 2 D3D11; VAC-secured online play needs the Steam client signed in and has not been validated.", "verifiedOn": ["preset"]}
 ]
}
"""#
}

// MARK: - GOG Galaxy / Epic Games Store metadata

/// One game installed by a storefront, as described by the store's own metadata.
struct StoreGameRecord {
    /// `gog` or `epic`.
    let source: String
    /// GOG `gameId` / Epic `AppName`.
    let gameID: String?
    let title: String
    let installDir: URL
    /// The store's launch executable (may be missing on disk; callers fall back to folder heuristics).
    let exeURL: URL?
}

/// Pure filesystem readers for GOG Galaxy (`goggame-<id>.info`), Epic Games Launcher (`Manifests/*.item`,
/// `.egstore/*.mancpn`) and Heroic (`legendaryConfig/legendary/installed.json`, `gog_store/installed.json`).
enum StoreMetadataLocator {
    struct GOGPlayTask {
        let path: String
        let isPrimary: Bool
        let category: String?
        let type: String?
    }

    struct GOGInfo {
        let gameID: String
        let rootGameID: String?
        let name: String
        let playTasks: [GOGPlayTask]
    }

    /// `$HOME`-aware home directory (tests run with a temporary HOME).
    static func homeDirectory() -> URL {
        if let h = ProcessInfo.processInfo.environment["HOME"], !h.isEmpty {
            return URL(fileURLWithPath: h, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static func heroicRoot() -> URL {
        homeDirectory().appendingPathComponent("Library/Application Support/heroic", isDirectory: true)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func subdirectories(of dir: URL) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return items.filter { isDirectory($0) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func readJSON(_ url: URL, maxBytes: Int = 8 << 20) -> Any? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.intValue, size > 0, size <= maxBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func stringValue(_ v: Any?) -> String? {
        if let s = v as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    /// `bin\x64\game.exe` -> `<base>/bin/x64/game.exe`.
    static func resolveRelative(_ raw: String, in base: URL) -> URL? {
        var rel = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/")
        while rel.hasPrefix("./") { rel.removeFirst(2) }
        while rel.hasPrefix("/") { rel.removeFirst() }
        guard !rel.isEmpty, !rel.split(separator: "/").contains("..") else { return nil }
        return base.appendingPathComponent(rel)
    }

    // MARK: GOG

    static func gogInfoFiles(in dir: URL) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return items.filter {
            let l = $0.lowercased()
            return l.hasPrefix("goggame-") && l.hasSuffix(".info")
        }.sorted().map { dir.appendingPathComponent($0) }
    }

    static func parseGOGInfo(_ url: URL) -> GOGInfo? {
        guard let obj = readJSON(url, maxBytes: 1 << 20) as? [String: Any],
              let id = stringValue(obj["gameId"]) else { return nil }
        let tasks: [GOGPlayTask] = ((obj["playTasks"] as? [[String: Any]]) ?? []).compactMap { t in
            guard let path = stringValue(t["path"]) else { return nil }
            return GOGPlayTask(path: path, isPrimary: (t["isPrimary"] as? Bool) ?? false,
                               category: stringValue(t["category"])?.lowercased(), type: stringValue(t["type"]))
        }
        let name = stringValue(obj["name"]) ?? url.deletingLastPathComponent().lastPathComponent
        return GOGInfo(gameID: id, rootGameID: stringValue(obj["rootGameId"]), name: name, playTasks: tasks)
    }

    /// The base game's `.info` in `dir` (DLC infos share the folder but carry a different `rootGameId`).
    static func primaryGOGInfo(in dir: URL, preferredID: String? = nil) -> (url: URL, info: GOGInfo)? {
        let infos = gogInfoFiles(in: dir).compactMap { u in parseGOGInfo(u).map { (url: u, info: $0) } }
        guard !infos.isEmpty else { return nil }
        if let id = preferredID, let m = infos.first(where: { $0.info.gameID == id }) { return m }
        func isRoot(_ i: GOGInfo) -> Bool { i.rootGameID == nil || i.rootGameID == i.gameID }
        return infos.first { isRoot($0.info) && !$0.info.playTasks.isEmpty }
            ?? infos.first { isRoot($0.info) }
            ?? infos.first
    }

    /// Primary `FileTask` `.exe` of a GOG game (uninstallers, documents, tools and URL tasks skipped).
    static func gogExecutable(info: GOGInfo, gameDir: URL) -> URL? {
        let excludedCategories: Set<String> = ["document", "tool"]
        let candidates = info.playTasks.enumerated().filter { _, t in
            (t.type == nil || t.type == "FileTask")
                && t.path.lowercased().hasSuffix(".exe")
                && !excludedCategories.contains(t.category ?? "")
                && !GameLibraryManager.isExcludedExecutable((t.path.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent)
        }.sorted { a, b in
            let ka = (a.element.isPrimary ? 0 : 1, a.element.category == "game" ? 0 : 1, a.offset)
            let kb = (b.element.isPrimary ? 0 : 1, b.element.category == "game" ? 0 : 1, b.offset)
            return ka < kb
        }
        for (_, t) in candidates {
            if let u = resolveRelative(t.path, in: gameDir), FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return candidates.first.flatMap { resolveRelative($0.element.path, in: gameDir) }
    }

    static func gogRecord(gameDir: URL, preferredID: String? = nil) -> StoreGameRecord? {
        guard let p = primaryGOGInfo(in: gameDir, preferredID: preferredID) else { return nil }
        return StoreGameRecord(source: "gog", gameID: p.info.gameID, title: p.info.name, installDir: gameDir,
                               exeURL: gogExecutable(info: p.info, gameDir: gameDir))
    }

    // MARK: Epic

    static func hasEGStore(gameDir: URL) -> Bool {
        isDirectory(gameDir.appendingPathComponent(".egstore", isDirectory: true))
    }

    /// `AppName` from `.egstore/*.mancpn` (nil when absent / unreadable).
    static func egstoreAppName(gameDir: URL) -> String? {
        let eg = gameDir.appendingPathComponent(".egstore", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: eg.path) else { return nil }
        for name in items.sorted() where name.lowercased().hasSuffix(".mancpn") {
            if let obj = readJSON(eg.appendingPathComponent(name), maxBytes: 1 << 20) as? [String: Any],
               let app = stringValue(obj["AppName"]) {
                return app
            }
        }
        return nil
    }

    static func epicRecord(gameDir: URL) -> StoreGameRecord? {
        guard hasEGStore(gameDir: gameDir) else { return nil }
        return StoreGameRecord(source: "epic", gameID: egstoreAppName(gameDir: gameDir), title: gameDir.lastPathComponent,
                               installDir: gameDir, exeURL: nil)
    }

    /// `C:\Games\X` -> `<prefix>/drive_c/Games/X` (via `dosdevices` when present); `Z:\…` -> `/…`; POSIX paths as-is.
    static func windowsPathToUnix(_ raw: String, prefix: URL?) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("/") { return URL(fileURLWithPath: s) }
        let chars = Array(s)
        guard chars.count >= 2, chars[0].isASCII, chars[0].isLetter, chars[1] == ":" else { return nil }
        let letter = String(chars[0]).lowercased()
        var rest = String(chars.dropFirst(2)).replacingOccurrences(of: "\\", with: "/")
        while rest.hasPrefix("/") { rest.removeFirst() }
        var base: URL? = nil
        if let prefix {
            let dosdevices = prefix.appendingPathComponent("dosdevices", isDirectory: true)
            let link = dosdevices.appendingPathComponent("\(letter):")
            if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) {
                base = dest.hasPrefix("/") ? URL(fileURLWithPath: dest, isDirectory: true)
                    : dosdevices.appendingPathComponent(dest, isDirectory: true).standardizedFileURL
            } else if letter == "c" {
                base = prefix.appendingPathComponent("drive_c", isDirectory: true)
            }
        }
        if base == nil && letter == "z" { base = URL(fileURLWithPath: "/", isDirectory: true) }
        guard let b = base else { return nil }
        return rest.isEmpty ? b : b.appendingPathComponent(rest)
    }

    /// One Epic Games Launcher `Manifests/*.item` (DLC, add-ons and incomplete installs skipped).
    static func parseEpicManifest(_ url: URL, prefix: URL?) -> StoreGameRecord? {
        guard let obj = readJSON(url, maxBytes: 4 << 20) as? [String: Any],
              let appName = stringValue(obj["AppName"]),
              let location = stringValue(obj["InstallLocation"]) else { return nil }
        if (obj["bIsIncompleteInstall"] as? Bool) == true { return nil }
        if let main = stringValue(obj["MainGameAppName"]), main != appName { return nil }
        if let cats = obj["AppCategories"] as? [String], !cats.isEmpty,
           !cats.contains(where: { $0.lowercased() == "games" }) { return nil }
        guard let installDir = windowsPathToUnix(location, prefix: prefix) else { return nil }
        let exe = stringValue(obj["LaunchExecutable"]).flatMap { resolveRelative($0, in: installDir) }
        let title = stringValue(obj["DisplayName"]) ?? installDir.lastPathComponent
        return StoreGameRecord(source: "epic", gameID: appName, title: title, installDir: installDir, exeURL: exe)
    }

    // MARK: Aggregate scans

    /// GOG `.info` first (exact title + launch task), then Epic `.egstore`.
    static func storeRecord(forGameFolder dir: URL) -> StoreGameRecord? {
        gogRecord(gameDir: dir) ?? epicRecord(gameDir: dir)
    }

    /// GOG Galaxy + Epic Games Launcher installs inside one Wine prefix.
    static func storeRecords(inPrefix prefix: URL) -> [StoreGameRecord] {
        let driveC = prefix.appendingPathComponent("drive_c", isDirectory: true)
        guard isDirectory(driveC) else { return [] }
        var out: [StoreGameRecord] = []
        var seen = Set<String>()
        func add(_ r: StoreGameRecord?) {
            guard let r, seen.insert(r.source + "|" + r.installDir.standardizedFileURL.path.lowercased()).inserted else { return }
            out.append(r)
        }
        for rel in ["GOG Games", "Program Files (x86)/GOG Galaxy/Games", "Program Files/GOG Galaxy/Games"] {
            for dir in subdirectories(of: driveC.appendingPathComponent(rel, isDirectory: true)) {
                add(gogRecord(gameDir: dir))
            }
        }
        let manifests = driveC.appendingPathComponent("ProgramData/Epic/EpicGamesLauncher/Data/Manifests", isDirectory: true)
        if let items = try? FileManager.default.contentsOfDirectory(atPath: manifests.path) {
            for name in items.sorted() where name.lowercased().hasSuffix(".item") {
                add(parseEpicManifest(manifests.appendingPathComponent(name), prefix: prefix))
            }
        }
        for rel in ["Program Files/Epic Games", "Program Files (x86)/Epic Games"] {
            for dir in subdirectories(of: driveC.appendingPathComponent(rel, isDirectory: true)) {
                add(epicRecord(gameDir: dir))
            }
        }
        return out
    }

    /// `~/Games/*`, `~/Games/Heroic/*` plus Heroic's legendary (Epic) and GOG installed lists.
    static func homeStoreRecords() -> [StoreGameRecord] {
        var out: [StoreGameRecord] = []
        var seen = Set<String>()
        func add(_ r: StoreGameRecord?) {
            guard let r, seen.insert(r.source + "|" + r.installDir.standardizedFileURL.path.lowercased()).inserted else { return }
            out.append(r)
        }
        let games = homeDirectory().appendingPathComponent("Games", isDirectory: true)
        for root in [games, games.appendingPathComponent("Heroic", isDirectory: true)] {
            for dir in subdirectories(of: root) { add(storeRecord(forGameFolder: dir)) }
        }
        for r in heroicLegendaryRecords() { add(r) }
        for r in heroicGOGRecords() { add(r) }
        return out
    }

    /// Heroic `legendaryConfig/legendary/installed.json` (Windows, non-DLC entries).
    static func heroicLegendaryRecords() -> [StoreGameRecord] {
        let url = heroicRoot().appendingPathComponent("legendaryConfig/legendary/installed.json")
        guard let obj = readJSON(url) as? [String: Any] else { return [] }
        var out: [StoreGameRecord] = []
        for (key, value) in obj.sorted(by: { $0.key < $1.key }) {
            guard let e = value as? [String: Any], (e["is_dlc"] as? Bool) != true,
                  let path = stringValue(e["install_path"]) else { continue }
            if let platform = stringValue(e["platform"])?.lowercased(), !platform.hasPrefix("win") { continue }
            let dir = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            let exe = stringValue(e["executable"]).flatMap { resolveRelative($0, in: dir) }
            out.append(StoreGameRecord(source: "epic", gameID: stringValue(e["app_name"]) ?? key,
                                       title: stringValue(e["title"]) ?? dir.lastPathComponent, installDir: dir, exeURL: exe))
        }
        return out
    }

    /// Heroic `gog_store/installed.json` (Windows, non-DLC entries; details come from the game's `.info`).
    static func heroicGOGRecords() -> [StoreGameRecord] {
        let url = heroicRoot().appendingPathComponent("gog_store/installed.json")
        guard let obj = readJSON(url) as? [String: Any], let list = obj["installed"] as? [[String: Any]] else { return [] }
        var out: [StoreGameRecord] = []
        for e in list where (e["is_dlc"] as? Bool) != true {
            guard let path = stringValue(e["install_path"]) else { continue }
            if let platform = stringValue(e["platform"])?.lowercased(), !platform.hasPrefix("win") { continue }
            let dir = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            let id = stringValue(e["appName"])
            if let rec = gogRecord(gameDir: dir, preferredID: id) {
                out.append(rec)
            } else {
                out.append(StoreGameRecord(source: "gog", gameID: id, title: dir.lastPathComponent, installDir: dir, exeURL: nil))
            }
        }
        return out
    }

    // MARK: Detection from an executable path

    private static let stopDirNames: Set<String> = [
        "drive_c", "steamapps", "common", "program files", "program files (x86)", "gog games", "games",
        "epic games", "heroic", "applications", "users", "volumes",
    ]

    /// Folders from the executable's directory up to (excluding) the first library-level folder.
    static func gameAncestors(forExePath exePath: String, maxLevels: Int = 6) -> [URL] {
        guard !exePath.isEmpty else { return [] }
        let home = homeDirectory().standardizedFileURL.path
        var out: [URL] = []
        var dir = URL(fileURLWithPath: exePath).standardizedFileURL.deletingLastPathComponent()
        for _ in 0..<maxLevels {
            let path = dir.path
            if path == "/" || path == home || stopDirNames.contains(dir.lastPathComponent.lowercased()) { break }
            out.append(dir)
            dir = dir.deletingLastPathComponent()
        }
        return out
    }

    /// Storefront for an installed executable: GOG `.info` / Epic `.egstore` in its game folder, else a Steam library.
    static func detectStore(forExePath exePath: String) -> (source: String, gameID: String?)? {
        for dir in gameAncestors(forExePath: exePath) {
            if let p = primaryGOGInfo(in: dir) { return ("gog", p.info.gameID) }
            if hasEGStore(gameDir: dir) { return ("epic", egstoreAppName(gameDir: dir)) }
        }
        if SteamLibraryLocator.steamLocation(forExePath: exePath) != nil { return ("steam", nil) }
        return nil
    }

    /// GOG game root (the folder holding `goggame-<id>.info`) for an executable.
    static func gogGameRoot(forExePath exePath: String, gameID: String?) -> (dir: URL, gameID: String)? {
        for dir in gameAncestors(forExePath: exePath) {
            if let p = primaryGOGInfo(in: dir, preferredID: gameID) { return (dir, p.info.gameID) }
        }
        return nil
    }

    /// Epic game root (the folder holding `.egstore`), else the executable's top-most game folder.
    static func epicGameRoot(forExePath exePath: String) -> URL? {
        let chain = gameAncestors(forExePath: exePath)
        return chain.first(where: { hasEGStore(gameDir: $0) }) ?? chain.last
    }
}
