import XCTest
@testable import ChromaCore

/// Термы одним регулярным выражением вместо перебора написаний.
///
/// Все числа в комментариях — с живого сервера на коллекции из 5765 чанков,
/// а не из головы: П6.1 ТЗ требует проверять такое на установленной версии.
final class TextStageRegexTests: XCTestCase {

    func testOneTermBecomesACaseInsensitivePatternWithALeftBoundary() {
        XCTAssertEqual(TextRelevance.regexPattern(of: ["риск"]), "(?i)\\bриск")
    }

    /// Скобка с перечислением — на несколько термов, и граница остаётся общей.
    func testSeveralTermsBecomeOneAlternation() {
        XCTAssertEqual(
            TextRelevance.regexPattern(of: ["данных", "копированию"]),
            "(?i)(\\bданных|\\bкопированию)"
        )
    }

    /// Граница **только слева**: справа она отсекает не мусор, а склонения —
    /// «рисков», «риски», «риска». Поправка к П6.1, проверенная на живых
    /// данных: 73 чанка из 104.
    func testTheBoundaryIsNeverAddedOnTheRight() {
        let pattern = TextRelevance.regexPattern(of: ["риск"])
        XCTAssertFalse(pattern.hasSuffix("\\b"), "граница справа обрежет склонения")
    }

    /// «ё» и «е» — классом символов: подстрочный поиск так не умел вовсе.
    func testYoAndYeAreTheSameLetter() {
        XCTAssertEqual(TextRelevance.regexPattern(of: ["орел"]), "(?i)\\bор[её]л")
        XCTAssertEqual(TextRelevance.regexPattern(of: ["орёл"]), "(?i)\\bор[её]л")
    }

    /// Текст запроса приходит от человека и означает ровно себя: «C++»,
    /// «1.4.4», скобки. Незаэкранированный он либо сломает разбор выражения,
    /// либо — хуже — найдёт не то.
    func testTheQueryTextIsEscaped() {
        let pattern = TextRelevance.regexPattern(of: ["c++"])
        XCTAssertTrue(pattern.contains("\\+\\+"), "плюсы ушли в выражение как повтор: \(pattern)")
        XCTAssertFalse(TextRelevance.regexPattern(of: ["1.4.4"]).contains("1.4.4"), "точка осталась любым знаком")
        // Скобка человека не должна открывать группу выражения.
        XCTAssertTrue(TextRelevance.regexPattern(of: ["(в редакции)"]).contains("\\("))
    }

    /// Экранирование идёт **до** замены «е» на класс, иначе скобки самого
    /// класса были бы экранированы вместе с текстом и класс перестал бы им быть.
    func testTheCharacterClassSurvivesEscaping() {
        let pattern = TextRelevance.regexPattern(of: ["сервер"])
        XCTAssertTrue(pattern.contains("с[её]рв[её]р"), pattern)
        XCTAssertFalse(pattern.contains("\\["), "класс символов оказался экранирован")
    }

    /// При выключенном разбиении на слова термом становится весь запрос — со
    /// скобками и кавычками. Граница перед скобкой не значит ничего, и
    /// выражение с ней не совпало бы вовсе.
    func testATermStartingWithPunctuationGetsNoBoundary() {
        XCTAssertEqual(TextRelevance.regexPattern(of: ["(в редакции)"]), "(?i)\\(в р[её]дакции\\)")
        XCTAssertEqual(TextRelevance.regexPattern(of: ["«сервер»"]), "(?i)«с[её]рв[её]р»")
    }

    /// Целая фраза — тоже терм, и граница у неё одна, в начале.
    func testTheWholeQueryAsOneTermKeepsItsBoundary() {
        XCTAssertEqual(
            TextRelevance.regexPattern(of: ["резервное копирование"]),
            "(?i)\\bр[её]з[её]рвно[её] копировани[её]"
        )
    }

    func testNoTermsGiveNoPattern() {
        XCTAssertTrue(TextRelevance.regexPattern(of: []).isEmpty)
    }

    /// Новый профиль строится с выражением: замер показал равное качество
    /// вчетверо дешевле (5.56 с против 1.41 с на четырнадцати запросах).
    func testANewProfileAsksWithARegex() {
        XCTAssertTrue(SearchProfile(name: "новый", collectionName: "к").textSearchUsesRegex)
    }

    /// А сохранённый — как записан. Способ поиска у существующего профиля
    /// выбрал человек, и граница слова меняет состав кандидатов.
    func testProfilesWrittenBeforeKeepTheOldWay() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"старый","collectionName":"к","textSearchEnabled":true}
        """
        let profile = try JSONDecoder().decode(SearchProfile.self, from: Data(json.utf8))
        XCTAssertFalse(profile.textSearchUsesRegex)
    }
}

/// Пустой `where_document` — это «отдай первые попавшиеся документы», а не
/// «не ищи»: без условия текстовая стадия вернула бы случайную горсть чанков
/// и выдала бы их за найденные.
extension TextStageRegexTests {
    func testTheOperatorNameLivesInOnePlace() {
        XCTAssertEqual(TextRelevance.regexOperator, "$regex")
    }
}
