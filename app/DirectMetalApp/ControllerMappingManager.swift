import CoreGraphics
import Foundation
import GameController

// MARK: - Presets + profile model

enum ControllerPreset: String, Codable, CaseIterable, Identifiable {
    case xboxStandard
    case nintendoSwap
    case playstationDualSense
    case invertedLookY
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .xboxStandard: return "Xbox Standard"
        case .nintendoSwap: return "Nintendo Layout (A↔B, X↔Y)"
        case .playstationDualSense: return "PlayStation DualSense"
        case .invertedLookY: return "Inverted Look (Right Stick Y)"
        case .custom: return "Custom"
        }
    }

    var summary: String {
        switch self {
        case .xboxStandard: return "Positional XInput layout; what Windows games expect by default."
        case .nintendoSwap: return "Swaps A/B and X/Y so the on-controller labels match prompts on Switch Pro / Joy-Con."
        case .playstationDualSense: return "Cross/Circle/Square/Triangle on XInput A/B/X/Y with DualSense haptics enabled."
        case .invertedLookY: return "Standard layout with the right stick's vertical axis inverted (flight-style look)."
        case .custom: return "Your own button remapping."
        }
    }
}

/// Per-game (or global `default`) controller remapping, dead zones and haptics.
/// `buttonMap[physical] = logical`: pressing the physical button sends the logical SDL/XInput button.
struct ControllerMappingProfile: Codable, Equatable {
    /// Canonical SDL GameController button names (the 16 remappable inputs).
    static let canonicalButtons: [String] = [
        "a", "b", "x", "y", "leftshoulder", "rightshoulder", "lefttrigger", "righttrigger",
        "leftstick", "rightstick", "start", "back", "dpup", "dpdown", "dpleft", "dpright",
    ]
    static let deadzoneRange: ClosedRange<Double> = 0.0...0.35
    static let defaultDeadzone = 0.10

    var preset: ControllerPreset
    var buttonMap: [String: String]
    var leftDeadzone: Double
    var rightDeadzone: Double
    var invertRightY: Bool
    var enableHaptics: Bool

    static var identityMap: [String: String] {
        Dictionary(uniqueKeysWithValues: canonicalButtons.map { ($0, $0) })
    }

    init(preset: ControllerPreset = .xboxStandard, buttonMap: [String: String]? = nil,
         leftDeadzone: Double = ControllerMappingProfile.defaultDeadzone,
         rightDeadzone: Double = ControllerMappingProfile.defaultDeadzone,
         invertRightY: Bool = false, enableHaptics: Bool = true) {
        self.preset = preset
        self.buttonMap = buttonMap ?? ControllerMappingProfile.identityMap
        self.leftDeadzone = leftDeadzone
        self.rightDeadzone = rightDeadzone
        self.invertRightY = invertRightY
        self.enableHaptics = enableHaptics
        self = normalized()
    }

    /// Factory settings for a preset.
    static func forPreset(_ preset: ControllerPreset) -> ControllerMappingProfile {
        var map = identityMap
        var invert = false
        switch preset {
        case .nintendoSwap:
            map["a"] = "b"; map["b"] = "a"; map["x"] = "y"; map["y"] = "x"
        case .invertedLookY:
            invert = true
        case .xboxStandard, .playstationDualSense, .custom:
            break
        }
        return ControllerMappingProfile(preset: preset, buttonMap: map, invertRightY: invert, enableHaptics: true)
    }

    /// Stock DirectMetal behavior: no environment overrides at all.
    static let stock = ControllerMappingProfile.forPreset(.xboxStandard)

    var isStock: Bool { normalized() == ControllerMappingProfile.stock }

    /// Switches preset: applies its button layout + look inversion, keeps the user's dead zones and haptics.
    mutating func applyPreset(_ p: ControllerPreset) {
        let base = ControllerMappingProfile.forPreset(p)
        preset = p
        buttonMap = base.buttonMap
        invertRightY = base.invertRightY
        self = normalized()
    }

    static func clampDeadzone(_ v: Double) -> Double {
        guard v.isFinite else { return defaultDeadzone }
        let c = min(max(v, deadzoneRange.lowerBound), deadzoneRange.upperBound)
        return (c * 100).rounded() / 100
    }

    /// Clamped dead zones (1 % steps) and a complete, valid 16-button map.
    func normalized() -> ControllerMappingProfile {
        var p = self
        p.leftDeadzone = Self.clampDeadzone(leftDeadzone)
        p.rightDeadzone = Self.clampDeadzone(rightDeadzone)
        var map: [String: String] = [:]
        let valid = Set(Self.canonicalButtons)
        for b in Self.canonicalButtons {
            let v = buttonMap[b]?.lowercased() ?? b
            map[b] = valid.contains(v) ? v : b
        }
        p.buttonMap = map
        return p
    }

    var isIdentityMap: Bool { normalized().buttonMap == Self.identityMap }

    static func label(for button: String) -> String {
        switch button {
        case "a": return "A (Cross)"
        case "b": return "B (Circle)"
        case "x": return "X (Square)"
        case "y": return "Y (Triangle)"
        case "leftshoulder": return "LB / L1"
        case "rightshoulder": return "RB / R1"
        case "lefttrigger": return "LT / L2"
        case "righttrigger": return "RT / R2"
        case "leftstick": return "L3 (Left Stick)"
        case "rightstick": return "R3 (Right Stick)"
        case "start": return "Start / Menu"
        case "back": return "Back / View"
        case "dpup": return "D-pad Up"
        case "dpdown": return "D-pad Down"
        case "dpleft": return "D-pad Left"
        case "dpright": return "D-pad Right"
        default: return button
        }
    }

    static func shortLabel(for button: String) -> String {
        switch button {
        case "leftshoulder": return "LB"
        case "rightshoulder": return "RB"
        case "lefttrigger": return "LT"
        case "righttrigger": return "RT"
        case "leftstick": return "L3"
        case "rightstick": return "R3"
        case "start": return "Menu"
        case "back": return "View"
        case "dpup": return "↑"
        case "dpdown": return "↓"
        case "dpleft": return "←"
        case "dpright": return "→"
        default: return button.uppercased()
        }
    }

    enum CodingKeys: String, CodingKey {
        case preset, buttonMap, leftDeadzone, rightDeadzone, invertRightY, enableHaptics
    }

    /// Tolerant decoder: unknown presets fall back to `custom`, bad values to defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func opt<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? c.decodeIfPresent(type, forKey: key)) ?? nil
        }
        let rawPreset = opt(String.self, .preset)
        preset = rawPreset.map { ControllerPreset(rawValue: $0) ?? .custom } ?? .xboxStandard
        buttonMap = opt([String: String].self, .buttonMap) ?? ControllerMappingProfile.identityMap
        leftDeadzone = opt(Double.self, .leftDeadzone) ?? ControllerMappingProfile.defaultDeadzone
        rightDeadzone = opt(Double.self, .rightDeadzone) ?? ControllerMappingProfile.defaultDeadzone
        invertRightY = opt(Bool.self, .invertRightY) ?? false
        enableHaptics = opt(Bool.self, .enableHaptics) ?? true
        self = normalized()
    }
}

// MARK: - Persistence + launch environment

/// Persists controller profiles to `~/Library/Application Support/DirectMetal/controller_profiles.json`
/// (`DIRECTMETAL_CONTROLLER_PROFILES` overrides the file) and turns them into launch environment variables.
enum ControllerMappingManager {
    static let schemaID = "directmetal.controller_profiles.v1"
    static let defaultKey = "default"
    static let fileName = "controller_profiles.json"

    static var profilesURL: URL {
        if let env = ProcessInfo.processInfo.environment["DIRECTMETAL_CONTROLLER_PROFILES"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        return GameLibraryManager.defaultSupportRoot().appendingPathComponent(fileName)
    }

    private static let lock = NSLock()

    static func normalizedKey(_ key: String?) -> String {
        let k = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return k.isEmpty ? defaultKey : k
    }

    /// All stored profiles (invalid entries are skipped, never fatal).
    static func loadAll() -> [String: ControllerMappingProfile] {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }

    private static func loadUnlocked() -> [String: ControllerMappingProfile] {
        guard let data = try? Data(contentsOf: profilesURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["profiles"] as? [String: Any] else { return [:] }
        var out: [String: ControllerMappingProfile] = [:]
        for (key, value) in raw {
            guard JSONSerialization.isValidJSONObject(value),
                  let d = try? JSONSerialization.data(withJSONObject: value),
                  let p = try? JSONDecoder().decode(ControllerMappingProfile.self, from: d) else { continue }
            out[normalizedKey(key)] = p
        }
        return out
    }

    private static func saveUnlocked(_ profiles: [String: ControllerMappingProfile]) throws {
        let url = profilesURL
        let fm = FileManager.default
        if profiles.isEmpty {
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            return
        }
        struct Document: Encodable {
            let schema: String
            let profiles: [String: ControllerMappingProfile]
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(Document(schema: schemaID, profiles: profiles))
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func storedProfile(for key: String?) -> ControllerMappingProfile? {
        loadAll()[normalizedKey(key)]
    }

    /// Per-game profile, else the global `default` profile, else stock. `source` is `game`, `global` or `stock`.
    static func resolvedProfile(for gameID: String?) -> (key: String, profile: ControllerMappingProfile, source: String) {
        let all = loadAll()
        let key = normalizedKey(gameID)
        if key != defaultKey, let p = all[key] { return (key, p, "game") }
        if let p = all[defaultKey] { return (defaultKey, p, "global") }
        return (defaultKey, .stock, "stock")
    }

    /// Stores `profile` under `key`. A stock global profile is simply removed; a per-game stock profile is
    /// kept on purpose (it overrides a customized global profile for that game).
    static func setProfile(_ profile: ControllerMappingProfile, for key: String?) throws {
        let k = normalizedKey(key)
        lock.lock()
        defer { lock.unlock() }
        var all = loadUnlocked()
        let p = profile.normalized()
        if k == defaultKey && p.isStock {
            all.removeValue(forKey: k)
        } else {
            all[k] = p
        }
        try saveUnlocked(all)
    }

    /// Removes the profile stored under `key`; returns whether one existed.
    @discardableResult
    static func resetProfile(for key: String?) throws -> Bool {
        let k = normalizedKey(key)
        lock.lock()
        defer { lock.unlock() }
        var all = loadUnlocked()
        guard all.removeValue(forKey: k) != nil else { return false }
        try saveUnlocked(all)
        return true
    }

    static func resetAll() throws {
        lock.lock()
        defer { lock.unlock() }
        try saveUnlocked([:])
    }

    /// Launch environment for `gameID` (per-game -> global -> stock). A stock profile yields `[:]`.
    static func environmentOverrides(for gameID: String?) -> [String: String] {
        let r = resolvedProfile(for: gameID)
        return environmentOverrides(profile: r.profile, key: r.key)
    }

    static func environmentOverrides(profile raw: ControllerMappingProfile, key: String) -> [String: String] {
        let profile = raw.normalized()
        guard !profile.isStock else { return [:] }
        var env: [String: String] = [
            "SDL_GAMECONTROLLERCONFIG": sdlMappingConfig(for: profile),
            "DIRECTMETAL_CONTROLLER_PROFILE": key,
            "DIRECTMETAL_CONTROLLER_PRESET": profile.preset.rawValue,
            "DIRECTMETAL_CONTROLLER_DEADZONE_L": String(format: "%.2f", profile.leftDeadzone),
            "DIRECTMETAL_CONTROLLER_DEADZONE_R": String(format: "%.2f", profile.rightDeadzone),
            "DIRECTMETAL_CONTROLLER_HAPTICS": profile.enableHaptics ? "1" : "0",
            "DIRECTMETAL_CONTROLLER_INVERT_RIGHT_Y": profile.invertRightY ? "1" : "0",
        ]
        if profile.preset == .nintendoSwap {
            // The swap is explicit in the mapping; stop SDL from re-swapping Nintendo face buttons by label.
            env["SDL_GAMECONTROLLER_USE_BUTTON_LABELS"] = "0"
        }
        return env
    }

    // MARK: SDL mapping generation

    /// Controllers commonly paired with Apple Silicon Macs (USB vendor/product IDs).
    static let knownControllers: [(name: String, vendor: UInt16, product: UInt16)] = [
        ("Xbox 360 Controller", 0x045e, 0x028e),
        ("Xbox One Controller", 0x045e, 0x02ea),
        ("Xbox One S Controller", 0x045e, 0x02fd),
        ("Xbox Series X|S Controller", 0x045e, 0x0b12),
        ("Xbox Series X|S Controller BT", 0x045e, 0x0b13),
        ("DualShock 4", 0x054c, 0x05c4),
        ("DualShock 4 v2", 0x054c, 0x09cc),
        ("DualSense Wireless Controller", 0x054c, 0x0ce6),
        ("DualSense Edge", 0x054c, 0x0df2),
        ("Nintendo Switch Pro Controller", 0x057e, 0x2009),
    ]

    /// Raw inputs in SDL's standard HIDAPI / virtual-gamepad order (identical for Xbox, PlayStation and Switch).
    static let rawInput: [String: String] = [
        "a": "b0", "b": "b1", "x": "b2", "y": "b3", "back": "b4", "guide": "b5", "start": "b6",
        "leftstick": "b7", "rightstick": "b8", "leftshoulder": "b9", "rightshoulder": "b10",
        "dpup": "b11", "dpdown": "b12", "dpleft": "b13", "dpright": "b14",
        "lefttrigger": "a4", "righttrigger": "a5",
    ]

    /// SDL2 joystick GUID (CRC and version zeroed; SDL matches mappings CRC/version-insensitively).
    static func sdlGUID(bus: UInt16, vendor: UInt16, product: UInt16) -> String {
        func le(_ v: UInt16) -> String { String(format: "%02x%02x", v & 0xff, v >> 8) }
        return le(bus) + "0000" + le(vendor) + "0000" + le(product) + "0000" + "0000" + "0000"
    }

    /// The SDL mapping body (`a:b1,b:b0,…`) for one profile.
    static func sdlMappingBody(for raw: ControllerMappingProfile) -> String {
        let profile = raw.normalized()
        let order = Dictionary(uniqueKeysWithValues: ControllerMappingProfile.canonicalButtons.enumerated().map { ($1, $0) })
        var pairs: [(logical: String, physical: String)] = []
        for physical in ControllerMappingProfile.canonicalButtons {
            pairs.append((profile.buttonMap[physical] ?? physical, physical))
        }
        pairs.sort { (order[$0.logical] ?? 99, order[$0.physical] ?? 99) < (order[$1.logical] ?? 99, order[$1.physical] ?? 99) }
        var parts = pairs.compactMap { p in rawInput[p.physical].map { "\(p.logical):\($0)" } }
        parts.append("guide:b5")
        parts.append(contentsOf: ["leftx:a0", "lefty:a1", "rightx:a2", profile.invertRightY ? "righty:a3~" : "righty:a3"])
        return parts.joined(separator: ",")
    }

    /// Newline-separated `SDL_GAMECONTROLLERCONFIG` value covering USB + Bluetooth GUIDs of `knownControllers`.
    static func sdlMappingConfig(for profile: ControllerMappingProfile) -> String {
        let body = sdlMappingBody(for: profile)
        var lines: [String] = []
        for c in knownControllers {
            for (bus, suffix) in [(UInt16(0x0003), ""), (UInt16(0x0005), " (Bluetooth)")] {
                let name = (c.name + suffix + " DirectMetal").replacingOccurrences(of: ",", with: " ")
                lines.append("\(sdlGUID(bus: bus, vendor: c.vendor, product: c.product)),\(name),\(body),")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Live input tester

/// Polls the first extended gamepad at 60 Hz for the GUI's live input tester.
@MainActor
final class ControllerLiveTester: ObservableObject {
    @Published private(set) var pressedButtons: Set<String> = []
    @Published private(set) var leftStick: CGPoint = .zero
    @Published private(set) var rightStick: CGPoint = .zero
    @Published private(set) var leftTrigger: Float = 0
    @Published private(set) var rightTrigger: Float = 0
    @Published private(set) var activeControllerName: String?

    private var timer: Timer?

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        poll()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                if let self { self.poll() } else { t.invalidate() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func poll() {
        guard let controller = GCController.controllers().first(where: { $0.extendedGamepad != nil }),
              let pad = controller.extendedGamepad else {
            if activeControllerName != nil || !pressedButtons.isEmpty || leftStick != .zero || rightStick != .zero
                || leftTrigger != 0 || rightTrigger != 0 {
                activeControllerName = nil
                pressedButtons = []
                leftStick = .zero
                rightStick = .zero
                leftTrigger = 0
                rightTrigger = 0
            }
            return
        }
        let name = controller.vendorName ?? controller.productCategory
        if name != activeControllerName { activeControllerName = name }

        var pressed = Set<String>()
        let buttons: [(String, GCControllerButtonInput?)] = [
            ("a", pad.buttonA), ("b", pad.buttonB), ("x", pad.buttonX), ("y", pad.buttonY),
            ("leftshoulder", pad.leftShoulder), ("rightshoulder", pad.rightShoulder),
            ("lefttrigger", pad.leftTrigger), ("righttrigger", pad.rightTrigger),
            ("leftstick", pad.leftThumbstickButton), ("rightstick", pad.rightThumbstickButton),
            ("start", pad.buttonMenu), ("back", pad.buttonOptions),
            ("dpup", pad.dpad.up), ("dpdown", pad.dpad.down), ("dpleft", pad.dpad.left), ("dpright", pad.dpad.right),
        ]
        for (key, input) in buttons where input?.isPressed == true { pressed.insert(key) }
        if pressed != pressedButtons { pressedButtons = pressed }

        let l = CGPoint(x: CGFloat(pad.leftThumbstick.xAxis.value), y: CGFloat(pad.leftThumbstick.yAxis.value))
        let r = CGPoint(x: CGFloat(pad.rightThumbstick.xAxis.value), y: CGFloat(pad.rightThumbstick.yAxis.value))
        if l != leftStick { leftStick = l }
        if r != rightStick { rightStick = r }
        if pad.leftTrigger.value != leftTrigger { leftTrigger = pad.leftTrigger.value }
        if pad.rightTrigger.value != rightTrigger { rightTrigger = pad.rightTrigger.value }
    }
}
