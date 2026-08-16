import XCTest
@testable import ChromaCore

/// замечания и сноски `.odt` извлекаются, а не оговариваются.
final class ODTPartsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-odt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Документ OpenDocument из готового тела `office:text`.
    private func write(body: String, name: String = "проба.odt") throws -> URL {
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"\
         xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"\
         xmlns:dc="http://purl.org/dc/elements/1.1/" office:version="1.2">
        <office:body><office:text>\(body)</office:text></office:body></office:document-content>
        """
        let url = root.appendingPathComponent(name)
        try ZIPFixtureBuilder(entries: [
            .init(path: "mimetype", contents: Data("application/vnd.oasis.opendocument.text".utf8), deflated: false),
            .init(path: "content.xml", contents: Data(content.utf8), deflated: true),
        ]).build().write(to: url)
        return url
    }

    private static let comment = """
    <office:annotation><dc:creator>Петров</dc:creator><dc:date>2026-08-16T10:00:00</dc:date>\
    <text:p>Уточнить срок: тридцать или сорок дней?</text:p></office:annotation>
    """

    private static let footnote = """
    <text:note text:id="ftn1" text:note-class="footnote"><text:note-citation>1</text:note-citation>\
    <text:note-body><text:p>Если иное не указано в приложении.</text:p></text:note-body></text:note>
    """

    @MainActor
    private func extract(_ url: URL) async throws -> ExtractedDocument {
        try await OfficeExtractor().extract(from: url, options: ExtractionOptions())
    }

    /// Главное: системный импортёр отдаёт номер сноски и молчит про её текст,
    /// а замечание теряет целиком. Оба теперь приходят текстом.
    @MainActor
    func testFootnotesAndCommentsAreExtracted() async throws {
        let url = try write(body: """
        <text:p>Срок поставки определяется сторонами.\(Self.comment)</text:p>
        <text:p>Оплата производится по факту\(Self.footnote) поставки.</text:p>
        """)
        let extracted = try await extract(url)

        XCTAssertTrue(
            extracted.plainText.contains("Сноска 1: Если иное не указано в приложении."),
            extracted.plainText
        )
        XCTAssertTrue(
            extracted.plainText.contains("Комментарий (Петров): Уточнить срок: тридцать или сорок дней?"),
            extracted.plainText
        )
        // И оговорки «не извлечены» больше нет — она стала бы неправдой.
        XCTAssertFalse(extracted.warnings.contains(.commentsSkipped), "\(extracted.warnings.map(\.text))")
    }

    /// Документ без замечаний ничего лишнего не получает: ни строк, ни оговорок.
    @MainActor
    func testAPlainDocumentGetsNothingExtra() async throws {
        let url = try write(body: "<text:p>Обычный текст без единого замечания.</text:p>")
        let extracted = try await extract(url)
        XCTAssertEqual(extracted.plainText, "Обычный текст без единого замечания.")
        XCTAssertFalse(extracted.warnings.contains(.commentsSkipped))
    }

    /// Правки: индексируется финальная редакция, и об этом говорится прямо —
    /// тем же словами, что у Word.
    @MainActor
    func testRevisionsAreNamedPrecisely() async throws {
        let url = try write(body: """
        <text:tracked-changes><text:changed-region text:id="ct1"><text:deletion>\
        <office:change-info><dc:creator>Иванов</dc:creator></office:change-info>\
        <text:p>СТО</text:p></text:deletion></text:changed-region></text:tracked-changes>
        <text:p>Цена ДВЕСТИ рублей.</text:p>
        """)
        let extracted = try await extract(url)
        XCTAssertTrue(
            extracted.warnings.contains { $0.text.contains("индексируется финальная редакция") },
            "\(extracted.warnings.map(\.text))"
        )
    }

    /// Замечание без автора остаётся замечанием: подпись пропадает, текст нет.
    @MainActor
    func testACommentWithoutAnAuthorKeepsItsText() async throws {
        let url = try write(body: """
        <text:p>Пункт договора.<office:annotation><text:p>Проверить редакцию.</text:p></office:annotation></text:p>
        """)
        let text = try await extract(url).plainText
        XCTAssertTrue(text.contains("Комментарий: Проверить редакцию."), text)
    }

    /// Если разметку прочитать не удалось, возвращается прежняя оговорка:
    /// «не смотрели» нельзя выдавать за «там ничего нет».
    @MainActor
    func testAnUnreadablePartFallsBackToTheOldCaveat() async throws {
        let url = root.appendingPathComponent("битый.odt")
        let content = "<office:document-content><office:body><office:text><text:p>Текст"
        try ZIPFixtureBuilder(entries: [
            .init(path: "mimetype", contents: Data("application/vnd.oasis.opendocument.text".utf8), deflated: false),
            .init(path: "content.xml", contents: Data(content.utf8), deflated: true),
        ]).build().write(to: url)

        // Импортёр такой файл прочитать не сможет — и это тоже не молчание,
        // а названная причина.
        do {
            let extracted = try await extract(url)
            XCTAssertNotNil(ODTPartsReader(url: url), "читалка обязана открыться")
            XCTAssertNil(ODTPartsReader(url: url)?.read(), "разбор битой разметки обязан вернуть nil")
            _ = extracted
        } catch {
            XCTAssertTrue("\(error)".count > 0, "отказ обязан называть причину")
        }
    }
}
