import Foundation

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
