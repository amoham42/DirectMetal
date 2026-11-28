import AppKit
import CoreGraphics
import Foundation

// MARK: - Steam library discovery

/// Locates Steam libraries, app IDs and the local `appcache/librarycache` artwork folders for a game executable.
/// Pure filesystem lookups (no network, no Steam client required).
enum SteamLibraryLocator {
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
    static func manifestIndex(steamapps: URL) -> [String: String] {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: steamapps.path) else { return [:] }
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
        "\(style.rawValue)|\(entry.steamAppID ?? "")|\(entry.exePath)"
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
        let appID = entry.steamAppID ?? SteamLibraryLocator.steamAppID(forExePath: entry.exePath)
        let steam: (ArtworkStyle) -> NSImage? = { s in
            guard let appID else { return nil }
            return self.steamArtwork(appID: appID, exePath: entry.exePath, style: s)
        }
        switch style {
        case .banner:
            return steam(.banner) ?? PEIconExtractor.extractIcon(exePath: entry.exePath)
        case .icon:
            return steam(.icon) ?? PEIconExtractor.extractIcon(exePath: entry.exePath) ?? steam(.banner)
        }
    }

    private func steamArtwork(appID: String, exePath: String, style: ArtworkStyle) -> NSImage? {
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
                if fm.fileExists(atPath: url.path), let img = Self.decodeImage(at: url) { return img }
            }
            // Newer Steam clients nest art one level deeper: librarycache/<appid>/<hash>/header.jpg
            if style == .banner,
               let subs = try? fm.contentsOfDirectory(at: dir.appendingPathComponent(appID, isDirectory: true),
                                                      includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for sub in subs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    for name in ["header.jpg", "library_600x900.jpg"] {
                        let url = sub.appendingPathComponent(name)
                        if fm.fileExists(atPath: url.path), let img = Self.decodeImage(at: url) { return img }
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

// MARK: - Windows PE embedded icon extractor

/// Pure-Swift extractor for the application icon embedded in a Windows PE32/PE32+ `.rsrc` section.
/// Walks `RT_GROUP_ICON` (14) -> `RT_ICON` (3), picks the largest / deepest entry and decodes both
/// PNG (Vista+) and classic DIB (32-bit BGRA, 24-bit BGR, 8/4/1-bit palette + AND mask) icons.
/// Every offset and length is bounds-checked: malformed, truncated or packed files return `nil`.
enum PEIconExtractor {
    private static let rtIcon: UInt32 = 3
    private static let rtGroupIcon: UInt32 = 14
    private static let maxEntriesPerDirectory = 4096
    private static let maxFileBytes = 4 << 30

    struct IconCandidate {
        let width: Int
        let height: Int
        let bitCount: Int
        let data: Data
    }

    static func extractIcon(exePath: String) -> NSImage? {
        guard !exePath.isEmpty,
              let attrs = try? FileManager.default.attributesOfItem(atPath: exePath),
              (attrs[.type] as? FileAttributeType) == .typeRegular,
              let size = (attrs[.size] as? NSNumber)?.intValue, size >= 64, size < maxFileBytes,
              let data = try? Data(contentsOf: URL(fileURLWithPath: exePath), options: .alwaysMapped)
        else { return nil }
        return extractIcon(peData: data)
    }

    static func extractIcon(peData: Data) -> NSImage? {
        let candidates = iconCandidates(peData: peData)
        // Best first: largest area, then deepest color; decode the next one if the best is corrupt.
        let ordered = candidates.sorted {
            let a0 = $0.width * $0.height, a1 = $1.width * $1.height
            return a0 != a1 ? a0 > a1 : $0.bitCount > $1.bitCount
        }
        for cand in ordered.prefix(6) {
            if let img = decodeIconImage(cand.data) { return img }
        }
        return nil
    }

    /// Icon images of the first `RT_GROUP_ICON` (or every `RT_ICON` when no group exists).
    static func iconCandidates(peData: Data) -> [IconCandidate] {
        peData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [IconCandidate] in
            let r = ByteReader(buf: raw)
            guard let rsrc = locateResourceSection(r) else { return [] }
            let icons = resourceLeaves(r, rsrc: rsrc, type: rtIcon)
            guard !icons.isEmpty else { return [] }
            var iconByID: [UInt32: Data] = [:]
            for leaf in icons where iconByID[leaf.id] == nil { iconByID[leaf.id] = leaf.data }

            if let group = resourceLeaves(r, rsrc: rsrc, type: rtGroupIcon).first {
                let out = parseGroup(group.data, iconByID: iconByID)
                if !out.isEmpty { return out }
            }
            // No (usable) group directory: probe each RT_ICON header for its dimensions.
            return icons.prefix(64).compactMap { leaf in
                guard let dims = probeDimensions(leaf.data) else { return nil }
                return IconCandidate(width: dims.w, height: dims.h, bitCount: dims.bpp, data: leaf.data)
            }
        }
    }

    // MARK: PE structure

    private struct ResourceSection {
        let fileOffset: Int
        let rva: UInt32
        let size: Int
        let sections: [(va: UInt32, vsize: UInt32, rawPtr: UInt32, rawSize: UInt32)]
    }

    private static func locateResourceSection(_ r: ByteReader) -> ResourceSection? {
        guard r.u16(0) == 0x5A4D, let lfanew = r.u32(0x3C).map(Int.init), lfanew > 0, lfanew < r.count - 24,
              r.u32(lfanew) == 0x0000_4550 else { return nil }
        let coff = lfanew + 4
        guard let nsec = r.u16(coff + 2).map(Int.init), nsec > 0, nsec <= 96,
              let optSize = r.u16(coff + 16).map(Int.init) else { return nil }
        let opt = coff + 20
        guard let magic = r.u16(opt) else { return nil }
        let numDirsOff: Int, dirsOff: Int
        switch magic {
        case 0x10B: numDirsOff = opt + 92; dirsOff = opt + 96   // PE32
        case 0x20B: numDirsOff = opt + 108; dirsOff = opt + 112 // PE32+
        default: return nil
        }
        guard let numDirs = r.u32(numDirsOff), numDirs > 2,
              dirsOff + 3 * 8 <= opt + optSize,
              let rsrcRVA = r.u32(dirsOff + 2 * 8), let rsrcSize = r.u32(dirsOff + 2 * 8 + 4),
              rsrcRVA != 0, rsrcSize >= 16 else { return nil }

        var sections: [(va: UInt32, vsize: UInt32, rawPtr: UInt32, rawSize: UInt32)] = []
        let secTable = opt + optSize
        for i in 0..<nsec {
            let s = secTable + i * 40
            guard let vsize = r.u32(s + 8), let va = r.u32(s + 12),
                  let rawSize = r.u32(s + 16), let rawPtr = r.u32(s + 20) else { return nil }
            sections.append((va, vsize, rawPtr, rawSize))
        }
        let sec = ResourceSection(fileOffset: 0, rva: rsrcRVA, size: Int(rsrcSize), sections: sections)
        guard let off = rvaToOffset(rsrcRVA, sec, r) else { return nil }
        return ResourceSection(fileOffset: off, rva: rsrcRVA, size: min(Int(rsrcSize), r.count - off), sections: sections)
    }

    private static func rvaToOffset(_ rva: UInt32, _ sec: ResourceSection, _ r: ByteReader) -> Int? {
        for s in sec.sections {
            let span = UInt64(max(s.vsize, s.rawSize))
            guard UInt64(rva) >= UInt64(s.va), UInt64(rva) < UInt64(s.va) + span else { continue }
            let delta = UInt64(rva) - UInt64(s.va)
            guard delta < UInt64(s.rawSize) else { return nil } // lives in zero-fill (uninitialized) space
            let off = UInt64(s.rawPtr) + delta
            return off < UInt64(r.count) ? Int(off) : nil
        }
        return nil
    }

    private struct Leaf {
        let id: UInt32
        let data: Data
    }

    /// All `type/<name>/<lang>` leaves of one resource type (first language per name), in directory order.
    private static func resourceLeaves(_ r: ByteReader, rsrc: ResourceSection, type: UInt32) -> [Leaf] {
        guard let typeDir = directoryEntries(r, rsrc: rsrc, dirOffset: 0)
            .first(where: { !$0.isNamed && $0.id == type && $0.isDirectory }) else { return [] }
        var out: [Leaf] = []
        for nameEntry in directoryEntries(r, rsrc: rsrc, dirOffset: typeDir.target) where nameEntry.isDirectory {
            guard let lang = directoryEntries(r, rsrc: rsrc, dirOffset: nameEntry.target).first(where: { !$0.isDirectory }),
                  let data = dataEntry(r, rsrc: rsrc, entryOffset: lang.target) else { continue }
            out.append(Leaf(id: nameEntry.isNamed ? UInt32.max : nameEntry.id, data: data))
            if out.count >= 1024 { break }
        }
        return out
    }

    private struct DirEntry {
        let isNamed: Bool
        let id: UInt32
        let isDirectory: Bool
        let target: Int // offset relative to the resource section start
    }

    private static func directoryEntries(_ r: ByteReader, rsrc: ResourceSection, dirOffset: Int) -> [DirEntry] {
        guard dirOffset >= 0, dirOffset + 16 <= rsrc.size else { return [] }
        let base = rsrc.fileOffset + dirOffset
        guard let named = r.u16(base + 12), let ids = r.u16(base + 14) else { return [] }
        let total = min(Int(named) + Int(ids), maxEntriesPerDirectory)
        var out: [DirEntry] = []
        out.reserveCapacity(total)
        for i in 0..<total {
            let e = base + 16 + i * 8
            guard dirOffset + 16 + i * 8 + 8 <= rsrc.size, let name = r.u32(e), let off = r.u32(e + 4) else { break }
            let target = Int(off & 0x7FFF_FFFF)
            // A subdirectory must point forward-ish inside the section (prevents self-referencing loops).
            if off & 0x8000_0000 != 0 && (target == dirOffset || target + 16 > rsrc.size) { continue }
            out.append(DirEntry(isNamed: name & 0x8000_0000 != 0, id: name & 0x7FFF_FFFF,
                                isDirectory: off & 0x8000_0000 != 0, target: target))
        }
        return out
    }

    private static func dataEntry(_ r: ByteReader, rsrc: ResourceSection, entryOffset: Int) -> Data? {
        guard entryOffset >= 0, entryOffset + 16 <= rsrc.size else { return nil }
        let e = rsrc.fileOffset + entryOffset
        guard let dataRVA = r.u32(e), let size = r.u32(e + 4), size > 0, size <= 16 << 20,
              let off = rvaToOffset(dataRVA, rsrc, r) else { return nil }
        return r.slice(off, Int(size))
    }

    // MARK: Icon group / image parsing

    private static func parseGroup(_ group: Data, iconByID: [UInt32: Data]) -> [IconCandidate] {
        group.withUnsafeBytes { raw -> [IconCandidate] in
            let g = ByteReader(buf: raw)
            guard g.u16(0) == 0, g.u16(2) == 1, let count = g.u16(4).map(Int.init), count > 0 else { return [] }
            var out: [IconCandidate] = []
            for i in 0..<min(count, 256) {
                let e = 6 + i * 14
                guard let w = g.u8(e), let h = g.u8(e + 1), let bpp = g.u16(e + 6), let id = g.u16(e + 12) else { break }
                guard let data = iconByID[UInt32(id)] else { continue }
                // Directory sizes can lie (0 == 256); trust the image header when it is readable.
                let dims = probeDimensions(data)
                out.append(IconCandidate(width: dims?.w ?? (w == 0 ? 256 : Int(w)),
                                         height: dims?.h ?? (h == 0 ? 256 : Int(h)),
                                         bitCount: dims?.bpp ?? Int(bpp), data: data))
            }
            return out
        }
    }

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    private static func isPNG(_ d: Data) -> Bool {
        d.count >= 8 && d.prefix(8).elementsEqual(pngSignature)
    }

    /// (width, height, bpp) from a PNG IHDR or a BITMAPINFOHEADER.
    private static func probeDimensions(_ d: Data) -> (w: Int, h: Int, bpp: Int)? {
        d.withUnsafeBytes { raw -> (w: Int, h: Int, bpp: Int)? in
            let r = ByteReader(buf: raw)
            if isPNG(d) {
                guard let w = r.u32be(16), let h = r.u32be(20), let depth = r.u8(24), let colorType = r.u8(25),
                      w > 0, h > 0, w <= 4096, h <= 4096 else { return nil }
                let channels: Int = [0: 1, 2: 3, 3: 1, 4: 2, 6: 4][Int(colorType)] ?? 4
                return (Int(w), Int(h), Int(depth) * channels)
            }
            guard let hdr = r.u32(0), hdr >= 40, hdr <= 1024,
                  let w = r.i32(4), let h2 = r.i32(8), let bpp = r.u16(14),
                  w > 0, w <= 1024, h2 != 0, abs(Int(h2)) / 2 <= 1024 else { return nil }
            return (Int(w), max(1, abs(Int(h2)) / 2), Int(bpp))
        }
    }

    /// Decodes one `RT_ICON` image (PNG or DIB+mask) into an `NSImage`.
    static func decodeIconImage(_ d: Data) -> NSImage? {
        if isPNG(d) {
            guard let rep = NSBitmapImageRep(data: d), rep.pixelsWide > 0, rep.pixelsHigh > 0, let cg = rep.cgImage
            else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        }
        guard let cg = decodeDIB(d) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func decodeDIB(_ d: Data) -> CGImage? {
        d.withUnsafeBytes { raw -> CGImage? in
            let r = ByteReader(buf: raw)
            guard let hdrSize = r.u32(0).map(Int.init), hdrSize >= 40, hdrSize <= 1024,
                  let wRaw = r.i32(4), let hRaw = r.i32(8), let bppRaw = r.u16(14), let compression = r.u32(16)
            else { return nil }
            let width = Int(wRaw)
            let bpp = Int(bppRaw)
            // Icon DIB heights cover XOR + AND masks; negative (top-down) heights are not used by icons.
            guard width > 0, width <= 1024, hRaw > 0 else { return nil }
            let height = Int(hRaw) / 2
            guard height > 0, height <= 1024, [1, 4, 8, 24, 32].contains(bpp),
                  compression == 0 || (compression == 3 && bpp == 32) else { return nil }

            var palette: [(UInt8, UInt8, UInt8)] = []
            var cursor = hdrSize
            if compression == 3 && hdrSize == 40 { cursor += 12 } // BI_BITFIELDS masks follow a v1 header
            if bpp <= 8 {
                let used = r.u32(32).map(Int.init) ?? 0
                let colors = (used > 0 && used <= 1 << bpp) ? used : 1 << bpp
                for i in 0..<colors {
                    guard let b = r.u8(cursor + i * 4), let g = r.u8(cursor + i * 4 + 1), let rr = r.u8(cursor + i * 4 + 2)
                    else { return nil }
                    palette.append((rr, g, b))
                }
                cursor += colors * 4
            }

            let xorStride = ((width * bpp + 31) / 32) * 4
            let andStride = ((width + 31) / 32) * 4
            let xorStart = cursor
            let andStart = xorStart + xorStride * height
            guard andStart <= r.count else { return nil }
            let hasMask = andStart + andStride * height <= r.count

            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            var anyAlpha = false
            for y in 0..<height {
                let srcRow = xorStart + (height - 1 - y) * xorStride // bottom-up
                for x in 0..<width {
                    var red: UInt8 = 0, green: UInt8 = 0, blue: UInt8 = 0, alpha: UInt8 = 255
                    switch bpp {
                    case 32:
                        guard let b = r.u8(srcRow + x * 4), let g = r.u8(srcRow + x * 4 + 1),
                              let rr = r.u8(srcRow + x * 4 + 2), let a = r.u8(srcRow + x * 4 + 3) else { return nil }
                        (red, green, blue, alpha) = (rr, g, b, a)
                        if a != 0 { anyAlpha = true }
                    case 24:
                        guard let b = r.u8(srcRow + x * 3), let g = r.u8(srcRow + x * 3 + 1),
                              let rr = r.u8(srcRow + x * 3 + 2) else { return nil }
                        (red, green, blue) = (rr, g, b)
                    default:
                        let bitIndex = x * bpp
                        guard let byte = r.u8(srcRow + bitIndex / 8) else { return nil }
                        let shift = 8 - bpp - (bitIndex % 8)
                        let idx = Int((byte >> UInt8(shift)) & UInt8((1 << bpp) - 1))
                        guard idx < palette.count else { return nil }
                        (red, green, blue) = palette[idx]
                    }
                    let o = (y * width + x) * 4
                    rgba[o] = red; rgba[o + 1] = green; rgba[o + 2] = blue; rgba[o + 3] = alpha
                }
            }

            // Transparency: 32-bit icons carry alpha; otherwise (or when alpha is all zero) apply the AND mask.
            let useMask = !(bpp == 32 && anyAlpha)
            for y in 0..<height {
                let maskRow = andStart + (height - 1 - y) * andStride
                for x in 0..<width {
                    let o = (y * width + x) * 4
                    if useMask {
                        if hasMask, let byte = r.u8(maskRow + x / 8) {
                            rgba[o + 3] = (byte >> UInt8(7 - x % 8)) & 1 == 1 ? 0 : 255
                        } else {
                            rgba[o + 3] = 255
                        }
                    }
                    // Premultiply for CoreGraphics.
                    let a = UInt16(rgba[o + 3])
                    if a < 255 {
                        rgba[o] = UInt8(UInt16(rgba[o]) * a / 255)
                        rgba[o + 1] = UInt8(UInt16(rgba[o + 1]) * a / 255)
                        rgba[o + 2] = UInt8(UInt16(rgba[o + 2]) * a / 255)
                    }
                }
            }

            guard let provider = CGDataProvider(data: Data(rgba) as CFData),
                  let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            return CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
            )
        }
    }
}

/// Bounds-checked little-endian reader over raw bytes; every accessor returns `nil` when out of range.
private struct ByteReader {
    let buf: UnsafeRawBufferPointer
    var count: Int { buf.count }

    @inline(__always) private func ok(_ off: Int, _ len: Int) -> Bool {
        off >= 0 && len >= 0 && off <= buf.count - len
    }

    func u8(_ off: Int) -> UInt8? {
        ok(off, 1) ? buf[off] : nil
    }

    func u16(_ off: Int) -> UInt16? {
        guard ok(off, 2) else { return nil }
        return UInt16(buf[off]) | UInt16(buf[off + 1]) << 8
    }

    func u32(_ off: Int) -> UInt32? {
        guard ok(off, 4) else { return nil }
        return UInt32(buf[off]) | UInt32(buf[off + 1]) << 8 | UInt32(buf[off + 2]) << 16 | UInt32(buf[off + 3]) << 24
    }

    func i32(_ off: Int) -> Int32? {
        u32(off).map { Int32(bitPattern: $0) }
    }

    func u32be(_ off: Int) -> UInt32? {
        guard ok(off, 4) else { return nil }
        return UInt32(buf[off]) << 24 | UInt32(buf[off + 1]) << 16 | UInt32(buf[off + 2]) << 8 | UInt32(buf[off + 3])
    }

    func slice(_ off: Int, _ len: Int) -> Data? {
        guard ok(off, len), len > 0, let base = buf.baseAddress else { return nil }
        return Data(bytes: base + off, count: len)
    }
}
