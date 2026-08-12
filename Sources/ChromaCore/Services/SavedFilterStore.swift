import Foundation

/// Named filters, kept per collection.
///
/// Cheap to build and used constantly: the same three or four conditions get
/// retyped every time a collection is opened.
public final class SavedFilterStore {
    private let file: GuardedJSONFile<[SavedFilter]>
    private let log: LogHandler
    private var filters: [SavedFilter]

    /// Why nothing is being saved, when that is the case.
    public var persistenceProblem: String? { file.problem }

    public init(directory: URL = AppPaths.supportDirectory, log: @escaping LogHandler = noopLogHandler) {
        // The dates in this file were written without a strategy, so it keeps
        // the plain coders: changing them would make every saved filter
        // unreadable — the very failure this guard exists for.
        self.file = GuardedJSONFile(
            url: directory.appendingPathComponent("saved-filters.json"),
            category: "Коллекции",
            log: log,
            decoder: { JSONDecoder() },
            encoder: {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                return encoder
            }
        )
        self.log = log
        self.filters = file.value(or: [])
    }

    public func filters(for collectionName: String) -> [SavedFilter] {
        filters
            .filter { $0.collectionName == collectionName }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    public func save(name: String, filter: DocumentFilter, collectionName: String) -> SavedFilter {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        // Saving under an existing name replaces it: two identical entries in
        // the menu are worse than losing the previous version.
        if let index = filters.firstIndex(where: { $0.collectionName == collectionName && $0.name == trimmed }) {
            filters[index].filter = filter
            filters[index].savedAt = Date()
            persist()
            return filters[index]
        }
        let saved = SavedFilter(name: trimmed, collectionName: collectionName, filter: filter)
        filters.append(saved)
        persist()
        log(.info, "Коллекции", "Фильтр «\(trimmed)» сохранён для коллекции «\(collectionName)»")
        return saved
    }

    /// Every filter of every collection — what H6 carries to another machine.
    public func all() -> [SavedFilter] { filters }

    /// Replaces the whole list, for an import that has already been shown
    /// to the user and confirmed.
    public func replaceAll(_ replacement: [SavedFilter]) {
        filters = replacement
        persist()
    }

    public func remove(id: UUID) {
        filters.removeAll { $0.id == id }
        persist()
    }

    /// Filters of a collection that no longer exists are of no use to anyone.
    public func removeAll(forCollection collectionName: String) {
        filters.removeAll { $0.collectionName == collectionName }
        persist()
    }

    private func persist() { file.write(filters) }
}
