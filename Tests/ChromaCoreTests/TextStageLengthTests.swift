import XCTest
@testable import ChromaCore

/// Текстовая стадия по длине запроса.
///
/// Замер, из которого взялась настройка: на 43 парах «запрос × коллекция»
/// стадия ведёт себя на длинных и коротких запросах противоположно. «МВХ» без
/// неё не находится вовсе (1.00 → 0.00), девять трудных вопросов с ней хуже
/// (0.452 против 0.571). Перебором порога: без стадии 0.685, со стадией
/// всегда 0.745, со стадией до пяти слов — 0.799.
final class TextStageLengthTests: XCTestCase {

    private func profile(limit: Int?, text: Bool = true) -> SearchProfile {
        SearchProfile(
            name: "опыт", collectionName: "к",
            textSearchEnabled: text, textSearchMaxWords: limit
        )
    }

    func testWithoutAThresholdTheStageWorksOnAnyQuery() {
        let profile = profile(limit: nil)
        XCTAssertTrue(profile.textSearchApplies(to: "МВХ"))
        XCTAssertTrue(profile.textSearchApplies(
            to: "Чем отличаются цены на модуль вычисления в коммерческих предложениях"))
    }

    /// Порог включительный: «не длиннее пяти слов» значит, что пять — можно.
    func testTheThresholdIsInclusive() {
        let profile = profile(limit: 5)
        XCTAssertTrue(profile.textSearchApplies(to: "один два три четыре пять"))
        XCTAssertFalse(profile.textSearchApplies(to: "один два три четыре пять шесть"))
    }

    func testTheAbbreviationKeepsTheStageAndTheLongQuestionLosesIt() {
        let profile = profile(limit: 5)
        XCTAssertTrue(profile.textSearchApplies(to: "СМЭВ"))
        XCTAssertTrue(profile.textSearchApplies(to: "Импортозамещение программного обеспечения"))
        XCTAssertFalse(profile.textSearchApplies(
            to: "Сколько копий данных хранят Hadoop, ClickHouse и Kafka и какой коэффициент"))
    }

    /// Выключенная стадия остаётся выключенной: порог её не включает.
    func testTheThresholdNeverTurnsTheStageOn() {
        XCTAssertFalse(profile(limit: 5, text: false).textSearchApplies(to: "МВХ"))
        XCTAssertFalse(profile(limit: nil, text: false).textSearchApplies(to: "МВХ"))
    }

    /// Пунктуация словом не считается, иначе порог сработал бы раньше времени.
    func testPunctuationIsNotAWord() {
        XCTAssertEqual(SearchProfile.wordCount("vCPU, МВХ"), 2)
        XCTAssertEqual(SearchProfile.wordCount("  Arenadata  "), 1)
        XCTAssertEqual(SearchProfile.wordCount("—  —"), 0)
        XCTAssertEqual(SearchProfile.wordCount(""), 0)
    }

    /// Профили, записанные до появления порога, читаются как «порога нет»:
    /// иначе правка молча поменяла бы поиск на всех сохранённых профилях.
    func testProfilesWrittenBeforeTheThresholdKeepWorking() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"старый","collectionName":"к","textSearchEnabled":true}
        """
        let profile = try JSONDecoder().decode(SearchProfile.self, from: Data(json.utf8))
        XCTAssertNil(profile.textSearchMaxWords)
        XCTAssertTrue(profile.textSearchApplies(to: "какой угодно длинный запрос из многих слов подряд"))
    }

    /// Порог переживает запись и чтение: настройка, теряющаяся при сохранении,
    /// выглядит как «не сработало».
    func testTheThresholdSurvivesARoundTrip() throws {
        let data = try JSONEncoder().encode(profile(limit: 5))
        let back = try JSONDecoder().decode(SearchProfile.self, from: data)
        XCTAssertEqual(back.textSearchMaxWords, 5)
    }
}
