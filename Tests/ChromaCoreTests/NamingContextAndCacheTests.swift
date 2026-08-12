import XCTest
@testable import ChromaCore

// MARK: - A5: collection names

/// Every case here was run against a live 1.4.4 server first; the expected
/// answers are the server's, not a reading of its documentation.
final class CollectionNameValidationTests: XCTestCase {
    func testNamesTheServerAccepts() {
        for name in ["abc", "a.b", "a-b", "a_b", "a__b", "0abc", "abc0", "UPPER_case",
                     "192.168.0.1.5", "999.999.999.999", "256.1.1.1", "01.2.3.4",
                     "2130706433", "1.2.3", "a1.2.3.4", String(repeating: "a", count: 512)] {
            XCTAssertTrue(CollectionNaming.isValid(name), "«\(name)» сервер принимает, значит и валидатор должен")
        }
    }

    func testEachRejectionNamesItsOwnRule() {
        let cases: [(String, CollectionNameRule)] = [
            ("ab", .tooShort),
            (String(repeating: "a", count: 513), .tooLong),
            ("Мои_заметки", .illegalCharacters),
            ("with space", .illegalCharacters),
            ("a/b", .illegalCharacters),
            ("-abc", .badFirstCharacter),
            (".abc", .badFirstCharacter),
            ("abc-", .badLastCharacter),
            ("abc.", .badLastCharacter),
            ("a..b", .consecutivePeriods),
            ("192.168.0.1", .looksLikeIPAddress),
            ("1.2.3.4", .looksLikeIPAddress),
            ("255.255.255.255", .looksLikeIPAddress),
            ("0.0.0.0", .looksLikeIPAddress),
        ]
        for (name, expected) in cases {
            let violations = CollectionNaming.violations(of: name)
            XCTAssertTrue(violations.contains(expected), "«\(name)»: ожидалось \(expected), получено \(violations)")
            XCTAssertFalse(CollectionNaming.isValid(name), "«\(name)» должно быть отклонено")
        }
    }

    /// The message has to say what to fix. «Недопустимое имя» is the thing this
    /// replaces.
    func testTheMessageNamesTheProblem() {
        XCTAssertEqual(CollectionNaming.firstProblem(with: "ok_name"), nil)
        XCTAssertTrue(try XCTUnwrap(CollectionNaming.firstProblem(with: "-abc")).contains("начинаться"))
        XCTAssertTrue(try XCTUnwrap(CollectionNaming.firstProblem(with: "a..b")).contains("точки"))
        XCTAssertTrue(try XCTUnwrap(CollectionNaming.firstProblem(with: "10.0.0.1")).contains("IP"))
        XCTAssertTrue(try XCTUnwrap(CollectionNaming.firstProblem(with: "ab")).contains("трёх"))
    }

    /// An address is stricter than «four numbers with dots»; the server accepts
    /// `256.1.1.1` and `01.2.3.4` as names precisely because they are not
    /// addresses.
    func testTheIPRuleMatchesWhatTheServerCallsAnAddress() {
        XCTAssertTrue(CollectionNaming.looksLikeIPv4("10.0.0.1"))
        XCTAssertTrue(CollectionNaming.looksLikeIPv4("0.0.0.0"))
        XCTAssertFalse(CollectionNaming.looksLikeIPv4("256.1.1.1"), "октет больше 255")
        XCTAssertFalse(CollectionNaming.looksLikeIPv4("01.2.3.4"), "ведущий ноль")
        XCTAssertFalse(CollectionNaming.looksLikeIPv4("1.2.3"), "три части")
        XCTAssertFalse(CollectionNaming.looksLikeIPv4("1.2.3.4.5"))
        XCTAssertFalse(CollectionNaming.looksLikeIPv4("a.b.c.d"))
    }

    func testSanitizeProducesSomethingTheServerWouldTake() {
        for raw in ["Мои заметки 2024", "..", "-", "a..b", "192.168.0.1", "!!!", "ab", "  ", "a/b/c"] {
            let cleaned = CollectionNaming.sanitize(raw)
            XCTAssertTrue(
                CollectionNaming.isValid(cleaned),
                "«\(raw)» → «\(cleaned)», нарушения: \(CollectionNaming.violations(of: cleaned))"
            )
        }
    }
}

// MARK: - A7: text against the model's context

final class ContextBudgetTests: XCTestCase {
    private func text(tokens: Int) -> String {
        String(repeating: "я", count: TokenEstimator.characters(forTokens: tokens))
    }

    func testUnderTheThresholdNothingIsSaid() {
        let verdict = ContextBudget.check(text(tokens: 100), contextLength: 1000)
        XCTAssertFalse(verdict.blocksSending)
        XCTAssertNil(verdict.message, "обычная работа не должна ничего сообщать")
    }

    /// The estimate is a heuristic, so the last fifth of the context is a
    /// warning rather than silence.
    func testNearTheLimitItWarnsButStillAllows() {
        let verdict = ContextBudget.check(text(tokens: 900), contextLength: 1000)
        XCTAssertFalse(verdict.blocksSending)
        let message = try? XCTUnwrap(verdict.message)
        XCTAssertTrue(message?.contains("≈") == true, "оценка помечается как приблизительная")
    }

    func testOverTheLimitItBlocksAndSaysBothNumbers() {
        let verdict = ContextBudget.check(text(tokens: 1200), contextLength: 1000)
        XCTAssertTrue(verdict.blocksSending)
        let message = try? XCTUnwrap(verdict.message)
        XCTAssertTrue(message?.contains("1000") == true, message ?? "")
        XCTAssertTrue(message?.contains("≈") == true, message ?? "")
    }

    /// Blocking on a number nobody reported would stop work that is fine.
    func testAnUnknownContextWarnsAndNeverBlocks() {
        let long = ContextBudget.check(String(repeating: "a", count: 9000), contextLength: nil)
        XCTAssertFalse(long.blocksSending)
        XCTAssertNotNil(long.message)

        let short = ContextBudget.check("короткий текст", contextLength: nil)
        XCTAssertFalse(short.blocksSending)
        XCTAssertNil(short.message)
    }

    func testAZeroContextIsTreatedAsUnknownRatherThanAsBlockEverything() {
        XCTAssertFalse(ContextBudget.check("текст", contextLength: 0).blocksSending)
    }

    /// Empty input never goes to the model: the vector would be meaningless and
    /// the row unsearchable.
    func testEmptyAndWhitespaceTextIsRefusedBeforeAnyCall() {
        for text in ["", "   ", "\n\t  \n"] {
            let verdict = ContextBudget.check(text, contextLength: 1000)
            XCTAssertEqual(verdict, .empty)
            XCTAssertTrue(verdict.blocksSending)
        }
    }

    func testTheBoundaryItselfIsAllowed() {
        let atLimit = ContextBudget.check(text(tokens: 1000), contextLength: 1000)
        XCTAssertFalse(atLimit.blocksSending, "ровно лимит — ещё можно")
        let overByOne = ContextBudget.check(text(tokens: 1001), contextLength: 1000)
        XCTAssertTrue(overByOne.blocksSending)
    }
}

// MARK: - A4: the name → UUID cache

private final class CacheTransport: HTTPTransport, @unchecked Sendable {
    /// Collections the «server» currently has, name → id.
    private var live: [String: String]
    private var calls: [String] = []
    private let lock = NSLock()

    init(live: [String: String]) {
        self.live = live
    }

    func replace(_ name: String, with id: String) {
        lock.lock(); defer { lock.unlock() }
        live[name] = id
    }

    func remove(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        live.removeValue(forKey: name)
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls.count
    }

    func count(matching suffix: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return calls.filter { $0.hasSuffix(suffix) }.count
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        lock.lock()
        calls.append(path)
        let known = live
        lock.unlock()

        func reply(_ status: Int, _ body: String) -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }

        if path.hasSuffix("/pre-flight-checks") { return reply(200, #"{"max_batch_size": 100}"#) }
        if path.hasSuffix("/collections") {
            let items = known.map { #"{"id":"\#($0.value)","name":"\#($0.key)"}"# }
            return reply(200, "[\(items.joined(separator: ","))]")
        }
        // Any per-collection call: only ids that are still live answer.
        let parts = path.split(separator: "/")
        guard let index = parts.firstIndex(of: "collections"), index + 1 < parts.count else {
            return reply(404, "")
        }
        let id = String(parts[index + 1])
        guard known.values.contains(id) else {
            return reply(404, #"{"error":"NotFoundError","message":"Collection [\#(id)] does not exist."}"#)
        }
        if path.hasSuffix("/count") { return reply(200, "7") }
        return reply(200, "{}")
    }
}

final class CollectionCacheTests: XCTestCase {
    private func client(_ transport: CacheTransport) -> ChromaClient {
        ChromaClient(
            endpoint: ChromaEndpoint(host: "localhost", port: 8000),
            retries: .never,
            transport: transport
        )
    }

    func testASecondResolveOfTheSameNameCostsNothing() async throws {
        let transport = CacheTransport(live: ["notes": "id-1"])
        let subject = client(transport)

        _ = try await subject.resolveID(of: "notes")
        let afterFirst = transport.callCount
        _ = try await subject.resolveID(of: "notes")
        XCTAssertEqual(transport.callCount, afterFirst, "второй резолв должен браться из кэша")
    }

    /// The case this exists for: another client deletes the collection and
    /// re-creates it under the same name. The app should carry on after one
    /// invisible re-resolve.
    func testAReCreatedCollectionIsPickedUpAfterOneReResolve() async throws {
        let transport = CacheTransport(live: ["notes": "id-1"])
        let subject = client(transport)
        _ = try await subject.resolveID(of: "notes")

        transport.replace("notes", with: "id-2")
        let count = try await subject.count(collectionID: "id-1")
        XCTAssertEqual(count, 7, "операция должна пройти на новом идентификаторе")

        // And the new id is what the cache holds now.
        let resolved = try await subject.resolveID(of: "notes")
        XCTAssertEqual(resolved, "id-2")
    }

    func testWritesSurviveARecreatedCollectionToo() async throws {
        let transport = CacheTransport(live: ["notes": "id-1"])
        let subject = client(transport)
        _ = try await subject.resolveID(of: "notes")

        transport.replace("notes", with: "id-2")
        try await subject.upsert(
            collectionID: "id-1",
            records: [EmbeddedRecord(id: "a", document: "текст", embedding: [0.1], metadata: [:])]
        )
        let resolved = try await subject.resolveID(of: "notes")
        XCTAssertEqual(resolved, "id-2")
    }

    /// A collection that is really gone must produce one error, not a loop.
    func testACollectionThatIsGoneFailsOnceWithABoundedNumberOfCalls() async throws {
        let transport = CacheTransport(live: ["notes": "id-1"])
        let subject = client(transport)
        _ = try await subject.resolveID(of: "notes")
        let beforeOperation = transport.callCount

        transport.remove("notes")
        do {
            _ = try await subject.count(collectionID: "id-1")
            XCTFail("ожидалась ошибка")
        } catch ChromaError.collectionNotFound {
            // expected
        }
        let spent = transport.callCount - beforeOperation
        XCTAssertLessThanOrEqual(spent, 2, "одна операция плюс один перерезолв, не больше (было \(spent))")
    }

    /// A 404 from an unknown endpoint has an empty body and means nothing about
    /// collections; reacting to the bare status code would send the app
    /// re-resolving forever.
    func testAPlain404IsNotMistakenForAMissingCollection() {
        let unknownEndpoint = ChromaClient.mapError(status: 404, data: Data(), endpoint: "http://localhost:8000")
        if case .collectionNotFound = unknownEndpoint {
            XCTFail("пустой 404 не должен означать «коллекция не найдена»")
        }

        let otherNotFound = ChromaClient.mapError(
            status: 404,
            data: Data(#"{"error":"NotFoundError","message":"Database [nope] does not exist."}"#.utf8),
            endpoint: "http://localhost:8000"
        )
        if case .collectionNotFound = otherNotFound {
            XCTFail("отсутствующая база — это не отсутствующая коллекция")
        }
    }

    /// Fixtures captured from a live 1.4.4 server.
    func testTheRealServerResponseIsClassified() throws {
        for fixture in ["error_collection_not_found", "error_collection_not_found_by_name"] {
            let data = try Fixture.data(fixture)
            let error = ChromaClient.mapError(status: 404, data: data, endpoint: "http://localhost:8000")
            guard case .collectionNotFound(let subject) = error else {
                return XCTFail("\(fixture) должен разбираться как collectionNotFound, получено \(error)")
            }
            XCTAssertFalse(subject.isEmpty)
            XCTAssertFalse(subject.contains("["), "имя достаётся из скобок: \(subject)")
        }
    }

    /// Two connections never share cache entries — they are separate clients,
    /// and a name means a different collection on a different server.
    func testTwoConnectionsDoNotShareIdentifiers() async throws {
        let first = client(CacheTransport(live: ["notes": "id-first"]))
        let second = client(CacheTransport(live: ["notes": "id-second"]))
        let a = try await first.resolveID(of: "notes")
        let b = try await second.resolveID(of: "notes")
        XCTAssertEqual(a, "id-first")
        XCTAssertEqual(b, "id-second")
    }

    /// The refresh button goes through `listCollections`, and a name that is no
    /// longer on the server must not survive in the cache (rule 3).
    func testRefreshingTheListDropsNamesTheServerNoLongerHas() async throws {
        let transport = CacheTransport(live: ["notes": "id-1", "archive": "id-2"])
        let subject = client(transport)
        _ = try await subject.resolveID(of: "archive")

        transport.remove("archive")
        _ = try await subject.listCollections(withCounts: false)

        do {
            _ = try await subject.resolveID(of: "archive")
            XCTFail("удалённая коллекция не должна резолвиться из кэша")
        } catch ChromaError.collectionNotFound {
            // expected
        }
    }
}
