import XCTest
@testable import ChromaCore

/// Адреса ссылок в метаданных чанка.
final class DocumentLinkTests: XCTestCase {
    // MARK: - Строка адресов

    /// Массивов в метаданных ChromaDB не бывает, поэтому адреса идут одной
    /// строкой через пробел — в адресе пробела быть не может, и строка
    /// разбирается обратно без потерь.
    func testUrlsBecomeOneSpaceSeparatedLine() {
        XCTAssertEqual(
            SourceSyncService.urlLine(["https://a.ru/x", "mailto:b@c.ru"]),
            "https://a.ru/x mailto:b@c.ru"
        )
        XCTAssertNil(SourceSyncService.urlLine([]))
    }

    /// Страница-оглавление несёт сотни ссылок; записать их все — раздуть
    /// каждую запись в базе. Строка обрезается по границе адреса, а не
    /// посреди него: обрубок не адрес.
    func testTheLineStopsAtTheLimitWithoutCuttingAnAddress() {
        let urls = (0..<50).map { "https://example.org/document/\($0)" }
        let line = try? XCTUnwrap(SourceSyncService.urlLine(urls))
        guard let line else { return XCTFail("строка не собралась") }

        XCTAssertLessThanOrEqual(line.count, SourceSyncService.urlLineLimit)
        for piece in line.components(separatedBy: " ") {
            XCTAssertTrue(urls.contains(piece), "адрес обрублен: \(piece)")
        }
    }

    // MARK: - Кому достаётся адрес

    /// Ссылка принадлежит тому чанку, внутри текста которого она стоит.
    func testALinkBelongsToTheChunkItStandsIn() {
        let text = """
        Первый абзац рассказывает о предмете договора и ни на что не ссылается.

        Второй абзац ссылается на постановление правительства по этому вопросу.

        Третий абзац подводит итог сказанному выше без единой ссылки наружу.
        """
        let secondStart = text.distance(
            from: text.startIndex, to: text.range(of: "Второй абзац")!.lowerBound
        )
        let document = ExtractedDocument(
            plainText: text,
            links: [DocumentLink(url: "https://pravo.gov.ru/1646", start: secondStart + 10)],
            containerFormat: "txt", extractorID: "test", extractorVersion: 1
        )
        let chunks = text.components(separatedBy: "\n\n").enumerated().map {
            TextChunk(index: $0.offset, text: $0.element)
        }
        let placements = ChunkLocator.placements(of: chunks, in: document)

        XCTAssertEqual(placements[1]?.links, ["https://pravo.gov.ru/1646"])
        XCTAssertEqual(placements[0]?.links ?? [], [])
        XCTAssertEqual(placements[2]?.links ?? [], [])
    }

    /// Один адрес, стоящий в чанке несколько раз, записывается один раз —
    /// а вот разные адреса сохраняют порядок появления.
    func testRepeatsCollapseButOrderSurvives() {
        XCTAssertEqual(
            ChunkLocator.distinct(["https://a.ru", "https://b.ru", "https://a.ru", "https://c.ru"]),
            ["https://a.ru", "https://b.ru", "https://c.ru"]
        )
    }

    /// Размещение, в котором есть только ссылки, пустым не считается:
    /// метаданное `source_urls` оно даёт.
    func testAPlacementWithOnlyLinksIsNotEmpty() {
        XCTAssertTrue(ChunkPlacement(start: 0).isEmpty)
        XCTAssertFalse(ChunkPlacement(start: 0, links: ["https://a.ru"]).isEmpty)
    }

    // MARK: - Перевод смещений через сшивку (PDF)

    /// Место ссылки PDF известно в **исходном** тексте страницы, а в документ
    /// уходит сшитый. Перевод идёт по счёту букв и цифр — их сшивка сохраняет
    /// все и в том же порядке.
    func testAnOffsetSurvivesTheReflow() {
        let original = "Первая строка текста\nвторая строка текста\nтретья строка"
        let reflowed = "Первая строка текста втор" + "ая строка текста третья строка"
        let map = PDFExtractor.significantOffsets(original: original, reflowed: reflowed)

        // Начало — начало.
        XCTAssertEqual(map(0), 0)
        // «вторая» стоит в исходнике после перевода строки, в сшитом — после
        // пробела; буква «в» у обоих одна и та же по счёту.
        let inOriginal = original.distance(
            from: original.startIndex, to: original.range(of: "вторая")!.lowerBound
        )
        let inReflowed = reflowed.distance(
            from: reflowed.startIndex, to: reflowed.range(of: "втор")!.lowerBound
        )
        XCTAssertEqual(map(inOriginal), inReflowed)
    }

    /// Смещение за концом текста не должно уводить за границы строки.
    func testAnOffsetBeyondTheTextIsClamped() {
        let map = PDFExtractor.significantOffsets(original: "текст", reflowed: "текст")
        XCTAssertEqual(map(-5), 0)
        XCTAssertLessThanOrEqual(map(9999), 5)
    }

    /// Дефис переноса сшивка снимает — на счёте букв это не сказывается,
    /// и смещение остаётся верным.
    func testAHyphenRemovedByTheReflowDoesNotShiftTheOffset() {
        let original = "Порядок приме-\nнения правил утверждён"
        let reflowed = "Порядок применения правил утверждён"
        let map = PDFExtractor.significantOffsets(original: original, reflowed: reflowed)

        let inOriginal = original.distance(
            from: original.startIndex, to: original.range(of: "правил")!.lowerBound
        )
        let inReflowed = reflowed.distance(
            from: reflowed.startIndex, to: reflowed.range(of: "правил")!.lowerBound
        )
        XCTAssertEqual(map(inOriginal), inReflowed)
    }
}
