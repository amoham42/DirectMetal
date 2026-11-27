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
        lastPlayedUtc: String? = nil
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
    }

    enum CodingKeys: String, CodingKey {
        case id, title, exePath, prefixName, engine, perfProfile, dx9Backend, upscaleMode
        case retinaMode, enableHUD, enableSandbox, extraArgs, architecture, detectedAPIs
        case detectedUpscalers, buildHash, playCount, lastPlayedUtc
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
            result = entries[idx]
        } else {
            let prefixMap = previouslyUsedPrefixes()
            var entry = GameLibraryEntry(
                title: (title?.isEmpty == false) ? title! : GameLibraryManager.deriveTitle(exePath: canonical),
                exePath: canonical,
                prefixName: prefixMap[canonical] ?? GameLibraryManager.defaultPrefixName(exePath: canonical)
            )
            entry.apply(profile: profile)
            entries.append(entry)
            result = entry
        }
        // Explicitly adding a game always un-hides it.
        var hidden = loadHidden()
        if hidden.remove(canonical) != nil { saveHidden(hidden) }
        save(entries)
        return result
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
    }

    /// Scans known locations, merges with the saved library (preserving user settings),
    /// re-inspects every executable, persists, and returns the full sorted library.
    @discardableResult
    func scanKnownLocations(extraDirs: [String] = []) -> [GameLibraryEntry] {
        let fm = FileManager.default
        let hidden = loadHidden()
        let prefixMap = previouslyUsedPrefixes()

        var discoveries: [Discovery] = []
        // 1. Explicit folders + DIRECTMETAL_SCAN_DIR + <cwd>/.directmetal_cache/games
        for dir in scanRoots(extraDirs: extraDirs) {
            discoveries.append(contentsOf: scanGameFolderRoot(dir))
        }
        // 2. Steam libraries inside DirectMetal prefixes
        discoveries.append(contentsOf: scanSteamLibraries())
        // 3. Previously launched executables recorded in prefix metadata
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
        }

        for d in discoveries {
            let c = GameLibraryManager.canonicalPath(d.exePath)
            if indexByPath[c] != nil || hidden.contains(c) { continue }
            guard fm.fileExists(atPath: c), let prof = try? PEInspector.inspect(exePath: c) else { continue }
            var entry = GameLibraryEntry(
                title: d.title,
                exePath: c,
                prefixName: prefixMap[c] ?? d.prefixName ?? GameLibraryManager.defaultPrefixName(exePath: c)
            )
            entry.apply(profile: prof)
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
            guard let exe = GameLibraryManager.primaryExecutable(inGameFolder: root, titleHint: root.lastPathComponent)
            else { return [] }
            return [Discovery(exePath: exe.path, title: root.lastPathComponent, prefixName: nil)]
        }
        return dirs.compactMap { dir in
            GameLibraryManager.primaryExecutable(inGameFolder: dir, titleHint: dir.lastPathComponent).map {
                Discovery(exePath: $0.path, title: dir.lastPathComponent, prefixName: nil)
            }
        }
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
                        out.append(Discovery(exePath: exe.path, title: title, prefixName: dir.lastPathComponent))
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
