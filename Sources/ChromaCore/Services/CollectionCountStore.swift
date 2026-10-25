import Foundation

/// Последнее известное число документов каждой коллекции.
///
/// **Зачем.** Спросить у ChromaDB «сколько документов» — значит заставить
/// сервер поднять в память HNSW-индекс коллекции, и обратно он его не
/// выгружает. Список коллекций просил число у каждой: на базе из 37
/// коллекций сервер занимал 2,1 ГБ сразу после запуска — до первого поиска
/// (замер на копии базы: 30 МБ до списка, 2158 МБ после). Теперь список
/// показывает последнее известное число отсюда, а у сервера спрашивается
/// только открытая коллекция и те, в которые только что писали.
///
/// Ключ — идентификатор коллекции: имя после удаления и создания заново
/// принадлежит уже другой коллекции, и чужое число ей не подходит.
public final class CollectionCountStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var counts: [String: Int]

    public init(fileURL: URL = AppPaths.supportDirectory.appendingPathComponent("collection-counts.json")) {
        self.fileURL = fileURL
        counts = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
    }

    public func count(for collectionID: String) -> Int? {
        lock.withLock { counts[collectionID] }
    }

    public func record(_ count: Int, for collectionID: String) {
        let changed = lock.withLock { () -> Bool in
            guard counts[collectionID] != count else { return false }
            counts[collectionID] = count
            return true
        }
        if changed { save() }
    }

    /// Забыть коллекции, которых на сервере больше нет.
    ///
    /// Только по полному списку **этого** сервера: у другого подключения
    /// свои коллекции, и их числа стирать незачем — поэтому забываются лишь
    /// идентификаторы, которые были у этого сервера и пропали из него.
    public func forget(_ collectionIDs: Set<String>) {
        guard !collectionIDs.isEmpty else { return }
        let changed = lock.withLock { () -> Bool in
            let before = counts.count
            counts = counts.filter { !collectionIDs.contains($0.key) }
            return counts.count != before
        }
        if changed { save() }
    }

    private func save() {
        let snapshot = lock.withLock { counts }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? AppPaths.ensureDirectory(fileURL.deletingLastPathComponent())
        try? data.write(to: fileURL, options: .atomic)
    }
}
