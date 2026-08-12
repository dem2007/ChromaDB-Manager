import XCTest
@testable import ChromaCore

// MARK: - Document-based

final class DocumentBasedChunkingTests: XCTestCase {
    private func configuration(
        format: DocumentSourceFormat = .auto,
        headerLevel: Int = 2,
        maxSection: Int = 4096,
        fallback: OversizedSectionFallback = .recursive,
        codeSplitBy: CodeSplitTarget = .both,
        tags: [String] = ["section", "article"]
    ) -> ChunkingConfiguration {
        ChunkingConfiguration(
            strategy: .documentBased,
            sizeUnit: .characters,
            sourceFormat: format,
            splitHeaderLevel: headerLevel,
            splitTags: tags,
            codeSplitBy: codeSplitBy,
            maxSectionSize: maxSection,
            oversizedFallback: fallback
        )
    }

    func testMarkdownSplitsOnTheConfiguredHeadingLevel() {
        let text = """
        # Заголовок документа
        Вступление.

        ## Первый раздел
        Текст первого раздела.

        ### Подраздел
        Он должен остаться со своим разделом.

        ## Второй раздел
        Текст второго.
        """
        let chunks = DocumentBasedChunker(configuration: configuration(format: .markdown), fileExtension: "md")
            .chunks(from: text)

        XCTAssertEqual(chunks.count, 3, "H1 + два H2; H3 не создаёт новую секцию")
        XCTAssertTrue(chunks[1].text.contains("Подраздел"), "подраздел должен остаться внутри своего H2")
    }

    func testMarkdownIgnoresHashesInsideCodeFences() {
        let text = """
        ## Раздел
        ```bash
        # это комментарий, а не заголовок
        ## и это тоже
        ```
        Конец раздела.
        """
        let chunks = DocumentBasedChunker(configuration: configuration(format: .markdown)).chunks(from: text)
        XCTAssertEqual(chunks.count, 1)
    }

    func testHeadingDetectionRequiresASpace() {
        XCTAssertEqual(DocumentBasedChunker.headingLevel(of: "## Заголовок"), 2)
        XCTAssertNil(DocumentBasedChunker.headingLevel(of: "#хештег"))
        XCTAssertNil(DocumentBasedChunker.headingLevel(of: "####### слишком глубоко"))
    }

    func testHTMLSplitsOnOutermostTagsAndKeepsNested() {
        let text = "<p>до</p><section>первая<section>вложенная</section></section><section>вторая</section><p>после</p>"
        let chunks = DocumentBasedChunker(configuration: configuration(format: .html), fileExtension: "html")
            .chunks(from: text)

        XCTAssertEqual(chunks.count, 4, "текст до, два блока section, текст после")
        XCTAssertTrue(chunks[1].text.contains("вложенная"), "вложенный section не должен становиться отдельным чанком")
        XCTAssertTrue(chunks.last?.text.contains("после") ?? false, "текст между блоками — тоже содержимое")
    }

    func testCodeSplitsOnTopLevelDeclarationsOnly() {
        let text = """
        import Foundation

        struct First {
            func method() {}
        }

        func topLevel() {
            print("hi")
        }
        """
        let chunks = DocumentBasedChunker(configuration: configuration(format: .code), fileExtension: "swift")
            .chunks(from: text)

        XCTAssertEqual(chunks.count, 3, "import, struct с методом внутри, функция верхнего уровня")
        XCTAssertTrue(chunks[1].text.contains("func method"), "метод не должен отрываться от своего типа")
    }

    func testCodeSplitByClassesIgnoresFunctions() {
        let text = """
        func alpha() {}
        class Beta {}
        func gamma() {}
        """
        let chunks = DocumentBasedChunker(configuration: configuration(format: .code, codeSplitBy: .classes), fileExtension: "swift")
            .chunks(from: text)
        XCTAssertEqual(chunks.count, 2, "новая секция только на class")
    }

    func testOversizedSectionGoesThroughTheFallback() {
        let long = String(repeating: "слово ", count: 400)
        let text = "## Раздел\n\(long)"

        let keep = DocumentBasedChunker(configuration: configuration(format: .markdown, maxSection: 200, fallback: .keep))
            .chunks(from: text)
        XCTAssertEqual(keep.count, 1, "«не делить» оставляет секцию как есть")

        let split = DocumentBasedChunker(configuration: configuration(format: .markdown, maxSection: 200, fallback: .recursive))
            .chunks(from: text)
        XCTAssertGreaterThan(split.count, 1)
        XCTAssertTrue(split.allSatisfy { $0.text.count <= 220 }, "после откатной стратегии секции должны уложиться в лимит")
    }

    func testFormatIsResolvedByExtension() {
        XCTAssertEqual(DocumentSourceFormat.resolved(.auto, fileExtension: "html"), .html)
        XCTAssertEqual(DocumentSourceFormat.resolved(.auto, fileExtension: "swift"), .code)
        XCTAssertEqual(DocumentSourceFormat.resolved(.auto, fileExtension: "md"), .markdown)
        XCTAssertEqual(DocumentSourceFormat.resolved(.auto, fileExtension: nil), .markdown)
        XCTAssertEqual(DocumentSourceFormat.resolved(.html, fileExtension: "md"), .html, "явный выбор важнее расширения")
    }
}

// MARK: - Hierarchical

final class HierarchicalChunkingTests: XCTestCase {
    private func text(_ paragraphs: Int) -> String {
        (0..<paragraphs)
            .map { "Абзац номер \($0). " + String(repeating: "содержательный текст. ", count: 12) }
            .joined(separator: "\n\n")
    }

    private var configuration: ChunkingConfiguration {
        ChunkingConfiguration(
            strategy: .hierarchical,
            sizeUnit: .characters,
            levels: 2,
            parentChunkSize: 900,
            childChunkSize: 300
        )
    }

    func testProducesParentsWithChildrenPointingAtThem() {
        let chunks = HierarchicalChunker(configuration: configuration).chunks(from: text(8))

        let parents = chunks.filter { $0.level == 1 }
        let children = chunks.filter { $0.level == 0 }
        XCTAssertGreaterThan(parents.count, 0)
        XCTAssertGreaterThan(children.count, parents.count, "дочерних чанков должно быть больше, чем родительских")

        for child in children {
            guard let parentIndex = child.parentIndex else { return XCTFail("у ребёнка должен быть родитель") }
            XCTAssertEqual(chunks[parentIndex].level, 1, "parentIndex должен указывать на родительский чанк")
            XCTAssertTrue(chunks[parentIndex].text.contains(child.text.prefix(20)), "ребёнок должен быть частью своего родителя")
        }
    }

    func testIndexesAreUniqueSoDocumentIDsDoNotCollide() {
        let chunks = HierarchicalChunker(configuration: configuration).chunks(from: text(6))
        XCTAssertEqual(Set(chunks.map(\.index)).count, chunks.count)

        let ids = chunks.map { SourceSyncService.documentID(relativePath: "a.md", chunkIndex: $0.index) }
        XCTAssertEqual(Set(ids).count, ids.count, "родители и дети живут в одной коллекции — ID обязаны не совпадать")
    }

    func testSingleLevelProducesOnlyParents() {
        var single = configuration
        single.levels = 1
        let chunks = HierarchicalChunker(configuration: single).chunks(from: text(6))
        XCTAssertTrue(chunks.allSatisfy { $0.level == 1 && $0.parentIndex == nil })
    }

    func testChildBiggerThanParentIsRejectedBeforeARun() {
        var broken = configuration
        broken.childChunkSize = 4096
        XCTAssertNotNil(broken.problem)
    }
}

// MARK: - Adaptive

final class AdaptiveChunkingTests: XCTestCase {
    func testDenseTextIsScoredHigherThanProse() {
        let prose = "Это спокойный текст без чисел, который просто рассказывает историю неспешными длинными предложениями."
        let dense = "1.2; 3.4; 5.6; 7.8; 9.0; 11,2; 13,4; 15,6; 17,8; 19,0; 21,2; 23,4."
        XCTAssertGreaterThan(AdaptiveChunker.density(of: dense), AdaptiveChunker.density(of: prose))
    }

    func testTargetSizeMovesTowardsMinForDenseText() {
        let configuration = ChunkingConfiguration(
            strategy: .adaptive,
            sizeUnit: .characters,
            minChunkSize: 100,
            maxChunkSize: 1000,
            baseChunkSize: 500,
            sensitivity: 1
        )
        let chunker = AdaptiveChunker(configuration: configuration)
        let dense = chunker.targetSize(for: "1.2; 3.4; 5.6; 7.8; 9.0; 11,2; 13,4; 15,6; 17,8.")
        let sparse = chunker.targetSize(for: String(repeating: "спокойное повествование без всяких цифр и знаков ", count: 6))

        XCTAssertLessThan(dense, 500)
        XCTAssertGreaterThan(sparse, 500)
        XCTAssertGreaterThanOrEqual(dense, 100)
        XCTAssertLessThanOrEqual(sparse, 1000)
    }

    func testZeroSensitivityKeepsTheBaseSize() {
        var configuration = ChunkingConfiguration(strategy: .adaptive, sizeUnit: .characters, baseChunkSize: 400, sensitivity: 0)
        configuration.minChunkSize = 100
        configuration.maxChunkSize = 900
        let chunker = AdaptiveChunker(configuration: configuration)
        XCTAssertEqual(chunker.targetSize(for: "1,2,3,4,5"), 400)
        XCTAssertEqual(chunker.targetSize(for: "обычный текст"), 400)
    }

    func testProducesNonEmptyChunksWithSequentialIndexes() {
        let configuration = ChunkingConfiguration(strategy: .adaptive, sizeUnit: .characters, minChunkSize: 80, maxChunkSize: 600, baseChunkSize: 200)
        let text = (0..<5).map { "Блок \($0). " + String(repeating: "текст ", count: 30) }.joined(separator: "\n\n")
        let chunks = AdaptiveChunker(configuration: configuration).chunks(from: text)

        XCTAssertFalse(chunks.isEmpty)
        XCTAssertEqual(chunks.map(\.index), Array(0..<chunks.count))
        XCTAssertTrue(chunks.allSatisfy { !$0.text.isEmpty })
    }
}

// MARK: - Semantic

/// Vectors from a fixed table: the chunker's job is to find the jump in meaning,
/// and a real model would make the test about the model instead.
private struct ScriptedEmbeddings: EmbeddingProvider {
    /// Sentence prefix → vector.
    let table: [String: [Double]]
    let fallback: [Double]

    func embed(texts: [String], model: String) async throws -> [[Double]] {
        texts.map { text in
            for (key, vector) in table where text.contains(key) { return vector }
            return fallback
        }
    }
}

final class SemanticChunkingTests: XCTestCase {
    private var configuration: ChunkingConfiguration {
        ChunkingConfiguration(
            strategy: .semantic,
            sizeUnit: .characters,
            thresholdMode: .absolute,
            thresholdValue: 0.5,
            sentenceBuffer: 1,
            minChunkSize: 32,
            maxChunkSize: 4096
        )
    }

    func testBreaksWhereMeaningJumps() async throws {
        // Three sentences about cats, then three about finance.
        let text = "Кошка спит на окне. Кошка ест корм. Кошка любит спать. Счёт оплачен вчера. Счёт закрыт банком. Счёт сдан в архив."
        let embeddings = ScriptedEmbeddings(
            table: ["Кошка": [1, 0], "Счёт": [0, 1]],
            fallback: [0.5, 0.5]
        )

        let chunks = try await SemanticChunker(configuration: configuration, embeddings: embeddings, model: "m")
            .chunks(from: text)

        XCTAssertEqual(chunks.count, 2, "разрыв должен быть один — на смене темы")
        XCTAssertTrue(chunks[0].text.contains("Кошка"))
        XCTAssertFalse(chunks[0].text.contains("Счёт"))
        XCTAssertTrue(chunks[1].text.contains("Счёт"))
    }

    func testUniformTextStaysWhole() async throws {
        let text = "Первое предложение. Второе предложение. Третье предложение. Четвёртое предложение."
        let embeddings = ScriptedEmbeddings(table: [:], fallback: [1, 0])
        let chunks = try await SemanticChunker(configuration: configuration, embeddings: embeddings, model: "m")
            .chunks(from: text)
        XCTAssertEqual(chunks.count, 1, "без смены смысла резать нечего")
    }

    func testMaximumSizeWinsOverSemantics() async throws {
        var bounded = configuration
        bounded.maxChunkSize = 60
        let text = String(repeating: "Одинаковое предложение о том же самом. ", count: 8)
        let embeddings = ScriptedEmbeddings(table: [:], fallback: [1, 0])

        let chunks = try await SemanticChunker(configuration: bounded, embeddings: embeddings, model: "m")
            .chunks(from: text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= 100 }, "потолок размера — жёсткий")
    }

    func testShortTextNeedsNoModelCalls() async throws {
        struct FailingProvider: EmbeddingProvider {
            func embed(texts: [String], model: String) async throws -> [[Double]] {
                XCTFail("для одного предложения вызывать модель не нужно")
                return []
            }
        }
        let chunks = try await SemanticChunker(configuration: configuration, embeddings: FailingProvider(), model: "m")
            .chunks(from: "Одно короткое предложение.")
        XCTAssertEqual(chunks.count, 1)
    }

    func testSentenceSplitter() {
        let sentences = SentenceSplitter.sentences(in: "Первое. Второе! Третье?\nЧетвёртое без точки")
        XCTAssertEqual(sentences.count, 4)
        XCTAssertEqual(sentences.last, "Четвёртое без точки")
    }

    func testCosineAndPercentile() {
        XCTAssertEqual(VectorMath.cosineSimilarity([1, 0], [1, 0]), 1, accuracy: 0.0001)
        XCTAssertEqual(VectorMath.cosineSimilarity([1, 0], [0, 1]), 0, accuracy: 0.0001)
        XCTAssertEqual(VectorMath.cosineDistance([1, 0], [0, 1]), 1, accuracy: 0.0001)
        XCTAssertEqual(VectorMath.cosineSimilarity([1, 0], []), 0, "разные размерности — не сравниваем")

        XCTAssertEqual(VectorMath.percentile([0.1, 0.2, 0.3, 0.9], 100), 0.9)
        XCTAssertEqual(VectorMath.percentile([0.1, 0.2, 0.3, 0.9], 0), 0.1)
        XCTAssertEqual(VectorMath.percentile([], 95), 0)
    }
}

// MARK: - LLM-based

private struct ScriptedChat: ChatProvider {
    let answers: [String]
    /// `nil` — модель не сказала, сколько у неё контекста: тогда бюджет окна
    /// не считается.
    var contextTokens: Int?
    /// Измеренная скорость письма, токенов в секунду. `nil` — не мерили;
    /// тогда время в расчёт окна не идёт.
    var tokensPerSecond: Double?
    let counter = Counter()

    func loadedContextLength(of model: String) async -> Int? { contextTokens }
    func generationSpeed(of model: String) async -> Double? { tokensPerSecond }

    /// Промпты целиком — чтобы проверять не только результат, но и то, что
    /// уходило в модель.
    let prompts = Prompts()

    final class Prompts: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String] = []
        func record(_ prompt: String) {
            lock.lock(); defer { lock.unlock() }
            value.append(prompt)
        }
        var all: [String] {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value - 1
        }
        var calls: Int {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    /// Records what the chunker asked for, so the tests can assert on the
    /// request as well as on the parsed result (part G).
    let seen = Seen()

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var settings: [ChatGenerationSettings] = []
        private var schemas: [String?] = []
        func record(_ s: ChatGenerationSettings, _ schema: ChatJSONSchema?) {
            lock.lock(); defer { lock.unlock() }
            settings.append(s); schemas.append(schema?.name)
        }
        var lastSettings: ChatGenerationSettings? {
            lock.lock(); defer { lock.unlock() }
            return settings.last
        }
        var lastSchemaName: String?? {
            lock.lock(); defer { lock.unlock() }
            return schemas.last
        }
    }

    func complete(
        prompt: String,
        model: String,
        settings: ChatGenerationSettings,
        schema: ChatJSONSchema?,
        timeout: TimeInterval?
    ) async throws -> String {
        seen.record(settings, schema)
        prompts.record(prompt)
        let index = counter.next()
        return answers[min(index, answers.count - 1)]
    }
}

/// Модель, которая не отвечает: вызов бросает ошибку, как таймаут LM Studio.
///
/// Первому вызову можно подсунуть ответ — так проверяется граница между
/// «не ответила ни разу» и «ответила, но разобрать не вышло».
private struct SilentChat: ChatProvider {
    struct NoAnswer: LocalizedError {
        var errorDescription: String? { "LM Studio не ответила за 120 с" }
    }

    var answeringFirst: String?
    let counter = ScriptedChat.Counter()

    func loadedContextLength(of model: String) async -> Int? { nil }

    func complete(
        prompt: String,
        model: String,
        settings: ChatGenerationSettings,
        schema: ChatJSONSchema?,
        timeout: TimeInterval?
    ) async throws -> String {
        let index = counter.next()
        if index == 0, let answeringFirst { return answeringFirst }
        throw NoAnswer()
    }
}

final class LLMChunkingTests: XCTestCase {
    private var configuration: ChunkingConfiguration {
        ChunkingConfiguration(
            strategy: .llmBased,
            sizeUnit: .characters,
            maxChunkSize: 4096,
            chatModel: "chat-model",
            llmMaxRetries: 1
        )
    }

    func testParsesAJSONArrayOutOfAChattyAnswer() {
        let answer = """
        Конечно! Вот фрагменты:
        ```json
        ["первый фрагмент", "второй фрагмент"]
        ```
        Надеюсь, это помогло.
        """
        XCTAssertEqual(LLMChunker.parse(answer), ["первый фрагмент", "второй фрагмент"])
    }

    func testParsingRejectsGarbage() {
        XCTAssertNil(LLMChunker.parse("я не понял задание"))
        XCTAssertNil(LLMChunker.parse("[]"))
        XCTAssertNil(LLMChunker.parse("[1, 2, 3]"), "числа — не фрагменты текста")
    }

    func testUsesTheModelsBoundaries() async throws {
        let chat = ScriptedChat(answers: ["[\"часть про кошек\", \"часть про счета\"]"])
        let chunks = try await LLMChunker(configuration: configuration, chat: chat)
            .chunks(from: "Кошка спит. Счёт оплачен.")

        XCTAssertEqual(chunks.map(\.text), ["часть про кошек", "часть про счета"])
        XCTAssertTrue(chunks.allSatisfy { $0.note == nil })
    }

    func testRetriesThenFallsBackToRecursiveWithAMark() async throws {
        var withFallback = configuration
        withFallback.onMalformedOutput = .fallbackToRecursive
        let chat = ScriptedChat(answers: ["ерунда", "тоже ерунда", "и ещё"])

        let chunks = try await LLMChunker(configuration: withFallback, chat: chat)
            .chunks(from: "Первый абзац текста.\n\nВторой абзац текста.")

        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(chunks.allSatisfy { $0.note != nil }, "откат обязан быть помечен")
        XCTAssertEqual(chat.counter.calls, 2, "одна попытка плюс один повтор")
    }

    // MARK: - Молчащая модель

    /// «Откатиться на Recursive» отвечает на вопрос «что делать, если ответ не
    /// разобрать». Молчание — не ответ не по формату, а недоступная модель.
    ///
    /// Разница стоила четырнадцати часов: на живой машине модель не ответила
    /// ни разу за день — 279 таймаутов, 94 отката, — а прогон всё это время
    /// шёл дальше и наполнял коллекцию «LLM» границами Recursive.
    func testASilentModelStopsTheRunEvenWhenFallbackIsChosen() async {
        var withFallback = configuration
        withFallback.onMalformedOutput = .fallbackToRecursive
        let chat = SilentChat()

        do {
            _ = try await LLMChunker(configuration: withFallback, chat: chat)
                .chunks(from: "Первый абзац текста.\n\nВторой абзац текста.")
            XCTFail("молчащая модель обязана останавливать прогон, а не подменять нарезку")
        } catch let error as LLMChunkingError {
            guard case .noAnswer(let model, let attempts, let reason) = error else {
                return XCTFail("ожидалась noAnswer, получено \(error)")
            }
            XCTAssertEqual(model, "chat-model", "имя модели — первое, что спросят")
            XCTAssertEqual(attempts, 2, "одна попытка плюс один повтор")
            XCTAssertTrue(reason.contains("не ответила"), reason)
        } catch {
            XCTFail("неожиданная ошибка: \(error)")
        }
    }

    /// И останавливает сразу, а не после каждого окна каждого файла.
    func testASilentModelIsAskedOnlyTheAllowedNumberOfTimes() async {
        var withFallback = configuration
        withFallback.onMalformedOutput = .fallbackToRecursive
        let chat = SilentChat()

        _ = try? await LLMChunker(configuration: withFallback, chat: chat)
            .chunks(from: String(repeating: "Абзац текста.\n\n", count: 500))

        XCTAssertEqual(chat.counter.calls, 2, "окон много, но спрашивать нечего — модель молчит")
    }

    /// Граница: модель, которая ответила хоть как-то, — живая, и её случай
    /// по-прежнему решает настройка про формат.
    func testAModelThatAnsweredBadlyOnceStillFallsBack() async throws {
        var withFallback = configuration
        withFallback.onMalformedOutput = .fallbackToRecursive
        // Первый вызов — ерунда в ответе, второй — молчание.
        let chat = SilentChat(answeringFirst: "совсем не список")

        let chunks = try await LLMChunker(configuration: withFallback, chat: chat)
            .chunks(from: "Первый абзац текста.\n\nВторой абзац текста.")

        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(chunks.allSatisfy { $0.note == LLMChunker.recursiveFallbackNote })
    }

    /// Отметка на чанках — одна строка на всех: по ней прогон узнаёт, что
    /// нарезка подменилась, и называет файл в сводке. Разойдутся — сводка
    /// молча перестанет о подмене говорить.
    func testTheFallbackMarkIsTheSharedConstant() async throws {
        var withFallback = configuration
        withFallback.onMalformedOutput = .fallbackToRecursive
        let chat = ScriptedChat(answers: ["ерунда", "тоже ерунда"])

        let chunks = try await LLMChunker(configuration: withFallback, chat: chat)
            .chunks(from: "Первый абзац текста.\n\nВторой абзац.")

        XCTAssertEqual(chunks.first?.note, LLMChunker.recursiveFallbackNote)
    }

    func testRetriesThenFailsWhenThatIsThePolicy() async {
        var strict = configuration
        strict.onMalformedOutput = .retryThenFail
        let chat = ScriptedChat(answers: ["ерунда"])

        do {
            _ = try await LLMChunker(configuration: strict, chat: chat).chunks(from: "Текст.")
            XCTFail("политика «сообщить об ошибке» должна бросить ошибку")
        } catch let error as LLMChunkingError {
            guard case .malformedOutput = error else { return XCTFail("ожидалась malformedOutput") }
        } catch {
            XCTFail("неожиданная ошибка: \(error)")
        }
    }

    func testOversizedPieceFromTheModelIsCutDown() async throws {
        var bounded = configuration
        bounded.maxChunkSize = 64
        let long = String(repeating: "очень длинный фрагмент. ", count: 20)
        let chat = ScriptedChat(answers: ["[\"\(long)\"]"])

        let chunks = try await LLMChunker(configuration: bounded, chat: chat).chunks(from: long)
        XCTAssertGreaterThan(chunks.count, 1, "модель проигнорировала лимит — режем сами")
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= 100 })
    }

    func testMissingChatModelIsRefusedBeforeAnyCall() async {
        var withoutModel = configuration
        withoutModel.chatModel = nil
        XCTAssertNotNil(withoutModel.problem)

        do {
            _ = try await LLMChunker(configuration: withoutModel, chat: ScriptedChat(answers: ["[]"]))
                .chunks(from: "Текст.")
            XCTFail("без модели чанкинг невозможен")
        } catch let error as LLMChunkingError {
            guard case .noChatModel = error else { return XCTFail("ожидалась noChatModel") }
        } catch {
            XCTFail("неожиданная ошибка: \(error)")
        }
    }
}

// MARK: - Signature and pipeline

final class AdvancedSignatureTests: XCTestCase {
    func testEachStrategyOnlySignsItsOwnParameters() {
        var documentBased = ChunkingConfiguration(strategy: .documentBased)
        let original = documentBased.signature
        // A hierarchical parameter must not disturb a Document-based recipe:
        // otherwise touching an unrelated slider would re-chunk the folder.
        documentBased.parentChunkSize = 9999
        XCTAssertEqual(documentBased.signature, original)

        documentBased.splitHeaderLevel = 3
        XCTAssertNotEqual(documentBased.signature, original)
    }

    func testHierarchicalSignatureFollowsBothSizes() {
        var configuration = ChunkingConfiguration(strategy: .hierarchical)
        let original = configuration.signature
        configuration.childChunkSize = 256
        XCTAssertNotEqual(configuration.signature, original)
    }

    func testSemanticSignatureFollowsThresholdAndModel() {
        var configuration = ChunkingConfiguration(strategy: .semantic)
        let original = configuration.signature
        configuration.thresholdValue = 80
        XCTAssertNotEqual(configuration.signature, original)

        var withModel = ChunkingConfiguration(strategy: .semantic)
        withModel.sentenceEmbeddingModel = "other-model"
        XCTAssertNotEqual(withModel.signature, original)
    }

    func testLLMSignatureFollowsThePrompt() {
        var configuration = ChunkingConfiguration(strategy: .llmBased, chatModel: "m")
        let original = configuration.signature
        configuration.promptTemplate = "совершенно другой запрос {{TEXT}}"
        XCTAssertNotEqual(configuration.signature, original, "изменённый шаблон — это другая нарезка")
    }

    func testEditedPromptFallsBackToTheModeDefault() {
        var configuration = ChunkingConfiguration(strategy: .llmBased, granularity: .atomic)
        XCTAssertEqual(configuration.effectivePrompt, LLMGranularity.atomic.defaultPrompt)
        configuration.promptTemplate = "   "
        XCTAssertEqual(configuration.effectivePrompt, LLMGranularity.atomic.defaultPrompt, "пробелы — это пустой шаблон")
    }

    func testPipelineRoutesSyncStrategiesWithoutAModel() async throws {
        let text = "## Раздел один\nтекст\n\n## Раздел два\nтекст"
        let pipeline = ChunkingPipeline(configuration: ChunkingConfiguration(strategy: .documentBased, sizeUnit: .characters))
        let chunks = try await pipeline.chunks(from: text, fileExtension: "md")
        XCTAssertEqual(chunks.count, 2)
    }

    func testPipelineRefusesSemanticWithoutAnEmbeddingModel() async {
        let pipeline = ChunkingPipeline(configuration: ChunkingConfiguration(strategy: .semantic))
        do {
            _ = try await pipeline.chunks(from: "Первое. Второе. Третье.")
            XCTFail("ожидалась ошибка")
        } catch let error as SemanticChunkingError {
            guard case .noEmbeddingModel = error else { return XCTFail("ожидалась noEmbeddingModel") }
        } catch {
            XCTFail("неожиданная ошибка: \(error)")
        }
    }

    func testConfigurationDecodesWithoutTheNewKeys() throws {
        // A source saved by the 2C build: none of the 2D keys exist yet, and its
        // chunk size must survive the upgrade untouched.
        let json = #"{"strategy":"fixed","chunkSize":333,"sizeUnit":"characters","overlapPercent":20,"separators":["\n"]}"#
        let configuration = try JSONDecoder().decode(ChunkingConfiguration.self, from: Data(json.utf8))

        XCTAssertEqual(configuration.chunkSize, 333)
        XCTAssertEqual(configuration.strategy, .fixed)
        XCTAssertEqual(configuration.parentChunkSize, 2048, "новые поля берут значения по умолчанию")
        XCTAssertEqual(configuration.granularity, .topical)
    }
}

// MARK: - Triggers

final class SyncTriggerTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return calendar
    }

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    func testIntervalCountsFromTheLastRun() {
        let schedule = SyncSchedule(kind: .interval, intervalMinutes: 30)
        let now = date("2026-07-30 12:00")
        let next = schedule.nextFireDate(after: now, lastRun: date("2026-07-30 11:45"), calendar: calendar)
        XCTAssertEqual(next, date("2026-07-30 12:15"))
    }

    func testOverdueIntervalFiresPromptlyWithoutCatchingUp() {
        let schedule = SyncSchedule(kind: .interval, intervalMinutes: 30)
        let now = date("2026-07-30 12:00")
        // The app was closed for hours: one run now, not one per missed slot.
        guard let next = schedule.nextFireDate(after: now, lastRun: date("2026-07-30 06:00"), calendar: calendar) else {
            return XCTFail("расписание должно дать дату")
        }
        XCTAssertGreaterThan(next, now)
        XCTAssertLessThan(next.timeIntervalSince(now), 60)
    }

    func testIntervalWithoutHistoryStartsFromNow() {
        let schedule = SyncSchedule(kind: .interval, intervalMinutes: 45)
        let now = date("2026-07-30 12:00")
        XCTAssertEqual(schedule.nextFireDate(after: now, lastRun: nil, calendar: calendar), date("2026-07-30 12:45"))
    }

    func testDailyPicksTodayWhenTheTimeHasNotPassed() {
        let schedule = SyncSchedule(kind: .dailyAt, hour: 18, minute: 30)
        let next = schedule.nextFireDate(after: date("2026-07-30 09:00"), lastRun: nil, calendar: calendar)
        XCTAssertEqual(next, date("2026-07-30 18:30"))
    }

    func testDailyRollsToTomorrowAfterTheTime() {
        let schedule = SyncSchedule(kind: .dailyAt, hour: 9, minute: 0)
        let next = schedule.nextFireDate(after: date("2026-07-30 10:00"), lastRun: nil, calendar: calendar)
        XCTAssertEqual(next, date("2026-07-31 09:00"))
    }

    func testDailyDoesNotRepeatAfterAlreadyRunningToday() {
        let schedule = SyncSchedule(kind: .dailyAt, hour: 18, minute: 0)
        let next = schedule.nextFireDate(
            after: date("2026-07-30 19:00"),
            lastRun: date("2026-07-30 18:01"),
            calendar: calendar
        )
        XCTAssertEqual(next, date("2026-07-31 18:00"))
    }

    func testSummaryReadsLikeASentence() {
        XCTAssertEqual(SyncSchedule(kind: .interval, intervalMinutes: 120).summary, "каждые 2 ч")
        XCTAssertEqual(SyncSchedule(kind: .interval, intervalMinutes: 45).summary, "каждые 45 мин")
        XCTAssertEqual(SyncSchedule(kind: .dailyAt, hour: 7, minute: 5).summary, "ежедневно в 07:05")

        var triggers = SyncTriggers()
        XCTAssertEqual(triggers.summary, "только вручную")
        XCTAssertFalse(triggers.isAnyEnabled)
        triggers.onLaunch = true
        triggers.onFileChanges = true
        XCTAssertTrue(triggers.summary.contains("при старте"))
        XCTAssertTrue(triggers.summary.contains("пауза 5 с"))
    }

    func testTriggersDecodeFromAConfigWithoutThem() throws {
        let json = #"{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","name":"docs","path":"/tmp/docs","collectionName":"docs_col"}"#
        let source = try JSONDecoder().decode(DataSource.self, from: Data(json.utf8))
        XCTAssertFalse(source.triggers.isAnyEnabled, "источник из старого конфига остаётся полностью ручным")
        XCTAssertEqual(source.triggers.debounceSeconds, 5)
    }
}

final class FolderWatcherDebounceTests: XCTestCase {
    func testBurstOfEventsCausesOneRun() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        let expectation = expectation(description: "one run")
        let counter = LLMChunkingTests.Counter()

        let watcher = FolderWatcher(url: root, debounce: 1) {
            counter.increment()
            expectation.fulfill()
        }
        // Simulates copying a folder: many events in a row.
        for _ in 0..<50 { watcher.eventArrived() }

        wait(for: [expectation], timeout: 4)
        // Give any stray timer a chance to fire before counting.
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(counter.value, 1, "лавина событий должна дать одну синхронизацию")
        watcher.stop()
    }

    func testStopCancelsAPendingRun() {
        let watcher = FolderWatcher(url: URL(fileURLWithPath: NSTemporaryDirectory()), debounce: 1) {
            XCTFail("после stop() обработчик вызываться не должен")
        }
        watcher.eventArrived()
        watcher.stop()
        Thread.sleep(forTimeInterval: 1.5)
    }
}

extension LLMChunkingTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0
        func increment() {
            lock.lock(); storage += 1; lock.unlock()
        }
        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }
}

/// 5 + — окно чанкинга против контекста модели.
final class LLMChunkingWindowTests: XCTestCase {
    /// Настройки по умолчанию: 2048 токенов на чанк. Окно считалось как
    /// «размер чанка × 4» — 28 672 символа, около 8192 токенов **одного
    /// промпта**, то есть весь контекст обычной загруженной модели, и это ещё
    /// без ответа. Чанкинг с такими настройками падал всегда.
    func testTheDefaultSizedWindowNoLongerFillsTheWholeContext() {
        let configuration = ChunkingConfiguration(
            strategy: .llmBased, sizeUnit: .tokens, maxChunkSize: 2_048, chatModel: "м"
        )
        let wanted = max(configuration.maxSizeInCharacters * 4, 2_000)
        XCTAssertGreaterThan(TokenEstimator.estimatedTokens(String(repeating: "я", count: wanted)), 8_000)

        let allowed = LLMChunker.windowLimit(contextTokens: 8_192, prompt: configuration.effectivePrompt)
        XCTAssertLessThan(allowed, wanted)
        let prompt = configuration.effectivePrompt.replacingOccurrences(
            of: "{{TEXT}}", with: String(repeating: "я", count: allowed)
        )
        // Промпт **и ответ** обязаны помещаться: модель переписывает текст,
        // а не оценивает его.
        let total = Double(TokenEstimator.estimatedTokens(prompt))
            + Double(TokenEstimator.estimatedTokens(String(repeating: "я", count: allowed)))
            * LLMChunker.answerToWindowRatio
        XCTAssertLessThanOrEqual(total, 8_192)
    }

    func testABiggerContextAllowsABiggerWindow() {
        let prompt = ChunkingConfiguration(strategy: .llmBased).effectivePrompt
        XCTAssertGreaterThan(
            LLMChunker.windowLimit(contextTokens: 32_768, prompt: prompt),
            LLMChunker.windowLimit(contextTokens: 8_192, prompt: prompt)
        )
    }

    /// Модель не сказала про контекст — ничего не выдумываем и не режем.
    func testWithoutAKnownContextTheWindowIsTheOneTheSettingsAskFor() async throws {
        let chat = ScriptedChat(answers: [#"{"chunks":["а","б"]}"#], contextTokens: nil)
        let configuration = ChunkingConfiguration(
            strategy: .llmBased, sizeUnit: .characters, maxChunkSize: 4_096, chatModel: "м"
        )
        _ = try await LLMChunker(configuration: configuration, chat: chat)
            .chunks(from: String(repeating: "текст ", count: 2_000))
        // 12 000 символов при окне 16 384 — один вызов.
        XCTAssertEqual(chat.counter.calls, 1)
    }

    /// Тот же текст на модели с маленьким контекстом делится на больше окон —
    /// и ни один промпт не выходит за него.
    func testASmallContextMeansMoreWindowsAndNoOversizedPrompt() async throws {
        let chat = ScriptedChat(answers: [#"{"chunks":["а","б"]}"#], contextTokens: 4_096)
        let configuration = ChunkingConfiguration(
            strategy: .llmBased, sizeUnit: .characters, maxChunkSize: 4_096, chatModel: "м"
        )
        _ = try await LLMChunker(configuration: configuration, chat: chat)
            .chunks(from: String(repeating: "текст ", count: 2_000))
        XCTAssertGreaterThan(chat.counter.calls, 1, "окно обязано было уменьшиться")
        for prompt in chat.prompts.all {
            XCTAssertLessThanOrEqual(
                TokenEstimator.estimatedTokens(prompt), 4_096,
                "ни один промпт не должен превышать контекст модели"
            )
        }
    }

    /// Контекста не хватает даже на минимальное окно — это надо сказать,
    /// а не отправлять запрос и получать 400.
    func testAContextTooSmallIsRefusedBeforeTheRequest() async {
        let chat = ScriptedChat(answers: [#"{"chunks":["а"]}"#], contextTokens: 512)
        let configuration = ChunkingConfiguration(
            strategy: .llmBased, sizeUnit: .characters, maxChunkSize: 4_096, chatModel: "м"
        )
        do {
            _ = try await LLMChunker(configuration: configuration, chat: chat)
                .chunks(from: String(repeating: "текст ", count: 2_000))
            XCTFail("ожидалась ошибка о нехватке контекста")
        } catch let error as LLMChunkingError {
            guard case .contextTooSmall = error else {
                return XCTFail("ожидалась contextTooSmall, получено \(error)")
            }
            XCTAssertEqual(chat.counter.calls, 0, "запрос не должен был уйти вовсе")
            XCTAssertNotNil(error.recoverySuggestion)
        } catch {
            XCTFail("неожиданная ошибка \(error)")
        }
    }
}

/// Модель, которая пишет и не может остановиться: вызов упирается в предел
/// длины ответа.
private struct LoopingChat: ChatProvider {
    let counter = ScriptedChat.Counter()

    func complete(
        prompt: String, model: String, settings: ChatGenerationSettings,
        schema: ChatJSONSchema?, timeout: TimeInterval?
    ) async throws -> String {
        _ = counter.next()
        throw LMStudioError.truncatedByTokenLimit(model: model)
    }
}

///, — зацикленный ответ и время как второй предел окна.
///
/// Оба дефекта нашлись на одном прогоне: за четырнадцать часов ни одного
/// дочитанного файла, 279 таймаутов. Числа в тестах — оттуда же, с той самой
/// машины: окно 6284 символа (2237 токенов промпта) и 9102 токена ответа
/// на него, скорость письма 72 ток/с, таймаут 120 с.
final class LLMRunawayAnswerTests: XCTestCase {
    private var configuration: ChunkingConfiguration {
        ChunkingConfiguration(
            strategy: .llmBased, sizeUnit: .characters, maxChunkSize: 4_096,
            chatModel: "м", llmMaxRetries: 1
        )
    }

    // MARK: - Предел длины ответа

    /// Запрос без `max_tokens` — это запрос, который нечем остановить.
    func testEveryRequestCarriesATokenLimit() async throws {
        let chat = ScriptedChat(answers: [#"{"chunks":["а","б"]}"#])
        _ = try await LLMChunker(configuration: configuration, chat: chat)
            .chunks(from: String(repeating: "текст ", count: 500))
        XCTAssertNotNil(chat.seen.lastSettings?.maxTokens, "G3: предел задаёт приложение")
    }

    /// Предел просторнее честного ответа и у́же круга.
    ///
    /// Обе границы важны. Слишком тесный предел рубил бы работу модели и
    /// выдавал бы обрезанный JSON за её ошибку; слишком просторный не ловил
    /// бы ничего — ровно то, что и было, когда предела не было вовсе.
    func testTheLimitPassesAnHonestAnswerAndCutsALoop() {
        let window = String(repeating: "я", count: 6_284)
        let limit = LLMChunker.answerLimit(forWindow: window)
        XCTAssertGreaterThan(limit, 2_192, "честный ответ на это окно — 2192 токена, он обязан пройти")
        XCTAssertLessThan(limit, 9_102, "круг на этом же окне — 9102 токена, он обязан упереться")
    }

    /// Совсем короткому окну предел не мешает: там накладные расходы формата
    /// сравнимы с самим текстом.
    func testATinyWindowKeepsAWorkableFloor() {
        XCTAssertEqual(LLMChunker.answerLimit(forWindow: "три слова тут"), LLMChunker.minimumAnswerLimit)
    }

    /// Заданный человеком предел приложение не трогает: G5 — то, что вписано
    /// в настройках, уходит как вписано.
    func testAManualLimitIsLeftAlone() async throws {
        var manual = configuration
        manual.generation.maxTokens = 777
        let chat = ScriptedChat(answers: [#"{"chunks":["а"]}"#])
        _ = try await LLMChunker(configuration: manual, chat: chat)
            .chunks(from: String(repeating: "текст ", count: 500))
        XCTAssertEqual(chat.seen.lastSettings?.maxTokens, 777)
    }

    /// Оборванный по пределу ответ — это ответ, а не молчание.
    ///
    /// Разница не словесная: молчание останавливает прогон, а ответ
    /// не по формату разбирает настройка источника. Спутать их значит либо
    /// встать там, где надо было откатиться, либо наполнять коллекцию
    /// границами Recursive там, где надо было встать.
    func testALoopingAnswerIsMalformedNotSilence() async throws {
        var fallback = configuration
        fallback.onMalformedOutput = .fallbackToRecursive
        let chat = LoopingChat()

        let chunks = try await LLMChunker(configuration: fallback, chat: chat)
            .chunks(from: String(repeating: "текст ", count: 500))

        XCTAssertFalse(chunks.isEmpty, "откат обязан был сработать")
        XCTAssertEqual(chunks.first?.note, LLMChunker.recursiveFallbackNote)
        XCTAssertEqual(chat.counter.calls, 2, "попытка и один повтор")
    }

    /// И при выбранном «останавливаться» останавливает та ошибка, которая
    /// про формат, — а не та, которая про недоступную модель.
    func testALoopingAnswerFailsAsMalformedWhenThatIsThePolicy() async {
        var strict = configuration
        strict.onMalformedOutput = .retryThenFail
        do {
            _ = try await LLMChunker(configuration: strict, chat: LoopingChat())
                .chunks(from: String(repeating: "текст ", count: 500))
            XCTFail("ожидалась ошибка")
        } catch let error as LLMChunkingError {
            guard case .malformedOutput = error else {
                return XCTFail("ожидалась malformedOutput, получено \(error)")
            }
        } catch {
            XCTFail("неожиданная ошибка \(error)")
        }
    }

    // MARK: - Время как предел окна

    /// Контекста хватает с запасом, а времени — нет. Именно это и случилось
    /// после перезагрузки модели на 128 000: окно выросло вчетверо, а сто
    /// двадцать секунд остались теми же.
    func testTheWindowShrinksToWhatTheModelCanWriteInTime() async throws {
        let text = String(repeating: "текст ", count: 2_400)
        let roomy = ScriptedChat(answers: [#"{"chunks":["а"]}"#], contextTokens: 128_000)
        _ = try await LLMChunker(configuration: configuration, chat: roomy)
            .chunks(from: text)

        let measured = ScriptedChat(
            answers: [#"{"chunks":["а"]}"#], contextTokens: 128_000, tokensPerSecond: 72
        )
        _ = try await LLMChunker(configuration: configuration, chat: measured)
            .chunks(from: text)

        XCTAssertGreaterThan(
            measured.counter.calls, roomy.counter.calls,
            "измеренная скорость обязана была урезать окно"
        )
        let longest = measured.prompts.all.map(\.count).max() ?? 0
        XCTAssertLessThanOrEqual(
            longest,
            LLMChunker.windowLimitByTime(timeout: 120, tokensPerSecond: 72)
                + configuration.effectivePrompt.count,
            "ни одно окно не должно быть длиннее того, что модель успевает переписать"
        )
    }

    /// Скорость не измерена — ведём себя как раньше: выдумывать её нельзя.
    func testWithoutAMeasuredSpeedTheWindowIsUnchanged() async throws {
        let text = String(repeating: "текст ", count: 2_400)
        let unknown = ScriptedChat(answers: [#"{"chunks":["а"]}"#], contextTokens: 128_000)
        _ = try await LLMChunker(configuration: configuration, chat: unknown)
            .chunks(from: text)
        let byContext = LLMChunker.windowLimit(
            contextTokens: 128_000, prompt: configuration.effectivePrompt
        )
        let expected = min(LLMChunker.wantedWindow(for: configuration), byContext)
        XCTAssertEqual(
            unknown.counter.calls,
            Int((Double(text.count) / Double(expected)).rounded(.up)),
            "без замера окно считается только от контекста"
        )
    }

    /// Модель, которая за таймаут не успевает ничего осмысленного, — это
    /// разговор до прогона, а не три таймаута на каждом окне каждого файла.
    func testAModelTooSlowForTheTimeoutIsRefusedBeforeTheRequest() async {
        let slow = ScriptedChat(
            answers: [#"{"chunks":["а"]}"#], contextTokens: 128_000, tokensPerSecond: 5
        )
        do {
            _ = try await LLMChunker(configuration: configuration, chat: slow)
                .chunks(from: String(repeating: "текст ", count: 500))
            XCTFail("ожидался отказ по времени")
        } catch let error as LLMChunkingError {
            guard case .tooSlowForTimeout = error else {
                return XCTFail("ожидалась tooSlowForTimeout, получено \(error)")
            }
            XCTAssertEqual(slow.counter.calls, 0, "запрос не должен был уйти")
            // Совет обязан быть про время: «перезагрузите с бо́льшим контекстом»
            // здесь сделало бы только хуже.
            XCTAssertTrue(error.recoverySuggestion?.contains("таймаут") ?? false, error.recoverySuggestion ?? "—")
        } catch {
            XCTFail("неожиданная ошибка \(error)")
        }
    }

    /// Предел длины обязан сработать раньше секундомера — с запасом,
    /// а не впритык.
    ///
    /// Число взято с живого прогона: при запасе в 10 % вызовы, упиравшиеся
    /// в предел, занимали 116–117 секунд из 120, и два из них таймаут всё-таки
    /// обогнал. Скорость меряется на калибровочном промпте, а работа идёт на
    /// промпте в несколько раз длиннее, где модель медленнее.
    func testTheTokenLimitIsReachedWellBeforeTheClock() {
        let timeout: TimeInterval = 120
        let measured = 73.4
        let budget = LLMChunker.answerBudget(timeout: timeout, tokensPerSecond: measured)

        // Даже если на деле модель окажется на четверть медленнее замера.
        let pessimistic = Double(budget) / (measured * 0.75)
        XCTAssertLessThan(
            pessimistic, timeout,
            "предел в \(budget) токенов должен дописываться раньше таймаута даже на просевшей скорости"
        )
    }

    /// Больше времени — больше окно: связь обязана быть прямой, иначе
    /// настройка таймаута ни на что не влияет.
    func testARaisedTimeoutBuysABiggerWindow() {
        XCTAssertGreaterThan(
            LLMChunker.windowLimitByTime(timeout: 600, tokensPerSecond: 72),
            LLMChunker.windowLimitByTime(timeout: 120, tokensPerSecond: 72)
        )
    }
}
