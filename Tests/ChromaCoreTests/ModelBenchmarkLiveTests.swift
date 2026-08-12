import XCTest
@testable import ChromaCore

/// F3 against a real LM Studio. Skipped unless asked for, like every other live
/// check here: the suite must stay runnable with nothing installed.
///
///     CDBM_LIVE_LMSTUDIO=http://localhost:1234 \
///     CDBM_LIVE_EMBEDDING_MODEL=text-embedding-qwen3-embedding-0.6b \
///     swift test --filter ModelBenchmarkLiveTests
final class ModelBenchmarkLiveTests: XCTestCase {
    private func liveClient() throws -> (LMStudioClient, String) {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CDBM_LIVE_LMSTUDIO"],
              let model = environment["CDBM_LIVE_EMBEDDING_MODEL"] else {
            throw XCTSkip("живая проверка: задайте CDBM_LIVE_LMSTUDIO и CDBM_LIVE_EMBEDDING_MODEL")
        }
        // No cache is passed on purpose: the benchmark must reach the model.
        return (try LMStudioClient(baseURLString: base), model)
    }

    func testAMeasurementAgainstALiveModel() async throws {
        let (client, model) = try liveClient()
        let service = ModelBenchmarkService(provider: client, log: { level, category, message in
            print("[\(level)] \(category): \(message)")
        })

        let started = Date()
        let result = try await service.run(model: model) { fraction, detail in
            print(String(format: "  %3.0f%% — %@", fraction * 100, detail))
        }
        let wall = Date().timeIntervalSince(started)

        print("""

        модель:       \(result.model)
        размерность:  \(result.dimension)
        первый вызов: \(String(format: "%.3f", result.firstCallSeconds)) с
        лучший батч:  \(result.optimalBatchSize ?? 0)
        текстов/с:    \(String(format: "%.1f", result.textsPerSecond))
        с/текст:      \(String(format: "%.4f", result.secondsPerText))
        всего:        \(String(format: "%.1f", wall)) с
        """)
        for batch in result.batches {
            print("  батч \(batch.batchSize): \(String(format: "%.3f", batch.seconds)) с → \(String(format: "%.1f", batch.textsPerSecond)) текстов/с")
        }

        XCTAssertGreaterThan(result.dimension, 0)
        XCTAssertGreaterThan(result.textsPerSecond, 0)
        XCTAssertGreaterThan(result.firstCallSeconds, 0)
        XCTAssertEqual(result.batches.count, BenchmarkCorpus.batchSizes.count)

        // What the run unblocks: an estimate for a model with no history.
        let plan = SyncPlan(
            sourceID: UUID(), sourceName: "live",
            items: [SyncPlanItem(
                relativePath: "a.txt", url: URL(fileURLWithPath: "/tmp/a.txt"), kind: .new,
                collectionName: "c", size: 50_000, modifiedAt: Date(),
                contentHash: "h", textLength: 50_000
            )],
            newlyMissing: [], pendingRemovals: []
        )
        let chunking = ChunkingConfiguration(strategy: .fixed, chunkSize: 1000, sizeUnit: .characters, overlapPercent: 0)
        XCTAssertNil(
            plan.estimatedDuration(chunking: chunking, embeddingModel: model, metrics: MetricsSnapshot()),
            "без измерений оценка молчит"
        )
        let estimate = plan.estimatedDuration(
            chunking: chunking, embeddingModel: model,
            metrics: MetricsSnapshot(), benchmarks: [result]
        )
        print("оценка на 50 000 символов: \(String(format: "%.1f", estimate?.embeddingSeconds ?? 0)) с")
        XCTAssertNotNil(estimate?.embeddingSeconds)
    }

    /// The measurement must reach the model even when the same texts have just
    /// been embedded: a cached benchmark reports a model that is infinitely fast.
    func testTheBenchmarkIsNotServedByTheCache() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["CDBM_LIVE_LMSTUDIO"],
              let model = environment["CDBM_LIVE_EMBEDDING_MODEL"] else {
            throw XCTSkip("живая проверка: задайте CDBM_LIVE_LMSTUDIO и CDBM_LIVE_EMBEDDING_MODEL")
        }
        let cacheFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("bench-cache-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: cacheFile) }

        let cache = EmbeddingCache(fileURL: cacheFile)
        await cache.open()
        let client = try LMStudioClient(baseURLString: base, cache: cache)

        // Warm the cache with the very texts the benchmark uses.
        let texts = Array(BenchmarkCorpus.allTexts.prefix(4))
        _ = try await client.embed(texts: texts, model: model)
        let warmed = await cache.statistics()
        XCTAssertGreaterThan(warmed.entries, 0, "кэш действительно наполнен")

        let before = await cache.statistics()
        let started = Date()
        _ = try await client.embedIgnoringCache(texts: texts, model: model)
        let elapsed = Date().timeIntervalSince(started)
        let after = await cache.statistics()

        XCTAssertEqual(after.hits, before.hits, "измерение не должно засчитываться как попадание в кэш")
        print("повторный вызов мимо кэша занял \(String(format: "%.3f", elapsed)) с — то есть модель действительно вызывалась")
    }
}
