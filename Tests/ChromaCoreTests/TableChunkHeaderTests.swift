import XCTest
@testable import ChromaCore

/// шапка таблицы попадает в каждый её кусок, из любого источника.
final class TableChunkHeaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-tch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func chunks(of text: String) async throws -> [TextChunk] {
        try await ChunkingPipeline(configuration: ChunkingConfiguration()).chunks(from: text)
    }

    /// Главное: таблица Word на шестьдесят строк раньше давала три куска,
    /// и строка заголовков была только в первом. Два остальных — сетка
    /// значений, по которой нельзя сказать, что 24 это количество, а не цена.
    func testEveryChunkOfAWordTableCarriesTheHeader() async throws {
        var body = "<w:p><w:r><w:t>Спецификация оборудования</w:t></w:r></w:p><w:tbl>"
        let rows = [["Артикул", "Наименование позиции", "Кол-во", "Цена за единицу"]]
            + (1...60).map { number in
                ["АРТ-\(1000 + number)", "Кабель UTP категории 5e, бухта \(number * 100) метров",
                 "\(number)", "\(number * 1250) ₽"]
            }
        for row in rows {
            body += "<w:tr>" + row.map { DocxFixture.cell(DocxFixture.paragraph($0), nil) }.joined() + "</w:tr>"
        }
        body += "</w:tbl>"
        let url = root.appendingPathComponent("спецификация.docx")
        try DocxFixture(body: body).build().write(to: url)

        let extracted = try await OfficeExtractor().extract(from: url, options: ExtractionOptions())
        let pieces = try await chunks(of: extracted.plainText)

        XCTAssertGreaterThan(pieces.count, 1, "таблица должна разрезаться, иначе проверять нечего")
        for piece in pieces where piece.text.contains("| АРТ-") {
            XCTAssertTrue(
                piece.text.contains("| Артикул | Наименование позиции | Кол-во | Цена за единицу |"),
                "кусок без названий колонок:\n\(piece.text.prefix(200))"
            )
        }
    }

    /// Кусок, в котором шапка и так есть, второй раз её не получает.
    func testTheHeaderIsNotDoubled() async throws {
        let table = TableText.render(
            [["Артикул", "Цена"]] + (1...40).map { ["АРТ-\(1000 + $0)", "\($0 * 100)"] }
        )
        let pieces = try await chunks(of: table)
        for piece in pieces {
            let count = piece.text.components(separatedBy: "| Артикул | Цена |").count - 1
            XCTAssertLessThanOrEqual(count, 1, piece.text)
        }
    }

    /// На куске стоит пометка: человек должен знать, откуда в тексте строка,
    /// которой в этом месте файла нет.
    func testTheRepeatIsExplained() {
        let table = TableText.render([["Артикул", "Цена"], ["АРТ-1", "100"], ["АРТ-2", "200"]])
        let rows = table.components(separatedBy: "\n")
        let tail = TextChunk(index: 1, text: rows[3])
        let result = TableChunkHeaders.applied(to: [TextChunk(index: 0, text: rows[0]), tail], in: table)
        XCTAssertTrue(result[1].text.hasPrefix("| Артикул | Цена |\n| --- | --- |"), result[1].text)
        XCTAssertEqual(result[1].note, TableChunkHeaders.note)
    }

    /// Текст без таблиц не трогается вовсе.
    func testProseIsLeftAlone() async throws {
        let text = (1...20).map { "Абзац номер \($0) обычного текста без единой таблицы внутри." }
            .joined(separator: "\n\n")
        let pieces = try await chunks(of: text)
        XCTAssertEqual(pieces, TableChunkHeaders.applied(to: pieces, in: text))
    }
}

/// Две таблицы, записанные вплотную, не путают шапки (разбор кода.
extension TableChunkHeaderTests {
    func testTwoTablesInARowKeepTheirOwnHeaders() {
        let text = """
        | Артикул | Цена |
        | --- | --- |
        | АРТ-1 | 100 |
        | Склад | Остаток |
        | --- | --- |
        | Москва | 12 |
        """
        let headers = TableChunkHeaders.headers(in: text)
        XCTAssertEqual(headers["| АРТ-1 | 100 |"], "| Артикул | Цена |\n| --- | --- |")
        XCTAssertEqual(headers["| Москва | 12 |"], "| Склад | Остаток |\n| --- | --- |")
        XCTAssertNil(headers["| Склад | Остаток |"], "это шапка второй таблицы, а не строка первой")
    }
}
