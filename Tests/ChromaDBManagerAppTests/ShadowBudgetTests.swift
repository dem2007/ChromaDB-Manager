import XCTest

/// Тени — самое дорогое, что рисует это приложение.
///
/// Каждая тень в SwiftUI — отдельный проход размытия, и цена его линейна по
/// радиусу. Замерено прямой отрисовкой кадров: карточка с радиусом 30 стоит
/// 63 мс на кадр, с 12 — 26, без тени — 2; экран разметки с девяноста
/// светящимися капсулами — 497 мс на кадр, без свечения — 5.
///
/// Числа легко вернуть обратно «чтобы было красивее», и заметно это будет не
/// на снимке, а только рукой на прокрутке. Поэтому — сторож.
final class ShadowBudgetTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ChromaDBManagerApp/Views/\(name)")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("исходники не найдены рядом с тестами")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Радиус тени карточки — в пределах бюджета.
    func testTheCardShadowStaysWithinItsBudget() throws {
        let theme = try source("Theme.swift")
        let radius = try XCTUnwrap(
            Self.number(after: "static let cardRadius: CGFloat = ", in: theme),
            "не нашёлся радиус тени карточки"
        )
        XCTAssertLessThanOrEqual(radius, 12, "тень карточки шире бюджета: каждая единица радиуса — время на кадр")
    }

    /// Обычная и второстепенная капсулы не светятся вовсе.
    ///
    /// Их на экране бывают десятки: строка разметки — это три капсулы, а строк
    /// тридцать. Свечения под белой капсулой с рамкой всё равно не видно.
    func testOrdinaryCapsulesDoNotGlow() throws {
        let components = try source("Components.swift")
        XCTAssertTrue(
            components.contains("case .normal, .secondary: return nil"),
            "обычные капсулы снова светятся — это самое дорогое, что есть на экране разметки"
        )
        // И проход размытия не запускается впустую, когда светить нечем.
        // «Нечем» — это `nil`, а не прозрачный цвет: равенство цветов SwiftUI
        // не обещает, и прозрачное свечение, записанное иначе, вернуло бы
        // размытие молча.
        XCTAssertTrue(
            components.contains("radius: glow == nil ? 0 : 8"),
            "нулевой радиус, когда свечения нет: проход размытия стоит времени и с прозрачным цветом"
        )
        XCTAssertTrue(
            components.contains("private var glow: Color?"),
            "свечение обязано быть необязательным цветом, а не сравниваться с .clear"
        )
    }

    private static func number(after marker: String, in text: String) -> CGFloat? {
        guard let range = text.range(of: marker) else { return nil }
        let rest = text[range.upperBound...].prefix(20)
        let digits = rest.prefix { $0.isNumber || $0 == "." }
        return CGFloat(Double(digits) ?? .nan)
    }
}
