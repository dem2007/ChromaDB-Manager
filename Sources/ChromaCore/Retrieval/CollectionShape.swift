import Foundation

/// Whether a collection was cut into two levels.
public enum CollectionShape: String, Sendable, Codable {
    /// One level. Collapsing and promotion have nothing to work with and are
    /// not offered in the profile.
    case flat
    /// Parents and children in one collection, linked by `parent_chunk_id`.
    case hierarchical

    public var isHierarchical: Bool { self == .hierarchical }
}

/// Answers «has this collection got two levels?» once per collection.
///
/// **Not by sampling.** On a collection where hierarchical chunks are under a
/// percent, a sample would not see them and the stages would quietly disappear
/// from the interface with no explanation. The question is answered by point
/// queries with `limit: 1`, whose answer does not depend on how much was
/// looked at.
///
/// Two of them rather than the one the specification names, because it assumes
/// `chunk_level` is the string `"child"` and the chunkers write an integer —
/// 0 for a child, 1 and up for a parent — for **every** chunk, flat strategies
/// included. So «есть ли уровень 0» alone says nothing, and the pair «есть и
/// родители, и дети» is what actually distinguishes a two-level collection from
/// a one-level one.
///
/// Keyed by collection **id**, not name. A collection that is deleted and
/// recreated gets a new id, so the entry that would have gone stale is
/// unreachable instead — the problem A4 solves for the name → UUID cache cannot
/// arise here.
public actor CollectionShapeCache {
    private var known: [String: CollectionShape] = [:]
    private let log: LogHandler

    public init(log: @escaping LogHandler = noopLogHandler) {
        self.log = log
    }

    public func shape(
        of collectionID: String,
        collectionName: String,
        database: any RetrievalDatabase
    ) async -> CollectionShape {
        if let known = known[collectionID] { return known }

        let shape: CollectionShape
        do {
            async let parentsProbe = database.anyDocument(
                collectionID: collectionID,
                matching: DocumentFilter(conditions: [ChunkLevelScope.parents.condition!])
            )
            async let childrenProbe = database.anyDocument(
                collectionID: collectionID,
                matching: DocumentFilter(conditions: [ChunkLevelScope.children.condition!])
            )
            let hasParents = try await parentsProbe
            let hasChildren = try await childrenProbe
            shape = hasParents && hasChildren ? .hierarchical : .flat
        } catch {
            // A collection whose shape could not be established is treated as
            // flat: the stages then do nothing, which is the outcome that
            // cannot make a search worse. Not cached — the next query asks
            // again rather than living with a guess.
            log(.warning, "Поиск",
                "Не удалось определить уровни коллекции «\(collectionName)»: \(error.localizedDescription). Иерархические стадии выключены для этого запроса.")
            return .flat
        }

        known[collectionID] = shape
        log(.debug, "Поиск", "Коллекция «\(collectionName)»: \(shape == .hierarchical ? "два уровня чанков" : "один уровень чанков")")
        return shape
    }

    /// Forget one collection — after a re-index changed how it is cut.
    public func forget(collectionID: String) {
        known.removeValue(forKey: collectionID)
    }

    /// Forget everything — a new connection may be a different database.
    public func reset() {
        known.removeAll()
    }
}
