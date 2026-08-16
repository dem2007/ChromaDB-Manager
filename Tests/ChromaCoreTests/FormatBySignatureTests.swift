import XCTest
@testable import ChromaCore

/// формат выбирается по содержимому файла, а не по его имени.
///
/// Замер на манифестах заказчика: **все 49** отказов «файл не похож
/// на ZIP-архив» — это файлы с именем `.xlsx`, внутри которых старая
/// двоичная книга Excel. Имя обещало одно, внутри лежало другое.
final class FormatBySignatureTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-sig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Старая книга Excel под именем новой узнаётся и идёт своим путём —
    /// через приложение, а не в отказ «это не ZIP».
    func testALegacyWorkbookNamedXlsxIsRecognised() throws {
        let url = root.appendingPathComponent("смета.xlsx")
        try DocFixture(paragraphs: ["Не книга, но контейнер OLE2 — важна подпись."])
            .build().write(to: url)
        XCTAssertEqual(TabularFormat.of(url), .legacyExcel, "по подписи это старый Excel, а не .xlsx")
    }

    /// И наоборот: настоящая книга под именем `.xls` читается своей читалкой,
    /// а не просит Numbers сделать то, что мы умеем сами.
    func testARealWorkbookNamedXlsIsReadNatively() throws {
        let url = root.appendingPathComponent("прайс.xls")
        try XLSXFixtureBuilder(sheets: [.init(
            name: "Лист", rows: [[.shared("Артикул"), .shared("Цена")], [.shared("АРТ-1"), .number(100)]]
        )]).build().write(to: url)
        XCTAssertEqual(TabularFormat.of(url), .workbook)

        // И действительно читается: имя файла разбору не мешает.
        let reader = try XLSXReader(url: url)
        let sheet = try XCTUnwrap(reader.sheets.first)
        XCTAssertEqual(try reader.rows(of: sheet).rows.count, 2)
    }

    /// Обычные случаи не трогаются: имя и содержимое сходятся.
    func testOrdinaryNamesAreLeftAlone() throws {
        let book = root.appendingPathComponent("книга.xlsx")
        try XLSXFixtureBuilder(sheets: [.init(name: "Лист", rows: [[.shared("а")]])]).build().write(to: book)
        XCTAssertEqual(TabularFormat.of(book), .workbook)

        let table = root.appendingPathComponent("данные.csv")
        try "а,б\n1,2".write(to: table, atomically: true, encoding: .utf8)
        XCTAssertEqual(TabularFormat.of(table), .delimited)

        XCTAssertNil(TabularFormat.of(root.appendingPathComponent("записка.txt")))
    }

    /// Документ Word 97 под именем `.docx` читается своей читалкой `.doc`,
    /// а не уходит в отказ: читалка для него есть.
    @MainActor
    func testABinaryWordDocumentNamedDocxIsStillRead() async throws {
        let url = root.appendingPathComponent("приложение.docx")
        try DocFixture(paragraphs: [
            "Порядок эксплуатации сетевого оборудования.",
            "Ответственность за исполнение возлагается на руководителей.",
        ], header: "ДСП").build().write(to: url)

        let extracted = try await OfficeExtractor().extract(from: url, options: ExtractionOptions())
        XCTAssertTrue(
            extracted.plainText.contains("Порядок эксплуатации сетевого оборудования."),
            extracted.plainText
        )
        XCTAssertTrue(extracted.plainText.contains("ДСП"), "колонтитул тоже на месте: \(extracted.plainText)")
    }
}
