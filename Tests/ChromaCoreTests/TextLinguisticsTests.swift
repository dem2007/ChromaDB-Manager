import XCTest
import NaturalLanguage
@testable import ChromaCore

/// Язык и ключевые слова средствами системы.
///
/// Проверки написаны на **русских** примерах не случайно: разметка частей
/// речи для русского у `NLTagger` неверна, и весь отбор здесь держится
/// на леммах и списке пустых слов. Если это перестанет работать, в метаданные
/// базы поедет мусор, который потом придётся вычищать переиндексацией.
final class TextLinguisticsTests: XCTestCase {
    /// Приводит ли **эта** система слово к начальной форме.
    ///
    /// Словарь лемм `NLTagger` меняется от версии macOS, и на этом держались
    /// проверки, которые от версии зависеть не должны. Замер: на macOS 26.5
    /// лемматизируются все 29 слов образца, а на сборщике GitHub «насоса»
    /// остаётся «насоса» — и «давление» с «давления» попадают в ключевые
    /// слова **двумя разными**, то есть ровно тем, чего приём избегает.
    ///
    /// Проверка, упавшая от такого расхождения, проверяет словарь системы,
    /// а не отбор, который мы написали. Поэтому спрашиваем прямо.
    static func lemmatises(_ word: String, to base: String) -> Bool {
        let sentence = "Значение \(word) указано в документе."
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = sentence
        // Язык называется прямо: на короткой фразе система его не распознаёт
        // и лемм не даёт вовсе — проба без этого объявляла бы «лемм нет»
        // на машине, где они есть.
        tagger.setLanguage(.russian, range: sentence.startIndex..<sentence.endIndex)
        guard let range = sentence.range(of: word) else { return false }
        let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
        return lemma?.lowercased() == base
    }

    // MARK: - Язык

    func testTheLanguageOfAProperSentenceIsRecognised() {
        XCTAssertEqual(TextLinguistics.language(of: "Отпуск оформляется заявлением за две недели."), "ru")
        XCTAssertEqual(TextLinguistics.language(of: "The backup runs nightly on the archive server."), "en")
    }

    /// «Итого: 42» система объявляет русским с уверенностью 1.00 — а слов
    /// в этой строке нет вовсе. Такому чанку язык достаётся от документа.
    func testATooShortStringGetsNoLanguageAtAll() {
        XCTAssertNil(TextLinguistics.language(of: "Итого: 42"))
        XCTAssertNil(TextLinguistics.language(of: ""))
        XCTAssertNil(TextLinguistics.language(of: "42 000 ₽"))
    }

    // MARK: - Ключевые слова: русский

    func testRussianKeywordsComeBackInTheirBaseForm() throws {
        // Эта проверка **о леммах**, и на системе без них она проверяет
        // не наш отбор, а чужой словарь.
        try XCTSkipUnless(
            Self.lemmatises("отпуска", to: "отпуск"),
            "система не приводит русские слова к начальной форме — проверять нечего"
        )
        let text = """
        Отпуск оформляется заявлением за две недели до начала. Заявление \
        на отпуск подписывает руководитель отдела. Отпуска переносятся \
        по согласованию с руководителем.
        """
        let words = TextLinguistics.keywords(in: text)
        XCTAssertTrue(words.contains("отпуск"), "«Отпуск», «отпуск» и «Отпуска» — одно слово: \(words)")
        XCTAssertTrue(words.contains("заявление"), words.joined(separator: ", "))
        XCTAssertTrue(words.contains("руководитель"), words.joined(separator: ", "))
        // Ни одной словоформы: фасет из «отпуска» и «отпуску» бесполезен.
        XCTAssertFalse(words.contains("отпуска"), words.joined(separator: ", "))
        XCTAssertFalse(words.contains("руководителем"), words.joined(separator: ", "))
    }

    /// Частое слово идёт первым: по нему и фильтруют.
    ///
    /// Проверяется **порядок**, а не лемматизация: слово о трёх упоминаниях
    /// обязано опередить слова об одном, и это наша логика. В какой форме
    /// оно при этом окажется, решает словарь системы — там, где он полон,
    /// это «насос», где нет — «насоса».
    func testTheMostFrequentWordLeads() {
        let text = """
        Превышение допустимого значения давления приводит к отказу насоса. \
        Давление измеряется манометром на входе насоса, показания заносятся \
        в журнал. Насос останавливается автоматически.
        """
        let words = TextLinguistics.keywords(in: text)
        XCTAssertEqual(
            words.first?.hasPrefix("насос"), true,
            "насос встречается трижды и обязан быть первым: \(words)"
        )
        XCTAssertTrue(words.contains { $0.hasPrefix("давлени") }, words.joined(separator: ", "))

        // А там, где система лемматизирует, форма обязана быть начальной:
        // иначе мы не заметим, если сломается уже наш отбор.
        if Self.lemmatises("насоса", to: "насос") {
            XCTAssertEqual(words.first, "насос", words.joined(separator: ", "))
        }
    }

    /// Слова, которые есть в любом документе, в ключевые не попадают —
    /// иначе фасет состоит из «система, данные, документ» у всех подряд.
    func testEmptyWordsAreDropped() {
        let text = """
        Данный документ является системой. В данном разделе приведены данные \
        и результаты работы. Настоящий текст имеет значение.
        """
        let words = TextLinguistics.keywords(in: text)
        for empty in ["документ", "система", "данные", "раздел", "результат", "значение", "текст"] {
            XCTAssertFalse(words.contains(empty), "«\(empty)» есть в любом документе: \(words)")
        }
    }

    /// Латиница внутри русского текста уцелевает: у технических терминов
    /// леммы нет, и терять их нельзя.
    func testLatinTermsInsideRussianTextSurvive() {
        let text = """
        Файл config.json лежит в каталоге приложения. Параметр timeout \
        задаётся в секундах, timeout по умолчанию равен тридцати.
        """
        let words = TextLinguistics.keywords(in: text)
        XCTAssertTrue(words.contains("timeout"), words.joined(separator: ", "))
    }

    // MARK: - Ключевые слова: английский

    /// Для английского разметка частей речи точная, и отбор идёт по ней:
    /// глаголы и наречия в ключевые слова не попадают.
    func testEnglishKeywordsAreNounsInTheirBaseForm() {
        let text = """
        The nightly backup runs at midnight and stores archives on the server. \
        Backups older than ninety days are removed from the archive.
        """
        let words = TextLinguistics.keywords(in: text)
        XCTAssertTrue(words.contains("backup"), words.joined(separator: ", "))
        XCTAssertTrue(words.contains("archive"), "archives и archive — одно слово: \(words)")
        XCTAssertFalse(words.contains("nightly"), "наречие — не ключевое слово: \(words)")
    }

    // MARK: - Общее

    func testShortWordsAndNumbersAreNotKeywords() {
        let words = TextLinguistics.keywords(in: "Год 2026 был тёплым, но не для всех. Ещё как.")
        XCTAssertFalse(words.contains("2026"))
        XCTAssertTrue(words.allSatisfy { $0.count >= 4 }, words.joined(separator: ", "))
    }

    func testTheListIsCappedAndJoinedForMetadata() {
        let text = String(
            repeating: "Насос манометр давление задвижка клапан фильтр трубопровод манжета прокладка фланец. ",
            count: 2
        )
        XCTAssertLessThanOrEqual(TextLinguistics.keywords(in: text).count, TextLinguistics.keywordLimit)
        let line = TextLinguistics.keywordLine(in: text)
        XCTAssertNotNil(line)
        XCTAssertFalse(line?.contains("[") ?? true, "в метаданных ChromaDB списков не бывает — только строка")
        XCTAssertNil(TextLinguistics.keywordLine(in: ""))
    }
}

/// Контекстный префикс: строка «Документ → Раздел» уходит в модель, но не
/// в текст документа.
final class ContextPrefixTests: XCTestCase {
    func testThePrefixIsBuiltFromTheTitleAndTheHeadingPath() {
        XCTAssertEqual(
            SourceSyncService.contextPrefix(title: "Регламент отпусков", headingPath: "Порядок > Заявление"),
            "Регламент отпусков → Порядок → Заявление"
        )
        XCTAssertEqual(
            SourceSyncService.contextPrefix(title: "Регламент", headingPath: nil),
            "Регламент"
        )
        XCTAssertNil(
            SourceSyncService.contextPrefix(title: "   ", headingPath: nil),
            "приписывать к тексту пустую стрелку — это шум в векторе"
        )
    }

    /// Имя документа берётся из его метаданных, а без них — из имени файла:
    /// чанк из «Регламент отпусков.docx» обязан находиться по слову «отпуск»,
    /// даже если внутри абзаца этого слова нет.
    func testTheTitleFallsBackToTheFileName() {
        XCTAssertEqual(
            SourceSyncService.documentTitle(
                metadata: ["title": .string("Регламент отпусков")], relativePath: "hr/reg-2026.docx"
            ),
            "Регламент отпусков"
        )
        XCTAssertEqual(
            SourceSyncService.documentTitle(metadata: [:], relativePath: "hr/Регламент отпусков.docx"),
            "Регламент отпусков"
        )
        XCTAssertEqual(
            SourceSyncService.documentTitle(metadata: ["title": .string("  ")], relativePath: "a/b.md"),
            "b"
        )
    }

    /// префикс меняет то, что уходит в модель, — значит это часть
    /// рецепта коллекции, и переиндексацию она обязана вызывать.
    func testTheOptionIsPartOfTheStrategySignature() {
        var plain = ChunkingConfiguration()
        var withContext = plain
        withContext.contextPrefix = true
        XCTAssertNotEqual(plain.signature, withContext.signature)

        // …и при любой стратегии, а не только у одной.
        plain.strategy = .semantic
        withContext.strategy = .semantic
        XCTAssertNotEqual(plain.signature, withContext.signature)
    }

    /// Выключено по умолчанию: включение стоит переиндексации всей коллекции,
    /// и решать это должен человек.
    func testTheOptionIsOffByDefault() {
        XCTAssertFalse(ChunkingConfiguration().contextPrefix)
    }
}
