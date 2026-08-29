import XCTest
@testable import ChromaDBManagerApp

/// Подсказка при рукопожатии — по-английски.
///
/// Она попадает в контекст **каждой** сессии агента раньше любого описания
/// инструмента, и до была русской на 70 %. Сторож ядра до неё не
/// доставал: `instructions` живёт в целевом модуле приложения, а тот сторож
/// импортирует только `ChromaCore`. В я записал, что он поймал бы
///, — это было неверно, и вот проверка, которая ловит на самом деле.
final class MCPHandshakeLanguageTests: XCTestCase {

    func testHandshakeInstructionsCarryNoRussian() {
        let text = MCPService.instructions
        let cyrillic = text.filter {
            ("а"..."я").contains($0) || ("А"..."Я").contains($0) || $0 == "ё" || $0 == "Ё"
        }
        XCTAssertTrue(
            cyrillic.isEmpty,
            "русский текст в подсказке при рукопожатии: \(cyrillic)"
        )
    }

    /// Подсказка обязана остаться содержательной: пустую или куцую строку
    /// проверка на язык пропустит с радостью, а модель останется без правила
    /// выбора инструмента, ради которого текст и написан.
    func testHandshakeInstructionsStillTeachTheToolChoice() {
        let text = MCPService.instructions
        for required in ["list_collections", "describe_collection", "collect_mentions", "get_file"] {
            XCTAssertTrue(text.contains(required), "подсказка не называет \(required)")
        }
        XCTAssertGreaterThan(text.count, 600, "подсказка усохла до бесполезной")
    }
}
