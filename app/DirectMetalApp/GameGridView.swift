import AppKit
import SwiftUI

// Native macOS 15 SwiftUI poster gallery / grid view for the DirectMetal game library.
// Reuses LauncherComponents (GameArtworkView, StorePill, BadgeView, ArchPill, LauncherStyle)
// so cards match the sidebar and detail view seamlessly.

// MARK: - Poster gallery grid

struct GamePosterGridView: View {
    @ObservedObject var vm: DirectMetalViewModel
    let onSelect: (GameLibraryEntry) -> Void

    private static let gridColumns: [GridItem] = [
        GridItem(.adaptive(minimum: 210, maximum: 260), spacing: 14),
    ]

    init(vm: DirectMetalViewModel, onSelect: @escaping (GameLibraryEntry) -> Void = { _ in }) {
        self.vm = vm
        self.onSelect = onSelect
    }

    private var hasActiveFilters: Bool {
        vm.libraryFilter != .all || !vm.searchText.isEmpty
    }

    private var filteredEmptyMessage: String {
        let query = vm.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = vm.libraryFilter == .all ? "" : " in \(vm.libraryFilter.rawValue)"
        if query.isEmpty {
            return "No \(vm.libraryFilter.rawValue) games in your library"
        }
        return "No matches for “\(query)”\(scope)"
    }

    var body: some View {
        let entries = vm.filteredLibrary
        Group {
            if entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: Self.gridColumns, spacing: 14) {
                        ForEach(entries) { entry in
                            GamePosterCard(vm: vm, entry: entry, onSelect: onSelect)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            if vm.library.isEmpty {
                if vm.isScanning {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Scanning your library…")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No Games Yet")
                        .font(.title3.weight(.semibold))
                    Text("Scan your prefixes and Steam libraries, or drop a Windows .exe anywhere on the window.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    HStack(spacing: 10) {
                        Button {
                            vm.scanLibrary()
                        } label: {
                            Label("Scan Library", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(vm.isScanning)

                        Button {
                            vm.openAddPanel()
                        } label: {
                            Label("Add .exe…", systemImage: "plus")
                        }
                        .controlSize(.regular)
                    }
                    .padding(.top, 4)
                }
            } else {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(filteredEmptyMessage)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if hasActiveFilters {
                    Button {
                        vm.clearFilters()
                    } label: {
                        Label("Clear Filters", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .padding(.top, 2)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Poster card

struct GamePosterCard: View {
    @ObservedObject var vm: DirectMetalViewModel
    let entry: GameLibraryEntry
    let onSelect: (GameLibraryEntry) -> Void

    @State private var isHovering = false

    private static let cardCornerRadius: CGFloat = 12

    private var isSelected: Bool {
        vm.selectedID == entry.id
    }

    private var isRunning: Bool {
        vm.runningGameID == entry.id
    }

    private var playDisabled: Bool {
        vm.isRunning || vm.runtimePaths == nil
    }

    private var playHelpText: String {
        if vm.runtimePaths == nil {
            return "Runtime not installed"
        }
        if isRunning {
            return "\(entry.title) is currently running"
        }
        if vm.isRunning {
            return "Another game is currently running"
        }
        return "Play \(entry.title)"
    }

    private var metadataHelpText: String {
        var parts: [String] = []
        if let playtime = LauncherStyle.playtimeText(entry.totalPlaySeconds) {
            parts.append(playtime)
        }
        parts.append(LauncherStyle.lastPlayedText(entry.lastPlayedUtc))
        if entry.playCount > 0 {
            parts.append("\(entry.playCount) play\(entry.playCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
        let badges = LauncherStyle.apiBadges(for: entry)

        VStack(alignment: .leading, spacing: 0) {
            PosterArtworkHeader(
                entry: entry,
                isHovering: isHovering,
                isRunning: isRunning,
                playDisabled: playDisabled,
                playHelp: playHelpText,
                onPlay: { vm.play(entry) }
            )

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(entry.title)
                    Spacer(minLength: 2)
                    if entry.isFavorite || isHovering {
                        Button {
                            vm.toggleFavorite(entry)
                        } label: {
                            Image(systemName: entry.isFavorite ? "star.fill" : "star")
                                .font(.system(size: 12))
                                .foregroundStyle(entry.isFavorite ? Color.yellow : Color.secondary.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                        .help(entry.isFavorite ? "Remove from Favorites" : "Pin to Favorites")
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        StorePill(source: entry.storeSource, gameID: entry.storeGameID)
                            .fixedSize()
                        ForEach(badges) { badge in
                            BadgeView(badge: badge)
                                .fixedSize()
                        }
                        ArchPill(architecture: entry.architecture)
                            .fixedSize()
                    }
                }
                .frame(height: 18, alignment: .leading)

                HStack(spacing: 6) {
                    if let playtime = LauncherStyle.playtimeText(entry.totalPlaySeconds) {
                        Label(playtime, systemImage: "timer")
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        Label(LauncherStyle.lastPlayedText(entry.lastPlayedUtc), systemImage: "clock")
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                    if entry.playCount > 0 {
                        Text("\(entry.playCount) play\(entry.playCount == 1 ? "" : "s")")
                            .lineLimit(1)
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help(metadataHelpText)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay {
            if isSelected {
                shape.fill(Color.accentColor.opacity(0.05))
                    .allowsHitTesting(false)
            }
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(
                isSelected
                    ? Color.accentColor
                    : (isHovering ? Color.primary.opacity(0.24) : Color.secondary.opacity(0.18)),
                lineWidth: isSelected ? 2 : 1
            )
            .allowsHitTesting(false)
        }
        .shadow(
            color: isSelected
                ? Color.accentColor.opacity(0.22)
                : Color.black.opacity(isHovering ? 0.18 : 0.08),
            radius: (isHovering || isSelected) ? 9 : 4,
            y: isHovering ? 4 : 2
        )
        .scaleEffect(isHovering ? 1.015 : 1.0)
        .animation(.snappy(duration: 0.18), value: isHovering)
        .animation(.snappy(duration: 0.18), value: isSelected)
        .contentShape(shape)
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture(count: 2) {
            vm.selectedID = entry.id
            onSelect(entry)
        }
        .onTapGesture(count: 1) {
            vm.selectedID = entry.id
        }
        .contextMenu {
            Button {
                vm.play(entry)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .disabled(playDisabled)

            Button {
                vm.selectedID = entry.id
                onSelect(entry)
            } label: {
                Label("Configure…", systemImage: "slider.horizontal.3")
            }

            Button {
                vm.toggleFavorite(entry)
            } label: {
                Label(
                    entry.isFavorite ? "Remove from Favorites" : "Pin to Favorites",
                    systemImage: entry.isFavorite ? "star.slash" : "star.fill"
                )
            }

            Divider()

            Button {
                vm.createGameShortcut(entry)
            } label: {
                Label("Create Shortcut", systemImage: "arrow.up.forward.app")
            }

            Button {
                vm.revealInFinder(entry)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }

            Button {
                vm.reinspect(entry)
            } label: {
                Label("Re-inspect PE", systemImage: "doc.viewfinder")
            }

            Divider()

            Button(role: .destructive) {
                vm.selectedID = entry.id
                vm.showRemoveConfirm = true
            } label: {
                Label("Remove from Library…", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - 16:9 poster artwork header

private struct PosterArtworkHeader: View {
    let entry: GameLibraryEntry
    let isHovering: Bool
    let isRunning: Bool
    let playDisabled: Bool
    let playHelp: String
    let onPlay: () -> Void

    @State private var bannerImage: NSImage?

    init(
        entry: GameLibraryEntry,
        isHovering: Bool,
        isRunning: Bool,
        playDisabled: Bool,
        playHelp: String,
        onPlay: @escaping () -> Void
    ) {
        self.entry = entry
        self.isHovering = isHovering
        self.isRunning = isRunning
        self.playDisabled = playDisabled
        self.playHelp = playHelp
        self.onPlay = onPlay
        _bannerImage = State(initialValue: GameArtworkManager.shared.cachedArtwork(for: entry, style: .banner))
    }

    private var loadKey: String {
        GameArtworkManager.artworkKey(entry, .banner)
    }

    private var hasWideBanner: Bool {
        guard let img = bannerImage else { return false }
        return img.size.width > img.size.height * 1.3
    }

    var body: some View {
        let accent = LauncherStyle.accent(for: entry.title)

        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .background {
                LinearGradient(
                    colors: [accent.opacity(0.38), accent.opacity(0.14)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .overlay {
                if let img = bannerImage, hasWideBanner {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        RadialGradient(
                            colors: [accent.opacity(0.28), .clear],
                            center: .topLeading,
                            startRadius: 8,
                            endRadius: 180
                        )
                        GameArtworkView(entry: entry, style: .banner, size: 62)
                    }
                }
            }
            .overlay {
                LinearGradient(
                    colors: [.clear, .black.opacity(hasWideBanner ? 0.34 : 0.14)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            }
            .overlay {
                if isHovering {
                    ZStack {
                        Color.black.opacity(0.36)
                        Button(action: onPlay) {
                            Label("Play", systemImage: "play.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.regular)
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                        .disabled(playDisabled)
                        .help(playHelp)
                    }
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isRunning {
                    runningPill
                        .padding(8)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .clipped()
            .animation(.easeOut(duration: 0.16), value: isHovering)
            .animation(.easeOut(duration: 0.18), value: isRunning)
            .task(id: loadKey) {
                await loadBanner()
            }
    }

    private var runningPill: some View {
        HStack(spacing: 5) {
            ProgressView()
                .controlSize(.mini)
            Text("Running…")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.green.opacity(0.88), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.24), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.28), radius: 4, y: 1.5)
        .environment(\.colorScheme, .dark)
    }

    private func loadBanner() async {
        let e = entry
        if let cached = GameArtworkManager.shared.cachedArtwork(for: e, style: .banner) {
            bannerImage = cached
            return
        }
        let box = await withCheckedContinuation { (cont: CheckedContinuation<PosterArtworkBox, Never>) in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: PosterArtworkBox(
                    image: GameArtworkManager.shared.loadArtwork(for: e, style: .banner)
                ))
            }
        }
        if !Task.isCancelled {
            bannerImage = box.image
        }
    }
}

private struct PosterArtworkBox: @unchecked Sendable {
    let image: NSImage?
}
