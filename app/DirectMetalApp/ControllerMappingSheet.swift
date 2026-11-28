import AppKit
import SwiftUI

// MARK: - Controller mapping, dead zones + live tester

struct ControllerMappingSheet: View {
    let entry: GameLibraryEntry?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var tester = ControllerLiveTester()
    @State private var perGame: Bool
    @State private var draft: ControllerMappingProfile
    @State private var source: String
    @State private var saveError: String?
    @State private var showEnv = false

    init(entry: GameLibraryEntry?) {
        self.entry = entry
        let hasGameProfile = entry.map { ControllerMappingManager.storedProfile(for: $0.id) != nil } ?? false
        let resolved = ControllerMappingManager.resolvedProfile(for: hasGameProfile ? entry?.id : nil)
        _perGame = State(initialValue: hasGameProfile)
        _draft = State(initialValue: resolved.profile)
        _source = State(initialValue: resolved.source)
    }

    private var scopeKey: String {
        perGame ? (entry?.id ?? ControllerMappingManager.defaultKey) : ControllerMappingManager.defaultKey
    }

    private func reload() {
        let r = ControllerMappingManager.resolvedProfile(for: perGame ? entry?.id : nil)
        draft = r.profile
        source = r.source
    }

    private func persist() {
        do {
            try ControllerMappingManager.setProfile(draft, for: scopeKey)
            saveError = nil
        } catch {
            saveError = "Could not save controller profile: \(error.localizedDescription)"
        }
        source = ControllerMappingManager.resolvedProfile(for: perGame ? entry?.id : nil).source
    }

    /// Edits that save immediately.
    private func binding<T>(_ kp: WritableKeyPath<ControllerMappingProfile, T>) -> Binding<T> {
        Binding(get: { draft[keyPath: kp] }, set: { draft[keyPath: kp] = $0; persist() })
    }

    private var sourceText: String {
        switch source {
        case "game": return "Custom profile for this game"
        case "global": return perGame ? "Inherits the global profile until you change something" : "Global profile (all games without their own)"
        default: return "Stock behavior — no controller environment is added at launch"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Label("Controller Mapping & Dead Zones", systemImage: "gamecontroller.fill")
                    .font(.title2.bold())
                Spacer()
                Label(tester.activeControllerName ?? "No controller", systemImage: tester.activeControllerName == nil ? "gamecontroller" : "dot.radiowaves.left.and.right")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(tester.activeControllerName == nil ? Color.secondary : Color.green)
            }
            .padding([.horizontal, .top], 22)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    scopeAndPreset
                    HStack(alignment: .top, spacing: 16) {
                        remapGrid
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        VStack(alignment: .leading, spacing: 14) {
                            sticksAndOptions
                            GroupBox {
                                ControllerTesterView(tester: tester, profile: draft)
                                    .padding(4)
                            } label: {
                                Label("Live Input Tester", systemImage: "waveform.path.ecg")
                            }
                        }
                        .frame(width: 330)
                    }
                    envPreview
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 12)
            }

            Divider()
            HStack(spacing: 10) {
                Button(role: .destructive) {
                    do {
                        try ControllerMappingManager.resetProfile(for: scopeKey)
                        saveError = nil
                    } catch {
                        saveError = "Could not reset: \(error.localizedDescription)"
                    }
                    reload()
                } label: {
                    Label(perGame ? "Reset Game Profile" : "Reset Global Profile", systemImage: "arrow.counterclockwise")
                }
                if let saveError {
                    Text(saveError).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else {
                    Text("Changes save automatically to \(ControllerMappingManager.profilesURL.lastPathComponent) and apply on the next launch.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .frame(width: 820, height: 680)
        .onAppear { tester.start() }
        .onDisappear { tester.stop() }
    }

    private var scopeAndPreset: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Scope", selection: Binding(get: { perGame }, set: { perGame = $0; reload() })) {
                    Text("Global (all games)").tag(false)
                    Text(entry.map { "This game: \($0.title)" } ?? "This game").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(entry == nil)
                Text(sourceText).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Text("Preset").foregroundStyle(.secondary)
                    Picker("Preset", selection: Binding(get: { draft.preset }, set: { draft.applyPreset($0); persist() })) {
                        ForEach(ControllerPreset.allCases) { p in Text(p.displayName).tag(p) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 300)
                    Text(draft.preset.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Label("Profile", systemImage: "person.crop.circle")
        }
    }

    private var remapGrid: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                GridRow {
                    Text("Press").font(.caption.bold()).foregroundStyle(.secondary)
                    Text("Game receives").font(.caption.bold()).foregroundStyle(.secondary)
                }
                ForEach(ControllerMappingProfile.canonicalButtons, id: \.self) { b in
                    GridRow {
                        Text(ControllerMappingProfile.label(for: b))
                            .font(.callout)
                            .foregroundStyle(tester.pressedButtons.contains(b) ? Color.green : Color.primary)
                        Picker(ControllerMappingProfile.label(for: b), selection: Binding(
                            get: { draft.buttonMap[b] ?? b },
                            set: { draft.buttonMap[b] = $0; draft.preset = .custom; persist() }
                        )) {
                            ForEach(ControllerMappingProfile.canonicalButtons, id: \.self) { t in
                                Text(ControllerMappingProfile.label(for: t)).tag(t)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                    }
                }
            }
            .padding(6)
        } label: {
            Label("Button Remapping", systemImage: "arrow.left.arrow.right")
        }
    }

    private var sticksAndOptions: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                deadzoneSlider("Left stick", \.leftDeadzone)
                deadzoneSlider("Right stick", \.rightDeadzone)
                Toggle("Invert right stick Y (look)", isOn: binding(\.invertRightY))
                Toggle("Haptics / rumble", isOn: binding(\.enableHaptics))
            }
            .toggleStyle(.checkbox)
            .padding(6)
        } label: {
            Label("Sticks & Feedback", systemImage: "dial.medium")
        }
    }

    private func deadzoneSlider(_ title: String, _ kp: WritableKeyPath<ControllerMappingProfile, Double>) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 78, alignment: .leading)
            Slider(value: Binding(get: { draft[keyPath: kp] }, set: { draft[keyPath: kp] = ControllerMappingProfile.clampDeadzone($0) }),
                   in: ControllerMappingProfile.deadzoneRange, step: 0.01) { editing in
                if !editing { persist() }
            }
            Text(String(format: "%2.0f%%", draft[keyPath: kp] * 100))
                .font(.callout.monospacedDigit())
                .frame(width: 38, alignment: .trailing)
        }
    }

    private var envPreview: some View {
        let env = ControllerMappingManager.environmentOverrides(profile: draft, key: scopeKey)
        return DisclosureGroup(isExpanded: $showEnv) {
            ScrollView(.horizontal) {
                Text(env.isEmpty ? "No variables (stock profile)."
                     : env.keys.sorted().map { "\($0)=\(env[$0]!.split(separator: "\n").first.map(String.init) ?? "")" }.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        } label: {
            Text("Launch environment (\(env.count) variable\(env.count == 1 ? "" : "s"); SDL_GAMECONTROLLERCONFIG shows its first mapping)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Visualizes live stick, trigger and button state; buttons show their remapped output.
struct ControllerTesterView: View {
    @ObservedObject var tester: ControllerLiveTester
    let profile: ControllerMappingProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if tester.activeControllerName == nil {
                Text("Connect a Bluetooth or USB controller and press any button.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .center, spacing: 14) {
                StickIndicator(label: "L", point: tester.leftStick, deadzone: profile.leftDeadzone, invertY: false)
                StickIndicator(label: "R", point: tester.rightStick, deadzone: profile.rightDeadzone, invertY: profile.invertRightY)
                VStack(spacing: 8) {
                    TriggerIndicator(label: "LT", value: tester.leftTrigger)
                    TriggerIndicator(label: "RT", value: tester.rightTrigger)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 4) {
                ForEach(ControllerMappingProfile.canonicalButtons, id: \.self) { b in
                    let pressed = tester.pressedButtons.contains(b)
                    let out = profile.buttonMap[b] ?? b
                    VStack(spacing: 0) {
                        Text(ControllerMappingProfile.shortLabel(for: b))
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                        if out != b {
                            Text("→\(ControllerMappingProfile.shortLabel(for: out))")
                                .font(.system(size: 8, weight: .semibold, design: .rounded))
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .foregroundStyle(pressed ? Color.white : Color.primary)
                    .background(pressed ? Color.green.opacity(0.85) : Color.secondary.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
        }
    }
}

struct StickIndicator: View {
    let label: String
    let point: CGPoint
    let deadzone: Double
    let invertY: Bool
    private let size: CGFloat = 78

    var body: some View {
        let magnitude = sqrt(point.x * point.x + point.y * point.y)
        let inDeadzone = magnitude <= CGFloat(deadzone)
        let r = size / 2
        VStack(spacing: 3) {
            ZStack {
                Circle().fill(Color.secondary.opacity(0.08))
                Circle().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
                Circle()
                    .fill(Color.orange.opacity(0.18))
                    .frame(width: size * CGFloat(deadzone), height: size * CGFloat(deadzone))
                Circle()
                    .fill(inDeadzone ? Color.secondary : Color.accentColor)
                    .frame(width: 10, height: 10)
                    .offset(x: max(-1, min(1, point.x)) * (r - 6), y: -max(-1, min(1, point.y)) * (r - 6))
            }
            .frame(width: size, height: size)
            Text("\(label) · DZ \(Int((deadzone * 100).rounded()))%\(invertY ? " · Y inv" : "")")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

struct TriggerIndicator: View {
    let label: String
    let value: Float

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10, weight: .bold, design: .rounded)).frame(width: 18)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.12))
                Capsule().fill(Color.accentColor).frame(width: 90 * CGFloat(max(0, min(1, value))))
            }
            .frame(width: 90, height: 8)
            Text(String(format: "%3.0f%%", value * 100)).font(.system(size: 9.5).monospacedDigit()).frame(width: 34, alignment: .trailing)
        }
    }
}
