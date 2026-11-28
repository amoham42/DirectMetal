import AppKit
import CoreGraphics
import Darwin
import Foundation

// MARK: - Steam library discovery

/// Locates Steam libraries, app IDs and the local `appcache/librarycache` artwork folders for a game executable.
/// Pure filesystem lookups (no network, no Steam client required).
enum SteamLibraryLocator {
    private struct CachedManifestIndex {
        let mtimeSec: Int
        let mtimeNsec: Int
        let index: [String: String]
    }

    private static let manifestCacheLock = NSLock()
    private static var manifestCache: [String: CachedManifestIndex] = [:]

    /// Clears the in-memory `appmanifest_*.acf` directory index cache (used by tests or after rescan).
    static func invalidateManifestCache() {
        manifestCacheLock.lock()
        manifestCache.removeAll()
        manifestCacheLock.unlock()
    }

    /// For `/…/steamapps/common/<installdir>/…/game.exe` returns the `steamapps` folder and `<installdir>`.
    static func steamLocation(forExePath exePath: String) -> (steamapps: URL, installDir: String)? {
        let comps = URL(fileURLWithPath: exePath).standardizedFileURL.pathComponents
        let lower = comps.map { $0.lowercased() }
        guard let ci = lower.lastIndex(of: "common"), ci >= 1, lower[ci - 1] == "steamapps", ci + 1 < comps.count - 1
        else { return nil }
        let steamapps = URL(fileURLWithPath: NSString.path(withComponents: Array(comps[0..<ci])), isDirectory: true)
        return (steamapps, comps[ci + 1])
    }

    /// `installdir` (lowercased) -> appid for every `appmanifest_*.acf` in a `steamapps` folder.
    /// Cached per `(path, dir mtime)` so scanning or loading artwork for N Steam games is O(N) instead of O(N^2).
    static func manifestIndex(steamapps: URL) -> [String: String] {
        let path = steamapps.standardizedFileURL.path
        var st = stat()
        let hasStat = (stat(path, &st) == 0)
        if hasStat {
            manifestCacheLock.lock()
            if let hit = manifestCache[path],
               hit.mtimeSec == st.st_mtimespec.tv_sec,
               hit.mtimeNsec == st.st_mtimespec.tv_nsec {
                manifestCacheLock.unlock()
                return hit.index
            }
            manifestCacheLock.unlock()
        }
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [:] }
        var out: [String: String] = [:]
        for file in items.sorted() where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
            guard let text = try? String(contentsOf: steamapps.appendingPathComponent(file), encoding: .utf8) else { continue }
            let fields = GameLibraryManager.parseACF(text)
            let fileID = String(file.dropFirst("appmanifest_".count).dropLast(".acf".count))
            let appid = fields["appid"].flatMap { isAppID($0) ? $0 : nil } ?? (isAppID(fileID) ? fileID : nil)
            if let appid, let dir = fields["installdir"], !dir.isEmpty, out[dir.lowercased()] == nil {
                out[dir.lowercased()] = appid
            }
        }
        if hasStat {
            manifestCacheLock.lock()
            if manifestCache.count > 64 { manifestCache.removeAll() }
            manifestCache[path] = CachedManifestIndex(
                mtimeSec: st.st_mtimespec.tv_sec,
                mtimeNsec: st.st_mtimespec.tv_nsec,
                index: out
            )
            manifestCacheLock.unlock()
        }
        return out
    }

    static func isAppID(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 12 && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Steam app ID for an executable: Steam library manifest (`installdir` -> `appid`) first, then a
    /// `steam_appid.txt` next to the executable or in up to three parent game folders.
    static func steamAppID(forExePath exePath: String) -> String? {
        guard !exePath.isEmpty else { return nil }
        if let loc = steamLocation(forExePath: exePath),
           let id = manifestIndex(steamapps: loc.steamapps)[loc.installDir.lowercased()] {
            return id
        }
        let fm = FileManager.default
        let stopNames: Set<String> = ["common", "steamapps", "games", "program files", "program files (x86)", "drive_c"]
        var dir = URL(fileURLWithPath: exePath).deletingLastPathComponent()
        for _ in 0..<4 {
            if stopNames.contains(dir.lastPathComponent.lowercased()) || dir.path == "/" { break }
            let txt = dir.appendingPathComponent("steam_appid.txt")
            if let attrs = try? fm.attributesOfItem(atPath: txt.path),
               let size = attrs[.size] as? NSNumber, size.intValue <= 64,
               let raw = try? Data(contentsOf: txt) {
                // Steam writes e.g. "440\n\0": take the leading digits, ignoring whitespace / NUL padding.
                let text = String(decoding: raw, as: UTF8.self)
                let id = String(text.drop(while: { $0.isWhitespace }).prefix(while: { $0.isASCII && $0.isNumber }))
                if isAppID(id) { return id }
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Every existing `appcache/librarycache` folder that may hold artwork for `exePath`: the Steam root that owns
    /// the game's library, the native macOS Steam client, and Windows Steam inside DirectMetal Wine prefixes.
    static func librarycacheDirectories(forExePath exePath: String, prefixRoot: URL) -> [URL] {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let loc = steamLocation(forExePath: exePath) {
            candidates.append(loc.steamapps.deletingLastPathComponent().appendingPathComponent("appcache/librarycache", isDirectory: true))
        }
        let env = ProcessInfo.processInfo.environment
        let home = env["HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fm.homeDirectoryForCurrentUser
        candidates.append(home.appendingPathComponent("Library/Application Support/Steam/appcache/librarycache", isDirectory: true))
        if let prefixes = try? fm.contentsOfDirectory(at: prefixRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for prefix in prefixes.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                for programFiles in ["Program Files (x86)", "Program Files"] {
                    candidates.append(prefix.appendingPathComponent("drive_c/\(programFiles)/Steam/appcache/librarycache", isDirectory: true))
                }
            }
        }
        var seen = Set<String>()
        return candidates.filter { url in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue && seen.insert(url.path).inserted
        }
    }
}

// MARK: - Artwork manager

enum ArtworkStyle: String {
    /// Wide hero art (Steam header / library poster), falling back to the executable icon.
    case banner
    /// Square art for list rows (Steam icon / executable icon), falling back to the Steam header.
    case icon
}

/// Resolved artwork plus where it came from (`gog-webcache`, `gog-folder`, `gog-ico`, `epic-heroic`,
/// `epic-folder`, `steam`, `exe-icon`).
struct ArtworkResolution {
    let image: NSImage
    let source: String
    let path: String

    /// Every decoder in this file builds its `NSImage` with `size` == source pixel dimensions (CG snapshot
    /// representations would report backing-scaled pixels instead).
    var pixelWidth: Int { Int(image.size.width.rounded()) }

    var pixelHeight: Int { Int(image.size.height.rounded()) }
}

/// Resolves real game artwork (local Steam library cache art or the icon embedded in the Windows `.exe`)
/// with a thread-safe in-memory cache. Safe to call from any thread; misses are cached too so list rows
/// never re-scan the disk while scrolling.
final class GameArtworkManager: @unchecked Sendable {
    static let shared = GameArtworkManager()

    private let cache = NSCache<NSString, NSImage>()
    private let lock = NSLock()
    private var misses = Set<String>()
    private let prefixRoot: URL

    init(prefixRoot: URL? = nil) {
        self.prefixRoot = prefixRoot ?? PrefixManager().prefixRoot
        cache.countLimit = 256
    }

    private func cacheKey(_ entry: GameLibraryEntry, _ style: ArtworkStyle) -> String {
        GameArtworkManager.artworkKey(entry, style)
    }

    /// Identity of an entry's artwork (also used by the GUI to reload when store metadata changes).
    static func artworkKey(_ entry: GameLibraryEntry, _ style: ArtworkStyle) -> String {
        "\(style.rawValue)|\(entry.steamAppID ?? "")|\(entry.storeSource ?? "")|\(entry.storeGameID ?? "")|\(entry.exePath)"
    }

    /// Detail-banner artwork for `entry` (Steam header/poster, else `.exe` icon), or `nil` => `GameMonogram`.
    func loadArtwork(for entry: GameLibraryEntry) -> NSImage? {
        loadArtwork(for: entry, style: .banner)
    }

    /// Cached result only (never touches the disk) — for instant first paint of list rows.
    func cachedArtwork(for entry: GameLibraryEntry, style: ArtworkStyle) -> NSImage? {
        cache.object(forKey: cacheKey(entry, style) as NSString)
    }

    func loadArtwork(for entry: GameLibraryEntry, style: ArtworkStyle) -> NSImage? {
        let key = cacheKey(entry, style)
        if let hit = cache.object(forKey: key as NSString) { return hit }
        lock.lock()
        let knownMiss = misses.contains(key)
        lock.unlock()
        if knownMiss { return nil }

        let image = resolve(entry, style)
        if let image {
            cache.setObject(image, forKey: key as NSString)
        } else {
            lock.lock()
            misses.insert(key)
            lock.unlock()
        }
        return image
    }

    /// Forget cached artwork (e.g. after a library rescan or Steam artwork download).
    func invalidate() {
        cache.removeAllObjects()
        lock.lock()
        misses.removeAll()
        lock.unlock()
    }

    private func resolve(_ entry: GameLibraryEntry, _ style: ArtworkStyle) -> NSImage? {
        resolveArtwork(for: entry, style: style)?.image
    }

    /// Uncached resolution with provenance (`library artwork` CLI / diagnostics). Order: GOG / Epic store art
    /// -> Steam library cache -> the Windows `.exe`'s embedded icon -> `nil` (`GameMonogram`).
    func resolveArtwork(for entry: GameLibraryEntry, style: ArtworkStyle) -> ArtworkResolution? {
        switch entry.storeSource {
        case "gog":
            if let r = gogArtwork(entry, style) { return r }
        case "epic":
            if let r = epicArtwork(entry, style) { return r }
        default:
            break
        }
        let appID = entry.steamAppID ?? SteamLibraryLocator.steamAppID(forExePath: entry.exePath)
        let steam: (ArtworkStyle) -> ArtworkResolution? = { s in
            guard let appID else { return nil }
            return self.steamArtwork(appID: appID, exePath: entry.exePath, style: s)
        }
        let exeIcon: () -> ArtworkResolution? = {
            PEIconExtractor.extractIcon(exePath: entry.exePath).map {
                ArtworkResolution(image: $0, source: "exe-icon", path: entry.exePath)
            }
        }
        switch style {
        case .banner:
            return steam(.banner) ?? exeIcon()
        case .icon:
            return steam(.icon) ?? exeIcon() ?? steam(.banner)
        }
    }

    // MARK: GOG Galaxy / Epic artwork

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "ico", "bmp", "gif", "tif", "tiff"]

    /// First decodable image among `names` in `dir` (case-insensitive file names).
    private func firstImage(in dir: URL, names: [String], source: String) -> ArtworkResolution? {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let byLower = Dictionary(items.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        for name in names {
            guard let real = byLower[name.lowercased()] else { continue }
            let url = dir.appendingPathComponent(real)
            if let img = Self.decodeImageFile(at: url) { return ArtworkResolution(image: img, source: source, path: url.path) }
        }
        return nil
    }

    /// Images under `dir` (max depth 2) whose lowercased file name starts with one of `prefixes`, in prefix order.
    private func prefixedImage(under dir: URL, prefixes: [String], source: String) -> ArtworkResolution? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return nil }
        var files: [URL] = []
        while let obj = en.nextObject() {
            guard let url = obj as? URL else { continue }
            if en.level > 2 { en.skipDescendants(); continue }
            if Self.imageExtensions.contains(url.pathExtension.lowercased()) { files.append(url) }
            if files.count > 512 { break }
        }
        files.sort { $0.path < $1.path }
        for prefix in prefixes {
            for url in files where url.lastPathComponent.lowercased().hasPrefix(prefix) {
                if let img = Self.decodeImageFile(at: url) { return ArtworkResolution(image: img, source: source, path: url.path) }
            }
        }
        return nil
    }

    /// GOG: `webcache/<id>/` art (game folder or the prefix's `ProgramData/GOG.com/Galaxy/webcache`), folder
    /// cover art, then `goggame-<id>.ico` / `support.ico` / `gfw_high.ico`.
    private func gogArtwork(_ entry: GameLibraryEntry, _ style: ArtworkStyle) -> ArtworkResolution? {
        guard let root = StoreMetadataLocator.gogGameRoot(forExePath: entry.exePath, gameID: entry.storeGameID) else { return nil }
        let id = entry.storeGameID ?? root.gameID
        var webcaches = [root.dir.appendingPathComponent("webcache/\(id)", isDirectory: true)]
        let comps = root.dir.pathComponents
        if let ci = comps.lastIndex(where: { $0.lowercased() == "drive_c" }) {
            let driveC = URL(fileURLWithPath: NSString.path(withComponents: Array(comps[0...ci])), isDirectory: true)
            webcaches.append(driveC.appendingPathComponent("ProgramData/GOG.com/Galaxy/webcache/\(id)", isDirectory: true))
        }
        let cover: () -> ArtworkResolution? = {
            for dir in webcaches {
                if let r = self.prefixedImage(under: dir, prefixes: ["cover", "background", "logo"], source: "gog-webcache") { return r }
            }
            return self.firstImage(in: root.dir, names: ["cover.jpg", "cover.png", "folder.jpg", "folder.png", "logo.png"],
                                   source: "gog-folder")
        }
        let icon: () -> ArtworkResolution? = {
            if let r = self.firstImage(in: root.dir, names: ["goggame-\(id).ico", "support.ico", "gfw_high.ico", "icon.ico", "icon.png"],
                                       source: "gog-ico") { return r }
            for dir in webcaches {
                if let r = self.prefixedImage(under: dir, prefixes: ["icon", "square"], source: "gog-webcache") { return r }
            }
            return nil
        }
        switch style {
        case .banner: return cover() ?? icon()
        case .icon: return icon() ?? cover()
        }
    }

    /// Epic: Heroic `images-cache/` + `icons/` (matched by `AppName`), then cover / icon files in the game folder.
    private func epicArtwork(_ entry: GameLibraryEntry, _ style: ArtworkStyle) -> ArtworkResolution? {
        let fm = FileManager.default
        let heroic = StoreMetadataLocator.heroicRoot()
        let id = entry.storeGameID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let heroicCache: () -> ArtworkResolution? = {
            guard id.count >= 3 else { return nil }
            let dir = heroic.appendingPathComponent("images-cache", isDirectory: true)
            guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
            let low = id.lowercased()
            for name in items.sorted() where name.lowercased().contains(low) {
                let url = dir.appendingPathComponent(name)
                if let img = Self.decodeImageFile(at: url) { return ArtworkResolution(image: img, source: "epic-heroic", path: url.path) }
            }
            return nil
        }
        let heroicIcon: () -> ArtworkResolution? = {
            guard !id.isEmpty else { return nil }
            return self.firstImage(in: heroic.appendingPathComponent("icons", isDirectory: true),
                                   names: ["\(id).png", "\(id).jpg", "\(id).jpeg", "\(id).webp", "\(id).ico"], source: "epic-heroic")
        }
        let root = StoreMetadataLocator.epicGameRoot(forExePath: entry.exePath)
        let stem = URL(fileURLWithPath: entry.exePath).deletingPathExtension().lastPathComponent
        let folderCover: () -> ArtworkResolution? = {
            guard let root else { return nil }
            return self.firstImage(in: root, names: ["cover.jpg", "cover.png", "keyart.jpg", "keyart.png", "folder.jpg", "folder.png",
                                                     "logo.png"], source: "epic-folder")
        }
        let folderIcon: () -> ArtworkResolution? = {
            guard let root else { return nil }
            return self.firstImage(in: root, names: ["icon.png", "icon.ico", "\(stem).ico", "\(stem).png"], source: "epic-folder")
        }
        switch style {
        case .banner: return heroicCache() ?? folderCover() ?? heroicIcon() ?? folderIcon()
        case .icon: return heroicIcon() ?? folderIcon() ?? heroicCache() ?? folderCover()
        }
    }

    /// Raster images via ImageIO; `.ico` files via the bundled ICO directory parser (largest, deepest entry).
    static func decodeImageFile(at url: URL) -> NSImage? {
        if url.pathExtension.lowercased() == "ico" {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 22, data.count < 32 << 20
            else { return nil }
            return PEIconExtractor.decodeICOFile(data)
        }
        return decodeImage(at: url)
    }

    private func steamArtwork(appID: String, exePath: String, style: ArtworkStyle) -> ArtworkResolution? {
        guard SteamLibraryLocator.isAppID(appID) else { return nil }
        let names: [String]
        switch style {
        case .banner:
            names = ["\(appID)_header.jpg", "\(appID)/header.jpg", "\(appID)_library_600x900.jpg",
                     "\(appID)/library_600x900.jpg", "\(appID)_library_hero.jpg", "\(appID)/library_hero.jpg"]
        case .icon:
            names = ["\(appID)_icon.jpg", "\(appID)/icon.jpg"]
        }
        let fm = FileManager.default
        for dir in SteamLibraryLocator.librarycacheDirectories(forExePath: exePath, prefixRoot: prefixRoot) {
            for name in names {
                let url = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: url.path), let img = Self.decodeImage(at: url) {
                    return ArtworkResolution(image: img, source: "steam", path: url.path)
                }
            }
            // Newer Steam clients nest art one level deeper: librarycache/<appid>/<hash>/header.jpg
            if style == .banner,
               let subs = try? fm.contentsOfDirectory(at: dir.appendingPathComponent(appID, isDirectory: true),
                                                      includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for sub in subs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    for name in ["header.jpg", "library_600x900.jpg"] {
                        let url = sub.appendingPathComponent(name)
                        if fm.fileExists(atPath: url.path), let img = Self.decodeImage(at: url) {
                            return ArtworkResolution(image: img, source: "steam", path: url.path)
                        }
                    }
                }
            }
        }
        return nil
    }

    static func decodeImage(at url: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 16, data.count < 32 << 20,
              let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 0, rep.pixelsHigh > 0,
              let cg = rep.cgImage
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
    }
}
