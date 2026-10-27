import XCTest
@testable import ChromaCore

/// модели в умолчаниях нарезки и в профилях поиска у каждого сервера
/// свои: имена моделей у LM Studio и Ollama разные, а числа нарезки и
/// остальные настройки поиска — общие.
final class PerServerModelsTests: XCTestCase {
    // MARK: - Умолчания нарезки

    func testChunkingDefaultsKeepTheNumbersCommonAndTheModelsApart() {
        var configuration = AppConfiguration(llmProvider: .lmStudio)
        var studio = configuration.chunkingDefault(for: .llmBased)
        studio.chatModel = "qwen/qwen3-8b"
        studio.enrichmentModel = "qwen/qwen3-4b"
        studio.chunkSize = 700
        configuration.setChunkingDefault(studio)

        configuration.llmProvider = .ollama
        var ollama = configuration.chunkingDefault(for: .llmBased)
        XCTAssertNil(ollama.chatModel, "модели LM Studio у Ollama не найдутся")
        XCTAssertNil(ollama.enrichmentModel)
        XCTAssertEqual(ollama.chunkSize, 700, "числа нарезки — общие")
        ollama.chatModel = "qwen3:8b"
        ollama.chunkSize = 900
        configuration.setChunkingDefault(ollama)
        XCTAssertEqual(configuration.chunkingDefault(for: .llmBased).chatModel, "qwen3:8b")

        configuration.llmProvider = .lmStudio
        let back = configuration.chunkingDefault(for: .llmBased)
        XCTAssertEqual(back.chatModel, "qwen/qwen3-8b")
        XCTAssertEqual(back.enrichmentModel, "qwen/qwen3-4b")
        XCTAssertEqual(back.chunkSize, 900)

        configuration.clearChunkingDefault(for: .llmBased)
        configuration.llmProvider = .ollama
        XCTAssertNil(configuration.chunkingDefault(for: .llmBased).chatModel)
        XCTAssertFalse(configuration.hasOwnChunkingDefault(for: .llmBased))
    }

    /// Модели Ollama сохраняются и переносятся; файл и перенос без них
    /// модели здесь не стирают.
    func testOllamaChunkingModelsSurviveAndTravel() throws {
        var configuration = AppConfiguration(llmProvider: .ollama)
        var semantic = configuration.chunkingDefault(for: .semantic)
        semantic.sentenceEmbeddingModel = "nomic-embed-text:latest"
        configuration.setChunkingDefault(semantic)

        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(decoded.chunkingDefault(for: .semantic).sentenceEmbeddingModel, "nomic-embed-text:latest")

        var target = AppConfiguration(llmProvider: .ollama)
        TransferablePreferences(from: configuration).apply(to: &target)
        XCTAssertEqual(target.chunkingDefault(for: .semantic).sentenceEmbeddingModel, "nomic-embed-text:latest")
    }

    /// Перенос с Мака, где был один сервер, моделей другого не стирает:
    /// с Apple Silicon не приходят модели Ollama, с Intel — модели LM Studio.
    func testTransferDoesNotEraseTheOtherServersChunkingModels() {
        var studioMac = AppConfiguration(llmProvider: .lmStudio)
        var studio = studioMac.chunkingDefault(for: .llmBased)
        studio.chatModel = "qwen/qwen3-8b"
        studioMac.setChunkingDefault(studio)

        var intelMac = AppConfiguration(llmProvider: .ollama)
        var ollama = intelMac.chunkingDefault(for: .llmBased)
        ollama.chatModel = "qwen3:8b"
        ollama.chunkSize = 640
        intelMac.setChunkingDefault(ollama)

        // С Intel на Apple Silicon: числа приезжают, модель LM Studio остаётся.
        var target = studioMac
        TransferablePreferences(from: intelMac).apply(to: &target)
        XCTAssertEqual(target.chunkingDefault(for: .llmBased).chunkSize, 640)
        XCTAssertEqual(target.chunkingDefault(for: .llmBased).chatModel, "qwen/qwen3-8b")
        target.llmProvider = .ollama
        XCTAssertEqual(target.chunkingDefault(for: .llmBased).chatModel, "qwen3:8b")

        // С Apple Silicon на Intel: модель Ollama остаётся.
        var back = intelMac
        TransferablePreferences(from: studioMac).apply(to: &back)
        XCTAssertEqual(back.chunkingDefault(for: .llmBased).chatModel, "qwen3:8b")
        back.llmProvider = .lmStudio
        XCTAssertEqual(back.chunkingDefault(for: .llmBased).chatModel, "qwen/qwen3-8b")
    }

    /// Ручная пометка типа — у модели своего сервера; прежние пометки
    /// LM Studio лежат под самим именем и действуют, как раньше.
    func testKindOverridesBelongToTheServer() {
        var configuration = AppConfiguration(modelKindOverrides: ["bge-m3-mlx": "embedding"])
        XCTAssertEqual(configuration.kindOverride(of: "bge-m3-mlx", server: .lmStudio), .embedding)
        XCTAssertNil(configuration.kindOverride(of: "bge-m3-mlx", server: .ollama))

        configuration.setKindOverride(.chat, of: "bge-m3-mlx", server: .ollama)
        XCTAssertEqual(configuration.kindOverride(of: "bge-m3-mlx", server: .ollama), .chat)
        XCTAssertEqual(configuration.kindOverride(of: "bge-m3-mlx", server: .lmStudio), .embedding)
        XCTAssertEqual(configuration.modelKindOverrides.count, 2)
    }

    // MARK: - Профили поиска

    private func makeStore() throws -> (SearchProfileStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (SearchProfileStore(directory: directory), directory)
    }

    func testTheRerankModelBelongsToTheServer() throws {
        let (store, directory) = try makeStore()
        var profile = store.defaultProfile(for: "notes")
        profile.rerankEnabled = true
        profile.rerankModel = "qwen/qwen3-8b"
        store.save(profile)

        store.server = .ollama
        var onOllama = store.defaultProfile(for: "notes")
        XCTAssertEqual(onOllama.rerankModel, "", "модель LM Studio у Ollama не найдётся")
        XCTAssertTrue(onOllama.rerankEnabled, "остальные настройки — общие")
        onOllama.rerankModel = "qwen3:8b"
        store.save(onOllama)

        let reopened = SearchProfileStore(directory: directory)
        XCTAssertEqual(reopened.defaultProfile(for: "notes").rerankModel, "qwen/qwen3-8b")
        reopened.server = .ollama
        XCTAssertEqual(reopened.defaultProfile(for: "notes").rerankModel, "qwen3:8b")
    }

    /// Профиль до: одна модель под ключом `rerankModel` — это модель
    /// LM Studio, и она же остаётся под этим ключом в файле.
    func testAnOlderProfileKeepsItsModelForLMStudio() throws {
        let old = Data(#"[{"collectionName":"notes","rerankEnabled":true,"rerankModel":"qwen/qwen3-8b"}]"#.utf8)
        let profiles = try JSONDecoder().decode([SearchProfile].self, from: old)
        let profile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(profile.rerankModel, "qwen/qwen3-8b")
        XCTAssertEqual(profile.unknownSettings, [])

        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        XCTAssertEqual(written["rerankModel"] as? String, "qwen/qwen3-8b")
        XCTAssertNil(written["lmStudioRerankModel"])
    }

    /// Снимок профиля в прогоне «Оценки» помнит сервер, на котором шёл.
    func testASnapshotRemembersItsServer() throws {
        var profile = SearchProfile(collectionName: "notes")
        profile.server = .ollama
        profile.rerankModel = "qwen3:8b"
        let decoded = try JSONDecoder().decode(SearchProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded.server, .ollama)
        XCTAssertEqual(decoded.rerankModel, "qwen3:8b")
    }
}

/// замеры скорости по паре «модель + сервер».
final class PerServerSpeedTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("speed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func benchmark(_ model: String, server: LLMProvider, seconds: Double) -> ModelBenchmark {
        ModelBenchmark(
            model: model, server: server, measuredAt: Date(), dimension: 768, firstCallSeconds: 1,
            batches: [BenchmarkBatchResult(batchSize: 4, texts: 100, seconds: seconds)]
        )
    }

    /// Одноимённая модель двух серверов — две скорости, и оценка времени
    /// берёт скорость выбранного.
    func testRunMetricsKeepTheServersApart() async {
        let store = MetricsStore(fileURL: directory.appendingPathComponent("metrics.json"))
        await store.recordEmbedding(model: "nomic-embed-text", server: .lmStudio, texts: 100, duration: 1)
        await store.recordEmbedding(model: "nomic-embed-text", server: .ollama, texts: 100, duration: 20)
        await store.recordJudgement(model: "qwen3", server: .ollama, calls: 2, duration: 10)
        let all = await store.current()
        XCTAssertEqual(all.models.count, 2)
        XCTAssertEqual(all.models.first { $0.serverID == "ollama" }?.title, "nomic-embed-text (Ollama)")
        XCTAssertEqual(all.models.first { $0.serverID == "lmStudio" }?.title, "nomic-embed-text")

        XCTAssertEqual(all.serving(.lmStudio).models.first?.averageSeconds ?? 0, 0.01, accuracy: 1e-9)
        XCTAssertEqual(all.serving(.ollama).models.first?.averageSeconds ?? 0, 0.2, accuracy: 1e-9)
        XCTAssertNil(all.serving(.lmStudio).judgeSecondsPerCall(model: "qwen3"))
        XCTAssertEqual(all.serving(.ollama).judgeSecondsPerCall(model: "qwen3") ?? 0, 5, accuracy: 1e-9)
    }

    /// Замер одного сервера не заменяет замер другого; LM Studio пишется
    /// без поля сервера — как до.
    func testBenchmarksKeepTheServersApart() async throws {
        let file = directory.appendingPathComponent("benchmarks.json")
        let store = BenchmarkStore(fileURL: file)
        await store.store(benchmark("nomic-embed-text", server: .lmStudio, seconds: 1))
        await store.store(benchmark("nomic-embed-text", server: .ollama, seconds: 30))
        await store.store(benchmark("nomic-embed-text", server: .ollama, seconds: 20))

        let reopened = BenchmarkStore(fileURL: file)
        let all = await reopened.all()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.serving(.ollama).first?.secondsPerText ?? 0, 0.2, accuracy: 1e-9)
        let studio = await reopened.benchmark(for: "nomic-embed-text", server: .lmStudio)
        XCTAssertEqual(studio?.secondsPerText ?? 0, 0.01, accuracy: 1e-9)
        XCTAssertNil(studio?.server)

        let written = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(written.components(separatedBy: "\"server\"").count - 1, 1, "поле сервера — только у Ollama")
    }

    /// Файл до читается: замеры без сервера — замеры LM Studio.
    func testOldMeasurementsAreLMStudios() throws {
        let old = Data(#"{"models":[{"model":"m","texts":4,"seconds":2}],"strategies":[],"judges":[]}"#.utf8)
        let snapshot = try JSONDecoder().decode(MetricsSnapshot.self, from: old)
        XCTAssertEqual(snapshot.serving(.lmStudio).models.count, 1)
        XCTAssertEqual(snapshot.serving(.ollama).models.count, 0)
    }
}
