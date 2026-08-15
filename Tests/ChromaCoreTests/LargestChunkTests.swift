import XCTest
@testable import ChromaCore

/// До какой длины дорастает чанк при этих настройках.
///
/// От этого числа зависит предупреждение в форме: «больше, чем модель
/// читает» — или молчание. Ошибка тут не видна ничем: предупреждение
/// не появится там, где нужно, и человек узнает о пределе из пропущенного
/// файла посреди прогона.
final class LargestChunkTests: XCTestCase {
    private func configuration(_ strategy: ChunkStrategy) -> ChunkingConfiguration {
        var configuration = ChunkingConfiguration(strategy: strategy)
        configuration.sizeUnit = .characters
        return configuration
    }

    func testEachStrategyIsMeasuredByItsOwnSetting() {
        var fixed = configuration(.fixed)
        fixed.chunkSize = 900
        XCTAssertEqual(fixed.largestChunkCharacters, 900)

        var recursive = configuration(.recursive)
        recursive.chunkSize = 1200
        XCTAssertEqual(recursive.largestChunkCharacters, 1200)

        var semantic = configuration(.semantic)
        semantic.maxChunkSize = 4096
        XCTAssertEqual(semantic.largestChunkCharacters, 4096)

        var adaptive = configuration(.adaptive)
        adaptive.maxChunkSize = 3000
        XCTAssertEqual(adaptive.largestChunkCharacters, 3000)

        // Родитель крупнее ребёнка по построению — по нему и считается.
        var hierarchical = configuration(.hierarchical)
        hierarchical.parentChunkSize = 8000
        hierarchical.childChunkSize = 512
        XCTAssertEqual(hierarchical.largestChunkCharacters, 8000)
    }

    /// Document-based: с откатом предел есть, без отката — нет.
    func testDocumentBasedDependsOnTheOversizedFallback() {
        var configuration = configuration(.documentBased)
        configuration.maxSectionSize = 5000

        configuration.oversizedFallback = .recursive
        XCTAssertEqual(configuration.largestChunkCharacters, 5000)

        configuration.oversizedFallback = .fixed
        XCTAssertEqual(configuration.largestChunkCharacters, 5000)

        // «Не делить» — сколько нашлось между заголовками, столько и уйдёт
        // в модель; обещать тут число нельзя.
        configuration.oversizedFallback = .keep
        XCTAssertNil(configuration.largestChunkCharacters)
    }

    /// LLM-based: границы расставляет чат-модель, и предел ей не задан ничем.
    func testTheLLMStrategyPromisesNothing() {
        XCTAssertNil(configuration(.llmBased).largestChunkCharacters)
    }

    /// Единица измерения учитывается: «токены» в форме — это знаки в модели.
    func testTokensAreConvertedToCharacters() {
        var configuration = ChunkingConfiguration(strategy: .fixed)
        configuration.sizeUnit = .tokens
        configuration.chunkSize = 512
        XCTAssertEqual(
            configuration.largestChunkCharacters,
            TokenEstimator.characters(forTokens: 512)
        )
    }

    /// Заводские настройки не должны упираться в предел самой скромной
    /// модели: 512 токенов — это меньше, чем читает что угодно.
    func testTheFactoryDefaultIsWellUnderAnyModel() throws {
        let largest = try XCTUnwrap(ChunkingConfiguration().largestChunkCharacters)
        XCTAssertLessThan(largest, EmbeddingInputProbe.suspiciousCharacters)
    }
}
