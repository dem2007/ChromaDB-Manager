import XCTest
@testable import ChromaCore

/// three ways to read a sheet, and the header rule that makes the second
/// of them worth anything.
final class SheetModeDetectionTests: XCTestCase {
    private func rows(_ grid: [[CellValue]], startingAt first: Int = 1) -> [SheetRow] {
        grid.enumerated().map { offset, line in
            var cells: [Int: CellValue] = [:]
            for (column, value) in line.enumerated() where !value.isEmpty {
                cells[column] = value
            }
            return SheetRow(number: first + offset, cells: cells)
        }
    }

    // MARK: - Data table

    func testAHeaderAndHomogeneousRowsAreADataTable() {
        let shape = SheetModeDetector.suggest(rows: rows([
            [.text("Артикул"), .text("Название"), .text("Цена")],
            [.text("A-1"), .text("Болт"), .number(12)],
            [.text("A-2"), .text("Гайка"), .number(8)],
            [.text("A-3"), .text("Шайба"), .number(3)],
        ]))

        XCTAssertEqual(shape.mode, .dataTable)
        XCTAssertEqual(shape.headerRow, 1)
        XCTAssertEqual(shape.columns, ["Артикул", "Название", "Цена"])
    }

    /// Gaps are normal in a real catalogue and must not disqualify the sheet.
    func testEmptyCellsDoNotBreakTheDetection() {
        let shape = SheetModeDetector.suggest(rows: rows([
            [.text("Код"), .text("Имя"), .text("Комментарий")],
            [.text("1"), .text("Первый"), .empty],
            [.text("2"), .text("Второй"), .text("есть")],
            [.text("3"), .text("Третий"), .empty],
        ]))
        XCTAssertEqual(shape.mode, .dataTable)
    }

    /// One untidy column among regular ones — a notes field with a stray number —
    /// should not turn a catalogue into one blob of text.
    func testOneMessyColumnDoesNotDisqualifyTheTable() {
        let shape = SheetModeDetector.suggest(rows: rows([
            [.text("Код"), .text("Название"), .text("Цена"), .text("Заметка")],
            [.text("1"), .text("Болт"), .number(12), .text("ок")],
            [.text("2"), .text("Гайка"), .number(8), .number(5)],
            [.text("3"), .text("Шайба"), .number(3), .text("уточнить")],
        ]))
        XCTAssertEqual(shape.mode, .dataTable)
    }

    /// The shape of a real price list: a narrow empty column at the left, the
    /// table starting from B. The column is empty from top to bottom, so it is a
    /// spacer — and judging the header by it used to reject the whole file
    ///.
    func testAnEmptySpacerColumnDoesNotDisqualifyTheHeader() {
        let shape = SheetModeDetector.suggest(rows: rows([
            [.empty, .text("Код позиции"), .text("Наименование"), .text("Кол-во, шт"), .text("Цена")],
            [.empty, .text("58.29.50.000"), .text("Программный комплекс 1"), .number(116), .number(446_600)],
            [.empty, .text("58.29.50.000"), .text("Программный комплекс 2"), .number(32805), .number(4550)],
            [.empty, .text("58.29.50.000"), .text("Программный комплекс 3"), .number(32805), .number(3280)],
        ]))

        XCTAssertEqual(shape.mode, .dataTable)
        XCTAssertEqual(shape.headerRow, 1)
        // The spacer keeps its place in the list: column titles are addressed by
        // position in the file, and dropping it would shift every index after it.
        XCTAssertEqual(shape.columns, ["A", "Код позиции", "Наименование", "Кол-во, шт", "Цена"])
    }

    func testASpacerColumnOnTheRightIsIgnoredToo() {
        let shape = SheetModeDetector.suggest(rows: rows([
            [.text("Код"), .text("Название"), .empty],
            [.text("1"), .text("Болт"), .empty],
            [.text("2"), .text("Гайка"), .empty],
        ]))
        XCTAssertEqual(shape.mode, .dataTable)
    }

    /// One title left off a wide table is a slip, not a reason to give up on it.
    func testOneMissingTitleAmongManyIsTolerated() {
        let shape = SheetModeDetector.suggest(rows: rows([
            [.text("Код"), .text("Название"), .text("Цена"), .text("Кол-во"), .empty],
            [.text("1"), .text("Болт"), .number(12), .number(5), .text("шт")],
            [.text("2"), .text("Гайка"), .number(8), .number(9), .text("шт")],
        ]))
        XCTAssertEqual(shape.mode, .dataTable, "4 названия из 5 — это строка заголовков")
    }

    /// A number in the title row is data, and data is not a title — this stays
    /// fatal however many other cells are filled.
    func testANumberAmongTheTitlesStillDisqualifiesTheRow() {
        let shape = SheetModeDetector.suggest(rows: rows([
            [.text("Код"), .text("Название"), .text("Цена"), .number(2024)],
            [.text("1"), .text("Болт"), .number(12), .number(5)],
            [.text("2"), .text("Гайка"), .number(8), .number(9)],
        ]))
        XCTAssertEqual(shape.mode, .document)
        XCTAssertNil(shape.headerRow)
    }

    // MARK: - Document

    /// The conservative direction: what the detector is unsure about becomes a
    /// document, which loses nothing. A wrong «data table» would produce a
    /// document per line of a report.
    func testAReportWithMixedColumnsIsADocument() {
        let shape = SheetModeDetector.suggest(rows: rows([
            [.text("Отчёт"), .text("за квартал"), .text("подписал")],
            [.text("Выручка"), .number(1200), .text("Иванов")],
            [.number(2024), .text("рост"), .number(15)],
            [.text("Итого"), .text("хорошо"), .date(Date())],
        ]))
        XCTAssertEqual(shape.mode, .document)
        XCTAssertTrue(shape.reason.contains("неоднородн"), shape.reason)
    }

    func testARowOfNumbersIsNotAHeader() {
        let shape = SheetModeDetector.suggest(rows: rows([
            [.number(1), .number(2), .number(3)],
            [.number(4), .number(5), .number(6)],
        ]))
        XCTAssertEqual(shape.mode, .document)
        XCTAssertNil(shape.headerRow)
    }

    func testAHeaderWithAGapIsNotAHeader() {
        let shape = SheetModeDetector.suggest(rows: rows([
            [.text("Название"), .empty, .text("Цена")],
            [.text("Болт"), .text("шт"), .number(12)],
        ]))
        XCTAssertEqual(shape.mode, .document)
    }

    func testASingleColumnIsTextNotATableOfRecords() {
        let shape = SheetModeDetector.suggest(rows: rows([
            [.text("Заметки по проекту")],
            [.text("Первый пункт")],
            [.text("Второй пункт")],
        ]))
        XCTAssertEqual(shape.mode, .document)
    }

    func testHeadersWithoutDataAreNotATable() {
        let shape = SheetModeDetector.suggest(rows: rows([
            [.text("Артикул"), .text("Название")],
        ]))
        XCTAssertEqual(shape.mode, .document)
        XCTAssertEqual(shape.headerRow, 1, "заголовки всё равно найдены и пригодятся")
    }

    // MARK: - Skip

    /// hidden sheets are hidden because somebody decided they are not
    /// for reading.
    func testAHiddenSheetIsSkippedByDefault() {
        let shape = SheetModeDetector.suggest(rows: rows([
            [.text("Код"), .text("Значение")],
            [.text("A"), .number(1)],
        ]), isHidden: true)
        XCTAssertEqual(shape.mode, .skip)
        XCTAssertTrue(shape.reason.contains("скрыт"))
    }

    func testAnEmptySheetIsSkipped() {
        XCTAssertEqual(SheetModeDetector.suggest(rows: []).mode, .skip)
        XCTAssertEqual(SheetModeDetector.suggest(rows: rows([[.empty, .empty]])).mode, .skip)
    }

    // MARK: - Headers

    /// Excel wraps a long header by putting a real newline in the cell. The
    /// title has to survive that as one line — a metadata key with a line break
    /// in it is a key nobody can type into a filter.
    func testAWrappedTitleBecomesOneLine() {
        let row = SheetRow(number: 1, cells: [
            0: .text("Код позиции\nОКПД2/КТРУ"),
            1: .text("Цена единицы,\nрубл"),
        ])
        XCTAssertEqual(
            SheetModeDetector.headerTitles(row, width: 2),
            ["Код позиции ОКПД2/КТРУ", "Цена единицы, рубл"]
        )
    }

    /// And a profile saved before that collapsing existed still matches the
    /// same file: both sides go through the same normalisation.
    func testAProfileSavedWithALineBreakStillMatches() {
        let layout = SheetLayout(headerRow: 1, columns: ["Цена единицы, рубл"])
        XCTAssertEqual(layout.index(of: "Цена единицы,\nрубл"), 0)
    }

    /// An unnamed column still needs a usable name downstream.
    func testAnUnnamedColumnGetsItsSpreadsheetLetter() {
        let row = SheetRow(number: 1, cells: [0: .text("Имя"), 2: .text("Цена")])
        XCTAssertEqual(SheetModeDetector.headerTitles(row, width: 3), ["Имя", "B", "Цена"])
    }

    /// The header row is where the *file* says it is: a sheet whose data starts
    /// at row 5 must report 5, not 1.
    func testTheHeaderRowIsTheFileRowNumber() {
        let shape = SheetModeDetector.suggest(rows: rows([
            [.text("Код"), .text("Имя")],
            [.text("1"), .text("Первый")],
            [.text("2"), .text("Второй")],
        ], startingAt: 5))
        XCTAssertEqual(shape.headerRow, 5)
    }
}

// MARK: - Rendering and the header rule

final class SheetRenderingTests: XCTestCase {
    private func rows(_ grid: [[CellValue]]) -> [SheetRow] {
        grid.enumerated().map { offset, line in
            var cells: [Int: CellValue] = [:]
            for (column, value) in line.enumerated() where !value.isEmpty { cells[column] = value }
            return SheetRow(number: offset + 1, cells: cells)
        }
    }

    func testASheetBecomesAMarkdownTable() {
        let rendered = SheetRenderer.render(rows: rows([
            [.text("Товар"), .text("Цена")],
            [.text("Болт"), .number(12)],
        ]), headerRow: 1)

        XCTAssertEqual(rendered.header, "| Товар | Цена |\n| --- | --- |")
        XCTAssertTrue(rendered.text.hasPrefix("| Товар | Цена |"))
        XCTAssertTrue(rendered.text.contains("| Болт | 12 |"))
    }

    /// A number that came from a spreadsheet reads as a number, not as `12.0`.
    func testWholeNumbersRenderWithoutADecimalTail() {
        let rendered = SheetRenderer.render(rows: rows([[.number(12), .number(3.5)]]), headerRow: nil)
        XCTAssertTrue(rendered.text.contains("| 12 | 3.5 |"), rendered.text)
    }

    /// A pipe inside a value would end the column early. The value is the
    /// user's, so it is escaped rather than dropped.
    func testAPipeInsideAValueIsEscaped() {
        let rendered = SheetRenderer.render(rows: rows([[.text("а|б"), .text("многострочный\nтекст")]]), headerRow: nil)
        XCTAssertTrue(rendered.text.contains("а\\|б"), rendered.text)
        XCTAssertFalse(rendered.text.contains("\n\n"))
        XCTAssertTrue(rendered.text.contains("многострочный текст"))
    }

    func testASingleColumnSheetIsPlainLinesNotATable() {
        let rendered = SheetRenderer.render(rows: rows([
            [.text("Первая заметка")],
            [.text("Вторая заметка")],
        ]), headerRow: 1)
        XCTAssertNil(rendered.header)
        XCTAssertEqual(rendered.text, "Первая заметка\nВторая заметка")
    }

    // MARK: - The rule calls mandatory

    /// Without this the second and every later chunk is a grid of values with
    /// no column names — rows of numbers that mean nothing on their own.
    func testEveryChunkKeepsTheHeader() {
        let header = "| Товар | Цена |\n| --- | --- |"
        let chunks = [
            TextChunk(index: 0, text: header + "\n| Болт | 12 |"),
            TextChunk(index: 1, text: "| Гайка | 8 |"),
            TextChunk(index: 2, text: "| Шайба | 3 |"),
        ]

        let result = SheetRenderer.repeatingHeader(header, in: chunks)
        XCTAssertTrue(result.allSatisfy { $0.text.hasPrefix(header) })
        // The chunk that already began with the header is not given a second one.
        XCTAssertEqual(result[0].text, chunks[0].text)
        XCTAssertNil(result[0].note)
        XCTAssertNotNil(result[1].note, "подмена содержимого чанка должна быть названа")
    }

    func testWithoutAHeaderNothingIsAdded() {
        let chunks = [TextChunk(index: 0, text: "просто текст")]
        XCTAssertEqual(SheetRenderer.repeatingHeader(nil, in: chunks), chunks)
        XCTAssertEqual(SheetRenderer.repeatingHeader("", in: chunks), chunks)
    }

    /// Индексы и связи чанков не должны пострадать от добавления заголовка.
    func testRepeatingTheHeaderKeepsChunkIdentity() {
        let header = "| A | B |\n| --- | --- |"
        let chunks = [
            TextChunk(index: 7, text: "| 1 | 2 |", level: 1, parentIndex: nil),
            TextChunk(index: 8, text: "| 3 | 4 |", level: 0, parentIndex: 7),
        ]
        let result = SheetRenderer.repeatingHeader(header, in: chunks)
        XCTAssertEqual(result.map(\.index), [7, 8])
        XCTAssertEqual(result.map(\.level), [1, 0])
        XCTAssertEqual(result[1].parentIndex, 7)
    }
}

// MARK: - Whole workbooks

final class WorkbookShapeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-shape-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// One workbook, three kinds of sheet — which is what a real file looks like.
    func testEachSheetGetsItsOwnProposal() throws {
        var builder = XLSXFixtureBuilder()
        builder.sheets = [
            .init(name: "Каталог", rows: [
                [.shared("Артикул"), .shared("Название"), .shared("Цена")],
                [.shared("A-1"), .shared("Болт"), .number(12)],
                [.shared("A-2"), .shared("Гайка"), .number(8)],
            ]),
            .init(name: "Пояснение", rows: [
                [.shared("Отчёт"), .shared("за квартал"), .shared("подписал")],
                [.shared("Выручка"), .number(1200), .shared("Иванов")],
                [.number(2024), .shared("рост"), .number(15)],
                [.shared("Итого"), .shared("хорошо"), .number(7)],
            ]),
            .init(name: "Служебный", isHidden: true, rows: [
                [.shared("Ключ"), .shared("Значение")],
                [.shared("k"), .number(1)],
            ]),
        ]
        let url = root.appendingPathComponent("book.xlsx")
        try builder.build().write(to: url)

        let shapes = try XLSXReader(url: url).shapes()
        XCTAssertEqual(shapes.map(\.sheet.name), ["Каталог", "Пояснение", "Служебный"])
        XCTAssertEqual(shapes.map(\.shape.mode), [.dataTable, .document, .skip])
        XCTAssertEqual(shapes[0].shape.columns, ["Артикул", "Название", "Цена"])
    }

    /// Judging a workbook must not cost a full parse.
    func testJudgingReadsOnlyASample() throws {
        var builder = XLSXFixtureBuilder()
        builder.sheets = [.init(name: "Большой", rows:
            [[.shared("Код"), .shared("Значение")]]
            + (0..<5000).map { [.shared("k\($0)"), .number(Double($0))] }
        )]
        let url = root.appendingPathComponent("big.xlsx")
        try builder.build().write(to: url)

        let shapes = try XLSXReader(url: url).shapes(sampleSize: 20)
        XCTAssertEqual(shapes[0].shape.mode, .dataTable)
        XCTAssertTrue(shapes[0].shape.reason.contains("20"), shapes[0].shape.reason)
    }
}
