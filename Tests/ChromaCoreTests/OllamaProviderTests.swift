import XCTest
@testable import ChromaCore

/// Ollama на месте LM Studio. Ответы — в форме из официальной
/// документации Ollama (docs.ollama.com/api) и проверенной вживую.
final class OllamaProviderTests: XCTestCase {
    // MARK: - /api/show

    /// Тип — из `capabilities`, потолок контекста — из
    /// `model_info["<архитектура>.context_length"]`.
    func testShowGivesTheKindAndTheContextCeiling() throws {
        let show = Data(#"""
        {"capabilities":["embedding"],
         "details":{"format":"gguf","family":"nomic-bert"},
         "model_info":{"general.architecture":"nomic-bert","nomic-bert.context_length":2048,"nomic-bert.embedding_length":768}}
        """#.utf8)
        let facts = try XCTUnwrap(LMStudioClient.ollamaFacts(from: show))
        XCTAssertEqual(facts, .init(capabilities: ["embedding"], contextLength: 2048))
        let model = LMStudioClient.describeOllama(name: "nomic-embed-text:latest", facts: facts, loadedContext: nil)
        XCTAssertEqual(model.kind, .embedding)
        XCTAssertFalse(model.kindIsInferred)
        XCTAssertEqual(model.contextLength, 2048)
        XCTAssertNil(model.loadedContextLength)
    }

    /// Чат-модель с рассуждением и зрением — чат; контекст — по ключу
    /// архитектуры, даже если рядом есть другие `*.context_length`-подобные.
    func testACompletionModelIsChat() throws {
        let show = Data(#"""
        {"capabilities":["completion","thinking","vision"],
         "model_info":{"general.architecture":"gemma4","gemma4.context_length":131072,"gemma4.block_count":42}}
        """#.utf8)
        let facts = try XCTUnwrap(LMStudioClient.ollamaFacts(from: show))
        let model = LMStudioClient.describeOllama(name: "gemma4", facts: facts, loadedContext: 4096)
        XCTAssertEqual(model.kind, .chat)
        XCTAssertEqual(model.contextLength, 131072)
        XCTAssertEqual(model.loadedContextLength, 4096)
    }

    /// Без архитектуры — любой `*.context_length`; без `capabilities` —
    /// тип не известен, и его определит пробный запрос, как у LM Studio.
    func testMissingFieldsDoNotInventAnswers() throws {
        let facts = try XCTUnwrap(LMStudioClient.ollamaFacts(from: Data(#"{"model_info":{"llama.context_length":8192}}"#.utf8)))
        XCTAssertEqual(facts.contextLength, 8192)
        XCTAssertEqual(LMStudioClient.describeOllama(name: "x", facts: facts, loadedContext: nil).kind, .unknown)
        XCTAssertEqual(LMStudioClient.describeOllama(name: "x", facts: nil, loadedContext: nil).kind, .unknown)
        XCTAssertNil(LMStudioClient.ollamaFacts(from: Data("не JSON".utf8)))
    }

    /// Без архитектуры — ключ верхнего уровня, а не кодировщика картинок,
    /// и одинаково при каждом разборе.
    func testTheFallbackContextKeyIsTheTopLevelOne() throws {
        let show = Data(#"{"model_info":{"mm.vision.context_length":729,"mm.context_length":32768}}"#.utf8)
        for _ in 0..<20 {
            XCTAssertEqual(LMStudioClient.ollamaFacts(from: show)?.contextLength, 32768)
        }
    }

    /// Облачные модели Ollama — не на этом Маке, и в список не идут.
    func testCloudModelsAreRecognised() throws {
        let tags = Data(#"""
        {"models":[
          {"name":"nomic-embed-text:latest","modified_at":"2026-07-12T22:06:26Z"},
          {"name":"gpt-oss:120b-cloud","remote_model":"gpt-oss:120b","remote_host":"https://ollama.com:443"}
        ]}
        """#.utf8)
        let decoded = try JSONDecoder().decode(LMStudioClient.OllamaTags.self, from: tags)
        XCTAssertEqual(decoded.models.map(\.isRemote), [false, true])
    }

    /// Сведения `/api/show` — общие на приложение: клиент живёт одну операцию.
    func testShowFactsOutliveTheClient() {
        let key = "http://localhost:11434\u{0}m\u{0}\(UUID())"
        XCTAssertNil(LMStudioClient.sharedOllamaFacts.value(for: key))
        LMStudioClient.sharedOllamaFacts.store(.init(capabilities: ["embedding"], contextLength: 2048), for: key)
        XCTAssertEqual(LMStudioClient.sharedOllamaFacts.value(for: key)?.contextLength, 2048)
    }

    /// Рассуждение не строкой не ломает ответ целиком.
    func testAReasoningObjectDoesNotBreakTheAnswer() throws {
        let data = Data(#"{"choices":[{"message":{"content":"{\"ok\":true}","reasoning":{"summary":"x"}},"finish_reason":"stop"}]}"#.utf8)
        let response = try JSONDecoder().decode(LMStudioClient.ChatResponse.self, from: data)
        XCTAssertEqual(response.choices.first?.message?.content, #"{"ok":true}"#)
        XCTAssertNil(response.choices.first?.message?.reasoning)
        let ollama = Data(#"{"choices":[{"message":{"content":"","reasoning":"думаю"},"finish_reason":"stop"}]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(LMStudioClient.ChatResponse.self, from: ollama).choices.first?.message?.reasoning, "думаю")
    }

    // MARK: - Предел чтения

    /// Сервер без молчаливой обрезки пробой не меряется: проба из длинных
    /// текстов у него только сорвалась бы — и повторялась на каждом файле.
    func testANonTruncatingServerIsNotProbed() async throws {
        struct Strict: EmbeddingProvider {
            final class Calls: @unchecked Sendable { var count = 0 }
            let calls = Calls()
            var truncatesSilently: Bool { false }
            func embed(texts: [String], model: String) async throws -> [[Double]] {
                calls.count += 1
                return texts.map { _ in [1, 0] }
            }
        }
        let provider = Strict()
        let binding = ModelBindingService()
        let first = await binding.measuredInputLimit(of: "m", embeddings: provider)
        let second = await binding.measuredInputLimit(of: "m", embeddings: provider)
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(provider.calls.count, 0)
        XCTAssertFalse(try LMStudioClient(baseURLString: "http://localhost:11434", provider: .ollama).truncatesSilently)
        XCTAssertTrue(try LMStudioClient(baseURLString: "http://localhost:1234").truncatesSilently)
    }

    // MARK: - /api/embed

    func testEmbedResponseIsReadInOrder() throws {
        let data = Data(#"{"model":"nomic-embed-text:latest","embeddings":[[0.1,0.2],[0.3,0.4]],"prompt_eval_count":4}"#.utf8)
        XCTAssertEqual(
            try LMStudioClient.ollamaEmbeddings(from: data, sent: 2, model: "nomic-embed-text:latest"),
            [[0.1, 0.2], [0.3, 0.4]]
        )
        // Имя без тега — та же модель: Ollama дописывает `:latest`.
        XCTAssertNoThrow(try LMStudioClient.ollamaEmbeddings(from: data, sent: 2, model: "nomic-embed-text"))
    }

    func testEmbedResponseIsCheckedLikeLMStudio() {
        let short = Data(#"{"model":"m","embeddings":[[0.1]]}"#.utf8)
        XCTAssertThrowsError(try LMStudioClient.ollamaEmbeddings(from: short, sent: 2, model: "m")) { error in
            guard case LMStudioError.embeddingCountMismatch(2, 1) = error else { return XCTFail("\(error)") }
        }
        let other = Data(#"{"model":"bge-m3","embeddings":[[0.1]]}"#.utf8)
        XCTAssertThrowsError(try LMStudioClient.ollamaEmbeddings(from: other, sent: 1, model: "nomic-embed-text")) { error in
            guard case LMStudioError.modelSubstituted = error else { return XCTFail("\(error)") }
        }
        let empty = Data(#"{"model":"m","embeddings":[]}"#.utf8)
        XCTAssertThrowsError(try LMStudioClient.ollamaEmbeddings(from: empty, sent: 1, model: "m")) { error in
            guard case LMStudioError.modelNotEmbedding = error else { return XCTFail("\(error)") }
        }
    }

    /// Ошибка Ollama — поле `error`, его и показывать.
    func testTheErrorFieldIsTheMessage() {
        XCTAssertEqual(
            LMStudioClient.ollamaErrorMessage(Data(#"{"error":"the input length exceeds the context length"}"#.utf8)),
            "the input length exceeds the context length"
        )
        XCTAssertNil(LMStudioClient.ollamaErrorMessage(Data(#"{"error":{"message":"x"}}"#.utf8)))
    }

    // MARK: - Тексты ошибок

    /// Ошибка называет сервер, от которого пришла, и совет — его.
    func testErrorsNameTheirOwnServer() throws {
        let unreachable = LMStudioError.unreachable("не удалось подключиться", server: .ollama).errorDescription ?? ""
        XCTAssertTrue(unreachable.hasPrefix("Ollama недоступна"), unreachable)
        XCTAssertTrue(unreachable.contains("ollama serve"), unreachable)
        XCTAssertFalse(unreachable.contains("LM Studio"), unreachable)
        XCTAssertTrue(LMStudioError.unreachable("x", server: .ollama).mcpReason.hasPrefix("Ollama is not reachable"))
        XCTAssertTrue((LMStudioError.unreachable("x", server: .lmStudio).errorDescription ?? "").contains("Local Server"))
    }

    /// Операция, начатая с одним сервером, после переключения на другой
    /// падает с именем своего: клиент, созданный позже, чужую ошибку
    /// не переименовывает.
    func testAnErrorKeepsItsServerAfterTheSwitch() async throws {
        // Порт 9 (discard) никто не слушает — отказ приходит сразу.
        let ollama = try LMStudioClient(baseURLString: "http://127.0.0.1:9", provider: .ollama)
        _ = try LMStudioClient(baseURLString: "http://127.0.0.1:9", provider: .lmStudio)
        do {
            _ = try await ollama.models()
            XCTFail("порт 9 не должен ответить")
        } catch let error as LMStudioError {
            let text = error.errorDescription ?? ""
            XCTAssertTrue(text.hasPrefix("Ollama недоступна"), text)
        }
    }

    // MARK: - Настройки

    func testEachServerKeepsItsOwnAddress() {
        var configuration = AppConfiguration(llmProvider: .lmStudio)
        configuration.llmBaseURL = "http://studio:1234"
        configuration.llmProvider = .ollama
        XCTAssertEqual(configuration.llmBaseURL, LLMProvider.ollama.defaultBaseURL)
        configuration.llmBaseURL = "http://imac:11434"
        configuration.llmProvider = .lmStudio
        XCTAssertEqual(configuration.llmBaseURL, "http://studio:1234")
        XCTAssertEqual(configuration.ollamaBaseURL, "http://imac:11434")
    }

    func testTheProviderSurvivesAndOldFilesGetThePlatformDefault() throws {
        var configuration = AppConfiguration()
        configuration.llmProvider = .ollama
        configuration.ollamaBaseURL = "http://imac:11434"
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(decoded.llmProvider, .ollama)
        XCTAssertEqual(decoded.ollamaBaseURL, "http://imac:11434")

        let old = try JSONDecoder().decode(AppConfiguration.self, from: Data(#"{"lmStudioBaseURL":"http://localhost:1234"}"#.utf8))
        XCTAssertEqual(old.llmProvider, .platformDefault)
        XCTAssertEqual(old.ollamaBaseURL, "http://localhost:11434")
        let unknown = try JSONDecoder().decode(AppConfiguration.self, from: Data(#"{"llmProvider":"vllm"}"#.utf8))
        XCTAssertEqual(unknown.llmProvider, .platformDefault)
    }

    /// Адрес Ollama переносится, выбор сервера — нет: он про железо этой машины.
    func testTransferCarriesTheAddressButNotTheChoice() {
        var source = AppConfiguration()
        source.llmProvider = .lmStudio
        source.ollamaBaseURL = "http://imac:11434"
        var target = AppConfiguration()
        target.llmProvider = .ollama
        TransferablePreferences(from: source).apply(to: &target)
        XCTAssertEqual(target.llmProvider, .ollama)
        XCTAssertEqual(target.ollamaBaseURL, "http://imac:11434")
    }

    /// Модель векторов и модель оценки у каждого сервера свои: переключение
    /// туда и обратно не теряет выбор, а у нового сервера модель пуста —
    /// её выберет экран «Подключение» из списка этого сервера.
    func testEachServerKeepsItsOwnModels() {
        var configuration = AppConfiguration(llmProvider: .lmStudio)
        configuration.defaultEmbeddingModel = "text-embedding-nomic-embed-text-v1.5"
        configuration.modelJudgeModel = "qwen/qwen3-8b"
        configuration.llmProvider = .ollama
        XCTAssertNil(configuration.defaultEmbeddingModel)
        XCTAssertNil(configuration.modelJudgeModel)
        configuration.defaultEmbeddingModel = "nomic-embed-text:latest"
        configuration.modelJudgeModel = "qwen3:8b"
        configuration.llmProvider = .lmStudio
        XCTAssertEqual(configuration.defaultEmbeddingModel, "text-embedding-nomic-embed-text-v1.5")
        XCTAssertEqual(configuration.modelJudgeModel, "qwen/qwen3-8b")
        XCTAssertEqual(configuration.ollamaEmbeddingModel, "nomic-embed-text:latest")
        XCTAssertEqual(configuration.ollamaJudgeModel, "qwen3:8b")
    }

    /// Обе пары моделей сохраняются, а единственная модель из файла до
    /// достаётся LM Studio — другого сервера тогда не было. Обратно так же:
    /// модель LM Studio лежит под прежним ключом, и прежняя сборка её прочтёт.
    func testModelsSurviveAndOldFilesGiveThemToLMStudio() throws {
        var configuration = AppConfiguration(llmProvider: .ollama)
        configuration.lmStudioEmbeddingModel = "text-embedding-bge-m3"
        configuration.ollamaEmbeddingModel = "bge-m3:latest"
        configuration.ollamaJudgeModel = "qwen3:8b"
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(decoded.lmStudioEmbeddingModel, "text-embedding-bge-m3")
        XCTAssertEqual(decoded.ollamaEmbeddingModel, "bge-m3:latest")
        XCTAssertEqual(decoded.ollamaJudgeModel, "qwen3:8b")
        XCTAssertNil(decoded.lmStudioJudgeModel)
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        XCTAssertEqual(written["defaultEmbeddingModel"] as? String, "text-embedding-bge-m3")
        XCTAssertNil(written["lmStudioEmbeddingModel"])

        let old = try JSONDecoder().decode(AppConfiguration.self, from: Data(#"""
        {"llmProvider":"lmStudio","defaultEmbeddingModel":"text-embedding-bge-m3","modelJudgeModel":"qwen/qwen3-8b"}
        """#.utf8))
        XCTAssertEqual(old.lmStudioEmbeddingModel, "text-embedding-bge-m3")
        XCTAssertEqual(old.lmStudioJudgeModel, "qwen/qwen3-8b")
        XCTAssertNil(old.ollamaEmbeddingModel)
        XCTAssertNil(old.ollamaJudgeModel)
    }

    /// Перенос везёт модели обоих серверов, каждую на своё место; файл без
    /// модели одного из серверов не стирает выбранную здесь — с Мака на Intel
    /// модель LM Studio не приходит.
    func testTransferCarriesTheModelOfEachServer() throws {
        var source = AppConfiguration(llmProvider: .lmStudio)
        source.lmStudioEmbeddingModel = "text-embedding-bge-m3"
        source.ollamaEmbeddingModel = "bge-m3:latest"
        var target = AppConfiguration(llmProvider: .ollama)
        TransferablePreferences(from: source).apply(to: &target)
        XCTAssertEqual(target.defaultEmbeddingModel, "bge-m3:latest")
        XCTAssertEqual(target.lmStudioEmbeddingModel, "text-embedding-bge-m3")

        let preferences = try JSONEncoder().encode(TransferablePreferences(from: AppConfiguration()))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: preferences) as? [String: Any])
        object["ollamaEmbeddingModel"] = nil
        object["defaultEmbeddingModel"] = "text-embedding-nomic"
        let old = try JSONDecoder().decode(
            TransferablePreferences.self, from: JSONSerialization.data(withJSONObject: object)
        )
        old.apply(to: &target)
        XCTAssertEqual(target.ollamaEmbeddingModel, "bge-m3:latest")
        XCTAssertEqual(target.lmStudioEmbeddingModel, "text-embedding-nomic")

        var intel = AppConfiguration(llmProvider: .ollama)
        intel.ollamaEmbeddingModel = "nomic-embed-text:latest"
        TransferablePreferences(from: intel).apply(to: &target)
        XCTAssertEqual(target.lmStudioEmbeddingModel, "text-embedding-nomic")
        XCTAssertEqual(target.ollamaEmbeddingModel, "nomic-embed-text:latest")
    }
}

/// Живая проверка против настоящей Ollama:
///
///     OLLAMA_IT=1 OLLAMA_URL=http://localhost:11434 OLLAMA_EMBED_MODEL=nomic-embed-text:latest \
///         OLLAMA_CHAT_MODEL=qwen3:8b swift test --filter OllamaLiveTests
///
/// `OLLAMA_CHAT_MODEL` необязателен: без него проверяются только векторы.
final class OllamaLiveTests: XCTestCase {
    func testTheClientWorksAgainstARealOllama() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["OLLAMA_IT"] == "1", "Живая проверка включается OLLAMA_IT=1")
        let url = environment["OLLAMA_URL"] ?? LLMProvider.ollama.defaultBaseURL
        let embedModel = environment["OLLAMA_EMBED_MODEL"] ?? "nomic-embed-text:latest"
        let client = try LMStudioClient(baseURLString: url, provider: .ollama)

        let models = try await client.models()
        let embedding = try XCTUnwrap(models.first { $0.id == embedModel }, "модели \(embedModel) нет в Ollama")
        XCTAssertEqual(embedding.kind, .embedding, "тип должен прийти из capabilities")
        XCTAssertNotNil(embedding.contextLength)

        let vectors = try await client.embed(texts: ["первый текст", "второй текст", "третий"], model: embedModel)
        XCTAssertEqual(vectors.count, 3)
        XCTAssertTrue(vectors.allSatisfy { !$0.isEmpty })

        // Предел входа — окно загруженной модели, не больше потолка.
        let limit = try await XCTUnwrapAsync(await client.contextLength(of: embedModel))
        XCTAssertLessThanOrEqual(limit, embedding.contextLength ?? .max)
        // И тот же предел — у службы привязки, которой пользуются синхронизация,
        // импорт, MCP и «Тестовый стенд».
        let bound = await ModelBindingService().contextLength(of: embedModel, lmStudio: client)
        XCTAssertEqual(bound, limit)
        // Сорвавшийся запрос предела не запоминается: у Ollama без предела
        // куски не дорезались бы до перезапуска, и каждый длиннее окна
        // отвергался бы вместе с файлом.
        let binding = ModelBindingService()
        let dead = try LMStudioClient(baseURLString: "http://127.0.0.1:9", provider: .ollama)
        let missing = await binding.contextLength(of: embedModel, lmStudio: dead)
        XCTAssertNil(missing)
        let recovered = await binding.contextLength(of: embedModel, lmStudio: client)
        XCTAssertEqual(recovered, limit)

        // Длиннее окна — ошибка, а не молча обрезанный вектор.
        let long = (0..<(limit * 3)).map { "слово\($0)" }.joined(separator: " ")
        do {
            _ = try await client.embedIgnoringCache(texts: [long], model: embedModel)
            XCTFail("текст длиннее контекста должен быть отвергнут")
        } catch LMStudioError.api(_, let message, .ollama) {
            XCTAssertTrue(message.contains("context length"), message)
        }

        // Чат-модель (необязательно): окно — из `/api/ps` после прогрева,
        // ответ по схеме — через `/v1/chat/completions`.
        guard let chatModel = environment["OLLAMA_CHAT_MODEL"] else { return }
        let window = await client.loadedContextLength(of: chatModel)
        XCTAssertNotNil(window, "окно чат-модели должно найтись после прогрева")
        let schema = ChatJSONSchema(
            name: "probe",
            schema: ["type": "object", "properties": ["ok": ["type": "boolean"]], "required": ["ok"]]
        )
        let answer = try await client.complete(
            prompt: "Ответь JSON {\"ok\": true}", model: chatModel,
            settings: ChatGenerationSettings(temperature: 0, seed: nil, maxTokens: 2000),
            schema: schema, timeout: 300
        )
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(answer.utf8)), answer)
    }
}

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
