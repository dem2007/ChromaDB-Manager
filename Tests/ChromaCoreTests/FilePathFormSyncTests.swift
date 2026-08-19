import XCTest
@testable import ChromaCore

/// Путь файла пишется в одной форме, а ищется — в любой.
///
/// Файловая система macOS отдаёт имена разложенными: «й» приходит двумя
/// знаками. Swift разницы не видит, поэтому ошибка и жила долго — её видят
/// только те, кто работает с байтами: ChromaDB, JSON и sha256.
final class FilePathFormSyncTests: XCTestCase {
    private func bytes(_ value: String) -> [UInt8] { Array(value.utf8) }

    /// Путь из файловой системы приводится к единой форме на входе.
    func testTheRelativePathIsWrittenInOneForm() {
        let root = URL(fileURLWithPath: "/Volumes/Архив")
        let file = URL(fileURLWithPath: "/Volumes/Архив/Отчёты/Первый/Договор.pdf".decomposedStringWithCanonicalMapping)
        XCTAssertEqual(
            bytes(SourceSyncService.relative(file, to: root)),
            bytes("Отчёты/Первый/Договор.pdf"),
            "иначе разложенный путь уходит в базу и не находится ничем, кроме себя самого"
        )
    }

    /// Идентификатор чанка не зависит от формы записи пути.
    ///
    /// Он собирается из sha256, а тот считает байты: две формы дали бы файлу
    /// два набора чанков — вместо замены прежних появились бы вторые.
    func testTheDocumentIDDoesNotDependOnTheForm() {
        let path = "Отчёты/Первый/Договор.pdf"
        XCTAssertEqual(
            SourceSyncService.documentID(relativePath: path, chunkIndex: 3),
            SourceSyncService.documentID(
                relativePath: path.decomposedStringWithCanonicalMapping, chunkIndex: 3
            )
        )
        let fingerprint = SourceSyncService.fileFingerprint(path)
        XCTAssertEqual(fingerprint.count, 16)
        XCTAssertTrue(
            fingerprint.allSatisfy { $0.isHexDigit && !$0.isUppercase },
            "отпечаток должен быть таким, чтобы его нельзя было перепечатать иначе: \(fingerprint)"
        )
        XCTAssertTrue(SourceSyncService.documentID(relativePath: path, chunkIndex: 3).hasPrefix(fingerprint))
    }

    /// Манифест прежних сборок читается в единой форме — вместе с записями
    /// об исчезнувших файлах и о проблемах.
    func testAnOldManifestIsReadInOneForm() throws {
        let old = "Отчёты/Первый/Договор.pdf".decomposedStringWithCanonicalMapping
        var manifest = SourceManifest(sourceID: UUID())
        manifest.entries[old] = ManifestEntry(
            relativePath: old, contentHash: "hash", modifiedAt: Date(), size: 10,
            chunkIDs: ["id-0"], collectionName: "архив",
            chunkingSignature: "подпись", embeddingModel: "bge-m3"
        )
        manifest.pendingRemovals = [
            PendingRemoval(relativePath: old, collectionName: "архив", chunkIDs: ["id-0"])
        ]
        manifest.problems = [
            FileProblem(relativePath: old, reason: "не прочитан", remedy: .retry)
        ]

        let data = try JSONEncoder().encode(manifest)
        let read = try JSONDecoder().decode(SourceManifest.self, from: data)

        let key = try XCTUnwrap(read.entries.keys.first)
        XCTAssertEqual(bytes(key), bytes("Отчёты/Первый/Договор.pdf"))
        XCTAssertEqual(bytes(read.entries[key]?.relativePath ?? ""), bytes("Отчёты/Первый/Договор.pdf"))
        XCTAssertEqual(bytes(read.pendingRemovals[0].relativePath), bytes("Отчёты/Первый/Договор.pdf"))
        XCTAssertEqual(bytes(read.problems[0].relativePath), bytes("Отчёты/Первый/Договор.pdf"))
    }

    /// База, которая узнаёт файл только по той форме, в какой он в ней лежит.
    private actor OldFormDatabase: SyncDatabase {
        let stored: String
        var asked: [String] = []
        init(stored: String) { self.stored = stored }

        func createCollection(name: String, metadata: ChromaMetadata?, configuration: CollectionConfiguration?, getOrCreate: Bool) async throws -> ChromaCollection {
            ChromaCollection(id: "id-\(name)", name: name, metadata: nil)
        }
        func resolveID(of name: String) async throws -> String { "id-\(name)" }
        func updateCollection(id: String, newName: String?, metadata: ChromaMetadata?) async throws {}
        func upsert(collectionID: String, records: [EmbeddedRecord]) async throws {}
        func updateDocuments(collectionID: String, updates: [DocumentUpdate]) async throws {}
        func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord] { [] }
        func embeddings(collectionID: String, ids: [String]) async throws -> [String: [Double]] { [:] }
        func deleteDocuments(collectionID: String, ids: [String]) async throws {}
        func deleteDocuments(collectionID: String, filter: DocumentFilter) async throws -> Int {
            guard let condition = filter.conditions.first(where: { $0.field == "source_file" }) else { return 0 }
            asked.append(condition.value)
            return Array(condition.value.utf8) == Array(stored.utf8) ? 3 : 0
        }
    }

    /// Чанки, записанные прежними сборками в разложенной форме, удаляются:
    /// иначе файл исчезает с диска, человек велит убрать его из базы, а
    /// приложение отчитывается «удалено 0» и оставляет чанки навсегда.
    func testChunksWrittenInTheOldFormAreStillDeleted() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-form-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manifests = ManifestStore(directory: root.appendingPathComponent("manifests"))
        let service = SourceSyncService(
            manifests: manifests, journal: SyncJournal(directory: root.appendingPathComponent("journals"))
        )
        let source = DataSource(
            name: "Архив", path: root.path, mapping: .singleCollectionWithRelativePath,
            collectionName: "архив"
        )
        let path = "Отчёты/Первый/Договор.pdf"
        let database = OldFormDatabase(stored: path.decomposedStringWithCanonicalMapping)

        let deleted = try await service.resolve(
            removal: PendingRemoval(relativePath: path, collectionName: "архив", chunkIDs: []),
            decision: .deleteChunks,
            source: source,
            chroma: database
        )
        XCTAssertEqual(deleted, 3, "чанки лежат в базе в прежней форме записи — их надо найти")
        let asked = await database.asked
        XCTAssertEqual(bytes(asked.first ?? ""), bytes(path), "спрашиваем сначала каноничной формой")
        XCTAssertGreaterThan(asked.count, 1, "и только на промахе пробуем остальные")
    }
}
