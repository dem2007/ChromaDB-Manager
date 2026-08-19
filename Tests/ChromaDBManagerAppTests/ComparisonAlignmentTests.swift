import XCTest

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
}
