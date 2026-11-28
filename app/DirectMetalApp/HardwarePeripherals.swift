import AppKit
import CoreGraphics
import Foundation
import GameController

// MARK: - Display: Retina / ProMotion / HDR-EDR telemetry

/// Main-display capabilities. Works headless too: without a window server every field falls back to
/// neutral values and `displayAvailable == false`.
struct DisplayCapabilities: Codable, Equatable {
    var displayAvailable: Bool
    var displayName: String
    var logicalWidth: Int
    var logicalHeight: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var scaleFactor: Double
    /// Windows LogPixels DPI DirectMetal applies with Retina mode (96 x backing scale).
    var dpi: Int
    var refreshRateHz: Double
    var variableRefresh: Bool
    /// Current EDR headroom (1.0 == SDR; rises with HDR content / brightness headroom).
    var edrHeadroom: Double
    /// Maximum EDR headroom the display can ever provide (XDR panels: ~16).
    var potentialEDRHeadroom: Double
    var supportsHDR: Bool
    /// `appkit` (NSScreen + CoreGraphics), `coregraphics` (off-main / no NSScreen) or `unavailable`.
    var source: String

    var isRetina: Bool { scaleFactor > 1.01 }
    var isProMotion: Bool { refreshRateHz >= 100 || variableRefresh }

    static let unavailable = DisplayCapabilities(
        displayAvailable: false, displayName: "No display", logicalWidth: 0, logicalHeight: 0,
        pixelWidth: 0, pixelHeight: 0, scaleFactor: 1.0, dpi: 96, refreshRateHz: 0, variableRefresh: false,
        edrHeadroom: 1.0, potentialEDRHeadroom: 1.0, supportsHDR: false, source: "unavailable"
    )

    /// Snapshot of the main display. Uses AppKit on the main thread; CoreGraphics only elsewhere.
    static func current() -> DisplayCapabilities {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { probeAppKit() }
        }
        return probeCoreGraphics()
    }

    private static func probeCoreGraphics() -> DisplayCapabilities {
        let id = CGMainDisplayID()
        guard id != kCGNullDirectDisplay, CGDisplayIsActive(id) != 0 || CGDisplayIsOnline(id) != 0,
              let mode = CGDisplayCopyDisplayMode(id) else { return .unavailable }
        var caps = DisplayCapabilities.unavailable
        caps.displayAvailable = true
        caps.displayName = CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)"
        caps.logicalWidth = max(mode.width, 1)
        caps.logicalHeight = max(mode.height, 1)
        caps.pixelWidth = max(mode.pixelWidth, caps.logicalWidth)
        caps.pixelHeight = max(mode.pixelHeight, caps.logicalHeight)
        caps.scaleFactor = max(Double(caps.pixelWidth) / Double(caps.logicalWidth), 1.0)
        caps.dpi = max(96, Int((96.0 * caps.scaleFactor).rounded()))
        caps.refreshRateHz = mode.refreshRate
        caps.source = "coregraphics"
        return caps
    }

    @MainActor
    private static func probeAppKit() -> DisplayCapabilities {
        var caps = probeCoreGraphics()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return caps }
        caps.displayAvailable = true
        caps.displayName = screen.localizedName
        let frame = screen.frame.size
        if caps.logicalWidth == 0 {
            caps.logicalWidth = Int(frame.width)
            caps.logicalHeight = Int(frame.height)
        }
        let scale = Double(screen.backingScaleFactor)
        if scale > 0 {
            caps.scaleFactor = scale
            caps.dpi = max(96, Int((96.0 * scale).rounded()))
            if caps.pixelWidth == 0 {
                caps.pixelWidth = Int((Double(frame.width) * scale).rounded())
                caps.pixelHeight = Int((Double(frame.height) * scale).rounded())
            }
        }
        caps.refreshRateHz = max(caps.refreshRateHz, Double(screen.maximumFramesPerSecond))
        let minInterval = screen.minimumRefreshInterval
        let maxInterval = screen.maximumRefreshInterval
        caps.variableRefresh = minInterval > 0 && maxInterval > minInterval * 1.05
        caps.edrHeadroom = max(1.0, Double(screen.maximumExtendedDynamicRangeColorComponentValue))
        caps.potentialEDRHeadroom = max(1.0, Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue))
        caps.supportsHDR = caps.potentialEDRHeadroom > 1.01
        caps.source = "appkit"
        return caps
    }

    /// e.g. "1512×982 @2x Retina"
    var resolutionLabel: String {
        guard displayAvailable else { return "No display" }
        let scale = scaleFactor.rounded() == scaleFactor ? String(format: "%.0fx", scaleFactor) : String(format: "%.2fx", scaleFactor)
        return "\(logicalWidth)×\(logicalHeight) @\(scale)\(isRetina ? " Retina" : "")"
    }

    /// e.g. "120 Hz ProMotion"
    var refreshLabel: String {
        guard refreshRateHz > 0 else { return "Refresh n/a" }
        return String(format: "%.0f Hz", refreshRateHz) + (isProMotion ? " ProMotion" : "")
    }

    /// e.g. "HDR/EDR 16.0x" or "SDR"
    var hdrLabel: String {
        supportsHDR ? String(format: "HDR/EDR %.1fx", potentialEDRHeadroom) : "SDR"
    }
}

// MARK: - Game controllers

struct ConnectedControllerInfo: Codable, Equatable, Identifiable {
    var id: String
    var vendorName: String
    var productCategory: String
    var supportsHaptics: Bool
    /// 0...100, or `nil` when the controller does not report a battery.
    var batteryLevel: Int?
    var batteryState: String?
    var isAttachedToDevice: Bool

    init(_ c: GCController, index: Int) {
        vendorName = c.vendorName ?? "Game Controller"
        productCategory = c.productCategory
        supportsHaptics = c.haptics != nil
        if let battery = c.battery, battery.batteryState != .unknown || battery.batteryLevel > 0 {
            batteryLevel = Int((max(0, min(1, battery.batteryLevel)) * 100).rounded())
            switch battery.batteryState {
            case .charging: batteryState = "charging"
            case .discharging: batteryState = "discharging"
            case .full: batteryState = "full"
            default: batteryState = nil
            }
        } else {
            batteryLevel = nil
            batteryState = nil
        }
        isAttachedToDevice = c.isAttachedToDevice
        id = "\(index)-\(vendorName)-\(productCategory)"
    }

    /// Currently connected controllers. GameController discovers already-paired devices asynchronously after
    /// process start, so CLI callers on the main thread can pass `discoveryWait` to spin the run loop briefly.
    static func snapshot(discoveryWait: TimeInterval = 0) -> [ConnectedControllerInfo] {
        if discoveryWait > 0, Thread.isMainThread, GCController.controllers().isEmpty {
            let deadline = Date().addingTimeInterval(discoveryWait)
            while Date() < deadline, GCController.controllers().isEmpty {
                RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.05)))
            }
        }
        return GCController.controllers().enumerated().map { ConnectedControllerInfo($0.element, index: $0.offset) }
    }

    /// e.g. "DualSense Wireless Controller · haptics · 80%"
    var summary: String {
        var parts = [vendorName]
        if supportsHaptics { parts.append("haptics") }
        if let batteryLevel { parts.append("\(batteryLevel)%") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Live monitor for the GUI

/// Publishes display + controller changes (`GCControllerDidConnect/Disconnect`, screen parameter changes).
@MainActor
final class PeripheralMonitor: ObservableObject {
    @Published private(set) var display: DisplayCapabilities
    @Published private(set) var controllers: [ConnectedControllerInfo]

    private let observers = NotificationObserverBag()

    init() {
        display = DisplayCapabilities.current()
        controllers = ConnectedControllerInfo.snapshot()
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .GCControllerDidConnect,
            .GCControllerDidDisconnect,
            NSApplication.didChangeScreenParametersNotification,
            NSWindow.didChangeScreenNotification,
        ]
        for name in names {
            observers.add(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
    }

    func refresh() {
        let d = DisplayCapabilities.current()
        if d != display { display = d }
        let c = ConnectedControllerInfo.snapshot()
        if c != controllers { controllers = c }
    }
}

/// Removes block-based NotificationCenter observers when its owner goes away.
private final class NotificationObserverBag {
    private var tokens: [NSObjectProtocol] = []

    func add(_ token: NSObjectProtocol) {
        tokens.append(token)
    }

    deinit {
        for t in tokens { NotificationCenter.default.removeObserver(t) }
    }
}

// MARK: - GitHub Releases update checker

struct UpdateCheckResult: Codable, Equatable {
    var currentVersion: String
    var latestVersion: String?
    var updateAvailable: Bool
    var releaseURL: String?
    var publishedAt: String?
    var error: String?
    var checkedURL: String
    var disabled: Bool
}

/// Non-blocking GitHub Releases update check (`DIRECTMETAL_UPDATE_URL` overrides the endpoint;
/// `DIRECTMETAL_DISABLE_UPDATE_CHECK=1` turns it off). Accepts `https://` and `file://` endpoints only.
enum UpdateChecker {
    static let defaultURL = "https://api.github.com/repos/amoham42/DirectMetal/releases/latest"
    static let timeout: TimeInterval = 5

    static var endpoint: String {
        let env = ProcessInfo.processInfo.environment["DIRECTMETAL_UPDATE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (env?.isEmpty == false) ? env! : defaultURL
    }

    static var isDisabled: Bool {
        let v = ProcessInfo.processInfo.environment["DIRECTMETAL_DISABLE_UPDATE_CHECK"]?.lowercased() ?? ""
        return ["1", "true", "yes", "on"].contains(v)
    }

    /// Runs the check on a background queue and calls `completion` on the main queue.
    static func checkAsync(currentVersion: String = RuntimeLauncher.appVersion(),
                           completion: @escaping @MainActor @Sendable (UpdateCheckResult) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = check(currentVersion: currentVersion)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(result) }
            }
        }
    }

    /// Synchronous check (CLI / background threads only; never call on the GUI main thread).
    static func check(currentVersion: String = RuntimeLauncher.appVersion()) -> UpdateCheckResult {
        let urlString = endpoint
        var result = UpdateCheckResult(currentVersion: currentVersion, latestVersion: nil, updateAvailable: false,
                                       releaseURL: nil, publishedAt: nil, error: nil, checkedURL: urlString, disabled: false)
        if isDisabled {
            result.disabled = true
            result.error = "update check disabled (DIRECTMETAL_DISABLE_UPDATE_CHECK=1)"
            return result
        }
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), ["https", "file"].contains(scheme) else {
            result.error = "refusing update URL \(urlString) (only https:// and file:// are allowed)"
            return result
        }

        var json: Any
        switch fetchJSON(url) {
        case .success(let obj): json = obj
        case .failure(let err):
            result.error = err.description
            return result
        }

        // `/releases/latest` may point at a non-app tag (e.g. `conformance-bins-v0.2`): fall back to the
        // release list and pick the highest semantic version.
        if let obj = json as? [String: Any], let tag = obj["tag_name"] as? String, !isVersionTag(tag),
           urlString.hasSuffix("/releases/latest"),
           let listURL = URL(string: String(urlString.dropLast("/latest".count)) + "?per_page=30"),
           case .success(let list) = fetchJSON(listURL), list is [[String: Any]] {
            json = list
        }

        let candidates: [[String: Any]]
        if let obj = json as? [String: Any] {
            guard obj["tag_name"] != nil else {
                let message = obj["message"] as? String
                result.error = message.map { "GitHub: \($0)" } ?? "no release tag found at \(urlString)"
                return result
            }
            candidates = [obj]
        } else if let list = json as? [[String: Any]] {
            candidates = list.filter { ($0["draft"] as? Bool) != true && ($0["prerelease"] as? Bool) != true }
        } else {
            result.error = "unexpected JSON from \(urlString)"
            return result
        }
        let versioned = candidates.filter { isVersionTag(($0["tag_name"] as? String) ?? "") }
        guard let rel = versioned.max(by: {
            compareVersions(($0["tag_name"] as? String) ?? "", ($1["tag_name"] as? String) ?? "") == .orderedAscending
        }), let tag = rel["tag_name"] as? String else {
            let seen = candidates.compactMap { $0["tag_name"] as? String }.prefix(3).joined(separator: ", ")
            result.error = "no versioned DirectMetal release published yet" + (seen.isEmpty ? "" : " (found tags: \(seen))")
            return result
        }
        result.latestVersion = normalizedVersion(tag)
        result.releaseURL = rel["html_url"] as? String
        result.publishedAt = rel["published_at"] as? String
        result.updateAvailable = compareVersions(tag, currentVersion) == .orderedDescending
        return result
    }

    /// `v1.2.0`, `1.2`, `v1.0.0-beta.1` => true; `conformance-bins-v0.2` => false.
    static func isVersionTag(_ tag: String) -> Bool {
        tag.range(of: #"^[vV]?\d+(\.\d+){0,3}([-+][0-9A-Za-z.\-+]*)?$"#, options: .regularExpression) != nil
    }

    private static func fetchJSON(_ url: URL) -> Result<Any, FetchError> {
        switch fetch(url) {
        case .failure(let message): return .failure(FetchError(message))
        case .success(let data):
            guard let obj = try? JSONSerialization.jsonObject(with: data) else {
                return .failure(FetchError("invalid JSON from \(url.absoluteString)"))
            }
            return .success(obj)
        }
    }

    private struct FetchError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    private enum FetchResult {
        case success(Data)
        case failure(String)
    }

    private final class FetchBox: @unchecked Sendable {
        var result: FetchResult = .failure("update check timed out after 5 s")
    }

    private static func fetch(_ url: URL) -> FetchResult {
        if url.isFileURL {
            guard let d = try? Data(contentsOf: url), d.count <= 4 << 20 else {
                return .failure("could not read \(url.path)")
            }
            return .success(d)
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("DirectMetal/\(RuntimeLauncher.appVersion())", forHTTPHeaderField: "User-Agent")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let box = FetchBox()
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { data, response, error in
            if let error {
                box.result = .failure("network error: \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                box.result = .failure("HTTP \(http.statusCode) from \(url.absoluteString)")
            } else if let data, data.count <= 4 << 20 {
                box.result = .success(data)
            } else {
                box.result = .failure("empty response from \(url.absoluteString)")
            }
            done.signal()
        }.resume()
        if done.wait(timeout: .now() + timeout + 1) == .timedOut {
            return .failure("update check timed out after \(Int(timeout)) s")
        }
        return box.result
    }

    /// "v1.2.0" -> "1.2.0"
    static func normalizedVersion(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = s.first, first == "v" || first == "V" { s.removeFirst() }
        return s
    }

    /// Semantic-version comparison: numeric core (missing parts == 0), then a pre-release sorts before its release.
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        func split(_ raw: String) -> (core: [Int], pre: String?) {
            let s = normalizedVersion(raw).split(separator: "+", maxSplits: 1).first.map(String.init) ?? ""
            let parts = s.split(separator: "-", maxSplits: 1).map(String.init)
            let core = (parts.first ?? "").split(separator: ".").map { comp -> Int in
                Int(comp.prefix(while: { $0.isNumber })) ?? 0
            }
            return (core, parts.count > 1 ? parts[1] : nil)
        }
        let (ca, pa) = split(a)
        let (cb, pb) = split(b)
        for i in 0..<max(3, max(ca.count, cb.count)) {
            let x = i < ca.count ? ca[i] : 0
            let y = i < cb.count ? cb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        switch (pa, pb) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (x?, y?):
            let r = x.compare(y, options: .numeric)
            return r
        }
    }
}
