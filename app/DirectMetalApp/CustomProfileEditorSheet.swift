import AppKit
import Foundation
import SwiftUI

// Native macOS 15 SwiftUI Custom Game Profile Editor & Community PR Exporter Sheet.
// Edits local overrides in `~/Library/Application Support/DirectMetal/game_profiles.json`
// (`directmetal.game_profiles.v1`), validates live with `UserProfileOverlayManager`,
// and exports clean JSON snippets for community PRs against `runtime/profiles/game_profiles.json`.

// MARK: - Picker Enum Conformances

extension PerfProfile: CaseIterable {
    static var allCases: [PerfProfile] { [.balanced, .ultra] }
}

extension DX9Backend: CaseIterable {
    static var allCases: [DX9Backend] { [.auto, .dxvk, .wined3d] }
}

// MARK: - Helpers

private struct ProfileEditorBanner: Equatable {
    let isError: Bool
    let message: String
    var tint: Color { isError ? .red : .green }
    var icon: String { isError ? "exclamationmark.octagon.fill" : "checkmark.circle.fill" }
}

private enum ProfileEditorFormat {
    static func perfLabel(_ p: PerfProfile) -> String { p == .ultra ? "Ultra" : "Balanced" }

    static func dx9Label(_ b: DX9Backend) -> String {
        switch b {
        case .auto: return "Auto"
        case .dxvk: return "DXVK"
        case .wined3d: return "WineD3D"
        }
    }

    static func parseCommaList(_ raw: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for token in raw.split(separator: ",", omittingEmptySubsequences: true) {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted {
                result.append(trimmed)
            }
        }
        return result
    }
}

// MARK: - Custom Profile Editor Sheet

struct CustomProfileEditorSheet: View {
    let entry: GameLibraryEntry
    @ObservedObject var vm: DirectMetalViewModel
    @Environment(\.dismiss) private var dismiss

    // Identity & matching
    @State private var profileID: String = ""
    @State private var title: String = ""
    @State private var gameEngine: String = ""
    @State private var matchExeNamesText: String = ""
    @State private var steamAppIdsText: String = ""
    @State private var storeSteam: Bool = false
    @State private var storeGOG: Bool = false
    @State private var storeEpic: Bool = false

    // Tuning settings
    @State private var perfProfile: PerfProfile = .balanced
    @State private var dx9Backend: DX9Backend = .auto
    @State private var upscaleMode: String = "off"
    @State private var retinaMode: Bool = true
    @State private var enableHUD: Bool = false
    @State private var enableSandbox: Bool = false

    // Honest verification & notes
    @State private var markVerifiedPlayable: Bool = false
    @State private var notes: String = ""

    // Preserved non-edited fields
    @State private var extraMatchTitles: [String] = []
    @State private var preservedGogGameIds: [String] = []
    @State private var preservedEpicAppNames: [String] = []
    @State private var autoPresetNotes: String = ""
    @State private var autoVerifiedNotes: String = ""

    // Overlay & UI state
    @State private var existingOverlayIDs: Set<String> = []
    @State private var statusBanner: ProfileEditorBanner?
    @State private var copiedPRJSON: Bool = false
    @State private var copyGeneration: Int = 0
    @State private var didInitialize: Bool = false

    init(entry: GameLibraryEntry, vm: DirectMetalViewModel) {
        self.entry = entry
        self._vm = ObservedObject(wrappedValue: vm)
    }

    // MARK: Derived state

    private var liveEntry: GameLibraryEntry {
        vm.library.first(where: { $0.id == entry.id }) ?? entry
    }

    private var trimmedProfileID: String {
        profileID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentIDExistsInOverlay: Bool {
        !trimmedProfileID.isEmpty && existingOverlayIDs.contains(trimmedProfileID)
    }

    private var hardwareVerifiedLabel: String {
        "\(vm.gpuInfo.gpuName) (macOS \(vm.gpuInfo.macosVersion))"
    }

    private var verificationToggleLabel: String {
        "Mark verified playable on this Mac (\(vm.gpuInfo.gpuName) · macOS \(vm.gpuInfo.macosVersion))"
    }

    private var currentDraft: GameProfile {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEngine = gameEngine.trimmingCharacters(in: .whitespacesAndNewlines)

        var matchTitles: [String] = []
        var seenTitles = Set<String>()
        for candidate in ([trimmedTitle] + extraMatchTitles) {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, seenTitles.insert(trimmed.lowercased()).inserted {
                matchTitles.append(trimmed)
            }
        }

        var stores: [String] = []
        if storeSteam { stores.append("steam") }
        if storeGOG { stores.append("gog") }
        if storeEpic { stores.append("epic") }

        return GameProfile(
            id: trimmedProfileID,
            title: trimmedTitle,
            matchTitles: matchTitles,
            matchExeNames: ProfileEditorFormat.parseCommaList(matchExeNamesText),
            steamAppIds: ProfileEditorFormat.parseCommaList(steamAppIdsText),
            perfProfile: perfProfile,
            dx9Backend: dx9Backend,
            upscaleMode: upscaleMode,
            retinaMode: retinaMode,
            enableHUD: enableHUD,
            enableSandbox: enableSandbox,
            status: markVerifiedPlayable ? "playable" : "preset",
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            verifiedOn: markVerifiedPlayable ? [hardwareVerifiedLabel] : ["preset"],
            gameEngine: trimmedEngine.isEmpty ? nil : trimmedEngine,
            stores: stores,
            gogGameIds: preservedGogGameIds,
            epicAppNames: preservedEpicAppNames
        )
    }

    // MARK: Body

    var body: some View {
        let draft = currentDraft
        let validationErrors = UserProfileOverlayManager.validate(draft)
        let isValid = validationErrors.isEmpty

        VStack(alignment: .leading, spacing: 0) {
            headerBar(isValid: isValid, errorCount: validationErrors.count)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let banner = statusBanner { statusBannerView(banner) }
                    validationBanner(errors: validationErrors)
                    identitySection
                    tuningSection
                    honestVerificationSection
                    notesSection
                }
                .padding(20)
            }

            Divider()
            footerBar(draft: draft, isValid: isValid)
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 540, idealHeight: 620)
        .onAppear {
            guard !didInitialize else { return }
            didInitialize = true
            initializeForm()
        }
        .onChange(of: markVerifiedPlayable) { _, isVerified in
            syncAutoNotesForVerificationToggle(isVerified: isVerified)
        }
    }

    // MARK: Header & Footer

    private func headerBar(isValid: Bool, errorCount: Int) -> some View {
        let badgeTint: Color = isValid ? .green : .orange
        let overrideTint: Color = currentIDExistsInOverlay ? .accentColor : .secondary
        return HStack(spacing: 12) {
            GameMonogram(title: title.isEmpty ? liveEntry.title : title, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Custom Game Profile Editor").font(.title3.bold()).lineLimit(1)
                    Text(currentIDExistsInOverlay ? "LOCAL OVERRIDE" : "DRAFT")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .foregroundStyle(overrideTint)
                        .background(overrideTint.opacity(0.14), in: Capsule())
                }
                HStack(spacing: 6) {
                    Text(liveEntry.title).font(.callout.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                    ArchPill(architecture: liveEntry.architecture)
                    ForEach(LauncherStyle.apiBadges(for: liveEntry)) { BadgeView(badge: $0) }
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Image(systemName: isValid ? "checkmark.seal.fill" : "exclamationmark.triangle.fill").font(.caption)
                Text(isValid ? "Valid" : "\(errorCount) Issue\(errorCount == 1 ? "" : "s")")
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            .foregroundStyle(badgeTint)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(badgeTint.opacity(0.14), in: Capsule())
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func footerBar(draft: GameProfile, isValid: Bool) -> some View {
        HStack(spacing: 10) {
            if currentIDExistsInOverlay {
                Button(role: .destructive) { removeOverride() } label: {
                    Label("Remove Override", systemImage: "trash")
                }
                .help("Remove '\(trimmedProfileID)' from ~/Library/Application Support/DirectMetal/game_profiles.json")
            }
            Spacer(minLength: 12)
            Button { copyPRJSON(draft) } label: {
                Label(copiedPRJSON ? "Copied!" : "Copy PR JSON", systemImage: copiedPRJSON ? "checkmark" : "doc.on.doc")
            }
            .disabled(!isValid)
            .help("Copy clean JSON snippet ready for a community PR against runtime/profiles/game_profiles.json")

            Button { saveLocalOverlay(draft) } label: {
                Label("Save Local Overlay", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isValid)
            .help("Save this profile to ~/Library/Application Support/DirectMetal/game_profiles.json")

            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    // MARK: Banners

    private func statusBannerView(_ banner: ProfileEditorBanner) -> some View {
        HStack(spacing: 8) {
            Image(systemName: banner.icon).foregroundStyle(banner.tint)
            Text(banner.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { withAnimation(.snappy(duration: 0.2)) { statusBanner = nil } } label: {
                Image(systemName: "xmark").font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss message")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(banner.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(banner.tint.opacity(0.30)))
    }

    private func validationBanner(errors: [String]) -> some View {
        let isValid = errors.isEmpty
        let tint: Color = isValid ? .green : (errors.count > 2 ? .red : .orange)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(tint)
                Text(
                    isValid
                        ? "Valid directmetal.game_profiles.v1 profile"
                        : "Schema validation failed (\(errors.count) issue\(errors.count == 1 ? "" : "s"))"
                )
                .font(.callout.weight(.semibold))
                .foregroundStyle(isValid ? Color.primary : tint)
                Spacer(minLength: 8)
                Text(LaunchDiagnostics.redactHome(UserProfileOverlayManager.defaultOverlayURL().path))
                    .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if !errors.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(errors.enumerated()), id: \.offset) { _, error in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•").foregroundStyle(tint)
                            Text(error).font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint.opacity(0.28)))
    }

    // MARK: Form Sections

    private var identitySection: some View {
        GroupBox {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Profile ID").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    HStack(spacing: 8) {
                        TextField("lowercase-kebab-case", text: $profileID)
                            .textFieldStyle(.roundedBorder).font(.body.monospaced())
                        Button("Auto-Slug") {
                            let seed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                            profileID = UserProfileOverlayManager.slugify(seed.isEmpty ? liveEntry.title : seed)
                        }
                        .controlSize(.small)
                        .help("Generate a deterministic lowercase kebab-case slug from the title")
                    }
                }
                GridRow {
                    Text("Title").foregroundStyle(.secondary)
                    TextField("Display title (e.g. Hades)", text: $title).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Game Engine").foregroundStyle(.secondary)
                    TextField("Optional (e.g. Unreal Engine 5, Unity, RE Engine)", text: $gameEngine)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Match Exe Names").foregroundStyle(.secondary)
                    TextField("Comma-separated .exe names (e.g. Hades.exe)", text: $matchExeNamesText)
                        .textFieldStyle(.roundedBorder).font(.body.monospaced())
                }
                GridRow {
                    Text("Steam App IDs").foregroundStyle(.secondary)
                    TextField("Comma-separated numeric IDs (e.g. 1145360)", text: $steamAppIdsText)
                        .textFieldStyle(.roundedBorder).font(.body.monospaced())
                }
                GridRow {
                    Text("Stores").foregroundStyle(.secondary)
                    HStack(spacing: 18) {
                        Toggle("Steam", isOn: $storeSteam)
                        Toggle("GOG", isOn: $storeGOG)
                        Toggle("Epic", isOn: $storeEpic)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
        } label: {
            Label("Identity & Matching", systemImage: "tag").font(.headline)
        }
    }

    private var tuningSection: some View {
        GroupBox {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Perf Profile").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Picker("Performance Profile", selection: $perfProfile) {
                        ForEach(PerfProfile.allCases, id: \.self) { p in
                            Text(ProfileEditorFormat.perfLabel(p)).tag(p)
                        }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 240)
                }
                GridRow {
                    Text("DX9 Backend").foregroundStyle(.secondary)
                    Picker("DX9 Backend", selection: $dx9Backend) {
                        ForEach(DX9Backend.allCases, id: \.self) { b in
                            Text(ProfileEditorFormat.dx9Label(b)).tag(b)
                        }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 300)
                }
                GridRow {
                    Text("MetalFX").foregroundStyle(.secondary)
                    Picker("MetalFX Upscaling", selection: $upscaleMode) {
                        ForEach(LauncherStyle.metalFXOptions, id: \.tag) { opt in
                            Text(opt.label).tag(opt.tag)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(maxWidth: 220)
                }
                GridRow {
                    Text("Options").foregroundStyle(.secondary)
                    HStack(spacing: 18) {
                        Toggle("Retina PPI", isOn: $retinaMode).help("Native Retina resolution with 192 DPI LogPixels")
                        Toggle("Metal HUD", isOn: $enableHUD).help("Show the Metal / DXVK performance HUD")
                        Toggle("Seatbelt Sandbox", isOn: $enableSandbox).help("Run inside a macOS Seatbelt sandbox profile")
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
        } label: {
            Label("Tuning Settings", systemImage: "slider.horizontal.3").font(.headline)
        }
    }

    private var honestVerificationSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(verificationToggleLabel, isOn: $markVerifiedPlayable).toggleStyle(.checkbox)
                HStack(spacing: 6) {
                    Image(systemName: markVerifiedPlayable ? "checkmark.seal.fill" : "sparkles")
                        .foregroundStyle(markVerifiedPlayable ? Color.green : Color.orange).font(.caption)
                    Text(
                        markVerifiedPlayable
                            ? "status: \"playable\" · verifiedOn: [\"\(hardwareVerifiedLabel)\"]"
                            : "status: \"preset\" · verifiedOn: [\"preset\"]"
                    )
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
        } label: {
            Label("Honest Verification", systemImage: "checkmark.shield").font(.headline)
        }
    }

    private var notesSection: some View {
        let trimmedCount = notes.trimmingCharacters(in: .whitespacesAndNewlines).count
        let meetsMinimum = trimmedCount >= UserProfileOverlayManager.minimumNotesLength
        return GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: $notes)
                    .font(.callout).frame(minHeight: 76, maxHeight: 110)
                    .scrollContentBackground(.hidden).padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.secondary.opacity(0.24)))
                HStack {
                    Text("Describe APIs, observed frame pacing, DRM caveats, or why these settings were chosen.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text("\(trimmedCount) chars (min \(UserProfileOverlayManager.minimumNotesLength))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(meetsMinimum ? Color.secondary : Color.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
        } label: {
            Label("Notes", systemImage: "note.text").font(.headline)
        }
    }

    // MARK: Actions & Initialization

    private func initializeForm() {
        let sourceEntry = liveEntry
        let presetDraft = UserProfileOverlayManager.draftProfile(
            from: sourceEntry, hardware: vm.gpuInfo, markVerifiedOnCurrentHardware: false
        )
        let verifiedDraft = UserProfileOverlayManager.draftProfile(
            from: sourceEntry, hardware: vm.gpuInfo, markVerifiedOnCurrentHardware: true
        )
        autoPresetNotes = presetDraft.notes ?? ""
        autoVerifiedNotes = verifiedDraft.notes ?? ""

        var existingMatch: GameProfile?
        do {
            let document = try UserProfileOverlayManager.loadOverlay()
            existingOverlayIDs = Set(document.profiles.map(\.id))
            existingMatch = findExistingOverride(in: document.profiles, for: sourceEntry, draftID: presetDraft.id)
        } catch {
            existingOverlayIDs = []
            statusBanner = ProfileEditorBanner(isError: true, message: "Could not read local overlay: \(error.localizedDescription)")
        }

        let seed = existingMatch ?? presetDraft
        profileID = seed.id
        title = seed.title
        gameEngine = seed.gameEngine ?? ""
        matchExeNamesText = seed.matchExeNames.joined(separator: ", ")
        steamAppIdsText = seed.steamAppIds.joined(separator: ", ")

        let storeSet = Set(seed.stores.map { $0.lowercased() })
        storeSteam = storeSet.contains("steam")
        storeGOG = storeSet.contains("gog")
        storeEpic = storeSet.contains("epic")

        perfProfile = seed.perfProfile ?? sourceEntry.perfProfile
        dx9Backend = seed.dx9Backend ?? sourceEntry.dx9Backend
        upscaleMode = seed.upscaleMode.flatMap { GameProfile.upscaleModes.contains($0) ? $0 : nil } ?? "off"
        retinaMode = seed.retinaMode ?? sourceEntry.retinaMode
        enableHUD = seed.enableHUD ?? sourceEntry.enableHUD
        enableSandbox = seed.enableSandbox ?? sourceEntry.enableSandbox

        markVerifiedPlayable = seed.isVerified && seed.status?.lowercased() == "playable"
        notes = seed.notes ?? autoPresetNotes

        extraMatchTitles = seed.matchTitles.filter { $0.caseInsensitiveCompare(seed.title) != .orderedSame }
        preservedGogGameIds = seed.gogGameIds
        preservedEpicAppNames = seed.epicAppNames
    }

    private func findExistingOverride(in profiles: [GameProfile], for entry: GameLibraryEntry, draftID: String) -> GameProfile? {
        if let pid = entry.profileID?.trimmingCharacters(in: .whitespacesAndNewlines), !pid.isEmpty,
           let match = profiles.first(where: { $0.id == pid }) { return match }
        if let match = profiles.first(where: { $0.id == draftID }) { return match }
        if let steamID = entry.steamAppID?.trimmingCharacters(in: .whitespacesAndNewlines), !steamID.isEmpty,
           let match = profiles.first(where: { $0.steamAppIds.contains(steamID) }) { return match }
        let exeName = URL(fileURLWithPath: entry.exePath).lastPathComponent
        if !exeName.isEmpty,
           let match = profiles.first(where: { $0.matchExeNames.contains { $0.caseInsensitiveCompare(exeName) == .orderedSame } }) {
            return match
        }
        return nil
    }

    private func syncAutoNotesForVerificationToggle(isVerified: Bool) {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if isVerified && trimmed == autoPresetNotes && !autoVerifiedNotes.isEmpty {
            notes = autoVerifiedNotes
        } else if !isVerified && trimmed == autoVerifiedNotes && !autoPresetNotes.isEmpty {
            notes = autoPresetNotes
        }
    }

    private func saveLocalOverlay(_ draft: GameProfile) {
        do {
            let document = try UserProfileOverlayManager.upsert(draft)
            existingOverlayIDs = Set(document.profiles.map(\.id))
            let message = "Saved custom profile '\(draft.id)' to local user overlay."
            withAnimation(.snappy(duration: 0.2)) { statusBanner = ProfileEditorBanner(isError: false, message: message) }
            vm.statusMessage = message
        } catch {
            withAnimation(.snappy(duration: 0.2)) { statusBanner = ProfileEditorBanner(isError: true, message: error.localizedDescription) }
        }
    }

    private func removeOverride() {
        let idToRemove = trimmedProfileID
        guard !idToRemove.isEmpty else { return }
        do {
            let document = try UserProfileOverlayManager.remove(id: idToRemove)
            existingOverlayIDs = Set(document.profiles.map(\.id))
            let message = "Removed custom profile override '\(idToRemove)' from local overlay."
            withAnimation(.snappy(duration: 0.2)) { statusBanner = ProfileEditorBanner(isError: false, message: message) }
            vm.statusMessage = message
        } catch {
            withAnimation(.snappy(duration: 0.2)) { statusBanner = ProfileEditorBanner(isError: true, message: error.localizedDescription) }
        }
    }

    private func copyPRJSON(_ draft: GameProfile) {
        do {
            let snippet = try UserProfileOverlayManager.exportPRSnippet(draft)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(snippet, forType: .string)

            copyGeneration &+= 1
            let token = copyGeneration
            withAnimation(.snappy(duration: 0.2)) { copiedPRJSON = true }
            vm.statusMessage = "Copied PR JSON snippet for '\(draft.id)' to clipboard."
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if copyGeneration == token {
                    withAnimation(.snappy(duration: 0.2)) { copiedPRJSON = false }
                }
            }
        } catch {
            withAnimation(.snappy(duration: 0.2)) { statusBanner = ProfileEditorBanner(isError: true, message: error.localizedDescription) }
        }
    }
}
