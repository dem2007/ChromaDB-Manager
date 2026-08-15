import XCTest
@testable import ChromaCore

/// synchronisation per row, not per file.
final class SheetSyncPlanTests: XCTestCase {
    private let sourceID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
    private let columns = ["Артикул", "Название", "Цена"]

    private func mapping(keyColumn: String? = "Артикул", template: String = "") -> TableMapping {
        TableMapping(
            sheetName: "Каталог", mode: .dataTable, headerRow: 1, columns: columns,
            roles: ["Артикул": .metadata, "Название": .text, "Цена": .metadata],
            keyColumn: keyColumn, textTemplate: template
        )
    }

    /// A sheet with a header and the given data rows.
    private func sheet(_ data: [(article: String, name: String, price: Double)], from first: Int = 2) -> [SheetRow] {
        var rows = [SheetRow(number: 1, cells: [0: .text("Артикул"), 1: .text("Название"), 2: .text("Цена")])]
        for (offset, item) in data.enumerated() {
            rows.append(SheetRow(number: first + offset, cells: [
                0: .text(item.article), 1: .text(item.name), 2: .number(item.price),
            ]))
        }
        return rows
    }

    private func plan(_ rows: [SheetRow], _ manifest: SheetManifest, mapping: TableMapping? = nil) -> SheetSyncPlan {
        let used = mapping ?? self.mapping()
        return TableSyncPlanner.plan(
            rows: rows, mapping: used, layout: SheetLayout(mapping: used), manifest: manifest,
            sourceID: sourceID, sourceFile: "прайс.xlsx"
        )
    }

    private func synced(_ rows: [SheetRow], mapping: TableMapping? = nil) -> SheetManifest {
        let used = mapping ?? self.mapping()
        let first = plan(rows, SheetManifest(sheetName: "Каталог"), mapping: used)
        return TableSyncPlanner.applying(first, to: SheetManifest(sheetName: "Каталог"), mapping: used)
    }

    // MARK: - The first run

    func testEverythingIsNewTheFirstTime() {
        let result = plan(sheet([("A-1", "Болт", 12), ("A-2", "Гайка", 8)]), SheetManifest(sheetName: "Каталог"))
        XCTAssertEqual(result.added.count, 2)
        XCTAssertEqual(result.unchanged, 0)
        XCTAssertTrue(result.disappeared.isEmpty)
        XCTAssertFalse(result.mappingChanged, "первый прогон не является сменой сопоставления")
    }

    func testTheHeaderRowIsNotADocument() {
        let result = plan(sheet([("A-1", "Болт", 12)]), SheetManifest(sheetName: "Каталог"))
        XCTAssertEqual(result.added.count, 1)
        XCTAssertEqual(result.added.first?.text, "Артикул: A-1\nНазвание: Болт")
        XCTAssertEqual(result.added.first?.metadata["row_number"], .int(2))
        XCTAssertFalse(result.added.contains { $0.metadata["row_number"] == .int(1) })
    }

    // MARK: - The second run (mandatory)

    func testAnUnchangedSheetCostsNothing() {
        let rows = sheet([("A-1", "Болт", 12), ("A-2", "Гайка", 8)])
        let result = plan(rows, synced(rows))
        XCTAssertEqual(result.unchanged, 2)
        XCTAssertEqual(result.embeddings, 0)
        XCTAssertEqual(result.writes, 0)
    }

    /// 9, mandatory: one edited cell must re-embed **one** row.
    func testEditingOneCellReembedsExactlyOneRow() {
        let before = sheet([("A-1", "Болт", 12), ("A-2", "Гайка", 8), ("A-3", "Шайба", 3)])
        let manifest = synced(before)
        let after = sheet([("A-1", "Болт", 12), ("A-2", "Гайка М6", 8), ("A-3", "Шайба", 3)])

        let result = plan(after, manifest)
        XCTAssertEqual(result.embeddings, 1)
        XCTAssertEqual(result.unchanged, 2)
        XCTAssertEqual(result.reembedded.first?.document.text, "Артикул: A-2\nНазвание: Гайка М6")
    }

    /// A changed price is a changed filter value, not changed meaning. Paying
    /// for a vector to say the same sentence is paying for nothing.
    func testAChangedMetadataValueDoesNotCostAVector() {
        let before = sheet([("A-1", "Болт", 12)])
        let manifest = synced(before)
        let after = sheet([("A-1", "Болт", 15)])

        let result = plan(after, manifest)
        XCTAssertEqual(result.embeddings, 0)
        XCTAssertEqual(result.metadataOnly.count, 1)
        XCTAssertEqual(result.metadataOnly.first?.document.metadata["цена"], .int(15))
    }

    // MARK: - Insertion (mandatory)

    /// With a key column, inserting a row costs **one** vector: the new row.
    ///
    /// The row that moved down keeps its identifier and its embedding; only its
    /// `row_number` is refreshed, which is a metadata write and not a re-index.
    func testInsertingARowCostsOneVector() {
        let before = sheet([("A-1", "Болт", 12), ("A-2", "Гайка", 8)])
        let manifest = synced(before)
        let after = sheet([("A-1", "Болт", 12), ("A-9", "Новый", 5), ("A-2", "Гайка", 8)])

        let result = plan(after, manifest)
        XCTAssertEqual(result.added.count, 1)
        XCTAssertEqual(result.embeddings, 1, "переиндексации листа быть не должно")
        XCTAssertEqual(result.unchanged, 1, "строка выше вставки не двигалась")
        XCTAssertEqual(result.metadataOnly.count, 1, "сдвинувшейся строке обновляется только номер")
        XCTAssertTrue(result.disappeared.isEmpty, "сдвинувшиеся строки не исчезали")

        // And the identifier really is the same one.
        let moved = try? XCTUnwrap(result.metadataOnly.first)
        XCTAssertEqual(moved?.document.id, manifest.rows["key\u{0}A-2"]?.documentID)
        XCTAssertEqual(moved?.previousID, manifest.rows["key\u{0}A-2"]?.documentID)
    }

    /// без ключевой колонки вставка тоже стоит один вектор.
    ///
    /// Строка узнаётся по номеру, и раньше вставка сдвигала все остальные:
    /// каждая сравнивалась с записью соседа, текст не совпадал — и хвост
    /// уходил на переэмбеддинг. Теперь сдвинувшаяся строка сперва ищется
    /// по содержимому и находится там, где она есть.
    func testWithoutAKeyAnInsertionStillCostsOneVector() {
        let mapping = mapping(keyColumn: nil)
        let before = sheet([("A-1", "Болт", 12), ("A-2", "Гайка", 8)])
        let manifest = synced(before, mapping: mapping)
        let after = sheet([("A-1", "Болт", 12), ("A-9", "Новый", 5), ("A-2", "Гайка", 8)])

        let result = plan(after, manifest, mapping: mapping)
        XCTAssertEqual(result.unchanged, 1, "первая строка не двигалась")
        XCTAssertEqual(result.embeddings, 1, "вектор считается только новой строке")
        XCTAssertEqual(result.added.count, 1)
        XCTAssertEqual(result.metadataOnly.count, 1, "сдвинувшейся строке обновляется только номер")
        XCTAssertTrue(result.disappeared.isEmpty)
    }

    /// Самое дорогое следствие прежнего разбора: «прежним» документом
    /// сдвинувшейся строки объявлялся документ **живого** соседа — и после
    /// записи он удалялся из базы. Проверяется прямо: ни один документ,
    /// который остаётся в манифесте, не может попасть в список на удаление.
    func testNoLiveDocumentIsEverSupersededByAnother() {
        let mapping = mapping(keyColumn: nil)
        let before = sheet([("A-1", "Болт", 12), ("A-2", "Гайка", 8), ("A-3", "Шайба", 3)])
        let manifest = synced(before, mapping: mapping)
        let after = sheet([
            ("A-1", "Болт", 12), ("A-9", "Новый", 5), ("A-2", "Гайка", 8), ("A-3", "Шайба", 3),
        ])

        let result = plan(after, manifest, mapping: mapping)
        let updated = TableSyncPlanner.applying(result, to: manifest, mapping: mapping)
        let alive = Set(updated.documentIDs)
        let superseded = (result.reembedded + result.metadataOnly)
            .filter { $0.previousID != $0.document.id }
            .map(\.previousID)
        XCTAssertTrue(
            superseded.allSatisfy { !alive.contains($0) },
            "документ живой строки не может считаться замещённым"
        )
        XCTAssertEqual(updated.rowCount, 4, "в манифесте ровно столько строк, сколько в файле")
    }

    /// Ключ прежнего номера убирается вместе с переносом: иначе одна
    /// строка осталась бы в манифесте дважды, и следующий прогон объявил бы
    /// её вторую половину исчезнувшей.
    func testAShiftedRowLeavesNoSecondRecordBehind() {
        let mapping = mapping(keyColumn: nil)
        let manifest = synced(sheet([("A-1", "Болт", 12), ("A-2", "Гайка", 8)]), mapping: mapping)
        let after = sheet([("A-1", "Болт", 12), ("A-9", "Новый", 5), ("A-2", "Гайка", 8)])

        let updated = TableSyncPlanner.applying(
            plan(after, manifest, mapping: mapping), to: manifest, mapping: mapping
        )
        XCTAssertEqual(updated.rowCount, 3)
        // И следующий прогон того же файла не находит ни изменений, ни пропаж.
        let again = plan(after, updated, mapping: mapping)
        XCTAssertEqual(again.unchanged, 3)
        XCTAssertTrue(again.disappeared.isEmpty)
        XCTAssertEqual(again.writes, 0)
    }

    /// Правка строки без ключа остаётся правкой: новый документ, старый —
    /// в «требуют решения», а не втихую удалён.
    func testWithoutAKeyAnEditIsStillAnEdit() {
        let mapping = mapping(keyColumn: nil)
        let manifest = synced(sheet([("A-1", "Болт", 12), ("A-2", "Гайка", 8)]), mapping: mapping)
        let after = sheet([("A-1", "Болт", 12), ("A-2", "Гайка М6", 8)])

        let result = plan(after, manifest, mapping: mapping)
        XCTAssertEqual(result.unchanged, 1)
        XCTAssertEqual(result.reembedded.count, 1, "текст изменился — это правка")
        XCTAssertTrue(result.added.isEmpty)
    }

    // MARK: - Rows that went away

    /// Rule 1 of Приложение 5 applies to a row exactly as it does to a file.
    func testADisappearedRowIsNotDeletedButOffered() {
        let before = sheet([("A-1", "Болт", 12), ("A-2", "Гайка", 8)])
        let manifest = synced(before)
        let after = sheet([("A-1", "Болт", 12)])

        let result = plan(after, manifest)
        XCTAssertEqual(result.disappeared.map(\.rowKey), ["A-2"])
        XCTAssertEqual(result.disappeared.first?.rowNumber, 3, "номер строки нужен, чтобы человек её нашёл")
    }

    /// And when the decision is made, deletion goes by explicit id — never by a
    /// filter on `row_number`, which would take whatever else shares it.
    func testRemovalGoesByExplicitIdentifiers() {
        let before = sheet([("A-1", "Болт", 12), ("A-2", "Гайка", 8)])
        let manifest = synced(before)
        let result = plan(sheet([("A-1", "Болт", 12)]), manifest)

        let ids = TableSyncPlanner.removalIDs(for: result.disappeared)
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(ids.first, manifest.rows["key\u{0}A-2"]?.documentID)
    }

    /// The record of a vanished row stays in the manifest until the user
    /// decides: forgetting it would leave a document nothing can address.
    func testAVanishedRowKeepsItsRecordUntilDecided() {
        let before = sheet([("A-1", "Болт", 12), ("A-2", "Гайка", 8)])
        let manifest = synced(before)
        let result = plan(sheet([("A-1", "Болт", 12)]), manifest)

        let updated = TableSyncPlanner.applying(result, to: manifest, mapping: mapping())
        XCTAssertNotNil(updated.rows["key\u{0}A-2"])
    }

    /// «Оставить в базе» должно помниться: строка исчезла, человек ответил —
    /// и следующий прогон не спрашивает о ней снова.
    func testARowLeftInTheDatabaseIsNotAskedAboutAgain() {
        let before = sheet([("A-1", "Болт", 12), ("A-2", "Гайка", 8)])
        var manifest = synced(before)
        let after = sheet([("A-1", "Болт", 12)])
        XCTAssertEqual(plan(after, manifest).disappeared.count, 1)

        manifest.rows["key\u{0}A-2"]?.isOrphaned = true
        XCTAssertTrue(plan(after, manifest).disappeared.isEmpty)
        XCTAssertNotNil(manifest.rows["key\u{0}A-2"], "запись остаётся: иначе документ нечем адресовать")
    }

    /// Вернувшаяся строка снова обычная — отметка «оставлена в базе» слетает
    /// вместе с перезаписью записи.
    func testAReturnedRowLosesItsOrphanMark() {
        let rows = sheet([("A-1", "Болт", 12), ("A-2", "Гайка", 8)])
        var manifest = synced(rows)
        manifest.rows["key\u{0}A-2"]?.isOrphaned = true
        // Строка вернулась и притом изменилась — значит будет переписана.
        let changed = sheet([("A-1", "Болт", 12), ("A-2", "Гайка М6", 8)])
        let result = plan(changed, manifest)
        let updated = TableSyncPlanner.applying(result, to: manifest, mapping: mapping())
        XCTAssertEqual(updated.rows["key\u{0}A-2"]?.isOrphaned, false)
    }

    /// Манифест, записанный до появления отметки, читается как есть.
    func testAManifestWithoutTheOrphanFlagStillReads() throws {
        let json = """
        {"sheetName":"Каталог","mappingSignature":"","rows":{"key\\u0000A-1":\
        {"documentID":"abc","rowNumber":2,"rowKey":"A-1","textHash":"x","metadataHash":"y"}}}
        """
        let decoded = try JSONDecoder().decode(SheetManifest.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.rows.count, 1)
        XCTAssertEqual(decoded.rows.first?.value.isOrphaned, false)
    }

    // MARK: - A changed mapping is not a sync

    /// a different mapping means every row is written by a different
    /// recipe. That is a re-index with a backup, offered — not started.
    func testAChangedMappingIsAnnouncedRatherThanPerformed() {
        let rows = sheet([("A-1", "Болт", 12)])
        let manifest = synced(rows)
        let result = plan(rows, manifest, mapping: mapping(template: "{Название} — {Цена}"))

        XCTAssertTrue(result.mappingChanged)
        // The rows still show up as work, but the flag is what the UI acts on:
        // a changed recipe is a whole-sheet operation, not row-by-row drift.
        XCTAssertEqual(result.reembedded.count, 1)
    }

    func testRenamingASheetIsNotAChangeOfMapping() {
        var first = mapping()
        first.sheetName = "Каталог"
        var second = mapping()
        second.sheetName = "Каталог 2024"
        XCTAssertEqual(first.signature, second.signature)
    }

    func testChangingAColumnRoleIsAChangeOfMapping() {
        var changed = mapping()
        changed.roles["Цена"] = .text
        XCTAssertNotEqual(mapping().signature, changed.signature)
    }

    // MARK: - Rows with nothing to say

    func testARowWithNoTextIsCountedNotDropped() {
        var rows = sheet([("A-1", "Болт", 12)])
        rows.append(SheetRow(number: 9, cells: [0: .text("A-5"), 2: .number(4)]))
        let result = plan(rows, SheetManifest(sheetName: "Каталог"))
        XCTAssertEqual(result.added.count, 1)
        XCTAssertEqual(result.empty, [9])
    }

    // MARK: - Повторы ключа

    /// Две строки с одним артикулом дают один документ: id считается от ключа.
    /// Пока повтор не ловился, обе уходили в `added` — и отчёт говорил
    /// «добавлено 2» там, где в базе оказывалась одна запись.
    func testARepeatedKeyIsReportedRatherThanCollapsed() {
        let rows = sheet([("A-1", "Болт", 12), ("A-1", "Болт оцинкованный", 14), ("A-2", "Гайка", 8)])
        let result = plan(rows, SheetManifest(sheetName: "Каталог"))

        XCTAssertEqual(result.added.count, 2, "записывается по одной строке на документ")
        XCTAssertEqual(result.duplicates.count, 1)
        XCTAssertEqual(result.duplicates.first?.rowKey, "A-1")
        XCTAssertEqual(result.duplicates.first?.rows, [2, 3])
        XCTAssertEqual(result.duplicates.first?.skipped, [3], "записана первая строка группы")
    }

    /// Без ключевой колонки id считается от содержимого — и две одинаковые
    /// строки сходятся к одному документу тем же порядком.
    func testTwoIdenticalRowsWithoutAKeyAreOneDocument() {
        let noKey = mapping(keyColumn: nil)
        let rows = sheet([("A-1", "Болт", 12), ("A-1", "Болт", 12)])
        let result = plan(rows, SheetManifest(sheetName: "Каталог"), mapping: noKey)

        XCTAssertEqual(result.added.count, 1)
        XCTAssertEqual(result.duplicates.first?.rowKey, nil)
        XCTAssertEqual(result.duplicates.first?.rows, [2, 3])
    }

    /// Пропущенный повтор не должен превращаться в «исчезло»: у него тот же
    /// документ, что у оставленной строки, и удаление по его id снесло бы
    /// строку, которая никуда не девалась.
    func testASkippedDuplicateIsNotOfferedForRemoval() {
        let before = sheet([("A-1", "Болт", 12)])
        let manifest = synced(before)
        let after = sheet([("A-1", "Болт", 12), ("A-1", "Болт", 12)])

        let result = plan(after, manifest)
        XCTAssertTrue(result.disappeared.isEmpty)
        XCTAssertEqual(result.duplicates.count, 1)
    }

    /// И то же самое, когда прошлый прогон успел записать обе строки под
    /// разными отметками: запись повтора остаётся в манифесте, но удалять
    /// по ней нечего — документ занят живой строкой.
    func testAnOldRecordOfADuplicateIsNotOfferedForRemoval() {
        let noKey = mapping(keyColumn: nil)
        var manifest = SheetManifest(sheetName: "Каталог", mappingSignature: noKey.signature)
        let rows = sheet([("A-1", "Болт", 12), ("A-1", "Болт", 12)])
        // Так выглядел манифест до правки: две отметки, один документ.
        let document = RowMapper.document(
            for: rows[1], mapping: noKey, layout: SheetLayout(mapping: noKey),
            sourceID: sourceID, sourceFile: "прайс.xlsx"
        )!
        manifest.rows["row\u{0}2"] = TableSyncPlanner.record(for: document, rowNumber: 2)
        manifest.rows["row\u{0}3"] = TableSyncPlanner.record(for: document, rowNumber: 3)

        let result = plan(rows, manifest, mapping: noKey)
        XCTAssertTrue(result.disappeared.isEmpty, "документ занят строкой 2 — предлагать его удаление нельзя")
    }

    // MARK: - Storage

    func testTheManifestSurvivesARoundTrip() throws {
        let manifest = synced(sheet([("A-1", "Болт", 12)]))
        let decoded = try JSONDecoder().decode(SheetManifest.self, from: try JSONEncoder().encode(manifest))
        XCTAssertEqual(decoded.rows.count, 1)
        XCTAssertEqual(decoded.mappingSignature, mapping().signature)
        XCTAssertEqual(decoded.rows.first?.value.rowKey, "A-1")
    }

    /// Dictionary order is not a change.
    func testTheMetadataSeedIgnoresDictionaryOrder() {
        let first: ChromaMetadata = ["b": .int(2), "a": .string("x"), "row_number": .int(5)]
        let second: ChromaMetadata = ["a": .string("x"), "row_number": .int(5), "b": .int(2)]
        XCTAssertEqual(TableSyncPlanner.metadataSeed(first), TableSyncPlanner.metadataSeed(second))
    }

    /// A moved row **is** a metadata change: leaving `row_number` out of the
    /// hash left it pointing at the wrong line of the file after an insertion.
    /// Found by the stage's Definition of Done run.
    func testAMovedRowUpdatesItsNumber() {
        let before = sheet([("A-1", "Болт", 12), ("A-2", "Гайка", 8)])
        let manifest = synced(before)
        // The same two rows, with one inserted above them.
        var after = sheet([("A-9", "Новый", 5)])
        after += sheet([("A-1", "Болт", 12), ("A-2", "Гайка", 8)], from: 3)

        let result = plan(after, manifest)
        XCTAssertEqual(result.added.count, 1)
        XCTAssertEqual(result.embeddings, 1, "сдвиг строк не стоит ни одного вектора")
        XCTAssertEqual(result.metadataOnly.count, 2, "но номера строк должны стать верными")
        XCTAssertEqual(result.unchanged, 0)
    }
}

// MARK: - Scale

/// The number puts in writing: one cell in twenty thousand rows.
final class SheetSyncScaleTests: XCTestCase {
    func testOneCellInTwentyThousandRowsCostsOneVector() {
        let columns = ["Артикул", "Название"]
        let mapping = TableMapping(
            sheetName: "Каталог", headerRow: 1, columns: columns,
            roles: ["Артикул": .metadata, "Название": .text], keyColumn: "Артикул"
        )
        let sourceID = UUID()

        func sheet(changing index: Int?) -> [SheetRow] {
            var rows = [SheetRow(number: 1, cells: [0: .text("Артикул"), 1: .text("Название")])]
            for i in 0..<20_000 {
                let name = i == index ? "Позиция \(i) исправленная" : "Позиция \(i)"
                rows.append(SheetRow(number: i + 2, cells: [0: .text("A-\(i)"), 1: .text(name)]))
            }
            return rows
        }

        let original = sheet(changing: nil)
        let first = TableSyncPlanner.plan(
            rows: original, mapping: mapping, layout: SheetLayout(mapping: mapping),
            manifest: SheetManifest(sheetName: "Каталог"),
            sourceID: sourceID, sourceFile: "прайс.xlsx"
        )
        let manifest = TableSyncPlanner.applying(first, to: SheetManifest(sheetName: "Каталог"), mapping: mapping)
        XCTAssertEqual(first.added.count, 20_000)

        let second = TableSyncPlanner.plan(
            rows: sheet(changing: 12_345), mapping: mapping, layout: SheetLayout(mapping: mapping),
            manifest: manifest,
            sourceID: sourceID, sourceFile: "прайс.xlsx"
        )
        XCTAssertEqual(second.embeddings, 1)
        XCTAssertEqual(second.unchanged, 19_999)
        XCTAssertTrue(second.disappeared.isEmpty)
    }
}
