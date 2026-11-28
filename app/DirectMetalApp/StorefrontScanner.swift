import Foundation

// MARK: - Storefront scanning & Steam ACF helpers

extension GameLibraryManager {
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

    // MARK: GOG Galaxy / Epic Games Store

    /// Store record -> discovery: the store's own launch executable, else the folder heuristic.
    func discovery(from rec: StoreGameRecord, prefixName: String?) -> Discovery? {
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
    func scanStorePrefix(_ prefix: URL, prefixName: String?) -> [Discovery] {
        var out: [Discovery] = []
        for rec in StoreMetadataLocator.storeRecords(inPrefix: prefix) {
            if let d = discovery(from: rec, prefixName: prefixName) { out.append(d) }
        }
        return out
    }

    /// Every DirectMetal prefix, `~/Games` (incl. Heroic's `~/Games/Heroic`) and Heroic's installed lists.
    func scanStoreLibraries() -> [Discovery] {
        var out: [Discovery] = []
        for dir in prefixDirectories() {
            out.append(contentsOf: scanStorePrefix(dir, prefixName: dir.lastPathComponent))
        }
        for rec in StoreMetadataLocator.homeStoreRecords() {
            if let d = discovery(from: rec, prefixName: nil) { out.append(d) }
        }
        return out
    }

    // MARK: Steam libraries & ACF parsing

    func scanSteamLibraries() -> [Discovery] {
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
