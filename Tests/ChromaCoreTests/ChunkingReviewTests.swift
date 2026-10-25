import XCTest
@testable import ChromaCore

/// Ультраревью среза «нарезка и просмотрщик».
final class ChunkingReviewTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-cut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - HTML

    /// Лишний закрывающий тег и незакрытый последний блок не повторяют текст.
    func testUnbalancedTagsDoNotDuplicateText() {
        let chunker = DocumentBasedChunker(configuration: ChunkingConfiguration(strategy: .documentBased))
        XCTAssertEqual(
            chunker.htmlSections("<section>A</section>B</section>"),
            ["<section>A</section>", "B</section>"]
        )
        XCTAssertEqual(chunker.htmlSections("X<section>Y"), ["X", "<section>Y"])
    }

    // MARK: - Модели и подпись

    /// Пустая модель предложений — «не задана»: откат к модели источника.
    func testAnEmptySentenceModelFallsBackToTheSourceModel() {
        var configuration = ChunkingConfiguration(strategy: .semantic)
        configuration.sentenceEmbeddingModel = "  "
        XCTAssertNil(configuration.resolvedSentenceModel)
        XCTAssertTrue(configuration.signature.contains("sm:source"), configuration.signature)
    }

    /// Модель обогащения — в подписи: её смена меняет векторы.
    func testTheEnrichmentModelIsPartOfTheSignature() {
        var configuration = ChunkingConfiguration(contextEnrichment: true, enrichmentModel: "qwen-a")
        let first = configuration.signature
        configuration.enrichmentModel = "qwen-b"
        XCTAssertNotEqual(configuration.signature, first)
        configuration.enrichmentModel = nil
        configuration.chatModel = "qwen-c"
        XCTAssertTrue(configuration.signature.contains("ctx+llm:qwen-c"), configuration.signature)
    }

    /// Абсолютный порог на карточке — с дробью, а не «0».
    func testTheAbsoluteThresholdIsShownWithItsFraction() {
        var configuration = ChunkingConfiguration(strategy: .semantic)
        configuration.thresholdMode = .absolute
        configuration.thresholdValue = 0.25
        XCTAssertTrue(configuration.summaryText.contains("0.25"), configuration.summaryText)
    }

    // MARK: - Дорезка таблиц

    /// Части таблицы, дорезанной под модель, несут длину дописанной шапки.
    func testSplitTablePiecesCarryTheirRepeatedHeaderLength() {
        let header = "| Артикул | Наименование |\n| --- | --- |"
        let rows = (1...60).map { "| A-\($0) | Позиция с довольно длинным описанием номер \($0) |" }
        let text = ([header] + rows).joined(separator: "\n")
        let fitted = OversizeChunks.fitted([TextChunk(index: 0, text: text)], contextLength: nil, characterLimit: 800).chunks
        XCTAssertGreaterThan(fitted.count, 1)
        XCTAssertEqual(fitted[0].repeatedHeaderLength, 0, "шапка первой части стоит в файле на своём месте")
        for piece in fitted.dropFirst() {
            XCTAssertTrue(piece.text.hasPrefix(header))
            XCTAssertEqual(piece.repeatedHeaderLength, header.count + 1)
        }

        let viaSheets = TableChunks.fitted([TextChunk(index: 0, text: text)], in: text) { _ in 800 }
        XCTAssertGreaterThan(viaSheets.count, 1)
        XCTAssertEqual(viaSheets.dropFirst().map(\.repeatedHeaderLength), Array(repeating: header.count + 1, count: viaSheets.count - 1))
    }

    /// Шапка, под которой первой строке не хватило места, переезжает в
    /// следующую часть как есть: в файле она стоит там же, и дописанной её
    /// не считают — иначе `get_file` срезал бы на стыке саму шапку таблицы.
    /// Срезав у каждой части дописанное, получаем текст целиком.
    func testACarriedHeaderIsNotMarkedAsRepeated() {
        let header = "| Поз. | Наименование | Кол-во |\n| --- | --- | --- |"
        // Первая строка таблицы — длинная: шапка, начавшая часть, вместе
        // с ней в эту часть не влезает. Предел — не меньше строки с шапкой:
        // иначе строку делят на продолжения, а их текст в файле не стоит.
        for first in stride(from: 100, through: 300, by: 20) {
            let section = (1...4).map { "Абзац \($0) пояснительной записки к спецификации оборудования." }
                + [header]
                + (1...12).map { number in
                    let words = number == 1 ? (first - 24) / 12 : number % 5 + 1
                    return "| \(number) | Изделие \(String(repeating: "с описанием ", count: words))| \(number) |"
                }
            let text = Array(repeating: section, count: 6).flatMap { $0 }.joined(separator: "\n")
            let original = text.components(separatedBy: "\n")
            let longest = original.map(\.count).max() ?? 0
            let headers = TableChunkHeaders.headers(in: text)
            // Окна, где шапка терялась, — у нижнего края: строка почти во весь
            // предел. Дальше хватает и двухсот.
            for limit in (longest + header.count + 2)...(longest + 200) {
                let pieces = TableChunks.splitWithHeaders(text, limit: limit, headers: headers)
                let rebuilt = pieces.flatMap { String($0.text.dropFirst($0.repeatedHeader)).components(separatedBy: "\n") }
                XCTAssertEqual(rebuilt, original, "строка \(first), предел \(limit): текст не собирается обратно")
                for piece in pieces {
                    let last = piece.text.components(separatedBy: "\n").last ?? ""
                    XCTAssertFalse(TableText.isSeparator(last), "строка \(first), предел \(limit): шапка осталась в конце части без строк")
                }
            }
        }
    }

    // MARK: - Кодировки и переводы строк

    /// Просмотрщик читает текст в cp1251 кириллицей, а не иероглифами UTF-16.
    func testTheViewerReadsWindows1251AsCyrillic() throws {
        let text = "Договор поставки оборудования для объекта"
        XCTAssertEqual(text.count % 2, 1)
        let even = text + "."
        let data = try XCTUnwrap(even.data(using: .windowsCP1251))
        XCTAssertEqual(data.count % 2, 0)
        let url = root.appendingPathComponent("cp1251.txt")
        try data.write(to: url)
        XCTAssertEqual(try TextDocumentLoader.plainText(at: url), even)
    }

    /// Текст из Windows режется по абзацам, как с «\n».
    func testWindowsLineEndingsBecomePlainNewlines() throws {
        let url = root.appendingPathComponent("crlf.txt")
        try Data("Первый абзац.\r\nЕго вторая строка.\r\n\r\nВторой абзац.".utf8).write(to: url)
        XCTAssertEqual(PlainTextExtractor.read(at: url), "Первый абзац.\nЕго вторая строка.\n\nВторой абзац.")
    }

    // MARK: - Обогащение

    /// Модель молчит — после трёх отказов подряд обогатитель больше не зовёт её.
    func testTheEnricherStopsAfterRepeatedSilence() async throws {
        final class Calls: @unchecked Sendable { var count = 0 }
        let calls = Calls()
        struct Silent: Error {}
        let enricher = ContextEnricher(model: "chat") { _, _ in
            calls.count += 1
            throw Silent()
        }
        let chunks = (0..<10).map { TextChunk(index: $0, text: "кусок \($0)") }
        let texts = chunks.map(\.text)
        let result = try await enricher.enriched(chunks: chunks, texts: texts, documentTitle: nil)
        XCTAssertEqual(result, texts)
        XCTAssertEqual(calls.count, ContextEnricher.silenceLimit)
        // Тот же обогатитель — на весь прогон: следующий файл модель не ждёт.
        _ = try await enricher.enriched(chunks: chunks, texts: texts, documentTitle: nil)
        XCTAssertEqual(calls.count, ContextEnricher.silenceLimit)
    }

    /// Один ответ между отказами сбрасывает счёт.
    func testAnAnswerResetsTheSilence() async throws {
        final class Calls: @unchecked Sendable { var count = 0 }
        let calls = Calls()
        struct Silent: Error {}
        let enricher = ContextEnricher(model: "chat") { _, _ in
            calls.count += 1
            if calls.count % 3 == 0 { return "Раздел о поставке." }
            throw Silent()
        }
        let chunks = (0..<9).map { TextChunk(index: $0, text: "кусок \($0)") }
        _ = try await enricher.enriched(chunks: chunks, texts: chunks.map(\.text), documentTitle: nil)
        XCTAssertEqual(calls.count, 9)
    }

    // MARK: - Окно с номерами предложений

    /// Короткие строки: «[N] » и ответ на каждую не выводят запрос за контекст.
    func testNumberedWindowsFitTheContext() {
        let template = ChunkingConfiguration(strategy: .llmBased).effectivePrompt
        XCTAssertTrue(LLMChunker.usesNumbering(template))
        let window = (1...700).map { "Строка \($0) списка" }.joined(separator: "\n")
        let context = 8_192
        let parts = LLMChunker.numberedWindows(window, contextTokens: context, prompt: template)
        XCTAssertGreaterThan(parts.count, 1)
        for part in parts {
            let units = SentenceSplitter.ranges(in: part)
            let prompt = template
                .replacingOccurrences(of: LLMChunker.numberedPlaceholder, with: LLMChunker.numbered(units, in: part))
            let needed = TokenEstimator.estimatedTokens(prompt, charactersPerToken: TokenEstimator.pessimisticCharactersPerToken)
                + LLMChunker.numberedAnswerLimit(units: units.count)
            XCTAssertLessThanOrEqual(needed, context, "часть всё ещё не влезает")
        }
        XCTAssertEqual(parts.joined(separator: "\n"), window, "при делении потерялся текст")
    }

    // MARK: - Просмотр строки таблицы

    /// Без номера строки окно — строки под шапкой, даже если шапка ниже
    /// двадцать четвёртой строки.
    func testATableWindowWithoutARowReadsBelowALowHeader() throws {
        var builder = XLSXFixtureBuilder()
        var rows: [[XLSXFixtureBuilder.Cell]] = (1...29).map { _ in [.absent] }
        rows.append([.shared("Артикул"), .shared("Цена")])
        rows += (1...5).map { [.shared("A-\($0)"), .number(Double($0))] }
        builder.sheets = [.init(name: "Лист", rows: rows)]
        let url = root.appendingPathComponent("low.xlsx")
        try builder.build().write(to: url)
        let window = try TableRowLoader.window(at: url, sheetName: "Лист", row: nil, headerRow: 30)
        XCTAssertEqual(window.header, ["Артикул", "Цена"])
        XCTAssertEqual(window.rows.count, 5)
    }
}
