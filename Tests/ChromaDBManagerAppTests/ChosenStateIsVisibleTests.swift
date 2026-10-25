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

    /// Выбранная оценка залита цветом, остальные — обычные кнопки.
    ///
    /// Живой случай: оценку ставили, а кнопка не менялась ничем, и человек
    /// жал её второй раз, снимая только что поставленную. Системный
    /// переключатель-кнопка с `.tint` красил надписи всех трёх, а заливку
    /// выбранной делал едва заметной — та же беда. Поэтому выбранная —
    /// `.borderedProminent` с цветом своей оценки, остальные — `.bordered`.
    func testTheChosenGradeIsFilledWithItsColour() throws {
        let view = try source("Sources/ChromaDBManagerApp/Views/EvaluationView.swift")
        XCTAssertTrue(view.contains("gradeButton(candidate, chosen: grade == candidate)"), "кнопка знает, выбрана ли её оценка")
        XCTAssertTrue(view.contains(".buttonStyle(.borderedProminent)"), "выбранная оценка — залитая кнопка")
        XCTAssertTrue(view.contains(".tint(Self.tint(candidate))"), "залита цветом своей оценки")
        XCTAssertFalse(view.contains("chromaChoice"), "капсульный стиль на экране оценки больше не нужен")
    }

    /// Каждый переключатель показывает, включён ли он.
    ///
    /// Сплошной обход экранов, а не список известных мест: кнопка, которая
    /// переключает признак и выглядит одинаково в обоих состояниях, — это
    /// ровно та ошибка, за которой сюда и пришли. Показывать можно чем
    /// угодно: другим стилем, другой надписью, — лишь бы разница была.
    func testEveryToggleButtonShowsWhetherItIsOn() throws {
        /// Исключений больше нет: капсульный стиль и «?» карточек ушли вместе
        /// с `Components.swift`, а переключатели стали `Toggle(.button)`.
        let allowed: [String] = []
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
}
