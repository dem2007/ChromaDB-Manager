import XCTest

/// Выбранная кнопка обязана выглядеть выбранной.
///
/// Сторож по исходникам: `.tint` на капсульном стиле компилируется, ничего
/// не ломает и ничего не делает — стиль рисует заливку и цвет надписи сам.
/// Живой случай: в стенде оценки «релевантен / частично / нерелевантен»
/// ставили отметку, а кнопка не менялась ничем — и человек жал её второй
/// раз, снимая только что поставленную оценку.
final class ChosenStateIsVisibleTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("исходники не найдены рядом с тестами")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Кнопки оценки красятся стилем, а не `.tint`.
    func testTheGradeButtonsPaintThemselvesThroughTheStyle() throws {
        let view = try source("Sources/ChromaDBManagerApp/Views/EvaluationView.swift")
        XCTAssertTrue(
            view.contains(".buttonStyle(.chromaChoice(grade == candidate ? Self.tint(candidate) : nil))"),
            "оценка обязана попадать в стиль кнопки"
        )
        XCTAssertFalse(
            view.contains(".tint(grade == candidate"),
            "`.tint` до капсульного стиля не доходит — красить им нельзя"
        )
        XCTAssertFalse(
            view.contains(".tint(chosen ?"),
            "выбранный k красится тем же способом, что и оценка"
        )
    }

    /// Каждый переключатель показывает, включён ли он.
    ///
    /// Сплошной обход экранов, а не список известных мест: кнопка, которая
    /// переключает признак и выглядит одинаково в обоих состояниях, — это
    /// ровно та ошибка, за которой сюда и пришли. Показывать можно чем
    /// угодно: другим стилем, другой надписью, — лишь бы разница была.
    func testEveryToggleButtonShowsWhetherItIsOn() throws {
        /// «?» у заголовка карточки: состояние видно по самому всплывающему
        /// окну, которое кнопка и открывает.
        let allowed = ["Components.swift"]
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ChromaDBManagerApp/Views")
        guard let files = try? FileManager.default.contentsOfDirectory(at: views, includingPropertiesForKeys: nil) else {
            throw XCTSkip("исходники экранов не найдены рядом с тестами")
        }

        var mute: [String] = []
        for file in files where file.pathExtension == "swift" && !allowed.contains(file.lastPathComponent) {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() where line.contains(".toggle()") {
                // Ближайшая кнопка выше и ближайший стиль ниже — та же
                // окрестность, в которой это читает человек.
                let above = (max(0, index - 6)...index).reversed()
                guard let button = above.first(where: { lines[$0].contains("Button") }) else { continue }
                let below = index..<min(index + 12, lines.count)
                let style = below.first { lines[$0].contains(".buttonStyle(") }.map { lines[$0] } ?? ""
                let showsState = style.contains("?") || lines[button].contains("?")
                if !showsState {
                    mute.append("\(file.lastPathComponent):\(index + 1) — \(lines[button].trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(mute, [], "переключатель обязан выглядеть по-разному включённым и выключенным")
    }

    /// Сам стиль умеет выбранное состояние: заливка, белая надпись, обводка.
    func testTheStyleKnowsHowToLookChosen() throws {
        let components = try source("Sources/ChromaDBManagerApp/Views/Components.swift")
        XCTAssertTrue(components.contains("var chosen: Color?"), "у стиля обязано быть выбранное состояние")
        XCTAssertTrue(components.contains("if chosen != nil { return .white }"), "надпись выбранной кнопки — белая")
        XCTAssertTrue(components.contains("Capsule().fill(chosen)"), "выбранная кнопка заливается своим цветом")
        XCTAssertTrue(
            components.contains("static func chromaChoice(_ chosen: Color?) -> CapsuleButtonStyle"),
            "стиль выбора вызывается одним именем во всём приложении"
        )
    }
}
