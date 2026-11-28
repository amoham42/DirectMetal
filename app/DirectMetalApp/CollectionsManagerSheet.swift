import AppKit
import Foundation
import SwiftUI

// Native macOS 15 SwiftUI Game Collections Manager Sheet.
// Manages user-defined collections via GameCollectionsManager (`collections.json`).

private struct CollectionsStatus: Equatable {
    let message: String
    let isError: Bool
}

private let accentColors: [CollectionAccentColor: Color] = [
    .blue: .blue, .purple: .purple, .pink: .pink, .red: .red, .orange: .orange,
    .yellow: .yellow, .green: .green, .teal: .teal, .indigo: .indigo, .gray: .gray,
]

private extension CollectionAccentColor {
    var swiftUIColor: Color { accentColors[self] ?? .blue }
}

private let curatedCollectionSymbols: [String] = [
    "folder.fill", "gamecontroller.fill", "star.fill", "flame.fill", "sparkles",
    "trophy.fill", "bolt.fill", "heart.fill", "bookmark.fill", "flag.fill",
]

struct CollectionsManagerSheet: View {
    @ObservedObject var vm: DirectMetalViewModel
    private let onChanged: (() -> Void)?
    private let manager = GameCollectionsManager()
    @Environment(\.dismiss) private var dismiss

    @State private var document = GameCollectionsDocument()
    @State private var selectedCollectionID: String?
    @State private var gameSearchText = ""
    @State private var status: CollectionsStatus?
    @State private var showNewPopover = false
    @State private var newName = ""
    @State private var newSymbol = GameCollection.defaultSymbolName
    @State private var newAccent: CollectionAccentColor = .blue
    @State private var newFormError: String?
    @State private var renamingCollection: GameCollection?
    @State private var renameDraft = ""
    @State private var deletingCollection: GameCollection?

    init(vm: DirectMetalViewModel, onChanged: (() -> Void)? = nil) {
        self.vm = vm
        self.onChanged = onChanged
    }

    // MARK: Derived state

    private var validGameIDs: Set<String> { Set(vm.library.map(\.id)) }

    private var staleMembershipCount: Int {
        let valid = validGameIDs
        return document.collections.reduce(0) { $0 + $1.gameIDs.filter { !valid.contains($0) }.count }
    }

    private var selectedCollection: GameCollection? {
        selectedCollectionID.flatMap { id in document.collections.first(where: { $0.id == id }) }
    }

    private var filteredLibrary: [GameLibraryEntry] {
        let sorted = vm.library.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        let q = gameSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return sorted }
        return sorted.filter { e in
            e.title.localizedCaseInsensitiveContains(q)
                || e.exePath.localizedCaseInsensitiveContains(q)
                || (e.storeSource?.localizedCaseInsensitiveContains(q) ?? false)
                || e.detectedAPIs.contains(where: { $0.localizedCaseInsensitiveContains(q) })
                || LauncherStyle.apiBadges(for: e).contains(where: { $0.text.localizedCaseInsensitiveContains(q) })
        }
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            if document.collections.isEmpty {
                ContentUnavailableView {
                    Label("No Game Collections Yet", systemImage: "rectangle.stack.badge.plus")
                } description: {
                    Text("Group your Windows games into custom collections like RPGs, Co-op, or Favorites.")
                } actions: {
                    Button { openNewCollectionForm() } label: { Label("Create Your First Collection", systemImage: "plus.circle.fill") }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    collectionsListColumn.frame(width: 240)
                    Divider()
                    membershipEditorColumn.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let status {
                Divider()
                statusBanner(status)
            }
            Divider()
            footerBar
        }
        .frame(minWidth: 720, idealWidth: 800, minHeight: 500, idealHeight: 580)
        .onAppear { reloadCollections() }
        .alert("Rename Collection",
               isPresented: Binding(get: { renamingCollection != nil }, set: { if !$0 { renamingCollection = nil } }),
               presenting: renamingCollection) { target in
            TextField("Collection name", text: $renameDraft)
            Button("Rename") { commitRename(target) }
                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { renamingCollection = nil }
        } message: { target in
            Text("Enter a new display name for “\(target.name)”.")
        }
        .alert("Delete Collection “\(deletingCollection?.name ?? "")”?",
               isPresented: Binding(get: { deletingCollection != nil }, set: { if !$0 { deletingCollection = nil } }),
               presenting: deletingCollection) { target in
            Button("Delete", role: .destructive) { commitDelete(target) }
            Button("Cancel", role: .cancel) { deletingCollection = nil }
        } message: { target in
            let n = target.gameIDs.count
            Text("Removes the collection and its \(n) game tag\(n == 1 ? "" : "s"). Games and prefixes stay untouched.")
        }
    }

    // MARK: Header & New Collection popover

    private var headerBar: some View {
        HStack(spacing: 10) {
            Label("Game Collections", systemImage: "rectangle.stack.fill")
                .font(.title2.bold())
                .lineLimit(1)

            Text("\(document.collections.count) collection\(document.collections.count == 1 ? "" : "s")")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9).padding(.vertical, 3.5)
                .background(Color.secondary.opacity(0.11), in: Capsule())

            Spacer(minLength: 8)

            if staleMembershipCount > 0 {
                Button { pruneStaleMemberships() } label: {
                    Label("Prune Stale (\(staleMembershipCount))", systemImage: "sparkles.rectangle.stack")
                }
                .controlSize(.small).tint(.orange)
                .help("Remove \(staleMembershipCount) stale game ID\(staleMembershipCount == 1 ? "" : "s") not in your library")
            }

            Button { openNewCollectionForm() } label: {
                Label("New Collection", systemImage: "plus")
            }
            .controlSize(.small).buttonStyle(.borderedProminent)
            .popover(isPresented: $showNewPopover, arrowEdge: .bottom) { newCollectionPopover }
        }
        .padding(.horizontal, 22).padding(.vertical, 15)
    }

    private var newCollectionPopover: some View {
        let iconCols = Array(repeating: GridItem(.fixed(32), spacing: 6), count: 5)
        let colorCols = Array(repeating: GridItem(.fixed(24), spacing: 8), count: 5)
        let tint = newAccent.swiftUIColor

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: newSymbol)
                    .font(.headline).foregroundStyle(tint).frame(width: 24, height: 24)
                    .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text("New Collection").font(.headline)
            }
            TextField("Collection name (e.g. RPGs, Co-op…)", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { createNewCollection() }

            Text("Icon").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            LazyVGrid(columns: iconCols, spacing: 6) {
                ForEach(curatedCollectionSymbols, id: \.self) { symbol in
                    let active = newSymbol == symbol
                    Button { newSymbol = symbol } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(active ? tint : .secondary)
                            .frame(width: 30, height: 28)
                            .background(active ? tint.opacity(0.18) : Color.secondary.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(active ? tint.opacity(0.65) : .clear, lineWidth: 1.2))
                    }
                    .buttonStyle(.plain).help(symbol)
                }
            }

            Text("Accent Color").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            LazyVGrid(columns: colorCols, spacing: 8) {
                ForEach(CollectionAccentColor.allCases, id: \.self) { accent in
                    let active = newAccent == accent
                    Button { newAccent = accent } label: {
                        Circle().fill(accent.swiftUIColor).frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(active ? 0.85 : 0), lineWidth: 2).padding(-2))
                            .overlay { if active { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) } }
                    }
                    .buttonStyle(.plain).help(accent.displayName)
                }
            }

            if let newFormError {
                Label(newFormError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") { showNewPopover = false }.controlSize(.small)
                Spacer()
                Button("Create") { createNewCollection() }
                    .controlSize(.small).buttonStyle(.borderedProminent)
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16).frame(width: 248)
    }

    // MARK: Left column — Collections list

    private var collectionsListColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("COLLECTIONS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(document.collections.count)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(document.collections) { col in
                        CollectionRowView(
                            collection: col,
                            isSelected: col.id == selectedCollectionID,
                            staleCount: staleCount(for: col),
                            onSelect: { selectedCollectionID = col.id },
                            onRename: { renameDraft = col.name; renamingCollection = col },
                            onDelete: { deletingCollection = col }
                        )
                    }
                }
                .padding(10)
            }
        }
        .background(Color.secondary.opacity(0.03))
    }

    // MARK: Right column — Membership editor

    @ViewBuilder
    private var membershipEditorColumn: some View {
        if let col = selectedCollection {
            let memberIDs = Set(col.gameIDs)
            let matching = filteredLibrary
            let addableCount = matching.filter { !memberIDs.contains($0.id) }.count
            let staleInCol = staleCount(for: col)
            let tint = col.accentColor.swiftUIColor

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: col.symbolName)
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(tint).frame(width: 28, height: 28)
                        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(col.name).font(.headline).lineLimit(1)
                        HStack(spacing: 6) {
                            Text("\(col.gameIDs.count) of \(vm.library.count) game\(vm.library.count == 1 ? "" : "s")")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            if staleInCol > 0 {
                                Text("· \(staleInCol) stale").font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(.orange)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    if !vm.library.isEmpty {
                        if addableCount > 0 {
                            Button("Select All Matching") { selectAllMatching(matching, in: col) }.controlSize(.small)
                        }
                        if !col.gameIDs.isEmpty {
                            Button("Clear Collection") { clearCollection(col) }.controlSize(.small)
                        }
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                Divider()

                if vm.library.isEmpty {
                    ContentUnavailableView("Your Library Is Empty", systemImage: "gamecontroller",
                                           description: Text("Scan your library or drop a Windows .exe into DirectMetal first, then assign games here."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    gameSearchBar(matchCount: matching.count)
                    if matching.isEmpty {
                        ContentUnavailableView { Label("No Matching Games", systemImage: "magnifyingglass") }
                            description: { Text("No library games match “\(gameSearchText)”.") }
                            actions: { Button("Clear Search") { gameSearchText = "" }.buttonStyle(.link) }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(matching) { entry in
                                    MembershipGameRow(entry: entry, isMember: memberIDs.contains(entry.id),
                                                      accent: tint, onToggle: { toggleMembership(entry, in: col) })
                                }
                            }
                            .padding(.horizontal, 18).padding(.bottom, 14)
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView("Select a Collection", systemImage: "sidebar.left",
                                   description: Text("Choose a collection on the left to manage its games."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func gameSearchBar(matchCount: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.callout)
            TextField("Search library games by title, API, or store…", text: $gameSearchText)
                .textFieldStyle(.plain).font(.callout)
            if !gameSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("\(matchCount) of \(vm.library.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button { gameSearchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Clear search")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.secondary.opacity(0.18)))
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    // MARK: Status banner & footer

    private func statusBanner(_ banner: CollectionsStatus) -> some View {
        let tint: Color = banner.isError ? .red : .green
        return HStack(spacing: 8) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").foregroundStyle(tint)
            Text(banner.message).font(.callout).lineLimit(2)
            Spacer(minLength: 8)
            Button { status = nil } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22).padding(.vertical, 8).background(tint.opacity(0.10))
    }

    private var footerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text").font(.caption).foregroundStyle(.tertiary)
            Text(LaunchDiagnostics.redactHome(manager.collectionsURL.path))
                .font(.caption.monospaced()).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 12)
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
    }

    // MARK: Actions

    private func staleCount(for col: GameCollection) -> Int {
        let valid = validGameIDs
        return col.gameIDs.filter { !valid.contains($0) }.count
    }

    private func reloadCollections(select preferredID: String? = nil) {
        let loaded = manager.load()
        document = loaded
        if let preferredID, loaded.collections.contains(where: { $0.id == preferredID }) {
            selectedCollectionID = preferredID
        } else if let current = selectedCollectionID, loaded.collections.contains(where: { $0.id == current }) {
            selectedCollectionID = current
        } else {
            selectedCollectionID = loaded.collections.first?.id
        }
    }

    private func runMutation(select preferredID: String? = nil, _ work: () throws -> String?) {
        do {
            guard let msg = try work() else { return }
            reloadCollections(select: preferredID)
            status = CollectionsStatus(message: msg, isError: false)
            onChanged?()
        } catch {
            status = CollectionsStatus(message: error.localizedDescription, isError: true)
        }
    }

    private func mutateStoredCollection(id: String, _ edit: (inout GameCollection) -> String?) {
        runMutation(select: id) {
            var doc = manager.load()
            guard let idx = doc.collections.firstIndex(where: { $0.id == id }),
                  let msg = edit(&doc.collections[idx]) else { return nil }
            doc.collections[idx].updatedAtUtc = GameCollectionsManager.utcTimestamp()
            try manager.save(doc)
            return msg
        }
    }

    private func openNewCollectionForm() {
        newName = ""; newSymbol = GameCollection.defaultSymbolName; newAccent = .blue; newFormError = nil
        showNewPopover = true
    }

    private func createNewCollection() {
        do {
            let created = try manager.createCollection(name: newName, symbolName: newSymbol, accentColor: newAccent)
            newFormError = nil; showNewPopover = false
            reloadCollections(select: created.id)
            status = CollectionsStatus(message: "Created collection “\(created.name)”.", isError: false)
            onChanged?()
        } catch {
            newFormError = error.localizedDescription
        }
    }

    private func commitRename(_ target: GameCollection) {
        renamingCollection = nil
        runMutation(select: target.id) {
            let updated = try manager.renameCollection(id: target.id, to: renameDraft)
            return "Renamed “\(target.name)” to “\(updated.name)”."
        }
    }

    private func commitDelete(_ target: GameCollection) {
        deletingCollection = nil
        let nextID: String? = {
            guard let i = document.collections.firstIndex(where: { $0.id == target.id }) else { return nil }
            return i + 1 < document.collections.count ? document.collections[i + 1].id : (i > 0 ? document.collections[i - 1].id : nil)
        }()
        runMutation(select: nextID) {
            try manager.deleteCollection(id: target.id)
            return "Deleted collection “\(target.name)”."
        }
    }

    private func toggleMembership(_ entry: GameLibraryEntry, in col: GameCollection) {
        runMutation(select: col.id) {
            let res = try manager.toggleGame(entry.id, in: col.id)
            return res.isMember ? "Added “\(entry.title)” to “\(res.collection.name)”."
                                : "Removed “\(entry.title)” from “\(res.collection.name)”."
        }
    }

    private func selectAllMatching(_ entries: [GameLibraryEntry], in col: GameCollection) {
        mutateStoredCollection(id: col.id) { stored in
            let existing = Set(stored.gameIDs)
            let additions = entries.map(\.id).filter { !existing.contains($0) }
            guard !additions.isEmpty else { return nil }
            stored.gameIDs.append(contentsOf: additions)
            return "Added \(additions.count) game\(additions.count == 1 ? "" : "s") to “\(stored.name)”."
        }
    }

    private func clearCollection(_ col: GameCollection) {
        mutateStoredCollection(id: col.id) { stored in
            let removed = stored.gameIDs.count
            guard removed > 0 else { return nil }
            stored.gameIDs.removeAll()
            return "Cleared \(removed) game\(removed == 1 ? "" : "s") from “\(stored.name)”."
        }
    }

    private func pruneStaleMemberships() {
        runMutation {
            let pruned = try manager.pruneMissingGames(validGameIDs: validGameIDs)
            return "Pruned \(pruned) stale game reference\(pruned == 1 ? "" : "s") across collections."
        }
    }
}

// MARK: - Row subviews

private struct CollectionRowView: View {
    let collection: GameCollection
    let isSelected: Bool
    let staleCount: Int
    let onSelect: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        let tint = collection.accentColor.swiftUIColor
        let badgeTint: Color = staleCount > 0 ? .orange : (isSelected ? tint : .secondary)

        HStack(spacing: 8) {
            Image(systemName: collection.symbolName)
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(tint).frame(width: 22, height: 22)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(collection.name)
                .font(.callout.weight(isSelected ? .semibold : .regular)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if isHovering || isSelected {
                HStack(spacing: 4) {
                    Button(action: onRename) { Image(systemName: "pencil").font(.system(size: 10.5, weight: .medium)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Rename \(collection.name)")
                    Button(action: onDelete) { Image(systemName: "trash").font(.system(size: 10.5, weight: .medium)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Delete \(collection.name)")
                }
            }
            Text("\(collection.gameIDs.count)")
                .font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(badgeTint)
                .padding(.horizontal, 6.5).padding(.vertical, 2)
                .background(badgeTint.opacity(0.14), in: Capsule())
        }
        .padding(.horizontal, 9).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? tint.opacity(0.13) : (isHovering ? Color.secondary.opacity(0.07) : .clear),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(isSelected ? tint.opacity(0.35) : .clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Rename…", action: onRename)
            Divider()
            Button("Delete…", role: .destructive, action: onDelete)
        }
    }
}

private struct MembershipGameRow: View {
    let entry: GameLibraryEntry
    let isMember: Bool
    let accent: Color
    let onToggle: () -> Void

    var body: some View {
        let badges = LauncherStyle.apiBadges(for: entry)
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: isMember ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(isMember ? accent : .secondary)
                GameArtworkView(entry: entry, style: .icon, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.title).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
                        if entry.isFavorite {
                            Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow).help("Favorite")
                        }
                    }
                    if !badges.isEmpty || entry.storeSource != nil {
                        HStack(spacing: 4) {
                            StorePill(source: entry.storeSource, gameID: entry.storeGameID ?? entry.steamAppID)
                            ForEach(badges) { BadgeView(badge: $0) }
                        }
                    }
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
            .background(isMember ? accent.opacity(0.08) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(isMember ? accent.opacity(0.32) : Color.secondary.opacity(0.14), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isMember ? .isSelected : [])
    }
}
