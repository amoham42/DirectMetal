import AppKit
import Foundation
import SwiftUI

// Native macOS 15 SwiftUI Community Game Profiles Browser Sheet.
// Displays bundled and user-overlay community game profiles from GameProfileRegistry,
// supports multi-field search, verification status chips, engine filtering, one-click
// preset application to the selected library entry, and quick access to the custom overlay folder.

// MARK: - Supporting types

private enum ProfileStatusFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case verified = "Hardware Verified"
    case presets = "Presets"

    var id: String { rawValue }

    var tint: Color {
        switch self {
        case .all: return .accentColor
        case .verified: return .green
        case .presets: return .orange
        }
    }

    func matches(_ profile: GameProfile) -> Bool {
        switch self {
        case .all: return true
        case .verified: return profile.isVerified
        case .presets: return !profile.isVerified
        }
    }
}

private enum ProfileDisplayFormat {
    static func perfLabel(_ profile: PerfProfile) -> String {
        switch profile {
        case .balanced: return "Balanced"
        case .ultra: return "Ultra"
        }
    }

    static func perfTint(_ profile: PerfProfile) -> Color {
        switch profile {
        case .balanced: return .blue
        case .ultra: return .purple
        }
    }

    static func dx9Label(_ backend: DX9Backend) -> String? {
        switch backend {
        case .auto: return nil
        case .dxvk: return "DX9: DXVK"
        case .wined3d: return "DX9: WineD3D"
        }
    }

    static func upscaleLabel(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty,
              trimmed != "off" else {
            return nil
        }
        switch trimmed {
        case "quality": return "MetalFX Quality"
        case "balanced": return "MetalFX Balanced"
        case "performance": return "MetalFX Perf"
        case "ultra_performance": return "MetalFX Ultra Perf"
        default: return "MetalFX \(trimmed)"
        }
    }

    static func storeGameID(for store: String, in profile: GameProfile) -> String? {
        switch store.lowercased() {
        case "steam": return profile.steamAppIds.first
        case "gog": return profile.gogGameIds.first
        case "epic": return profile.epicAppNames.first
        default: return nil
        }
    }

    static func verifiedDevices(_ profile: GameProfile) -> String? {
        let devices = profile.verifiedOn.filter { !$0.isEmpty && $0.lowercased() != "preset" }
        guard !devices.isEmpty else { return nil }
        return devices.joined(separator: ", ")
    }
}

// MARK: - Profile Browser Sheet

struct ProfileBrowserSheet: View {
    @ObservedObject var vm: DirectMetalViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var registry: GameProfileRegistry = GameProfileRegistry.shared
    @State private var isLoading: Bool = false
    @State private var loadGeneration: Int = 0
    @State private var searchText: String = ""
    @State private var statusFilter: ProfileStatusFilter = .all
    @State private var selectedEngine: String = ""
    @State private var appliedBannerMessage: String?

    private var profiles: [GameProfile] {
        registry.profiles
    }

    private var verifiedCount: Int {
        profiles.reduce(0) { $0 + ($1.isVerified ? 1 : 0) }
    }

    private var presetCount: Int {
        profiles.count - verifiedCount
    }

    private var availableEngines: [String] {
        let unique = Set(profiles.compactMap { profile -> String? in
            guard let raw = profile.gameEngine?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                return nil
            }
            return raw
        })
        return unique.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var searchAndEngineMatches: [GameProfile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return profiles.filter { profile in
            if !selectedEngine.isEmpty {
                let engine = profile.gameEngine?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard engine == selectedEngine else { return false }
            }
            guard !query.isEmpty else { return true }
            if profile.title.localizedCaseInsensitiveContains(query) { return true }
            if profile.id.localizedCaseInsensitiveContains(query) { return true }
            if let engine = profile.gameEngine, engine.localizedCaseInsensitiveContains(query) { return true }
            if let notes = profile.notes, notes.localizedCaseInsensitiveContains(query) { return true }
            if profile.stores.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
            if profile.matchExeNames.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
            if profile.matchTitles.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
            return false
        }
    }

    private var filteredProfiles: [GameProfile] {
        searchAndEngineMatches.filter(statusFilter.matches)
    }

    private var isFiltering: Bool {
        statusFilter != .all
            || !selectedEngine.isEmpty
            || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func statusCount(_ filter: ProfileStatusFilter) -> Int {
        searchAndEngineMatches.reduce(0) { $0 + (filter.matches($1) ? 1 : 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                summaryHeader
                    .padding(.horizontal, 22)
                    .padding(.top, 14)

                if let banner = appliedBannerMessage {
                    appliedBannerView(banner)
                        .padding(.horizontal, 22)
                }

                searchAndFilterSection
                    .padding(.horizontal, 22)

                contentArea
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footerBar
        }
        .frame(minWidth: 700, idealWidth: 780, minHeight: 500, idealHeight: 580)
        .onAppear {
            reloadRegistry()
        }
    }

    // MARK: Title & footer

    private var titleBar: some View {
        HStack(spacing: 12) {
            Label("Community Game Profiles", systemImage: "books.vertical")
                .font(.title2.bold())
                .lineLimit(1)

            Spacer(minLength: 8)

            if let selected = vm.selectedEntry {
                HStack(spacing: 5) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.caption2)
                    Text("Selected: \(selected.title)")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(Color.secondary.opacity(0.10), in: Capsule())
                .frame(maxWidth: 260, alignment: .trailing)
                .help("Applying a profile updates settings for \(selected.title)")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var footerBar: some View {
        let supportRoot = GameLibraryManager.defaultSupportRoot()
        return HStack(spacing: 10) {
            Button {
                openCustomOverlayFolder()
            } label: {
                Label("Open Custom Overlay Folder", systemImage: "folder")
            }
            .help("Reveal \(LaunchDiagnostics.redactHome(supportRoot.path)) in Finder to add or edit game_profiles.json")

            Text(LaunchDiagnostics.redactHome(supportRoot.path))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer(minLength: 12)

            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    // MARK: Summary header, banner & filters

    private var summaryHeader: some View {
        GroupBox {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(profiles.count) profile\(profiles.count == 1 ? "" : "s")")
                            .font(.title3.bold().monospacedDigit())

                        Text("·")
                            .foregroundStyle(.tertiary)

                        Label("\(verifiedCount) hardware verified", systemImage: "checkmark.seal.fill")
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.green)

                        Text("·")
                            .foregroundStyle(.tertiary)

                        Label("\(presetCount) community preset\(presetCount == 1 ? "" : "s")", systemImage: "sparkles")
                            .font(.callout.weight(.medium).monospacedDigit())
                            .foregroundStyle(.orange)
                    }

                    HStack(spacing: 6) {
                        Text("Source:")
                            .foregroundStyle(.tertiary)
                        Text(LaunchDiagnostics.redactHome(registry.source))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    .font(.caption.monospaced())

                    if let overlay = registry.userOverlay {
                        HStack(spacing: 6) {
                            Text("User overlay:")
                                .foregroundStyle(.tertiary)
                            Text(LaunchDiagnostics.redactHome(overlay))
                                .foregroundStyle(.green)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        .font(.caption.monospaced())
                    }
                }

                Spacer(minLength: 8)

                Button {
                    let report = vm.syncLibraryProfiles(registry: registry, overwriteCustomized: false)
                    if report.appliedCount > 0 {
                        appliedBannerMessage = "Applied \(report.appliedCount) community preset\(report.appliedCount == 1 ? "" : "s") across your library (\(report.skippedCustomizedCount) customized preserved)."
                    } else if report.skippedCustomizedCount > 0 {
                        appliedBannerMessage = "All \(report.alreadyMatchedCount) matched games already synced (\(report.skippedCustomizedCount) customized preserved)."
                    } else {
                        appliedBannerMessage = "No new community presets to apply (\(report.alreadyMatchedCount) already matched, \(report.unmatchedCount) unmatched)."
                    }
                } label: {
                    Label("Sync Library", systemImage: "arrow.triangle.2.circlepath")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(isLoading || vm.library.isEmpty)
                .help("Apply newly matched community profiles across your library without overwriting customized games")

                Button {
                    reloadRegistry()
                } label: {
                    if isLoading {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text("Refreshing…")
                        }
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .controlSize(.small)
                .disabled(isLoading)
                .help("Reload bundled and user-overlay game profiles from disk")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func appliedBannerView(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    appliedBannerMessage = nil
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss status message")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Color.green.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.green.opacity(0.30))
        )
    }

    private var searchAndFilterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                TextField("Search title, ID, engine, notes, storefront, or .exe…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if isFiltering {
                    Text("\(filteredProfiles.count) of \(profiles.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.18))
            )

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(ProfileStatusFilter.allCases) { filter in
                        let count = statusCount(filter)
                        let selected = statusFilter == filter
                        Button {
                            statusFilter = filter
                        } label: {
                            HStack(spacing: 4) {
                                Text(filter.rawValue)
                                    .font(.caption.weight(.semibold))
                                Text("\(count)")
                                    .font(.caption2.weight(.medium).monospacedDigit())
                                    .opacity(selected ? 0.9 : 0.75)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .foregroundStyle(selected ? Color.white : (count == 0 ? Color.secondary : filter.tint))
                            .background(
                                selected ? filter.tint : filter.tint.opacity(count == 0 ? 0.06 : 0.13),
                                in: Capsule()
                            )
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }

                Spacer(minLength: 8)

                if !availableEngines.isEmpty {
                    HStack(spacing: 6) {
                        Text("Engine")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Engine", selection: $selectedEngine) {
                            Text("All Engines").tag("")
                            Divider()
                            ForEach(availableEngines, id: \.self) { engine in
                                Text(engine).tag(engine)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 200)
                        .help("Filter profiles by game engine")
                    }
                }

                if isFiltering {
                    Button("Clear") {
                        clearFilters()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Reset search, status, and engine filters")
                }
            }
        }
    }

    // MARK: Content list

    @ViewBuilder
    private var contentArea: some View {
        if profiles.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 34))
                    .foregroundStyle(.tertiary)
                Text("No Community Profiles Loaded")
                    .font(.headline)
                Text("DirectMetal could not find any valid profiles in the bundled catalog or your custom overlay file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredProfiles.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text("No profiles match the current filter")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if isFiltering {
                    Button("Clear Filters") {
                        clearFilters()
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let selected = vm.selectedEntry
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(filteredProfiles) { profile in
                        ProfileBrowserCard(
                            profile: profile,
                            selectedEntry: selected,
                            isActiveOnSelected: selected?.profileID == profile.id,
                            onApply: {
                                guard let target = vm.selectedEntry else { return }
                                apply(profile, to: target)
                            }
                        )
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: Actions

    private func reloadRegistry() {
        loadGeneration &+= 1
        let gen = loadGeneration
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = GameProfileRegistry.load()
            DispatchQueue.main.async {
                guard gen == self.loadGeneration else { return }
                self.registry = loaded
                if !self.selectedEngine.isEmpty && !self.availableEngines.contains(self.selectedEngine) {
                    self.selectedEngine = ""
                }
                self.isLoading = false
            }
        }
    }

    private func apply(_ profile: GameProfile, to entry: GameLibraryEntry) {
        vm.update(entry.id) { $0.apply(gameProfile: profile) }
        let message = "Applied \(profile.title) preset to \(entry.title)."
        vm.statusMessage = message
        withAnimation(.snappy(duration: 0.2)) {
            appliedBannerMessage = message
        }
    }

    private func clearFilters() {
        searchText = ""
        statusFilter = .all
        selectedEngine = ""
    }

    private func openCustomOverlayFolder() {
        let supportRoot = GameLibraryManager.defaultSupportRoot()
        let fm = FileManager.default
        try? fm.createDirectory(at: supportRoot, withIntermediateDirectories: true)
        let overlayFile = supportRoot.appendingPathComponent(GameProfileRegistry.fileName)
        if fm.fileExists(atPath: overlayFile.path) {
            NSWorkspace.shared.activateFileViewerSelecting([overlayFile])
        } else {
            NSWorkspace.shared.open(supportRoot)
        }
    }
}

// MARK: - Profile card subview

private struct ProfileBrowserCard: View {
    let profile: GameProfile
    let selectedEntry: GameLibraryEntry?
    let isActiveOnSelected: Bool
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            settingsChipsRow
            if let notes = profile.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                Text(notes)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            metadataRow
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isActiveOnSelected ? Color.accentColor.opacity(0.06) : Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isActiveOnSelected ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.16),
                    lineWidth: 1
                )
        )
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .center, spacing: 7) {
                    Text(profile.title)
                        .font(.headline)
                        .lineLimit(1)

                    if profile.isVerified {
                        Label("Verified", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .foregroundStyle(.green)
                            .background(Color.green.opacity(0.14), in: Capsule())
                            .help(profile.verificationLabel)
                    } else {
                        Label("Preset", systemImage: "sparkles")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .foregroundStyle(.orange)
                            .background(Color.orange.opacity(0.14), in: Capsule())
                            .help(profile.verificationLabel)
                    }

                    if isActiveOnSelected {
                        Text("Active")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .foregroundStyle(Color.accentColor)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                            .help("Currently applied to \(selectedEntry?.title ?? "selected game")")
                    }
                }

                HStack(spacing: 6) {
                    if let engine = profile.gameEngine?.trimmingCharacters(in: .whitespacesAndNewlines), !engine.isEmpty {
                        Text(engine)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .foregroundStyle(.indigo)
                            .background(Color.indigo.opacity(0.13), in: Capsule())
                    }

                    ForEach(profile.stores, id: \.self) { store in
                        StorePill(
                            source: store,
                            gameID: ProfileDisplayFormat.storeGameID(for: store, in: profile)
                        )
                    }

                    if profile.status?.lowercased() == "needs-steam-login" {
                        Label("Steam Login", systemImage: "person.badge.key")
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .foregroundStyle(.orange)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                }
            }

            Spacer(minLength: 8)

            if let selected = selectedEntry {
                Button(action: onApply) {
                    Label {
                        Text("Apply to \(selected.title)")
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } icon: {
                        Image(systemName: isActiveOnSelected ? "arrow.clockwise.circle" : "wand.and.stars")
                    }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: 230, alignment: .trailing)
                .help("Apply \(profile.title) settings to \(selected.title)")
            }
        }
    }

    private var settingsChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let perf = profile.perfProfile {
                    ProfileSettingChip(
                        icon: perf == .ultra ? "bolt.fill" : "gauge.medium",
                        text: ProfileDisplayFormat.perfLabel(perf),
                        tint: ProfileDisplayFormat.perfTint(perf)
                    )
                }

                if let dx9 = profile.dx9Backend, let dx9Text = ProfileDisplayFormat.dx9Label(dx9) {
                    ProfileSettingChip(
                        icon: "cpu",
                        text: dx9Text,
                        tint: .orange
                    )
                }

                if let upscaleText = ProfileDisplayFormat.upscaleLabel(profile.upscaleMode) {
                    ProfileSettingChip(
                        icon: "sparkles.rectangle.stack",
                        text: upscaleText,
                        tint: .teal
                    )
                }

                if profile.retinaMode == true {
                    ProfileSettingChip(
                        icon: "display",
                        text: "Retina",
                        tint: .blue
                    )
                }

                if profile.enableSandbox == true {
                    ProfileSettingChip(
                        icon: "lock.shield.fill",
                        text: "Sandbox",
                        tint: .green
                    )
                }

                if profile.enableHUD == true {
                    ProfileSettingChip(
                        icon: "chart.bar.xaxis",
                        text: "Metal HUD",
                        tint: .secondary
                    )
                }
            }
            .padding(.vertical, 1)
        }
    }

    private var metadataRow: some View {
        HStack(spacing: 10) {
            Text(profile.id)
                .textSelection(.enabled)

            if let devices = ProfileDisplayFormat.verifiedDevices(profile) {
                Text("·")
                Label(devices, systemImage: "desktopcomputer")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if !profile.matchExeNames.isEmpty {
                Text("·")
                Label(profile.matchExeNames.joined(separator: ", "), systemImage: "terminal")
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.tertiary)
    }
}

private struct ProfileSettingChip: View {
    let icon: String
    let text: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .foregroundStyle(tint)
            .background(tint.opacity(0.11), in: Capsule())
    }
}
