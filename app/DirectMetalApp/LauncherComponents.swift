import AppKit
import SwiftUI

// Reusable launcher building blocks: badges, pills, monograms, artwork, peripheral strip,
// sidebar rows and the status bar. Pure presentation — no state beyond what callers pass in.

// MARK: - Presentation helpers

struct LauncherBadge: Identifiable, Hashable {
    let text: String
    let color: Color
    var id: String { text }
}

enum LauncherStyle {
    static let metalFXOptions: [(tag: String, label: String)] = [
        ("off", "Off"),
        ("quality", "Quality 1.5x"),
        ("balanced", "Balanced 1.7x"),
        ("performance", "Perf 2.0x"),
        ("ultra_performance", "Ultra Perf 2.5x"),
    ]

    static func apiBadges(for entry: GameLibraryEntry) -> [LauncherBadge] {
        var out: [LauncherBadge] = []
        let apis = Set(entry.detectedAPIs)
        if apis.contains("D3D12") { out.append(LauncherBadge(text: "DX12", color: .purple)) }
        if apis.contains("D3D11") { out.append(LauncherBadge(text: "DX11", color: .blue)) }
        if apis.contains("D3D10") { out.append(LauncherBadge(text: "DX10", color: .teal)) }
        if apis.contains("D3D9") { out.append(LauncherBadge(text: "DX9", color: .orange)) }
        if !entry.detectedUpscalers.isEmpty || entry.launchUpscaleMode != nil {
            out.append(LauncherBadge(text: "MetalFX", color: .green))
        }
        return out
    }

    static func accent(for title: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .red, .mint, .cyan]
        let sum = title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
        return palette[sum % palette.count]
    }

    static func initials(for title: String) -> String {
        let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.prefix(2).compactMap { $0.first.map { String($0).uppercased() } }
        return letters.isEmpty ? "?" : letters.joined()
    }

    static func lastPlayedText(_ iso: String?) -> String {
        guard let iso, let date = GameLibraryManager.isoFormatter.date(from: iso) else { return "Never played" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "Played " + f.localizedString(for: date, relativeTo: Date())
    }
}

struct BadgeView: View {
    let badge: LauncherBadge
    var body: some View {
        Text(badge.text)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .foregroundStyle(badge.color)
            .background(badge.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct ArchPill: View {
    let architecture: String
    var body: some View {
        Text(architecture)
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .foregroundStyle(.secondary)
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.45), lineWidth: 0.8))
    }
}

/// Compact storefront pill (Steam / GOG / Epic); renders nothing for standalone / unknown games.
struct StorePill: View {
    let source: String?
    var gameID: String? = nil

    static func info(_ source: String?) -> (label: String, color: Color)? {
        switch source?.lowercased() {
        case "steam": return ("Steam", Color(red: 0.10, green: 0.27, blue: 0.47))
        case "gog": return ("GOG", Color(red: 0.49, green: 0.18, blue: 0.62))
        case "epic": return ("Epic", Color(white: 0.22))
        default: return nil
        }
    }

    var body: some View {
        if let info = StorePill.info(source) {
            Text(info.label)
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .foregroundStyle(.white)
                .background(info.color, in: Capsule())
                .help(gameID.map { "\(info.label) game ID \($0)" } ?? "Installed by \(info.label)")
        }
    }
}

struct GameMonogram: View {
    let title: String
    var size: CGFloat = 34
    var body: some View {
        let color = LauncherStyle.accent(for: title)
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.55)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(
                Text(LauncherStyle.initials(for: title))
                    .font(.system(size: size * 0.38, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            )
            .shadow(color: color.opacity(0.25), radius: size * 0.08, y: size * 0.04)
    }
}

struct StatusPill: View {
    let title: String
    let value: String
    let ok: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.callout.weight(.semibold))
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Real game artwork (Steam library art or the `.exe`'s embedded icon) with a `GameMonogram` fallback.
/// Artwork is decoded on a background queue and cached, so list scrolling never touches the disk.
struct GameArtworkView: View {
    let entry: GameLibraryEntry
    var style: ArtworkStyle = .icon
    var size: CGFloat = 34
    /// Frame width for wide art (Steam header banners); `nil` keeps every artwork square.
    var wideWidth: CGFloat? = nil
    @State private var image: NSImage?

    init(entry: GameLibraryEntry, style: ArtworkStyle = .icon, size: CGFloat = 34, wideWidth: CGFloat? = nil) {
        self.entry = entry
        self.style = style
        self.size = size
        self.wideWidth = wideWidth
        _image = State(initialValue: GameArtworkManager.shared.cachedArtwork(for: entry, style: style))
    }

    private var loadKey: String { GameArtworkManager.artworkKey(entry, style) }

    var body: some View {
        Group {
            if let image {
                let wide = image.size.width > image.size.height * 1.3
                let width = wide ? (wideWidth ?? size) : size
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * (wide ? 0.14 : 0.2), style: .continuous))
                    .shadow(color: .black.opacity(wide ? 0.22 : 0.12), radius: size * 0.06, y: size * 0.03)
            } else {
                GameMonogram(title: entry.title, size: size)
            }
        }
        .task(id: loadKey) { await load() }
    }

    private func load() async {
        let e = entry
        let s = style
        if let cached = GameArtworkManager.shared.cachedArtwork(for: e, style: s) {
            image = cached
            return
        }
        let box = await withCheckedContinuation { (cont: CheckedContinuation<ArtworkBox, Never>) in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: ArtworkBox(image: GameArtworkManager.shared.loadArtwork(for: e, style: s)))
            }
        }
        if !Task.isCancelled { image = box.image }
    }
}

private struct ArtworkBox: @unchecked Sendable {
    let image: NSImage?
}

/// "Community preset" pill + note for entries seeded from `game_profiles.json`.
struct ProfilePresetPill: View {
    let entry: GameLibraryEntry
    let profile: GameProfile?

    var body: some View {
        let verified = profile?.isVerified ?? false
        let tint: Color = verified ? .green : .orange
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Label("Community preset · \(profile?.title ?? entry.profileID ?? "Custom")",
                      systemImage: verified ? "checkmark.seal.fill" : "sparkles")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .foregroundStyle(tint)
                    .background(tint.opacity(0.14), in: Capsule())
                if let profile {
                    Text(profile.verificationLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let note = entry.profileNote, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(note)
            }
        }
    }
}

struct PeripheralChip: View {
    let icon: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.10), in: Capsule())
    }
}

/// Display (Retina / ProMotion / HDR-EDR) and game controller strip, live-updated by `PeripheralMonitor`.
struct PeripheralStrip: View {
    @ObservedObject var monitor: PeripheralMonitor
    /// Opens the controller remapping / dead zone sheet when set.
    var onControllers: (() -> Void)? = nil

    var body: some View {
        let d = monitor.display
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                PeripheralChip(icon: "display", text: d.resolutionLabel, tint: d.isRetina ? .blue : .secondary)
                    .help("\(d.displayName): \(d.pixelWidth)×\(d.pixelHeight) px, \(d.dpi) DPI LogPixels with Retina mode")
                PeripheralChip(icon: "gauge.with.dots.needle.67percent", text: d.refreshLabel,
                               tint: d.isProMotion ? .purple : .secondary)
                    .help(d.variableRefresh ? "Variable refresh (ProMotion / Adaptive-Sync)" : "Fixed refresh rate")
                PeripheralChip(icon: d.supportsHDR ? "sun.max.fill" : "sun.min", text: d.hdrLabel,
                               tint: d.supportsHDR ? .orange : .secondary)
                    .help(String(format: "EDR headroom now %.2fx, maximum %.2fx", d.edrHeadroom, d.potentialEDRHeadroom))
                Divider().frame(height: 14)
                if monitor.controllers.isEmpty {
                    PeripheralChip(icon: "gamecontroller", text: "No controller")
                        .help("Connect a Bluetooth or USB game controller; it appears here automatically.")
                } else {
                    ForEach(monitor.controllers) { c in
                        PeripheralChip(icon: "gamecontroller.fill", text: c.summary, tint: .green)
                            .help("\(c.productCategory)\(c.batteryState.map { " · \($0)" } ?? "")")
                    }
                }
                if let onControllers {
                    Button {
                        onControllers()
                    } label: {
                        Label("Controllers…", systemImage: "slider.horizontal.3")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Remap buttons, tune stick dead zones and haptics, and test controller input live")
                }
            }
            .padding(.vertical, 1)
        }
        .onAppear { monitor.refresh() }
    }
}

// MARK: - Sidebar row

struct GameRow: View {
    let entry: GameLibraryEntry
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 10) {
            GameArtworkView(entry: entry, style: .icon, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.system(.body, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    StorePill(source: entry.storeSource, gameID: entry.storeGameID)
                    ForEach(LauncherStyle.apiBadges(for: entry)) { BadgeView(badge: $0) }
                    ArchPill(architecture: entry.architecture)
                }
            }
            Spacer(minLength: 0)
            if isRunning {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 3)
        .help(entry.exePath)
    }
}

// MARK: - Status bar

struct LauncherStatusBar: View {
    @ObservedObject var vm: DirectMetalViewModel

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(vm.isRunning ? Color.orange : (vm.isScanning || vm.isCacheBusy ? Color.blue : Color.green))
                .frame(width: 8, height: 8)
            Text(vm.statusMessage)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
            Spacer(minLength: 12)
            Text("\(vm.library.count) game\(vm.library.count == 1 ? "" : "s")")
            Divider().frame(height: 12)
            Label(vm.runtimePaths == nil ? "Runtime missing" : "Runtime ready",
                  systemImage: vm.runtimePaths == nil ? "xmark.octagon" : "checkmark.circle")
                .foregroundStyle(vm.runtimePaths == nil ? Color.red : Color.secondary)
            Divider().frame(height: 12)
            Text(vm.gpuSummary)
            Divider().frame(height: 12)
            Text("v\(RuntimeLauncher.appVersion())")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - Hardware security / attestation card

/// Secure Enclave, SIP/SSV, hardened runtime and App Attest status with a self-verified key id.
struct AttestationSecurityCard: View {
    @ObservedObject var vm: DirectMetalViewModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let st = vm.attestationStatus {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                        StatusPill(title: "Secure Enclave", value: st.secureEnclaveAvailable ? "Active" : "Unavailable", ok: st.secureEnclaveAvailable)
                        StatusPill(title: "SIP", value: st.sipEnabled ? "Enabled" : "Disabled", ok: st.sipEnabled)
                        StatusPill(title: "SSV", value: st.ssvSealed ? "Sealed" : "Open", ok: st.ssvSealed)
                        StatusPill(title: "Hardened Runtime", value: st.hardenedRuntime ? "On" : "Off", ok: st.hardenedRuntime)
                        StatusPill(
                            title: "DCAppAttest",
                            value: st.appAttestProvisioned ? "Provisioned" : (st.dcAppAttestSupported ? "OS Ready (Dev ID)" : "Unsupported"),
                            ok: st.dcAppAttestSupported
                        )
                        StatusPill(title: "DCDevice", value: st.dcDeviceSupported ? "Supported" : "Unsupported", ok: st.dcDeviceSupported)
                    }
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow {
                            Text("key_id_sha256").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            HStack(spacing: 6) {
                                Text(vm.attestationKeyId.isEmpty ? "—" : vm.attestationKeyId)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                Text(vm.attestationVerified ? "SELF-VERIFY PASS" : "PENDING")
                                    .font(.caption2.bold())
                                    .foregroundStyle(vm.attestationVerified ? .green : .orange)
                            }
                        }
                        GridRow {
                            Text("CS Flags").foregroundStyle(.secondary)
                            Text("\(st.csStatusFlagsHex)  (valid=\(st.csValid ? "1" : "0") runtime=\(st.csRuntime ? "1" : "0") debugged=\(st.csDebugged ? "1" : "0"))")
                        }
                    }
                    .font(.caption.monospaced())
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Collecting hardware attestation telemetry…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            HStack {
                Label("Hardware Security & Secure Enclave Attestation", systemImage: "lock.shield")
                Spacer()
                if vm.attestationRunning { ProgressView().controlSize(.mini) }
                Button("Run Attestation") { vm.runAttestationCheck() }
                    .controlSize(.small)
                    .disabled(vm.attestationRunning)
            }
        }
    }
}
