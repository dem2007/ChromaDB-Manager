import XCTest
@testable import ChromaCore

/// знаки, которые мешают поиску.
final class TextNormalizationTests: XCTestCase {
    func testSpacesHyphensAndSymbolFontCharactersAreReadable() {
        let text = "от\u{00A0}5\u{202F}мая \u{F0B7} пункт \u{F02D} сервер 0 \u{F0A3} 1 \u{F03D} k 44\u{2011}ФЗ"
        XCTAssertEqual(TextNormalization.normalized(text), "от 5 мая • пункт − сервер 0 ≤ 1 = k 44-ФЗ")
    }

    func testDecomposedLettersAreComposed() {
        XCTAssertEqual(TextNormalization.normalized("и\u{0306}ога"), "йога")
    }

    /// Удалённые знаки сдвигают смещения документа: раздел, страница и
    /// ссылка остаются на своих местах.
    func testRemovalsShiftTheDocumentOffsets() {
        let text = "пере\u{00AD}нос\u{200B} и раздел"
        let start = text.distance(from: text.startIndex, to: text.range(of: "раздел")!.lowerBound)
        let document = ExtractedDocument(
            plainText: text,
            structure: [DocumentNode(level: 1, title: "раздел", start: start)],
            pageStarts: [0, start],
            links: [DocumentLink(url: "https://example.org", start: start)],
            containerFormat: "txt", extractorID: "test", extractorVersion: 1
        )
        let normalized = TextNormalization.normalized(document)
        XCTAssertEqual(normalized.plainText, "перенос и раздел")
        let expected = normalized.plainText.distance(
            from: normalized.plainText.startIndex, to: normalized.plainText.range(of: "раздел")!.lowerBound
        )
        XCTAssertEqual(normalized.structure.first?.start, expected)
        XCTAssertEqual(normalized.pageStarts, [0, expected])
        XCTAssertEqual(normalized.links.first?.start, expected)
    }

    func testPlainTextIsLeftAsItIs() {
        let text = "Обычный текст без особых знаков: 1.2, «кавычки» — тире."
        XCTAssertEqual(TextNormalization.normalized(text), text)
    }

    /// Версия в документе — версия экстрактора: иначе каждый HTML-файл
    /// считался «устаревшим» на каждой синхронизации.
    func testHTMLDocumentCarriesTheExtractorVersion() throws {
        let document = try HTMLExtractor.document(
            from: Data("<html><body><h1>Заголовок</h1><p>Текст&nbsp;страницы</p></body></html>".utf8),
            contentType: nil, baseURL: nil
        )
        XCTAssertEqual(document.extractorVersion, HTMLExtractor().version)
        XCTAssertTrue(document.plainText.contains("Текст страницы"), document.plainText)
    }
}
