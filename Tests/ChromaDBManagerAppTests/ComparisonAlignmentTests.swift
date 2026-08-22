import XCTest
import AppKit

/// Сравнение вариантов стоит строками, а не стопкой независимых колонок.
///
/// Сторож по исходникам, как `ChosenStateIsVisibleTests`: разъехавшиеся
/// колонки компилируются, проходят все прочие тесты и видны только глазами —
/// а сравнивать по ним нельзя, потому что четвёртая строка одного варианта
/// стоит напротив шестой у соседнего.
final class ComparisonAlignmentTests: XCTestCase {
    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ChromaDBManagerApp/Views/EvaluationView.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("исходники экрана не найдены рядом с тестами")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Строки одного номера — в одном ряду сетки.
    func testTheVariantsAreComparedInAGrid() throws {
        let view = try source()
        XCTAssertTrue(view.contains("Grid(alignment: .topLeading"), "выдачи вариантов обязаны стоять сеткой")
        XCTAssertTrue(view.contains("GridRow {"), "у каждого номера результата — свой ряд")
    }

    /// Горизонтальная прокрутка одна на карточку, а не своя у каждого запроса:
    /// вложенных прокруток было столько же, сколько запросов, и колесо
    /// трекпада металось между ними.
    func testThereIsOneHorizontalScrollForTheWholeCard() throws {
        let view = try source()
        let occurrences = view.components(separatedBy: "ScrollView(.horizontal").count - 1
        XCTAssertLessThanOrEqual(occurrences, 2, "лишние вложенные прокрутки: \(occurrences)")
    }

    /// Высота строки не пляшет: место под три строки текста отведено всегда.
    func testTheRowKeepsItsHeight() throws {
        let view = try source()
        XCTAssertTrue(
            view.contains("lineLimit(3, reservesSpace: true)"),
            "плавающая высота строки — это и есть «скачет при прокрутке»"
        )
    }

    /// Строка разметки помещается в колонку целиком — со значком «показать
    /// в источнике».
    ///
    /// Ширина колонки — число в исходнике, а ширина трёх капсул — метрики
    /// шрифта: они не совпадают сами по себе, и разошлись молча. Значок стоял
    /// последним, поэтому за край уезжал именно он: половина видна, нажать
    /// нельзя. Глазами это ловится только если прокрутить сравнение до правого
    /// края колонки, поэтому — тест.
    func testTheMarkingRowFitsTheColumnTogetherWithTheSourceButton() throws {
        let view = try source()
        let column = try XCTUnwrap(
            Self.number(after: "private static let columnWidth: CGFloat = ", in: view),
            "не нашлась ширина колонки"
        )

        // Метрики берутся из стиля кнопки, а не выдумываются здесь: если стиль
        // изменится, тест обязан считать по-новому, а не проходить по старому.
        let components = try self.components()
        let padding = try XCTUnwrap(
            Self.number(after: "kind == .normal ? ", in: components),
            "не нашёлся горизонтальный отступ капсулы"
        )
        let fontSize = try XCTUnwrap(
            Self.number(after: "let size: CGFloat = kind == .secondary ? 12.5 : ", in: components),
            "не нашёлся кегль надписи на капсуле"
        )

        // Выбранная кнопка набрана `.medium`, и место под неё держится всегда
        // (`reservesEmphasisWidth`) — считать надо по ней, а не по `.regular`.
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let titles = ["релевантен", "частично", "нерелевантен"]
        let capsules = titles.reduce(0.0) { total, title in
            total + (title as NSString).size(withAttributes: [.font: font]).width + 2 * padding
        }

        // Промежутки: `HStack(spacing: 4)` ставит их между всеми соседями,
        // включая распорку перед значком, — их три, а не два.
        let spacing = 4.0
        let icon = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: fontSize, weight: .regular))?
            .size.width ?? 18

        let needed = capsules + 2 * spacing + spacing + spacing + icon
        XCTAssertGreaterThanOrEqual(
            column, needed,
            "строка разметки шире колонки — значок «показать в источнике» уедет за край: "
                + "нужно \(String(format: "%.1f", needed)) pt, в колонке \(String(format: "%.1f", column)) pt"
        )
    }

    private func components() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ChromaDBManagerApp/Views/Components.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("исходники экрана не найдены рядом с тестами")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Число сразу за образцом — так тест читает величину из исходника, а не
    /// повторяет её у себя, где она устареет молча.
    private static func number(after marker: String, in text: String) -> CGFloat? {
        guard let range = text.range(of: marker) else { return nil }
        let tail = text[range.upperBound...].prefix(12)
        let digits = tail.prefix { $0.isNumber || $0 == "." }
        return Double(digits).map { CGFloat($0) }
    }
}
