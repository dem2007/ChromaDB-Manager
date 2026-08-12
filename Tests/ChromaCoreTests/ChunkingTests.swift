import XCTest
@testable import ChromaCore

final class ChunkingTests: XCTestCase {
    func testFixedSizeSplitsWithOverlap() {
        let text = String(repeating: "a", count: 250)
        let chunks = FixedSizeChunker(size: 100, overlap: 20).chunks(from: text)

        // step = size - overlap = 80 → windows at 0…100, 80…180, 160…250
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].text.count, 100)
        XCTAssertEqual(chunks.last?.text.count, 90)
        XCTAssertEqual(chunks.map(\.index), [0, 1, 2])
    }

    func testFixedSizeKeepsShortTextIntact() {
        let chunks = FixedSizeChunker(size: 100, overlap: 10).chunks(from: "короткий текст")
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.text, "короткий текст")
    }

    func testFixedSizeClampsOverlapBelowSize() {
        // An overlap >= size would make the window never advance.
        let chunker = FixedSizeChunker(size: 50, overlap: 500)
        XCTAssertLessThan(chunker.overlap, chunker.size)
        let chunks = chunker.chunks(from: String(repeating: "b", count: 500))
        XCTAssertFalse(chunks.isEmpty)
    }

    func testRecursiveRespectsMaximumSize() {
        let paragraph = String(repeating: "предложение. ", count: 40)
        let text = [paragraph, paragraph, paragraph].joined(separator: "\n\n")
        let chunks = RecursiveChunker(size: 200, overlap: 20, separators: ["\n\n", "\n", ". ", " "])
            .chunks(from: text)

        XCTAssertFalse(chunks.isEmpty)
        for chunk in chunks {
            // Overlap is prepended to a chunk, so the bound is size + overlap.
            XCTAssertLessThanOrEqual(chunk.text.count, 220)
            XCTAssertFalse(chunk.text.isEmpty)
        }
    }

    func testRecursivePrefersParagraphBoundaries() {
        let text = "Первый абзац.\n\nВторой абзац.\n\nТретий абзац."
        let chunks = RecursiveChunker(size: 20, overlap: 0, separators: ["\n\n", "\n", ". ", " "])
            .chunks(from: text)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertTrue(chunks[0].text.hasPrefix("Первый"))
        XCTAssertTrue(chunks[1].text.hasPrefix("Второй"))
    }

    func testRecursiveHandlesTextWithoutSeparators() {
        let text = String(repeating: "x", count: 500)
        let chunks = RecursiveChunker(size: 100, overlap: 0, separators: ["\n\n", "\n"]).chunks(from: text)
        XCTAssertEqual(chunks.count, 5)
    }

    func testEmptyInputProducesNoChunks() {
        XCTAssertTrue(RecursiveChunker(size: 100, overlap: 10, separators: ["\n"]).chunks(from: "   \n  ").isEmpty)
        XCTAssertTrue(FixedSizeChunker(size: 100, overlap: 10).chunks(from: "").isEmpty)
    }

    func testConfigurationConvertsTokensToCharacters() {
        var configuration = ChunkingConfiguration(strategy: .fixed, chunkSize: 100, sizeUnit: .tokens, overlapPercent: 10)
        XCTAssertEqual(configuration.chunkSizeInCharacters, TokenEstimator.characters(forTokens: 100))
        XCTAssertEqual(configuration.overlapInCharacters, Int((Double(configuration.chunkSizeInCharacters) * 0.1).rounded()))

        configuration.sizeUnit = .characters
        XCTAssertEqual(configuration.chunkSizeInCharacters, 100)
    }

    func testConfigurationClampsOverlapPercent() {
        let configuration = ChunkingConfiguration(chunkSize: 100, sizeUnit: .characters, overlapPercent: 500)
        XCTAssertLessThan(configuration.overlapInCharacters, configuration.chunkSizeInCharacters)
    }

    func testFactoryBuildsRequestedStrategy() {
        XCTAssertTrue(ChunkerFactory.make(ChunkingConfiguration(strategy: .fixed)) is FixedSizeChunker)
        XCTAssertTrue(ChunkerFactory.make(ChunkingConfiguration(strategy: .recursive)) is RecursiveChunker)
    }

    func testTokenEstimatorRoundTrip() {
        XCTAssertEqual(TokenEstimator.estimatedTokens(""), 0)
        XCTAssertEqual(TokenEstimator.characters(forTokens: 10), 35)
        XCTAssertEqual(TokenEstimator.estimatedTokens(String(repeating: "a", count: 35)), 10)
    }
}
