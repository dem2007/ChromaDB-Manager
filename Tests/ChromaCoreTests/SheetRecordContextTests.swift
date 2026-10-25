import XCTest
@testable import ChromaCore

/// таблицы книг и документов: шапка в несколько строк, ряд
/// нумерации граф, название первой строкой, путь записи, ключ «№».
final class SheetRecordContextTests: XCTestCase {
    private let sourceID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!

    private func row(_ number: Int, _ values: [String]) -> SheetRow {
        var cells: [Int: CellValue] = [:]
        for (index, value) in values.enumerated() where !value.isEmpty { cells[index] = .text(value) }
        return SheetRow(number: number, cells: cells)
    }

    private func plan(
        _ rows: [SheetRow], mapping: TableMapping, merges: [XLSXReader.MergedRange] = [],
        manifest: SheetManifest? = nil
    ) -> SheetSyncPlan {
        TableSyncPlanner.plan(
            rows: rows, mapping: mapping, layout: SheetLayout(mapping: mapping),
            manifest: manifest ?? SheetManifest(sheetName: "Лист"),
            sourceID: sourceID, sourceFile: "расчёт.xlsx", merges: merges
        )
    }

    // MARK: - Ряд нумерации граф

    func testAColumnNumberingRowIsRecognised() {
        XCTAssertTrue(TableText.isColumnNumbering(["1", "2", "3", "4", "5"]))
        XCTAssertTrue(TableText.isColumnNumbering(["А", "1", "1а", "2", "3"]), "графа с буквой")
        XCTAssertTrue(TableText.isColumnNumbering(["1", "2", "", "3", "5", "6"]), "пустая и пропущенная графа")
        XCTAssertFalse(TableText.isColumnNumbering(["1", "1", "2", "3"]), "количества, а не графы")
        XCTAssertFalse(TableText.isColumnNumbering(["0", "1", "1", "2"]))
        XCTAssertFalse(TableText.isColumnNumbering(["10", "11", "12"]), "не с начала")
        XCTAssertFalse(TableText.isColumnNumbering(["1", "Сервер", "3"]))
        XCTAssertFalse(TableText.isColumnNumbering(["1", "2"]), "мало граф")
        XCTAssertFalse(TableText.isColumnNumbering(["1", "3", "5", "7"]), "одни скачки")
    }

    /// В документе ряд «1 | 2 | 3» под шапкой — не строка таблицы.
    func testTheNumberingRowLeavesADocumentTable() {
        let rows = TableRecords.merged([
            ["№", "Наименование", "Кол-во"],
            ["1", "2", "3"],
            ["1", "Сервер", "2"],
        ])
        XCTAssertEqual(rows, [["№", "Наименование", "Кол-во"], ["1", "Сервер", "2"]])
    }

    /// В книге — не запись; строка ниже с такими же числами — запись.
    func testTheNumberingRowIsNotARecord() {
        let mapping = TableMapping(
            sheetName: "Лист", mode: .dataTable, headerRow: 1, columns: ["Наименование", "Роль", "Часы"],
            roles: ["Наименование": .text, "Роль": .text, "Часы": .metadata]
        )
        let rows = [
            row(1, ["Наименование", "Роль", "Часы"]),
            row(2, ["1", "2", "3"]),
            row(3, ["Анализ", "Архитектор", "8"]),
        ]
        let result = plan(rows, mapping: mapping)
        XCTAssertEqual(result.added.compactMap { $0.metadata["row_number"] }, [.int(3)])
        XCTAssertEqual(RowMapper.dataRows(rows, below: nil, layout: SheetLayout(mapping: mapping)).count, 3,
                       "без шапки нумерации граф не бывает")
    }

    // MARK: - Название первой строкой

    func testATitleRowBecomesACaption() {
        typealias Cell = SpannedTable.Cell
        let table = SpannedTable(cells: [
            Cell(text: "Спецификация оборудования", row: 0, column: 0, columnSpan: 3),
            Cell(text: "№", row: 1, column: 0),
            Cell(text: "Наименование", row: 1, column: 1),
            Cell(text: "Кол-во", row: 1, column: 2),
            Cell(text: "1", row: 2, column: 0),
            Cell(text: "Сервер", row: 2, column: 1),
            Cell(text: "2", row: 2, column: 2),
        ])
        let (caption, rest) = table.separatingCaption()
        XCTAssertEqual(caption, "Спецификация оборудования")
        XCTAssertEqual(rest.rows().first, ["№", "Наименование", "Кол-во"])
        XCTAssertEqual(table.rendered().components(separatedBy: "\n").first, "Спецификация оборудования")
    }

    /// Одна строка под объединённой — это шапка с данными, не название.
    func testAMergedHeaderOverOneRowIsNotACaption() {
        typealias Cell = SpannedTable.Cell
        let table = SpannedTable(cells: [
            Cell(text: "Итого", row: 0, column: 0, columnSpan: 2),
            Cell(text: "1", row: 1, column: 0),
            Cell(text: "2", row: 1, column: 1),
        ])
        XCTAssertNil(table.separatingCaption().caption)
    }

    /// Хвост раздела во всю ширину над строкой данных — не название:
    /// строка с суммами шапкой не становится.
    func testASectionTailAboveDataIsNotACaption() {
        typealias Cell = SpannedTable.Cell
        let table = SpannedTable(cells: [
            Cell(text: "ИТ-инфраструктуры в г. Москве, Этап 1", row: 0, column: 0, columnSpan: 3),
            Cell(text: "технической поддержки #13", row: 1, column: 0),
            Cell(text: "1", row: 1, column: 1),
            Cell(text: "12 345 678,00", row: 1, column: 2),
            Cell(text: "Лицензия", row: 2, column: 0),
            Cell(text: "2", row: 2, column: 1),
            Cell(text: "100,00", row: 2, column: 2),
        ])
        XCTAssertNil(table.separatingCaption().caption)
        // А шапка с годами под названием — шапка.
        let years = SpannedTable(cells: [
            Cell(text: "Перечень услуг", row: 0, column: 0, columnSpan: 4),
            Cell(text: "№", row: 1, column: 0),
            Cell(text: "Наименование", row: 1, column: 1),
            Cell(text: "2026", row: 1, column: 2),
            Cell(text: "2027", row: 1, column: 3),
            Cell(text: "1", row: 2, column: 0),
            Cell(text: "vCPU", row: 2, column: 1),
            Cell(text: "0", row: 2, column: 2),
            Cell(text: "0", row: 2, column: 3),
        ])
        XCTAssertEqual(years.separatingCaption().caption, "Перечень услуг")
    }

    // MARK: - Шапка в несколько строк

    /// Расчёт трудозатрат: год над командами, команды над ролями.
    private var labour: (rows: [SheetRow], merges: [XLSXReader.MergedRange], mapping: TableMapping) {
        let rows = [
            row(1, ["Расчёт трудозатрат"]),
            row(2, ["", "", "Трудозатраты на 2026 г", "", ""]),
            row(3, ["", "", "Команда управления", "", "Разработка"]),
            row(4, ["№", "Работа", "Архитектор", "Аналитик", "Архитектор"]),
            row(5, ["1", "Анализ", "8", "16", "4"]),
        ]
        let merges = [
            XLSXReader.MergedRange(reference: "C2:E2")!,
            XLSXReader.MergedRange(reference: "C3:D3")!,
        ]
        let columns = ["№", "Работа", "Архитектор", "Аналитик", "Архитектор (2)"]
        let mapping = TableMapping(
            sheetName: "Лист", mode: .dataTable, headerRow: 4, columns: columns,
            roles: ["№": .metadata, "Работа": .text, "Архитектор": .metadata, "Аналитик": .metadata,
                    "Архитектор (2)": .metadata]
        )
        return (rows, merges, mapping)
    }

    func testParentHeaderRowsNameTheColumns() throws {
        let (rows, merges, mapping) = labour
        let labels = try XCTUnwrap(SheetHeaderLabels.labels(rows: rows, headerRow: 4, merges: merges, width: 5))
        XCTAssertEqual(labels, [
            "№", "Работа",
            "Трудозатраты на 2026 г / Команда управления / Архитектор",
            "Трудозатраты на 2026 г / Команда управления / Аналитик",
            "Трудозатраты на 2026 г / Разработка / Архитектор",
        ])
        let labelled = mapping.labelled(rows: rows, merges: merges, layout: SheetLayout(mapping: mapping))
        XCTAssertEqual(labelled.columns, mapping.columns, "имена колонок — по ним сопоставляют профиль")
        XCTAssertEqual(labelled.titles["Архитектор (2)"], "Трудозатраты на 2026 г / Разработка / Архитектор")
        XCTAssertNil(labelled.titles["Работа"], "одна строка — название не меняется")
    }

    /// Своё название человека главнее; без объединений шапка — одна строка.
    func testOwnTitlesAndPlainSheetsAreLeftAlone() {
        let (rows, merges, base) = labour
        var mapping = base
        mapping.titles["Аналитик"] = "Часы аналитика"
        let layout = SheetLayout(mapping: mapping)
        XCTAssertEqual(mapping.labelled(rows: rows, merges: merges, layout: layout).titles["Аналитик"], "Часы аналитика")
        XCTAssertEqual(mapping.labelled(rows: rows, merges: [], layout: layout), mapping)
    }

    /// Записи получают склеенные подписи, а подпись сопоставления та же:
    /// иначе экран профиля вечно просил бы переиндексации.
    func testThePlanUsesTheLabelsButKeepsTheSignature() throws {
        let (rows, merges, mapping) = labour
        let manifest = SheetManifest(sheetName: "Лист", mappingSignature: mapping.signature)
        let result = plan(rows, mapping: mapping, merges: merges, manifest: manifest)
        XCTAssertFalse(result.mappingChanged)
        let document = try XCTUnwrap(result.added.first)
        XCTAssertEqual(document.metadata["trudozatraty_na_2026_g_razrabotka_arhitektor"], nil, "ключи кириллицей")
        XCTAssertEqual(document.metadata["трудозатраты_на_2026_г_разработка_архитектор"], .string("4"))
        XCTAssertEqual(document.metadata["номер"], .string("1"))
    }

    /// Шапка в две строки: «№» и «Наименование» объединены вниз, под годом —
    /// подпись. Вторая строка — продолжение шапки, а не запись; название
    /// таблицы на всю ширину в подписи не идёт.
    func testAHeaderContinuedDownwardAndATitleAbove() throws {
        let rows = [
            row(2, ["Перечень услуг"]),
            row(4, ["№", "Наименование", "2026", ""]),
            row(5, ["№", "Наименование", "Стоимость", "Объём"]),
            row(6, ["1", "Процессор", "10", "2"]),
        ]
        let merges = ["A2:D2", "A4:A5", "B4:B5", "C4:D4"].compactMap(XLSXReader.MergedRange.init(reference:))
        XCTAssertEqual(SheetHeaderLabels.continuationEnd(headerRow: 4, merges: merges), 5)
        let labels = try XCTUnwrap(SheetHeaderLabels.labels(rows: rows, headerRow: 4, merges: merges, width: 4))
        XCTAssertEqual(labels, ["№", "Наименование", "2026 / Стоимость", "2026 / Объём"])
        let mapping = TableMapping(
            sheetName: "Лист", mode: .dataTable, headerRow: 4, columns: ["№", "Наименование", "2026", "D"],
            roles: ["№": .metadata, "Наименование": .text, "2026": .metadata, "D": .metadata]
        )
        let result = plan(rows, mapping: mapping, merges: merges)
        XCTAssertEqual(result.added.compactMap { $0.metadata["row_number"] }, [.int(6)])
        XCTAssertEqual(result.added.first?.metadata["2026_стоимость"], .string("10"))
        // Объединение вдоль данных шапку не продлевает.
        XCTAssertEqual(SheetHeaderLabels.continuationEnd(
            headerRow: 4, merges: [XLSXReader.MergedRange(reference: "A4:A20")!]), 4)
    }

    // MARK: - Путь записи

    private let works = TableMapping(
        sheetName: "Лист", mode: .dataTable, headerRow: 1, columns: ["№", "Наименование", "Часы"],
        roles: ["№": .metadata, "Наименование": .text, "Часы": .metadata]
    )

    func testANumberedRecordCarriesItsAncestors() {
        let rows = [
            row(1, ["№", "Наименование", "Часы"]),
            row(2, ["2.2", "Разработка ПО", ""]),
            row(3, ["2.2.1", "Группа подсистем", ""]),
            row(4, ["2.2.1.1", "Подсистема 1", "40"]),
            row(5, ["2.3", "Внедрение", "10"]),
        ]
        let texts = Dictionary(uniqueKeysWithValues: plan(rows, mapping: works).added.compactMap { document in
            document.metadata["row_number"].map { ($0, document.text) }
        })
        XCTAssertEqual(texts[.int(4)], "Наименование: 2.2 Разработка ПО / 2.2.1 Группа подсистем / Подсистема 1")
        XCTAssertEqual(texts[.int(3)], "Наименование: 2.2 Разработка ПО / Группа подсистем")
        XCTAssertEqual(texts[.int(5)], "Наименование: Внедрение", "у «2.3» в листе нет «2»")
    }

    /// Путь — в колонке, заполненной у разделов, а не в самой длинной.
    func testThePathGoesWhereTheSectionsAreNamed() {
        let mapping = TableMapping(
            sheetName: "Лист", mode: .dataTable, headerRow: 1, columns: ["№", "Наименование", "Результат"],
            roles: ["№": .metadata, "Наименование": .text, "Результат": .text]
        )
        let rows = [
            row(1, ["№", "Наименование", "Результат"]),
            row(2, ["4", "Эксплуатация", ""]),
            row(3, ["4.1", "Мониторинг", "Отчёт о результатах мониторинга за установленный период"]),
            row(4, ["4.2", "Резервное копирование", "Отчёт о результатах резервного копирования"]),
        ]
        let text = plan(rows, mapping: mapping).added.first { $0.metadata["row_number"] == .int(3) }?.text
        XCTAssertEqual(text, "Наименование: 4 Эксплуатация / Мониторинг\nРезультат: Отчёт о результатах мониторинга за установленный период")
    }

    /// Строка без номера — часть позиции над ней; метаданные — как в ячейке.
    func testAPartRowNamesItsPosition() {
        let rows = [
            row(1, ["№", "Наименование", "Часы"]),
            row(2, ["1", "Сервер в составе:", "2"]),
            row(3, ["", "CPU Xeon", ""]),
            row(4, ["", "", "7"]),
            row(5, ["2", "Стойка", "1"]),
        ]
        let added = plan(rows, mapping: works).added
        let part = added.first { $0.metadata["row_number"] == .int(3) }
        XCTAssertEqual(part?.text, "Наименование: 1 Сервер в составе: / CPU Xeon")
        XCTAssertNil(part?.metadata["наименование"], "текстовая колонка в метаданные не идёт")
        XCTAssertNil(added.first { $0.metadata["row_number"] == .int(4) }, "пустой текст путь не заполняет")
    }

    // MARK: - Ключ «№»

    func testSignsAreSpelledInKeys() {
        XCTAssertEqual(ColumnKeyNormaliser.normalise("№"), "номер")
        XCTAssertEqual(ColumnKeyNormaliser.normalise("№ п/п"), "номер_пп")
        XCTAssertEqual(ColumnKeyNormaliser.normalise("НДС, %"), "ндс_процент")
    }

    // MARK: - Объединения XLS и ODS

    func testXLSMergedCellsAreRead() {
        var payload = Data([2, 0])
        for value: UInt16 in [1, 1, 2, 4, 2, 2, 0, 1] { payload += withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        XCTAssertEqual(XLSReader.mergedRanges(payload), [
            XLSXReader.MergedRange(reference: "C2:E2")!,
            XLSXReader.MergedRange(reference: "A3:B3")!,
        ])
    }

    func testODSMergedCellsAreRead() throws {
        var builder = ODSFixtureBuilder()
        builder.tables = [.init(name: "Лист", rows: [
            [.string("Отчёт")],
            [.empty, .spanning(.string("2026"), rows: 1, columns: 2), .covered],
            [.spanning(.string("Раздел"), rows: 2, columns: 1), .string("a"), .string("b")],
            [.covered, .string("c"), .string("d")],
        ])]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-merge-\(UUID().uuidString).ods")
        try builder.build().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try ODSReader(url: url)
        XCTAssertEqual(try reader.rowsAndMerges(of: reader.sheets[0]).merges, [
            XLSXReader.MergedRange(reference: "B2:C2")!,
            XLSXReader.MergedRange(reference: "A3:A4")!,
        ])
    }

    // MARK: - Ревью

    /// Колонка-повтор без групп над ней остаётся «Архитектор (2)».
    func testAnUnrefinedDuplicateKeepsItsNumber() {
        let rows = [
            row(1, ["", "2026", "", ""]),
            row(2, ["Работа", "Архитектор", "Аналитик", "Архитектор"]),
            row(3, ["Анализ", "8", "16", "4"]),
        ]
        let merges = [XLSXReader.MergedRange(reference: "B1:C1")!]
        let mapping = TableMapping(
            sheetName: "Лист", mode: .dataTable, headerRow: 2,
            columns: ["Работа", "Архитектор", "Аналитик", "Архитектор (2)"],
            roles: ["Работа": .text, "Архитектор": .metadata, "Аналитик": .metadata, "Архитектор (2)": .metadata]
        )
        let labelled = mapping.labelled(rows: rows, merges: merges, layout: SheetLayout(mapping: mapping))
        XCTAssertEqual(labelled.titles["Архитектор"], "2026 / Архитектор")
        XCTAssertNil(labelled.titles["Архитектор (2)"])
    }

    /// Шапка листа глубже трёх строк: строка подписей остаётся шапкой,
    /// верхняя группа — названием над таблицей.
    func testATallSheetHeaderKeepsItsLabels() {
        let rows = [
            row(1, ["", "Всего", "", "", ""]),
            row(2, ["", "2026", "", "2027", ""]),
            row(3, ["", "Команда", "", "Команда", ""]),
            row(4, ["Работа", "Архитектор", "Аналитик", "Архитектор", "Аналитик"]),
            row(5, ["Анализ", "8", "16", "4", "2"]),
        ]
        let merges = ["B1:E1", "B2:C2", "D2:E2", "B3:C3", "D3:E3"].compactMap(XLSXReader.MergedRange.init(reference:))
        let rendered = SheetRenderer.render(rows: rows, headerRow: 4, merges: merges)
        XCTAssertEqual(rendered.header?.components(separatedBy: "\n").first,
                       "| Работа | 2026 / Команда / Архитектор | 2026 / Команда / Аналитик | 2027 / Команда / Архитектор | 2027 / Команда / Аналитик |")
        XCTAssertTrue(rendered.text.hasPrefix("Всего\n"), rendered.text)
    }

    /// «№» не отбирает ключ у настоящей колонки «Номер».
    func testASpelledSignYieldsToARealWord() {
        let map = ColumnKeyNormaliser.map(titles: ["№", "Номер", "НДС, %"])
        XCTAssertEqual(map.keys["Номер"], "номер")
        XCTAssertEqual(map.keys["№"], "номер_2")
        XCTAssertEqual(map.keys["НДС, %"], "ндс_процент")
    }

    /// Объединение в `.xls` разливается только по строкам, которые есть.
    func testXLSMergesDoNotInventRows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-xls-\(UUID().uuidString).xls")
        defer { try? FileManager.default.removeItem(at: url) }
        try XLSFixture(sheets: [.init(name: "Лист", rows: [
            [.inline("Площадка"), .inline("Позиция")],
            [.inline("Энск"), .inline("Сервер")],
            [.blank, .inline("Стойка")],
        ], merges: ["A2:A1000"])]).build().write(to: url)
        let reader = try XLSReader(url: url)
        let read = try reader.rowsAndMerges(of: reader.sheets[0])
        XCTAssertEqual(read.rows.count, 3)
        XCTAssertEqual(read.rows[2].value(at: 0), .text("Энск"))
        XCTAssertEqual(read.merges, [XLSXReader.MergedRange(reference: "A2:A1000")!])
    }

    /// `rowspan` больше числа строк обрезается, как в браузере.
    func testAnHTMLRowspanIsClampedToTheTable() throws {
        let page = try HTMLParser.parse("""
        <table><tr><th>Площадка</th><th>Позиция</th></tr>
        <tr><td rowspan="1000">Энск</td><td>Сервер</td></tr></table>
        """, baseURL: nil)
        XCTAssertEqual(page.plainText.components(separatedBy: "\n").filter { $0.hasPrefix("|") }.count, 3)
    }
}
