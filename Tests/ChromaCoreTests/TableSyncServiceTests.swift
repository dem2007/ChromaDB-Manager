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
        /// Как у ChromaDB: `update` метаданные **сливает**, ключ убирает только
        /// явным снятием, а записи с незнакомым идентификатором не создаёт.
        /// Стенд, заменявший метаданные целиком и не отдававший документов,
        /// не видел ни забытых ключей, ни пропадавших строк.
        func updateDocuments(collectionID: String, updates: [DocumentUpdate]) async throws {
            metadataUpdates += updates
            for update in updates {
                guard let existing = documents[update.id], let metadata = update.metadata else { continue }
                var merged = existing.metadata.merging(metadata) { _, new in new }
                for key in update.removedMetadataKeys { merged[key] = nil }
                documents[update.id] = EmbeddedRecord(
                    id: existing.id, document: existing.document,
                    embedding: existing.embedding, metadata: merged
                )
            }
        }
        func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord] {
            ids.compactMap { documents[$0] }.map {
                DocumentRecord(id: $0.id, document: $0.document, metadata: $0.metadata, embeddingDimension: $0.embedding.count)
            }
        }
        func embeddings(collectionID: String, ids: [String]) async throws -> [String: [Double]] {
            ids.reduce(into: [:]) { result, id in result[id] = documents[id]?.embedding }
        }

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

    private func profile(
        mode: SheetMode = .dataTable, keyColumn: String? = "Артикул", columns: [String]? = nil
    ) -> TableProfile {
        let used = columns ?? self.columns
        var roles: [String: ColumnRole] = ["Артикул": .metadata, "Название": .text, "Цена": .metadata]
        for column in used where roles[column] == nil { roles[column] = .metadata }
        return TableProfile(
            name: "Каталог",
            mapping: TableMapping(
                sheetName: "Каталог", mode: mode, headerRow: 1, columns: used,
                roles: roles, keyColumn: keyColumn
            )
        )
    }

    private func context(profiles: [TableProfile], rowLimit: Int? = nil, documentMetadata: ChromaMetadata = [:]) -> TableSyncService.Context {
        TableSyncService.Context(
            sourceID: sourceID, relativePath: "прайс.xlsx", collectionID: "col",
            collectionName: "catalogue", embeddingModel: "m", dimension: 4,
            profiles: profiles, rowLimit: rowLimit, documentMetadata: documentMetadata
        )
    }

    private func workbook(
        _ items: [(String, String, Double)], sheet: String = "Каталог",
        extraSheet: XLSXFixtureBuilder.Sheet? = nil, note: String? = nil
    ) throws -> URL {
        var builder = XLSXFixtureBuilder()
        var header: [XLSXFixtureBuilder.Cell] = [.shared("Артикул"), .shared("Название"), .shared("Цена")]
        if note != nil { header.append(.shared("Примечание")) }
        var rows: [[XLSXFixtureBuilder.Cell]] = [header]
        for item in items {
            var row: [XLSXFixtureBuilder.Cell] = [.shared(item.0), .shared(item.1), .number(item.2)]
            if let note { row.append(.inline(note)) }
            rows.append(row)
        }
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
        rowLimit: Int? = nil,
        documentMetadata: ChromaMetadata = [:]
    ) async throws -> TableSyncReport {
        let sheets = try await TableSyncService.read(url: url).sheets
        return try await TableSyncService().sync(
            sheets: sheets, manifest: &manifest, context: context(profiles: profiles, rowLimit: rowLimit, documentMetadata: documentMetadata),
            chroma: database, embeddings: embeddings
        )
    }

    // MARK: - Поля файла

    /// Строка таблицы несёт поля файла: имя, уровни пути, свои поля
    /// источника. Колонка строки с тем же именем важнее. Правка общих полей
    /// доходит до записанных строк без новых векторов.
    func testARowCarriesTheFieldsOfItsFile() async throws {
        let url = try workbook([("A-1", "Болт", 12), ("A-2", "Гайка", 8)])
        var manifest = TableFileManifest(relativePath: "прайс.xlsx", collectionName: "catalogue")
        let database = FakeDatabase()
        let embeddings = FakeEmbeddings()
        let shared: ChromaMetadata = ["file_name": .string("прайс.xlsx"), "OGV": .string("Ведомство А"), "цена": .int(0)]

        try await run(url, manifest: &manifest, profiles: [profile()], database: database, embeddings: embeddings, documentMetadata: shared)
        let bolt = try XCTUnwrap(database.documents.values.first { $0.document.contains("Болт") })
        XCTAssertEqual(bolt.metadata["file_name"], .string("прайс.xlsx"))
        XCTAssertEqual(bolt.metadata["OGV"], .string("Ведомство А"))
        XCTAssertEqual(bolt.metadata["цена"], .int(12), "колонка строки важнее общего поля")

        let embedded = embeddings.counter.texts
        var renamed = shared
        renamed["OGV"] = .string("Ведомство Б")
        let report = try await run(url, manifest: &manifest, profiles: [profile()], database: database, embeddings: embeddings, documentMetadata: renamed)
        XCTAssertEqual(embeddings.counter.texts, embedded, "векторы не пересчитываются")
        XCTAssertEqual(report.rowsMetadataOnly, 2)
        XCTAssertTrue(database.documents.values.allSatisfy { $0.metadata["OGV"] == .string("Ведомство Б") })
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
        // Ключ строки — впереди текста: по артикулу её и ищут,
        // а раньше он был только в метаданных.
        XCTAssertEqual(bolt.document, "Артикул: A-1\nНазвание: Болт")
        XCTAssertEqual(bolt.metadata["артикул"], .string("A-1"))
        XCTAssertEqual(bolt.metadata["цена"], .int(12))
        XCTAssertEqual(bolt.metadata["sheet_name"], .string("Каталог"))
        XCTAssertEqual(bolt.metadata["row_number"], .int(2))
        XCTAssertEqual(bolt.metadata["row_key"], .string("A-1"))
        XCTAssertEqual(bolt.metadata["table_mode"], .string("dataTable"))
        XCTAssertEqual(bolt.metadata["source_id"], .string(sourceID.uuidString))
        XCTAssertEqual(bolt.metadata[DocumentOrigin.metadataKey], .string("source"))
    }


    /// Очищенный лист ждёт записи, и прогон это ожидание снимает.
    ///
    /// Полный круг: лист записан, человек нажал «Переиндексировать»,
    /// манифест забыл лист и пометил его ждущим, синхронизация записала
    /// строки заново — и признак снялся. Пока он стоит, приложение говорит
    /// человеку, что этих строк в базе нет.
    func testAForgottenSheetAwaitsWriteUntilTheRunWritesIt() async throws {
        let url = try workbook([("A-1", "Болт", 12), ("A-2", "Гайка", 8)])
        var manifest = TableFileManifest(relativePath: "прайс.xlsx", collectionName: "catalogue")
        let database = FakeDatabase()
        let embeddings = FakeEmbeddings()

        try await run(url, manifest: &manifest, profiles: [profile()], database: database, embeddings: embeddings)
        XCTAssertTrue(manifest.sheetsAwaitingWrite.isEmpty, "записанный лист ничего не ждёт")

        // Человек нажал кнопку: строки из коллекции убраны, лист забыт.
        let forgotten = manifest.forgetSheet("Каталог")
        XCTAssertEqual(forgotten.count, 2)
        XCTAssertEqual(manifest.sheetsAwaitingWrite, ["Каталог"])
        XCTAssertEqual(manifest.rowCount, 0, "строк листа манифест больше не помнит")

        let report = try await run(url, manifest: &manifest, profiles: [profile()], database: database, embeddings: embeddings)

        XCTAssertEqual(report.rowsAdded, 2, "строки записаны заново — по нынешней разметке")
        XCTAssertTrue(manifest.sheetsAwaitingWrite.isEmpty, "ожидание снимает та самая запись, которой ждали")
    }

    /// Ожидание снимается только у того листа, который записан: у соседнего
    /// оно остаётся, иначе один прогон гасил бы напоминание про другой лист.
    func testWritingOneSheetLeavesTheOtherWaiting() async throws {
        let url = try workbook([("A-1", "Болт", 12)])
        var manifest = TableFileManifest(relativePath: "прайс.xlsx", collectionName: "catalogue")
        manifest.sheetsAwaitingWrite = ["Каталог", "Услуги"]

        try await run(
            url, manifest: &manifest, profiles: [profile()],
            database: FakeDatabase(), embeddings: FakeEmbeddings()
        )

        XCTAssertEqual(manifest.sheetsAwaitingWrite, ["Услуги"])
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
        XCTAssertTrue(database.documents.values.contains { $0.document == "Артикул: A-1\nНазвание: Болт М8" })
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

    /// Лист без колонки-ключа: идентификатор строки считается от её значений,
    /// и правка одной цены его меняет. `update` по новому идентификатору
    /// не делал ничего, а прежний документ удалялся как заменённый — строка
    /// пропадала из коллекции насовсем.
    func testARepricedRowWithoutAKeyColumnMovesWithItsVector() async throws {
        let profile = profile(keyColumn: nil)
        let url = try workbook([("A-1", "Болт", 12)])
        var manifest = TableFileManifest(relativePath: "прайс.xlsx", collectionName: "catalogue")
        let database = FakeDatabase()
        let embeddings = FakeEmbeddings()
        try await run(url, manifest: &manifest, profiles: [profile], database: database, embeddings: embeddings)
        let oldID = try XCTUnwrap(database.documents.keys.first)
        let vector = try XCTUnwrap(database.documents[oldID]?.embedding)
        let before = embeddings.counter.texts

        let repriced = try workbook([("A-1", "Болт", 15)])
        let report = try await run(repriced, manifest: &manifest, profiles: [profile], database: database, embeddings: embeddings)

        XCTAssertEqual(report.rowsMetadataOnly, 1)
        XCTAssertEqual(database.documents.count, 1, "строка пропала из коллекции")
        let moved = try XCTUnwrap(database.documents.values.first)
        XCTAssertNotEqual(moved.id, oldID)
        XCTAssertEqual(moved.metadata["цена"], .int(15))
        XCTAssertEqual(moved.embedding, vector, "текст тот же — вектор переехал, а не посчитан заново")
        XCTAssertEqual(embeddings.counter.texts, before)
    }

    ///, до конца конвейера: вставка строки в файл без ключевой колонки
    /// не должна уносить из базы ничего.
    ///
    /// Раньше уносила: сдвинувшиеся строки считались правками соседей, их
    /// прежние документы удалялись после записи — а манифест продолжал считать
    /// их записанными, так что ни один следующий прогон их не возвращал.
    func testInsertingARowKeepsEveryDocumentInTheCollection() async throws {
        let profile = profile(keyColumn: nil)
        let url = try workbook([("A-1", "Болт", 12), ("A-2", "Гайка", 8), ("A-3", "Шайба", 3)])
        var manifest = TableFileManifest(relativePath: "прайс.xlsx", collectionName: "catalogue")
        let database = FakeDatabase()
        let embeddings = FakeEmbeddings()
        try await run(url, manifest: &manifest, profiles: [profile], database: database, embeddings: embeddings)
        XCTAssertEqual(database.documents.count, 3)
        let before = Set(database.documents.keys)

        let wider = try workbook([
            ("A-1", "Болт", 12), ("A-9", "Новый", 5), ("A-2", "Гайка", 8), ("A-3", "Шайба", 3),
        ])
        let report = try await run(wider, manifest: &manifest, profiles: [profile], database: database, embeddings: embeddings)

        XCTAssertEqual(database.documents.count, 4, "было три строки, стало четыре")
        XCTAssertTrue(before.isSubset(of: Set(database.documents.keys)), "ни один прежний документ не пропал")
        XCTAssertTrue(database.deleted.isEmpty, "удалять было нечего")
        XCTAssertEqual(report.rowsAdded, 1)
        XCTAssertEqual(report.rowsReembedded, 0, "сдвиг — не правка, вектор считается только новой строке")
    }

    /// обрезка по длине не молчит — она называет колонку и счёт.
    func testALongValueIsCutAndTheRunSaysWhichColumn() async throws {
        let long = String(repeating: "я", count: RowMapper.metadataValueLimit + 100)
        let url = try workbook([("A-1", "Болт", 12), ("A-2", "Гайка", 8)], note: long)
        var manifest = TableFileManifest(relativePath: "прайс.xlsx", collectionName: "catalogue")
        let database = FakeDatabase()
        let report = try await run(
            url, manifest: &manifest,
            profiles: [profile(columns: columns + ["Примечание"])],
            database: database, embeddings: FakeEmbeddings()
        )

        let warning = try XCTUnwrap(report.warnings.first { $0.contains("обрезано") })
        XCTAssertTrue(warning.contains("Примечание"), warning)
        XCTAssertTrue(warning.contains("2"), "строк с обрезкой две — \(warning)")
        let stored = try XCTUnwrap(database.documents.values.first)
        guard case .string(let value)? = stored.metadata["примечание"] else {
            return XCTFail("примечание должно быть строкой")
        }
        XCTAssertEqual(value.count, RowMapper.metadataValueLimit + 1)
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
        // И записывается туда, где решение будут принимать — в манифест
        //. Отчёт живёт до конца прогона, а человек решает потом.
        XCTAssertEqual(manifest.pendingRemovals["Каталог"]?.rows.map(\.rowKey), ["A-2"])
    }

    /// Строка вернулась в файл — решать больше нечего, и список чистится сам,
    /// как у файлов.
    func testAReturnedRowClearsTheDecisionList() async throws {
        let url = try workbook([("A-1", "Болт", 12), ("A-2", "Гайка", 8)])
        var manifest = TableFileManifest(relativePath: "прайс.xlsx", collectionName: "catalogue")
        let database = FakeDatabase()
        let embeddings = FakeEmbeddings()
        try await run(url, manifest: &manifest, profiles: [profile()], database: database, embeddings: embeddings)

        let shorter = try workbook([("A-1", "Болт", 12)])
        try await run(shorter, manifest: &manifest, profiles: [profile()], database: database, embeddings: embeddings)
        XCTAssertNotNil(manifest.pendingRemovals["Каталог"])

        let restored = try workbook([("A-1", "Болт", 12), ("A-2", "Гайка", 8)])
        try await run(restored, manifest: &manifest, profiles: [profile()], database: database, embeddings: embeddings)
        XCTAssertNil(manifest.pendingRemovals["Каталог"], "строка на месте — решать нечего")
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

    /// Выборка — не весь лист: лист, ждущий записи, ждёт и дальше,
    /// исчезнувшие строки ждут решения, подписи файла не ставятся — и
    /// следующий полный прогон откроет файл и допишет остальное.
    func testASampleRunDoesNotMarkTheSheetAsWritten() async throws {
        let url = try workbook([("A-1", "Болт", 12), ("A-2", "Гайка", 8), ("A-3", "Шайба", 3)])
        var manifest = TableFileManifest(relativePath: "прайс.xlsx", collectionName: "catalogue")
        let database = FakeDatabase()
        try await run(url, manifest: &manifest, profiles: [profile()], database: database, embeddings: FakeEmbeddings())
        let written = manifest.profilesSignature
        XCTAssertFalse(written.isEmpty)

        // Пропажа строки замечена полным прогоном…
        let shorter = try workbook([("A-1", "Болт", 12), ("A-2", "Гайка", 8)])
        try await run(shorter, manifest: &manifest, profiles: [profile()], database: database, embeddings: FakeEmbeddings())
        XCTAssertEqual(manifest.pendingRemovals["Каталог"]?.rows.count, 1)

        // …а лист переиндексируют и пробуют на выборке.
        _ = manifest.forgetSheet("Каталог")
        try await run(shorter, manifest: &manifest, profiles: [profile()], database: database, embeddings: FakeEmbeddings(), rowLimit: 1)
        XCTAssertEqual(manifest.sheetsAwaitingWrite, ["Каталог"], "выборка не записала лист целиком")
        XCTAssertEqual(manifest.profilesSignature, "", "подпись после выборки скрыла бы файл от полного прогона")

        try await run(shorter, manifest: &manifest, profiles: [profile()], database: database, embeddings: FakeEmbeddings())
        XCTAssertEqual(manifest.sheetsAwaitingWrite, [])
        XCTAssertEqual(manifest.profilesSignature, written)
        XCTAssertEqual(manifest.sheets["Каталог"]?.rowCount, 2)
    }

    /// Выборка не снимает список исчезнувших строк: в её плане их нет вовсе.
    func testASampleRunKeepsPendingRemovals() async throws {
        let url = try workbook([("A-1", "Болт", 12), ("A-2", "Гайка", 8)])
        var manifest = TableFileManifest(relativePath: "прайс.xlsx", collectionName: "catalogue")
        let database = FakeDatabase()
        try await run(url, manifest: &manifest, profiles: [profile()], database: database, embeddings: FakeEmbeddings())
        let shorter = try workbook([("A-1", "Болт", 12)])
        try await run(shorter, manifest: &manifest, profiles: [profile()], database: database, embeddings: FakeEmbeddings())
        XCTAssertEqual(manifest.pendingRemovals["Каталог"]?.rows.count, 1)

        try await run(shorter, manifest: &manifest, profiles: [profile()], database: database, embeddings: FakeEmbeddings(), rowLimit: 1)
        XCTAssertEqual(manifest.pendingRemovals["Каталог"]?.rows.count, 1, "выборка сняла решение о строках")
    }

    /// Лист-документ с куском длиннее контекста модели дорезается, как кусок
    /// файла: в модель не уходит ничего длиннее контекста, а лист
    /// попадает в базу целиком, а не пропускается.
    func testADocumentSheetLongerThanTheContextIsCutToFit() async throws {
        let items = (1...400).map { ("A-\($0)", "Позиция номер \($0) с длинным описанием", Double($0)) }
        let url = try workbook(items)
        var manifest = TableFileManifest(relativePath: "прайс.xlsx", collectionName: "catalogue")
        let database = FakeDatabase()
        let sheets = try await TableSyncService.read(url: url).sheets
        var context = context(profiles: [profile(mode: .document)])
        context.contextLength = 512
        let report = try await TableSyncService().sync(
            sheets: sheets, manifest: &manifest, context: context, chroma: database, embeddings: FakeEmbeddings()
        )
        XCTAssertEqual(report.sheetsIndexed, ["Каталог"])
        XCTAssertTrue(report.problems.isEmpty, "\(report.problems.map(\.reason))")
        XCTAssertGreaterThan(database.documents.count, 1)
        for document in database.documents.values {
            XCTAssertFalse(
                ContextBudget.check(document.document, contextLength: 512).blocksSending,
                "кусок длиннее контекста ушёл в модель"
            )
        }
        let text = database.documents.values.map(\.document).joined(separator: "\n")
        XCTAssertTrue(text.contains("A-400"), "хвост листа не попал в базу")
        XCTAssertTrue(report.warnings.contains { $0.contains("дорезано") }, "\(report.warnings)")
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

    // MARK: - Разбор ревью: идентификаторы строк

    private func sync(
        _ url: URL, file: String, manifest: inout TableFileManifest, profiles: [TableProfile],
        database: FakeDatabase, embeddings: FakeEmbeddings, rowLimit: Int? = nil
    ) async throws -> TableSyncReport {
        let sheets = try await TableSyncService.read(url: url).sheets
        var context = context(profiles: profiles, rowLimit: rowLimit)
        context.relativePath = file
        return try await TableSyncService().sync(
            sheets: sheets, manifest: &manifest, context: context, chroma: database, embeddings: embeddings
        )
    }

    /// Два файла источника, читаемые одним профилем, с одними и теми же
    /// ключами — разные документы, и у каждого свой лист в метаданных.
    func testRowsOfTwoFilesWithTheSameKeyStaySeparate() async throws {
        let url = try workbook([("A-1", "Болт", 12), ("A-2", "Гайка", 8)], sheet: "Январь")
        let database = FakeDatabase()
        let embeddings = FakeEmbeddings()
        var january = TableFileManifest(relativePath: "январь.xlsx", collectionName: "catalogue")
        var february = TableFileManifest(relativePath: "февраль.xlsx", collectionName: "catalogue")
        try await sync(url, file: "январь.xlsx", manifest: &january, profiles: [profile()], database: database, embeddings: embeddings)
        try await sync(url, file: "февраль.xlsx", manifest: &february, profiles: [profile()], database: database, embeddings: embeddings)

        XCTAssertEqual(database.documents.count, 4, "строки второго файла затёрли первый")
        XCTAssertTrue(Set(january.sheets.values.flatMap(\.documentIDs)).isDisjoint(with: february.sheets.values.flatMap(\.documentIDs)))
        XCTAssertTrue(database.documents.values.allSatisfy { $0.metadata["sheet_name"] == .string("Январь") },
                      "лист в метаданных — настоящий лист книги, а не тот, где размечали профиль")
    }

    /// Строки, записанные по прежней схеме идентификаторов, переезжают под
    /// новые со своими векторами — модель не зовётся, прежние id снимаются.
    /// Под прежним id, который делили файлы, лежит чужой текст — такая
    /// строка считается заново.
    func testRowsUnderTheOldIdentifiersMoveWithTheirVectors() async throws {
        let url = try workbook([("A-1", "Болт", 12), ("A-2", "Гайка", 8)])
        let database = FakeDatabase()
        let embeddings = FakeEmbeddings()
        var manifest = TableFileManifest(relativePath: "прайс.xlsx", collectionName: "catalogue")
        try await run(url, manifest: &manifest, profiles: [profile()], database: database, embeddings: embeddings)
        XCTAssertEqual(embeddings.counter.texts, 2)

        // Как было до исправления: те же строки под прежними id. У второй
        // под её id лежит текст другого файла.
        var sheet = try XCTUnwrap(manifest.sheets["Каталог"])
        for (identity, record) in sheet.rows {
            let old = "old-" + record.documentID
            var moved = try XCTUnwrap(database.documents.removeValue(forKey: record.documentID))
            if record.rowKey == "A-2" {
                moved = EmbeddedRecord(id: old, document: "Артикул: A-2\nНазвание: Шайба", embedding: [9, 9, 9, 9], metadata: moved.metadata)
            } else {
                moved = EmbeddedRecord(id: old, document: moved.document, embedding: moved.embedding, metadata: moved.metadata)
            }
            database.documents[old] = moved
            sheet.rows[identity]?.documentID = old
        }
        manifest.sheets["Каталог"] = sheet

        try await run(url, manifest: &manifest, profiles: [profile()], database: database, embeddings: embeddings)

        XCTAssertEqual(embeddings.counter.texts, 3, "заново считается только строка с чужим текстом под прежним id")
        XCTAssertEqual(database.documents.count, 2)
        XCTAssertTrue(database.documents.keys.allSatisfy { !$0.hasPrefix("old-") }, "прежние id должны быть сняты")
        XCTAssertEqual(Set(database.documents.keys), Set(manifest.sheets["Каталог"]?.documentIDs ?? []))
    }

    /// Лист, разметку которого перевели в «документ», не стирает свои строки
    /// молча: это переиндексация, и её предлагают отдельно.
    func testADocumentSheetWithAChangedMappingIsLeftAlone() async throws {
        let url = try workbook([("A-1", "Болт", 12), ("A-2", "Гайка", 8)])
        let database = FakeDatabase()
        let embeddings = FakeEmbeddings()
        var manifest = TableFileManifest(relativePath: "прайс.xlsx", collectionName: "catalogue")
        try await run(url, manifest: &manifest, profiles: [profile()], database: database, embeddings: embeddings)

        let report = try await run(url, manifest: &manifest, profiles: [profile(mode: .document)], database: database, embeddings: embeddings)
        XCTAssertEqual(report.sheetsNeedingReindex, ["Каталог"])
        XCTAssertEqual(database.deleted, [])
        XCTAssertEqual(database.documents.count, 2)
    }

    /// Пробный прогон на выборке строк лист-документ целиком не пишет.
    func testATrialRunDoesNotWriteADocumentSheetWhole() async throws {
        let url = try workbook([("A-1", "Болт", 12), ("A-2", "Гайка", 8)])
        let database = FakeDatabase()
        let embeddings = FakeEmbeddings()
        var manifest = TableFileManifest(relativePath: "прайс.xlsx", collectionName: "catalogue")
        let report = try await run(
            url, manifest: &manifest, profiles: [profile(mode: .document)],
            database: database, embeddings: embeddings, rowLimit: 1
        )
        XCTAssertEqual(database.upsertCalls, 0)
        XCTAssertEqual(embeddings.counter.texts, 0)
        XCTAssertFalse(report.warnings.isEmpty)
    }

    /// Шапка листа-документа, дописанная после нарезки, — в размер куска
    ///: кусок, вылезший за него, делится по строкам, и шапка — в
    /// каждой части.
    func testTheRepeatedSheetHeaderFitsTheChunkSize() async throws {
        let items = (1...40).map { ("A-\($0)", "Позиция каталога номер \($0) с длинным названием", Double($0)) }
        let url = try workbook(items)
        let database = FakeDatabase()
        var manifest = TableFileManifest(relativePath: "прайс.xlsx", collectionName: "catalogue")
        var chunking = ChunkingConfiguration()
        chunking.strategy = .fixed
        chunking.sizeUnit = .characters
        chunking.chunkSize = 400
        chunking.overlapPercent = 0
        let pipeline = ChunkingPipeline(configuration: chunking)
        var context = context(profiles: [profile(mode: .document)])
        context.chunker = { text in try await pipeline.chunks(from: text, fileExtension: "md") }
        context.chunkLimit = { [chunking] chunk in chunking.characterLimit(of: chunk) }
        // Ход — по партиям: счётчик не стоит, пока пишется файл.
        let reported = WrittenCounter()
        context.onBatchWritten = { count in _ = reported.add(count) }
        let sheets = try await TableSyncService.read(url: url).sheets
        try await TableSyncService().sync(
            sheets: sheets, manifest: &manifest, context: context, chroma: database, embeddings: FakeEmbeddings()
        )
        let texts = database.documents.values.map(\.document)
        XCTAssertGreaterThan(texts.count, 3)
        XCTAssertEqual(reported.add(0), texts.count, "о каждой записанной партии сказано")
        for text in texts {
            XCTAssertLessThanOrEqual(Double(text.count), 400 * 1.1, "кусок вылез за размер вместе с шапкой: \(text.count)")
            XCTAssertTrue(text.contains("| Артикул | Название | Цена |"), "шапка в каждом куске")
        }
    }

    /// Кусок без строк таблицы — длинное примечание над ней — получает шапку
    /// листа после нарезки и всё равно укладывается в размер: без
    /// подгонки он вылезал на длину шапки.
    func testANotesChunkWithTheSheetHeaderFitsTheChunkSize() async throws {
        var builder = XLSXFixtureBuilder()
        let note = String(repeating: "Примечание к прайсу, которое занимает много места. ", count: 7)
        var rows: [[XLSXFixtureBuilder.Cell]] = [[.inline(note)], [.shared("Артикул"), .shared("Название"), .shared("Цена")]]
        for index in 1...6 { rows.append([.shared("A-\(index)"), .shared("Позиция \(index)"), .number(Double(index))]) }
        builder.sheets = [.init(name: "Каталог", rows: rows)]
        let url = root.appendingPathComponent("прайс.xlsx")
        try builder.build().write(to: url)

        let profile = TableProfile(name: "Каталог", mapping: TableMapping(
            sheetName: "Каталог", mode: .document, headerRow: 2, columns: columns,
            roles: ["Артикул": .metadata, "Название": .text, "Цена": .metadata], keyColumn: "Артикул"
        ))
        var chunking = ChunkingConfiguration()
        chunking.strategy = .fixed
        chunking.sizeUnit = .characters
        chunking.chunkSize = 300
        chunking.overlapPercent = 0
        let pipeline = ChunkingPipeline(configuration: chunking)
        var context = context(profiles: [profile])
        context.chunker = { text in try await pipeline.chunks(from: text, fileExtension: "md") }
        context.chunkLimit = { [chunking] chunk in chunking.characterLimit(of: chunk) }
        let database = FakeDatabase()
        var manifest = TableFileManifest(relativePath: "прайс.xlsx", collectionName: "catalogue")
        try await TableSyncService().sync(
            sheets: try await TableSyncService.read(url: url).sheets, manifest: &manifest, context: context,
            chroma: database, embeddings: FakeEmbeddings()
        )
        let texts = database.documents.values.map(\.document)
        XCTAssertFalse(texts.isEmpty)
        for text in texts {
            XCTAssertLessThanOrEqual(Double(text.count), 300 * 1.1, "кусок вылез за размер вместе с шапкой: \(text.count)\n\(text)")
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

    private func run(
        _ url: URL, manifest: inout TableFileManifest, database: Database, chunkLines: Int = 4,
        profiles: [TableProfile]? = nil, unmatchedSheetsAsText: Bool = false,
        documentMetadata: ChromaMetadata = [:]
    ) async throws -> TableSyncReport {
        let sheets = try await TableSyncService.read(url: url).sheets
        return try await TableSyncService().sync(
            sheets: sheets, manifest: &manifest,
            context: TableSyncService.Context(
                sourceID: UUID(uuidString: "00000000-0000-0000-0000-0000000000DD")!,
                relativePath: "отчёт.xlsx", collectionID: "col", collectionName: "reports",
                embeddingModel: "m", dimension: 4, profiles: profiles ?? [profile()],
                chunker: chunker(chunkLines), unmatchedSheetsAsText: unmatchedSheetsAsText,
                documentMetadata: documentMetadata
            ),
            chroma: database, embeddings: Embeddings()
        )
    }

    /// Кусок листа-документа несёт поля файла: без них лист не
    /// попадал под фильтр по уровням пути, а в выдаче у него не было имени.
    func testASheetChunkCarriesTheFieldsOfItsFile() async throws {
        let url = try report(rows: 12)
        var manifest = TableFileManifest(relativePath: "отчёт.xlsx", collectionName: "reports")
        let database = Database()
        _ = try await run(url, manifest: &manifest, database: database,
                          documentMetadata: ["file_name": .string("отчёт.xlsx"), "YEAR": .string("2026")])
        XCTAssertGreaterThan(database.documents.count, 1)
        XCTAssertTrue(database.documents.values.allSatisfy {
            $0.metadata["file_name"] == .string("отчёт.xlsx") && $0.metadata["YEAR"] == .string("2026")
        })
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

    /// лист, под который не подошёл ни один профиль, пишется текстом
    /// с заголовком в каждом чанке и считается в покрытии книги; без флага —
    /// по-прежнему ждёт профиля и не пишет ничего.
    func testAnUnmatchedSheetIsWrittenAsText() async throws {
        let url = try report(rows: 12)
        var manifest = TableFileManifest(relativePath: "отчёт.xlsx", collectionName: "reports")
        let database = Database()
        let result = try await run(url, manifest: &manifest, database: database, profiles: [], unmatchedSheetsAsText: true)

        XCTAssertEqual(result.sheetsIndexed, ["Отчёт"])
        XCTAssertTrue(result.problems.isEmpty, "\(result.problems)")
        XCTAssertTrue(result.warnings.contains { $0.contains("записан текстом") }, "\(result.warnings)")
        XCTAssertGreaterThan(database.documents.count, 1)
        let header = "| Показатель | Значение | Комментарий |"
        XCTAssertTrue(database.documents.values.allSatisfy { $0.document.hasPrefix(header) })
        XCTAssertTrue(database.documents.values.allSatisfy { $0.metadata["table_mode"] == .string("document") })
    }

    /// кусок с дописанной шапкой знает её длину, и шапка в начале
    /// его текста — ровно столько знаков; место листа в книге — у каждого.
    func testARepeatedHeaderIsMeasuredInTheMetadata() async throws {
        let url = try report(rows: 12)
        var manifest = TableFileManifest(relativePath: "отчёт.xlsx", collectionName: "reports")
        let database = Database()
        try await run(url, manifest: &manifest, database: database)

        let header = "| Показатель | Значение | Комментарий |"
        let measured = database.documents.values.filter { $0.metadata[TableChunkHeaders.lengthKey] != nil }
        XCTAssertFalse(measured.isEmpty)
        for record in measured {
            guard case .int(let length)? = record.metadata[TableChunkHeaders.lengthKey] else { return XCTFail() }
            let prefix = String(record.document.prefix(length))
            XCTAssertTrue(prefix.hasPrefix(header) && prefix.hasSuffix("\n"), prefix)
        }
        XCTAssertTrue(database.documents.values.allSatisfy { $0.metadata["sheet_index"] == .int(0) })
    }

    func testWithoutTheFallbackAnUnmatchedSheetWaitsForAProfile() async throws {
        let url = try report(rows: 3)
        var manifest = TableFileManifest(relativePath: "отчёт.xlsx", collectionName: "reports")
        let database = Database()
        let result = try await run(url, manifest: &manifest, database: database, profiles: [])

        XCTAssertEqual(result.problems.map(\.sheetName), ["Отчёт"])
        XCTAssertTrue(database.documents.isEmpty)
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
