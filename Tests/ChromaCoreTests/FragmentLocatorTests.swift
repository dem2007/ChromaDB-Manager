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
        let head = "Услуга размещения оборудования на серверной площадке "
        let tail = " Параметры качества оказания Услуги приведены в таблице."
        let document = head + "ТАБЛИЦА 1 41 стр. колонка вторая" + tail
        let chunk = head + "предоставляется по заявке Заказчика" + tail
        let found = located(chunk, in: document)
        XCTAssertEqual(found?.1, .edges)
        XCTAssertTrue(found?.0.hasPrefix("Услуга размещения") == true)
        XCTAssertTrue(found?.0.hasSuffix("в таблице.") == true)
    }

    /// Конец ищется **после** начала: иначе на документе, где начало чанка
    /// встречается дважды, подсветка растянулась бы назад через полстраницы.
    func testTheTailIsSearchedAfterTheHeadAndNotBefore() {
        let head = "Услуга размещения оборудования на серверной площадке "
        let tail = " Параметры качества оказания Услуги приведены в таблице."
        let document = tail + " … посторонний текст … " + head + "середина иная" + tail
        let chunk = head + "совсем другая середина" + tail
        guard let match = FragmentLocator.locate(chunk: chunk, in: document) else {
            return XCTFail("края должны найтись")
        }
        let highlighted = String(document[match.range])
        XCTAssertTrue(highlighted.hasPrefix("Услуга размещения"), highlighted)
        XCTAssertFalse(highlighted.contains("посторонний"), "выделение уехало назад: \(highlighted)")
    }

    // MARK: - Шаг 3: самое длинное предложение

    func testTheLongestSentenceIsUsedWhenEdgesFail() {
        let sentence = "Показатель считается по окончании каждого расчётного месяца"
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
        let paragraph = "Услуга размещения оборудования на серверной площадке оказывается "
            + "Исполнителем в соответствии с параметрами качества, приведёнными ниже. "
        let chunk = String(repeating: paragraph, count: 100)
        let document = String(repeating: "Посторонний текст документа. ", count: 500)
            + chunk + String(repeating: "И ещё посторонний текст. ", count: 500)
        let started = Date()
        let match = FragmentLocator.locate(chunk: chunk, in: document)
        XCTAssertNotNil(match)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0, "поиск места не должен занимать секунды")
    }

    // MARK: - По частям

    /// Пункты списка у Word начинаются с «•», в куске — с «— », а номер
    /// заголовка в тексте Word не стоит вовсе. Кусок находится целиком.
    func testListMarkersAndHeadingNumbersDoNotHideTheChunk() throws {
        let document = """
        Оглавление
        Состав услуги файлового архива\t348
        Прочий раздел о сетях передачи данных и каналах связи.
        Состав услуги файлового архива
        Встроенный журнал событий обязан рассылать оповещения о событиях таких видов:
        \t•\tрост каталога сверх заданного предела;
        \t•\tрост раздела сверх заданной доли от лимита.
        Следующий раздел о резервном копировании.
        """
        let chunk = """
        7.3.2 Состав услуги файлового архива
        Встроенный журнал событий обязан рассылать оповещения о событиях таких видов:
        — рост каталога сверх заданного предела;
        — рост раздела сверх заданной доли от лимита.
        """
        let match = try XCTUnwrap(FragmentLocator.locate(chunk: chunk, in: document))
        XCTAssertEqual(match.strategy, .allParts)
        let found = String(document[match.range])
        XCTAssertTrue(found.hasPrefix("Состав услуги файлового архива\nВстроенный"), "не в оглавлении: \(found)")
        XCTAssertTrue(found.hasSuffix("доли от лимита"), found)
    }

    /// «Все части нашлись» — ещё не «кусок подсвечен целиком»: строки таблицы
    /// из одних коротких ячеек опорой не служат, и подсветка кончается на
    /// предложении над ними. Точной она не считается (ревью…).
    func testUnanchoredRowsAtTheEndAreNotCalledExact() throws {
        let document = "Состав поставки определяется спецификацией к договору. № Кол-во 1 2 шт. 2 5 шт. 3 7 шт. 4 1 шт. 5 3 шт."
        let chunk = """
        Состав поставки определяется спецификацией к договору.
        | № | Кол-во |
        | --- | --- |
        | 1 | 2 шт. |
        | 2 | 5 шт. |
        | 3 | 7 шт. |
        | 4 | 1 шт. |
        | 5 | 3 шт. |
        """
        let match = try XCTUnwrap(FragmentLocator.locate(chunk: chunk, in: document))
        XCTAssertEqual(match.strategy, .mostParts)
        XCTAssertFalse(match.strategy.isExact)
    }

    /// Метка списка снимается и внутри ячейки, и после двоеточия: у Word там
    /// «•», у PDF — «–», а в куске — «— ».
    func testAListMarkerInsideACellIsDropped() throws {
        let document = "Функции Журнал: • рост каталога сверх заданного предела; • рост раздела сверх лимита"
        let chunk = "| Функции | Журнал: — рост каталога сверх заданного предела; — рост раздела сверх лимита |"
        let match = try XCTUnwrap(FragmentLocator.locate(chunk: chunk, in: document))
        XCTAssertEqual(match.strategy, .allParts)
        XCTAssertTrue(String(document[match.range]).hasSuffix("сверх лимита"), String(document[match.range]))
    }

    /// Состав сервера в прайсе: извлечение свело строки записи в одну и
    /// дописало количество в скобках с заголовком колонки. В PDF
    /// количество стоит отдельной колонкой — кусок находится по составу.
    func testRecordLabelsAddedByExtractionAreDropped() throws {
        let page = """
        7 Сервер Тип 7 (Архив) Сервер «Пример» T50
        X100 (ПРМР.000000.001) в составе:
        CPU Альфа 7726R 3.1GHz, 12C/24T, 18MB, 120W 2
        RAM DDR5 32GB 4800MHz ECC 12
        HDD SATA 8TB 3.5" 5400rpm 34
        """
        let chunk = """
        | № | Наименование | Кол-во, шт. |
        | --- | --- | --- |
        | 7 | Сервер Тип 7 (Архив) Сервер «Пример» T50 X100 (ПРМР.000000.001) в составе: CPU Альфа 7726R 3.1GHz, 12C/24T, 18MB, 120W (Кол-во, шт.: 2); RAM DDR5 32GB 4800MHz ECC (Кол-во, шт.: 12); HDD SATA 8TB 3.5" 5400rpm (Кол-во, шт.: 34) | 1 |
        """
        XCTAssertEqual(
            FragmentLocator.withoutRecordLabels("Сервер (Архив): CPU 120W (Кол-во, шт.: 2); RAM (Кол-во, шт.: 12)", headers: ["Кол-во, шт."]),
            "Сервер (Архив): CPU 120W; RAM"
        )
        let match = try XCTUnwrap(FragmentLocator.locate(chunk: chunk, in: page))
        XCTAssertNotEqual(match.strategy, .longestSentence)
        let found = String(page[match.range])
        XCTAssertTrue(found.hasPrefix("Сервер Тип 7"), found)
        XCTAssertTrue(found.hasSuffix("5400rpm"), found)
    }

    /// Такой же абзац выше — в соседнем разделе — не уводит подсветку:
    /// за ним нет остальных частей куска.
    func testARepeatedParagraphAboveDoesNotStretchTheHighlight() throws {
        let shared = "После копирования записей и смены рабочего узла Заказчик сверяет контрольные суммы архива."
        let document = """
        \(shared)
        Раздел о переезде архива завершён.
        \(String(repeating: "Посторонний текст раздела. ", count: 200))
        \(shared)
        Исполнитель сохраняет возможность вернуться на прежний узел в течение двух недель.
        """
        let chunk = "\(shared)\nИсполнитель сохраняет возможность вернуться на прежний узел в течение двух недель."
        let match = try XCTUnwrap(FragmentLocator.locate(chunk: chunk, in: document))
        let found = String(document[match.range])
        XCTAssertFalse(found.contains("Посторонний"), "подсветка растянулась от первого повтора")
        XCTAssertTrue(found.hasSuffix("двух недель."), found)
    }

    /// Края куска: начало — ближайшее к концу, а не первое в документе.
    func testEdgesTakeTheNearestStart() throws {
        let head = "Требования к услуге резервного копирования данных потребителей"
        let source = head + " " + String(repeating: "чужое ", count: 300)
            + head + " и середина куска, которая не совпала, а за ней его конец, как и в документе."
        let needle = NormalisedText.normalise(head + " и середина куска, записанная иначе, а за ней его конец, как и в документе.")
        let range = try XCTUnwrap(FragmentLocator.byEdges(needle: needle, haystack: NormalisedText(source)))
        XCTAssertFalse(source[range].contains("чужое"), String(source[range]))
    }

    // MARK: - Таблицы

    /// Кусок таблицы — Markdown с повторённой шапкой, а PDFKit читает ту же
    /// таблицу не строками: колонка количества стоит отдельно. Находится по
    /// узнаваемым ячейкам по порядку, без шапки: она стоит над
    /// строкой 11, которой в куске нет.
    func testATableChunkIsFoundByItsCells() throws {
        let page = """
        № Наименование Значение Количество 11. Контроллер тип 4 Контроллер Альфа 7720R \
        12. Контроллер тип 5 Контроллер Альфа 7718R 13. Контроллер тип 6 Контроллер Альфа 7414R \
        14. Контроллер тип 7 Контроллер Альфа 7858R 15. Контроллер тип 8 Контроллер Альфа 7722 \
        1 шт. 1 шт. 1 шт. 1 шт. 1 шт.
        """
        let chunk = """
        | № | Наименование | Значение | Количество |
        | --- | --- | --- | --- |
        | 12. | Контроллер тип 5 | Контроллер Альфа 7718R | 1 шт. |
        | 13. | Контроллер тип 6 | Контроллер Альфа 7414R | 1 шт. |
        | 14. | Контроллер тип 7 | Контроллер Альфа 7858R | 1 шт. |
        """
        let match = try XCTUnwrap(FragmentLocator.locate(chunk: chunk, in: page))
        XCTAssertEqual(match.strategy, .allParts)
        let found = String(page[match.range])
        XCTAssertTrue(found.hasPrefix("Контроллер тип 5"), found)
        XCTAssertTrue(found.hasSuffix("7858R"), found)
        XCTAssertFalse(found.contains("7720R"), "строка 11 в кусок не входит")
    }

    /// Шапка куска опорой не служит: на странице она стоит над всей
    /// таблицей, и подсветка начиналась бы с неё.
    func testTheHeaderOfATableChunkIsNotItsStart() {
        let rows = FragmentLocator.tableRows(of: "| Наименование характеристики | Значение |\n| --- | --- |\n| Объём оперативной памяти | 64 ГБ |")
        XCTAssertEqual(rows, [["Объём оперативной памяти", "64 ГБ"]])
    }

    /// Ячейка совпадает целиком, а не внутри длинного слова: «Контроллер тип 1»
    /// не находится в «Контроллер тип 12», стоящем выше.
    func testATableCellIsMatchedWhole() throws {
        let page = "11. Контроллер тип 12 Контроллер Альфа 7326 12. Контроллер тип 1 Контроллер Альфа 7848R 13. Контроллер тип 2 Контроллер Альфа 7840R"
        let chunk = """
        | № | Наименование | Значение |
        | --- | --- | --- |
        | 12. | Контроллер тип 1 | Контроллер Альфа 7848 |
        | 13. | Контроллер тип 2 | Контроллер Альфа 7840R |
        """
        let match = try XCTUnwrap(FragmentLocator.locateByTableCells(chunk: chunk, in: page))
        let found = String(page[match.range])
        XCTAssertTrue(found.hasPrefix("Контроллер тип 1 "), found)
        XCTAssertTrue(found.hasSuffix("7840R"), found)
    }

    /// Раздел, повторённый нормализацией в каждой строке куска, опорой не
    /// служит: на странице он один, над всем блоком, и подсветка начиналась
    /// бы со строк, которых в куске нет.
    func testARepeatedSectionIsNotTheStartOfATableChunk() throws {
        let page = """
        1. Модернизация серверной инфраструктуры 1.1 Сервер хранения данных тип 1 \
        1.2 Коммутатор доступа уровня ядра 1.3 Сервер приложений повышенной ёмкости \
        1.4 Система резервного копирования данных
        """
        let chunk = """
        | Раздел | № | Наименование |
        | --- | --- | --- |
        | 1. Модернизация серверной инфраструктуры | 1.3 | Сервер приложений повышенной ёмкости |
        | 1. Модернизация серверной инфраструктуры | 1.4 | Система резервного копирования данных |
        """
        let match = try XCTUnwrap(FragmentLocator.locateByTableCells(chunk: chunk, in: page))
        let found = String(page[match.range])
        XCTAssertTrue(found.hasPrefix("Сервер приложений"), found)
        XCTAssertFalse(found.contains("Коммутатор"), found)
    }

    /// Экранированная труба внутри значения остаётся в ячейке — разбор тот же,
    /// что у нарезки.
    func testAnEscapedPipeStaysInsideTheCell() {
        XCTAssertEqual(
            FragmentLocator.tableRows(of: "| А | Б |\n| --- | --- |\n| RAID 1 \\| RAID 10 | да |"),
            [["RAID 1 | RAID 10", "да"]]
        )
    }
}

