import XCTest
@testable import ChromaCore

final class ReembeddingRequestTests: XCTestCase {
    private func collection(name: String = "docs_col", model: String? = "old-model", dimension: Int? = 4) -> ChromaCollection {
        var metadata: ChromaMetadata = [:]
        if let model { metadata[CollectionBindingKeys.model] = .string(model) }
        if let dimension { metadata[CollectionBindingKeys.dimension] = .int(dimension) }
        return ChromaCollection(id: UUID().uuidString, name: name, metadata: metadata, dimension: dimension)
    }

    func testSuggestedNameUsesTheModelTailAndStaysValid() {
        let name = ReembeddingRequest.suggestedName(
            for: collection(name: "notes"),
            model: "text-embedding-qwen3-embedding-0.6b"
        )
        XCTAssertTrue(CollectionNaming.isValid(name), name)
        XCTAssertTrue(name.hasPrefix("notes_"), name)
        XCTAssertFalse(name.contains("/"))
    }

    func testCloneNeedsANameDifferentFromTheOriginal() {
        var request = ReembeddingRequest(
            collection: collection(),
            targetModel: "new-model",
            scenario: .clone,
            newCollectionName: "docs_col"
        )
        XCTAssertNotNil(request.problem, "клон не может называться как исходная коллекция")

        request.newCollectionName = "docs_col_new"
        XCTAssertNil(request.problem)

        request.newCollectionName = "  "
        XCTAssertNotNil(request.problem)
    }

    func testTargetModelIsRequired() {
        let request = ReembeddingRequest(
            collection: collection(),
            targetModel: "",
            scenario: .inPlace
        )
        XCTAssertNotNil(request.problem)
    }

    func testRechunkingProblemsSurfaceInTheRequest() {
        var chunking = ChunkingConfiguration(strategy: .llmBased)
        chunking.chatModel = nil
        let request = ReembeddingRequest(
            collection: collection(),
            targetModel: "new-model",
            scenario: .inPlace,
            rechunk: true,
            chunking: chunking
        )
        XCTAssertNotNil(request.problem, "LLM-based без чат-модели не должен запускаться")
    }

    func testPieceIDKeepsTheOriginalWhenNothingIsSplit() {
        // A plain re-embedding must not rename anything.
        XCTAssertEqual(ReembeddingService.pieceID(original: "doc-1", index: 0, total: 1), "doc-1")
        XCTAssertEqual(ReembeddingService.pieceID(original: "doc-1", index: 0, total: 3), "doc-1")
        XCTAssertEqual(ReembeddingService.pieceID(original: "doc-1", index: 2, total: 3), "doc-1#2")
    }
}

final class ReembeddingJournalTests: XCTestCase {
    private var fileURL: URL!
    private var journal: ReembeddingJournal!

    override func setUpWithError() throws {
        fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-journal-\(UUID().uuidString).json")
        journal = ReembeddingJournal(fileURL: fileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func entry(_ outcome: ReembeddingJournalEntry.Outcome) -> ReembeddingJournalEntry {
        ReembeddingJournalEntry(
            startedAt: Date().addingTimeInterval(-30),
            scenario: .clone,
            sourceCollection: "docs",
            resultCollection: "docs_new",
            model: "model",
            dimension: 4,
            processed: 10,
            written: 12,
            outcome: outcome,
            detail: "проверка"
        )
    }

    func testEntriesArePersistedNewestFirst() {
        journal.record(entry(.finished))
        journal.record(entry(.cancelled))

        let reloaded = ReembeddingJournal(fileURL: fileURL).load()
        XCTAssertEqual(reloaded.entries.count, 2)
        XCTAssertEqual(reloaded.entries.first?.outcome, .cancelled, "последняя операция должна быть сверху")
    }

    func testCheckpointRoundTripAndReplacement() {
        let first = ReembeddingCheckpoint(
            collectionID: "abc", collectionName: "docs", targetModel: "m",
            chunkingSignature: "", rechunk: false, doneIDs: ["a", "b"], totalIDs: 10, startedAt: Date()
        )
        journal.save(first)
        XCTAssertEqual(journal.checkpoint(for: "abc")?.processed, 2)

        var second = first
        second.doneIDs = ["a", "b", "c"]
        journal.save(second)
        XCTAssertEqual(journal.checkpoint(for: "abc")?.processed, 3, "контрольная точка должна заменяться, а не дублироваться")
        XCTAssertEqual(ReembeddingJournal(fileURL: fileURL).load().checkpoints.count, 1)

        journal.clearCheckpoint(collectionID: "abc")
        XCTAssertNil(journal.checkpoint(for: "abc"))
    }

    func testCheckpointsAndEntriesCoexist() {
        journal.record(entry(.finished))
        journal.save(ReembeddingCheckpoint(
            collectionID: "abc", collectionName: "docs", targetModel: "m",
            chunkingSignature: "", rechunk: false, doneIDs: ["a"], totalIDs: 5, startedAt: Date()
        ))
        let reloaded = ReembeddingJournal(fileURL: fileURL).load()
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.checkpoints.count, 1)
    }

    func testCorruptJournalDoesNotBlockAnything() throws {
        try "{ мусор".write(to: fileURL, atomically: true, encoding: .utf8)
        let file = ReembeddingJournal(fileURL: fileURL).load()
        XCTAssertTrue(file.entries.isEmpty)
        XCTAssertTrue(file.checkpoints.isEmpty)
    }
}

final class MetricsStoreTests: XCTestCase {
    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-metrics-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    func testEmbeddingAveragesAccumulate() async {
        let store = MetricsStore(fileURL: fileURL)
        await store.recordEmbedding(model: "m1", texts: 10, duration: 2)
        await store.recordEmbedding(model: "m1", texts: 10, duration: 4)
        await store.recordEmbedding(model: "m2", texts: 1, duration: 5)

        let snapshot = await store.current()
        let first = snapshot.models.first { $0.model == "m1" }
        XCTAssertEqual(first?.texts, 20)
        XCTAssertEqual(first?.averageSeconds ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertEqual(snapshot.models.first { $0.model == "m2" }?.averageSeconds ?? 0, 5, accuracy: 0.0001)
    }

    func testChunkingThroughputAndRuns() async {
        let store = MetricsStore(fileURL: fileURL)
        await store.recordChunking(strategy: .recursive, characters: 10_000, duration: 1)
        await store.recordChunking(strategy: .recursive, characters: 10_000, duration: 3)
        await store.recordChunking(strategy: .llmBased, characters: 1_000, duration: 30)

        let snapshot = await store.current()
        let recursive = snapshot.strategies.first { $0.strategy == .recursive }
        XCTAssertEqual(recursive?.runs, 2)
        XCTAssertEqual(recursive?.averageSeconds ?? 0, 2, accuracy: 0.0001)
        XCTAssertEqual(recursive?.throughput ?? 0, 5, accuracy: 0.0001)

        // The point of the statistics screen: LLM-based must look expensive.
        let llm = snapshot.strategies.first { $0.strategy == .llmBased }
        XCTAssertGreaterThan(llm?.averageSeconds ?? 0, recursive?.averageSeconds ?? 0)
    }

    func testZeroAndNegativeSamplesAreIgnored() async {
        let store = MetricsStore(fileURL: fileURL)
        await store.recordEmbedding(model: "m", texts: 0, duration: 1)
        await store.recordChunking(strategy: .fixed, characters: 0, duration: 1)
        let snapshot = await store.current()
        XCTAssertTrue(snapshot.isEmpty)
    }

    func testSnapshotSurvivesARestart() async throws {
        let store = MetricsStore(fileURL: fileURL)
        await store.recordEmbedding(model: "m", texts: 4, duration: 1)
        // The write is debounced; wait for it rather than reaching into internals.
        try await Task.sleep(nanoseconds: 900_000_000)

        let reopened = MetricsStore(fileURL: fileURL)
        let snapshot = await reopened.current()
        XCTAssertEqual(snapshot.models.first?.texts, 4)
    }

    func testResetClearsEverything() async {
        let store = MetricsStore(fileURL: fileURL)
        await store.recordEmbedding(model: "m", texts: 4, duration: 1)
        await store.reset()
        let snapshot = await store.current()
        XCTAssertTrue(snapshot.isEmpty)
    }
}

final class ReembeddingVerificationTests: XCTestCase {
    func testVerificationReadsAsASentence() {
        let clean = ReembeddingVerification(
            sourceDocuments: 10, resultDocuments: 10, dimension: 768,
            queryReturnedHit: true, note: nil
        )
        XCTAssertTrue(clean.isClean)
        XCTAssertTrue(clean.line.contains("768"))
        XCTAssertTrue(clean.line.contains("вернул результат"))

        let silent = ReembeddingVerification(
            sourceDocuments: 10, resultDocuments: 10, dimension: 768,
            queryReturnedHit: false, note: nil
        )
        XCTAssertFalse(silent.isClean, "коллекция, которая ничего не находит, — это неудача")

        let mismatched = ReembeddingVerification(
            sourceDocuments: 10, resultDocuments: 9, dimension: 768,
            queryReturnedHit: true, note: "число документов изменилось"
        )
        XCTAssertFalse(mismatched.isClean)
        XCTAssertTrue(mismatched.line.contains("число документов изменилось"))
    }
}
