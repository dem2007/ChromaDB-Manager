import XCTest
@testable import ChromaCore

/// Сшивка визуальных строк PDF в абзацы.
final class PDFTextReflowTests: XCTestCase {
    /// Ширина набора — 68 знаков; строки абзаца идут во всю ширину, последняя
    /// короче. Это и есть признак конца абзаца.
    private let prose = """
    Настоящий регламент устанавливает порядок взаимодействия сторон при
    оказании услуг связи и определяет требования к качеству предоставляемых
    сервисов на всём протяжении срока действия договора между сторонами.
    Стороны подтверждают согласие.
    Плановые работы проводятся в ночное время по предварительному уведомлению
    заказчика не позднее чем за пять рабочих дней до даты начала таких работ.
    """

    func testWrappedLinesBecomeParagraphs() {
        let result = PDFTextReflow.page(prose)
        let paragraphs = result.components(separatedBy: "\n\n")

        XCTAssertEqual(paragraphs.count, 2, "два абзаца, а получено \(paragraphs.count):\n\(result)")
        XCTAssertTrue(paragraphs[0].hasPrefix("Настоящий регламент"))
        XCTAssertTrue(paragraphs[0].hasSuffix("Стороны подтверждают согласие."))
        XCTAssertTrue(paragraphs[1].hasPrefix("Плановые работы"))
        // Внутри абзаца переводов строк не остаётся вовсе — ради этого всё
        // и затевалось: иначе recursive режет по строке, а не по предложению.
        XCTAssertFalse(paragraphs[0].contains("\n"))
    }

    /// Ни одного знака не потеряно и не переставлено — сшивка меняет только
    /// пробелы, переводы строк и те дефисы, о которых решила отдельно.
    func testNothingButWhitespaceChanges() {
        let letters = { (text: String) in String(text.filter { $0.isLetter || $0.isNumber }) }
        XCTAssertEqual(letters(PDFTextReflow.page(prose)), letters(prose))
    }

    /// Таблица не сшивается: там строка — это запись, и склеить её
    /// со следующей значило бы смешать две записи.
    func testATableIsLeftAlone() {
        let table = """
        Наименование услуги Цена Количество
        Подключение канала 12 000 2
        Абонентская плата 4 500 12
        Настройка оборудования 8 000 1
        Диагностика 3 000 4
        """
        let result = PDFTextReflow.page(table)
        XCTAssertFalse(result.contains("\n\n"), "таблицу сшивать нельзя:\n\(result)")
        XCTAssertEqual(result.components(separatedBy: "\n").count, 5)
    }

    /// Пункты перечисления остаются пунктами, даже когда предыдущая строка
    /// шла во всю ширину.
    func testListItemsStayApart() {
        let list = """
        Исполнитель обязан обеспечить выполнение следующих требований к работам
        ● Круглосуточный мониторинг доступности всех компонентов информационной
        ● Восстановление работоспособности в течение четырёх часов с момента
        1. Ежемесячный отчёт о качестве оказанных услуг за отчётный период
        2. Ежеквартальная сверка взаимных расчётов между сторонами договора
        """
        let paragraphs = PDFTextReflow.page(list).components(separatedBy: "\n\n")
        XCTAssertEqual(paragraphs.count, 5, "каждый пункт — свой блок, а вышло:\n\(paragraphs)")
    }

    // MARK: - Дефис

    /// Документ, который пользуется автопереносом: слитная форма встречается
    /// в нём же, и дефис снимается.
    func testASyllableBreakIsGluedWhenTheDocumentSaysSo() {
        let pages = ["Порядок применения правил.", "Порядок приме-\nнения настоящего приложения."]
        let vocabulary = PDFTextReflow.vocabulary(ofPages: pages)
        XCTAssertTrue(vocabulary.words.contains("применения"))

        let result = PDFTextReflow.joined("Порядок приме-", "нения настоящего", vocabulary: vocabulary)
        XCTAssertEqual(result, "Порядок применения настоящего")
    }

    /// Составное слово: дефис — часть слова, и снимать его нельзя.
    /// Именно этот случай преобладает в делопроизводственных документах.
    func testACompoundWordKeepsItsHyphen() {
        let pages = [
            "Развитие информационно-телекоммуникационной сети общего пользования.",
            "Развитие информационно-\nтелекоммуникационной инфраструктуры.",
        ]
        let vocabulary = PDFTextReflow.vocabulary(ofPages: pages)

        let result = PDFTextReflow.joined(
            "Развитие информационно-", "телекоммуникационной инфраструктуры", vocabulary: vocabulary
        )
        XCTAssertEqual(result, "Развитие информационно-телекоммуникационной инфраструктуры")
    }

    /// Документ не сказал о слове ничего. Тогда дефис остаётся: выдуманное
    /// слитное слово не найдёт ни поиск, ни модель.
    func testAnUnknownWordKeepsItsHyphenByDefault() {
        let result = PDFTextReflow.joined("шеф-", "повар готовит", vocabulary: .empty)
        XCTAssertEqual(result, "шеф-повар готовит")
    }

    /// А если документ вообще пользуется автопереносом — неопознанное слово
    /// тоже перенос: это настройка на весь файл.
    func testAnUnknownWordFollowsTheDocumentsHabit() {
        let pages = [
            "Строительной организации выданы разрешения.",
            "Работы строитель-\nной организации приняты заказчиком без замечаний.",
        ]
        let vocabulary = PDFTextReflow.vocabulary(ofPages: pages)
        XCTAssertTrue(vocabulary.usesHyphenation, "документ переносит по слогам")

        XCTAssertEqual(
            PDFTextReflow.joined("совсем незнако-", "мого слова", vocabulary: vocabulary),
            "совсем незнакомого слова"
        )
    }

    /// Слова с разрыва не попадают в словарь — иначе он подтверждал бы сам
    /// себя и отвечал «да» на любой вопрос.
    func testABrokenWordDoesNotVouchForItself() {
        let pages = ["Единственное упоминание: информационно-\nтехнологическое обеспечение."]
        let vocabulary = PDFTextReflow.vocabulary(ofPages: pages)

        XCTAssertFalse(vocabulary.words.contains("информационно-технологическое"))
        XCTAssertFalse(vocabulary.words.contains("информационнотехнологическое"))
    }

    /// Прописная буква в начале следующей строки — новое предложение,
    /// а не продолжение слова. Дефис там тире, и склеивать нечего.
    func testAHyphenBeforeACapitalIsNotABrokenWord() {
        XCTAssertNil(PDFTextReflow.brokenWord(at: 0, in: ["Первое —", "Второе положение"]))
        XCTAssertNotNil(PDFTextReflow.brokenWord(at: 0, in: ["приме-", "нение"]))
    }

    /// Пустая строка в исходнике — граница, поставленная самим документом,
    /// и она точнее любой догадки по ширине.
    func testAnExplicitBlankLineIsHonoured() {
        let text = """
        Первый абзац идёт во всю ширину строки и продолжается дальше по тексту
        документа без единого разрыва внутри себя.

        Второй абзац начинается после пустой строки и тоже идёт во всю ширину
        набора, как ему и положено.
        """
        let paragraphs = PDFTextReflow.page(text).components(separatedBy: "\n\n")
        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertTrue(paragraphs[1].hasPrefix("Второй абзац"))
    }

    /// Короткому куску сшивать нечего, и выдумывать ширину набора по двум
    /// строкам нельзя.
    func testTooFewLinesAreLeftAlone() {
        XCTAssertEqual(PDFTextReflow.page("Одна строка."), "Одна строка.")
        XCTAssertEqual(PDFTextReflow.page("Раз\nДва"), "Раз\nДва")
    }
}
