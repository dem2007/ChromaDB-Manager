import XCTest
@testable import ChromaCore

/// поиск места чанка в исходном документе.
///
/// Тесты «золотые» в том смысле, какой требует ТЗ: тексты отличаются от
/// исходных ровно теми искажениями, которые вносит извлечение, — переносы,
/// пробелы, лигатуры, — и место обязано находиться.
final class FragmentLocatorTests: XCTestCase {

    private func located(_ chunk: String, in document: String) -> (String, FragmentLocator.Strategy)? {
        guard let match = FragmentLocator.locate(chunk: chunk, in: document) else { return nil }
        return (String(document[match.range]), match.strategy)
    }

    // MARK: - Шаг 1: точное совпадение

    func testAnUntouchedChunkIsFoundWhole() {
        let document = "Первый абзац. Доступность рассчитывается как отношение времени. Третий абзац."
        let found = located("Доступность рассчитывается как отношение времени.", in: document)
        XCTAssertEqual(found?.1, .exact)
        XCTAssertEqual(found?.0, "Доступность рассчитывается как отношение времени.")
    }

    /// Подсветка идёт по **исходному** тексту: если бы диапазон считался
    /// в нормализованном, выделение уехало бы на число выброшенных пробелов.
    func testTheRangePointsIntoTheOriginalTextNotTheNormalisedOne() {
        let document = "Заголовок\n\n\n   Доступность    рассчитывается\n   как отношение.   Конец."
        guard let match = FragmentLocator.locate(
            chunk: "Доступность рассчитывается как отношение.", in: document
        ) else { return XCTFail("не нашлось") }
        let highlighted = String(document[match.range])
        XCTAssertTrue(highlighted.hasPrefix("Доступность"), highlighted)
        XCTAssertTrue(highlighted.hasSuffix("отношение."), highlighted)
        // Внутри выделения остались исходные пробелы и переводы строк —
        // значит это действительно кусок оригинала.
        XCTAssertTrue(highlighted.contains("\n"), highlighted)
    }

    /// Извлечение схлопывает пробелы и переводы строк; документ на диске —
    /// нет. Наивный поиск подстроки здесь и промахивается.
    func testWhitespaceDifferencesDoNotPreventTheMatch() {
        let document = "…текст.\n\nДоступность\n    рассчитывается   как\nотношение времени.\n\n…"
        XCTAssertEqual(
            located("Доступность рассчитывается как отношение времени.", in: document)?.1,
            .exact
        )
    }

    /// Перенос слова: «приме-\nнение» в вёрстке — одно слово «применение».
    func testAWordBrokenByAHyphenAndNewlineIsGluedBack() {
        let document = "Порядок приме-\nнения настоящего Приложения определяется контрактом."
        XCTAssertEqual(
            located("Порядок применения настоящего Приложения определяется контрактом.", in: document)?.1,
            .exact
        )
    }

    /// А обычный дефис внутри строки — часть слова и обязан остаться.
    ///
    /// Со слитной формой совпадение теперь бывает, но только последним шагом
    /// и под своим именем: `ignoringHyphens` — огрублённый поиск, и человеку
    /// об этом говорят. Точным такое совпадение не считается.
    func testAnOrdinaryHyphenSurvives() {
        let document = "Обслуживание ИТ-инфраструктуры заказчика."
        XCTAssertEqual(located("Обслуживание ИТ-инфраструктуры заказчика.", in: document)?.1, .exact)

        let glued = FragmentLocator.locate(chunk: "ИТинфраструктуры", in: document)
        XCTAssertEqual(glued?.strategy, .ignoringHyphens)
        XCTAssertEqual(glued?.strategy.isExact, false)
    }

    /// То, ради чего слепой шаг заведён: извлечение сохранило дефис
    /// составного слова, а на странице он разорван концом строки.
    ///
    /// Без этого шага подсветка пропадала бы на делопроизводственных
    /// документах, где таких слов больше всего.
    func testACompoundWordBrokenByALineEndStillMatches() {
        let document = "Развитие информационно-\nтелекоммуникационной инфраструктуры органов власти."
        let chunk = "Развитие информационно-телекоммуникационной инфраструктуры органов власти."
        XCTAssertEqual(FragmentLocator.locate(chunk: chunk, in: document)?.strategy, .ignoringHyphens)
    }

    func testCaseAndDiacriticsDoNotMatter() {
        let document = "Ещё раз: ДОСТУПНОСТЬ Услуги за Отчетный период."
        XCTAssertEqual(located("доступность услуги за отчётный период", in: document)?.1, .exact)
    }

    /// Лигатура в PDF раскладывается в две буквы, но позиция в оригинале
    /// у них одна — карта обязана это выдержать.
    func testALigatureDoesNotBreakTheMapping() {
        let document = "The oﬃce of the classiﬁcation committee."
        guard let match = FragmentLocator.locate(
            chunk: "office of the classification", in: document
        ) else { return XCTFail("лигатура должна раскладываться") }
        XCTAssertTrue(String(document[match.range]).contains("ﬃ"))
    }

    // MARK: - Шаг 2: по краям

    /// Середина испорчена (в PDF так бывает от порядка колонок), края целы.
    func testEdgesMatchWhenTheMiddleDiffers() {
        let head = "Услуга предоставления ресурсов центра обработки данных "
        let tail = " Параметры качества оказания Услуги приведены в таблице."
        let document = head + "ТАБЛИЦА 1 41 стр. колонка вторая" + tail
        let chunk = head + "предоставляется по заявке Заказчика" + tail
        let found = located(chunk, in: document)
        XCTAssertEqual(found?.1, .edges)
        XCTAssertTrue(found?.0.hasPrefix("Услуга предоставления") == true)
        XCTAssertTrue(found?.0.hasSuffix("в таблице.") == true)
    }

    /// Конец ищется **после** начала: иначе на документе, где начало чанка
    /// встречается дважды, подсветка растянулась бы назад через полстраницы.
    func testTheTailIsSearchedAfterTheHeadAndNotBefore() {
        let head = "Услуга предоставления ресурсов центра обработки данных "
        let tail = " Параметры качества оказания Услуги приведены в таблице."
        let document = tail + " … посторонний текст … " + head + "середина иная" + tail
        let chunk = head + "совсем другая середина" + tail
        guard let match = FragmentLocator.locate(chunk: chunk, in: document) else {
            return XCTFail("края должны найтись")
        }
        let highlighted = String(document[match.range])
        XCTAssertTrue(highlighted.hasPrefix("Услуга предоставления"), highlighted)
        XCTAssertFalse(highlighted.contains("посторонний"), "выделение уехало назад: \(highlighted)")
    }

    // MARK: - Шаг 3: самое длинное предложение

    func testTheLongestSentenceIsUsedWhenEdgesFail() {
        let sentence = "Доступность рассчитывается по истечении каждого отчетного периода"
        let document = "Совсем другое начало. \(sentence). И совсем другой конец."
        let chunk = "Иное начало, которого в документе нет. \(sentence). Иной конец, которого тоже нет."
        let found = located(chunk, in: document)
        XCTAssertEqual(found?.1, .longestSentence)
        XCTAssertEqual(found?.0, sentence)
    }

    /// Короткое предложение не годится: «Да.» найдётся где угодно и подсветит
    /// случайное место — это хуже, чем не подсветить ничего.
    func testAShortSentenceIsNotUsedAsAnAnchor() {
        let document = "Да. Здесь длинный и совершенно посторонний текст документа."
        XCTAssertNil(FragmentLocator.locate(chunk: "Да. Нет.", in: document))
    }

    // MARK: - Шаг 4: не нашлось — это исход, а не ошибка

    func testAChunkThatIsNotThereReturnsNothingRatherThanAWrongPlace() {
        let document = "Текст про совершенно другое: закупка оборудования и сроки поставки."
        XCTAssertNil(FragmentLocator.locate(
            chunk: "Аттестационные испытания объекта информатизации проводятся Исполнителем.",
            in: document
        ))
    }

    func testEmptyInputsAreNotAMatch() {
        XCTAssertNil(FragmentLocator.locate(chunk: "", in: "текст"))
        XCTAssertNil(FragmentLocator.locate(chunk: "текст", in: ""))
        XCTAssertNil(FragmentLocator.locate(chunk: "   \n  ", in: "текст"))
    }

    // MARK: - Устойчивость

    /// Чанк в семь тысяч знаков — обычный размер иерархической нарезки.
    func testALongChunkInALongDocumentIsFoundQuickly() {
        let paragraph = "Услуга предоставления ресурсов центра обработки данных оказывается "
            + "Исполнителем в соответствии с параметрами качества, приведёнными ниже. "
        let chunk = String(repeating: paragraph, count: 100)
        let document = String(repeating: "Посторонний текст документа. ", count: 500)
            + chunk + String(repeating: "И ещё посторонний текст. ", count: 500)
        let started = Date()
        let match = FragmentLocator.locate(chunk: chunk, in: document)
        XCTAssertNotNil(match)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0, "поиск места не должен занимать секунды")
    }
}
