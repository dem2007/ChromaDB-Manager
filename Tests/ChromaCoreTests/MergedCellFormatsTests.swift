import XCTest
@testable import ChromaCore

/// объединённые ячейки в каждом формате приходят к одному правилу.
final class MergedCellFormatsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").filter { $0.hasPrefix("|") }
    }

    // MARK: - HTML

    /// Документ о приёмке: «Единица измерения» над «код» и «обозначение»,
    /// а «№» и «Количество» — на две строки шапки. Раньше `rowspan` и
    /// `colspan` не читались, и количество вставало под единицу измерения.
    func testHTMLSpansKeepValuesUnderTheirHeadings() throws {
        let page = try HTMLParser.parse("""
        <table>
        <tr><th rowspan="2">№</th><th colspan="2">Единица измерения</th><th rowspan="2">Количество</th>\
        <th rowspan="2">Сумма</th></tr>
        <tr><th>код</th><th>обозначение</th></tr>
        <tr><td>1</td><td>876</td><td>усл. ед.</td><td>1</td><td>874 798 752,70</td></tr>
        <tr><td colspan="4">Всего к оплате</td><td>874 798 752,70</td></tr>
        </table>
        """, baseURL: nil)
        XCTAssertEqual(lines(page.plainText), [
            "| № | Единица измерения / код | Единица измерения / обозначение | Количество | Сумма |",
            "| --- | --- | --- | --- | --- |",
            "| 1 | 876 | усл. ед. | 1 | 874 798 752,70 |",
            "| Всего к оплате | Всего к оплате | Всего к оплате | Всего к оплате | 874 798 752,70 |",
        ])
    }

    /// Объединение вниз в строках данных — в каждой строке.
    func testHTMLRowspanRepeatsDown() throws {
        let page = try HTMLParser.parse("""
        <table><tr><th>Площадка</th><th>Позиция</th></tr>
        <tr><td rowspan="2">Энск</td><td>Сервер</td></tr>
        <tr><td>Коммутатор</td></tr></table>
        """, baseURL: nil)
        XCTAssertEqual(lines(page.plainText).last, "| Энск | Коммутатор |")
    }

    // MARK: - DOCX

    private func docx(_ body: String) async throws -> String {
        let url = root.appendingPathComponent("t-\(UUID().uuidString).docx")
        try DocxFixture(body: body).build().write(to: url)
        return try await OfficeExtractor().extract(from: url, options: ExtractionOptions()).plainText
    }

    private func cell(_ text: String, span: Int = 1, merge: String? = nil) -> String {
        var properties = span > 1 ? "<w:gridSpan w:val=\"\(span)\"/>" : ""
        if let merge { properties += merge == "restart" ? "<w:vMerge w:val=\"restart\"/>" : "<w:vMerge/>" }
        let content = text.isEmpty ? "<w:p/>" : DocxFixture.paragraph(text)
        return "<w:tc><w:tcPr>\(properties)</w:tcPr>\(content)</w:tc>"
    }

    /// Ячейка на две колонки — в первой из них, а не в последней; пропуск
    /// в начале строки (`w:gridBefore`) не сдвигает строку влево.
    func testDocxSpansAndSkippedCellsKeepColumns() async throws {
        let text = try await docx("<w:tbl>"
            + "<w:tr>" + cell("Позиция") + cell("Цена", span: 2) + cell("Срок") + "</w:tr>"
            + "<w:tr>" + cell("Болт") + cell("12") + cell("руб.") + cell("май") + "</w:tr>"
            + "<w:tr><w:trPr><w:gridBefore w:val=\"1\"/></w:trPr>" + cell("15") + cell("руб.") + cell("июнь") + "</w:tr>"
            + "</w:tbl>")
        XCTAssertEqual(lines(text), [
            "| Позиция | Цена | Срок |", "| --- | --- | --- |",
            "| Болт | 12 руб. | май |", "|  | 15 руб. | июнь |",
        ])
    }

    /// Две строки шапки, помеченные повторяемыми, — одна строка подписей;
    /// строка-раздел — колонкой.
    func testDocxHeaderRowsAndSections() async throws {
        let header = "<w:trPr><w:tblHeader/></w:trPr>"
        let text = try await docx("<w:tbl>"
            + "<w:tr>\(header)" + cell("№", merge: "restart") + cell("Стоимость", span: 2) + "</w:tr>"
            + "<w:tr>\(header)" + cell("", merge: "continue") + cell("без НДС") + cell("с НДС") + "</w:tr>"
            + "<w:tr>" + cell("Площадка Энск", span: 3) + "</w:tr>"
            + "<w:tr>" + cell("1") + cell("100") + cell("122") + "</w:tr>"
            + "<w:tr>" + cell("Площадка Городец", span: 3) + "</w:tr>"
            + "<w:tr>" + cell("2") + cell("200") + cell("244") + "</w:tr>"
            + "</w:tbl>")
        XCTAssertEqual(lines(text), [
            "| Раздел | № | Стоимость / без НДС | Стоимость / с НДС |", "| --- | --- | --- | --- |",
            "| Площадка Энск | 1 | 100 | 122 |", "| Площадка Городец | 2 | 200 | 244 |",
        ])
    }

    /// Вложенная таблица — текст клетки внешней, а не отдельная таблица,
    /// рвущая внешнюю надвое.
    func testDocxNestedTableStaysInItsCell() async throws {
        let nested = "<w:tbl><w:tr>" + cell("вложено 1") + cell("вложено 2") + "</w:tr></w:tbl>"
        let text = try await docx("<w:tbl>"
            + "<w:tr>" + cell("Позиция") + cell("Состав") + "</w:tr>"
            + "<w:tr>" + cell("Сервер") + "<w:tc><w:tcPr/>\(nested)<w:p/></w:tc>" + "</w:tr>"
            + "<w:tr>" + cell("Коммутатор") + cell("порты") + "</w:tr>"
            + "</w:tbl>")
        XCTAssertEqual(lines(text), [
            "| Позиция | Состав |", "| --- | --- |",
            "| Сервер | вложено 1 / вложено 2 |", "| Коммутатор | порты |",
        ])
    }

    // MARK: - XLSX

    /// Блок «две колонки на три строки» заполняет весь прямоугольник.
    func testXLSXBlockMergeFillsTheWholeBlock() throws {
        var builder = XLSXFixtureBuilder()
        builder.sheets = [.init(
            name: "Лист",
            rows: [
                [.shared("Раздел"), .absent, .shared("Позиция")],
                [.shared("Энск"), .absent, .shared("Сервер")],
                [.absent, .absent, .shared("Коммутатор")],
            ],
            merges: ["A2:B3"]
        )]
        let url = root.appendingPathComponent("book.xlsx")
        try builder.build().write(to: url)
        let reader = try XLSXReader(url: url)
        let result = try reader.rows(of: reader.sheets[0])
        for row in 1...2 {
            XCTAssertEqual(result.rows[row].value(at: 0), .text("Энск"))
            XCTAssertEqual(result.rows[row].value(at: 1), .text("Энск"))
        }
        XCTAssertEqual(result.rows[0].value(at: 1), .empty, "шапка вне блока не трогается")
        XCTAssertEqual(result.warnings, [])
    }

    // MARK: - Правило во всех книгах

    /// `.xls`: блок «две колонки на две строки» — значение во всех четырёх
    /// клетках; строка «Итого», объединённая вбок, — в каждой колонке.
    func testXLSMergesFillTheWholeRectangle() throws {
        let url = root.appendingPathComponent("book.xls")
        try XLSFixture(sheets: [.init(name: "Лист", rows: [
            [.shared("Раздел"), .blank, .shared("Позиция")],
            [.shared("Энск"), .blank, .shared("Сервер")],
            [.blank, .blank, .shared("Коммутатор")],
            [.shared("Итого"), .blank, .number(2)],
        ], merges: ["A2:B3", "A4:B4"])]).build().write(to: url)
        let reader = try XLSReader(url: url)
        let rows = try reader.rows(of: reader.sheets[0]).rows
        for row in 1...2 {
            XCTAssertEqual(rows[row].value(at: 0), .text("Энск"))
            XCTAssertEqual(rows[row].value(at: 1), .text("Энск"))
        }
        XCTAssertEqual(rows[3].value(at: 1), .text("Итого"))
        XCTAssertEqual(rows[0].value(at: 1), .empty, "вне объединений ничего не появляется")
    }

    /// `.ods`: блок — так же, как в `.xlsx` и `.xls`.
    func testODSMergesFillTheWholeRectangle() throws {
        var builder = ODSFixtureBuilder()
        builder.tables = [.init(name: "Лист", rows: [
            [.string("Раздел"), .string(""), .string("Позиция")],
            [.spanning(.string("Энск"), rows: 2, columns: 2), .covered, .string("Сервер")],
            [.covered, .covered, .string("Коммутатор")],
        ])]
        let url = root.appendingPathComponent("book.ods")
        try builder.build().write(to: url)
        let reader = try ODSReader(url: url)
        let rows = try reader.rows(of: reader.sheets[0]).rows
        for row in 1...2 {
            XCTAssertEqual(rows[row].value(at: 0), .text("Энск"))
            XCTAssertEqual(rows[row].value(at: 1), .text("Энск"))
        }
        XCTAssertEqual(rows[2].value(at: 2), .text("Коммутатор"))
    }

    /// Таблица документа: строка «Итого» на три колонки и блок на две
    /// строки — значение в каждой клетке, которую объединение накрывает.
    func testDocumentTablesSpreadBothWays() {
        let table = SpannedTable(cells: [
            .init(text: "Раздел", row: 0, column: 0), .init(text: "Вид", row: 0, column: 1),
            .init(text: "Позиция", row: 0, column: 2), .init(text: "Цена", row: 0, column: 3),
            .init(text: "Энск", row: 1, column: 0, rowSpan: 2, columnSpan: 2),
            .init(text: "Сервер", row: 1, column: 2), .init(text: "10", row: 1, column: 3),
            .init(text: "Коммутатор", row: 2, column: 2), .init(text: "5", row: 2, column: 3),
            .init(text: "Итого", row: 3, column: 0, columnSpan: 3), .init(text: "15", row: 3, column: 3),
        ])
        XCTAssertEqual(table.rows(mergingRecords: false), [
            ["Раздел", "Вид", "Позиция", "Цена"],
            ["Энск", "Энск", "Сервер", "10"],
            ["Энск", "Энск", "Коммутатор", "5"],
            ["Итого", "Итого", "Итого", "15"],
        ])
    }

    /// `.docx`: `gridSpan` и `vMerge` — тем же правилом.
    func testDocxSpreadsBothWays() async throws {
        let text = try await docx("<w:tbl>"
            + "<w:tr>" + cell("Раздел") + cell("Вид") + cell("Позиция") + "</w:tr>"
            + "<w:tr>" + cell("Энск", span: 2, merge: "restart") + cell("Сервер") + "</w:tr>"
            + "<w:tr>" + cell("", span: 2, merge: "continue") + cell("Коммутатор") + "</w:tr>"
            + "</w:tbl>")
        XCTAssertEqual(lines(text), [
            "| Раздел | Вид | Позиция |", "| --- | --- | --- |",
            "| Энск | Энск | Сервер |", "| Энск | Энск | Коммутатор |",
        ])
    }

    /// Название над таблицей, разложенное по колонкам, — не шапка; строки-
    /// разделы на всю ширину — не записи и не повод счесть таблицу отчётом.
    /// Раньше обе строки были одной ячейкой, и так их и понимали; разложенные
    /// по колонкам, они должны пониматься так же.
    func testTitlesAndSectionsSpreadAcrossTheTableStayWhatTheyWere() throws {
        var titled = XLSXFixtureBuilder()
        titled.sheets = [.init(name: "Лист", rows: [
            [.shared("Отчёт за март"), .absent, .absent],
            [.shared("Артикул"), .shared("Название"), .shared("Цена")],
            [.shared("A-1"), .shared("Болт"), .number(5)],
        ], merges: ["A1:C1"])]
        let titledURL = root.appendingPathComponent("titled.xlsx")
        try titled.build().write(to: titledURL)
        let titledReader = try XLSXReader(url: titledURL)
        let titledRows = try titledReader.rows(of: titledReader.sheets[0]).rows
        XCTAssertNotEqual(SheetModeDetector.suggest(rows: titledRows).headerRow, 1, "название принято за шапку")

        var sectioned = XLSXFixtureBuilder()
        sectioned.sheets = [.init(name: "Лист", rows: [
            [.shared("Артикул"), .shared("Название"), .shared("Цена")],
            [.shared("Крепёж"), .absent, .absent],
            [.shared("A-1"), .shared("Болт"), .number(5)],
            [.shared("A-2"), .shared("Гайка"), .number(3)],
            [.shared("Профиль"), .absent, .absent],
            [.shared("A-3"), .shared("Уголок"), .number(1)],
        ], merges: ["A2:C2", "A5:C5"])]
        let url = root.appendingPathComponent("sectioned.xlsx")
        try sectioned.build().write(to: url)
        let reader = try XLSXReader(url: url)
        let read = try reader.rowsAndMerges(of: reader.sheets[0])
        let shape = SheetModeDetector.suggest(rows: read.rows)
        XCTAssertEqual(shape.mode, .dataTable, shape.reason)

        let mapping = TableMapping(
            sheetName: "Лист", headerRow: 1, columns: ["Артикул", "Название", "Цена"],
            roles: ["Артикул": .metadata, "Название": .text, "Цена": .metadata], keyColumn: "Артикул"
        )
        let plan = TableSyncPlanner.plan(
            rows: read.rows, mapping: mapping, layout: SheetLayout(shape: shape),
            manifest: SheetManifest(sheetName: "Лист"), sourceID: UUID(), sourceFile: "f.xlsx",
            merges: read.merges
        )
        XCTAssertEqual(plan.added.count, 3, "разделы стали записями")
        XCTAssertEqual(plan.empty, [2, 5])
    }

    // MARK: - DOC

    /// Описание строки `.doc`: границы ячеек и признак продолжения вниз.
    func testDocRowDefinitionIsParsed() {
        var bytes: [UInt8] = [0, 0, 2]               // длина операнда (её учёл обход), две ячейки
        for edge in [0, 1440, 4320] {                // границы в двадцатых долях пункта
            bytes += [UInt8(edge & 0xFF), UInt8(edge >> 8)]
        }
        var first = [UInt8](repeating: 0, count: 20)
        first[0] = 0x60                              // vertMerge = 3: начало объединения
        var second = [UInt8](repeating: 0, count: 20)
        second[0] = 0x20                             // vertMerge = 1: продолжение
        bytes += first + second
        let cells = DocPartsReader.tableCells(Data(bytes))
        XCTAssertEqual(cells?.map(\.left), [0, 1440])
        XCTAssertEqual(cells?.map(\.right), [1440, 4320])
        XCTAssertEqual(cells?.map(\.continuesAbove), [false, true])
    }

    /// Ячейки разных строк — на общую сетку по границам.
    func testDocCellsAreSnappedToOneGrid() {
        typealias Paragraph = DocxPartsReader.Paragraph
        var paragraphs = [
            Paragraph(text: "Цена", cell: .init(table: 0, row: 0, column: 0)),
            Paragraph(text: "12", cell: .init(table: 0, row: 1, column: 0)),
            Paragraph(text: "руб.", cell: .init(table: 0, row: 1, column: 1)),
        ]
        DocPartsReader.placeOnGrid(
            &paragraphs,
            placed: [(0, 0, 0), (1, 1, 0), (2, 1, 1)],
            rows: [
                0: [.init(left: 0, right: 2880)],
                1: [.init(left: 0, right: 1440), .init(left: 1450, right: 2880)],
            ]
        )
        XCTAssertEqual(paragraphs[0].cell?.columnSpan, 2, "ячейка на всю ширину занимает обе колонки")
        XCTAssertEqual(paragraphs[2].cell?.column, 1)
    }
}
