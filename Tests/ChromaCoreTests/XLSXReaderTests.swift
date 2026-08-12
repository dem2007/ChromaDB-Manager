import XCTest
@testable import ChromaCore

/// 2 and — the traps that make a naive XLSX parser return rubbish.
final class XLSXReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-xlsx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ builder: XLSXFixtureBuilder, _ name: String = "book.xlsx") throws -> URL {
        let url = root.appendingPathComponent(name)
        try builder.build().write(to: url)
        return url
    }

    private func readRows(_ builder: XLSXFixtureBuilder, sheet: Int = 0) throws -> [SheetRow] {
        let reader = try XLSXReader(url: try write(builder))
        return try reader.rows(of: reader.sheets[sheet]).rows
    }

    // MARK: - Shared strings (mandatory)

    /// Without the shared-strings table a column of names reads back as a column
    /// of integers — the single most common way to get this wrong.
    func testSharedStringsComeBackAsTextNotIndices() throws {
        var builder = XLSXFixtureBuilder()
        builder.sheets = [.init(name: "Данные", rows: [
            [.shared("Поставщик"), .shared("Город")],
            [.shared("Северсталь"), .shared("Череповец")],
            [.shared("Уралхим"), .shared("Березники")],
        ])]

        let rows = try readRows(builder)
        XCTAssertEqual(rows[0].value(at: 0), .text("Поставщик"))
        XCTAssertEqual(rows[1].value(at: 0), .text("Северсталь"))
        XCTAssertEqual(rows[2].value(at: 1), .text("Березники"))
    }

    /// Repeated text shares one entry; the reader must still give every cell its
    /// own value rather than only the first.
    func testRepeatedTextResolvesEverywhere() throws {
        var builder = XLSXFixtureBuilder()
        builder.sheets = [.init(name: "Лист", rows: [
            [.shared("да"), .shared("нет")],
            [.shared("да"), .shared("да")],
        ])]
        let rows = try readRows(builder)
        XCTAssertEqual(rows[1].value(at: 0), .text("да"))
        XCTAssertEqual(rows[1].value(at: 1), .text("да"))
    }

    func testInlineStringsAreReadToo() throws {
        var builder = XLSXFixtureBuilder()
        builder.sheets = [.init(name: "Лист", rows: [[.inline("Прямо в ячейке")]])]
        XCTAssertEqual(try readRows(builder)[0].value(at: 0), .text("Прямо в ячейке"))
    }

    // MARK: - Sparse rows (mandatory)

    /// The trap of: empty cells are simply absent from the file, so laying
    /// values out in the order they appear shifts everything after a gap left.
    func testSparseRowsDoNotShiftLeft() throws {
        var builder = XLSXFixtureBuilder()
        builder.sheets = [.init(name: "Лист", rows: [
            [.shared("A"), .shared("B"), .shared("C"), .shared("D")],
            // B and C missing entirely, not empty strings.
            [.number(1), .absent, .absent, .number(4)],
        ])]

        let rows = try readRows(builder)
        XCTAssertEqual(rows[1].value(at: 0), .number(1))
        XCTAssertEqual(rows[1].value(at: 1), .empty)
        XCTAssertEqual(rows[1].value(at: 2), .empty)
        XCTAssertEqual(rows[1].value(at: 3), .number(4), "значение четвёртой колонки не должно уехать во вторую")
        XCTAssertEqual(rows[1].values(width: 4), [.number(1), .empty, .empty, .number(4)])
    }

    /// Whole rows can be missing as well, and the numbers the file gives them
    /// are what the row numbering must follow.
    func testMissingRowsKeepTheirNumbers() throws {
        var builder = XLSXFixtureBuilder()
        builder.sheets = [.init(
            name: "Лист",
            rows: [[.shared("шапка")], [.shared("десятая")]],
            rowNumbers: [1, 10]
        )]
        let rows = try readRows(builder)
        XCTAssertEqual(rows.map(\.number), [1, 10])
    }

    // MARK: - Dates (mandatory)

    private func iso(_ value: CellValue) -> String? {
        guard case .date(let date) = value else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    func testASerialNumberWithADateFormatBecomesADate() throws {
        var builder = XLSXFixtureBuilder()
        // 45000 = 2023-03-15 in the 1900 system.
        builder.sheets = [.init(name: "Лист", rows: [[.date(serial: 45000), .number(45000)]])]
        let rows = try readRows(builder)
        XCTAssertEqual(iso(rows[0].value(at: 0)), "2023-03-15")
        // Same number without a date format stays a number — the format is the
        // only thing that decides.
        XCTAssertEqual(rows[0].value(at: 1), .number(45000))
    }

    func testTheFirstTwoMonthsOf1900AreOffByExcelsBug() throws {
        var builder = XLSXFixtureBuilder()
        builder.sheets = [.init(name: "Лист", rows: [[.date(serial: 1), .date(serial: 59), .date(serial: 61)]])]
        let rows = try readRows(builder)
        XCTAssertEqual(iso(rows[0].value(at: 0)), "1900-01-01")
        XCTAssertEqual(iso(rows[0].value(at: 1)), "1900-02-28")
        XCTAssertEqual(iso(rows[0].value(at: 2)), "1900-03-01")
    }

    /// Serial 60 is «29 February 1900», a day that never existed. Inventing a
    /// date for it would be worse than saying so.
    func testThePhantomLeapDayIsRefusedAndNamed() throws {
        var builder = XLSXFixtureBuilder()
        builder.sheets = [.init(name: "Лист", rows: [[.date(serial: 60)]])]
        let reader = try XLSXReader(url: try write(builder))
        let (rows, warnings) = try reader.rows(of: reader.sheets[0])

        XCTAssertEqual(rows[0].value(at: 0), .number(60))
        XCTAssertTrue(warnings.contains { if case .phantomLeapDay = $0 { return true }; return false })
    }

    func testThe1904WorkbooksUseTheirOwnEpoch() throws {
        var builder = XLSXFixtureBuilder()
        builder.uses1904 = true
        builder.sheets = [.init(name: "Лист", rows: [[.date(serial: 0), .date(serial: 366)]])]
        let reader = try XLSXReader(url: try write(builder))
        XCTAssertTrue(reader.uses1904Dates)
        let rows = try reader.rows(of: reader.sheets[0]).rows
        XCTAssertEqual(iso(rows[0].value(at: 0)), "1904-01-01")
        XCTAssertEqual(iso(rows[0].value(at: 1)), "1905-01-01")
    }

    func testACustomDateMaskCountsAsADate() throws {
        var builder = XLSXFixtureBuilder()
        builder.customDateMask = "dd.mm.yyyy"
        builder.sheets = [.init(name: "Лист", rows: [[.date(serial: 45000)]])]
        XCTAssertEqual(iso(try readRows(builder)[0].value(at: 0)), "2023-03-15")
    }

    /// A mask is not a date just because a letter in a quoted literal looks like
    /// one: `0" дней"` is a number of days, not a date.
    func testAMaskWithALiteralIsNotADate() {
        XCTAssertFalse(XLSXReader.maskIsDate("0\" дней\""))
        XCTAssertFalse(XLSXReader.maskIsDate("[Red]0.00"))
        XCTAssertFalse(XLSXReader.maskIsDate("General"))
        XCTAssertFalse(XLSXReader.maskIsDate("#,##0.00"))
        XCTAssertTrue(XLSXReader.maskIsDate("dd.mm.yyyy"))
        XCTAssertTrue(XLSXReader.maskIsDate("[$-419]d mmmm yyyy"))
        XCTAssertTrue(XLSXReader.maskIsDate("h:mm:ss"))
    }

    // MARK: - Formulas

    func testAFormulaIsReadFromItsCachedValue() throws {
        var builder = XLSXFixtureBuilder()
        builder.sheets = [.init(name: "Лист", rows: [[.formula("SUM(B1:C1)", cached: 42)]])]
        XCTAssertEqual(try readRows(builder)[0].value(at: 0), .number(42))
    }

    /// A file that was never recalculated has no cached value. The cell is
    /// empty — and the reader says so instead of pretending it read something.
    func testAFormulaWithoutACachedValueIsEmptyAndReported() throws {
        var builder = XLSXFixtureBuilder()
        builder.sheets = [.init(name: "Лист", rows: [[.formula("SUM(B1:C1)", cached: nil), .number(7)]])]
        let reader = try XLSXReader(url: try write(builder))
        let (rows, warnings) = try reader.rows(of: reader.sheets[0])

        XCTAssertEqual(rows[0].value(at: 0), .empty)
        XCTAssertEqual(rows[0].value(at: 1), .number(7), "соседняя ячейка не должна пострадать")
        XCTAssertEqual(warnings.first, .formulaWithoutValue(cells: 1))
    }

    // MARK: - Booleans and errors

    func testBooleansBecomeBooleans() throws {
        var builder = XLSXFixtureBuilder()
        builder.sheets = [.init(name: "Лист", rows: [[.boolean(true), .boolean(false)]])]
        let rows = try readRows(builder)
        XCTAssertEqual(rows[0].value(at: 0), .boolean(true))
        XCTAssertEqual(rows[0].value(at: 1), .boolean(false))
    }

    /// `#N/A` is not a value. Writing the string «#N/A» into metadata would make
    /// it filterable, which is precisely wrong.
    func testErrorValuesAreEmptyNotTheirText() throws {
        var builder = XLSXFixtureBuilder()
        builder.sheets = [.init(name: "Лист", rows: [[.error("#N/A"), .error("#DIV/0!")]])]
        let rows = try readRows(builder)
        XCTAssertEqual(rows[0].value(at: 0), .empty)
        XCTAssertEqual(rows[0].value(at: 1), .empty)
    }

    // MARK: - Sheets

    func testSheetsAreListedInOrderWithTheirHiddenFlag() throws {
        var builder = XLSXFixtureBuilder()
        builder.sheets = [
            .init(name: "Данные", rows: [[.shared("a")]]),
            .init(name: "Справочник", isHidden: true, rows: [[.shared("b")]]),
            .init(name: "Расчёты", rows: [[.shared("c")]]),
        ]
        let reader = try XLSXReader(url: try write(builder))
        XCTAssertEqual(reader.sheets.map(\.name), ["Данные", "Справочник", "Расчёты"])
        XCTAssertEqual(reader.sheets.map(\.isHidden), [false, true, false])
    }

    /// Each sheet's rows come from its own part — a mix-up here would be silent
    /// and total.
    func testEachSheetReadsItsOwnRows() throws {
        var builder = XLSXFixtureBuilder()
        builder.sheets = [
            .init(name: "Первый", rows: [[.shared("первый")]]),
            .init(name: "Второй", rows: [[.shared("второй")]]),
        ]
        let reader = try XLSXReader(url: try write(builder))
        XCTAssertEqual(try reader.rows(of: reader.sheet(named: "Второй")).rows[0].value(at: 0), .text("второй"))
    }

    func testAMissingSheetIsNamed() throws {
        var builder = XLSXFixtureBuilder()
        builder.sheets = [.init(name: "Данные", rows: [[.shared("a")]])]
        let reader = try XLSXReader(url: try write(builder))
        XCTAssertThrowsError(try reader.sheet(named: "Нет такого")) { error in
            XCTAssertEqual(error as? XLSXError, .sheetMissing("Нет такого"))
        }
    }

    // MARK: - Streaming and limits

    /// The preview reads twenty rows out of fifty thousand and stops. Without
    /// this the «первые 20 строк» of would cost a full parse.
    func testReadingCanStopEarly() throws {
        var builder = XLSXFixtureBuilder()
        builder.sheets = [.init(name: "Лист", rows: (0..<500).map { [.number(Double($0))] })]
        let reader = try XLSXReader(url: try write(builder))

        var seen = 0
        try reader.forEachRow(of: reader.sheets[0]) { _ in
            seen += 1
            return seen < 20
        }
        XCTAssertEqual(seen, 20)
    }

    func testTheRowLimitIsAnnouncedRatherThanSilent() throws {
        var builder = XLSXFixtureBuilder()
        builder.sheets = [.init(name: "Лист", rows: (0..<50).map { [.number(Double($0))] })]
        let reader = try XLSXReader(url: try write(builder))
        let (rows, warnings) = try reader.rows(of: reader.sheets[0], limits: .init(maxRows: 10))

        XCTAssertEqual(rows.count, 10)
        XCTAssertEqual(warnings.first, .rowLimitReached(limit: 10))
    }

    // MARK: - Column addressing

    func testColumnLettersAndIndicesAgree() {
        XCTAssertEqual(XLSXReader.columnIndex(ofReference: "A1"), 0)
        XCTAssertEqual(XLSXReader.columnIndex(ofReference: "B2"), 1)
        XCTAssertEqual(XLSXReader.columnIndex(ofReference: "Z100"), 25)
        XCTAssertEqual(XLSXReader.columnIndex(ofReference: "AA1"), 26)
        XCTAssertEqual(XLSXReader.columnIndex(ofReference: "BC12"), 54)
        XCTAssertEqual(XLSXReader.columnName(0), "A")
        XCTAssertEqual(XLSXReader.columnName(25), "Z")
        XCTAssertEqual(XLSXReader.columnName(26), "AA")
        XCTAssertEqual(XLSXReader.columnName(54), "BC")
    }

    // MARK: - Refusal

    func testAFileThatIsNotAWorkbookIsRefusedWithAReason() throws {
        let url = root.appendingPathComponent("not.xlsx")
        try Data("это не архив".utf8).write(to: url)
        XCTAssertThrowsError(try XLSXReader(url: url)) { error in
            guard case .notAWorkbook = error as? XLSXError else {
                return XCTFail("ожидался отказ по формату, получено \(error)")
            }
        }
    }

    /// A ZIP that is not a workbook — the reader must not mistake any archive
    /// for a spreadsheet.
    func testAnArchiveWithoutAWorkbookPartIsRefused() throws {
        var builder = ZIPFixtureBuilder()
        builder.entries.append(.init(path: "hello.txt", contents: Data("привет".utf8)))
        let url = root.appendingPathComponent("archive.xlsx")
        try builder.build().write(to: url)
        XCTAssertThrowsError(try XLSXReader(url: url))
    }

    /// `.xls` and `.xlsb` are different binary formats, not variants of
    /// OOXML. They are named, never half-parsed.
    func testTheOldBinaryFormatsAreNotClaimedAsSupported() {
        XCTAssertFalse(XLSXReader.supportedExtensions.contains("xls"))
        XCTAssertFalse(XLSXReader.supportedExtensions.contains("xlsb"))
        XCTAssertEqual(Set(XLSXReader.refusedExtensions), ["xls", "xlsb"])
    }

    // MARK: -

    /// The rule the whole stage rests on: a spreadsheet must not be reachable
    /// through the text-extraction registry, or it would be flattened into
    /// meaningless prose and embedded as such.
    func testASpreadsheetIsNotHandledByTheExtractionRegistry() {
        let url = URL(fileURLWithPath: "/tmp/book.xlsx")
        XCTAssertNil(ExtractorRegistry.standard().candidate(for: url))
    }
}

// MARK: - Merged cells

extension XLSXReaderTests {
    private func mergedFixture() -> XLSXFixtureBuilder {
        var builder = XLSXFixtureBuilder()
        builder.sheets = [.init(
            name: "Лист",
            rows: [
                // B1 merged — the value lives only in A1.
                [.shared("Итого за квартал"), .absent],
                [.shared("Северсталь"), .number(62)],
            ],
            merges: ["A1:B1"]
        )]
        return builder
    }

    /// Off by default: in a data table a merged cell is usually a heading, and
    /// copying it into every cell would invent values nobody typed.
    func testMergedCellsAreNotSpreadByDefault() throws {
        let rows = try readRows(mergedFixture())
        XCTAssertEqual(rows[0].value(at: 0), .text("Итого за квартал"))
        XCTAssertEqual(rows[0].value(at: 1), .empty)
    }

    func testMergedCellsSpreadWhenAsked() throws {
        let reader = try XLSXReader(url: try write(mergedFixture()))
        let rows = try reader.rows(of: reader.sheets[0], limits: .init(spreadMergedCells: true)).rows
        XCTAssertEqual(rows[0].value(at: 0), .text("Итого за квартал"))
        XCTAssertEqual(rows[0].value(at: 1), .text("Итого за квартал"))
        XCTAssertEqual(rows[1].value(at: 1), .number(62), "строки вне диапазона не трогаются")
    }

    func testAMergeReferenceIsParsedBothWays() {
        let range = XLSXReader.MergedRange(reference: "B2:D5")
        XCTAssertEqual(range?.firstColumn, 1)
        XCTAssertEqual(range?.lastColumn, 3)
        XCTAssertEqual(range?.firstRow, 2)
        XCTAssertEqual(range?.lastRow, 5)
        XCTAssertNil(XLSXReader.MergedRange(reference: "B2"))
    }
}
