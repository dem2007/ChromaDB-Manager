import XCTest
@testable import ChromaCore

/// CSV and TSV, where the encoding and the delimiter both have to be
/// worked out rather than assumed.
final class DelimitedTableTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-csv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ data: Data, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func write(_ text: String, _ name: String, encoding: String.Encoding = .utf8, bom: Bool = false) throws -> URL {
        var data = Data()
        if bom, encoding == .utf8 { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        data.append(text.data(using: encoding)!)
        return try write(data, name)
    }

    // MARK: - Encoding

    func testUTF8IsRecognised() throws {
        let url = try write("Название,Цена\nБолт,12\n", "utf8.csv")
        XCTAssertEqual(try DelimitedTableReader.detect(url: url).encoding, .utf8)
    }

    func testAByteOrderMarkIsRecognisedAndStripped() throws {
        let url = try write("Название,Цена\nБолт,12\n", "bom.csv", bom: true)
        let format = try DelimitedTableReader.detect(url: url)
        XCTAssertEqual(format.encoding, .utf8WithBOM)

        let rows = try DelimitedTableReader.rows(url: url).rows
        // Without stripping the BOM the first column would be named «\u{FEFF}Название»
        // and never match a saved mapping.
        XCTAssertEqual(rows[0].value(at: 0), .text("Название"))
    }

    /// The case Latin-1 hides: a Cyrillic CSV in Windows-1251 read as Latin-1
    /// never fails, it just turns «Болт» into «Áîëò» — a successful-looking
    /// import of rubbish.
    func testWindows1251IsReadAsCyrillicNotAsLatin1() throws {
        let url = try write("Название;Цена\nБолт;12\n", "cp1251.csv", encoding: .windowsCP1251)
        let format = try DelimitedTableReader.detect(url: url)
        XCTAssertEqual(format.encoding, .windows1251)

        let rows = try DelimitedTableReader.rows(url: url).rows
        XCTAssertEqual(rows[0].value(at: 0), .text("Название"))
        XCTAssertEqual(rows[1].value(at: 0), .text("Болт"))
    }

    func testUTF16IsRecognisedByItsBOM() throws {
        var data = Data([0xFF, 0xFE])
        data.append("Имя,Цена\nБолт,12\n".data(using: .utf16LittleEndian)!)
        let url = try write(data, "utf16.csv")
        XCTAssertEqual(try DelimitedTableReader.detect(url: url).encoding, .utf16LE)
        XCTAssertEqual(try DelimitedTableReader.rows(url: url).rows[1].value(at: 0), .text("Болт"))
    }

    func testAnEmptyFileSaysSo() throws {
        let url = try write(Data(), "empty.csv")
        XCTAssertThrowsError(try DelimitedTableReader.detect(url: url)) { error in
            XCTAssertEqual(error as? TabularError, .empty)
        }
    }

    // MARK: - Delimiter

    /// Excel in a Russian locale writes semicolons. Read as commas the whole row
    /// becomes one column — an import that looks like it worked.
    func testSemicolonsAreDetected() throws {
        let url = try write("Название;Цена;Склад\nБолт;12;Москва\nГайка;8;Тверь\n", "semi.csv")
        let format = try DelimitedTableReader.detect(url: url)
        XCTAssertEqual(format.delimiter, ";")

        let rows = try DelimitedTableReader.rows(url: url, format: format).rows
        XCTAssertEqual(rows[1].values(width: 3), [.text("Болт"), .number(12), .text("Москва")])
    }

    func testCommasAreDetected() throws {
        let url = try write("a,b,c\n1,2,3\n4,5,6\n", "commas.csv")
        XCTAssertEqual(try DelimitedTableReader.detect(url: url).delimiter, ",")
    }

    func testTabsAreDetectedFromTheExtension() throws {
        let url = try write("a\tb\n1\t2\n", "file.tsv")
        XCTAssertEqual(try DelimitedTableReader.detect(url: url).delimiter, "\t")
    }

    /// A delimiter inside a quoted value is part of the value, and must not vote.
    func testADelimiterInsideQuotesDoesNotCount() {
        let line = "\"Иванов; Пётр\",Москва,12"
        XCTAssertEqual(DelimitedTableReader.countOutsideQuotes(";", in: line), 0)
        XCTAssertEqual(DelimitedTableReader.countOutsideQuotes(",", in: line), 2)
    }

    /// Consistency beats frequency: commas appearing inside text on every line
    /// must not outvote the semicolon that actually divides the columns.
    func testTheConsistentDelimiterWins() {
        let text = "Имя;Описание\nБолт;большой, оцинкованный\nГайка;мелкая, латунная\n"
        XCTAssertEqual(DelimitedTableReader.detectDelimiter(in: text).delimiter, ";")
    }

    func testAFileWithNoDelimiterIsOneColumnAndSaysSo() {
        let result = DelimitedTableReader.detectDelimiter(in: "первая строка\nвторая строка\n")
        XCTAssertTrue(result.reason.contains("одна колонка"), result.reason)
    }

    /// The detection is a proposal; requires it to be overridable.
    func testAManualFormatOverridesDetection() throws {
        let url = try write("a;b\n1;2\n", "override.csv")
        let forced = DelimitedFormat(encoding: .utf8, delimiter: ",")
        let rows = try DelimitedTableReader.rows(url: url, format: forced).rows
        XCTAssertEqual(rows[0].value(at: 0), .text("a;b"), "с запятой строка не делится — это и просили")
    }

    // MARK: - Values

    func testNumbersAndBooleansAreTyped() throws {
        let url = try write("n,x,b\n12,3.5,true\n", "types.csv")
        let rows = try DelimitedTableReader.rows(url: url).rows
        XCTAssertEqual(rows[1].value(at: 0), .number(12))
        XCTAssertEqual(rows[1].value(at: 1), .number(3.5))
        XCTAssertEqual(rows[1].value(at: 2), .boolean(true))
    }

    /// A leading zero is part of the value: postal codes and article numbers
    /// lose their meaning as integers, and the loss is silent.
    func testALeadingZeroKeepsTheValueAsText() throws {
        let url = try write("code\n007\n0123\n0.5\n", "zeros.csv")
        let rows = try DelimitedTableReader.rows(url: url).rows
        XCTAssertEqual(rows[1].value(at: 0), .text("007"))
        XCTAssertEqual(rows[2].value(at: 0), .text("0123"))
        XCTAssertEqual(rows[3].value(at: 0), .number(0.5), "«0.5» — это всё-таки число")
    }

    /// A CSV carries no formats, so a date can only be recognised where it is
    /// unambiguous. `03.04.2024` is April in one country and March in another.
    func testOnlyAnUnambiguousDateIsReadAsADate() throws {
        let url = try write("d\n2024-03-15\n03.04.2024\n", "dates.csv")
        let rows = try DelimitedTableReader.rows(url: url).rows
        guard case .date = rows[1].value(at: 0) else { return XCTFail("ISO-дата должна распознаться") }
        XCTAssertEqual(rows[2].value(at: 0), .text("03.04.2024"))
    }

    func testQuotedFieldsSurviveWithTheirCommasAndNewlines() throws {
        let url = try write("a,b\n\"один, два\",\"строка\nвторая\"\n", "quoted.csv")
        let rows = try DelimitedTableReader.rows(url: url).rows
        XCTAssertEqual(rows[1].value(at: 0), .text("один, два"))
        XCTAssertEqual(rows[1].value(at: 1), .text("строка\nвторая"))
    }

    /// CSV and XLSX converge on the same row type, so everything after this —
    /// modes, mapping, identity — is shared rather than written twice.
    func testACSVRowFeedsTheSameMapping() throws {
        let url = try write("Артикул,Название,Цена\nA-1,Болт,12\n", "map.csv")
        let rows = try DelimitedTableReader.rows(url: url).rows
        let shape = SheetModeDetector.suggest(rows: rows)
        XCTAssertEqual(shape.mode, .dataTable)
        XCTAssertEqual(shape.columns, ["Артикул", "Название", "Цена"])

        let mapping = TableMapping.suggested(sheetName: "map.csv", shape: shape)
        let document = RowMapper.document(
            for: rows[1], mapping: mapping,
            layout: SheetLayout(shape: shape),
            sourceID: UUID(), sourceFile: "map.csv"
        )
        XCTAssertEqual(document?.metadata["цена"], .int(12))
        XCTAssertEqual(document?.rowKey, "A-1")
    }
}

// MARK: - Which formats exist at all

final class TabularFormatTests: XCTestCase {
    func testEachExtensionIsClassified() {
        XCTAssertEqual(TabularFormat.of(URL(fileURLWithPath: "/a/b.xlsx")), .workbook)
        XCTAssertEqual(TabularFormat.of(URL(fileURLWithPath: "/a/b.XLSM")), .workbook)
        XCTAssertEqual(TabularFormat.of(URL(fileURLWithPath: "/a/b.csv")), .delimited)
        XCTAssertEqual(TabularFormat.of(URL(fileURLWithPath: "/a/b.tsv")), .delimited)
        XCTAssertEqual(TabularFormat.of(URL(fileURLWithPath: "/a/b.ods")), .openDocument)
        XCTAssertEqual(TabularFormat.of(URL(fileURLWithPath: "/a/b.numbers")), .numbers)
        XCTAssertNil(TabularFormat.of(URL(fileURLWithPath: "/a/b.pdf")))
    }

    /// то, что не читается, названо и объяснено — «пересохраните как
    /// .xlsx», — а не разобрано наполовину в мусор.
    ///
    /// `.xls` из этого списка ушёл: его открывает Numbers, и он идёт
    /// путём экспорта через приложение. `.xlsb` не открывает и она.
    func testTheOldBinaryFormatsAreRefusedWithAHint() {
        XCTAssertEqual(TabularFormat.of(URL(fileURLWithPath: "/a/b.xls")), .legacyExcel)
        XCTAssertEqual(TabularFormat.of(URL(fileURLWithPath: "/a/b.xlsb")), .legacyBinary)

        let reason = TabularError.legacyBinaryFormat("xlsb").errorDescription ?? ""
        XCTAssertTrue(reason.contains(".xlsx"), reason)
        XCTAssertTrue(reason.contains("пересохраните"), reason)
    }

    /// A workbook must not reach the text-extraction registry by any of its
    /// extensions — flattened into prose it would be embedded as
    /// meaningless text.
    func testNoWorkbookFormatIsHandledAsText() {
        for ext in ["xlsx", "xlsm", "ods", "numbers", "xls", "xlsb"] {
            let url = URL(fileURLWithPath: "/tmp/file.\(ext)")
            XCTAssertNil(ExtractorRegistry.standard().candidate(for: url), ext)
        }
    }

    /// **`.csv` and `.tsv` still go to the text extractor, and that is not yet a
    /// contradiction — it is the state this test records.**
    ///
    /// A delimited file conforms to `.text`, so `PlainTextExtractor` has claimed
    /// it since stage 2. says a *table* must not be flattened into prose;
    /// 1 says a sheet may legitimately be a «документ». Both are satisfied
    /// once a delimited file goes through the tabular pipeline and its **mode**
    /// decides — rows, or a rendered document.
    ///
    /// Routing is not wired yet, and taking `.csv` away from the text extractor
    /// before it is would simply stop CSVs being indexed. This test exists so
    /// the change is made deliberately when routing lands, rather than being
    /// discovered as a silent gap.
    func testDelimitedFilesAreStillTextUntilRoutingLands() {
        for ext in ["csv", "tsv"] {
            let url = URL(fileURLWithPath: "/tmp/file.\(ext)")
            XCTAssertEqual(ExtractorRegistry.standard().candidate(for: url)?.id, "plaintext", ext)
        }
    }
}
