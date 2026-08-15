import XCTest
@testable import ChromaCore

/// исчезнувшие строки таблиц можно наконец разобрать.
///
/// До этого механизм был посчитан целиком — `disappeared`, `removalIDs` — и
/// не подключён: `removalIDs` не звали нигде, отчёт таблиц собирался
/// в переменную, которую никто не читал. Строка, удалённая из прайса,
/// оставалась в базе навсегда и продолжала находиться поиском.
final class TableRowRemovalTests: XCTestCase {
    private final class FakeDatabase: SyncDatabase, @unchecked Sendable {
        var deletedByID: [String] = []

        func createCollection(name: String, metadata: ChromaMetadata?, configuration: CollectionConfiguration?, getOrCreate: Bool) async throws -> ChromaCollection {
            ChromaCollection(id: "col", name: name, metadata: metadata, dimension: nil, tenant: nil, database: nil)
        }
        func resolveID(of name: String) async throws -> String { "col" }
        func updateCollection(id: String, newName: String?, metadata: ChromaMetadata?) async throws {}
        func upsert(collectionID: String, records: [EmbeddedRecord]) async throws {}
        func updateDocuments(collectionID: String, updates: [DocumentUpdate]) async throws {}
        func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord] { [] }
        func embeddings(collectionID: String, ids: [String]) async throws -> [String: [Double]] { [:] }
        func deleteDocuments(collectionID: String, ids: [String]) async throws { deletedByID += ids }
        func deleteDocuments(collectionID: String, filter: DocumentFilter) async throws -> Int {
            XCTFail("строки удаляются только явным списком id — фильтр забрал бы соседей по номеру")
            return 0
        }
    }

    private var directory: URL!
    private var store: TableManifestStore!
    private var service: SourceSyncService!
    private let source = DataSource(name: "прайсы", path: "/tmp/прайсы", collectionName: "catalogue")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("table-removals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = TableManifestStore(directory: directory)
        service = SourceSyncService(
            manifests: ManifestStore(directory: directory), tableManifests: store
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Манифест, где одна строка листа исчезла и ждёт решения.
    private func seed() -> TableRowRecord {
        let gone = TableRowRecord(
            documentID: "doc-a2", rowNumber: 3, rowKey: "A-2",
            textHash: "t", metadataHash: "m"
        )
        let kept = TableRowRecord(
            documentID: "doc-a1", rowNumber: 2, rowKey: "A-1",
            textHash: "t", metadataHash: "m"
        )
        var sheet = SheetManifest(sheetName: "Каталог")
        sheet.rows[kept.identity] = kept
        sheet.rows[gone.identity] = gone
        var file = TableFileManifest(relativePath: "прайс.xlsx", collectionName: "catalogue")
        file.sheets["Каталог"] = sheet
        file.pendingRemovals["Каталог"] = SheetRowRemoval(rows: [gone])
        store.save(["прайс.xlsx": file], sourceID: source.id)
        return gone
    }

    func testTheListIsReadableFromTheManifest() {
        _ = seed()
        let pending = store.pendingRemovals(sourceID: source.id)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.sheetName, "Каталог")
        XCTAssertEqual(pending.first?.collectionName, "catalogue")
        XCTAssertEqual(pending.first?.rows.map(\.rowKey), ["A-2"])
        XCTAssertEqual(pending.first?.rowLabels, ["строка 3 · A-2"])
    }

    func testDeletingRemovesTheDocumentsAndForgetsTheRows() async throws {
        let gone = seed()
        let database = FakeDatabase()
        let deleted = try await service.resolve(
            rowRemoval: store.pendingRemovals(sourceID: source.id)[0],
            decision: .deleteChunks, source: source, chroma: database
        )

        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(database.deletedByID, ["doc-a2"])
        let after = store.load(sourceID: source.id)["прайс.xlsx"]
        XCTAssertNil(after?.sheets["Каталог"]?.rows[gone.identity], "записи удалённой строки быть не должно")
        XCTAssertEqual(after?.sheets["Каталог"]?.rowCount, 1, "остальные строки не тронуты")
        XCTAssertTrue(after?.pendingRemovals.isEmpty ?? false)
    }

    func testKeepingLeavesTheDocumentsAndStopsAsking() async throws {
        let gone = seed()
        let database = FakeDatabase()
        let deleted = try await service.resolve(
            rowRemoval: store.pendingRemovals(sourceID: source.id)[0],
            decision: .keepInDatabase, source: source, chroma: database
        )

        XCTAssertEqual(deleted, 0)
        XCTAssertTrue(database.deletedByID.isEmpty)
        let after = store.load(sourceID: source.id)["прайс.xlsx"]
        // Запись остаётся — иначе документ в коллекции нечем адресовать.
        XCTAssertEqual(after?.sheets["Каталог"]?.rows[gone.identity]?.isOrphaned, true)
        XCTAssertTrue(after?.pendingRemovals.isEmpty ?? false)
        XCTAssertTrue(store.pendingRemovals(sourceID: source.id).isEmpty)
    }

    func testPostponingChangesNothing() async throws {
        _ = seed()
        let database = FakeDatabase()
        _ = try await service.resolve(
            rowRemoval: store.pendingRemovals(sourceID: source.id)[0],
            decision: .postpone, source: source, chroma: database
        )
        XCTAssertTrue(database.deletedByID.isEmpty)
        XCTAssertEqual(store.pendingRemovals(sourceID: source.id).count, 1)
    }

    /// Манифест прошлых версий читается как есть: списка на решение в нём
    /// не было, и это не повод считать файл повреждённым.
    func testAManifestWithoutTheListStillReads() throws {
        let json = """
        {"прайс.xlsx":{"relativePath":"прайс.xlsx","collectionName":"catalogue",\
        "sheets":{},"modifiedAt":"2026-01-01T00:00:00Z","size":10,"profilesSignature":""}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([String: TableFileManifest].self, from: Data(json.utf8))
        XCTAssertEqual(decoded["прайс.xlsx"]?.pendingRemovals.isEmpty, true)
    }
}
