import XCTest
@testable import ChromaCore

/// Контекстное обогащение чат-моделью.
final class ContextEnricherTests: XCTestCase {
    private func chunk(_ index: Int, _ text: String) -> TextChunk {
        TextChunk(index: index, text: text)
    }

    func testContextGoesIntoTheEmbeddedTextAndNotIntoTheDocument() async throws {
        let enricher = ContextEnricher(model: "chat") { _, _ in
            "Документ описывает порядок отпусков. Фрагмент — про перенос дней."
        }
        let chunks = [chunk(0, "Перенос допускается по заявлению.")]

        let texts = try await enricher.enriched(
            chunks: chunks, texts: chunks.map(\.text), documentTitle: "Регламент"
        )

        XCTAssertTrue(texts[0].hasPrefix("Документ описывает порядок отпусков."), texts[0])
        XCTAssertTrue(texts[0].hasSuffix("Перенос допускается по заявлению."), texts[0])
        // Сам чанк не тронут: в базу пойдёт его собственный текст.
        XCTAssertEqual(chunks[0].text, "Перенос допускается по заявлению.")
    }

    /// «Модель не выбрана» — это и `nil`, и пустая строка: поле обещает откат
    /// к чат-модели источника, и запись, приехавшая переносом настроек или
    /// правкой файла конфигурации, не должна молча выключать обогащение.
    func testAnEmptyEnrichmentModelFallsBackToTheSourceChatModel() {
        var chunking = ChunkingConfiguration(chatModel: "qwen-chat")
        XCTAssertEqual(chunking.resolvedEnrichmentModel, "qwen-chat")

        chunking.enrichmentModel = ""
        XCTAssertEqual(chunking.resolvedEnrichmentModel, "qwen-chat")

        chunking.enrichmentModel = "   "
        XCTAssertEqual(chunking.resolvedEnrichmentModel, "qwen-chat")

        chunking.enrichmentModel = "своя-модель"
        XCTAssertEqual(chunking.resolvedEnrichmentModel, "своя-модель")

        // Нет ни той, ни другой — сказать нечего, и опция молчит.
        XCTAssertNil(ChunkingConfiguration().resolvedEnrichmentModel)
    }

    /// Модель обязана знать, **где** в документе фрагмент: это половина
    /// вопроса, ради которого приём и делается. Раздел приходит из разметки
    /// чанка и попадает в промпт своей строкой.
    func testTheHeadingPathOfEachChunkReachesThePrompt() async throws {
        let prompts = PromptLog()
        let enricher = ContextEnricher(model: "chat") { prompt, _ in
            await prompts.add(prompt)
            return "контекст"
        }
        let chunks = [chunk(0, "первый"), chunk(1, "второй")]

        _ = try await enricher.enriched(
            chunks: chunks, texts: chunks.map(\.text), documentTitle: "Регламент",
            headingPaths: [0: "Отпуска > Перенос", 1: "Отпуска > Отзыв"]
        )

        let all = await prompts.value
        XCTAssertTrue(all[0].contains("Раздел: Отпуска > Перенос"), all[0])
        XCTAssertTrue(all[1].contains("Раздел: Отпуска > Отзыв"), all[1])
    }

    /// Разметки у чанка может не быть — тогда строки раздела в промпте нет
    /// вовсе, а не пустая: пустой заголовок это шум, а не контекст.
    func testAChunkWithoutAHeadingGetsNoSectionLine() async throws {
        let prompts = PromptLog()
        let enricher = ContextEnricher(model: "chat") { prompt, _ in
            await prompts.add(prompt)
            return "контекст"
        }

        _ = try await enricher.enriched(
            chunks: [chunk(0, "первый")], texts: ["первый"], documentTitle: "Регламент"
        )

        let all = await prompts.value
        XCTAssertFalse(all[0].contains("Раздел:"), all[0])
    }

    /// Один вызов на чанк — ровно столько, сколько чанков. Пакетировать
    /// нельзя: смысл приёма в том, что модель видит именно этот фрагмент.
    func testOneCallPerChunk() async throws {
        let counter = CallCounter()
        let enricher = ContextEnricher(model: "chat") { _, _ in
            await counter.bump()
            return "контекст"
        }
        let chunks = (0..<5).map { chunk($0, "текст \($0)") }

        _ = try await enricher.enriched(
            chunks: chunks, texts: chunks.map(\.text), documentTitle: nil
        )
        let calls = await counter.value
        XCTAssertEqual(calls, 5)
    }

    /// Молчание модели по одному чанку не срывает синхронизацию папки: этот
    /// фрагмент идёт в эмбеддинг как был.
    func testAFailedCallLeavesThatChunkAsItWas() async throws {
        let enricher = ContextEnricher(model: "chat") { prompt, _ in
            if prompt.contains("второй") { throw LMStudioError.emptyResponse }
            return "контекст"
        }
        let chunks = [chunk(0, "первый"), chunk(1, "второй"), chunk(2, "третий")]

        let texts = try await enricher.enriched(
            chunks: chunks, texts: chunks.map(\.text), documentTitle: nil
        )

        XCTAssertEqual(texts[1], "второй", "неудача у одного чанка не портит остальные")
        XCTAssertTrue(texts[0].hasPrefix("контекст"))
        XCTAssertTrue(texts[2].hasPrefix("контекст"))
    }

    /// Отмена — это отмена: она обязана дойти наружу, а не превратиться
    /// в «контекст не получен» для каждого оставшегося чанка.
    func testCancellationIsNotSwallowed() async throws {
        let enricher = ContextEnricher(model: "chat") { _, _ in throw CancellationError() }
        do {
            _ = try await enricher.enriched(
                chunks: [chunk(0, "текст")], texts: ["текст"], documentTitle: nil
            )
            XCTFail("отмена должна была выйти наружу")
        } catch is CancellationError {
            // ожидаемо
        }
    }

    func testTheAnswerIsFlattenedTrimmedAndCapped() {
        XCTAssertEqual(ContextEnricher.cleaned("\n «Про отпуска.» \n\n Второе. \n"), "Про отпуска. Второе.")
        XCTAssertNil(ContextEnricher.cleaned("   \n  "))

        let long = String(repeating: "а", count: ContextEnricher.maximumLength + 50)
        let capped = try! XCTUnwrap(ContextEnricher.cleaned(long))
        XCTAssertEqual(capped.count, ContextEnricher.maximumLength + 1, "обрезано плюс многоточие")
        XCTAssertTrue(capped.hasSuffix("…"))
    }

    /// Промпт просит контекст, а не пересказ: пересказанный фрагмент в векторе
    /// — это тот же фрагмент другими словами.
    func testThePromptAsksForContextRatherThanASummary() {
        let prompt = ContextEnricher.prompt(
            documentTitle: "Регламент", headingPath: "Раздел 2", text: "текст"
        )
        XCTAssertTrue(prompt.contains("Не пересказывай"), prompt)
        XCTAssertTrue(prompt.contains("Регламент"))
        XCTAssertTrue(prompt.contains("Раздел 2"))
    }

    // MARK: - Оценка стоимости

    func testTheEstimateCountsOneCallPerChunk() {
        let estimate = ContextEnricher.estimate(chunks: 9_771, secondsPerCall: 0.8, basis: .benchmark)
        XCTAssertEqual(estimate.embeddings, 9_771)
        XCTAssertEqual(estimate.seconds ?? 0, 9_771 * 0.8, accuracy: 0.001)
    }

    /// Без замера скорости время не называется вовсе — угаданных чисел не
    /// показываем (правило 4 приложения 5).
    func testWithoutAMeasurementThereIsNoTime() {
        let estimate = ContextEnricher.estimate(chunks: 100, secondsPerCall: nil)
        XCTAssertNil(estimate.seconds)
        XCTAssertEqual(estimate.basis, .unknown)
    }

    // MARK: - Настройка источника

    /// Опция выключена у нового источника: она стоит часов работы модели,
    /// и включать её должен человек.
    func testEnrichmentIsOffByDefault() {
        XCTAssertFalse(ChunkingConfiguration().contextEnrichment)
    }

    /// Настройка, которой файл не знает, читается как выключенная, а не ломает
    /// разбор всей конфигурации.
    func testAConfigurationWrittenBeforeEnrichmentStillDecodes() throws {
        let json = #"{"strategy":"recursive","chunkSize":512}"#
        let configuration = try JSONDecoder().decode(
            ChunkingConfiguration.self, from: Data(json.utf8)
        )
        XCTAssertFalse(configuration.contextEnrichment)
        XCTAssertEqual(configuration.chunkSize, 512)
    }

    /// Включённое обогащение меняет подпись нарезки — значит следующая
    /// синхронизация перечанкует и переэмбедит источник, а не решит, что
    /// ничего не изменилось.
    func testEnrichmentChangesTheChunkingSignature() {
        var plain = ChunkingConfiguration()
        let before = plain.signature
        plain.contextEnrichment = true
        XCTAssertNotEqual(plain.signature, before)
        XCTAssertTrue(plain.signature.contains("ctx+llm"), plain.signature)
    }
}

private actor CallCounter {
    private(set) var value = 0
    func bump() { value += 1 }
}

/// Промпты по порядку вызовов — чтобы проверять, что в них уехало.
private actor PromptLog {
    private(set) var value: [String] = []
    func add(_ prompt: String) { value.append(prompt) }
}
