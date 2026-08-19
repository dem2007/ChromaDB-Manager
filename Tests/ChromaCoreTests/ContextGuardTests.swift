import XCTest
@testable import ChromaCore

/// A7 + — места, где текст уходил в модель без проверки длины.
///
/// Общее у всех трёх: эмбеддинг переразмеренного текста **не даёт ошибки**
///, поэтому пропуск проверки не виден никак — ни в логе, ни в отчёте,
/// ни в самой коллекции. Проверять приходится тем, что запрос не ушёл.
final class ContextGuardTests: XCTestCase {

    // MARK: - Semantic-чанкинг

    func testASentenceLongerThanTheContextStopsSemanticChunking() async {
        let embeddings = ContextAwareEmbeddings(contextTokens: 512)
        // Точка в конце обязательна: без неё разделитель приклеит следующее
        // предложение к этому, и «предложений» станет два — а на двух стратегия
        // и не запускается.
        let text = [
            String(repeating: "я", count: 40_000) + ".",
            "Обычное предложение.",
            "И ещё одно.",
        ].joined(separator: " ")
        let configuration = ChunkingConfiguration(strategy: .semantic, sizeUnit: .characters)
        do {
            _ = try await SemanticChunker(
                configuration: configuration, embeddings: embeddings, model: "м"
            ).chunks(from: text)
            XCTFail("ожидалась ошибка о слишком длинном предложении")
        } catch let error as SemanticChunkingError {
            guard case .sentenceLongerThanContext = error else {
                return XCTFail("ожидалась sentenceLongerThanContext, получено \(error)")
            }
            let calls = await embeddings.calls
            XCTAssertEqual(calls, 0, "ни один вектор не должен был считаться")
            XCTAssertNotNil(error.recoverySuggestion)
        } catch {
            XCTFail("неожиданная ошибка \(error)")
        }
    }

    func testNormalSentencesStillGoThrough() async throws {
        let embeddings = ContextAwareEmbeddings(contextTokens: 8_192)
        let text = (0..<6).map { "Предложение номер \($0) про содержательный предмет." }.joined(separator: " ")
        let chunks = try await SemanticChunker(
            configuration: ChunkingConfiguration(strategy: .semantic, sizeUnit: .characters),
            embeddings: embeddings, model: "м"
        ).chunks(from: text)
        XCTAssertFalse(chunks.isEmpty)
        let calls = await embeddings.calls
        XCTAssertGreaterThan(calls, 0)
    }

    /// Контекст неизвестен — блокировать по догадке нельзя.
    func testAnUnknownContextDoesNotBlockSemanticChunking() async throws {
        let embeddings = ContextAwareEmbeddings(contextTokens: nil)
        let text = (0..<6).map { "Предложение \($0)." }.joined(separator: " ")
        _ = try await SemanticChunker(
            configuration: ChunkingConfiguration(strategy: .semantic, sizeUnit: .characters),
            embeddings: embeddings, model: "м"
        ).chunks(from: text)
        let calls = await embeddings.calls
        XCTAssertGreaterThan(calls, 0)
    }

    // MARK: - Бюджет как таковой

    /// Пересчёт в другую модель — ровно тот случай, когда контекст становится
    /// **меньше** прежнего, и документы, помещавшиеся раньше, перестают.
    func testTheVerdictThatStopsAReembeddingRun() {
        let long = String(repeating: "я", count: 40_000)
        guard case .tooLong = ContextBudget.check(long, contextLength: 2_048) else {
            return XCTFail("длинный текст при малом контексте — это tooLong")
        }
        guard case .fits = ContextBudget.check("коротко", contextLength: 2_048) else {
            return XCTFail("короткий текст обязан проходить")
        }
        // Неизвестный контекст не блокирует.
        XCTAssertFalse(ContextBudget.check(long, contextLength: nil).blocksSending)
    }

    /// Для эмбеддингов берётся потолок, для порождающих вызовов — загруженный
    /// контекст. Это разные числа и разные измерения ( против).
    func testTheTwoContextNumbersAreNotTheSameThing() {
        let model = LMStudioModel(
            id: "м", kind: .chat, contextLength: 40_960, loadedContextLength: 8_192
        )
        XCTAssertNotEqual(model.contextLength, model.loadedContextLength)
    }

    /// «Думающая» модель при заданной схеме кладёт ответ в канал рассуждения
    /// и оставляет `content` пустым. Раньше это было сорок падений из сорока
    /// с «пустым ответом» при готовом ответе рядом. Данные из живого
    /// ответа qwen3.5-9b.
    func testAnswerComesFromReasoningOnlyWhenContentIsEmpty() {
        // Со схемой: content пуст, ответ по схеме — в канале рассуждения.
        XCTAssertEqual(
            LMStudioClient.answerText(content: "", reasoning: #"{"word": "Привет"}"#),
            #"{"word": "Привет"}"#
        )
        // Без схемы: ответ в content, рассуждения — рядом и в ответ не идут.
        XCTAssertEqual(
            LMStudioClient.answerText(content: "\n\nПривет", reasoning: "Thinking Process: …"),
            "\n\nПривет"
        )
        // Пусто и там и там — это по-прежнему пустой ответ, а не выдумка.
        XCTAssertNil(LMStudioClient.answerText(content: "", reasoning: nil))
        XCTAssertNil(LMStudioClient.answerText(content: nil, reasoning: ""))
    }

    /// Таблица моделей обязана называть оба числа, когда они расходятся:
    /// показанный один потолок читался как опровержение предупреждения
    /// чанкинга, которое называет загруженный контекст.
    func testTheModelsTableNamesBothContextNumbersWhenTheyDiffer() {
        let loadedSmaller = LMStudioModel(
            id: "м", kind: .chat, contextLength: 131_072, loadedContextLength: 8_192
        )
        let line = loadedSmaller.contextLine ?? ""
        XCTAssertTrue(line.contains("8"), line)
        XCTAssertTrue(line.contains("131"), line)

        // Совпали — по-прежнему одно число, но «загружена» сказать обязательно.
        //
        // Раньше здесь стояло «без лишних слов», и слово было не лишним:
        // модель, поднятая ровно на своём потолке, читалась в точности как
        // незагруженная — обе строки «128000 токенов». Поймано на живом экране
        // после того, как рядом появился второй экземпляр модели.
        let same = LMStudioModel(
            id: "м", kind: .chat, contextLength: 8_192, loadedContextLength: 8_192
        )
        XCTAssertTrue(same.contextLine?.contains("загружена") == true, same.contextLine ?? "")
        XCTAssertNotEqual(
            same.contextLine,
            LMStudioModel(id: "м", kind: .chat, contextLength: 8_192).contextLine,
            "загруженная и незагруженная не могут читаться одинаково"
        )

        // Не загружена — потолок и есть всё, что известно.
        let notLoaded = LMStudioModel(id: "м", kind: .chat, contextLength: 131_072)
        XCTAssertFalse(notLoaded.contextLine?.contains("загружена") == true, notLoaded.contextLine ?? "")

        XCTAssertNil(LMStudioModel(id: "м", kind: .chat).contextLine)
    }
}

private actor ContextAwareEmbeddings: EmbeddingProvider {
    private let contextTokens: Int?
    private(set) var calls = 0

    init(contextTokens: Int?) { self.contextTokens = contextTokens }

    func contextLength(of model: String) async -> Int? { contextTokens }

    func embed(texts: [String], model: String) async throws -> [[Double]] {
        calls += 1
        return texts.enumerated().map { index, _ in [Double(index), 1, 0] }
    }
}

/// калибровка оценки токенов.
final class TokenRatioStoreTests: XCTestCase {
    func testAMeasurementReplacesThePessimisticDefault() async {
        let store = TokenRatioStore()
        let before = await store.ratio(of: "м")
        XCTAssertNil(before)
        let defaulted = await store.budgetRatio(of: "м")
        XCTAssertEqual(defaulted, TokenEstimator.pessimisticCharactersPerToken)
        await store.record(characters: 12_193, tokens: 5_682, model: "м")
        let measured = await store.budgetRatio(of: "м")
        XCTAssertEqual(measured, 12_193.0 / 5_682.0, accuracy: 0.0001)
    }

    /// Худший из встреченных текстов, а не типичный: бюджет ошибается опасно
    /// только в одну сторону.
    func testTheWorstObservedRatioWins() async {
        let store = TokenRatioStore()
        await store.record(characters: 4_000, tokens: 1_000, model: "м")   // 4.0
        await store.record(characters: 2_000, tokens: 1_000, model: "м")   // 2.0 — хуже
        await store.record(characters: 3_500, tokens: 1_000, model: "м")   // 3.5
        let worst = await store.budgetRatio(of: "м")
        XCTAssertEqual(worst, 2.0, accuracy: 0.0001)
    }

    func testAnAnswerWithoutUsageChangesNothing() async {
        let store = TokenRatioStore()
        await store.record(characters: 1_000, tokens: nil, model: "м")
        await store.record(characters: 0, tokens: 100, model: "м")
        let value = await store.ratio(of: "м")
        XCTAssertNil(value)
    }

    func testModelsDoNotShareAMeasurement() async {
        let store = TokenRatioStore()
        await store.record(characters: 2_000, tokens: 1_000, model: "первая")
        let first = await store.budgetRatio(of: "первая")
        XCTAssertEqual(first, 2.0, accuracy: 0.0001)
        let second = await store.budgetRatio(of: "вторая")
        XCTAssertEqual(second, TokenEstimator.pessimisticCharactersPerToken)
    }

    /// Замеренное соотношение обязано давать бюджет **больше** пессимистичного,
    /// иначе калибровка не имеет смысла: она затем и нужна, чтобы перестать
    /// резать лишнее, как только стало известно настоящее число.
    func testAMeasuredRatioAllowsALongerPrompt() {
        let documents = (0..<20).map { _ in String(repeating: "я", count: 4_000) }
        let pessimistic = Reranker.fit(
            documents: documents, query: "з", template: "", contextTokens: 8_192,
            charactersPerToken: TokenEstimator.pessimisticCharactersPerToken
        )
        let measured = Reranker.fit(
            documents: documents, query: "з", template: "", contextTokens: 8_192,
            charactersPerToken: 2.8
        )
        let pessimisticLength = pessimistic.documents.reduce(0) { $0 + $1.count }
        let measuredLength = measured.documents.reduce(0) { $0 + $1.count }
        XCTAssertGreaterThan(measuredLength, pessimisticLength)
    }
}
