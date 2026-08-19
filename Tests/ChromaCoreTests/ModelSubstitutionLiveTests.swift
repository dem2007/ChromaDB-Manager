import XCTest
@testable import ChromaCore

/// Подмена модели — против настоящей LM Studio.
///
/// Пропускается, пока не попросили, как и остальные живые проверки. Смысл
/// её в том, что поведение, ради которого написана защита, нельзя вычитать
/// из документации: LM Studio нигде не обещает подменять модель молча, это
/// измерено.
///
///     CDBM_LIVE_LMSTUDIO=http://localhost:1234 \
///     CDBM_LIVE_UNSERVED_MODEL=bge-m3-mlx \
///     CDBM_LIVE_EMBEDDING_MODEL=text-embedding-qwen3-embedding-4b \
///     swift test --filter ModelSubstitutionLiveTests
final class ModelSubstitutionLiveTests: XCTestCase {

    private func live() throws -> (LMStudioClient, unserved: String, served: String) {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CDBM_LIVE_LMSTUDIO"],
              let unserved = environment["CDBM_LIVE_UNSERVED_MODEL"],
              let served = environment["CDBM_LIVE_EMBEDDING_MODEL"] else {
            throw XCTSkip("живая проверка: задайте CDBM_LIVE_LMSTUDIO, CDBM_LIVE_UNSERVED_MODEL и CDBM_LIVE_EMBEDDING_MODEL")
        }
        return (try LMStudioClient(baseURLString: base), unserved, served)
    }

    /// Модель, которую LM Studio не подаёт на эмбеддинги, обязана дать
    /// остановку с именами обеих сторон — а не чужой вектор.
    func testAModelLMStudioWillNotServeIsCaught() async throws {
        let (client, unserved, served) = try live()
        // Сначала загружаем ту, что подменит: без единой загруженной модели
        // LM Studio отвечает честной ошибкой, и проверять было бы нечего.
        _ = try await client.embedIgnoringCache(texts: ["разогрев"], model: served)

        do {
            _ = try await client.embedIgnoringCache(texts: ["проверка"], model: unserved)
            XCTFail("LM Studio подала «\(unserved)» на эмбеддинги — проверьте, та ли это модель")
        } catch let error as LMStudioError {
            guard case .modelSubstituted(let requested, let returned) = error else {
                throw XCTSkip("LM Studio ответила иначе: \(error.errorDescription ?? "\(error)")")
            }
            XCTAssertEqual(requested, unserved)
            XCTAssertNotEqual(returned, unserved)
            print("подмена поймана: просили \(requested), ответила \(returned)")
        }
    }

    /// И обратное: у модели, которую LM Studio действительно подаёт,
    /// проверка молчит. Иначе защита стоила бы дороже, чем стережёт.
    func testTheServedModelPassesWithoutComplaint() async throws {
        let (client, _, served) = try live()
        let vectors = try await client.embedIgnoringCache(texts: ["проверка"], model: served)
        XCTAssertEqual(vectors.count, 1)
        XCTAssertFalse(vectors[0].isEmpty)
    }
}
