import Foundation

// User Game Collections & Tagging Manager for DirectMetal.
// Persists user-defined game collections in
// `~/Library/Application Support/DirectMetal/collections.json`
// (`directmetal.collections.v1`), respecting `DIRECTMETAL_LIBRARY_DIR`.

// MARK: - Accent Color

enum CollectionAccentColor: String, Codable, CaseIterable, Hashable, Sendable {
    case blue, purple, pink, red, orange, yellow, green, teal, indigo, gray

    var displayName: String { rawValue.capitalized }
}

// MARK: - Data Models

struct GameCollection: Codable, Identifiable, Equatable, Sendable {
    static let defaultSymbolName = "folder.fill"

    let id: String
    var name: String
    var symbolName: String
    var accentColor: CollectionAccentColor
    var gameIDs: [String]
    var createdAtUtc: String
    var updatedAtUtc: String

    init(
        id: String? = nil,
        name: String,
        symbolName: String = GameCollection.defaultSymbolName,
        accentColor: CollectionAccentColor = .blue,
        gameIDs: [String] = [],
        createdAtUtc: String = GameCollectionsManager.utcTimestamp(),
        updatedAtUtc: String? = nil
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitID = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSymbol = symbolName.trimmingCharacters(in: .whitespacesAndNewlines)

        self.id = (explicitID?.isEmpty == false) ? explicitID! : GameCollectionsManager.slugify(trimmedName)
        self.name = trimmedName
        self.symbolName = trimmedSymbol.isEmpty ? Self.defaultSymbolName : trimmedSymbol
        self.accentColor = accentColor
        self.gameIDs = GameCollectionsManager.deduplicatedGameIDs(gameIDs)
        self.createdAtUtc = createdAtUtc
        self.updatedAtUtc = updatedAtUtc ?? createdAtUtc
    }

    enum CodingKeys: String, CodingKey {
        case id, name, symbolName, accentColor, gameIDs, createdAtUtc, updatedAtUtc
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedName = try c.decode(String.self, forKey: .name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decodedName.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .name, in: c, debugDescription: "GameCollection name must not be empty."
            )
        }
        let decodedID = try c.decodeIfPresent(String.self, forKey: .id)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedID = (decodedID?.isEmpty == false) ? decodedID! : GameCollectionsManager.slugify(decodedName)
        guard !resolvedID.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .id, in: c, debugDescription: "GameCollection id must not be empty."
            )
        }
        let rawSymbol = try c.decodeIfPresent(String.self, forKey: .symbolName)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let decodedAccent = (try? c.decodeIfPresent(CollectionAccentColor.self, forKey: .accentColor)) ?? .blue
        let decodedGameIDs = try c.decodeIfPresent([String].self, forKey: .gameIDs) ?? []
        let now = GameCollectionsManager.utcTimestamp()
        let decodedCreated = try c.decodeIfPresent(String.self, forKey: .createdAtUtc) ?? now

        self.id = resolvedID
        self.name = decodedName
        self.symbolName = rawSymbol.isEmpty ? Self.defaultSymbolName : rawSymbol
        self.accentColor = decodedAccent
        self.gameIDs = GameCollectionsManager.deduplicatedGameIDs(decodedGameIDs)
        self.createdAtUtc = decodedCreated
        self.updatedAtUtc = try c.decodeIfPresent(String.self, forKey: .updatedAtUtc) ?? decodedCreated
    }
}

struct GameCollectionsDocument: Codable, Equatable, Sendable {
    static let schemaID = "directmetal.collections.v1"

    let schema: String
    var collections: [GameCollection]

    init(schema: String = GameCollectionsDocument.schemaID, collections: [GameCollection] = []) {
        self.schema = schema
        self.collections = collections
    }
}

// MARK: - Errors

enum GameCollectionsError: Error, LocalizedError, Equatable, Sendable {
    case invalidName(String)
    case duplicateCollection(String)
    case collectionNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidName(let detail):
            return "Invalid collection name: \(detail)"
        case .duplicateCollection(let identifier):
            return "A collection matching '\(identifier)' already exists."
        case .collectionNotFound(let id):
            return "Collection not found: '\(id)'"
        }
    }
}

// MARK: - Manager

struct GameCollectionsManager: Sendable {
    static let fileName = "collections.json"
    static let schemaID = GameCollectionsDocument.schemaID
    static let maxSlugLength = 64

    let collectionsURL: URL

    init(supportRoot: URL? = nil) {
        let root = supportRoot ?? GameLibraryManager.defaultSupportRoot()
        self.collectionsURL = root.appendingPathComponent(Self.fileName)
    }

    // MARK: Persistence

    /// Loads `collections.json` tolerantly; missing or corrupt files return an empty v1 document.
    func load() -> GameCollectionsDocument {
        guard let data = try? Data(contentsOf: collectionsURL),
              let decoded = try? JSONDecoder().decode(GameCollectionsDocument.self, from: data),
              decoded.schema == Self.schemaID
        else {
            return GameCollectionsDocument()
        }

        var seenIDs = Set<String>()
        var unique: [GameCollection] = []
        unique.reserveCapacity(decoded.collections.count)
        for var collection in decoded.collections {
            guard seenIDs.insert(collection.id).inserted else { continue }
            collection.gameIDs = Self.deduplicatedGameIDs(collection.gameIDs)
            unique.append(collection)
        }
        return GameCollectionsDocument(schema: decoded.schema, collections: unique)
    }

    /// Creates parent directories as needed and atomically writes pretty-printed, sorted JSON.
    func save(_ doc: GameCollectionsDocument) throws {
        var normalized = doc
        for index in normalized.collections.indices {
            normalized.collections[index].gameIDs = Self.deduplicatedGameIDs(normalized.collections[index].gameIDs)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(normalized)

        try FileManager.default.createDirectory(
            at: collectionsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: collectionsURL, options: .atomic)
    }

    // MARK: Collection CRUD

    @discardableResult
    func createCollection(
        name: String,
        symbolName: String = "folder.fill",
        accentColor: CollectionAccentColor = .blue
    ) throws -> GameCollection {
        let (trimmedName, slug) = try Self.validateName(name)
        var doc = load()
        if Self.hasConflict(name: trimmedName, slug: slug, in: doc.collections, excludingID: nil) {
            throw GameCollectionsError.duplicateCollection(slug)
        }

        let now = Self.utcTimestamp()
        let collection = GameCollection(
            id: slug,
            name: trimmedName,
            symbolName: symbolName,
            accentColor: accentColor,
            gameIDs: [],
            createdAtUtc: now,
            updatedAtUtc: now
        )
        doc.collections.append(collection)
        try save(doc)
        return collection
    }

    @discardableResult
    func renameCollection(id: String, to newName: String) throws -> GameCollection {
        let (trimmedName, newSlug) = try Self.validateName(newName)
        var doc = load()
        guard let index = Self.index(of: id, in: doc.collections) else {
            throw GameCollectionsError.collectionNotFound(id)
        }
        if Self.hasConflict(name: trimmedName, slug: newSlug, in: doc.collections, excludingID: doc.collections[index].id) {
            throw GameCollectionsError.duplicateCollection(newSlug)
        }

        doc.collections[index].name = trimmedName
        doc.collections[index].updatedAtUtc = Self.utcTimestamp()
        try save(doc)
        return doc.collections[index]
    }

    func deleteCollection(id: String) throws {
        var doc = load()
        guard let index = Self.index(of: id, in: doc.collections) else {
            throw GameCollectionsError.collectionNotFound(id)
        }
        doc.collections.remove(at: index)
        try save(doc)
    }

    // MARK: Membership Operations

    @discardableResult
    func addGame(_ gameID: String, to collectionID: String) throws -> GameCollection {
        try mutateCollection(id: collectionID) { collection in
            let trimmed = gameID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !collection.gameIDs.contains(trimmed) else { return false }
            collection.gameIDs.append(trimmed)
            return true
        }.collection
    }

    @discardableResult
    func removeGame(_ gameID: String, from collectionID: String) throws -> GameCollection {
        try mutateCollection(id: collectionID) { collection in
            let trimmed = gameID.trimmingCharacters(in: .whitespacesAndNewlines)
            let before = collection.gameIDs.count
            collection.gameIDs.removeAll { $0 == trimmed }
            return collection.gameIDs.count != before
        }.collection
    }

    @discardableResult
    func toggleGame(_ gameID: String, in collectionID: String) throws -> (collection: GameCollection, isMember: Bool) {
        var isMember = false
        let result = try mutateCollection(id: collectionID) { collection in
            let trimmed = gameID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            if collection.gameIDs.contains(trimmed) {
                collection.gameIDs.removeAll { $0 == trimmed }
                isMember = false
            } else {
                collection.gameIDs.append(trimmed)
                isMember = true
            }
            return true
        }
        return (collection: result.collection, isMember: isMember)
    }

    func collections(containing gameID: String) -> [GameCollection] {
        let trimmed = gameID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return load().collections.filter { $0.gameIDs.contains(trimmed) }
    }

    func games(in collectionID: String, from library: [GameLibraryEntry]) -> [GameLibraryEntry] {
        let doc = load()
        guard let index = Self.index(of: collectionID, in: doc.collections) else { return [] }
        let entriesByID = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return doc.collections[index].gameIDs.compactMap { entriesByID[$0] }
    }

    @discardableResult
    func pruneMissingGames(validGameIDs: Set<String>) throws -> Int {
        var doc = load()
        var totalPruned = 0
        let now = Self.utcTimestamp()

        for index in doc.collections.indices {
            let before = doc.collections[index].gameIDs.count
            doc.collections[index].gameIDs.removeAll { !validGameIDs.contains($0) }
            let removed = before - doc.collections[index].gameIDs.count
            if removed > 0 {
                totalPruned += removed
                doc.collections[index].updatedAtUtc = now
            }
        }
        if totalPruned > 0 { try save(doc) }
        return totalPruned
    }

    // MARK: Formatting

    static func formatText(_ doc: GameCollectionsDocument, library: [GameLibraryEntry]) -> String {
        var lines: [String] = ["DirectMetal Game Collections"]
        guard !doc.collections.isEmpty else {
            lines.append("")
            lines.append("No collections yet.")
            return lines.joined(separator: "\n") + "\n"
        }

        let entriesByID = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let totalMemberships = doc.collections.reduce(0) { $0 + $1.gameIDs.count }
        let collectionNoun = doc.collections.count == 1 ? "collection" : "collections"
        let membershipNoun = totalMemberships == 1 ? "membership" : "memberships"
        lines.append("Summary: \(doc.collections.count) \(collectionNoun), \(totalMemberships) game \(membershipNoun)")

        for collection in doc.collections {
            lines.append("")
            let count = collection.gameIDs.count
            let gameNoun = count == 1 ? "game" : "games"
            lines.append(
                "• \(collection.name) (\(collection.id)) — \(count) \(gameNoun) [\(collection.accentColor.rawValue), \(collection.symbolName)]"
            )
            if collection.gameIDs.isEmpty {
                lines.append("    (empty)")
            } else {
                for gameID in collection.gameIDs {
                    if let entry = entriesByID[gameID] {
                        lines.append("    - \(entry.title) (\(entry.id))")
                    } else {
                        lines.append("    - [missing] (\(gameID))")
                    }
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Helpers

    /// Converts a collection display name into a deterministic lowercase kebab-case slug
    /// matching `^[a-z0-9]+(?:-[a-z0-9]+)*$` (empty if no ASCII alphanumeric characters remain).
    static func slugify(_ raw: String) -> String {
        let folded = raw
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()

        let apostrophes: Set<Unicode.Scalar> = ["'", "\u{2018}", "\u{2019}", "`"]
        var result = ""
        result.reserveCapacity(min(folded.count, maxSlugLength))
        var pendingHyphen = false

        for scalar in folded.unicodeScalars {
            if apostrophes.contains(scalar) { continue }
            let value = scalar.value
            if (value >= 97 && value <= 122) || (value >= 48 && value <= 57) {
                if pendingHyphen && !result.isEmpty { result.append("-") }
                pendingHyphen = false
                result.append(Character(scalar))
            } else if !result.isEmpty {
                pendingHyphen = true
            }
        }

        if result.count > maxSlugLength {
            result = String(result.prefix(maxSlugLength))
            while result.hasSuffix("-") { result.removeLast() }
        }
        return result
    }

    static func deduplicatedGameIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(ids.count)
        for raw in ids {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    static func utcTimestamp(for date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func mutateCollection(
        id: String,
        _ body: (inout GameCollection) -> Bool
    ) throws -> (collection: GameCollection, changed: Bool) {
        var doc = load()
        guard let index = Self.index(of: id, in: doc.collections) else {
            throw GameCollectionsError.collectionNotFound(id)
        }
        let changed = body(&doc.collections[index])
        if changed {
            doc.collections[index].updatedAtUtc = Self.utcTimestamp()
            try save(doc)
        }
        return (doc.collections[index], changed)
    }

    private static func validateName(_ raw: String) throws -> (name: String, slug: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GameCollectionsError.invalidName("Collection name must not be empty.")
        }
        let slug = slugify(trimmed)
        guard !slug.isEmpty else {
            throw GameCollectionsError.invalidName("'\(trimmed)' must contain at least one letter or digit.")
        }
        return (trimmed, slug)
    }

    private static func hasConflict(
        name: String,
        slug: String,
        in collections: [GameCollection],
        excludingID: String?
    ) -> Bool {
        collections.contains { existing in
            if let excludingID, existing.id == excludingID { return false }
            return existing.id == slug
                || existing.name.caseInsensitiveCompare(name) == .orderedSame
                || slugify(existing.name) == slug
        }
    }

    private static func index(of collectionID: String, in collections: [GameCollection]) -> Int? {
        let trimmed = collectionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return collections.firstIndex(where: { $0.id == trimmed })
    }
}
