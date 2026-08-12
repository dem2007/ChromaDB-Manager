import Foundation

/// One query that was actually run.
///
/// Local, and deliberately never written into the database: what somebody
/// searched for is about the person, not about the collection.
public struct QueryHistoryEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var collectionName: String
    /// The profile the search ran under, by name — profiles are renamed and
    /// deleted, and a history entry should still say what it was.
    public var profileName: String
    public var profileID: UUID?
    /// The filter as it was applied, so «повторить» repeats the whole query and
    /// not just its text.
    public var filter: DocumentFilter?
    public var ranAt: Date
    public var resultCount: Int
    public var duration: TimeInterval
    /// Pinned entries survive eviction and sort to the top.
    public var isPinned: Bool
    /// Marked for the evaluation stand's query set.
    ///
    /// The stand does not exist yet, so this is a flag rather than a write into
    /// its storage: inventing a format it will have to match would be worse than
    /// recording the fact where it already lives.
    public var isChosenForEvaluation: Bool

    public init(
        id: UUID = UUID(),
        text: String,
        collectionName: String,
        profileName: String,
        profileID: UUID? = nil,
        filter: DocumentFilter? = nil,
        ranAt: Date = Date(),
        resultCount: Int = 0,
        duration: TimeInterval = 0,
        isPinned: Bool = false,
        isChosenForEvaluation: Bool = false
    ) {
        self.id = id
        self.text = text
        self.collectionName = collectionName
        self.profileName = profileName
        self.profileID = profileID
        self.filter = filter
        self.ranAt = ranAt
        self.resultCount = resultCount
        self.duration = duration
        self.isPinned = isPinned
        self.isChosenForEvaluation = isChosenForEvaluation
    }

    /// What is identical about two runs of «the same» query: the text, the
    /// collection and the filter. Time and result count are not part of it.
    var sameQueryKey: String {
        let filterKey = (try? filter.map { String(describing: try $0.whereClause() ?? [:]) }) ?? nil
        return "\(collectionName)\u{0}\(text.trimmingCharacters(in: .whitespacesAndNewlines))\u{0}\(filterKey ?? "")"
    }

    public var line: String {
        let time = duration < 1
            ? String(localized: "\(Int((duration * 1000).rounded())) мс")
            : String(localized: "\(String(format: "%.1f", duration)) с")
        let results = RussianCount.phrase(resultCount, "результат", "результата", "результатов")
        return String(localized: "\(results) · \(time) · профиль «\(profileName)»")
    }
}

/// Every query that was run, kept locally.
///
/// The point of it is not nostalgia. It is the only realistic way the evaluation
/// stand of D1 ever gets a query set: nobody writes twenty representative
/// queries by hand, and everybody has already typed them.
public final class QueryHistoryStore {
    /// Default cap. Old entries fall off the end — pinned ones do not.
    public static let defaultLimit = 1000

    private let file: GuardedJSONFile<[QueryHistoryEntry]>
    private let log: LogHandler
    private var entries: [QueryHistoryEntry]
    public var limit: Int

    public init(
        directory: URL = AppPaths.supportDirectory,
        limit: Int = QueryHistoryStore.defaultLimit,
        log: @escaping LogHandler = noopLogHandler
    ) {
        self.file = GuardedJSONFile(
            url: directory.appendingPathComponent("query-history.json"),
            category: "Коллекции",
            log: log
        )
        self.limit = limit
        self.log = log
        self.entries = file.value(or: [])
    }

    /// Почему ничего не сохраняется, если это так.
    public var persistenceProblem: String? { file.problem }

    /// Newest first, pinned above the rest.
    public func all() -> [QueryHistoryEntry] {
        entries.sorted { left, right in
            if left.isPinned != right.isPinned { return left.isPinned }
            return left.ranAt > right.ranAt
        }
    }

    public func entries(for collectionName: String) -> [QueryHistoryEntry] {
        all().filter { $0.collectionName == collectionName }
    }

    /// Free-text search over the history — E6 asks for it because a history of a
    /// thousand entries is unusable without one.
    public func search(_ text: String, in collectionName: String? = nil) -> [QueryHistoryEntry] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = collectionName.map { entries(for: $0) } ?? all()
        guard !needle.isEmpty else { return base }
        return base.filter {
            $0.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// Records a run.
    ///
    /// The same query run twice does not become two entries: it updates the one
    /// that is there. A history where «требования к оборудованию» appears
    /// forty times is a history nobody scrolls.
    @discardableResult
    public func record(_ entry: QueryHistoryEntry) -> QueryHistoryEntry {
        var stored = entry
        stored.text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stored.text.isEmpty else { return stored }

        if let index = entries.firstIndex(where: { $0.sameQueryKey == stored.sameQueryKey }) {
            // Everything the user marked about it survives the repeat.
            stored.id = entries[index].id
            stored.isPinned = entries[index].isPinned
            stored.isChosenForEvaluation = entries[index].isChosenForEvaluation
            entries[index] = stored
        } else {
            entries.append(stored)
        }
        evict()
        persist()
        return stored
    }

    public func setPinned(_ pinned: Bool, id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isPinned = pinned
        persist()
    }

    public func setChosenForEvaluation(_ chosen: Bool, id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isChosenForEvaluation = chosen
        persist()
    }

    /// What the evaluation stand will read when it exists.
    public func chosenForEvaluation(in collectionName: String? = nil) -> [QueryHistoryEntry] {
        (collectionName.map { entries(for: $0) } ?? all()).filter(\.isChosenForEvaluation)
    }

    public func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    /// Clearing is its own action, never a side effect of anything else.
    public func clear(collectionName: String? = nil) {
        let before = entries.count
        if let collectionName {
            entries.removeAll { $0.collectionName == collectionName }
        } else {
            entries.removeAll()
        }
        persist()
        log(.info, "Поиск", "История запросов очищена: удалено \(before - entries.count)")
    }

    /// Drops the oldest until the cap is met.
    ///
    /// Pinned entries are never dropped, and neither are ones marked for the
    /// evaluation set: both are things the user deliberately kept, and eviction
    /// is a housekeeping rule, not a decision about their work.
    private func evict() {
        guard entries.count > limit else { return }
        let protectedCount = entries.filter { $0.isPinned || $0.isChosenForEvaluation }.count
        let removable = entries
            .filter { !$0.isPinned && !$0.isChosenForEvaluation }
            .sorted { $0.ranAt < $1.ranAt }
        let excess = entries.count - max(limit, protectedCount)
        guard excess > 0 else { return }
        let doomed = Set(removable.prefix(excess).map(\.id))
        entries.removeAll { doomed.contains($0.id) }
    }

    private func persist() { file.write(entries) }
}
