import XCTest
@testable import ChromaCore

/// прогон сообщает, что коллекции заведены, до записи, а не в конце.
final class CollectionsReadyTests: XCTestCase {
    private final class Database: SyncDatabase, @unchecked Sendable {
        var created: [String] = []
        var writes = 0
        func createCollection(name: String, metadata: ChromaMetadata?, configuration: CollectionConfiguration?, getOrCreate: Bool) async throws -> ChromaCollection {
            created.append(name)
            return ChromaCollection(id: "col", name: name, metadata: metadata, dimension: nil, tenant: nil, database: nil)
        }
        func resolveID(of name: String) async throws -> String { "col" }
        func updateCollection(id: String, newName: String?, metadata: ChromaMetadata?) async throws {}
        func upsert(collectionID: String, records: [EmbeddedRecord]) async throws { writes += 1 }
        func updateDocuments(collectionID: String, updates: [DocumentUpdate]) async throws {}
        func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord] { [] }
        func embeddings(collectionID: String, ids: [String]) async throws -> [String: [Double]] { [:] }
        func deleteDocuments(collectionID: String, ids: [String]) async throws {}
        func deleteDocuments(collectionID: String, filter: DocumentFilter) async throws -> Int { 0 }
    }

    private struct Embeddings: EmbeddingProvider {
        func embed(texts: [String], model: String) async throws -> [[Double]] { texts.map { _ in [1, 2, 3, 4] } }
    }

    private final class Seen: @unchecked Sendable {
        var readyAfterWrites: [Int] = []
    }

    func testTheRunSaysTheCollectionsAreReadyBeforeWriting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ready-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "Текст файла для проверки.".write(to: directory.appendingPathComponent("а.md"), atomically: true, encoding: .utf8)

        let service = SourceSyncService(manifests: ManifestStore(directory: directory.appendingPathComponent("manifests")))
        let source = DataSource(name: "docs", path: directory.path, fileExtensions: ["md"], collectionName: "ready_check")
        let database = Database()
        let seen = Seen()
        _ = try await service.sync(
            source: source, embeddingModel: "stub", chroma: database,
            embeddings: Embeddings(), binding: ModelBindingService()
        ) { update in
            if update.collectionsReady { seen.readyAfterWrites.append(database.writes) }
        }
        XCTAssertEqual(database.created, ["ready_check"])
        XCTAssertEqual(seen.readyAfterWrites, [0], "о коллекциях — один раз и до первой записи")
        XCTAssertGreaterThan(database.writes, 0)
    }
}
