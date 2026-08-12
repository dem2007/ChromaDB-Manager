import XCTest
@testable import ChromaCore

/// тип «Реранкинг» и порядок моделей в выпадающих списках.
final class ModelKindTests: XCTestCase {
    func testTheRerankingKindExistsAndIsNamed() {
        XCTAssertEqual(LMStudioModelKind.reranking.rawValue, "reranking")
        XCTAssertEqual(LMStudioModelKind.reranking.title, "Реранкинг")
        XCTAssertTrue(LMStudioModelKind.allCases.contains(.reranking))
    }

    /// Ставится только вручную: LM Studio отдаёт переранжировщики обычным
    /// `llm`, и если бы этот тип приходил из API, он бы уже приходил.
    func testTheAPINeverReportsIt() throws {
        let json = """
        {"data":[
          {"id":"qwen3-reranker-0.6b","type":"llm","max_context_length":40960,"loaded_context_length":8192},
          {"id":"jina-reranker-v3.5-mlx","type":"llm","max_context_length":131072}
        ]}
        """
        let models = try LMStudioClient.decodeModelsForTesting(Data(json.utf8))
        XCTAssertEqual(models.count, 2)
        for model in models {
            XCTAssertEqual(
                model.kind, .chat,
                "переранжировщик приходит из API обычной чат-моделью — тип ставит человек"
            )
        }
    }

    /// Переопределение переживает запись и чтение настроек: тип, поставленный
    /// руками, — единственный его источник, и потерять его нельзя.
    func testTheManualOverrideSurvivesTheFile() throws {
        var configuration = AppConfiguration()
        configuration.modelKindOverrides["qwen3-reranker-0.6b"] = LMStudioModelKind.reranking.rawValue
        let restored = try JSONDecoder().decode(
            AppConfiguration.self, from: JSONEncoder().encode(configuration)
        )
        XCTAssertEqual(
            restored.modelKindOverrides["qwen3-reranker-0.6b"],
            LMStudioModelKind.reranking.rawValue
        )
    }
}

/// порядок в выпадающих списках.
final class ModelPickerOrderTests: XCTestCase {
    private var library: [LMStudioModel] {
        [
            LMStudioModel(id: "text-embedding-nomic", kind: .embedding),
            LMStudioModel(id: "google/gemma-4-e4b", kind: .chat),
            LMStudioModel(id: "qwen3-reranker-0.6b", kind: .reranking),
            LMStudioModel(id: "неопознанная", kind: .unknown),
            LMStudioModel(id: "aaa-chat", kind: .chat),
            LMStudioModel(id: "jina-reranker-v3.5-mlx", kind: .reranking),
        ]
    }

    func testRerankersComeFirstForTheRerankingPicker() {
        let order = ModelPickerOrder.sorted(library, preferring: .reranking).map(\.id)
        XCTAssertEqual(Array(order.prefix(2)), ["jina-reranker-v3.5-mlx", "qwen3-reranker-0.6b"])
        XCTAssertEqual(order.last, "text-embedding-nomic", "эмбеддинговые — в самом конце")
    }

    func testChatModelsComeFirstForTheChunkingPicker() {
        let order = ModelPickerOrder.sorted(library, preferring: .chat).map(\.id)
        XCTAssertEqual(Array(order.prefix(2)), ["aaa-chat", "google/gemma-4-e4b"])
        XCTAssertEqual(order.last, "text-embedding-nomic")
    }

    /// Ни один список ничего не теряет: порядок — не фильтр. Модель
    /// с неверно определённым типом обязана остаться доступной, иначе
    /// исправить положение будет нечем.
    func testNothingIsDroppedFromEitherPicker() {
        for preferred in [LMStudioModelKind.chat, .reranking] {
            let order = ModelPickerOrder.sorted(library, preferring: preferred)
            XCTAssertEqual(Set(order.map(\.id)), Set(library.map(\.id)))
            XCTAssertEqual(order.count, library.count)
        }
    }

    /// Внутри группы — по идентификатору, чтобы список не переставлялся сам
    /// собой между обновлениями.
    func testTheOrderInsideAGroupIsStable() {
        let first = ModelPickerOrder.sorted(library, preferring: .reranking).map(\.id)
        let again = ModelPickerOrder.sorted(library.reversed(), preferring: .reranking).map(\.id)
        XCTAssertEqual(first, again)
    }

    /// В таблице — группировка по типу, а не «нужное сверху»: это перечень
    /// установленного.
    func testTheTableGroupsByKind() {
        let order = ModelPickerOrder.tableSorted(library).map(\.id)
        XCTAssertEqual(order.first, "text-embedding-nomic")
        XCTAssertEqual(
            Array(order.dropFirst().prefix(2)),
            ["jina-reranker-v3.5-mlx", "qwen3-reranker-0.6b"]
        )
    }
}
