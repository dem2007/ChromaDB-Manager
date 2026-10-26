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
        XCTAssertEqual(EvaluationPreview.stems(of: "Порядок обновления"), ["порядо", "обновл"])
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

    /// Окно не длиннее заказанного — карточка отведена под пять строк.
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

    // MARK: - Редкость слов

    /// Слова, которые есть почти в каждом куске выдачи, не перетягивают окно
    /// у редких: общая фраза о «государственных информационных системах»
    /// обходила место, где стоят «комплексное тестирование» и «дней».
    func testRareWordsOutweighCommonOnes() {
        let boilerplate = "услуг по развитию и доработке государственных информационных систем"
        let text = boilerplate + ". " + String(repeating: "Прочий текст положения. ", count: 14)
            + "Общий срок проведения комплексного тестирования — не менее 10 дней."
        let query = "Сколько дней длится комплексное тестирование при развитии государственных информационных систем"
        let others = (0..<20).map { "\(boilerplate) номер \($0)" }
        let rarity = EvaluationPreview.Rarity(texts: others + [text], queries: [query])

        let weighted = EvaluationPreview.snippet(of: text, matching: query, rarity: rarity)
        XCTAssertTrue(weighted.contains("10 дней"), weighted)
        let plain = EvaluationPreview.snippet(of: text, matching: query)
        XCTAssertTrue(plain.contains("государственных информационных"), "без весов побеждает общая фраза: \(plain)")
    }

    /// Ответ обычно стоит за словами вопроса — перед совпадением окно берёт
    /// немного, и «КС3» не уходит за край.
    func testTheAnswerAfterTheWordsStaysInTheWindow() {
        let text = String(repeating: "Требования к пропускной способности порта оборудования. ", count: 6)
            + "Канал к шлюзу обмена шифруется средствами защиты. Средства защиты берутся класса не ниже КС3 и "
            + "работают в паре с резервным узлом. "
            + String(repeating: "Прочие требования. ", count: 10)
        let snippet = EvaluationPreview.snippet(of: text, matching: "Какой класс средств защиты нужен для канала к шлюзу обмена")
        XCTAssertTrue(snippet.contains("КС3"), snippet)
        XCTAssertTrue(snippet.hasPrefix("…"), snippet)
    }

    /// Из окон равного веса берётся то, где слова стоят теснее.
    func testTheTighterWindowWinsATie() {
        let text = "Подключение " + String(repeating: "прокладка ", count: 12) + "СМЭВ. "
            + String(repeating: "Прочий текст. ", count: 12)
            + "Подключение к СМЭВ — защищённое, класс КС3. " + String(repeating: "Хвост. ", count: 30)
        let snippet = EvaluationPreview.snippet(of: text, matching: "подключение СМЭВ", limit: 80)
        XCTAssertTrue(snippet.contains("КС3"), snippet)
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
