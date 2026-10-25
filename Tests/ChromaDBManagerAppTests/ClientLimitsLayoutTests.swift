import XCTest
@testable import ChromaDBManagerApp

/// Сторож по исходникам карточки клиента.
///
/// Проверять глазами тут нечего до тех пор, пока окно не сузили: шесть пар
/// «подпись — поле» в одном ряду SwiftUI ужимает, отбирая ширину у подписей,
/// и «Документов в сутки» превращается в столбик по букве в строке. Тест
/// стережёт то, что этому мешает.
final class ClientLimitsLayoutTests: XCTestCase {
    private func clientsView() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ChromaDBManagerApp/Views/ClientsView.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("исходники экрана не найдены рядом с тестами")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Поля лимитов переносятся ячейками, а не сжимаются в одну строку.
    /// Лимиты — в «Для опытных», с одним «?» на весь блок ( «Клиенты →
    /// Ключи»). Прежняя сетка из шести полей со своим «?» у каждого
    /// ушла вместе с карточками: в форме каждое поле — своя строка, и
    /// подписи больше не делят ширину с полями ввода.
    func testTheLimitsLiveInAnAdvancedSectionWithOneHelp() throws {
        let source = try clientsView()
        XCTAssertTrue(source.contains("screen: \"clients.limits\""), "лимиты свёрнуты в «Для опытных»")
        let block = try XCTUnwrap(source.range(of: "screen: \"clients.limits\""))
        let tail = source[block.upperBound...].prefix(400)
        XCTAssertTrue(tail.contains("help: String(localized:"), "у блока лимитов один «?» в заголовке")
        XCTAssertFalse(source.contains("HelpButton("), "«?» у каждого поля — шум")
    }

    private func declaration(_ name: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: "private struct \(name): View"))
        let tail = source[start.lowerBound...]
        guard let end = tail.range(of: "\n}\n") else { return String(tail) }
        return String(tail[..<end.upperBound])
    }

    /// Подсказка в пустом поле — само число, а без предела так и сказано
    ///: длинная фраза в поле обрезалась ровно на числе.
    func testTheHintIsTheNumberItself() throws {
        let source = try clientsView()
        XCTAssertFalse(source.contains("placeholder: String(localized: \"по умолчанию"),
                       "подсказку строит само поле из значения по умолчанию")
        let field = try declaration("LimitField", in: source)
        XCTAssertTrue(field.contains("let defaultValue: Int?"), "значение по умолчанию приходит числом")
        XCTAssertTrue(field.contains("defaultValue.formatted"), "в поле стоит само число")
        XCTAssertTrue(field.contains("String(localized: \"без лимита\")"), "а без предела — так и сказано")
    }

    /// Числа похожи, а действуют по-разному — у каждого поля своя подсказка.
    func testEveryLimitExplainsItself() throws {
        let source = try clientsView()
        let calls = source.components(separatedBy: "            LimitField(\n").dropFirst()
        XCTAssertEqual(calls.count, 6, "полей предела шесть")
        for call in calls {
            XCTAssertTrue(call.prefix(1200).contains("help: String(localized:"),
                          "у каждого поля предела своя расшифровка")
        }
        XCTAssertTrue(try declaration("LimitField", in: source).contains(".help(help)"),
                      "расшифровка показывается подсказкой поля")
    }
}
