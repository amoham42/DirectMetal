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
