import Foundation

/// Query sets, kept locally.
///
/// In `Application Support` beside the search profiles and the query history,
/// by rule 2.8: a set is the user's working material, not a property of any
/// collection, and it has to outlive the collections it was run against.
public final class QuerySetStore {
    private let file: GuardedJSONFile<[QuerySet]>
    private let log: LogHandler
    private var sets: [QuerySet]

    /// Почему ничего не сохраняется, если это так. Размеченный эталон —
    /// часы ручной работы, и затирать его нечитаемым файлом нельзя.
    public var persistenceProblem: String? { file.problem }

    public init(directory: URL = AppPaths.supportDirectory, log: @escaping LogHandler = noopLogHandler) {
        self.file = GuardedJSONFile(
            url: directory.appendingPathComponent("query-sets.json"),
            category: "Оценка",
            log: log
        )
        self.log = log
        self.sets = file.value(or: [])
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public func all() -> [QuerySet] {
        sets.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func set(id: UUID) -> QuerySet? { sets.first { $0.id == id } }

    @discardableResult
    public func save(_ set: QuerySet) -> QuerySet {
        var stored = set
        stored.name = set.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if stored.name.isEmpty { stored.name = String(localized: "Без названия") }
        stored.updatedAt = Date()

        if let index = sets.firstIndex(where: { $0.id == stored.id }) {
            sets[index] = stored
        } else {
            sets.append(stored)
        }
        persist()
        return stored
    }

    public func remove(id: UUID) {
        guard let removed = sets.first(where: { $0.id == id }) else { return }
        sets.removeAll { $0.id == id }
        persist()
        log(.warning, "Оценка", "Набор запросов «\(removed.name)» удалён")
    }

    // MARK: - Из истории

    /// Adds queries to a set, skipping ones already in it.
    ///
    /// «Основной способ наполнения»: nobody writes twenty representative
    /// queries by hand, and everybody has already typed them. Sameness is the
    /// text plus the filter — the same words with another `where` are another
    /// query, exactly as the history counts them.
    @discardableResult
    public func add(_ queries: [EvaluationQuery], to setID: UUID) -> Int {
        guard let index = sets.firstIndex(where: { $0.id == setID }) else { return 0 }
        var added = 0
        for query in queries where !sets[index].queries.contains(where: { Self.sameQuery($0, query) }) {
            sets[index].queries.append(query)
            added += 1
        }
        if added > 0 {
            sets[index].updatedAt = Date()
            persist()
            log(.info, "Оценка", "В набор «\(sets[index].name)» добавлено запросов: \(added)")
        }
        return added
    }

    static func sameQuery(_ left: EvaluationQuery, _ right: EvaluationQuery) -> Bool {
        let leftFilter = (try? left.filter.map { String(describing: try $0.whereClause() ?? [:]) }) ?? nil
        let rightFilter = (try? right.filter.map { String(describing: try $0.whereClause() ?? [:]) }) ?? nil
        return left.text.trimmingCharacters(in: .whitespacesAndNewlines)
            == right.text.trimmingCharacters(in: .whitespacesAndNewlines)
            && leftFilter == rightFilter
    }

    /// The set every history entry marked «в набор» goes into by default.
    ///
    /// Created on first use rather than at launch: an empty set nobody asked
    /// for is one more thing on screen to ignore.
    @discardableResult
    public func defaultSet() -> QuerySet {
        if let existing = sets.first(where: { $0.name == Self.defaultSetName }) { return existing }
        return save(QuerySet(
            name: Self.defaultSetName,
            note: String(localized: "Запросы, отмеченные в истории поиска.")
        ))
    }

    public static let defaultSetName = String(localized: "Из истории")

    // MARK: - Разметка

    /// Records a grade for one result of one query, as a text fragment.
    ///
    /// The fragment is the beginning of the found text rather than all of it:
    /// a whole chunk as ground truth would match only itself, and the point is
    /// to match the same passage however the next variant cut it.
    @discardableResult
    public func mark(
        queryID: UUID,
        in setID: UUID,
        documentID: String,
        text: String?,
        grade: RelevanceGrade,
        note: String = ""
    ) -> Bool {
        guard let setIndex = sets.firstIndex(where: { $0.id == setID }),
              let queryIndex = sets[setIndex].queries.firstIndex(where: { $0.id == queryID })
        else { return false }

        guard let fragment = Self.fragment(from: text) else {
            // Nothing to quote — fall back to the id, which at least works
            // inside this one collection.
            sets[setIndex].queries[queryIndex].documents.removeAll { $0.id == documentID }
            sets[setIndex].queries[queryIndex].documents.append(
                ExpectedDocument(id: documentID, grade: grade)
            )
            sets[setIndex].updatedAt = Date()
            persist()
            return true
        }

        var query = sets[setIndex].queries[queryIndex]
        // Re-marking the same passage replaces the grade instead of stacking a
        // second opinion on top of the first.
        query.fragments.removeAll { ExpectedFragment.normalised($0.fragment) == ExpectedFragment.normalised(fragment) }
        query.fragments.append(ExpectedFragment(fragment: fragment, grade: grade, note: note))
        sets[setIndex].queries[queryIndex] = query
        sets[setIndex].updatedAt = Date()
        persist()
        return true
    }

    /// Takes back a grade given to one result.
    ///
    /// A mis-click otherwise leaves ground truth nobody meant and no way back —
    /// and wrong ground truth is worse than none, because every later run is
    /// scored against it. Removing is an explicit press on the grade already
    /// given, never something the app decides on its own (правило 1).
    @discardableResult
    public func unmark(queryID: UUID, in setID: UUID, documentID: String, text: String?) -> Bool {
        guard let setIndex = sets.firstIndex(where: { $0.id == setID }),
              let queryIndex = sets[setIndex].queries.firstIndex(where: { $0.id == queryID })
        else { return false }

        var query = sets[setIndex].queries[queryIndex]
        let before = query.fragments.count + query.documents.count
        if let fragment = Self.fragment(from: text) {
            query.fragments.removeAll {
                ExpectedFragment.normalised($0.fragment) == ExpectedFragment.normalised(fragment)
            }
        }
        query.documents.removeAll { $0.id == documentID }
        guard before != query.fragments.count + query.documents.count else { return false }

        sets[setIndex].queries[queryIndex] = query
        sets[setIndex].updatedAt = Date()
        persist()
        return true
    }

    /// How much of a found text becomes the fragment.
    ///
    /// Long enough to be unique in a collection, short enough to survive being
    /// re-chunked: a passage cut at a different boundary still contains this
    /// much of its beginning.
    public static let fragmentLength = 120

    static func fragment(from text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard collapsed.count >= 12 else { return collapsed.isEmpty ? nil : collapsed }
        return String(collapsed.prefix(fragmentLength))
    }

    // MARK: - Перенос

    public func exportData(_ set: QuerySet) throws -> Data {
        try Self.encoder().encode(set)
    }

    /// A set read from a file, with a new id.
    ///
    /// New because the file may have come from the machine this set still lives
    /// on: an import adds, it never overwrites something the user did not name.
    public func importing(_ data: Data) throws -> QuerySet {
        var decoded = try Self.decoder().decode(QuerySet.self, from: data)
        decoded.id = UUID()
        decoded.queries = decoded.queries.map { query in
            var copy = query
            copy.id = UUID()
            return copy
        }
        return decoded
    }

    private func persist() { file.write(sets) }
}

public extension EvaluationQuery {
    /// A history entry as a query of a set (E6 → D1.1).
    init(_ entry: QueryHistoryEntry) {
        self.init(
            text: entry.text,
            filter: entry.filter,
            comment: String(localized: "из истории поиска, коллекция «\(entry.collectionName)»")
        )
    }
}
