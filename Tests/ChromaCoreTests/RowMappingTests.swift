import XCTest
@testable import ChromaCore

/// a row becomes a document: its text, its metadata keys, and its
/// identity.
final class ColumnKeyTests: XCTestCase {
    func testTitlesBecomeUsableKeys() {
        XCTAssertEqual(ColumnKeyNormaliser.normalise("Цена, руб."), "цена_руб")
        XCTAssertEqual(ColumnKeyNormaliser.normalise("  Название товара  "), "название_товара")
        XCTAssertEqual(ColumnKeyNormaliser.normalise("Unit Price"), "unit_price")
        XCTAssertEqual(ColumnKeyNormaliser.normalise("qty-2024"), "qty_2024")
    }

    /// `$` starts a ChromaDB filter operator and a dot is a path separator in
    /// most query languages; neither survives into a key.
    func testCharactersThatWouldBreakAFilterAreDropped() {
        XCTAssertEqual(ColumnKeyNormaliser.normalise("$gt"), "gt")
        XCTAssertEqual(ColumnKeyNormaliser.normalise("a.b.c"), "abc")
        XCTAssertEqual(ColumnKeyNormaliser.normalise("«кавычки»"), "кавычки")
    }

    /// The user's own words make the best key, so Cyrillic is left alone rather
    /// than transliterated into something they would not recognise.
    func testCyrillicIsKept() {
        XCTAssertEqual(ColumnKeyNormaliser.normalise("Поставщик"), "поставщик")
    }

    func testAColumnWithNoUsableNameFallsBackToItsLetter() {
        let map = ColumnKeyNormaliser.map(titles: ["Имя", "!!!", "Цена"])
        XCTAssertEqual(map.key(for: "!!!"), "b")
    }

    // MARK: - The first kind of collision

    func testTwoColumnsCollapsingIntoOneKeyAreBothKept() {
        let map = ColumnKeyNormaliser.map(titles: ["Цена, руб.", "Цена руб"])
        XCTAssertEqual(map.key(for: "Цена, руб."), "цена_руб")
        XCTAssertEqual(map.key(for: "Цена руб"), "цена_руб_2")
        XCTAssertEqual(map.collisions.map(\.reason), [.duplicate])
        XCTAssertTrue(map.collisions[0].explanation.contains("уже занят"))
    }

    // MARK: - The second kind — the one warns about

    /// A column called exactly like an auto-field. Left alone it would silently
    /// overwrite the value row-level synchronisation depends on — which breaks
    /// syncing rather than merely losing a column.
    func testAColumnNamedLikeAnAutoFieldGetsAPrefix() {
        let map = ColumnKeyNormaliser.map(titles: ["row_number", "source_file", "Название"])
        XCTAssertEqual(map.key(for: "row_number"), "col_row_number")
        XCTAssertEqual(map.key(for: "source_file"), "col_source_file")
        XCTAssertEqual(map.key(for: "Название"), "название")
        XCTAssertEqual(Set(map.collisions.map(\.reason)), [.reserved])
        XCTAssertTrue(map.collisions[0].explanation.contains("служебное поле"))
    }

    func testTheCollectionsOwnFieldsAreProtectedToo() {
        let map = ColumnKeyNormaliser.map(titles: ["_cdbm_model", "origin", "chunk_index"])
        XCTAssertEqual(map.key(for: "_cdbm_model"), "col__cdbm_model")
        XCTAssertEqual(map.key(for: "origin"), "col_origin")
        XCTAssertEqual(map.key(for: "chunk_index"), "col_chunk_index")
    }

    /// The auto-fields of this very stage have to be protected as well, or a
    /// sheet with a «sheet_name» column would overwrite its own provenance.
    func testTheTableAutoFieldsAreReserved() {
        for field in RowMapper.autoMetadataKeys {
            XCTAssertTrue(MetadataSchema.isTechnicalKey(field), field)
        }
    }
}

// MARK: - Text

final class RowTextTests: XCTestCase {
    private let columns = ["Артикул", "Название", "Описание", "Цена"]
    private var layout: SheetLayout { SheetLayout(headerRow: 1, columns: columns) }

    private var row: SheetRow {
        SheetRow(number: 7, cells: [
            0: .text("A-1"), 1: .text("Болт М8"), 2: .text("Оцинкованный"), 3: .number(12),
        ])
    }

    private func mapping(template: String = "", roles: [String: ColumnRole]) -> TableMapping {
        TableMapping(sheetName: "Каталог", columns: columns, roles: roles, textTemplate: template)
    }

    func testTheDefaultTemplateIsColumnColonValue() {
        let text = RowMapper.text(for: row, mapping: mapping(roles: [
            "Название": .text, "Описание": .text, "Цена": .metadata,
        ]), layout: layout)
        XCTAssertEqual(text, "Название: Болт М8\nОписание: Оцинкованный")
    }

    /// Only the columns marked as carrying meaning: an article number in the
    /// text is noise in the vector.
    func testColumnsMarkedAsMetadataStayOutOfTheText() {
        let text = RowMapper.text(for: row, mapping: mapping(roles: [
            "Название": .text, "Артикул": .metadata, "Цена": .metadata,
        ]), layout: layout)
        XCTAssertFalse(text.contains("A-1"))
        XCTAssertFalse(text.contains("12"))
    }

    func testATemplateIsFilledIn() {
        let text = RowMapper.text(for: row, mapping: mapping(
            template: "{Название}. {Описание}. Цена {Цена} руб.",
            roles: ["Название": .text, "Описание": .text]
        ), layout: layout)
        XCTAssertEqual(text, "Болт М8. Оцинкованный. Цена 12 руб.")
    }

    /// A template may name a column the user did not mark as text — that is the
    /// point of a template, and it must not be second-guessed.
    func testATemplateMayUseAnyColumn() {
        let text = RowMapper.text(for: row, mapping: mapping(
            template: "{Артикул}", roles: ["Название": .text]
        ), layout: layout)
        XCTAssertEqual(text, "A-1")
    }

    /// `{Название}` must not be eaten by a shorter column name that is its
    /// prefix.
    func testALongerColumnNameWins() {
        let columns = ["Наз", "Название"]
        let row = SheetRow(number: 1, cells: [0: .text("короткая"), 1: .text("длинная")])
        let text = RowMapper.text(
            for: row,
            mapping: TableMapping(sheetName: "s", columns: columns, textTemplate: "{Название}"),
            layout: SheetLayout(headerRow: 1, columns: columns)
        )
        XCTAssertEqual(text, "длинная")
    }

    /// A typo in a template would otherwise become an empty document without a
    /// word said.
    func testAnUnknownPlaceholderIsNamed() {
        XCTAssertEqual(
            RowMapper.unknownPlaceholders(in: "{Название} — {Цна}", columns: columns),
            ["Цна"]
        )
        XCTAssertTrue(RowMapper.unknownPlaceholders(in: "{Название}", columns: columns).isEmpty)
    }

    func testARowWithNoTextIsNotADocument() {
        let empty = SheetRow(number: 3, cells: [3: .number(12)])
        XCTAssertNil(RowMapper.document(
            for: empty,
            mapping: mapping(roles: ["Название": .text]),
            layout: layout,
            sourceID: UUID(),
            sourceFile: "book.xlsx"
        ))
    }
}

// MARK: - Metadata

final class RowMetadataTests: XCTestCase {
    private let columns = ["Артикул", "Цена", "Дата", "В наличии", "Заметка"]

    private func document(_ row: SheetRow, keyColumn: String? = nil) -> TableRowDocument? {
        var roles: [String: ColumnRole] = [:]
        for column in columns { roles[column] = .metadata }
        roles["Заметка"] = .text
        return RowMapper.document(
            for: row,
            mapping: TableMapping(
                sheetName: "Каталог", columns: columns, roles: roles, keyColumn: keyColumn
            ),
            layout: SheetLayout(headerRow: 1, columns: columns),
            sourceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            sourceFile: "прайс.xlsx"
        )
    }

    /// в текст идёт «15 %», в метаданные — 15.
    ///
    /// Разные числа не по недосмотру: в тексте человек ищет то, что видит
    /// в книге, а фильтр пишет по тому же числу — `= 15`, а не `= 0.15`.
    func testAPercentReadsAsPercentInBothPlaces() throws {
        let row = SheetRow(number: 5, cells: [
            0: .text("A-1"),
            1: .measured(0.15, .percent),
            4: .text("скидка"),
        ])
        let document = try XCTUnwrap(document(row))
        XCTAssertEqual(document.metadata["цена"], .int(15))
        XCTAssertEqual(row.value(at: 1).displayText, "15 %")
    }

    func testACurrencyKeepsItsNumberInMetadata() throws {
        let row = SheetRow(number: 5, cells: [
            0: .text("A-1"),
            1: .measured(1234.5, NumberUnit(suffix: "₽")),
            4: .text("цена"),
        ])
        let document = try XCTUnwrap(document(row))
        XCTAssertEqual(document.metadata["цена"], .double(1234.5))
    }

    /// у метаданных появился предел длины.
    ///
    /// Для текста документа предел есть — контекст модели; для метаданных
    /// не было никакого, и примечание на сорок тысяч знаков уезжало в базу
    /// целиком, а потом возвращалось в каждом результате поиска.
    func testALongValueIsCutToTheLimitAndSaysSo() throws {
        let long = String(repeating: "я", count: RowMapper.metadataValueLimit + 500)
        let row = SheetRow(number: 5, cells: [0: .text(long), 4: .text("есть")])
        let document = try XCTUnwrap(document(row))

        guard case .string(let stored)? = document.metadata["артикул"] else {
            return XCTFail("значение должно остаться строкой")
        }
        XCTAssertEqual(stored.count, RowMapper.metadataValueLimit + 1, "предел плюс многоточие")
        XCTAssertTrue(stored.hasSuffix("…"), "обрезка видна в самом значении, а не только в отчёте")
        XCTAssertEqual(document.truncatedColumns, ["Артикул"])
    }

    func testAValueAtTheLimitIsLeftAlone() throws {
        let exact = String(repeating: "я", count: RowMapper.metadataValueLimit)
        let row = SheetRow(number: 5, cells: [0: .text(exact), 4: .text("есть")])
        let document = try XCTUnwrap(document(row))
        XCTAssertEqual(document.metadata["артикул"], .string(exact))
        XCTAssertTrue(document.truncatedColumns.isEmpty)
    }

    /// Предел — про строки. Число и дата короткие по природе, и трогать их
    /// значило бы превращать их в строки.
    func testNumbersAndDatesAreNotTouched() throws {
        let row = SheetRow(number: 5, cells: [
            1: .number(12), 2: .date(Date(timeIntervalSince1970: 1_700_000_000)), 4: .text("есть"),
        ])
        let document = try XCTUnwrap(document(row))
        XCTAssertEqual(document.metadata["цена"], .int(12))
        XCTAssertTrue(document.truncatedColumns.isEmpty)
    }

    /// only string, int, float and bool exist in ChromaDB metadata.
    func testValuesAreCoercedToWhatChromaDBAccepts() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let row = SheetRow(number: 5, cells: [
            0: .text("A-1"), 1: .number(12), 2: .date(date), 3: .boolean(true), 4: .text("есть"),
        ])
        let metadata = try XCTUnwrap(document(row)).metadata

        XCTAssertEqual(metadata["артикул"], .string("A-1"))
        XCTAssertEqual(metadata["цена"], .int(12), "целое из таблицы должно остаться целым")
        XCTAssertEqual(metadata["в_наличии"], .bool(true))
        // Dates go out as ISO-8601 strings, as everywhere else in this project.
        guard case .string(let iso)? = metadata["дата"] else { return XCTFail("дата должна быть строкой") }
        XCTAssertTrue(iso.hasPrefix("2023-11-14"), iso)
    }

    func testAFractionalNumberStaysFractional() throws {
        let row = SheetRow(number: 1, cells: [1: .number(12.5), 4: .text("есть")])
        XCTAssertEqual(try XCTUnwrap(document(row)).metadata["цена"], .double(12.5))
    }

    /// An absent value must not become an empty string: it would then match a
    /// filter looking for one.
    func testEmptyCellsAreNotWritten() throws {
        let row = SheetRow(number: 1, cells: [0: .text("A-1"), 4: .text("есть")])
        let metadata = try XCTUnwrap(document(row)).metadata
        XCTAssertNil(metadata["цена"])
        XCTAssertNil(metadata["дата"])
    }

    func testTheAutoFieldsAreAlwaysThere() throws {
        let row = SheetRow(number: 42, cells: [0: .text("A-1"), 4: .text("есть")])
        let metadata = try XCTUnwrap(document(row, keyColumn: "Артикул")).metadata

        XCTAssertEqual(metadata["source_file"], .string("прайс.xlsx"))
        XCTAssertEqual(metadata["sheet_name"], .string("Каталог"))
        XCTAssertEqual(metadata["row_number"], .int(42))
        XCTAssertEqual(metadata["row_key"], .string("A-1"))
        XCTAssertEqual(metadata["table_mode"], .string("dataTable"))
    }

    func testWithoutAKeyColumnThereIsNoRowKey() throws {
        let row = SheetRow(number: 1, cells: [0: .text("A-1"), 4: .text("есть")])
        XCTAssertNil(try XCTUnwrap(document(row)).metadata["row_key"])
    }
}

// MARK: - Identity (mandatory)

final class RowIdentityTests: XCTestCase {
    private let sourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let columns = ["Артикул", "Название"]

    private func mapping(keyColumn: String?) -> TableMapping {
        TableMapping(
            sheetName: "Каталог", columns: columns,
            roles: ["Артикул": .metadata, "Название": .text],
            keyColumn: keyColumn
        )
    }

    private func document(_ number: Int, _ article: String, _ name: String, keyColumn: String?) -> TableRowDocument? {
        RowMapper.document(
            for: SheetRow(number: number, cells: [0: .text(article), 1: .text(name)]),
            mapping: mapping(keyColumn: keyColumn),
            layout: SheetLayout(headerRow: 1, columns: columns),
            sourceID: sourceID,
            sourceFile: "book.xlsx"
        )
    }

    /// 9, mandatory: inserting a row in the middle must not change the
    /// identifiers of the others, or one insertion re-indexes the whole sheet.
    func testWithAKeyColumnInsertingARowChangesNoOtherID() throws {
        let before = try [
            XCTUnwrap(document(2, "A-1", "Болт", keyColumn: "Артикул")),
            XCTUnwrap(document(3, "A-2", "Гайка", keyColumn: "Артикул")),
        ]
        // The same two rows, now at rows 3 and 4 because one was inserted above.
        let after = try [
            XCTUnwrap(document(3, "A-1", "Болт", keyColumn: "Артикул")),
            XCTUnwrap(document(4, "A-2", "Гайка", keyColumn: "Артикул")),
        ]
        XCTAssertEqual(before.map(\.id), after.map(\.id))
    }

    /// And the row number does move — the id simply does not follow it.
    func testTheRowNumberStillFollowsTheFile() throws {
        let moved = try XCTUnwrap(document(4, "A-1", "Болт", keyColumn: "Артикул"))
        XCTAssertEqual(moved.metadata["row_number"], .int(4))
    }

    /// With a key, editing a row updates the same document.
    func testWithAKeyColumnEditingARowKeepsItsID() throws {
        let original = try XCTUnwrap(document(2, "A-1", "Болт", keyColumn: "Артикул"))
        let edited = try XCTUnwrap(document(2, "A-1", "Болт М8 оцинкованный", keyColumn: "Артикул"))
        XCTAssertEqual(original.id, edited.id)
        XCTAssertNotEqual(original.text, edited.text)
    }

    /// Without a key, inserting is still safe…
    func testWithoutAKeyInsertingIsStillSafe() throws {
        let before = try XCTUnwrap(document(2, "A-1", "Болт", keyColumn: nil))
        let after = try XCTUnwrap(document(9, "A-1", "Болт", keyColumn: nil))
        XCTAssertEqual(before.id, after.id, "id не должен зависеть от номера строки")
    }

    /// …but any edit produces a new document, which is exactly why the manifest
    /// has to remember the old id in order to delete it.
    func testWithoutAKeyAnEditProducesANewDocument() throws {
        let original = try XCTUnwrap(document(2, "A-1", "Болт", keyColumn: nil))
        let edited = try XCTUnwrap(document(2, "A-1", "Болт М8", keyColumn: nil))
        XCTAssertNotEqual(original.id, edited.id)
    }

    /// Two sources with identical sheets must not write onto each other.
    func testIDsAreScopedToTheSourceAndTheSheet() {
        let byOtherSource = RowMapper.identifier(
            sourceID: UUID(), sheetName: "Каталог", key: "A-1", rowContent: "x"
        )
        let bySameSourceOtherSheet = RowMapper.identifier(
            sourceID: sourceID, sheetName: "Другой", key: "A-1", rowContent: "x"
        )
        let mine = RowMapper.identifier(
            sourceID: sourceID, sheetName: "Каталог", key: "A-1", rowContent: "x"
        )
        XCTAssertNotEqual(mine, byOtherSource)
        XCTAssertNotEqual(mine, bySameSourceOtherSheet)
    }

    /// A key and a content hash must not collide even when the strings match.
    func testAKeyIDAndAContentIDAreDifferentThings() {
        let keyed = RowMapper.identifier(sourceID: sourceID, sheetName: "s", key: "A-1", rowContent: "A-1")
        let unkeyed = RowMapper.identifier(sourceID: sourceID, sheetName: "s", key: nil, rowContent: "A-1")
        XCTAssertNotEqual(keyed, unkeyed)
    }
}

// MARK: - Suggestions

final class TableMappingSuggestionTests: XCTestCase {
    func testTheSuggestionPicksTextKeyAndFilters() {
        let shape = SheetShape(
            mode: .dataTable, headerRow: 1,
            columns: ["Артикул", "Название", "Описание", "Цена"],
            reason: ""
        )
        let mapping = TableMapping.suggested(sheetName: "Каталог", shape: shape)

        XCTAssertEqual(mapping.keyColumn, "Артикул")
        XCTAssertEqual(mapping.role(of: "Название"), .text)
        XCTAssertEqual(mapping.role(of: "Описание"), .text)
        XCTAssertEqual(mapping.role(of: "Цена"), .metadata)
    }

    /// A sheet with no prose column still has to produce documents with text in
    /// them, or every row would be dropped as empty.
    func testASheetWithoutProseStillGetsATextColumn() {
        let shape = SheetShape(mode: .dataTable, headerRow: 1, columns: ["Код", "Цена"], reason: "")
        let mapping = TableMapping.suggested(sheetName: "s", shape: shape)
        XCTAssertTrue(mapping.textColumns.contains("Код"))
    }
}
