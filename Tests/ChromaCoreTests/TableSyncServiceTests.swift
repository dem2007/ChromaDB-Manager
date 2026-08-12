import XCTest
@testable import ChromaCore

/// end to end: a table file becomes documents, and the second run costs
/// almost nothing.
final class TableSyncServiceTests: XCTestCase {
    // MARK: - Fakes

    private final class FakeDatabase: SyncDatabase, @unchecked Sendable {
        var documents: [String: EmbeddedRecord] = [:]
        var metadataUpdates: [DocumentUpdate] = []
        var deleted: [String] = []
        var upsertCalls = 0

        func createCollection(name: String, metadata: ChromaMetadata?, configuration: CollectionConfiguration?, getOrCreate: Bool) async throws -> ChromaCollection {
            ChromaCollection(id: "col", name: name, metadata: metadata, dimension: nil, tenant: nil, database: nil)
        }
        func resolveID(of name: String) async throws -> String { "col" }
        func updateCollection(id: String, newName: String?, metadata: ChromaMetadata?) async throws {}
        func upsert(collectionID: String, records: [EmbeddedRecord]) async throws {
            upsertCalls += 1
            for record in records { documents[record.id] = record }
        }
        func updateDocuments(collectionID: String, updates: [DocumentUpdate]) async throws {
            metadataUpdates += updates
            for update in updates {
                guard let existing = documents[update.id], let metadata = update.metadata else { continue }
                documents[update.id] = EmbeddedRecord(
                    id: existing.id, document: existing.document,
                    embedding: existing.embedding, metadata: metadata
                )
            }
        }
        /// Переносом чанков при переименовании этот стенд не занимается.
        func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord] { [] }
        func embeddings(collectionID: String, ids: [String]) async throws -> [String: [Double]] { [:] }

        func deleteDocuments(collectionID: String, ids: [String]) async throws {
            deleted += ids
            for id in ids { documents[id] = nil }
        }
        func deleteDocuments(collectionID: String, filter: DocumentFilter) async throws -> Int {
            XCTFail("удаление по условию запрещено — только явным списком")
            return 0
        }
    }

    private struct FakeEmbeddings: EmbeddingProvider {
        final class Counter: @unchecked Sendable { var texts = 0 }
        let counter = Counter()
        func embed(texts: [String], model: String) async throws -> [[Double]] {
            counter.texts += texts.count
            return texts.map { text in [Double(text.count), 1, 2, 3] }
        }
        func embed(text: String, model: String) async throws -> [Double] {
            try await embed(texts: [text], model: model)[0]
        }
    }

    // MARK: - Fixtures

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-tsync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let sourceID = UUID(uuidString: "00000000-0000-0000-0000-0000000000CC")!
    private let columns = ["Артикул", "Название", "Цена"]

    private func profile(mode: SheetMode = .dataTable) -> TableProfile {
        TableProfile(
            name: "Каталог",
            mapping: TableMapping(
                sheetName: "Каталог", mode: mode, headerRow: 1, columns: columns,
                roles: ["Артикул": .metadata, "Название": .text, "Цена": .metadata],
                keyColumn: "Артикул"
            )
        )
    }

    private func context(profiles: [TableProfile], rowLimit: Int? = nil) -> TableSyncService.Context {
        TableSyncService.Context(
            sourceID: sourceID, relativePath: "прайс.xlsx", collectionID: "col",
            collectionName: "catalogue", embeddingModel: "m", dimension: 4,
            profiles: profiles, rowLimit: rowLimit
        )
    }

    private func workbook(_ items: [(String, String, Double)], sheet: String = "Каталог", extraSheet: XLSXFixtureBuilder.Sheet? = nil) throws -> URL {
        var builder = XLSXFixtureBuilder()
        var rows: [[XLSXFixtureBuilder.Cell]] = [[.shared("Артикул"), .shared("Название"), .shared("Цена")]]
        for item in items { rows.append([.shared(item.0), .shared(item.1), .number(item.2)]) }
        builder.sheets = [.init(name: sheet, rows: rows)]
        if let extraSheet { builder.sheets.append(extraSheet) }

        let url = root.appendingPathComponent("прайс.xlsx")
        try builder.build().write(to: url)
        return url
    }

    @discardableResult
    private func run(
        _ url: URL,
        manifest: inout TableFileManifest,
        profiles: [TableProfile],
        database: FakeDatabase,
        embeddings: FakeEmbeddings,
        rowLimit: Int? = nil
    ) async throws -> TableSyncReport {
        let sheets = try await TableSyncService.read(url: url).sheets
        return try await TableSyncService().sync(
            sheets: sheets, manifest: &manifest, context: context(profiles: profiles, rowLimit: rowLimit),
            chroma: database, embeddings: embeddings
        )
    }

    // MARK: - The first run

    func testARowBecomesADocument() async throws {
        let url = try workbook([("A-1", "Болт", 12), ("A-2", "Гайка", 8)])
        var manifest = TableFileManifest(relativePath: "прайс.xlsx", collectionName: "catalogue")
        let database = FakeDatabase()
        let embeddings = FakeEmbeddings()

        let report = try await run(url, manifest: &manifest, profiles: [profile()], database: database, embeddings: embeddings)

        XCTAssertEqual(report.rowsAdded, 2)
        XCTAssertEqual(database.documents.count, 2)
        XCTAssertEqual(embeddings.counter.texts, 2)

        let bolt = try XCTUnwrap(database.documents.values.first { $0.document.contains("Болт") })
        XCTAssertEqual(bolt.document, "Название: Болт")
        XCTAssertEqual(bolt.metadata["артикул"], .string("A-1"))
        XCTAssertEqual(bolt.metadata["цена"], .int(12))
        XCTAssertEqual(bolt.metadata["sheet_name"], .string("Каталог"))
        XCTAssertEqual(bolt.metadata["row_number"], .int(2))
        XCTAssertEqual(bolt.metadata["row_key"], .string("A-1"))
        XCTAssertEqual(bolt.metadata["table_mode"], .string("dataTable"))
        XCTAssertEqual(bolt.metadata["source_id"], .string(sourceID.uuidString))
        XCTAssertEqual(bolt.metadata[DocumentOrigin.metadataKey], .string("source"))
    }


    /// Отмена слышна на каждом листе, а не только внутри пакетов записи.
    ///
    /// У книги, где почти всё не изменилось, до пакетов дело может не дойти
    /// вовсе — и «Отменить» не действовало до конца файла.
    func testCancellationIsHeardBeforeAnythingIsWritten() async throws {
        let url = try workbook([("A-1", "Болт", 12), ("A-2", "Гайка", 8)])
        let database = FakeDatabase()
        let embeddings = FakeEmbeddings()
        let sheets = try await TableSyncService.read(url: url).sheets
        let prepared = context(profiles: [profile()])

        let task = Task {
            var manifest = TableFileManifest(relativePath: "прайс.xlsx", collectionName: "catalogue")
            return try await TableSyncService().sync(
                sheets: sheets, manifest: &manifest, context: prepared,
                chroma: database, embeddings: embeddings
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("отменённая синхронизация не должна доходить до конца")
        } catch is CancellationError {
            // Именно это и ожидается.
        }
        XCTAssertTrue(database.documents.isEmpty, "в базу не должно уйти ничего")
        XCTAssertEqual(embeddings.counter.texts, 0, "и модель не должна считать векторы")
    }

    // MARK: - The second run

    func testAnUnchangedFileWritesNothing() async throws {
        let url = try workbook([("A-1", "Болт", 12), ("A-2", "Гайка", 8)])
        var manifest = TableFileManifest(relativePath: "прайс.xlsx", collectionName: "catalogue")
        let database = FakeDatabase()
        let embeddings = FakeEmbeddings()

        try await run(url, manifest: &manifest, profiles: [profile()], database: database, embeddings: embeddings)
        let after = embeddings.counter.texts
        let report = try await run(url, manifest: &manifest, profiles: [profile()], database: database, embeddings: embeddings)

        XCTAssertEqual(report.rowsUnchanged, 2)
        XCTAssertEqual(report.rowsWritten, 0)
        XCTAssertEqual(embeddings.counter.texts, after, "второй прогон не должен обращаться к модели")
    }

    func testEditingOneRowReembedsOnlyIt() async throws {
        let url = try workbook([("A-1", "Болт", 12), ("A-2", "Гайка", 8)])
        var manifest = TableFileManifest(relativePath: "прайс.xlsx", collectionName: "catalogue")
        let database = FakeDatabase()
        let embeddings = FakeEmbeddings()
        try await run(url, manifest: &manifest, profiles: [profile()], database: database, embeddings: embeddings)
        let before = embeddings.counter.texts

        let edited = try workbook([("A-1", "Болт М8", 12), ("A-2", "Гайка", 8)])
        let report = try await run(edited, manifest: &manifest, profiles: [profile()], database: database, embeddings: embeddings)

        XCTAssertEqual(report.rowsReembedded, 1)
        XCTAssertEqual(report.rowsUnchanged, 1)
        XCTAssertEqual(embeddings.counter.texts - before, 1)
        XCTAssertTrue(database.documents.values.contains { $0.document == "Название: Болт М8" })
    }

    /// a changed price costs a write, not a vector — and the vector that
    /// was there must survive, which an upsert with an empty embedding would not
    /// have allowed.
    func testAChangedPriceUpdatesMetadataAndKeepsTheVector() async throws {
        let url = try workbook([("A-1", "Болт", 12)])
        var manifest = TableFileManifest(relativePath: "прайс.xlsx", collectionName: "catalogue")
        let database = FakeDatabase()
        let embeddings = FakeEmbeddings()
        try await run(url, manifest: &manifest, profiles: [profile()], database: database, embeddings: embeddings)

        let id = try XCTUnwrap(database.documents.keys.first)
        let vector = try XCTUnwrap(database.documents[id]?.embedding)
        let before = embeddings.counter.texts

        let repriced = try workbook([("A-1", "Болт", 15)])
        let report = try await run(repriced, manifest: &manifest, profiles: [profile()], database: database, embeddings: embeddings)

        XCTAssertEqual(report.rowsMetadataOnly, 1)
        XCTAssertEqual(report.rowsReembedded, 0)
        XCTAssertEqual(embeddings.counter.texts, before, "к модели обращаться незачем")
        XCTAssertEqual(database.metadataUpdates.count, 1)
        XCTAssertEqual(database.documents[id]?.embedding, vector, "вектор должен остаться на месте")
        XCTAssertEqual(database.documents[id]?.metadata["цена"], .int(15))
    }

    // MARK: - Rows that went away

    /// Rule 1 of Приложение 5: nothing is deleted automatically, not even a row.
    func testADisappearedRowIsReportedNotDeleted() async throws {
        let url = try workbook([("A-1", "Болт", 12), ("A-2", "Гайка", 8)])
        var manifest = TableFileManifest(relativePath: "прайс.xlsx", collectionName: "catalogue")
        let database = FakeDatabase()
        let embeddings = FakeEmbeddings()
        try await run(url, manifest: &manifest, profiles: [profile()], database: database, embeddings: embeddings)

        let shorter = try workbook([("A-1", "Болт", 12)])
        let report = try await run(shorter, manifest: &manifest, profiles: [profile()], database: database, embeddings: embeddings)

        XCTAssertEqual(report.disappeared.map(\.rowKey), ["A-2"])
        XCTAssertEqual(database.documents.count, 2, "документ исчезнувшей строки остаётся до решения")
        XCTAssertTrue(database.deleted.isEmpty)
    }

    // MARK: - Sheets nobody mapped

    /// a sheet whose columns match no profile is not indexed «как
    /// получится» — it is reported with the difference.
    func testASheetWithUnknownColumnsIsReportedRatherThanGuessed() async throws {
        let other = XLSXFixtureBuilder.Sheet(name: "Контакты", rows: [
            [.shared("Email"), .shared("Телефон")],
            [.shared("a@b.c"), .shared("+7")],
        ])
        let url = try workbook([("A-1", "Болт", 12)], extraSheet: other)
        var manifest = TableFileManifest(relativePath: "прайс.xlsx", collectionName: "catalogue")
        let database = FakeDatabase()

        let report = try await run(url, manifest: &manifest, profiles: [profile()], database: database, embeddings: FakeEmbeddings())

        XCTAssertEqual(report.sheetsIndexed, ["Каталог"])
        XCTAssertEqual(report.problems.map(\.sheetName), ["Контакты"])
        XCTAssertTrue(report.problems[0].reason.contains("Email"), report.problems[0].reason)
        XCTAssertEqual(database.documents.count, 1, "непонятый лист не должен ничего записать")
    }

    /// назначение профиля вручную **не** отменяет правило
    ///
    /// Самое опасное, что могло бы дать назначение: «я сказал читать этим
    /// профилем» — и лист читается им наполовину, а колонки, которых в файле
    /// нет, молча становятся пустыми метаданными. Обнаруживается это не при
    /// индексации, а недели спустя, пустым результатом чужого фильтра.
    func testAnAssignedProfileStillCannotReadColumnsThatAreNotThere() async throws {
        let url = try workbook([("A-1", "Болт", 12)])
        var manifest = TableFileManifest(relativePath: "прайс.xlsx", collectionName: "catalogue")
        let database = FakeDatabase()

        // Профиль про другую таблицу — и он же назначен этому файлу.
        let foreign = TableProfile(name: "Контакты", mapping: TableMapping(
            sheetName: "Контакты", mode: .dataTable, headerRow: 1,
            columns: ["Email", "Телефон"],
            roles: ["Email": .metadata, "Телефон": .metadata], keyColumn: "Email"
        ))
        let sheets = try await TableSyncService.read(url: url).sheets
        let report = try await TableSyncService().sync(
            sheets: sheets, manifest: &manifest,
            context: TableSyncService.Context(
                sourceID: sourceID, relativePath: "прайс.xlsx", collectionID: "col",
                collectionName: "catalogue", embeddingModel: "m", dimension: 4,
                profiles: [foreign], assignedProfileID: foreign.id
            ),
            chroma: database, embeddings: FakeEmbeddings()
        )

        XCTAssertEqual(report.problems.map(\.sheetName), ["Каталог"])
        XCTAssertTrue(report.problems[0].reason.contains("Email"), report.problems[0].reason)
        XCTAssertEqual(database.documents.count, 0, "ни одной строки записать не должно")
    }

    /// А назначенный по делу профиль работает там, где подбор бы не справился.
    func testAnAssignedProfileReadsAFileWhoseHeaderIsNotOnTheFirstRow() async throws {
        var builder = XLSXFixtureBuilder()
        builder.sheets = [.init(name: "Каталог", rows: [
            [.shared("Отчёт за март")],
            [],
            [.shared("Артикул"), .shared("Название"), .shared("Цена")],
            [.shared("A-1"), .shared("Болт"), .number(12)],
        ])]
        let url = root.appendingPathComponent("отчёт.xlsx")
        try builder.build().write(to: url)

        var manifest = TableFileManifest(relativePath: "отчёт.xlsx", collectionName: "catalogue")
        let database = FakeDatabase()
        let assigned = TableProfile(name: "Мартовский", mapping: TableMapping(
            sheetName: "Каталог", mode: .dataTable, headerRow: 3, columns: columns,
            roles: ["Артикул": .metadata, "Название": .text, "Цена": .metadata],
            keyColumn: "Артикул"
        ))

        let sheets = try await TableSyncService.read(url: url).sheets
        let report = try await TableSyncService().sync(
            sheets: sheets, manifest: &manifest,
            context: TableSyncService.Context(
                sourceID: sourceID, relativePath: "отчёт.xlsx", collectionID: "col",
                collectionName: "catalogue", embeddingModel: "m", dimension: 4,
                profiles: [assigned], assignedProfileID: assigned.id
            ),
            chroma: database, embeddings: FakeEmbeddings()
        )

        XCTAssertEqual(report.sheetsIndexed, ["Каталог"])
        XCTAssertEqual(report.rowsAdded, 1, "строка под шапкой отчёта — единственная запись")
        XCTAssertTrue(report.problems.isEmpty, "\(report.problems)")
    }

    /// A hidden sheet the detector calls «не индексировать» is an answer, not a
    /// problem: it must not fill the decisions list with noise.
    func testAHiddenSheetIsSkippedQuietly() async throws {
        let hidden = XLSXFixtureBuilder.Sheet(name: "Служебный", isHidden: true, rows: [
            [.shared("Ключ"), .shared("Значение")],
            [.shared("k"), .number(1)],
        ])
        let url = try workbook([("A-1", "Болт", 12)], extraSheet: hidden)
        var manifest = TableFileManifest(relativePath: "прайс.xlsx", collectionName: "catalogue")

        let report = try await run(url, manifest: &manifest, profiles: [profile()], database: FakeDatabase(), embeddings: FakeEmbeddings())
        XCTAssertEqual(report.sheetsIndexed, ["Каталог"])
        XCTAssertTrue(report.problems.isEmpty)
    }

    // MARK: - A changed mapping

    /// a different recipe for every row is a re-index with a backup,
    /// offered — so the sheet is left exactly as it was.
    func testAChangedMappingStopsAndAsks() async throws {
        let url = try workbook([("A-1", "Болт", 12)])
        var manifest = TableFileManifest(relativePath: "прайс.xlsx", collectionName: "catalogue")
        let database = FakeDatabase()
        let embeddings = FakeEmbeddings()
        try await run(url, manifest: &manifest, profiles: [profile()], database: database, embeddings: embeddings)
        let before = embeddings.counter.texts

        var changed = profile()
        changed.variants[0].mapping.textTemplate = "{Название} — {Цена}"
        let report = try await run(url, manifest: &manifest, profiles: [changed], database: database, embeddings: embeddings)

        XCTAssertEqual(report.sheetsNeedingReindex, ["Каталог"])
        XCTAssertEqual(report.rowsWritten, 0)
        XCTAssertEqual(embeddings.counter.texts, before, "переиндексация запускается пользователем, а не сама")
    }

    // MARK: - A sample run

    /// trying the first rows must write only those rows.
    func testASampleRunWritesOnlyTheFirstRows() async throws {
        let url = try workbook([("A-1", "Болт", 12), ("A-2", "Гайка", 8), ("A-3", "Шайба", 3)])
        var manifest = TableFileManifest(relativePath: "прайс.xlsx", collectionName: "catalogue")
        let database = FakeDatabase()

        let report = try await run(url, manifest: &manifest, profiles: [profile()], database: database, embeddings: FakeEmbeddings(), rowLimit: 2)
        XCTAssertEqual(report.rowsAdded, 2)
        XCTAssertEqual(database.documents.count, 2)
    }

    // MARK: - Formats

    /// Every format supports arrives at the same pipeline.
    func testACSVGoesThroughTheSamePipeline() async throws {
        let url = root.appendingPathComponent("прайс.csv")
        try "Артикул;Название;Цена\nA-1;Болт;12\n".write(to: url, atomically: true, encoding: .utf8)

        var manifest = TableFileManifest(relativePath: "прайс.csv", collectionName: "catalogue")
        let database = FakeDatabase()
        var csvProfile = profile()
        csvProfile.variants[0].mapping.sheetName = "прайс"

        let sheets = try await TableSyncService.read(url: url).sheets
        XCTAssertEqual(sheets.count, 1)
        let report = try await TableSyncService().sync(
            sheets: sheets, manifest: &manifest,
            context: TableSyncService.Context(
                sourceID: sourceID, relativePath: "прайс.csv", collectionID: "col",
                collectionName: "catalogue", embeddingModel: "m", dimension: 4, profiles: [csvProfile]
            ),
            chroma: database, embeddings: FakeEmbeddings()
        )
        XCTAssertEqual(report.rowsAdded, 1)
        XCTAssertEqual(database.documents.values.first?.metadata["цена"], .int(12))
    }

    /// то, что не читается, названо и объяснено, а не прочитано наполовину.
    func testALegacyBinaryFileIsRefusedWithItsHint() async throws {
        let url = root.appendingPathComponent("двоичный.xlsb")
        try Data("BIFF".utf8).write(to: url)

        await XCTAssertThrowsErrorAsync(try await TableSyncService.read(url: url)) { error in
            XCTAssertEqual(error as? TabularError, .legacyBinaryFormat("xlsb"))
        }
    }

    /// `.xls` идёт путём экспорта через приложение — и с выключенным
    /// экспортом отказывает по этой причине, а не по причине «формат не
    /// поддерживается».
    func testALegacyExcelFileGoesThroughTheApplicationExport() async throws {
        let url = root.appendingPathComponent("старый.xls")
        try Data("BIFF".utf8).write(to: url)

        await XCTAssertThrowsErrorAsync(
            try await TableSyncService.read(url: url, allowApplicationExport: false)
        ) { error in
            XCTAssertNil(error as? TabularError, "это не отказ по формату")
            XCTAssertTrue(
                error.localizedDescription.contains("выключен"),
                error.localizedDescription
            )
        }
    }
}

// MARK: - Persistence and statistics

final class TableManifestStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-tstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func manifest(_ path: String, sheets: [String: Int]) -> TableFileManifest {
        var file = TableFileManifest(relativePath: path, collectionName: "catalogue")
        for (name, count) in sheets {
            var sheet = SheetManifest(sheetName: name)
            for index in 0..<count {
                let record = TableRowRecord(
                    documentID: "\(path)-\(name)-\(index)", rowNumber: index + 2,
                    rowKey: "k\(index)", textHash: "t", metadataHash: "m"
                )
                sheet.rows[record.identity] = record
            }
            file.sheets[name] = sheet
        }
        return file
    }

    func testManifestsSurviveARoundTrip() {
        let store = TableManifestStore(directory: root)
        let sourceID = UUID()
        store.save(["прайс.xlsx": manifest("прайс.xlsx", sheets: ["Каталог": 3])], sourceID: sourceID)

        let loaded = store.load(sourceID: sourceID)
        XCTAssertEqual(loaded["прайс.xlsx"]?.rowCount, 3)
        XCTAssertEqual(loaded["прайс.xlsx"]?.sheets["Каталог"]?.rowCount, 3)
    }

    func testAMissingManifestIsEmptyNotAnError() {
        XCTAssertTrue(TableManifestStore(directory: root).load(sourceID: UUID()).isEmpty)
    }

    /// «сколько строк из каких таблиц проиндексировано» — per sheet,
    /// because one workbook routinely holds a catalogue and a reference table.
    func testStatisticsCountRowsPerSheet() {
        let store = TableManifestStore(directory: root)
        let sourceID = UUID()
        store.save([
            "прайс.xlsx": manifest("прайс.xlsx", sheets: ["Каталог": 12, "Справочник": 4]),
            "контакты.csv": manifest("контакты.csv", sheets: ["контакты": 7]),
        ], sourceID: sourceID)

        let rows = store.statistics(sourceID: sourceID, sourceName: "Прайсы")
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.relativePath), ["контакты.csv", "прайс.xlsx", "прайс.xlsx"])
        XCTAssertEqual(rows.first { $0.sheetName == "Каталог" }?.rows, 12)
        XCTAssertEqual(rows.first { $0.sheetName == "Справочник" }?.rows, 4)
        XCTAssertTrue(rows.allSatisfy { $0.sourceName == "Прайсы" })
    }
}

// MARK: - Document mode

/// A sheet that is a report, not a set of records: rendered to text, cut by the
/// source's strategy, and — the part calls compulsory — the header
/// repeated in every chunk.
final class DocumentSheetTests: XCTestCase {
    private final class Database: SyncDatabase, @unchecked Sendable {
        var documents: [String: EmbeddedRecord] = [:]
        var deleted: [String] = []
        func createCollection(name: String, metadata: ChromaMetadata?, configuration: CollectionConfiguration?, getOrCreate: Bool) async throws -> ChromaCollection {
            ChromaCollection(id: "col", name: name, metadata: nil, dimension: nil, tenant: nil, database: nil)
        }
        func resolveID(of name: String) async throws -> String { "col" }
        func updateCollection(id: String, newName: String?, metadata: ChromaMetadata?) async throws {}
        func upsert(collectionID: String, records: [EmbeddedRecord]) async throws {
            for record in records { documents[record.id] = record }
        }
        func updateDocuments(collectionID: String, updates: [DocumentUpdate]) async throws {}
        /// Переносом чанков при переименовании этот стенд не занимается.
        func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord] { [] }
        func embeddings(collectionID: String, ids: [String]) async throws -> [String: [Double]] { [:] }

        func deleteDocuments(collectionID: String, ids: [String]) async throws {
            deleted += ids
            for id in ids { documents[id] = nil }
        }
        func deleteDocuments(collectionID: String, filter: DocumentFilter) async throws -> Int {
            XCTFail("удаление по условию запрещено")
            return 0
        }
    }

    private struct Embeddings: EmbeddingProvider {
        func embed(texts: [String], model: String) async throws -> [[Double]] {
            texts.map { _ in [1, 2, 3, 4] }
        }
        func embed(text: String, model: String) async throws -> [Double] { [1, 2, 3, 4] }
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-doc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func report(rows: Int) throws -> URL {
        var builder = XLSXFixtureBuilder()
        var grid: [[XLSXFixtureBuilder.Cell]] = [[.shared("Показатель"), .shared("Значение"), .shared("Комментарий")]]
        for index in 0..<rows {
            grid.append([.shared("Строка \(index)"), .number(Double(index)), .shared("примечание \(index)")])
        }
        builder.sheets = [.init(name: "Отчёт", rows: grid)]
        let url = root.appendingPathComponent("отчёт.xlsx")
        try builder.build().write(to: url)
        return url
    }

    private func profile() -> TableProfile {
        TableProfile(
            name: "Отчёт",
            mapping: TableMapping(
                sheetName: "Отчёт", mode: .document, headerRow: 1,
                columns: ["Показатель", "Значение", "Комментарий"],
                roles: [:]
            )
        )
    }

    /// Cut small enough that the sheet really does become several chunks.
    private func chunker(_ size: Int) -> @Sendable (String) async throws -> [TextChunk] {
        { text in
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            return stride(from: 0, to: lines.count, by: size).enumerated().map { index, start in
                TextChunk(index: index, text: lines[start..<min(start + size, lines.count)].joined(separator: "\n"))
            }
        }
    }

    private func run(_ url: URL, manifest: inout TableFileManifest, database: Database, chunkLines: Int = 4) async throws -> TableSyncReport {
        let sheets = try await TableSyncService.read(url: url).sheets
        return try await TableSyncService().sync(
            sheets: sheets, manifest: &manifest,
            context: TableSyncService.Context(
                sourceID: UUID(uuidString: "00000000-0000-0000-0000-0000000000DD")!,
                relativePath: "отчёт.xlsx", collectionID: "col", collectionName: "reports",
                embeddingModel: "m", dimension: 4, profiles: [profile()],
                chunker: chunker(chunkLines)
            ),
            chroma: database, embeddings: Embeddings()
        )
    }

    /// The rule calls compulsory: without the header, the second chunk is
    /// a grid of values with no column names.
    func testEveryChunkCarriesTheHeaderRow() async throws {
        let url = try report(rows: 12)
        var manifest = TableFileManifest(relativePath: "отчёт.xlsx", collectionName: "reports")
        let database = Database()

        let result = try await run(url, manifest: &manifest, database: database)
        XCTAssertEqual(result.sheetsIndexed, ["Отчёт"])
        XCTAssertGreaterThan(database.documents.count, 1, "лист должен разбиться на несколько чанков")

        let header = "| Показатель | Значение | Комментарий |"
        XCTAssertTrue(database.documents.values.allSatisfy { $0.document.hasPrefix(header) })
        XCTAssertTrue(database.documents.values.allSatisfy { $0.metadata["table_mode"] == .string("document") })
    }

    func testRowsAreNotDocumentsInThisMode() async throws {
        let url = try report(rows: 12)
        var manifest = TableFileManifest(relativePath: "отчёт.xlsx", collectionName: "reports")
        let database = Database()
        try await run(url, manifest: &manifest, database: database)

        XCTAssertLessThan(database.documents.count, 12, "12 строк не должны стать 12 документами")
        XCTAssertTrue(database.documents.values.allSatisfy { $0.metadata["row_key"] == nil })
    }

    /// The same incrementality as rows: an unchanged sheet costs nothing.
    func testAnUnchangedSheetIsNotRewritten() async throws {
        let url = try report(rows: 12)
        var manifest = TableFileManifest(relativePath: "отчёт.xlsx", collectionName: "reports")
        let database = Database()
        let first = try await run(url, manifest: &manifest, database: database)
        let second = try await run(url, manifest: &manifest, database: database)

        XCTAssertGreaterThan(first.rowsAdded, 0)
        XCTAssertEqual(second.rowsAdded, 0)
        XCTAssertEqual(second.rowsReembedded, 0)
        XCTAssertEqual(second.rowsUnchanged, first.rowsAdded)
    }

    /// A sheet that got shorter leaves chunks nothing refers to — removed by
    /// explicit id, after the new ones are written.
    func testAShorterSheetLosesItsTailByIdentifier() async throws {
        var manifest = TableFileManifest(relativePath: "отчёт.xlsx", collectionName: "reports")
        let database = Database()
        try await run(try report(rows: 40), manifest: &manifest, database: database)
        let before = database.documents.count

        try await run(try report(rows: 4), manifest: &manifest, database: database)
        XCTAssertLessThan(database.documents.count, before)
        XCTAssertFalse(database.deleted.isEmpty)
    }

    // MARK: - Свои названия колонок

    /// Переименование меняет ключ в метаданных: имя из файла уезжает в базу
    /// и остаётся там навсегда, а «Столбец 3» фильтровать нечем.
    func testARenamedColumnUsesTheChosenNameAsTheMetadataKey() {
        var mapping = TableMapping(
            sheetName: "Лист1",
            columns: ["Столбец 3", "Цена"],
            roles: ["Столбец 3": .metadata, "Цена": .metadata]
        )
        XCTAssertEqual(mapping.title(of: "Столбец 3"), "Столбец 3", "без переименования — заголовок из файла")

        mapping.titles = ["Столбец 3": "Группа ПО"]
        XCTAssertEqual(mapping.title(of: "Столбец 3"), "Группа ПО")
        XCTAssertNotNil(mapping.keyMap.key(for: "Группа ПО"))
        XCTAssertNil(mapping.keyMap.key(for: "Столбец 3"), "ключ считается по выбранному имени")
    }

    /// Пустое имя — это «оставить как в файле», а не «без названия».
    func testAnEmptyCustomNameFallsBackToTheFileHeader() {
        var mapping = TableMapping(sheetName: "Лист1", columns: ["Цена"])
        mapping.titles = ["Цена": "   "]
        XCTAssertEqual(mapping.title(of: "Цена"), "Цена")
    }

    /// В шаблоне работают оба имени — иначе профиль, в котором колонку только
    /// что переименовали, нельзя было бы сохранить: своё имя объявлялось бы
    /// опечаткой, а проверка шаблона запрещает сохранение.
    func testATemplateMayUseEitherName() {
        var mapping = TableMapping(sheetName: "Лист1", columns: ["Столбец 3", "Цена"])
        mapping.titles = ["Столбец 3": "Группа ПО"]

        XCTAssertEqual(
            RowMapper.unknownPlaceholders(in: "{Группа ПО} — {Цена}", mapping: mapping), [],
            "своё название колонки опечаткой не является"
        )
        XCTAssertEqual(
            RowMapper.unknownPlaceholders(in: "{Столбец 3}", mapping: mapping), [],
            "заголовок из файла продолжает работать — уже написанные шаблоны не ломаются"
        )
        XCTAssertEqual(
            RowMapper.unknownPlaceholders(in: "{Группа ПА}", mapping: mapping), ["Группа ПА"],
            "настоящая опечатка по-прежнему видна"
        )
    }

    /// Переименование — смена рецепта строки: меняются и ключ метаданных,
    /// и подпись в тексте. Без этого половина коллекции осталась бы с ключом
    /// `stolbec_3`, половина — с `gruppa_po`, и фильтр находил бы то одну.
    func testRenamingAColumnChangesTheMappingSignature() {
        var mapping = TableMapping(sheetName: "Лист1", columns: ["Столбец 3", "Цена"])
        let before = mapping.signature
        mapping.titles = ["Столбец 3": "Группа ПО"]
        XCTAssertNotEqual(mapping.signature, before)
    }

    /// А сопоставление без переименований обязано дать ту же подпись, что
    /// и раньше: иначе все уже проиндексированные листы разом попросили бы
    /// переиндексацию — ни за что.
    func testAMappingWithoutRenamesKeepsItsOldSignature() {
        var mapping = TableMapping(
            sheetName: "Лист1", mode: .dataTable, headerRow: 1,
            columns: ["Артикул", "Цена"],
            roles: ["Артикул": .metadata, "Цена": .metadata],
            keyColumn: "Артикул"
        )
        mapping.titles = ["Артикул": "", "Цена": "   "]
        XCTAssertEqual(
            mapping.signature,
            "mode:dataTable;header:1;columns:Артикул|Цена;roles:Артикул=metadata,Цена=metadata;key:Артикул;template:"
        )
    }
}
