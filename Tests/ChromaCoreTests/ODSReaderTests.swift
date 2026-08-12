import XCTest
@testable import ChromaCore

/// Builds `.ods` files, the same way asks for the `.xlsx` ones: by script.
struct ODSFixtureBuilder {
    indirect enum Cell {
        case string(String)
        /// Several `<text:p>` in one cell — how ODS spells a multi-line value.
        case paragraphs([String])
        case number(Double)
        case boolean(Bool)
        case date(String)
        case empty
        /// One cell standing for several identical ones.
        case repeated(Cell, times: Int)
        /// The non-anchor part of a merge.
        case covered
    }

    struct Table {
        var name: String
        var isHidden = false
        var rows: [[Cell]]
        /// Rows written once with `number-rows-repeated`.
        var rowRepeats: [Int]?
    }

    var tables: [Table] = []

    func build() -> Data {
        var body = ""
        for table in tables {
            let visibility = table.isHidden ? " table:visibility=\"collapse\"" : ""
            body += "<table:table table:name=\"\(Self.escape(table.name))\"\(visibility)>"
            for (index, cells) in table.rows.enumerated() {
                let repeats = table.rowRepeats?[index] ?? 1
                let attribute = repeats > 1 ? " table:number-rows-repeated=\"\(repeats)\"" : ""
                body += "<table:table-row\(attribute)>"
                for cell in cells { body += Self.xml(for: cell) }
                body += "</table:table-row>"
            }
            body += "</table:table>"
        }

        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content \
        xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
        xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" \
        xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">\
        <office:body><office:spreadsheet>\(body)</office:spreadsheet></office:body>\
        </office:document-content>
        """

        var builder = ZIPFixtureBuilder()
        builder.entries.append(.init(path: "mimetype", contents: Data("application/vnd.oasis.opendocument.spreadsheet".utf8)))
        builder.entries.append(.init(path: "content.xml", contents: Data(content.utf8), deflated: true))
        return builder.build()
    }

    private static func xml(for cell: Cell, repeats: Int = 1) -> String {
        let attribute = repeats > 1 ? " table:number-columns-repeated=\"\(repeats)\"" : ""
        switch cell {
        case .repeated(let inner, let times):
            return xml(for: inner, repeats: times)
        case .covered:
            return "<table:covered-table-cell\(attribute)/>"
        case .empty:
            return "<table:table-cell\(attribute)/>"
        case .string(let value):
            return "<table:table-cell office:value-type=\"string\"\(attribute)><text:p>\(escape(value))</text:p></table:table-cell>"
        case .paragraphs(let values):
            let text = values.map { "<text:p>\(escape($0))</text:p>" }.joined()
            return "<table:table-cell office:value-type=\"string\"\(attribute)>\(text)</table:table-cell>"
        case .number(let value):
            let plain = value == value.rounded() ? String(Int(value)) : String(value)
            return "<table:table-cell office:value-type=\"float\" office:value=\"\(plain)\"\(attribute)><text:p>\(plain)</text:p></table:table-cell>"
        case .boolean(let value):
            return "<table:table-cell office:value-type=\"boolean\" office:boolean-value=\"\(value)\"\(attribute)/>"
        case .date(let iso):
            return "<table:table-cell office:value-type=\"date\" office:date-value=\"\(iso)\"\(attribute)/>"
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// OpenDocument, where emptiness is repetition rather than omission.
final class ODSReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-ods-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ builder: ODSFixtureBuilder, _ name: String = "book.ods") throws -> URL {
        let url = root.appendingPathComponent(name)
        try builder.build().write(to: url)
        return url
    }

    private func rows(_ builder: ODSFixtureBuilder, sheet: Int = 0) throws -> [SheetRow] {
        let reader = try ODSReader(url: try write(builder))
        return try reader.rows(of: reader.sheets[sheet]).rows
    }

    func testValuesCarryTheirOwnTypes() throws {
        var builder = ODSFixtureBuilder()
        builder.tables = [.init(name: "Лист", rows: [
            [.string("Товар"), .string("Цена"), .string("Есть"), .string("Дата")],
            [.string("Болт"), .number(12), .boolean(true), .date("2024-03-15")],
        ])]

        let rows = try rows(builder)
        XCTAssertEqual(rows[1].value(at: 0), .text("Болт"))
        XCTAssertEqual(rows[1].value(at: 1), .number(12))
        XCTAssertEqual(rows[1].value(at: 2), .boolean(true))
        guard case .date(let date) = rows[1].value(at: 3) else { return XCTFail("дата должна быть датой") }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        XCTAssertEqual(formatter.string(from: date), "2024-03-15")
    }

    /// ODS's version of the sparse-row trap: gaps are written as one cell that
    /// repeats, and ignoring the count shifts everything after it left.
    func testRepeatedColumnsHoldTheirPlaces() throws {
        var builder = ODSFixtureBuilder()
        builder.tables = [.init(name: "Лист", rows: [
            [.number(1), .repeated(.empty, times: 3), .number(5)],
        ])]

        let row = try rows(builder)[0]
        XCTAssertEqual(row.value(at: 0), .number(1))
        XCTAssertEqual(row.value(at: 1), .empty)
        XCTAssertEqual(row.value(at: 3), .empty)
        XCTAssertEqual(row.value(at: 4), .number(5), "после трёх пустых значение должно стоять в пятой колонке")
    }

    /// A repeated *value* really is that many cells — this is how ODS writes a
    /// column filled with the same thing.
    func testARepeatedValueFillsEveryCellItClaims() throws {
        var builder = ODSFixtureBuilder()
        builder.tables = [.init(name: "Лист", rows: [
            [.repeated(.string("да"), times: 3), .string("нет")],
        ])]

        let row = try rows(builder)[0]
        XCTAssertEqual(row.values(width: 4), [.text("да"), .text("да"), .text("да"), .text("нет")])
    }

    /// A sheet ends with a cell claiming to repeat to the edge of the format.
    /// Materialising that is how three rows become a million.
    func testAbsurdRepetitionIsCappedRatherThanMaterialised() throws {
        var builder = ODSFixtureBuilder()
        builder.tables = [.init(name: "Лист", rows: [
            [.string("Товар"), .repeated(.empty, times: 16_384)],
            [.string("Болт"), .repeated(.empty, times: 16_384)],
        ], rowRepeats: [1, 1_048_576])]

        let rows = try rows(builder)
        XCTAssertLessThanOrEqual(rows.count, ODSParser.repetitionLimit + 1)
        XCTAssertEqual(rows[0].value(at: 0), .text("Товар"))
        XCTAssertEqual(rows[1].value(at: 0), .text("Болт"))
    }

    /// A repeated row is that many identical rows — used for blocks of blanks
    /// and, occasionally, for real repeated data.
    func testARepeatedRowBecomesThatManyRows() throws {
        var builder = ODSFixtureBuilder()
        builder.tables = [.init(name: "Лист", rows: [
            [.string("шапка")],
            [.string("одно и то же")],
        ], rowRepeats: [1, 3])]

        let rows = try rows(builder)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(rows[3].value(at: 0), .text("одно и то же"))
    }

    /// The covered half of a merge holds no value of its own; reading one would
    /// duplicate the anchor's across the range.
    func testACoveredCellIsEmpty() throws {
        var builder = ODSFixtureBuilder()
        builder.tables = [.init(name: "Лист", rows: [
            [.string("Итого за квартал"), .covered],
        ])]
        let row = try rows(builder)[0]
        XCTAssertEqual(row.value(at: 0), .text("Итого за квартал"))
        XCTAssertEqual(row.value(at: 1), .empty)
    }

    func testSeveralParagraphsInOneCellBecomeSeveralLines() throws {
        var builder = ODSFixtureBuilder()
        builder.tables = [.init(name: "Лист", rows: [[.paragraphs(["первая", "вторая"])]])]
        XCTAssertEqual(try rows(builder)[0].value(at: 0), .text("первая\nвторая"))
    }

    func testSheetsAreListedWithTheirVisibility() throws {
        var builder = ODSFixtureBuilder()
        builder.tables = [
            .init(name: "Данные", rows: [[.string("a")]]),
            .init(name: "Служебный", isHidden: true, rows: [[.string("b")]]),
        ]
        let reader = try ODSReader(url: try write(builder))
        XCTAssertEqual(reader.sheets.map(\.name), ["Данные", "Служебный"])
        XCTAssertEqual(reader.sheets.map(\.isHidden), [false, true])
    }

    /// All tables share one `content.xml`, so reading the second must not pick
    /// up rows of the first.
    func testEachTableReadsOnlyItsOwnRows() throws {
        var builder = ODSFixtureBuilder()
        builder.tables = [
            .init(name: "Первый", rows: [[.string("первый")]]),
            .init(name: "Второй", rows: [[.string("второй")], [.string("ещё второй")]]),
        ]
        let reader = try ODSReader(url: try write(builder))
        let rows = try reader.rows(of: reader.sheet(named: "Второй")).rows
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].value(at: 0), .text("второй"))
    }

    func testReadingCanStopEarly() throws {
        var builder = ODSFixtureBuilder()
        builder.tables = [.init(name: "Лист", rows: (0..<200).map { [.number(Double($0))] })]
        let reader = try ODSReader(url: try write(builder))

        var seen = 0
        try reader.forEachRow(of: reader.sheets[0]) { _ in
            seen += 1
            return seen < 5
        }
        XCTAssertEqual(seen, 5)
    }

    func testAFileThatIsNotAnODSIsRefused() throws {
        let url = root.appendingPathComponent("not.ods")
        try Data("это не архив".utf8).write(to: url)
        XCTAssertThrowsError(try ODSReader(url: url))
    }

    /// ODS rows feed the same mapping as everything else.
    func testODSFeedsTheSharedPipeline() throws {
        var builder = ODSFixtureBuilder()
        builder.tables = [.init(name: "Каталог", rows: [
            [.string("Артикул"), .string("Название"), .string("Цена")],
            [.string("A-1"), .string("Болт"), .number(12)],
            [.string("A-2"), .string("Гайка"), .number(8)],
        ])]
        let rows = try rows(builder)
        XCTAssertEqual(SheetModeDetector.suggest(rows: rows).mode, .dataTable)
    }
}

// MARK: - .numbers

/// read by the application that owns the format, with's limits.
final class NumbersReaderTests: XCTestCase {
    private struct FakeExporter: NumbersExporting {
        let workbook: Data?
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()

        func exportWorkbook(from url: URL, to destination: URL, timeout: TimeInterval) async throws {
            counter.calls += 1
            guard let workbook else { throw ExtractionError.applicationUnavailable("Numbers не отвечает") }
            try workbook.write(to: destination)
        }
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-numbers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func workbookData() -> Data {
        var builder = XLSXFixtureBuilder()
        builder.sheets = [.init(name: "Лист 1", rows: [
            [.shared("Артикул"), .shared("Цена")],
            [.shared("A-1"), .number(12)],
        ])]
        return builder.build()
    }

    /// The whole point: Numbers converts, and the reader from 5.1 takes over.
    func testTheExportedWorkbookIsReadByTheXLSXReader() async throws {
        let source = root.appendingPathComponent("прайс.numbers")
        try Data("не важно — экспортёр подменён".utf8).write(to: source)

        let exporter = FakeExporter(workbook: workbookData())
        let (reader, temporary) = try await NumbersReader(exporter: exporter)
            .workbook(at: source, allowApplicationExport: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        XCTAssertEqual(exporter.counter.calls, 1)
        XCTAssertEqual(reader.sheets.map(\.name), ["Лист 1"])
        XCTAssertEqual(try reader.rows(of: reader.sheets[0]).rows[1].value(at: 1), .number(12))
    }

    /// Off unless asked: the export raises a window, so it never happens behind
    /// the user's back.
    func testWithoutTheSettingNothingIsExported() async throws {
        let source = root.appendingPathComponent("прайс.numbers")
        try Data("x".utf8).write(to: source)
        let exporter = FakeExporter(workbook: workbookData())

        await XCTAssertThrowsErrorAsync(
            try await NumbersReader(exporter: exporter).workbook(at: source, allowApplicationExport: false)
        ) { error in
            XCTAssertEqual(
                (error as? ExtractionError)?.errorDescription,
                ExtractionError.applicationUnavailable("экспорт через приложение выключен в настройках источника").errorDescription
            )
        }
        XCTAssertEqual(exporter.counter.calls, 0, "Numbers не должен подниматься вовсе")
    }

    func testAFailedExportIsReportedNotSwallowed() async throws {
        let source = root.appendingPathComponent("прайс.numbers")
        try Data("x".utf8).write(to: source)

        await XCTAssertThrowsErrorAsync(
            try await NumbersReader(exporter: FakeExporter(workbook: nil))
                .workbook(at: source, allowApplicationExport: true)
        )
    }

    ///'s lesson, which cost a live debugging session: a third-party app
    /// declares `com.apple.Numbers`, so only Apple's own identifier will do.
    func testNumbersIsAddressedByApplesOwnIdentifier() {
        XCTAssertEqual(AppleScriptNumbersExporter.bundleIdentifier, "com.apple.iWork.Numbers")
    }
}
