import XCTest
@testable import ChromaCore

/// the recipe that shaped a collection's chunks is recorded, versioned, and
/// its change is reported instead of acted upon.
final class StrategyParamsHashTests: XCTestCase {
    private func fixed(size: Int = 400) -> ChunkingConfiguration {
        ChunkingConfiguration(strategy: .fixed, chunkSize: size, sizeUnit: .characters, overlapPercent: 10)
    }

    // MARK: - The digest itself

    func testTheSameRecipeGivesTheSameDigest() {
        XCTAssertEqual(StrategyParamsHash.of(fixed()), StrategyParamsHash.of(fixed()))
    }

    func testADifferentChunkSizeIsADifferentRecipe() {
        XCTAssertNotEqual(StrategyParamsHash.of(fixed(size: 400)), StrategyParamsHash.of(fixed(size: 500)))
    }

    /// G6 names these explicitly: generation parameters shape the boundaries,
    /// so they belong to the identity of the collection.
    func testTemperatureAndPromptAreInsideTheDigest() {
        let base = ChunkingConfiguration(
            strategy: .llmBased, chatModel: "qwen", promptTemplate: "Раздели текст.",
            generation: ChatGenerationSettings(temperature: 0)
        )
        var warmer = base
        warmer.temperature = 0.7
        var reworded = base
        reworded.promptTemplate = "Раздели текст по смыслу."

        XCTAssertNotEqual(StrategyParamsHash.of(base), StrategyParamsHash.of(warmer))
        XCTAssertNotEqual(StrategyParamsHash.of(base), StrategyParamsHash.of(reworded))
    }

    func testTemperatureIsZeroByDefault() {
        // a re-run has to produce the same collection.
        XCTAssertEqual(ChunkingConfiguration(strategy: .llmBased).temperature, 0)
    }

    // MARK: - The stored form

    func testTheVersionTravelsWithTheValue() {
        let hash = StrategyParamsHash.of(fixed())
        XCTAssertTrue(hash.stored.hasPrefix("v\(StrategyParamsHash.currentSchemaVersion):"))
        XCTAssertEqual(StrategyParamsHash.parse(hash.stored), hash)
    }

    func testGarbageIsNotMistakenForAHash() {
        XCTAssertNil(StrategyParamsHash.parse("fixed/400c/ov10"))
        XCTAssertNil(StrategyParamsHash.parse("v:"))
        XCTAssertNil(StrategyParamsHash.parse("vX:abc"))
        XCTAssertNil(StrategyParamsHash.parse(nil as String?))
    }

    func testItIsReadFromCollectionMetadata() {
        let hash = StrategyParamsHash.of(fixed())
        let metadata: ChromaMetadata = [CollectionBindingKeys.strategyParamsHash: hash.value]
        XCTAssertEqual(StrategyParamsHash.parse(metadata), hash)
        // The readable predecessor is not a hash and must not be read as one.
        XCTAssertNil(StrategyParamsHash.parse([CollectionBindingKeys.legacyChunking: .string("fixed/400c/ov10")]))
    }

    // MARK: - Comparison

    func testAnIdenticalRecipeMatches() {
        let current = StrategyParamsHash.of(fixed())
        XCTAssertEqual(StrategyParamsHash.compare(stored: current, current: current), .matches)
    }

    func testAChangedRecipeIsReportedWithWhatWasStored() {
        let stored = StrategyParamsHash.of(fixed(size: 400))
        let current = StrategyParamsHash.of(fixed(size: 900))
        XCTAssertEqual(StrategyParamsHash.compare(stored: stored, current: current), .differs(stored: stored.digest))
    }

    func testACollectionWithoutAHashIsMigratedRatherThanAccused() {
        XCTAssertEqual(StrategyParamsHash.compare(stored: nil, current: StrategyParamsHash.of(fixed())), .migrate)
    }

    /// The reason the version exists: adding fields to the digest must not
    /// declare every existing collection heterogeneous at once.
    func testAnOlderSchemaIsMigratedAndNotCalledADifference() {
        let old = StrategyParamsHash(schemaVersion: 0, digest: "deadbeef")
        XCTAssertEqual(StrategyParamsHash.compare(stored: old, current: StrategyParamsHash.of(fixed())), .migrate)
    }
}
