import XCTest
@testable import ChromaCore

/// сверка с документацией серверов: ChromaDB и LM Studio.
final class ServerContractTests: XCTestCase {
    /// Список в метаданных (ChromaDB 1.x, схема `HashMap`) читается списком
    /// и записывается обратно списком, а не строкой `<unsupported>`.
    func testAMetadataListSurvivesARoundTrip() throws {
        let json = Data(#"{"tags": ["закупка", "облако"], "years": [2026, 2027], "n": 3}"#.utf8)
        let metadata = try JSONDecoder().decode(ChromaMetadata.self, from: json)
        XCTAssertEqual(metadata["tags"], .list([.string("закупка"), .string("облако")]))
        XCTAssertEqual(metadata["years"], .list([.int(2026), .int(2027)]))
        XCTAssertEqual(metadata["tags"]?.displayString, "[закупка, облако]")

        let encoded = try JSONEncoder().encode(metadata)
        let back = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertEqual(back?["tags"] as? [String], ["закупка", "облако"])
        XCTAssertEqual(back?["years"] as? [Int], [2026, 2027])
    }

    /// `GET /api/v1/models` — родной REST API LM Studio 0.4: ключ модели,
    /// тип, потолок контекста и контекст загруженного экземпляра.
    func testLMStudioV1ModelsAreRead() throws {
        let json = Data("""
        {"models": [
          {"type": "llm", "key": "qwen/qwen3-4b", "max_context_length": 262144,
           "loaded_instances": [{"id": "qwen/qwen3-4b", "config": {"context_length": 4096}}]},
          {"type": "embedding", "key": "text-embedding-qwen3-embedding-0.6b",
           "max_context_length": 32768, "loaded_instances": []}
        ]}
        """.utf8)
        let models = try LMStudioClient.decodeV1Models(json)
        XCTAssertEqual(models.map(\.id), ["qwen/qwen3-4b", "text-embedding-qwen3-embedding-0.6b"])
        XCTAssertEqual(models[0].kind, .chat)
        XCTAssertEqual(models[0].loadedContextLength, 4096)
        XCTAssertEqual(models[0].contextLength, 262144)
        XCTAssertEqual(models[1].kind, .embedding)
        XCTAssertNil(models[1].loadedContextLength, "незагруженная модель загруженного контекста не имеет")
    }
}
