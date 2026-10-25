import XCTest
@testable import ChromaCore

/// текст документа на экране: начало, без управляющих символов,
/// двоичное — словами.
final class DisplayTextTests: XCTestCase {
    func testALongTextIsShownByItsStart() {
        let long = String(repeating: "слово ", count: 5_000)
        let preview = DisplayText.preview(long, limit: 1_000)
        XCTAssertEqual(preview.text.unicodeScalars.count, 1_000)
        XCTAssertTrue(preview.isTruncated)
        XCTAssertEqual(preview.totalCharacters, long.unicodeScalars.count)
        XCTAssertFalse(preview.looksBinary)
    }

    /// Архив, прочитанный как текст: «PK», управляющие символы через каждые
    /// несколько знаков — так выглядел документ, на котором зависало
    /// приложение.
    func testAZipReadAsTextLooksBinary() {
        var junk = "PK\u{3}\u{4}\u{14}\u{0}\u{6}\u{0}[Content_Types].xml"
        for index in 0..<2_000 { junk += "ö\u{1}\u{0}é\(index)\u{7}" }
        let preview = DisplayText.preview(junk)
        XCTAssertTrue(preview.looksBinary)
        XCTAssertGreaterThan(preview.controlCharacters, 100)
        XCTAssertFalse(preview.text.unicodeScalars.contains { $0.value < 0x20 && $0 != "\n" && $0 != "\t" })
    }

    func testOrdinaryTextIsLeftAsItIs() {
        let text = "Раздел 1.\n\tОбщие положения."
        let preview = DisplayText.preview(text)
        XCTAssertEqual(preview.text, text)
        XCTAssertFalse(preview.isTruncated)
        XCTAssertFalse(preview.looksBinary)
    }
}
