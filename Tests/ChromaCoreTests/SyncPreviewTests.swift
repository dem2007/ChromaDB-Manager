import XCTest
@testable import ChromaCore

// MARK: - J2: chunk-count estimate

final class ChunkCountEstimateTests: XCTestCase {
    func testFixedStrategyDividesByStepSize() {
        var config = ChunkingConfiguration(strategy: .fixed, chunkSize: 100, sizeUnit: .characters, overlapPercent: 0)
        XCTAssertEqual(config.estimatedChunkCount(forCharacters: 1000), 10)

        // Overlap shortens the effective step, so more chunks are needed.
        config.overlapPercent = 50
        XCTAssertEqual(config.estimatedChunkCount(forCharacters: 1000), 20)
    }

    func testZeroCharactersIsZeroChunks() {
        let config = ChunkingConfiguration(strategy: .fixed, chunkSize: 100, sizeUnit: .characters)
        XCTAssertEqual(config.estimatedChunkCount(forCharacters: 0), 0)
    }

    func testAtLeastOneChunkForAnyNonEmptyText() {
        let config = ChunkingConfiguration(strategy: .fixed, chunkSize: 10_000, sizeUnit: .characters)
        XCTAssertEqual(config.estimatedChunkCount(forCharacters: 5), 1)
    }

    func testHierarchicalCountsBothParentsAndChildren() {
        var config = ChunkingConfiguration(strategy: .hierarchical, sizeUnit: .characters)
        config.parentChunkSize = 1000
        config.childChunkSize = 200
        // 2000 characters: ~2 parents + ~10 children.
        let count = config.estimatedChunkCount(forCharacters: 2000)
        XCTAssertEqual(count, 2 + 10)
    }
}

// MARK: - J2: plan-level estimate (chunk count + duration)

final class SyncPlanEstimateTests: XCTestCase {
    private var root: URL!
    private var service: SourceSyncService!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cdbm-j2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        service = SourceSyncService(manifests: ManifestStore(directory: root.appendingPathComponent("manifests")))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var folder: URL { root.appendingPathComponent("docs") }

    private func makeSource(chunkSize: Int = 100) -> DataSource {
        DataSource(
            name: "docs", path: folder.path, fileExtensions: ["md"], recursive: true, collectionName: "docs_col",
            chunking: ChunkingConfiguration(strategy: .fixed, chunkSize: chunkSize, sizeUnit: .characters, overlapPercent: 0)
        )
    }

    private func write(_ text: String, _ name: String) throws {
        try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// The estimate uses the extracted text length captured in the plan
    /// (`SyncPlanItem.textLength`), not the raw file size — this is the check
    /// that the plumbing is actually wired, not just present.
    func testEstimateUsesExtractedTextLengthNotFileSize() async throws {
        let text = String(repeating: "a", count: 950)
        try write(text, "a.md")
        let source = makeSource(chunkSize: 100)

        let plan = try await service.plan(source: source, embeddingModel: "m")
        XCTAssertEqual(plan.writeItems.first?.textLength, 950)
        // ceil(950 / 100) = 10
        XCTAssertEqual(plan.estimatedChunkCount(chunking: source.chunking), 10)
    }

    func testEstimateSumsAcrossMultipleFiles() async throws {
        try write(String(repeating: "a", count: 100), "a.md")
        try write(String(repeating: "b", count: 250), "b.md")
        let source = makeSource(chunkSize: 100)

        let plan = try await service.plan(source: source, embeddingModel: "m")
        // ceil(100/100) + ceil(250/100) = 1 + 3
        XCTAssertEqual(plan.estimatedChunkCount(chunking: source.chunking), 4)
    }

    /// Rule 4, Приложение 5: no guessed numbers — a strategy/model with no
    /// recorded runs contributes nothing, and no data at all means `nil`.
    func testNoHistoryMeansNoTimeEstimate() async throws {
        try write("текст документа побольше десяти символов", "a.md")
        let source = makeSource()
        let plan = try await service.plan(source: source, embeddingModel: "m")

        let estimate = plan.estimatedDuration(chunking: source.chunking, embeddingModel: "m", metrics: MetricsSnapshot())
        XCTAssertNil(estimate)
    }

    func testHistoryProducesATimeEstimate() async throws {
        try write(String(repeating: "текст. ", count: 50), "a.md")
        let source = makeSource(chunkSize: 100)
        let plan = try await service.plan(source: source, embeddingModel: "m")

        // 1000 characters/second chunking, 0.5 s per chunk embedding.
        let metrics = MetricsSnapshot(
            models: [.init(model: "m", texts: 10, seconds: 5)],
            strategies: [.init(strategy: .fixed, runs: 1, characters: 1000, seconds: 1)]
        )
        let estimate = try XCTUnwrap(plan.estimatedDuration(chunking: source.chunking, embeddingModel: "m", metrics: metrics))
        XCTAssertNotNil(estimate.chunkingSeconds)
        XCTAssertNotNil(estimate.embeddingSeconds)
        XCTAssertNotNil(estimate.totalSeconds)
    }

    /// The threshold reads exactly as the UI states it: «показывать план, если
    /// файлов больше N». Zero therefore means every run that writes anything,
    /// not «выключено» — it was special-cased as off, so the setting said one
    /// thing and did the opposite (found in live testing).
    func testZeroThresholdStopsEveryRunThatWritesAnything() async throws {
        try write("текст один", "a.md")
        try write("текст два", "b.md")
        let source = makeSource()
        let plan = try await service.plan(source: source, embeddingModel: "m")

        XCTAssertEqual(plan.writeItems.count, 2)
        XCTAssertTrue(plan.needsConfirmation(threshold: 0), "порог 0 — подтверждать всегда")
        XCTAssertTrue(plan.needsConfirmation(threshold: 1))
        XCTAssertFalse(plan.needsConfirmation(threshold: 2), "ровно по порогу — ещё не «больше»")
        XCTAssertFalse(plan.needsConfirmation(threshold: 100))
    }

    /// Nothing to write means nothing to confirm, whatever the threshold says.
    func testAnEmptyRunNeverAsksForConfirmation() async throws {
        let source = makeSource()
        let plan = try await service.plan(source: source, embeddingModel: "m")
        XCTAssertFalse(plan.hasWork)
        XCTAssertFalse(plan.needsConfirmation(threshold: 0))
    }

    /// A plan with nothing to write has nothing to estimate, not a zero.
    func testNoWorkMeansNoEstimateEitherWayNilOrZero() async throws {
        let source = makeSource()
        let plan = try await service.plan(source: source, embeddingModel: "m")
        XCTAssertFalse(plan.hasWork)
        XCTAssertNil(plan.estimatedDuration(
            chunking: source.chunking, embeddingModel: "m",
            metrics: MetricsSnapshot(models: [.init(model: "m", texts: 1, seconds: 1)])
        ))
    }
}

// MARK: - J2: excluding files from a run

final class SyncExclusionTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var manifests: ManifestStore!
    private var source: DataSource!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cdbm-j2-excl-\(UUID().uuidString)")
        folder = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        manifests = ManifestStore(directory: root.appendingPathComponent("manifests"))
        source = DataSource(
            name: "docs", path: folder.path, fileExtensions: ["md"], recursive: true,
            mapping: .singleCollectionWithRelativePath, collectionName: "docs_col",
            chunking: ChunkingConfiguration(strategy: .fixed, chunkSize: 40, sizeUnit: .characters, overlapPercent: 0)
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, _ name: String) throws {
        try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func makeService() -> SourceSyncService { SourceSyncService(manifests: manifests) }

    /// The point of the "uncheck a file" half of J2: it must not be written,
    /// and the manifest must not learn about it either, so the next plan still
    /// offers it — excluding a file is "not now", not "pretend it is done".
    func testExcludedFileIsNeitherWrittenNorMarkedDone() async throws {
        try write(String(repeating: "keep me. ", count: 10), "keep.md")
        try write(String(repeating: "skip me. ", count: 10), "skip.md")
        let service = makeService()
        let database = FailingDatabase()

        let summary = try await service.sync(
            source: source, embeddingModel: "m", chroma: database, embeddings: CountingEmbeddings(),
            binding: ModelBindingService(), excludedPaths: ["skip.md"], progress: { _ in }
        )

        XCTAssertEqual(summary.added, 1, "только keep.md должен быть записан")
        let written = await database.documents(in: "docs_col")
        XCTAssertTrue(written.values.contains { $0.contains("keep me") })
        XCTAssertFalse(written.values.contains { $0.contains("skip me") })

        XCTAssertTrue(
            summary.skipped.contains { $0.file == "skip.md" },
            "исключённый файл должен быть виден в отчёте, а не тихо пропущен"
        )

        // The manifest must still consider skip.md unsynced, so a plain sync
        // (no exclusions) picks it up next time.
        let nextPlan = try await service.plan(source: source, embeddingModel: "m")
        XCTAssertTrue(nextPlan.writeItems.contains { $0.relativePath == "skip.md" })
        XCTAssertFalse(nextPlan.writeItems.contains { $0.relativePath == "keep.md" })
    }

    /// Excluding everything must behave exactly like "nothing to do" — no
    /// collection creation, no dimension probe, same summary shape as an
    /// ordinary no-op run.
    func testExcludingEverythingIsAClearNoOp() async throws {
        try write("текст один", "a.md")
        try write("текст два", "b.md")
        let service = makeService()
        let database = FailingDatabase()

        let summary = try await service.sync(
            source: source, embeddingModel: "m", chroma: database, embeddings: CountingEmbeddings(),
            binding: ModelBindingService(), excludedPaths: ["a.md", "b.md"], progress: { _ in }
        )

        XCTAssertEqual(summary.added, 0)
        XCTAssertEqual(summary.updated, 0)
        XCTAssertEqual(summary.skipped.count, 2)
        let written = await database.documents(in: "docs_col")
        XCTAssertTrue(written.isEmpty)
    }

    /// Without any exclusion, behaviour is exactly what it was before J2 —
    /// the new parameter defaults to an empty set.
    func testNoExclusionsMeansTheOldBehaviour() async throws {
        try write(String(repeating: "текст документа. ", count: 5), "a.md")
        let service = makeService()
        let database = FailingDatabase()

        let summary = try await service.sync(
            source: source, embeddingModel: "m", chroma: database, embeddings: CountingEmbeddings(),
            binding: ModelBindingService(), progress: { _ in }
        )
        XCTAssertEqual(summary.added, 1)
        XCTAssertTrue(summary.skipped.isEmpty)
    }
}

// MARK: - J2: configurable threshold

final class SyncPreviewThresholdConfigTests: XCTestCase {
    func testDefaultMatchesTheSpecNumber() {
        XCTAssertEqual(SourceSyncService.defaultPreviewThresholdFiles, 100)
        XCTAssertEqual(AppConfiguration().syncPreviewThresholdFiles, 100)
    }

    /// The tolerant-decoding guarantee: a config written before this field
    /// existed must not fail to load, just fall back (same as every other
    /// field in `AppConfiguration.init(from:)`).
    func testAnOlderConfigWithoutTheFieldFallsBackToTheDefault() throws {
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.syncPreviewThresholdFiles, SourceSyncService.defaultPreviewThresholdFiles)
    }
}
