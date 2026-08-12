import XCTest
@testable import ChromaCore

/// §I2.1 — переименование файла не стоит ни одного вектора.
final class GitRenameTests: XCTestCase {
    /// База, которая помнит, о чём её просили, и в каком порядке.
    private final class Database: SyncDatabase, @unchecked Sendable {
        var records: [String: EmbeddedRecord] = [:]
        private(set) var calls: [String] = []
        var refusesUpsert = false

        func seed(_ record: EmbeddedRecord) { records[record.id] = record }

        func createCollection(
            name: String, metadata: ChromaMetadata?, configuration: CollectionConfiguration?, getOrCreate: Bool
        ) async throws -> ChromaCollection {
            ChromaCollection(id: "collection", name: name, metadata: metadata)
        }

        func resolveID(of name: String) async throws -> String { "collection" }
        func updateCollection(id: String, newName: String?, metadata: ChromaMetadata?) async throws {}

        func upsert(collectionID: String, records incoming: [EmbeddedRecord]) async throws {
            calls.append("upsert")
            if refusesUpsert { throw ChromaError.api(status: 500, code: nil, message: "запись отклонена") }
            for record in incoming { records[record.id] = record }
        }

        func updateDocuments(collectionID: String, updates: [DocumentUpdate]) async throws {
            XCTFail("перенос чанков делается upsert-ом с теми же векторами, а не правкой метаданных")
        }

        func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord] {
            calls.append("documents")
            return ids.compactMap { id in
                guard let record = records[id] else { return nil }
                return DocumentRecord(
                    id: id, document: record.document, metadata: record.metadata,
                    embeddingDimension: record.embedding.count
                )
            }
        }

        func embeddings(collectionID: String, ids: [String]) async throws -> [String: [Double]] {
            calls.append("embeddings")
            return ids.reduce(into: [:]) { result, id in result[id] = records[id]?.embedding }
        }

        func deleteDocuments(collectionID: String, ids: [String]) async throws {
            calls.append("delete")
            for id in ids { records.removeValue(forKey: id) }
        }

        func deleteDocuments(collectionID: String, filter: DocumentFilter) async throws -> Int {
            XCTFail("удалять надо явным списком идентификаторов, а не фильтром")
            return 0
        }
    }

    private let sourceID = UUID()

    private func manifest(chunkIDs: [String]) -> SourceManifest {
        var manifest = SourceManifest(sourceID: sourceID)
        manifest.record(ManifestEntry(
            relativePath: "docs/guide.md", contentHash: "хэш", modifiedAt: Date(), size: 100,
            chunkIDs: chunkIDs, collectionName: "code",
            chunkingSignature: "sig", embeddingModel: "e5"
        ))
        return manifest
    }

    private func seededDatabase(chunks: Int) -> (Database, [String]) {
        let database = Database()
        var ids: [String] = []
        for index in 0..<chunks {
            let id = SourceSyncService.documentID(relativePath: "docs/guide.md", chunkIndex: index)
            ids.append(id)
            database.seed(EmbeddedRecord(
                id: id, document: "кусок \(index)",
                embedding: [Double(index), 0.5, 0.25],
                metadata: [
                    "source_file": .string("docs/guide.md"),
                    "git_relative_path": .string("docs/guide.md"),
                    "chunk_index": .int(index),
                ]
            ))
        }
        return (database, ids)
    }

    /// Главное: векторы те же самые. Пересчитать их значило бы заплатить
    /// локальной моделью за то, что файл назвали иначе.
    func testChunksMoveWithTheirVectorsUntouched() async throws {
        let (database, oldIDs) = seededDatabase(chunks: 3)
        var manifest = manifest(chunkIDs: oldIDs)

        let outcome = await GitRenames.apply(
            [(from: "docs/guide.md", to: "docs/manual.md")],
            sourceID: sourceID, manifest: &manifest, chroma: database
        )

        XCTAssertEqual(outcome.moved, 1)
        XCTAssertEqual(outcome.chunks, 3)
        XCTAssertTrue(outcome.failed.isEmpty)

        for index in 0..<3 {
            let newID = SourceSyncService.documentID(relativePath: "docs/manual.md", chunkIndex: index)
            let moved = try XCTUnwrap(database.records[newID])
            XCTAssertEqual(moved.embedding, [Double(index), 0.5, 0.25], "вектор обязан быть тем же самым")
            XCTAssertEqual(moved.document, "кусок \(index)")
            XCTAssertEqual(moved.metadata["source_file"], .string("docs/manual.md"))
            XCTAssertEqual(moved.metadata["git_relative_path"], .string("docs/manual.md"))
        }
        for id in oldIDs { XCTAssertNil(database.records[id], "старые идентификаторы должны уйти") }
    }

    /// Порядок из A6 не переставляется: прочитать, записать новое, удалить
    /// старое. Наоборот — это дыра в базе на время сбоя.
    func testTheOrderIsReadWriteDelete() async throws {
        let (database, oldIDs) = seededDatabase(chunks: 2)
        var manifest = manifest(chunkIDs: oldIDs)

        _ = await GitRenames.apply(
            [(from: "docs/guide.md", to: "docs/manual.md")],
            sourceID: sourceID, manifest: &manifest, chroma: database
        )
        XCTAssertEqual(database.calls, ["documents", "embeddings", "upsert", "delete"])
    }

    func testTheManifestFollowsTheFileToItsNewName() async throws {
        let (database, oldIDs) = seededDatabase(chunks: 2)
        var manifest = manifest(chunkIDs: oldIDs)

        _ = await GitRenames.apply(
            [(from: "docs/guide.md", to: "docs/manual.md")],
            sourceID: sourceID, manifest: &manifest, chroma: database
        )

        XCTAssertNil(manifest.entries["docs/guide.md"])
        let entry = try XCTUnwrap(manifest.entries["docs/manual.md"])
        XCTAssertEqual(entry.contentHash, "хэш", "текст не менялся — хэш тоже")
        XCTAssertEqual(
            entry.chunkIDs,
            (0..<2).map { SourceSyncService.documentID(relativePath: "docs/manual.md", chunkIndex: $0) }
        )
    }

    /// Не получилось перенести — файл просто проиндексируется заново. Дороже,
    /// но не неправильно, и старые чанки при этом остаются на месте.
    func testAFailedMoveLeavesTheOldChunksAloneAndSaysSo() async throws {
        let (database, oldIDs) = seededDatabase(chunks: 2)
        database.refusesUpsert = true
        var manifest = manifest(chunkIDs: oldIDs)

        let outcome = await GitRenames.apply(
            [(from: "docs/guide.md", to: "docs/manual.md")],
            sourceID: sourceID, manifest: &manifest, chroma: database
        )

        XCTAssertEqual(outcome.moved, 0)
        XCTAssertEqual(outcome.failed, ["docs/guide.md"])
        for id in oldIDs { XCTAssertNotNil(database.records[id], "неудача не должна ничего стирать") }
        XCTAssertNotNil(manifest.entries["docs/guide.md"])
    }

    /// Иерархический чанкинг ссылается на родителя по идентификатору, а тот
    /// тоже производен от пути: не поправить — и ссылка повиснет.
    func testTheParentLinkIsRewrittenToo() async throws {
        let database = Database()
        let parentID = SourceSyncService.documentID(relativePath: "docs/guide.md", chunkIndex: 0)
        let childID = SourceSyncService.documentID(relativePath: "docs/guide.md", chunkIndex: 1)
        database.seed(EmbeddedRecord(
            id: parentID, document: "родитель", embedding: [1, 0],
            metadata: ["source_file": .string("docs/guide.md"), "chunk_index": .int(0)]
        ))
        database.seed(EmbeddedRecord(
            id: childID, document: "ребёнок", embedding: [0, 1],
            metadata: [
                "source_file": .string("docs/guide.md"), "chunk_index": .int(1),
                "parent_chunk_id": .string(parentID),
            ]
        ))
        var manifest = manifest(chunkIDs: [parentID, childID])

        _ = await GitRenames.apply(
            [(from: "docs/guide.md", to: "docs/manual.md")],
            sourceID: sourceID, manifest: &manifest, chroma: database
        )

        let newChildID = SourceSyncService.documentID(relativePath: "docs/manual.md", chunkIndex: 1)
        let newParentID = SourceSyncService.documentID(relativePath: "docs/manual.md", chunkIndex: 0)
        XCTAssertEqual(database.records[newChildID]?.metadata["parent_chunk_id"], .string(newParentID))
    }
}
