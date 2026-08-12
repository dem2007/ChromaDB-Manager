import XCTest
@testable import ChromaCore

/// A clock the fake model winds forward and the service reads. Real waiting
/// would make the suite slow for nothing: what is under test is the arithmetic
/// of the measurement, not the passage of time.
private final class VirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: Double = 0

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return Date(timeIntervalSince1970: 1_000_000 + elapsed)
    }

    func advance(by seconds: Double) {
        lock.lock()
        elapsed += seconds
        lock.unlock()
    }
}

/// A model with a known cost structure: a one-off load, a fixed cost per call
/// and a fixed cost per text. Those three are exactly what the benchmark claims
/// to be able to tell apart.
private actor ClockedModel: UncachedEmbeddingProvider {
    private let clock: VirtualClock
    private let dimension: Int
    private let firstCallSeconds: Double
    private let perCallSeconds: Double
    private let perTextSeconds: Double
    private var calls: [[String]] = []

    init(
        clock: VirtualClock,
        dimension: Int = 4,
        firstCallSeconds: Double = 3,
        perCallSeconds: Double = 0.2,
        perTextSeconds: Double = 0.1
    ) {
        self.clock = clock
        self.dimension = dimension
        self.firstCallSeconds = firstCallSeconds
        self.perCallSeconds = perCallSeconds
        self.perTextSeconds = perTextSeconds
    }

    func embedIgnoringCache(texts: [String], model: String) async throws -> [[Double]] {
        let isFirst = calls.isEmpty
        calls.append(texts)
        clock.advance(by: isFirst
            ? firstCallSeconds
            : perCallSeconds + perTextSeconds * Double(texts.count))
        return texts.map { _ in Array(repeating: 0.5, count: dimension) }
    }

    func callCount() -> Int { calls.count }
    func textsSeen() -> Int { calls.reduce(0) { $0 + $1.count } }
}

/// A model that changes its dimension partway through — the one thing that
/// invalidates a measurement rather than merely skewing it.
private actor DimensionSwappingModel: UncachedEmbeddingProvider {
    private var callsMade = 0
    private let swapAfter: Int

    init(swapAfter: Int) { self.swapAfter = swapAfter }

    func embedIgnoringCache(texts: [String], model: String) async throws -> [[Double]] {
        callsMade += 1
        let dimension = callsMade > swapAfter ? 8 : 4
        return texts.map { _ in Array(repeating: 0.5, count: dimension) }
    }
}

final class ModelBenchmarkServiceTests: XCTestCase {
    private func makeService(
        firstCallSeconds: Double = 3,
        perCallSeconds: Double = 0.2,
        perTextSeconds: Double = 0.1
    ) -> (ModelBenchmarkService, ClockedModel) {
        let clock = VirtualClock()
        let model = ClockedModel(
            clock: clock,
            firstCallSeconds: firstCallSeconds,
            perCallSeconds: perCallSeconds,
            perTextSeconds: perTextSeconds
        )
        return (ModelBenchmarkService(provider: model, now: { clock.now }), model)
    }

    func testTheCorpusIsCoveredOncePerBatchSize() async throws {
        let (service, model) = makeService()

        let result = try await service.run(model: "m")

        let corpus = BenchmarkCorpus.allTexts.count
        for size in BenchmarkCorpus.batchSizes {
            let batch = try XCTUnwrap(result.batches.first { $0.batchSize == size })
            XCTAssertEqual(batch.texts, corpus, "каждый размер батча прогоняет весь корпус целиком")
        }
        // Plus the single warm-up text.
        let seen = await model.textsSeen()
        XCTAssertEqual(seen, corpus * BenchmarkCorpus.batchSizes.count + 1)
        let calls = await model.callCount()
        XCTAssertEqual(calls, BenchmarkCorpus.totalCalls, "предупреждение о длительности считает ровно столько же вызовов")
    }

    /// The number F3 asks for by name: loading the model into memory happens
    /// once and must not be smeared over the per-text average.
    func testTheFirstCallIsMeasuredApartFromEverythingElse() async throws {
        let (service, _) = makeService(firstCallSeconds: 9, perCallSeconds: 0.1, perTextSeconds: 0.01)

        let result = try await service.run(model: "m")

        XCTAssertEqual(result.firstCallSeconds, 9, accuracy: 0.001)
        for batch in result.batches {
            XCTAssertLessThan(batch.seconds, 9, "загрузка модели не попадает ни в один батч")
        }
        XCTAssertLessThan(result.secondsPerText, 1)
    }

    /// A per-call cost that does not shrink with batch size is what makes bigger
    /// batches faster — and the optimum has to come out of the measurements,
    /// not out of a preference for the largest batch.
    func testTheOptimalBatchSizeFollowsTheMeasurements() async throws {
        let (service, _) = makeService(firstCallSeconds: 1, perCallSeconds: 1, perTextSeconds: 0.01)

        let result = try await service.run(model: "m")

        XCTAssertEqual(result.optimalBatchSize, BenchmarkCorpus.batchSizes.max())
        XCTAssertGreaterThan(result.textsPerSecond, 0)
        XCTAssertEqual(result.dimension, 4)
    }

    /// The opposite machine: a model whose cost is entirely per text gains
    /// nothing from batching, and the benchmark must not claim otherwise.
    func testBatchingIsNotCreditedWhenItDoesNotHelp() async throws {
        let (service, _) = makeService(firstCallSeconds: 1, perCallSeconds: 0, perTextSeconds: 0.5)

        let result = try await service.run(model: "m")

        let throughputs = result.batches.map(\.textsPerSecond)
        let spread = (throughputs.max() ?? 0) - (throughputs.min() ?? 0)
        XCTAssertLessThan(spread, 0.01, "одинаковая скорость на всех батчах — значит батч не помогает")
    }

    func testADimensionChangeMidRunAbortsTheMeasurement() async {
        let service = ModelBenchmarkService(provider: DimensionSwappingModel(swapAfter: 2))
        do {
            _ = try await service.run(model: "m")
            XCTFail("измерение, в котором модель сменила размерность, не должно давать результат")
        } catch {
            // Any error is right here; a stored benchmark would not be.
        }
    }
}

// MARK: - The warning shown before the run (rule 4, Приложение 5)

final class BenchmarkEstimateTests: XCTestCase {
    private func sample(_ model: String, texts: Int, seconds: Double, firstCall: Double = 5) -> ModelBenchmark {
        ModelBenchmark(
            model: model, measuredAt: Date(), dimension: 4, firstCallSeconds: firstCall,
            batches: [BenchmarkBatchResult(batchSize: 4, texts: texts, seconds: seconds)]
        )
    }

    func testNothingMeasuredMeansNoNumber() {
        XCTAssertNil(ModelBenchmarkService.estimatedSeconds(
            model: "m", benchmarks: [], metrics: MetricsSnapshot()
        ))
    }

    func testAPreviousBenchmarkIsTheBasis() throws {
        let seconds = try XCTUnwrap(ModelBenchmarkService.estimatedSeconds(
            model: "m", benchmarks: [sample("m", texts: 10, seconds: 5)], metrics: MetricsSnapshot()
        ))
        XCTAssertGreaterThan(seconds, 5, "в оценку входит и загрузка модели, и сам прогон")
    }

    func testRealRunsAreUsedWhenNoBenchmarkExists() throws {
        let metrics = MetricsSnapshot(models: [
            MetricsSnapshot.ModelMetric(model: "m", texts: 100, seconds: 50),
        ])
        let seconds = try XCTUnwrap(ModelBenchmarkService.estimatedSeconds(
            model: "m", benchmarks: [], metrics: metrics
        ))
        XCTAssertGreaterThan(seconds, 0)
    }

    func testAnotherModelsNumbersAreNotBorrowed() {
        XCTAssertNil(ModelBenchmarkService.estimatedSeconds(
            model: "m", benchmarks: [sample("other", texts: 10, seconds: 5)], metrics: MetricsSnapshot()
        ))
    }
}

// MARK: - Storage

final class BenchmarkStoreTests: XCTestCase {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("benchmarks-\(UUID().uuidString).json")
    }

    private func sample(_ model: String, seconds: Double) -> ModelBenchmark {
        ModelBenchmark(
            model: model, measuredAt: Date(timeIntervalSince1970: 1_700_000_000),
            dimension: 768, firstCallSeconds: 2,
            batches: [BenchmarkBatchResult(batchSize: 8, texts: 16, seconds: seconds)]
        )
    }

    func testABenchmarkSurvivesAReload() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let store = BenchmarkStore(fileURL: file)
        await store.store(sample("m", seconds: 4))

        let reopened = BenchmarkStore(fileURL: file)
        let found = await reopened.benchmark(for: "m")
        let stored = try XCTUnwrap(found)
        XCTAssertEqual(stored.dimension, 768)
        XCTAssertEqual(stored.measuredAt.timeIntervalSince1970, 1_700_000_000, accuracy: 1)
    }

    /// Measuring again replaces rather than accumulates: the machine or the LM
    /// Studio version may have changed in between, and an average across those
    /// is a number describing nothing.
    func testMeasuringAgainReplacesRatherThanAccumulates() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let store = BenchmarkStore(fileURL: file)
        await store.store(sample("m", seconds: 4))
        await store.store(sample("m", seconds: 8))

        let all = await store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].batches[0].seconds, 8)
    }

    func testTheComparisonIsOrderedBySpeed() async {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let store = BenchmarkStore(fileURL: file)
        await store.store(sample("slow", seconds: 16))
        await store.store(sample("fast", seconds: 2))

        let order = await store.all().map(\.model)
        XCTAssertEqual(order, ["fast", "slow"])
    }
}

// MARK: - The estimate F3 exists to unblock

final class SyncEstimateWithBenchmarkTests: XCTestCase {
    private func plan() -> SyncPlan {
        SyncPlan(
            sourceID: UUID(),
            sourceName: "docs",
            items: [
                SyncPlanItem(
                    relativePath: "a.txt",
                    url: URL(fileURLWithPath: "/tmp/a.txt"),
                    kind: .new,
                    collectionName: "docs_col",
                    size: 10_000,
                    modifiedAt: Date(),
                    contentHash: "h",
                    textLength: 10_000
                ),
            ],
            newlyMissing: [],
            pendingRemovals: []
        )
    }

    private var chunking: ChunkingConfiguration {
        ChunkingConfiguration(strategy: .fixed, chunkSize: 1000, sizeUnit: .characters, overlapPercent: 0)
    }

    /// Before F3 this case was silent: no runs, no estimate. That silence is
    /// exactly the gap the benchmark closes.
    func testABenchmarkGivesAnEstimateWhereThereAreNoRunsYet() throws {
        let benchmark = ModelBenchmark(
            model: "m", measuredAt: Date(), dimension: 4, firstCallSeconds: 3,
            batches: [BenchmarkBatchResult(batchSize: 8, texts: 100, seconds: 10)]
        )
        XCTAssertNil(plan().estimatedDuration(
            chunking: chunking, embeddingModel: "m", metrics: MetricsSnapshot()
        ))
        let estimate = try XCTUnwrap(plan().estimatedDuration(
            chunking: chunking, embeddingModel: "m",
            metrics: MetricsSnapshot(), benchmarks: [benchmark]
        ))
        XCTAssertNotNil(estimate.embeddingSeconds)
    }

    /// Real work wins over the corpus: the benchmark is representative, the
    /// user's own texts are the truth.
    func testRealRunsWinOverTheBenchmark() throws {
        let metrics = MetricsSnapshot(models: [
            MetricsSnapshot.ModelMetric(model: "m", texts: 10, seconds: 10),  // 1 s per text
        ])
        let benchmark = ModelBenchmark(
            model: "m", measuredAt: Date(), dimension: 4, firstCallSeconds: 3,
            batches: [BenchmarkBatchResult(batchSize: 8, texts: 100, seconds: 1)]  // 0.01 s per text
        )
        let estimate = try XCTUnwrap(plan().estimatedDuration(
            chunking: chunking, embeddingModel: "m", metrics: metrics, benchmarks: [benchmark]
        ))
        let chunks = Double(plan().estimatedChunkCount(chunking: chunking))
        XCTAssertEqual(try XCTUnwrap(estimate.embeddingSeconds), chunks, accuracy: 0.001)
    }

    func testABenchmarkOfAnotherModelChangesNothing() {
        let benchmark = ModelBenchmark(
            model: "other", measuredAt: Date(), dimension: 4, firstCallSeconds: 3,
            batches: [BenchmarkBatchResult(batchSize: 8, texts: 100, seconds: 10)]
        )
        XCTAssertNil(plan().estimatedDuration(
            chunking: chunking, embeddingModel: "m",
            metrics: MetricsSnapshot(), benchmarks: [benchmark]
        ))
    }
}
