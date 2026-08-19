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
    func testTheLimitsAreLaidOutAsAGrid() throws {
        let source = try clientsView()
        XCTAssertTrue(
            source.contains("columns: [GridItem(.adaptive(minimum: 150), spacing: 16, alignment: .leading)]"),
            "лимиты клиента должны раскладываться сеткой — их шесть, и в ряд они не помещаются"
        )
    }

    /// Объявление целиком — от строки `private struct X` до закрывающей
    /// скобки в нулевом отступе.
    ///
    /// Прежде тут стояло `prefix(1200)`, и проверка ломалась от дописанного
    /// комментария: код был на месте, а нужная строка уезжала за край окна.
    /// Тест, падающий от комментария, не сторожит ничего — он только приучает
    /// не верить падениям.
    private func declaration(_ name: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: "private struct \(name): View"))
        let tail = source[start.lowerBound...]
        guard let end = tail.range(of: "\n}\n") else { return String(tail) }
        return String(tail[..<end.upperBound])
    }

    /// Подпись поля не ужимается ни при какой ширине окна.
    func testLabelsKeepTheirWidth() throws {
        let tail = try declaration("LimitField", in: try clientsView())
        XCTAssertTrue(tail.contains(".fixedSize(horizontal: true, vertical: false)"),
                      "подпись поля должна держать свою ширину")
        XCTAssertTrue(tail.contains("VStack(alignment: .leading"),
                      "подпись стоит над полем: слева она делит ширину с полем ввода")
    }

    /// Подсказка в поле — само число, а не фраза.
    ///
    /// Поле шириной 120, и «по умолчанию 24000» обрезалось с конца — то есть
    /// ровно на числе, ради которого подсказку и читают.
    func testTheHintIsTheNumberItself() throws {
        let source = try clientsView()
        XCTAssertFalse(source.contains("placeholder: String(localized: \"по умолчанию"),
                       "подсказку строит само поле из значения по умолчанию")
        let field = try declaration("LimitField", in: source)
        XCTAssertTrue(field.contains("let defaultValue: Int?"),
                      "значение по умолчанию приходит числом")
        XCTAssertTrue(field.contains("defaultValue.formatted"),
                      "в поле стоит само число")
        XCTAssertTrue(field.contains("String(localized: \"без лимита\")"),
                      "а без предела — так и сказано")
    }

    /// У каждого предела есть расшифровка: числа тут похожи друг
    /// на друга, а действуют по-разному — один отклоняет запись целиком,
    /// другой молча обрезает текст в ответе агенту.
    func testEveryLimitExplainsItself() throws {
        let source = try clientsView()
        // По вызовам, а не по всем упоминаниям: объявление самой функции
        // стоит без отступа сетки и в счёт не идёт.
        let calls = source.components(separatedBy: "            limitField(\n").dropFirst()
        XCTAssertEqual(calls.count, 6, "полей предела шесть")
        for call in calls {
            XCTAssertTrue(call.prefix(1200).contains("help: String(localized:"),
                          "у каждого поля предела своя расшифровка")
        }
        XCTAssertTrue(try declaration("LimitField", in: source).contains("HelpButton(text: help"),
                      "расшифровка показывается тем же знаком «?», что и в карточках")
    }
}
