import XCTest
import SQLite3
@testable import ChromaCore

/// the local model is the scarcest resource in the app, so the same text is
/// never embedded twice — and the cache never hands back a vector that belongs
/// to a different text or a different model.
final class EmbeddingCacheTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeCache(limitBytes: Int64 = EmbeddingCache.defaultLimitBytes) async -> EmbeddingCache {
        let cache = EmbeddingCache(
            fileURL: directory.appendingPathComponent("cache.sqlite3"),
            limitBytes: limitBytes
        )
        await cache.open()
        return cache
    }

    private func vector(_ seed: Double, dimension: Int = 8) -> [Double] {
        (0..<dimension).map { Double($0) * seed }
    }

    // MARK: - Keys

    func testTheKeyIsTheModelAndTheTextTogether() {
        let a = EmbeddingCache.key(model: "nomic", text: "текст")
        XCTAssertNotEqual(a, EmbeddingCache.key(model: "qwen", text: "текст"))
        XCTAssertNotEqual(a, EmbeddingCache.key(model: "nomic", text: "другой текст"))
        XCTAssertEqual(a, EmbeddingCache.key(model: "nomic", text: "текст"))
    }

    /// Line endings and trailing spaces only. Anything more would hand back the
    /// vector of a *different* text.
    func testNormalisationTouchesLineEndingsAndTrailingSpacesOnly() {
        XCTAssertEqual(
            EmbeddingCache.key(model: "m", text: "первая\r\nвторая   "),
            EmbeddingCache.key(model: "m", text: "первая\nвторая")
        )
        // Case, inner spacing and punctuation are part of the text.
        XCTAssertNotEqual(
            EmbeddingCache.key(model: "m", text: "текст  здесь"),
            EmbeddingCache.key(model: "m", text: "текст здесь")
        )
        XCTAssertNotEqual(
            EmbeddingCache.key(model: "m", text: "Текст"),
            EmbeddingCache.key(model: "m", text: "текст")
        )
    }

    // MARK: - Storage

    /// Vectors from a live model round-trip exactly: LM Studio returns float32
    /// values, verified against two models.
    func testAVectorFromAModelComesBackUnchanged() async {
        let cache = await makeCache()
        let original = [-0.05068928003311157, 0.25, -0.5, 1.0].map { Double(Float($0)) }
        await cache.store(model: "m", text: "текст", vector: original)

        let restored = await cache.vector(model: "m", text: "текст")
        XCTAssertEqual(restored, original)
    }

    /// A value that is *not* float32 is rounded to float32 — the price of
    /// halving the file. Stated here so nobody discovers it in a diff later.
    func testANonFloat32ValueIsRoundedToFloat32() {
        let restored = EmbeddingCache.decode(EmbeddingCache.encode([0.1]))
        XCTAssertEqual(restored?.first, Double(Float(0.1)))
        XCTAssertNotEqual(restored?.first, 0.1)
    }

    /// the models this app talks to return float32 values, so the binary
    /// form loses nothing — «выключение кэша не меняет результатов».
    func testTheBinaryFormIsLosslessForFloat32Values() {
        let values = (0..<256).map { Double(Float(Double($0) * 0.0137 - 1.7)) }
        let restored = EmbeddingCache.decode(EmbeddingCache.encode(values))
        XCTAssertEqual(restored, values)
    }

    func testAnEmptyVectorIsNotStored() async {
        let cache = await makeCache()
        await cache.store(model: "m", text: "текст", vector: [])
        let statistics = await cache.statistics()
        XCTAssertEqual(statistics.entries, 0)
    }

    // MARK: - What the cache is for

    func testTheSameTextAndModelIsAHit() async {
        let cache = await makeCache()
        await cache.store(model: "m", text: "текст", vector: vector(1))
        _ = await cache.vector(model: "m", text: "текст")
        let statistics = await cache.statistics()
        XCTAssertEqual(statistics.hits, 1)
        XCTAssertEqual(statistics.misses, 0)
    }

    func testTheSameTextWithAnotherModelIsAMiss() async {
        let cache = await makeCache()
        await cache.store(model: "m", text: "текст", vector: vector(1))
        let other = await cache.vector(model: "другая", text: "текст")
        XCTAssertNil(other)
        let statistics = await cache.statistics()
        XCTAssertEqual(statistics.misses, 1)
    }

    /// The dimension is a column, not part of the key: at lookup time the vector
    /// does not exist yet. Checked right after the read.
    func testAVectorOfTheWrongDimensionIsDroppedRatherThanReturned() async {
        let cache = await makeCache()
        await cache.store(model: "m", text: "текст", vector: vector(1, dimension: 8))

        let mismatched = await cache.vector(model: "m", text: "текст", expectedDimension: 1024)
        XCTAssertNil(mismatched)
        // Dropped, not merely refused: the next lookup must not find it either.
        let again = await cache.vector(model: "m", text: "текст")
        XCTAssertNil(again)
    }

    func testEverythingOfOneModelCanBeDropped() async {
        let cache = await makeCache()
        await cache.store(model: "m", text: "первый", vector: vector(1))
        await cache.store(model: "m", text: "второй", vector: vector(2))
        await cache.store(model: "другая", text: "первый", vector: vector(3))

        await cache.removeAll(model: "m")
        let mine = await cache.vector(model: "m", text: "первый")
        let theirs = await cache.vector(model: "другая", text: "первый")
        XCTAssertNil(mine)
        XCTAssertNotNil(theirs, "модель, которая не менялась, не должна пострадать")
    }

    // MARK: - Size

    /// Предел — про место в файле: векторы по 4 КБ, как у модели
    /// на 1024 измерения, ложатся цепочками страниц, и сумма векторов
    /// меньше файла. После вытеснения и сам файл на диске не больше предела.
    func testEvictionRemovesWhatWasUsedLongestAgo() async throws {
        let cache = await makeCache()
        for index in 0..<5 {
            await cache.store(model: "m", text: "текст-\(index)", vector: vector(Double(index + 1), dimension: 1024))
        }
        // Used now, so it must survive the sweep even though it is the oldest.
        _ = await cache.vector(model: "m", text: "текст-0")

        for index in 5..<300 {
            await cache.store(model: "m", text: "текст-\(index)", vector: vector(Double(index + 1), dimension: 1024))
        }
        let full = await cache.statistics()
        XCTAssertGreaterThan(full.fileBytes, full.bytes, "файл больше суммы векторов — потому предел и считается по файлу")

        let limit: Int64 = 600_000
        await cache.setLimit(bytes: limit)

        let statistics = await cache.statistics()
        XCTAssertLessThanOrEqual(statistics.fileBytes, limit)
        XCTAssertGreaterThan(statistics.entries, 0, "кэш не должен опустошаться целиком")
        let onDisk = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("cache.sqlite3").path
        )[.size] as? NSNumber
        XCTAssertLessThanOrEqual(onDisk?.int64Value ?? .max, limit, "освобождённое место обязано вернуться диску")
        let recentlyUsed = await cache.vector(model: "m", text: "текст-299")
        XCTAssertNotNil(recentlyUsed, "последняя запись должна пережить вытеснение")
        let oldest = await cache.vector(model: "m", text: "текст-1")
        XCTAssertNil(oldest, "давно не нужная запись вытесняется первой")
    }

    /// Файл, созданный прежней сборкой без возврата места, перестраивается
    /// при открытии — один раз.
    func testAnOldFileLearnsToGiveSpaceBack() async throws {
        let url = directory.appendingPathComponent("cache.sqlite3")
        let first = EmbeddingCache(fileURL: url)
        await first.open()
        await first.store(model: "m", text: "текст", vector: vector(1, dimension: 1024))
        // Как у прежней сборки: режим выключен.
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        sqlite3_exec(handle, "PRAGMA auto_vacuum = NONE; VACUUM;", nil, nil, nil)
        sqlite3_close(handle)

        let reopened = EmbeddingCache(fileURL: url)
        await reopened.open()
        let kept = await reopened.vector(model: "m", text: "текст")
        XCTAssertNotNil(kept, "перестройка не теряет записей")
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        var statement: OpaquePointer?
        sqlite3_prepare_v2(handle, "PRAGMA auto_vacuum", -1, &statement, nil)
        sqlite3_step(statement)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 2)
        sqlite3_finalize(statement)
        sqlite3_close(handle)
    }

    func testClearingEmptiesIt() async {
        let cache = await makeCache()
        await cache.store(model: "m", text: "текст", vector: vector(1))
        await cache.clear()
        let statistics = await cache.statistics()
        XCTAssertEqual(statistics.entries, 0)
        XCTAssertEqual(statistics.bytes, 0)
    }

    // MARK: - Failure

    /// A damaged cache is not a reason to stop embedding: it holds nothing but
    /// copies of work that can be redone.
    func testADamagedDatabaseDoesNotStopTheApp() async throws {
        let fileURL = directory.appendingPathComponent("cache.sqlite3")
        try Data("это не база данных, а мусор".utf8).write(to: fileURL)

        var warnings: [String] = []
        let cache = EmbeddingCache(fileURL: fileURL, log: { level, _, message in
            if level == .warning { warnings.append(message) }
        })
        await cache.open()

        // Either it was rebuilt or it stayed off; both are fine, and neither
        // may throw or crash.
        await cache.store(model: "m", text: "текст", vector: vector(1))
        _ = await cache.vector(model: "m", text: "текст")
        XCTAssertFalse(warnings.isEmpty, "о выключенном или пересозданном кэше нужно сказать в журнал")
    }

    func testAnUnopenedCacheIsSimplyInert() async {
        let cache = EmbeddingCache(fileURL: URL(fileURLWithPath: "/dev/null/nope/cache.sqlite3"))
        await cache.open()
        await cache.store(model: "m", text: "текст", vector: vector(1))
        let restored = await cache.vector(model: "m", text: "текст")
        XCTAssertNil(restored)
        let available = await cache.isAvailable
        XCTAssertFalse(available)
    }

    // MARK: - Through the client

    /// 3 asks for "no network call on a repeat". Proven by pointing the
    /// client at a port where nothing listens: a cached answer arrives anyway,
    /// which it could not if a request had been made.
    func testARepeatedTextIsAnsweredWithoutTheNetwork() async throws {
        let cache = await makeCache()
        let stored = [0.25, -0.5, 0.75, 1.0]
        await cache.store(model: "m", text: "текст", vector: stored)

        let client = try LMStudioClient(baseURLString: "http://127.0.0.1:1", cache: cache)
        let vectors = try await client.embed(texts: ["текст"], model: "m")
        XCTAssertEqual(vectors, [stored])
    }

    func testATextThatIsNotCachedStillGoesToTheModel() async throws {
        let cache = await makeCache()
        await cache.store(model: "m", text: "знакомый", vector: [0.25, 0.5])

        let client = try LMStudioClient(baseURLString: "http://127.0.0.1:1", cache: cache)
        do {
            _ = try await client.embed(texts: ["незнакомый"], model: "m")
            XCTFail("незнакомый текст обязан уйти в модель")
        } catch {
            // Unreachable, as it must be: the request was actually attempted.
        }
    }

    /// The same text under another model is not the same vector.
    func testAnotherModelIsNotAnsweredFromTheCache() async throws {
        let cache = await makeCache()
        await cache.store(model: "m", text: "текст", vector: [0.25, 0.5])

        let client = try LMStudioClient(baseURLString: "http://127.0.0.1:1", cache: cache)
        do {
            _ = try await client.embed(texts: ["текст"], model: "другая")
            XCTFail("для другой модели вектор должен считаться заново")
        } catch {}
    }

    /// Turning the cache off changes the speed, not the answers: without
    /// a cache the same call has nowhere to get the vector from.
    func testWithoutACacheNothingIsAnsweredLocally() async throws {
        let cache = await makeCache()
        await cache.store(model: "m", text: "текст", vector: [0.25, 0.5])

        let client = try LMStudioClient(baseURLString: "http://127.0.0.1:1", cache: nil)
        do {
            _ = try await client.embed(texts: ["текст"], model: "m")
            XCTFail("без кэша запрос обязан уйти в сеть")
        } catch {}
    }
}
