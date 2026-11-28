import Foundation
import SwiftUI

// Quick-Launch Command Palette (⌘K): Spotlight-style fuzzy search across the game library
// and launcher quick actions, with full keyboard navigation and instant game launch (⌘↩).

// MARK: - Fuzzy / substring matcher (pure, unit-testable)

/// Pure fuzzy and substring ranker used by `CommandPaletteSheet`.
///
/// Score tiers (for non-empty queries, higher is better):
/// - Exact match: `1000`
/// - Prefix match: `800...900`
/// - Word-boundary substring match: `600...750`
/// - Mid-word substring match: `400...550`
/// - Subsequence (fuzzy) match: `1...350`
/// - Empty query: `0`
/// - Non-match: `nil`
enum CommandPaletteMatcher {
    static func score(query: String, text: String) -> Int? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        guard !text.isEmpty else { return nil }

        let collapsedQuery = trimmed
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        let normQuery = normalize(collapsedQuery)
        let normText = normalize(text)
        guard !normQuery.isEmpty, !normText.isEmpty else { return nil }

        if normText == normQuery {
            return 1000
        }

        let qChars = Array(normQuery)
        let tChars = Array(normText)
        let origChars = Array(text)
        let useOriginalForCamelCase = origChars.count == tChars.count

        // Prefix match (800...900): shorter targets rank higher.
        if qChars.count <= tChars.count && normText.hasPrefix(normQuery) {
            let lengthBonus = max(0, 100 - (tChars.count - qChars.count))
            return 800 + lengthBonus
        }

        // Contiguous substring scan: prefer the earliest word-boundary occurrence over mid-word.
        if qChars.count <= tChars.count {
            var earliestBoundary: Int?
            var earliestAny: Int?
            let maxStart = tChars.count - qChars.count
            for start in 0...maxStart {
                if matchesContiguous(qChars, in: tChars, at: start) {
                    if earliestAny == nil {
                        earliestAny = start
                    }
                    if earliestBoundary == nil && isWordBoundary(at: start, normChars: tChars, origChars: origChars, useOriginal: useOriginalForCamelCase) {
                        earliestBoundary = start
                        break
                    }
                }
            }

            if let idx = earliestBoundary {
                let positionBonus = max(0, 100 - idx)
                let lengthBonus = max(0, 50 - (tChars.count - qChars.count) / 2)
                return 600 + positionBonus + lengthBonus
            }

            if let idx = earliestAny {
                let positionBonus = max(0, 100 - idx)
                let lengthBonus = max(0, 50 - (tChars.count - qChars.count) / 2)
                return 400 + positionBonus + lengthBonus
            }
        }

        // Subsequence match (1...350), first against the query as-is, then ignoring spaces
        // so multi-word queries like "direct metal" match CamelCase targets like "DirectMetal".
        if let sub = subsequenceScore(qChars: qChars, tChars: tChars, origChars: origChars, useOriginal: useOriginalForCamelCase) {
            return sub
        }

        let compactQuery = qChars.filter { !$0.isWhitespace }
        if compactQuery.count < qChars.count, !compactQuery.isEmpty {
            return subsequenceScore(qChars: compactQuery, tChars: tChars, origChars: origChars, useOriginal: useOriginalForCamelCase)
        }

        return nil
    }

    /// Scores a primary title alongside secondary searchable keywords (badges, storefront, exe name).
    /// Keyword-only matches are discounted so title matches always rank above metadata matches.
    static func score(query: String, title: String, keywords: [String]) -> Int? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        var best = score(query: trimmed, text: title)
        for keyword in keywords where !keyword.isEmpty {
            if let kwScore = score(query: trimmed, text: keyword) {
                let discounted = max(1, (kwScore * 6) / 10)
                if best == nil || discounted > best! {
                    best = discounted
                }
            }
        }
        return best
    }

    private static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func matchesContiguous(_ q: [Character], in t: [Character], at start: Int) -> Bool {
        for i in 0..<q.count {
            if t[start + i] != q[i] { return false }
        }
        return true
    }

    private static func isWordBoundary(at index: Int, normChars: [Character], origChars: [Character], useOriginal: Bool) -> Bool {
        if index == 0 { return true }
        let prev = normChars[index - 1]
        let curr = normChars[index]
        if !(prev.isLetter || prev.isNumber) && (curr.isLetter || curr.isNumber) {
            return true
        }
        if useOriginal && origChars[index - 1].isLowercase && origChars[index].isUppercase {
            return true
        }
        return false
    }

    private static func subsequenceScore(qChars: [Character], tChars: [Character], origChars: [Character], useOriginal: Bool) -> Int? {
        guard !qChars.isEmpty, qChars.count <= tChars.count else { return nil }

        // Backward pass computes the latest valid match index for each query character so
        // the forward pass can safely prefer consecutive and word-boundary positions.
        var lastPos = Array(repeating: -1, count: qChars.count)
        var tIdx = tChars.count - 1
        for qIdx in stride(from: qChars.count - 1, through: 0, by: -1) {
            let needed = qChars[qIdx]
            while tIdx >= 0 && tChars[tIdx] != needed {
                tIdx -= 1
            }
            guard tIdx >= 0 else { return nil }
            lastPos[qIdx] = tIdx
            tIdx -= 1
        }

        var matched: [Int] = []
        matched.reserveCapacity(qChars.count)
        var prev = -1

        for qIdx in 0..<qChars.count {
            let needed = qChars[qIdx]
            let lower = prev + 1
            let upper = lastPos[qIdx]
            guard lower <= upper else { return nil }

            var chosen: Int?
            // 1. Consecutive character continuation
            if qIdx > 0 && tChars[lower] == needed {
                chosen = lower
            }
            // 2. Word-boundary character match
            if chosen == nil {
                for j in lower...upper where tChars[j] == needed {
                    if isWordBoundary(at: j, normChars: tChars, origChars: origChars, useOriginal: useOriginal) {
                        chosen = j
                        break
                    }
                }
            }
            // 3. Earliest available match
            if chosen == nil {
                for j in lower...upper where tChars[j] == needed {
                    chosen = j
                    break
                }
            }

            guard let picked = chosen else { return nil }
            matched.append(picked)
            prev = picked
        }

        var boundaryHits = 0
        var consecutiveHits = 0
        for (i, pos) in matched.enumerated() {
            if isWordBoundary(at: pos, normChars: tChars, origChars: origChars, useOriginal: useOriginal) {
                boundaryHits += 1
            }
            if i > 0 && pos == matched[i - 1] + 1 {
                consecutiveHits += 1
            }
        }

        let first = matched.first ?? 0
        let last = matched.last ?? first
        let span = last - first + 1
        let gapPenalty = max(0, span - matched.count)

        let raw = 120 + boundaryHits * 24 + consecutiveHits * 16 - gapPenalty * 3 - first * 2
        return min(350, max(1, raw))
    }
}

// MARK: - Palette item model

private struct PaletteQuickAction: Identifiable {
    enum Kind {
        case scanLibrary
        case addExeOrFolder
        case systemHealth
        case prefixManager
        case launchHistory
        case profileBrowser
        case hudCustomizer
        case controllers
        case checkUpdates
        case posterGallery
        case detailInspector
        case exportBackup
        case importBackup
        case exportSupportBundle
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let shortcutHint: String?
    let keywords: [String]
    /// True when the action presents a modal sheet or NSOpenPanel/NSSavePanel after dismissal.
    let presentsModal: Bool

    static let all: [PaletteQuickAction] = [
        PaletteQuickAction(
            id: "action.scan-library",
            kind: .scanLibrary,
            title: "Scan Game Library",
            subtitle: "Discover games in prefixes, Steam libraries & folders",
            systemImage: "arrow.clockwise",
            tint: .blue,
            shortcutHint: "⌘R",
            keywords: ["scan", "refresh", "rescan", "discover", "steam", "gog", "epic", "library"],
            presentsModal: false
        ),
        PaletteQuickAction(
            id: "action.add-exe",
            kind: .addExeOrFolder,
            title: "Add Windows .exe or Folder…",
            subtitle: "Import a Windows executable or scan a game directory",
            systemImage: "plus.circle",
            tint: .green,
            shortcutHint: "⌘O",
            keywords: ["add", "exe", "folder", "import", "install", "open", "windows", "game"],
            presentsModal: true
        ),
        PaletteQuickAction(
            id: "action.system-health",
            kind: .systemHealth,
            title: "System Health, Cache & Benchmark…",
            subtitle: "Diagnostics, shader cache maintenance & Metal GPU benchmark",
            systemImage: "stethoscope",
            tint: .teal,
            shortcutHint: "⌘D",
            keywords: ["health", "diagnostics", "doctor", "shader", "cache", "benchmark", "gpu", "metal"],
            presentsModal: true
        ),
        PaletteQuickAction(
            id: "action.prefix-manager",
            kind: .prefixManager,
            title: "APFS Prefixes & Storage…",
            subtitle: "Inspect, reset, or delete Copy-on-Write Wine prefixes",
            systemImage: "externaldrive.badge.timemachine",
            tint: .indigo,
            shortcutHint: "⇧⌘P",
            keywords: ["apfs", "prefix", "prefixes", "storage", "wine", "cow", "disk", "reset"],
            presentsModal: true
        ),
        PaletteQuickAction(
            id: "action.controllers",
            kind: .controllers,
            title: "Controller Remapping & Deadzones…",
            subtitle: "Remap buttons, tune stick deadzones, haptics & live input tester",
            systemImage: "gamecontroller",
            tint: .purple,
            shortcutHint: "⌘,",
            keywords: ["controller", "gamepad", "remap", "deadzone", "xbox", "dualsense", "haptics", "input"],
            presentsModal: true
        ),
        PaletteQuickAction(
            id: "action.launch-history",
            kind: .launchHistory,
            title: "Launch History…",
            subtitle: "Review recent game sessions, exit codes, durations & copy reports",
            systemImage: "clock.arrow.circlepath",
            tint: .indigo,
            shortcutHint: "⇧⌘H",
            keywords: ["history", "launches", "log", "sessions", "recent", "exit", "crash"],
            presentsModal: true
        ),
        PaletteQuickAction(
            id: "action.profile-browser",
            kind: .profileBrowser,
            title: "Community Game Profiles…",
            subtitle: "Browse 100+ verified & community presets and apply to the selected game",
            systemImage: "sparkles.rectangle.stack",
            tint: .purple,
            shortcutHint: "⇧⌘B",
            keywords: ["profiles", "presets", "community", "games", "settings", "database", "apply"],
            presentsModal: true
        ),
        PaletteQuickAction(
            id: "action.hud-customizer",
            kind: .hudCustomizer,
            title: "Customize Metal Performance HUD…",
            subtitle: "Configure FPS overlay layout, corner alignment, scale & opacity",
            systemImage: "gauge.with.dots.needle.67percent",
            tint: .green,
            shortcutHint: "⇧⌘M",
            keywords: ["hud", "metal", "fps", "overlay", "graph", "alignment", "scale", "opacity", "telemetry"],
            presentsModal: true
        ),
        PaletteQuickAction(
            id: "action.updates",
            kind: .checkUpdates,
            title: "Check for Updates…",
            subtitle: "Check DirectMetal app & MetalSharp-Wine runtime releases",
            systemImage: "arrow.down.circle",
            tint: .orange,
            shortcutHint: "⌘U",
            keywords: ["update", "updates", "upgrade", "release", "runtime", "version", "github"],
            presentsModal: true
        ),
        PaletteQuickAction(
            id: "action.poster-gallery",
            kind: .posterGallery,
            title: "Switch to Poster Gallery",
            subtitle: "Browse your game library in the visual poster grid",
            systemImage: "square.grid.2x2",
            tint: .pink,
            shortcutHint: "⌘2",
            keywords: ["gallery", "poster", "grid", "covers", "artwork", "view"],
            presentsModal: false
        ),
        PaletteQuickAction(
            id: "action.detail-inspector",
            kind: .detailInspector,
            title: "Switch to Detail Inspector",
            subtitle: "Inspect per-game settings, engine options & launch diagnostics",
            systemImage: "sidebar.left",
            tint: .cyan,
            shortcutHint: "⌘1",
            keywords: ["detail", "inspector", "sidebar", "settings", "list", "view"],
            presentsModal: false
        ),
        PaletteQuickAction(
            id: "action.export-backup",
            kind: .exportBackup,
            title: "Export Library Backup…",
            subtitle: "Save a portable JSON snapshot of games & controller profiles",
            systemImage: "square.and.arrow.up",
            tint: .mint,
            shortcutHint: nil,
            keywords: ["export", "backup", "json", "save", "snapshot", "settings"],
            presentsModal: true
        ),
        PaletteQuickAction(
            id: "action.import-backup",
            kind: .importBackup,
            title: "Import Library Backup…",
            subtitle: "Restore games & controller profiles from a JSON backup",
            systemImage: "square.and.arrow.down",
            tint: .mint,
            shortcutHint: nil,
            keywords: ["import", "backup", "restore", "json", "load", "settings"],
            presentsModal: true
        ),
        PaletteQuickAction(
            id: "action.support-bundle",
            kind: .exportSupportBundle,
            title: "Export Diagnostics Support Bundle…",
            subtitle: "Create a privacy-redacted .tar.gz archive for GitHub bug reports",
            systemImage: "doc.zipper",
            tint: .teal,
            shortcutHint: nil,
            keywords: ["support", "bundle", "diagnostics", "bug", "report", "logs", "export", "redact"],
            presentsModal: true
        ),
    ]
}

private enum PaletteItem: Identifiable {
    case game(GameLibraryEntry)
    case action(PaletteQuickAction)

    var id: String {
        switch self {
        case .game(let entry): return "game.\(entry.id)"
        case .action(let action): return action.id
        }
    }

    var isGame: Bool {
        if case .game = self { return true }
        return false
    }
}

private struct ScoredPaletteItem: Identifiable {
    let item: PaletteItem
    let score: Int
    let order: Int

    var id: String { item.id }
}

// MARK: - Command palette sheet

struct CommandPaletteSheet: View {
    @ObservedObject var vm: DirectMetalViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var selectedItemID: String?
    @State private var hoveredItemID: String?
    @State private var hasActivated: Bool = false
    @FocusState private var searchFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !trimmedQuery.isEmpty
    }

    private var canLaunchGames: Bool {
        !vm.isRunning && vm.runtimePaths != nil
    }

    /// Games in recent-first order for empty-query browsing.
    private var defaultGameItems: [PaletteItem] {
        LibrarySort.recent.sorted(vm.library).map { .game($0) }
    }

    private var defaultActionItems: [PaletteItem] {
        PaletteQuickAction.all.map { .action($0) }
    }

    /// Unified ranked items shown in the list and traversed by keyboard navigation.
    private var displayedItems: [PaletteItem] {
        guard isSearching else {
            return defaultGameItems + defaultActionItems
        }

        let q = trimmedQuery
        var scored: [ScoredPaletteItem] = []
        var order = 0

        for entry in LibrarySort.recent.sorted(vm.library) {
            var keywords: [String] = []
            if let store = entry.storeSource, !store.isEmpty { keywords.append(store) }
            keywords.append(contentsOf: entry.detectedAPIs)
            keywords.append(contentsOf: LauncherStyle.apiBadges(for: entry).map(\.text))
            keywords.append(entry.architecture)
            let exeName = URL(fileURLWithPath: entry.exePath).lastPathComponent
            if !exeName.isEmpty { keywords.append(exeName) }

            if let s = CommandPaletteMatcher.score(query: q, title: entry.title, keywords: keywords) {
                scored.append(ScoredPaletteItem(item: .game(entry), score: s, order: order))
            }
            order += 1
        }

        for action in PaletteQuickAction.all {
            if let s = CommandPaletteMatcher.score(query: q, title: action.title, keywords: action.keywords) {
                scored.append(ScoredPaletteItem(item: .action(action), score: s, order: order))
            }
            order += 1
        }

        return scored
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                return a.order < b.order
            }
            .map(\.item)
    }

    private var effectiveSelectedID: String? {
        let items = displayedItems
        if let selectedItemID, items.contains(where: { $0.id == selectedItemID }) {
            return selectedItemID
        }
        return items.first?.id
    }

    private var selectedItem: PaletteItem? {
        guard let id = effectiveSelectedID else { return nil }
        return displayedItems.first(where: { $0.id == id })
    }

    var body: some View {
        let items = displayedItems
        let activeID = effectiveSelectedID

        VStack(spacing: 0) {
            searchHeader
            Divider()
            resultsBody(items: items, activeID: activeID)
            Divider()
            footerBar(resultCount: items.count)
        }
        .frame(width: 580, height: 420)
        .background(.regularMaterial)
        .onAppear {
            selectedItemID = items.first?.id
            searchFocused = true
            DispatchQueue.main.async {
                searchFocused = true
            }
        }
        .onChange(of: query) {
            selectedItemID = displayedItems.first?.id
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(keys: [.return]) { press in
            activateSelected(launchIfGame: press.modifiers.contains(.command))
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    // MARK: - Search header

    private var searchHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Jump to game, launch, or run action…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .regular))
                .focused($searchFocused)
                .onSubmit {
                    activateSelected(launchIfGame: false)
                }
                .onKeyPress(.upArrow) {
                    moveSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(keys: [.return]) { press in
                    activateSelected(launchIfGame: press.modifiers.contains(.command))
                    return .handled
                }
                .onKeyPress(.escape) {
                    dismiss()
                    return .handled
                }

            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            } else {
                keycapBadge("⌘K")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    // MARK: - Results list

    @ViewBuilder
    private func resultsBody(items: [PaletteItem], activeID: String?) -> some View {
        if items.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No matches for “\(trimmedQuery)”")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Try a game title, API badge (DX12, DX11, MetalFX), or launcher action.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button("Clear Search") {
                    query = ""
                    searchFocused = true
                }
                .buttonStyle(.link)
                .font(.callout)
                .padding(.top, 2)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if isSearching {
                            sectionHeader("Results (\(items.count))")
                            ForEach(items) { item in
                                rowView(for: item, isSelected: item.id == activeID)
                                    .id(item.id)
                            }
                        } else {
                            let games = defaultGameItems
                            if !games.isEmpty {
                                sectionHeader("Library Games (\(games.count))")
                                ForEach(games) { item in
                                    rowView(for: item, isSelected: item.id == activeID)
                                        .id(item.id)
                                }
                            }
                            sectionHeader("Quick Actions")
                            ForEach(defaultActionItems) { item in
                                rowView(for: item, isSelected: item.id == activeID)
                                    .id(item.id)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .onChange(of: selectedItemID) { _, newID in
                    guard let newID else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(newID)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 3)
    }

    @ViewBuilder
    private func rowView(for item: PaletteItem, isSelected: Bool) -> some View {
        switch item {
        case .game(let entry):
            gameRow(entry: entry, isSelected: isSelected, isHovered: hoveredItemID == item.id)
        case .action(let action):
            actionRow(action: action, isSelected: isSelected, isHovered: hoveredItemID == item.id)
        }
    }

    private func gameRow(entry: GameLibraryEntry, isSelected: Bool, isHovered: Bool) -> some View {
        let isRunningThis = vm.runningGameID == entry.id
        let playable = canLaunchGames

        return HStack(spacing: 10) {
            GameArtworkView(entry: entry, style: .icon, size: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(entry.title)
                        .font(.system(.body, weight: .semibold))
                        .lineLimit(1)
                    StorePill(source: entry.storeSource, gameID: entry.storeGameID)
                    ForEach(LauncherStyle.apiBadges(for: entry).prefix(3)) { badge in
                        BadgeView(badge: badge)
                    }
                }

                HStack(spacing: 5) {
                    if isRunningThis {
                        Text("Running · Inspect")
                            .foregroundStyle(.orange)
                    } else if playable {
                        Text("Inspect · ⌘↩ Play")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(vm.runtimePaths == nil ? "Inspect · Runtime missing" : "Inspect")
                            .foregroundStyle(.secondary)
                    }

                    if entry.lastPlayedUtc != nil {
                        Text("· \(LauncherStyle.lastPlayedText(entry.lastPlayedUtc))")
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
            }

            Spacer(minLength: 8)

            if isRunningThis {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 4)
            } else {
                Button {
                    launchGame(entry)
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!playable)
                .opacity(playable ? 1.0 : 0.4)
                .help(playable ? "Launch \(entry.title) (⌘↩)" : (vm.runtimePaths == nil ? "Runtime not installed" : "Another game is already running"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(rowBackground(isSelected: isSelected, isHovered: isHovered))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            selectGame(entry)
        }
        .onHover { hovering in
            hoveredItemID = hovering ? "game.\(entry.id)" : (hoveredItemID == "game.\(entry.id)" ? nil : hoveredItemID)
        }
    }

    private func actionRow(action: PaletteQuickAction, isSelected: Bool, isHovered: Bool) -> some View {
        let isCurrentView: Bool = {
            switch action.kind {
            case .posterGallery: return vm.showGalleryView
            case .detailInspector: return !vm.showGalleryView
            default: return false
            }
        }()
        let isBusy = action.kind == .scanLibrary && vm.isScanning

        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(action.tint.opacity(0.14))
                    .frame(width: 30, height: 30)
                Image(systemName: action.systemImage)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(action.tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(action.title)
                        .font(.system(.body, weight: .medium))
                        .lineLimit(1)
                    if isCurrentView {
                        Text("Active")
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .foregroundStyle(.secondary)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                    }
                }
                Text(action.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 4)
            } else if let shortcut = action.shortcutHint {
                keycapBadge(shortcut)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(rowBackground(isSelected: isSelected, isHovered: isHovered))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            performAction(action)
        }
        .onHover { hovering in
            hoveredItemID = hovering ? action.id : (hoveredItemID == action.id ? nil : hoveredItemID)
        }
    }

    @ViewBuilder
    private func rowBackground(isSelected: Bool, isHovered: Bool) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
                )
        } else if isHovered {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        } else {
            Color.clear
        }
    }

    private func keycapBadge(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 0.5)
            )
    }

    // MARK: - Footer bar

    private func footerBar(resultCount: Int) -> some View {
        HStack(spacing: 10) {
            Text("↑↓ Navigate · ↩ Open · Esc Close")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if selectedItem?.isGame == true && canLaunchGames {
                Text("⌘↩ Play")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Text("\(resultCount) item\(resultCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Navigation & execution

    private func moveSelection(by delta: Int) {
        let items = displayedItems
        guard !items.isEmpty else {
            selectedItemID = nil
            return
        }
        let currentIndex = effectiveSelectedID.flatMap { id in
            items.firstIndex(where: { $0.id == id })
        } ?? 0
        let nextIndex = (currentIndex + delta + items.count) % items.count
        selectedItemID = items[nextIndex].id
    }

    private func activateSelected(launchIfGame: Bool) {
        guard let item = selectedItem else { return }
        switch item {
        case .game(let entry):
            if launchIfGame && canLaunchGames {
                launchGame(entry)
            } else {
                selectGame(entry)
            }
        case .action(let action):
            performAction(action)
        }
    }

    private func selectGame(_ entry: GameLibraryEntry) {
        guard !hasActivated else { return }
        hasActivated = true
        vm.selectedID = entry.id
        vm.showGalleryView = false
        dismiss()
    }

    private func launchGame(_ entry: GameLibraryEntry) {
        guard !hasActivated else { return }
        hasActivated = true
        vm.selectedID = entry.id
        vm.showGalleryView = false
        dismiss()
        if canLaunchGames {
            vm.play(entry)
        }
    }

    private func performAction(_ action: PaletteQuickAction) {
        guard !hasActivated else { return }
        hasActivated = true
        dismiss()

        let run: @MainActor () -> Void = {
            switch action.kind {
            case .scanLibrary:
                vm.scanLibrary()
            case .addExeOrFolder:
                vm.openAddPanel()
            case .systemHealth:
                vm.openSystemHealth()
            case .prefixManager:
                vm.openPrefixManager()
            case .launchHistory:
                vm.openLaunchHistory()
            case .profileBrowser:
                vm.openProfileBrowser()
            case .hudCustomizer:
                vm.openHUDCustomizer()
            case .controllers:
                vm.openControllers()
            case .checkUpdates:
                vm.openUpdates()
            case .posterGallery:
                vm.showGalleryView = true
            case .detailInspector:
                vm.showGalleryView = false
            case .exportBackup:
                vm.exportLibraryBackup()
            case .importBackup:
                vm.importLibraryBackup()
            case .exportSupportBundle:
                vm.exportDiagnosticsBundle()
            }
        }

        if action.presentsModal {
            // Defer modal sheets and NSOpenPanel/NSSavePanel slightly so this sheet finishes
            // dismissing and `vm.isPresentingModal` clears before the target sheet presents.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                run()
            }
        } else {
            run()
        }
    }
}
