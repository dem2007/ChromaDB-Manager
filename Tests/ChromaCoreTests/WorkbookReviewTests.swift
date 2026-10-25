import XCTest
@testable import ChromaCore

/// Ультраревью среза «книги Excel и их нарезка»: читалки.
final class WorkbookReviewTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-books-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func save(_ data: Data, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: - XLSX

    /// Лист, оборванный посреди XML, — ошибка, а не лист покороче: иначе
    /// строки после сбоя считались исчезнувшими.
    func testABrokenSheetIsAnErrorRatherThanAShorterSheet() throws {
        var builder = XLSXFixtureBuilder()
        builder.sheets = [.init(name: "Лист", rows: [
            [.shared("Артикул")],
            [.shared("A-1")],
            [.raw("<c r=\"REF\" t=\"inlineStr\"><is><t>сбой \u{1}</t></is></c>")],
            [.shared("A-3")],
        ])]
        let reader = try XLSXReader(url: try save(builder.build(), "broken.xlsx"))
        XCTAssertThrowsError(try reader.rowsAndMerges(of: reader.sheets[0])) { error in
            guard case .sheetBroken(let sheet, _) = error as? XLSXError else {
                return XCTFail("ждали sheetBroken, пришло \(error)")
            }
            XCTAssertEqual(sheet, "Лист")
        }
    }

    /// Остановка пределом строк — не сбой разбора.
    func testStoppingAtTheRowLimitIsNotABrokenSheet() throws {
        var builder = XLSXFixtureBuilder()
        builder.sheets = [.init(name: "Лист", rows: (1...5).map { [.number(Double($0))] })]
        let reader = try XLSXReader(url: try save(builder.build(), "long.xlsx"))
        let read = try reader.rowsAndMerges(of: reader.sheets[0], limits: XLSXReader.Limits(maxRows: 2))
        XCTAssertEqual(read.rows.count, 2)
        XCTAssertEqual(read.warnings, [.rowLimitReached(limit: 2)])
    }

    /// Ячейка `inlineStr` из нескольких кусков оформления — целиком,
    /// без фонетической подсказки.
    func testAnInlineStringKeepsEveryRun() throws {
        var builder = XLSXFixtureBuilder()
        builder.sheets = [.init(name: "Лист", rows: [[
            .raw("<c r=\"REF\" t=\"inlineStr\"><is><r><t xml:space=\"preserve\">Кабель </t></r><r><t>UTP 5e</t></r><rPh sb=\"0\" eb=\"1\"><t>かな</t></rPh></is></c>"),
        ]])]
        let reader = try XLSXReader(url: try save(builder.build(), "runs.xlsx"))
        let rows = try reader.rows(of: reader.sheets[0]).rows
        XCTAssertEqual(rows.first?.cells[0], .text("Кабель UTP 5e"))
    }

    // MARK: - CSV

    /// Длинный ряд цифр — номер: точнее пятнадцати знаков число его не держит.
    func testLongDigitRunsStayText() {
        XCTAssertEqual(DelimitedTableReader.inferred("40702810900000012345"), .text("40702810900000012345"))
        XCTAssertEqual(DelimitedTableReader.inferred("4276380012345678"), .text("4276380012345678"))
        XCTAssertEqual(DelimitedTableReader.inferred("123456789012345"), .number(123456789012345))
        XCTAssertEqual(DelimitedTableReader.inferred("-12"), .number(-12))
    }

    // MARK: - ODS

    /// Примечание к ячейке — не часть её значения.
    func testACellCommentIsNotPartOfTheValue() throws {
        var builder = ODSFixtureBuilder()
        builder.tables = [.init(name: "Лист", rows: [
            [.annotated(.string("Цена"), note: "уточнить у поставщика"), .string("Кол-во")],
        ])]
        let reader = try ODSReader(url: try save(builder.build(), "notes.ods"))
        let rows = try reader.rows(of: reader.sheets[0]).rows
        XCTAssertEqual(rows.first?.cells[0], .text("Цена"))
        XCTAssertEqual(rows.first?.cells[1], .text("Кол-во"))
    }

    /// Строки после большого пустого блока стоят под своими номерами.
    func testRowsAfterALongEmptyRunKeepTheirNumbers() throws {
        var builder = ODSFixtureBuilder()
        builder.tables = [.init(
            name: "Лист",
            rows: [[.string("Начало")], [.empty], [.string("Конец"), .repeated(.empty, times: 2000), .string("Справа")]],
            rowRepeats: [1, 3000, 1]
        )]
        let reader = try ODSReader(url: try save(builder.build(), "gap.ods"))
        let rows = try reader.rows(of: reader.sheets[0]).rows
        let last = try XCTUnwrap(rows.last)
        XCTAssertEqual(last.number, 3002)
        XCTAssertEqual(last.cells[0], .text("Конец"))
        XCTAssertEqual(last.cells[2001], .text("Справа"), "колонка после широкого пустого повтора уехала")
    }

    /// Лист, скрытый стилем (так его скрывает LibreOffice), — скрыт.
    func testASheetHiddenByItsStyleIsHidden() throws {
        var builder = ODSFixtureBuilder()
        builder.tables = [
            .init(name: "Данные", rows: [[.string("a")]]),
            .init(name: "Справочник", hiddenByStyle: true, rows: [[.string("b")]]),
        ]
        let reader = try ODSReader(url: try save(builder.build(), "hidden.ods"))
        XCTAssertEqual(reader.sheets.map(\.isHidden), [false, true])
    }

    // MARK: - XLS

    /// Диаграмма на листе — свой подпоток; её конец — не конец листа.
    func testAnEmbeddedChartDoesNotEndTheSheet() throws {
        let fixture = XLSFixture(sheets: [.init(
            name: "Лист",
            rows: [[.shared("Раздел"), .blank], [.shared("Позиция")]],
            merges: ["A1:B1"],
            embeddedChart: true
        )])
        let reader = try XLSReader(url: try save(fixture.build(), "chart.xls"))
        let read = try reader.rowsAndMerges(of: reader.sheets[0])
        XCTAssertEqual(read.merges.count, 1, "объединения после диаграммы не прочитаны")
        XCTAssertEqual(read.rows.first { $0.number == 1 }?.cells[1], .text("Раздел"))
    }

    // MARK: - Оговорки читалки

    /// Оговорки доходят до синхронизации — с именем листа.
    func testReaderWarningsReachTheCallerWithTheSheetName() async throws {
        var builder = XLSXFixtureBuilder()
        builder.sheets = [.init(name: "Расчёт", rows: [[.shared("Сумма")], [.formula("A1*2", cached: nil)]])]
        let url = try save(builder.build(), "formulas.xlsx")
        let read = try await TableSyncService.read(url: url)
        XCTAssertEqual(read.warnings.count, 1)
        XCTAssertTrue(read.warnings[0].hasPrefix("лист «Расчёт»: формул без сохранённого значения"), read.warnings[0])
    }
}
