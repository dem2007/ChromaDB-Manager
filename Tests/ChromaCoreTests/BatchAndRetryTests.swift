import XCTest
@testable import ChromaCore

// MARK: - A transport that fails on demand

/// A ChromaDB that answers exactly what the test tells it to.
///
/// The rules being checked here — how many times a call is repeated, that a
/// write is never repeated, that a cancelled sequence stops sending — cannot be
/// provoked against a real server: it would have to be asked to return 503
/// twice and then succeed.
private final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    enum Reply {
        case ok(String)
        case status(Int, String)
        case transport(URLError.Code)
        /// Sleeps past any deadline the test sets.
        case hang
    }

    /// path suffix → replies, one per call; the last one repeats.
    private var script: [String: [Reply]] = [:]
    private var calls: [String] = []
    private var bodies: [(path: String, json: [String: Any])] = []
    private let lock = NSLock()
    /// Makes every answer take a moment, so a test can cancel while a sequence
    /// of sub-batches is still going.
    var replyDelay: TimeInterval = 0

    init(script: [String: [Reply]] = [:]) {
        self.script = script
    }

    func set(_ path: String, _ replies: [Reply]) {
        lock.lock(); defer { lock.unlock() }
        script[path] = replies
    }

    func callCount(_ suffix: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return calls.filter { $0.hasSuffix(suffix) }.count
    }

    var allCalls: [String] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    func sentBodies(_ suffix: String) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return bodies.filter { $0.path.hasSuffix(suffix) }.map(\.json)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        lock.lock()
        calls.append(path)
        let attempt = calls.filter { $0 == path }.count
        let match = script.first { path.hasSuffix($0.key) }?.value ?? []
        if let body = request.httpBody,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            bodies.append((path, json))
        }
        lock.unlock()

        if replyDelay > 0 {
            // Not cancellable on purpose: a request already on the wire is
            // answered whatever the caller does.
            try? await Task.sleep(nanoseconds: UInt64(replyDelay * 1_000_000_000))
        }
        let reply = match.isEmpty ? Reply.ok("{}") : match[min(attempt - 1, match.count - 1)]
        switch reply {
        case .hang:
            try await Task.sleep(nanoseconds: 30_000_000_000)
            throw URLError(.timedOut)
        case .transport(let code):
            throw URLError(code)
        case .ok(let body):
            return (Data(body.utf8), Self.response(path: path, status: 200))
        case .status(let code, let body):
            return (Data(body.utf8), Self.response(path: path, status: code))
        }
    }

    private static func response(path: String, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "http://localhost:8000\(path)")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }
}

private func sample(_ id: String, dimension: Int = 4, text: String = "текст") -> EmbeddedRecord {
    EmbeddedRecord(
        id: id,
        document: text,
        embedding: Array(repeating: 0.5, count: dimension),
        metadata: ["k": .string(id)]
    )
}

private func client(
    _ transport: ScriptedTransport,
    timeouts: TimeoutSettings = TimeoutSettings(),
    retries: RetryPolicy = RetryPolicy(maxAttempts: 3, delays: [0.01, 0.01])
) -> ChromaClient {
    ChromaClient(
        endpoint: ChromaEndpoint(host: "localhost", port: 8000),
        timeouts: timeouts,
        retries: retries,
        transport: transport
    )
}

// MARK: - A2: splitting

final class BatchSplitterTests: XCTestCase {
    private func limits(_ records: Int, bytes: Int = WriteLimits.defaultBodyBytes) -> WriteLimits {
        WriteLimits(maxRecords: records, maxBodyBytes: bytes, isReportedByServer: true)
    }

    func testSplittingByRecordCount() throws {
        let ten = (0..<10).map { sample("r\($0)") }

        XCTAssertEqual(try BatchSplitter.split([], limits: limits(10)).count, 0)
        XCTAssertEqual(try BatchSplitter.split(ten, limits: limits(10)).map(\.count), [10])
        XCTAssertEqual(try BatchSplitter.split(ten, limits: limits(9)).map(\.count), [9, 1])
        XCTAssertEqual(try BatchSplitter.split(ten, limits: limits(3)).map(\.count), [3, 3, 3, 1])
        XCTAssertEqual(try BatchSplitter.split(ten, limits: limits(1)).map(\.count), Array(repeating: 1, count: 10))
    }

    func testNothingIsLostOrReorderedBySplitting() throws {
        let records = (0..<25).map { sample("r\($0)") }
        let batches = try BatchSplitter.split(records, limits: limits(7))
        XCTAssertEqual(batches.flatMap { $0 }.map(\.id), records.map(\.id))
    }

    /// A record that cannot fit on its own has to be an error: halving the
    /// batch forever would never make it smaller.
    func testASingleOversizedRecordIsAnErrorAndNotAnEndlessSplit() {
        let huge = sample("big", dimension: 1, text: String(repeating: "я", count: 5000))
        XCTAssertThrowsError(try BatchSplitter.split([huge], limits: limits(100, bytes: 2048))) { error in
            guard case BatchSplitError.recordTooLarge(let id, _, let limit) = error else {
                return XCTFail("ожидалась recordTooLarge, получено \(error)")
            }
            XCTAssertEqual(id, "big")
            XCTAssertEqual(limit, 2048)
        }
    }

    /// Either limit alone lets the other one through: a thousand rows of long
    /// vectors is tens of megabytes, and a body that big fails while the row
    /// count is still well inside the server's limit.
    func testWhicheverLimitIsHitFirstWins() throws {
        let records = (0..<10).map { sample("r\($0)", dimension: 100) }

        let byCount = try BatchSplitter.split(records, limits: limits(4, bytes: 10 * 1024 * 1024))
        XCTAssertEqual(byCount.map(\.count), [4, 4, 2])

        let perRecord = BatchSplitter.estimatedBytes(of: records[0])
        let bySize = try BatchSplitter.split(records, limits: limits(1000, bytes: perRecord * 3 + 128))
        XCTAssertEqual(bySize.map(\.count), [3, 3, 3, 1])
    }

    /// The estimate decides how much goes into one request, so it must never
    /// come out below what is actually sent — a low estimate means a 413 from
    /// the server, and there is no way to notice it here.
    func testTheSizeEstimateIsNeverLowerThanTheRealJSON() throws {
        let samples: [EmbeddedRecord] = [
            sample("plain"),
            sample("кириллица", text: "Текст с кавычками \"и\\ обратными слэшами\nи переводом строки"),
            EmbeddedRecord(
                id: "mixed",
                document: String(repeating: "a", count: 500),
                embedding: (0..<128).map { Double($0) / 3.0 },
                metadata: ["s": .string("значение"), "i": .int(42), "d": .double(0.1234567890123), "b": .bool(true), "n": .null]
            ),
        ]
        for sample in samples {
            let real = try JSONSerialization.data(withJSONObject: [
                "ids": [sample.id],
                "documents": [sample.document],
                "embeddings": [sample.embedding],
                "metadatas": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(sample.metadata))],
            ])
            XCTAssertGreaterThanOrEqual(
                BatchSplitter.estimatedBytes(of: sample) + 128,
                real.count,
                "оценка \(BatchSplitter.estimatedBytes(of: sample)) меньше реальных \(real.count) байт для «\(sample.id)»"
            )
        }
    }
}

// MARK: - A2: the client applies the limits

final class WriteLimitTests: XCTestCase {
    private let collectionsPath = "/collections"

    func testTheLimitComesFromPreFlightChecks() async {
        let transport = ScriptedTransport(script: [
            "pre-flight-checks": [.ok(#"{"max_batch_size": 7, "supports_base64_encoding": true}"#)],
        ])
        let limits = await client(transport).writeLimits()
        XCTAssertEqual(limits.maxRecords, 7)
        XCTAssertTrue(limits.isReportedByServer)
    }

    /// A server without the endpoint must not be assumed generous.
    func testAMissingEndpointFallsBackToTheSafeValue() async {
        let transport = ScriptedTransport(script: [
            "pre-flight-checks": [.status(404, "not found")],
        ])
        var logged: [String] = []
        let subject = ChromaClient(
            endpoint: ChromaEndpoint(host: "localhost", port: 8000),
            log: { level, _, message in if level == .warning { logged.append(message) } },
            retries: .never,
            transport: transport
        )
        let limits = await subject.writeLimits()
        XCTAssertEqual(limits.maxRecords, WriteLimits.fallbackRecords)
        XCTAssertFalse(limits.isReportedByServer)
        XCTAssertTrue(logged.contains { $0.contains("безопасное значение") }, "\(logged)")
    }

    func testAnUnreadableAnswerAlsoFallsBack() async {
        let transport = ScriptedTransport(script: [
            "pre-flight-checks": [.ok(#"{"max_batch_size": null}"#)],
        ])
        let limits = await client(transport).writeLimits()
        XCTAssertEqual(limits.maxRecords, WriteLimits.fallbackRecords)
        XCTAssertFalse(limits.isReportedByServer)
    }

    func testAWriteIsCutIntoRequestsTheServerAccepts() async throws {
        let transport = ScriptedTransport(script: [
            "pre-flight-checks": [.ok(#"{"max_batch_size": 3}"#)],
        ])
        let subject = client(transport)
        try await subject.upsert(collectionID: "c1", records: (0..<10).map { sample("r\($0)") })

        XCTAssertEqual(transport.callCount("/upsert"), 4)
        let sentIDs = transport.sentBodies("/upsert").compactMap { $0["ids"] as? [String] }
        XCTAssertEqual(sentIDs.map(\.count), [3, 3, 3, 1])
        XCTAssertEqual(sentIDs.flatMap { $0 }, (0..<10).map { "r\($0)" }, "порядок записей сохраняется")
    }

    func testDeletionByIDIsCutTheSameWay() async throws {
        let transport = ScriptedTransport(script: [
            "pre-flight-checks": [.ok(#"{"max_batch_size": 4}"#)],
        ])
        try await client(transport).deleteDocuments(collectionID: "c1", ids: (0..<9).map { "r\($0)" })
        XCTAssertEqual(transport.callCount("/delete"), 3)
    }

    /// A failure in the middle leaves the earlier sub-batches written. There
    /// are no transactions to roll back, so the count has to be reported.
    func testAFailureOnTheSecondOfFourReportsWhatWasWritten() async {
        let transport = ScriptedTransport(script: [
            "pre-flight-checks": [.ok(#"{"max_batch_size": 3}"#)],
            "/upsert": [.ok("{}"), .status(500, #"{"error":"InternalError","message":"диск"}"#)],
        ])
        let subject = client(transport)
        do {
            try await subject.upsert(collectionID: "c1", records: (0..<10).map { sample("r\($0)") })
            XCTFail("ожидалась ошибка")
        } catch ChromaError.partialWrite(let failure) {
            XCTAssertEqual(failure.written, 3)
            XCTAssertEqual(failure.total, 10)
            XCTAssertEqual(failure.failedBatch, 2)
            XCTAssertEqual(failure.batchCount, 4)
            XCTAssertTrue(failure.reason.contains("диск"), failure.reason)
        } catch {
            XCTFail("неожиданная ошибка: \(error)")
        }
        // The failing sub-batch is not repeated behind the user's back.
        XCTAssertEqual(transport.callCount("/upsert"), 2)
    }

    /// Failing on the very first sub-batch is not «partial» — nothing was
    /// written, and the caller needs the real error, not a wrapper.
    func testAFailureBeforeAnythingIsWrittenKeepsTheOriginalError() async {
        let transport = ScriptedTransport(script: [
            "pre-flight-checks": [.ok(#"{"max_batch_size": 3}"#)],
            "/upsert": [.status(400, #"{"error":"InvalidArgumentError","message":"Collection expecting embedding with dimension of 8, got 4"}"#)],
        ])
        do {
            try await client(transport).upsert(collectionID: "c1", records: (0..<10).map { sample("r\($0)") })
            XCTFail("ожидалась ошибка")
        } catch ChromaError.dimensionMismatch(let expected, let got) {
            XCTAssertEqual(expected, 8)
            XCTAssertEqual(got, 4)
        } catch {
            XCTFail("неожиданная ошибка: \(error)")
        }
    }

    /// Cancellation lands between sub-batches: what is already on the wire is
    /// going to be applied, but nothing new is sent.
    func testCancellationStopsTheRemainingSubBatches() async throws {
        let transport = ScriptedTransport(script: [
            "pre-flight-checks": [.ok(#"{"max_batch_size": 1}"#)],
        ])
        transport.replyDelay = 0.003
        let subject = client(transport)
        let task = Task {
            try await subject.upsert(collectionID: "c1", records: (0..<200).map { sample("r\($0)") })
        }
        try await Task.sleep(nanoseconds: 60_000_000)
        task.cancel()

        do {
            try await task.value
            XCTFail("ожидалась отмена")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("отмена должна приходить как CancellationError, получено \(error)")
        }
        let sent = transport.callCount("/upsert")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(transport.callCount("/upsert"), sent, "после отмены новых запросов быть не должно")
        XCTAssertLessThan(sent, 200)
    }
}

// MARK: - A8: timeouts and retries

final class RetryPolicyTests: XCTestCase {
    func testTheDelaysAreTheOnesThePolicyNames() {
        let policy = RetryPolicy.reads
        XCTAssertEqual(policy.maxAttempts, 3, "две повторные попытки сверх первой")
        XCTAssertEqual(policy.delay(beforeAttempt: 1), 0, "первая попытка идёт без задержки")
        XCTAssertEqual(policy.delay(beforeAttempt: 2, jitter: 0), 0.5)
        XCTAssertEqual(policy.delay(beforeAttempt: 3, jitter: 0), 1.5)
    }

    func testJitterStaysWithinAQuarterOfTheBaseDelay() {
        for _ in 0..<50 {
            let delay = RetryPolicy.reads.delay(beforeAttempt: 2)
            XCTAssertGreaterThanOrEqual(delay, 0.375)
            XCTAssertLessThanOrEqual(delay, 0.625)
        }
    }

    func testWritesAreNeverRepeatedByTheirClass() {
        XCTAssertFalse(ChromaOperation.write.isRetriedAutomatically)
        XCTAssertFalse(ChromaOperation.management.isRetriedAutomatically)
        for operation in [ChromaOperation.liveness, .metadata, .fetch, .query] {
            XCTAssertTrue(operation.isRetriedAutomatically, "\(operation)")
        }
    }

    func testEachClassKeepsItsOwnDeadline() {
        let timeouts = TimeoutSettings()
        XCTAssertEqual(timeouts[.liveness], 3)
        XCTAssertEqual(timeouts[.metadata], 15)
        XCTAssertEqual(timeouts[.fetch], 30)
        XCTAssertEqual(timeouts[.query], 60)
        XCTAssertEqual(timeouts[.write], 120)
        XCTAssertEqual(timeouts[.management], 15, "управление коллекциями идёт по классу метаданных")
    }

    /// A hand-edited config must not be able to switch timeouts off.
    func testAConfigWithNonsenseValuesFallsBackToTheDefaults() throws {
        let json = #"{"liveness": 0, "metadata": -5, "query": 45, "write": 100000}"#
        let decoded = try JSONDecoder().decode(TimeoutSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.liveness, 3)
        XCTAssertEqual(decoded.metadata, 15)
        XCTAssertEqual(decoded.query, 45, "разумное значение сохраняется")
        XCTAssertEqual(decoded.write, 120)
    }
}

final class RequestRetryTests: XCTestCase {
    func testAReadIsRepeatedOnAGatewayErrorAndThenSucceeds() async throws {
        let transport = ScriptedTransport(script: [
            "/collections": [.status(503, "down"), .status(502, "down"), .ok("[]")],
        ])
        let collections = try await client(transport).listCollections(withCounts: false)
        XCTAssertTrue(collections.isEmpty)
        XCTAssertEqual(transport.callCount("/collections"), 3)
    }

    func testAReadGivesUpAfterTwoRetries() async {
        let transport = ScriptedTransport(script: ["/collections": [.status(503, "down")]])
        do {
            _ = try await client(transport).listCollections(withCounts: false)
            XCTFail("ожидалась ошибка")
        } catch {
            XCTAssertEqual(transport.callCount("/collections"), 3, "первая попытка плюс две повторные")
        }
    }

    /// 4xx is the request's own fault; repeating it produces the same answer.
    func testABadRequestIsNotRepeated() async {
        let transport = ScriptedTransport(script: [
            "/collections": [.status(422, #"{"error":"ValidationError","message":"unknown field"}"#)],
        ])
        do {
            _ = try await client(transport).listCollections(withCounts: false)
            XCTFail("ожидалась ошибка")
        } catch {
            XCTAssertEqual(transport.callCount("/collections"), 1)
        }
    }

    func testATransportFailureIsRepeatedForReads() async throws {
        let transport = ScriptedTransport(script: [
            "/collections": [.transport(.networkConnectionLost), .ok("[]")],
        ])
        _ = try await client(transport).listCollections(withCounts: false)
        XCTAssertEqual(transport.callCount("/collections"), 2)
    }

    /// The heart of A8.3: an upsert that failed may already have been applied,
    /// so it is never sent again without the user saying so.
    func testAWriteIsNeverRepeatedAutomatically() async {
        let transport = ScriptedTransport(script: [
            "pre-flight-checks": [.ok(#"{"max_batch_size": 100}"#)],
            "/upsert": [.transport(.networkConnectionLost)],
        ])
        do {
            try await client(transport).upsert(collectionID: "c1", records: [sample("r1")])
            XCTFail("ожидалась ошибка")
        } catch {
            XCTAssertEqual(transport.callCount("/upsert"), 1, "ровно один сетевой вызов")
        }
    }

    func testCreatingACollectionIsNotRepeatedEither() async {
        let transport = ScriptedTransport(script: ["/collections": [.status(503, "down")]])
        do {
            _ = try await client(transport).createCollection(name: "c1")
            XCTFail("ожидалась ошибка")
        } catch {
            XCTAssertEqual(transport.callCount("/collections"), 1)
        }
    }

    /// A hung read outlives `URLRequest.timeoutInterval`, so the outer clock is
    /// what actually ends it — and the error says which class ran out.
    func testAHungCallEndsWithATypedTimeoutNamingItsClass() async {
        let transport = ScriptedTransport(script: ["healthcheck": [.hang]])
        let subject = client(
            transport,
            timeouts: TimeoutSettings(liveness: 1),
            retries: .never
        )
        do {
            try await subject.healthcheck()
            XCTFail("ожидался таймаут")
        } catch ChromaError.timedOut(let operation, let seconds) {
            XCTAssertEqual(operation, .liveness)
            XCTAssertEqual(seconds, 1)
        } catch {
            XCTFail("неожиданная ошибка: \(error)")
        }
    }

    /// A timeout is not retried: the deadline for this class has already
    /// expired, and waiting the same amount again is the opposite of what it
    /// was set for.
    func testATimeoutIsNotRetried() async {
        let transport = ScriptedTransport(script: ["healthcheck": [.hang]])
        let subject = client(transport, timeouts: TimeoutSettings(liveness: 1))
        do {
            try await subject.healthcheck()
            XCTFail("ожидался таймаут")
        } catch {
            XCTAssertEqual(transport.callCount("/healthcheck"), 1)
        }
    }

    /// the clock starts when the operation starts, not when it was asked
    /// for. Written before the task queue of F2 exists, because afterwards the
    /// defect would only show under load: anything queued behind a long
    /// synchronisation would fail without sending a single byte.
    func testTheDeadlineStartsWithTheWorkAndNotWithTheWait() async throws {
        let transport = ScriptedTransport(script: ["healthcheck": [.ok("{}")]])
        let subject = client(transport, timeouts: TimeoutSettings(liveness: 1), retries: .never)

        // Prepared now, run later — the shape a queue gives every operation.
        let queued: @Sendable () async throws -> Void = { try await subject.healthcheck() }
        try await Task.sleep(nanoseconds: 1_500_000_000)

        try await queued()
        XCTAssertEqual(transport.callCount("/healthcheck"), 1, "операция должна выполниться, а не отпасть по таймауту")
    }

    /// The other half of the same rule: once the work has started, its own
    /// slowness still counts.
    func testWaitingDoesNotBuyTheOperationExtraTime() async {
        let transport = ScriptedTransport(script: ["healthcheck": [.hang]])
        let subject = client(transport, timeouts: TimeoutSettings(liveness: 1), retries: .never)
        let queued: @Sendable () async throws -> Void = { try await subject.healthcheck() }
        try? await Task.sleep(nanoseconds: 500_000_000)

        let started = Date()
        do {
            try await queued()
            XCTFail("ожидался таймаут")
        } catch ChromaError.timedOut(let operation, _) {
            XCTAssertEqual(operation, .liveness)
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertGreaterThanOrEqual(elapsed, 0.9, "таймаут не должен срабатывать раньше своего срока")
            XCTAssertLessThan(elapsed, 2, "и не должен продлеваться на время ожидания")
        } catch {
            XCTFail("неожиданная ошибка: \(error)")
        }
    }
}
