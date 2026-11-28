import AppKit
import SwiftUI

// MARK: - SwiftUI Alignment Helpers

extension MetalHUDAlignment {
    var swiftUIAlignment: Alignment {
        switch self {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }

    var scaleAnchor: UnitPoint {
        switch self {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }
}

// MARK: - Live Metal Performance HUD Customizer Sheet

struct MetalHUDCustomizerSheet: View {
    @ObservedObject var vm: DirectMetalViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var config: MetalHUDConfiguration
    @State private var saveError: String?
    @State private var copiedEnv: Bool = false

    init(vm: DirectMetalViewModel) {
        self.vm = vm
        _config = State(initialValue: MetalHUDConfigManager.load())
    }

    private var normalizedConfig: MetalHUDConfiguration {
        config.normalized()
    }

    private var previewEnvironment: [String: String] {
        normalizedConfig.environmentVariables(hudEnabled: true)
    }

    private var scalePercent: Int {
        Int((normalizedConfig.scale * 100.0).rounded())
    }

    private var opacityPercent: Int {
        Int((normalizedConfig.opacity * 100.0).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    previewStageSection
                    presetPickerSection

                    HStack(alignment: .top, spacing: 14) {
                        alignmentSelectorCard
                            .frame(width: 240)
                        slidersAndOptionsCard
                            .frame(maxWidth: .infinity)
                    }

                    environmentPreviewCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }

            Divider()

            footerBar
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 540, idealHeight: 620)
    }

    // MARK: Header

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Metal Performance HUD Customizer")
                    .font(.title3.bold())
                Text("Configure live overlay telemetry, corner placement, scale, and opacity for Metal & DX9 launches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(vm.gpuSummary)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Live Interactive Corner Preview Canvas

    private var previewStageSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                MetalHUDPreviewCanvas(
                    config: normalizedConfig,
                    gpuInfo: vm.gpuInfo,
                    onSelectAlignment: { chosen in
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            config.alignment = chosen
                        }
                    }
                )
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 245)

                HStack(spacing: 12) {
                    Label("Click any corner in the viewport to reposition the HUD.", systemImage: "hand.tap")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(normalizedConfig.preset.displayName) · \(normalizedConfig.alignment.displayName) · \(scalePercent)% · \(opacityPercent)% opacity")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
        } label: {
            Label("Live Viewport Preview (16:9)", systemImage: "display")
                .font(.subheadline.weight(.semibold))
        }
    }

    // MARK: Preset Picker Cards

    private var presetPickerSection: some View {
        GroupBox {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: 130), spacing: 10),
                    GridItem(.flexible(minimum: 130), spacing: 10),
                ],
                spacing: 10
            ) {
                ForEach(MetalHUDPreset.allCases) { preset in
                    presetCard(preset)
                }
            }
            .padding(4)
        } label: {
            Label("Telemetry Preset", systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.semibold))
        }
    }

    private func presetCard(_ preset: MetalHUDPreset) -> some View {
        let selected = normalizedConfig.preset == preset
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                config.preset = preset
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: preset.symbolName)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    Text(preset.displayName)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                }

                Text(preset.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 4) {
                    ForEach(preset.metricHighlights, id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                            .background(
                                (selected ? Color.accentColor : Color.secondary).opacity(0.13),
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                            )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                selected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        selected ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.22),
                        lineWidth: selected ? 1.5 : 1.0
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: 2×2 Corner Alignment Selector

    private var alignmentSelectorCard: some View {
        GroupBox {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    alignmentButton(.topLeft)
                    alignmentButton(.topRight)
                }
                HStack(spacing: 8) {
                    alignmentButton(.bottomLeft)
                    alignmentButton(.bottomRight)
                }
            }
            .padding(4)
        } label: {
            Label("Corner Alignment", systemImage: "rectangle.inset.topleft.filled")
                .font(.subheadline.weight(.semibold))
        }
    }

    private func alignmentButton(_ alignment: MetalHUDAlignment) -> some View {
        let selected = normalizedConfig.alignment == alignment
        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                config.alignment = alignment
            }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: alignment.symbolName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(alignment.displayName)
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .background(
                selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        selected ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.22),
                        lineWidth: selected ? 1.5 : 1.0
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Scale, Opacity & DX9 Options

    private var slidersAndOptionsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("HUD Scale")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Text("\(scalePercent)%")
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { normalizedConfig.scale },
                            set: { config.scale = MetalHUDConfiguration.clampScale($0) }
                        ),
                        in: MetalHUDConfiguration.scaleRange,
                        step: 0.05
                    )
                    HStack {
                        Text("50%").font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                        Text("100%").font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                        Text("200%").font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Opacity")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Text("\(opacityPercent)%")
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { normalizedConfig.opacity },
                            set: { config.opacity = MetalHUDConfiguration.clampOpacity($0) }
                        ),
                        in: MetalHUDConfiguration.opacityRange,
                        step: 0.05
                    )
                    HStack {
                        Text("25%").font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                        Text("85%").font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                        Text("100%").font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                Divider()

                Toggle(isOn: $config.showDXVKHudOnDX9) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show DXVK HUD on DirectX 9 games")
                            .font(.callout.weight(.medium))
                        Text("Mirrors this preset into DXVK_HUD when running DX9 titles via DXVK.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .padding(4)
        } label: {
            Label("Appearance & DirectX 9 Overlay", systemImage: "dial.medium")
                .font(.subheadline.weight(.semibold))
        }
    }

    // MARK: Live Environment Variable Preview

    private var environmentPreviewCard: some View {
        let env = previewEnvironment
        let lines = env.keys.sorted().compactMap { key in
            env[key].map { "\(key)=\($0)" }
        }
        let joined = lines.joined(separator: "\n")

        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Emitted when the game's Metal Performance HUD toggle is enabled:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(joined, forType: .string)
                        copiedEnv = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copiedEnv = false
                        }
                    } label: {
                        Label(copiedEnv ? "Copied" : "Copy Env", systemImage: copiedEnv ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    Text(joined)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .padding(4)
        } label: {
            Label("Launch Environment Preview (\(env.count) variables)", systemImage: "terminal")
                .font(.subheadline.weight(.semibold))
        }
    }

    // MARK: Footer

    private var footerBar: some View {
        HStack(spacing: 10) {
            Button(role: .destructive) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    config = .defaultConfig
                    saveError = nil
                }
            } label: {
                Label("Reset Defaults", systemImage: "arrow.counterclockwise")
            }
            .disabled(normalizedConfig == .defaultConfig)

            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                Text("Saved to \(MetalHUDConfigManager.configURL.lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("Save") {
                saveAndDismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func saveAndDismiss() {
        let finalConfig = normalizedConfig
        do {
            try MetalHUDConfigManager.save(finalConfig)
            saveError = nil
            vm.statusMessage =
                "Saved Metal Performance HUD (\(finalConfig.preset.displayName), \(finalConfig.alignment.displayName), \(scalePercent)% scale, \(opacityPercent)% opacity)."
            dismiss()
        } catch {
            saveError = "Could not save HUD config: \(error.localizedDescription)"
        }
    }
}

// MARK: - Interactive 16:9 Viewport Preview & Simulated Metal HUD Badge

private struct MetalHUDPreviewCanvas: View {
    let config: MetalHUDConfiguration
    let gpuInfo: MetalHardwareInfo
    let onSelectAlignment: (MetalHUDAlignment) -> Void

    @State private var hoveredCorner: MetalHUDAlignment?

    /// Keeps the preview badge crisp and legible across 50%–200% without overflowing the 16:9 stage.
    private var previewScaleFactor: CGFloat {
        CGFloat(0.45 + 0.55 * config.scale)
    }

    private var metalLabel: String {
        if gpuInfo.supportsMetal4 { return "Metal 4" }
        if gpuInfo.supportsMetal3 { return "Metal 3" }
        return "Metal"
    }

    private var gpuDisplayName: String {
        let name = gpuInfo.gpuName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "Unavailable" {
            return "Apple Silicon GPU"
        }
        return name
    }

    private var workingSetLabel: String {
        let total = gpuInfo.workingSetGiB > 0.5 ? gpuInfo.workingSetGiB : 16.0
        let used = min(4.2, total * 0.45)
        return String(format: "%.1f / %.0f GB", used, total)
    }

    var body: some View {
        ZStack {
            gameSceneBackdrop

            // Subtle interactive corner targets so clicking any corner moves the HUD directly.
            cornerHotspots

            // Live Metal Performance HUD badge positioned in the chosen corner.
            ZStack(alignment: config.alignment.swiftUIAlignment) {
                Color.clear
                MetalHUDPreviewBadge(
                    preset: config.preset,
                    gpuName: gpuDisplayName,
                    metalLabel: metalLabel,
                    workingSetLabel: workingSetLabel
                )
                .scaleEffect(previewScaleFactor, anchor: config.alignment.scaleAnchor)
                .opacity(config.opacity)
                .padding(12)
                .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
    }

    private var gameSceneBackdrop: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.07, blue: 0.13),
                    Color(red: 0.08, green: 0.11, blue: 0.19),
                    Color(red: 0.04, green: 0.05, blue: 0.09),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color(red: 0.16, green: 0.36, blue: 0.62).opacity(0.32),
                    Color.clear,
                ],
                center: UnitPoint(x: 0.5, y: 0.38),
                startRadius: 12,
                endRadius: 210
            )

            // Stylized horizon and perspective ground grid to evoke a live 3D game frame.
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let horizonY = h * 0.56

                Path { path in
                    path.move(to: CGPoint(x: 0, y: horizonY))
                    path.addLine(to: CGPoint(x: w, y: horizonY))

                    for step in 1...4 {
                        let t = CGFloat(step) / 4.0
                        let y = horizonY + (h - horizonY) * (t * t)
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: w, y: y))
                    }

                    let vanish = CGPoint(x: w * 0.5, y: horizonY)
                    for idx in -4...4 {
                        let bottomX = w * 0.5 + CGFloat(idx) * (w * 0.18)
                        path.move(to: vanish)
                        path.addLine(to: CGPoint(x: bottomX, y: h))
                    }
                }
                .stroke(Color.cyan.opacity(0.12), lineWidth: 0.75)

                // Center crosshair reticle for viewport authenticity.
                Path { path in
                    let cx = w * 0.5
                    let cy = h * 0.5
                    path.move(to: CGPoint(x: cx - 7, y: cy))
                    path.addLine(to: CGPoint(x: cx - 2.5, y: cy))
                    path.move(to: CGPoint(x: cx + 2.5, y: cy))
                    path.addLine(to: CGPoint(x: cx + 7, y: cy))
                    path.move(to: CGPoint(x: cx, y: cy - 7))
                    path.addLine(to: CGPoint(x: cx, y: cy - 2.5))
                    path.move(to: CGPoint(x: cx, y: cy + 2.5))
                    path.addLine(to: CGPoint(x: cx, y: cy + 7))
                }
                .stroke(Color.white.opacity(0.24), lineWidth: 1)
            }

            VStack {
                Spacer()
                Text("2560 × 1440 · \(metalLabel) · ProMotion 120 Hz")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.32))
                    .padding(.bottom, 6)
            }
        }
    }

    private var cornerHotspots: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                cornerZone(.topLeft)
                cornerZone(.topRight)
            }
            HStack(spacing: 0) {
                cornerZone(.bottomLeft)
                cornerZone(.bottomRight)
            }
        }
    }

    private func cornerZone(_ alignment: MetalHUDAlignment) -> some View {
        let isSelected = config.alignment == alignment
        let isHovered = hoveredCorner == alignment

        return Button {
            onSelectAlignment(alignment)
        } label: {
            ZStack(alignment: alignment.swiftUIAlignment) {
                Color.clear
                if !isSelected {
                    Text(alignment.displayName)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(isHovered ? 0.80 : 0.28))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Color.white.opacity(isHovered ? 0.14 : 0.04),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(Color.white.opacity(isHovered ? 0.35 : 0.10), style: StrokeStyle(lineWidth: 0.75, dash: [3, 2]))
                        )
                        .padding(10)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredCorner = hovering ? alignment : (hoveredCorner == alignment ? nil : hoveredCorner)
        }
    }
}

private struct MetalHUDPreviewBadge: View {
    let preset: MetalHUDPreset
    let gpuName: String
    let metalLabel: String
    let workingSetLabel: String

    private static let frameTimeSamples: [Double] = [
        8.2, 8.4, 8.1, 8.5, 8.3, 8.7, 8.2, 8.1, 8.4, 9.6,
        8.5, 8.2, 8.3, 8.1, 8.4, 8.2, 8.0, 8.6, 8.3, 8.4,
        8.2, 10.4, 8.8, 8.3, 8.2, 8.4, 8.1, 8.3, 8.5, 8.2,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 3.5) {
            if preset != .minimal {
                HStack(spacing: 5) {
                    Text(gpuName)
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.white)
                    Text("·")
                        .foregroundStyle(Color.white.opacity(0.45))
                    Text(metalLabel)
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.cyan)
                    Text("2560×1440")
                        .font(.system(size: 8, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.72))
                    if preset == .detailed {
                        Text("MetalFX 1.5×")
                            .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.mint)
                    }
                }
            }

            HStack(spacing: 8) {
                metricPair(label: "FPS", value: "118.4", accent: .green)
                metricPair(label: "Frame", value: "8.4 ms", accent: .white)
                if preset != .minimal {
                    metricPair(label: "GPU", value: "6.9 ms", accent: .cyan)
                }
                if preset == .detailed {
                    metricPair(label: "CPU", value: "3.1 ms", accent: .yellow)
                }
            }

            if preset != .minimal {
                HStack(spacing: 8) {
                    metricPair(label: preset == .detailed ? "UMA" : "Mem", value: workingSetLabel, accent: .white.opacity(0.9))
                    if preset == .frameGraph || preset == .detailed {
                        metricPair(label: "1% Low", value: "96.2", accent: .orange)
                    }
                }
            }

            if preset == .frameGraph || preset == .detailed {
                MetalHUDFrameGraphSparkline(samples: Self.frameTimeSamples)
                    .frame(width: preset == .detailed ? 210 : 178, height: 22)
                    .padding(.top, 1)
            }

            if preset == .detailed {
                HStack(spacing: 8) {
                    metricPair(label: "Present", value: "Direct", accent: .white.opacity(0.85))
                    metricPair(label: "Shaders", value: "0", accent: .white.opacity(0.85))
                    HStack(spacing: 3) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 5, height: 5)
                        Text("Thermal: Nominal")
                            .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.85))
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6.5)
        .background(Color.black.opacity(0.80), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75)
        )
        .shadow(color: Color.black.opacity(0.45), radius: 6, y: 2)
    }

    private func metricPair(label: String, value: String, accent: Color) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.58))
            Text(value)
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)
        }
    }
}

private struct MetalHUDFrameGraphSparkline: View {
    let samples: [Double]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let minVal = 6.0
            let maxVal = 13.0
            let span = max(maxVal - minVal, 0.1)

            ZStack {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white.opacity(0.06))

                // 8.33 ms (120 Hz) target pacing guideline.
                let targetY = h * CGFloat(1.0 - (8.33 - minVal) / span)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: targetY))
                    path.addLine(to: CGPoint(x: w, y: targetY))
                }
                .stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 0.6, dash: [2, 2]))

                // Area fill beneath frame-time curve.
                Path { path in
                    guard samples.count >= 2 else { return }
                    let stepX = w / CGFloat(samples.count - 1)
                    path.move(to: CGPoint(x: 0, y: h))
                    for (idx, val) in samples.enumerated() {
                        let clamped = min(max(val, minVal), maxVal)
                        let x = CGFloat(idx) * stepX
                        let y = h * CGFloat(1.0 - (clamped - minVal) / span)
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [Color.green.opacity(0.32), Color.green.opacity(0.03)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                // Crisp green frame-time line.
                Path { path in
                    guard samples.count >= 2 else { return }
                    let stepX = w / CGFloat(samples.count - 1)
                    for (idx, val) in samples.enumerated() {
                        let clamped = min(max(val, minVal), maxVal)
                        let x = CGFloat(idx) * stepX
                        let y = h * CGFloat(1.0 - (clamped - minVal) / span)
                        if idx == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(Color.green, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
