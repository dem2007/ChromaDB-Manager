import XCTest
@testable import ChromaCore

/// что предлагается новому источнику по умолчанию.
///
/// Список пишется руками (экстракторы выбирают по `UTType` и перечня не имеют),
/// поэтому его сверяет тест: разойтись с тем, что приложение действительно
/// читает, он может только молча.
final class SupportedExtensionsTests: XCTestCase {
    func testEveryTableFormatTheAppReadsIsOffered() {
        for format in TabularFormat.allExtensions where !TextExtractor.unsupportedExtensions.contains(format) {
            XCTAssertTrue(
                TextExtractor.supportedExtensions.contains(format),
                "\(format) читается табличным конвейером, но новому источнику не предлагается"
            )
        }
    }

    /// Форматы, которые приложение читать не умеет, предлагать нельзя: файл
    /// попадёт в «пропущено» на каждом прогоне и будет засорять диагностику.
    func testNothingUnsupportedIsOffered() {
        for extension_ in TextExtractor.unsupportedExtensions {
            XCTAssertFalse(
                TextExtractor.supportedExtensions.contains(extension_),
                "\(extension_) предлагается, хотя не читается"
            )
        }
    }

    /// Стадия 5 научила приложение читать таблицы — и они ушли из списка
    /// неподдерживаемых. Тест держит эту связь: вернуть их туда, не заметив,
    /// значит снова начать отказываться от файлов, которые работают.
    func testSpreadsheetsAreNoLongerCalledUnsupported() {
        for format in ["xlsx", "xlsm", "ods", "numbers", "csv", "tsv", "xls"] {
            XCTAssertFalse(TextExtractor.unsupportedExtensions.contains(format), format)
        }
        XCTAssertFalse(
            TextExtractor.unsupportedExtensions.contains("xls"),
            ".xls читается через Numbers с"
        )
        XCTAssertTrue(
            TextExtractor.unsupportedExtensions.contains("xlsb"),
            "двоичный .xlsb не открывает и Numbers"
        )
    }

    func testTheListHasNoDuplicatesAndNoDots() {
        let all = TextExtractor.supportedExtensions
        XCTAssertEqual(Set(all).count, all.count, "повторы в списке")
        XCTAssertTrue(all.allSatisfy { !$0.contains(".") && $0 == $0.lowercased() })
    }

    func testTheFormatsTheCardNamesAreInTheList() {
        // Названные в подписи под полем — те же, что предлагаются.
        for named in ["md", "txt", "pdf", "docx", "doc", "rtf", "odt", "epub", "pages", "key"] {
            XCTAssertTrue(TextExtractor.supportedExtensions.contains(named), named)
        }
    }
}
