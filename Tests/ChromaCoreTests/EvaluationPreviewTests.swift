import XCTest
@testable import ChromaCore

/// Карточка результата показывает то место, ради которого её читают.
final class EvaluationPreviewTests: XCTestCase {

    /// Главный случай: родитель и его первый ребёнок начинаются одинаково,
    /// и по началу их не различить.
    func testSnippetShowsMatchInsteadOfBeginning() {
        let opening = String(repeating: "Общие положения настоящего регламента. ", count: 6)
        let text = opening + "Порядок обновления справочников определяется приложением 4."
        let snippet = EvaluationPreview.snippet(
            of: text, matching: "Порядок обновления справочников"
        )
        XCTAssertTrue(snippet.contains("обновления"), snippet)
        XCTAssertTrue(snippet.hasPrefix("…"), "обрезанное начало обязано быть видно: \(snippet)")
    }

    /// И различить их по карточке становится возможно.
    func testParentAndChildDifferInPreview() {
        let child = "Общие положения. " + String(repeating: "Текст раздела. ", count: 8)
        let parent = child + "Порядок обновления справочников определяется приложением 4."
        let query = "порядок обновления справочников"
        XCTAssertNotEqual(
            EvaluationPreview.snippet(of: child, matching: query),
            EvaluationPreview.snippet(of: parent, matching: query)
        )
    }

    /// Слово в другом падеже — то же слово.
    func testMatchesDifferentGrammaticalForm() {
        let text = String(repeating: "Прочий текст. ", count: 12) + "Условия обновления указаны ниже."
        let snippet = EvaluationPreview.snippet(of: text, matching: "лицензирование")
        XCTAssertTrue(snippet.contains("обновления"), snippet)
    }

    /// Короткие слова не тянут окно на себя: «для» есть в любом куске.
    func testShortWordsAreIgnored() {
        XCTAssertEqual(EvaluationPreview.stems(of: "для как при"), [])
        XCTAssertEqual(EvaluationPreview.stems(of: "Порядок обновления"), ["порядо", "лиценз"])
    }

    /// Ни одно слово запроса не встретилось — показывается начало, как и
    /// раньше, а не пустота.
    func testFallsBackToBeginning() {
        let text = String(repeating: "Совершенно посторонний текст. ", count: 10)
        let snippet = EvaluationPreview.snippet(of: text, matching: "лицензирование программного")
        XCTAssertTrue(snippet.hasPrefix("Совершенно посторонний"), snippet)
        XCTAssertTrue(snippet.hasSuffix("…"), snippet)
    }

    /// Короткий кусок показывается целиком и без многоточий.
    func testShortTextIsShownWhole() {
        XCTAssertEqual(
            EvaluationPreview.snippet(of: "Короткий  кусок\nтекста", matching: "кусок"),
            "Короткий кусок текста"
        )
    }

    /// Окно не длиннее заказанного — карточка отведена под три строки.
    func testSnippetKeepsToTheLimit() {
        let text = String(repeating: "слово ", count: 200) + "лицензирование " + String(repeating: "слово ", count: 200)
        let snippet = EvaluationPreview.snippet(of: text, matching: "лицензирование")
        XCTAssertLessThanOrEqual(snippet.count, EvaluationPreview.limit + 2, snippet)
    }

    /// Окно встаёт туда, где рядом стоят **разные** слова запроса.
    func testWindowPrefersMoreDistinctWords() {
        let text = "Обновление упоминается тут. "
            + String(repeating: "прокладка ", count: 20)
            + "Порядок обновления справочников описан здесь."
        let snippet = EvaluationPreview.snippet(
            of: text, matching: "порядок обновления справочников"
        )
        XCTAssertTrue(snippet.contains("справочников"), snippet)
    }

    // MARK: - Длина и уровень

    func testShapeNamesParent() {
        let shape = EvaluationPreview.shape(
            text: String(repeating: "а", count: 3214), metadata: ["chunk_level": .int(1)]
        )
        // Разряды разделяет тот же пробел, что и везде в приложении, —
        // не тот, что набирается с клавиатуры.
        XCTAssertEqual(shape, "\(3214.formatted()) знаков · родительский")
    }

    func testShapeNamesChildOnlyWhenItHasAParent() {
        XCTAssertEqual(
            EvaluationPreview.shape(
                text: String(repeating: "а", count: 503),
                metadata: ["chunk_level": .int(0), "parent_chunk_id": .string("abc")]
            ),
            "503 знака · дочерний"
        )
        // Плоская нарезка тоже пишет нулевой уровень — «дочерним» её кусок
        // называть нечем.
        XCTAssertEqual(
            EvaluationPreview.shape(text: String(repeating: "а", count: 503), metadata: ["chunk_level": .int(0)]),
            "503 знака"
        )
    }

    func testShapeIsNothingWithoutText() {
        XCTAssertNil(EvaluationPreview.shape(text: nil, metadata: nil))
        XCTAssertNil(EvaluationPreview.shape(text: "", metadata: nil))
    }
}
