import Foundation

/// What indexing needs from a database — nothing more.
///
/// A protocol rather than the concrete client because the failures this exists
/// to survive (dying between the write and the cleanup) cannot be provoked
/// against a real server on demand. The tests hand in a database that fails
/// exactly where they ask it to; the app hands in `ChromaClient`.
public protocol SyncDatabase: Sendable {
    func createCollection(
        name: String,
        metadata: ChromaMetadata?,
        configuration: CollectionConfiguration?,
        getOrCreate: Bool
    ) async throws -> ChromaCollection
    func resolveID(of name: String) async throws -> String
    /// Needed for one thing only: bringing a collection's recorded chunking
    /// recipe up to the current schema version.
    func updateCollection(id: String, newName: String?, metadata: ChromaMetadata?) async throws
    func upsert(collectionID: String, records: [EmbeddedRecord]) async throws
    /// Partial update — the one path that changes a document **without**
    /// recomputing its vector.
    ///
    /// Table sources need it: a changed price is a changed filter value,
    /// not changed meaning, and the stored embedding still describes the row.
    /// Upserting with an empty embedding would not do — it would replace the
    /// vector with nothing.
    func updateDocuments(collectionID: String, updates: [DocumentUpdate]) async throws
    /// Документы по явному списку идентификаторов.
    ///
    /// Нужно ровно для одного случая — переименования файла в git-репозитории
    ///: идентификатор чанка производен от пути, значит, при
    /// переименовании он меняется, а вектор — нет. Читаем старые чанки,
    /// перекладываем под новые идентификаторы с **теми же** векторами, старые
    /// удаляем.
    func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord]
    /// Векторы этих же чанков. Отдельным вызовом, потому что страница
    /// документов с векторами — это мегабайты, а здесь их ровно столько,
    /// сколько в одном файле.
    func embeddings(collectionID: String, ids: [String]) async throws -> [String: [Double]]
    func deleteDocuments(collectionID: String, ids: [String]) async throws
    /// Only used to clean up after manifests written before chunk ids were
    /// remembered; the normal path deletes by explicit id.
    func deleteDocuments(collectionID: String, filter: DocumentFilter) async throws -> Int
}

// `documents(collectionID:ids:)` и `embeddings(collectionID:ids:)` у клиента
// уже есть — их же требует конвейер поиска.
extension ChromaClient: SyncDatabase {}
