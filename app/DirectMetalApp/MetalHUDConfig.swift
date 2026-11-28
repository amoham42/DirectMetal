import Foundation

// MARK: - HUD Presets & Corner Alignment

/// Preset telemetry layouts for Apple's Metal Performance HUD (`MTL_HUD_ELEMENTS`)
/// and the equivalent DXVK Vulkan overlay (`DXVK_HUD`) on DirectX 9 games.
enum MetalHUDPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case minimal
    case standard
    case frameGraph
    case detailed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .minimal: return "Minimal"
        case .standard: return "Standard"
        case .frameGraph: return "Frame Graph"
        case .detailed: return "Detailed"
        }
    }

    var summary: String {
        switch self {
        case .minimal:
            return "FPS and frame time only for an unobtrusive counter."
        case .standard:
            return "FPS, frame time, GPU time, memory, and Metal resolution."
        case .frameGraph:
            return "Standard telemetry plus a live frame-time graph and 1%-low metrics."
        case .detailed:
            return "Full Apple Silicon telemetry: FPS, GPU/CPU times, UMA memory, shaders, present mode, thermal state, and MetalFX scale."
        }
    }

    /// Apple `MTL_HUD_ELEMENTS` token list emitted when the Metal Performance HUD is enabled.
    var mtlElements: [String] {
        switch self {
        case .minimal:
            return ["fps", "frametime"]
        case .standard:
            return ["device", "layersize", "memory", "fps", "frametime", "gputime"]
        case .frameGraph:
            return ["device", "layersize", "memory", "fps", "frametime", "gputime", "frameintervalgraph", "fpsgraph"]
        case .detailed:
            return [
                "device",
                "layersize",
                "layerscale",
                "memory",
                "fps",
                "frametime",
                "gputime",
                "presentdelay",
                "frameintervalgraph",
                "frameintervalhistogram",
                "shaders",
                "thermal",
            ]
        }
    }

    /// Equivalent `DXVK_HUD` comma-separated element list for DirectX 9 games on DXVK.
    var dxvkHudElements: String {
        switch self {
        case .minimal:
            return "fps,frametimes"
        case .standard:
            return "fps,frametimes,devinfo,api,memory"
        case .frameGraph:
            return "fps,frametimes,devinfo,api,memory,gpuload"
        case .detailed:
            return "fps,frametimes,devinfo,api,memory,gpuload,compiler,pipelines,drawcalls"
        }
    }

    var symbolName: String {
        switch self {
        case .minimal: return "speedometer"
        case .standard: return "gauge.with.dots.needle.67percent"
        case .frameGraph: return "waveform.path.ecg"
        case .detailed: return "cpu.fill"
        }
    }

    var metricHighlights: [String] {
        switch self {
        case .minimal:
            return ["FPS", "Frame ms"]
        case .standard:
            return ["FPS", "GPU ms", "Memory", "Resolution"]
        case .frameGraph:
            return ["Standard", "Graph", "1% Low"]
        case .detailed:
            return ["CPU/GPU", "UMA", "Shaders", "Thermal", "MetalFX"]
        }
    }

    /// Parses canonical raw values and common CLI shorthand aliases.
    static func parse(_ raw: String) -> MetalHUDPreset? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = allCases.first(where: { $0.rawValue.lowercased() == key }) {
            return exact
        }
        switch key {
        case "min", "compact", "fps": return .minimal
        case "default", "std", "normal": return .standard
        case "graph", "frame-graph", "frame_graph", "frametime": return .frameGraph
        case "full", "all", "verbose", "telemetry": return .detailed
        default: return nil
        }
    }
}

/// Screen corner where the Metal Performance HUD is anchored (`MTL_HUD_ALIGNMENT`).
enum MetalHUDAlignment: String, Codable, CaseIterable, Identifiable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }

    /// Exact value accepted by Apple's `MTL_HUD_ALIGNMENT` environment variable.
    var mtlAlignmentValue: String {
        switch self {
        case .topLeft: return "topleft"
        case .topRight: return "topright"
        case .bottomLeft: return "bottomleft"
        case .bottomRight: return "bottomright"
        }
    }

    var symbolName: String {
        switch self {
        case .topLeft: return "arrow.up.left.square"
        case .topRight: return "arrow.up.right.square"
        case .bottomLeft: return "arrow.down.left.square"
        case .bottomRight: return "arrow.down.right.square"
        }
    }

    /// Parses canonical raw values, `MTL_HUD_ALIGNMENT` values, and common CLI aliases.
    static func parse(_ raw: String) -> MetalHUDAlignment? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = allCases.first(where: {
            $0.rawValue.lowercased() == key || $0.mtlAlignmentValue == key
        }) {
            return exact
        }
        switch key {
        case "top-left", "top_left", "tl": return .topLeft
        case "top-right", "top_right", "tr": return .topRight
        case "bottom-left", "bottom_left", "bl": return .bottomLeft
        case "bottom-right", "bottom_right", "br": return .bottomRight
        default: return nil
        }
    }
}

// MARK: - HUD Configuration Model

/// Persistent user configuration for the Metal Performance HUD and DX9 DXVK overlay.
struct MetalHUDConfiguration: Codable, Equatable, Sendable {
    static let scaleRange: ClosedRange<Double> = 0.5...2.0
    static let opacityRange: ClosedRange<Double> = 0.25...1.0
    static let defaultScale: Double = 1.0
    static let defaultOpacity: Double = 0.85

    static let defaultConfig = MetalHUDConfiguration()

    var preset: MetalHUDPreset
    var alignment: MetalHUDAlignment
    var scale: Double
    var opacity: Double
    var showDXVKHudOnDX9: Bool

    init(
        preset: MetalHUDPreset = .standard,
        alignment: MetalHUDAlignment = .topRight,
        scale: Double = MetalHUDConfiguration.defaultScale,
        opacity: Double = MetalHUDConfiguration.defaultOpacity,
        showDXVKHudOnDX9: Bool = true
    ) {
        self.preset = preset
        self.alignment = alignment
        self.scale = scale
        self.opacity = opacity
        self.showDXVKHudOnDX9 = showDXVKHudOnDX9
        self = normalized()
    }

    enum CodingKeys: String, CodingKey {
        case preset
        case alignment
        case scale
        case opacity
        case showDXVKHudOnDX9
    }

    /// Tolerant decoder: falls back to safe defaults for missing, unknown, or non-finite fields.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func decodeOptional<T: Decodable>(_ type: T.Type, forKey key: CodingKeys) -> T? {
            (try? container.decodeIfPresent(type, forKey: key)) ?? nil
        }

        if let rawPreset = decodeOptional(String.self, forKey: .preset) {
            preset = MetalHUDPreset.parse(rawPreset) ?? .standard
        } else {
            preset = .standard
        }

        if let rawAlignment = decodeOptional(String.self, forKey: .alignment) {
            alignment = MetalHUDAlignment.parse(rawAlignment) ?? .topRight
        } else {
            alignment = .topRight
        }

        scale = decodeOptional(Double.self, forKey: .scale) ?? Self.defaultScale
        opacity = decodeOptional(Double.self, forKey: .opacity) ?? Self.defaultOpacity
        showDXVKHudOnDX9 = decodeOptional(Bool.self, forKey: .showDXVKHudOnDX9) ?? true
        self = normalized()
    }

    static func clampScale(_ value: Double) -> Double {
        guard value.isFinite else { return defaultScale }
        let clamped = min(max(value, scaleRange.lowerBound), scaleRange.upperBound)
        return (clamped * 100.0).rounded() / 100.0
    }

    static func clampOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return defaultOpacity }
        let clamped = min(max(value, opacityRange.lowerBound), opacityRange.upperBound)
        return (clamped * 100.0).rounded() / 100.0
    }

    /// Returns a copy with `scale` (`0.5...2.0`) and `opacity` (`0.25...1.0`) clamped and NaN/Inf guarded.
    func normalized() -> MetalHUDConfiguration {
        var copy = self
        copy.scale = Self.clampScale(scale)
        copy.opacity = Self.clampOpacity(opacity)
        return copy
    }

    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    private static func formatDecimal(_ value: Double) -> String {
        String(format: "%.2f", locale: posixLocale, value)
    }

    /// Builds the `MTL_HUD_*` (and optional `DXVK_HUD`) environment variables for game launch.
    func environmentVariables(hudEnabled: Bool) -> [String: String] {
        guard hudEnabled else {
            return ["MTL_HUD_ENABLED": "0"]
        }
        let cfg = normalized()
        var env: [String: String] = [
            "MTL_HUD_ENABLED": "1",
            "MTL_HUD_ALIGNMENT": cfg.alignment.mtlAlignmentValue,
            "MTL_HUD_SCALE": Self.formatDecimal(cfg.scale),
            "MTL_HUD_OPACITY": Self.formatDecimal(cfg.opacity),
            "MTL_HUD_ELEMENTS": cfg.preset.mtlElements.joined(separator: ","),
        ]
        if cfg.showDXVKHudOnDX9 {
            env["DXVK_HUD"] = cfg.preset.dxvkHudElements
        }
        return env
    }
}

// MARK: - Persistence Manager

/// Thread-safe persistence and launch-environment provider for `MetalHUDConfiguration`.
/// Stores JSON at `~/Library/Application Support/DirectMetal/hud_config.json`
/// (overridable via `DIRECTMETAL_HUD_CONFIG` for isolated tests).
enum MetalHUDConfigManager {
    static let fileName = "hud_config.json"
    static let envOverrideKey = "DIRECTMETAL_HUD_CONFIG"

    private static let lock = NSLock()

    static var configURL: URL {
        if let override = ProcessInfo.processInfo.environment[envOverrideKey], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return GameLibraryManager.defaultSupportRoot().appendingPathComponent(fileName)
    }

    /// Loads the saved HUD configuration, returning `.defaultConfig` if absent or malformed.
    static func load() -> MetalHUDConfiguration {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }

    private static func loadUnlocked() -> MetalHUDConfiguration {
        let url = configURL
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(MetalHUDConfiguration.self, from: data) else {
            return .defaultConfig
        }
        return decoded.normalized()
    }

    /// Persists a normalized HUD configuration atomically to disk.
    static func save(_ config: MetalHUDConfiguration) throws {
        let normalized = config.normalized()
        lock.lock()
        defer { lock.unlock() }

        let url = configURL
        let fm = FileManager.default
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(normalized)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Removes any persisted HUD config file so future loads return `.defaultConfig`.
    static func reset() throws {
        lock.lock()
        defer { lock.unlock() }

        let url = configURL
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    /// Convenience helper for `RuntimeLauncher` and CLI callers.
    static func launchEnvironment(hudEnabled: Bool) -> [String: String] {
        guard hudEnabled else {
            return ["MTL_HUD_ENABLED": "0"]
        }
        return load().environmentVariables(hudEnabled: true)
    }
}
