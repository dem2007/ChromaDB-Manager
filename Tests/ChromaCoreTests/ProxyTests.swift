import XCTest
@testable import ChromaCore

/// Paths taken verbatim from traffic captured between the real `chromadb`
/// Python client and chroma 1.4.4.
final class ChromaRouteTests: XCTestCase {
    private let tenantPath = "/api/v2/tenants/default_tenant/databases/default_database/collections"

    func testReadsDoneWithPOSTAreStillReads() {
        // The whole reason the parser exists: `get` and `query` are POSTs.
        let uuid = "1916a0d6-cabc-4569-b1f4-3ff9df0d154c"
        let get = ChromaRoute.parse(method: "POST", path: "\(tenantPath)/\(uuid)/get")
        XCTAssertEqual(get.access, .read)
        XCTAssertEqual(get.operation, "get")
        XCTAssertEqual(get.collectionReference, uuid)

        XCTAssertEqual(ChromaRoute.parse(method: "POST", path: "\(tenantPath)/\(uuid)/query").access, .read)
        XCTAssertEqual(ChromaRoute.parse(method: "POST", path: "\(tenantPath)/\(uuid)/add").access, .write)
        XCTAssertEqual(ChromaRoute.parse(method: "POST", path: "\(tenantPath)/\(uuid)/upsert").access, .write)
        XCTAssertEqual(ChromaRoute.parse(method: "POST", path: "\(tenantPath)/\(uuid)/update").access, .write)
        XCTAssertEqual(ChromaRoute.parse(method: "POST", path: "\(tenantPath)/\(uuid)/delete").access, .write)
    }

    func testCountIsAGETWithAQueryString() {
        let route = ChromaRoute.parse(
            method: "GET",
            path: "\(tenantPath)/1916a0d6-cabc-4569-b1f4-3ff9df0d154c/count?read_level=index_and_wal"
        )
        XCTAssertEqual(route.operation, "count")
        XCTAssertEqual(route.access, .read)
        XCTAssertTrue(route.isKnown)
    }

    func testTheSamePathPositionHoldsBothIdsAndNames() {
        // Data operations use the UUID; delete_collection uses the name.
        let byName = ChromaRoute.parse(method: "DELETE", path: "\(tenantPath)/proxy_probe")
        XCTAssertEqual(byName.operation, "delete_collection")
        XCTAssertEqual(byName.access, .write)
        XCTAssertEqual(byName.target, .collection(reference: "proxy_probe", looksLikeID: false))

        let byID = ChromaRoute.parse(method: "PUT", path: "\(tenantPath)/1916a0d6-cabc-4569-b1f4-3ff9df0d154c")
        XCTAssertEqual(byID.operation, "update_collection")
        XCTAssertEqual(byID.target, .collection(reference: "1916a0d6-cabc-4569-b1f4-3ff9df0d154c", looksLikeID: true))
    }

    func testCollectionLevelOperations() {
        XCTAssertEqual(ChromaRoute.parse(method: "GET", path: tenantPath).operation, "list_collections")
        XCTAssertEqual(ChromaRoute.parse(method: "GET", path: tenantPath).access, .read)
        XCTAssertEqual(ChromaRoute.parse(method: "POST", path: tenantPath).operation, "create_collection")
        XCTAssertEqual(ChromaRoute.parse(method: "POST", path: tenantPath).access, .write)
    }

    func testServiceEndpointsIncludingTheOneTheClientCallsFirst() {
        // Without /auth/identity the real client fails at construction.
        XCTAssertEqual(ChromaRoute.parse(method: "GET", path: "/api/v2/auth/identity").access, .service)
        XCTAssertEqual(ChromaRoute.parse(method: "GET", path: "/api/v2/heartbeat").access, .service)
        XCTAssertEqual(ChromaRoute.parse(method: "GET", path: "/api/v2/pre-flight-checks").access, .service)
        XCTAssertEqual(ChromaRoute.parse(method: "GET", path: "/api/v2/tenants/default_tenant").operation, "get_tenant")
        XCTAssertEqual(
            ChromaRoute.parse(method: "GET", path: "/api/v2/tenants/default_tenant/databases/default_database").operation,
            "get_database"
        )
        // Reset destroys everything — a write, whatever else it is.
        XCTAssertEqual(ChromaRoute.parse(method: "POST", path: "/api/v2/reset").access, .write)
    }

    func testUnknownPathsAreWritesUnlessTheyAreGETs() {
        // Deny-by-default needs the unknown POST to look like a write.
        let post = ChromaRoute.parse(method: "POST", path: "/api/v2/something/new")
        XCTAssertFalse(post.isKnown)
        XCTAssertEqual(post.access, .write)

        let get = ChromaRoute.parse(method: "GET", path: "/api/v2/something/new")
        XCTAssertFalse(get.isKnown)
        XCTAssertEqual(get.access, .read, "новый эндпоинт чтения не должен ломаться после обновления ChromaDB")

        XCTAssertFalse(ChromaRoute.parse(method: "GET", path: "/api/v1/collections").isKnown)
    }
}

final class HTTPRequestParserTests: XCTestCase {
    private func request(_ path: String, body: String = "", extra: String = "") -> Data {
        var head = "POST \(path) HTTP/1.1\r\nHost: h\r\n\(extra)"
        if !body.isEmpty { head += "Content-Length: \(body.utf8.count)\r\n" }
        return Data((head + "\r\n" + body).utf8)
    }

    func testTwoRequestsOnOneConnectionAreReadSeparately() throws {
        var parser = HTTPRequestParser()
        let body = #"{"ids":["a1"]}"#
        parser.append(request("/api/v2/x", body: body) + request("/api/v2/y", body: body))

        let first = try XCTUnwrap(try parser.next())
        XCTAssertEqual(first.path, "/api/v2/x")
        XCTAssertEqual(String(data: first.body, encoding: .utf8), body)
        let second = try XCTUnwrap(try parser.next())
        XCTAssertEqual(second.path, "/api/v2/y")
        XCTAssertNil(try parser.next())
    }

    func testARequestSplitAcrossPacketsIsAssembled() throws {
        var parser = HTTPRequestParser()
        parser.append(Data("GET /api/v2/heart".utf8))
        XCTAssertNil(try parser.next())
        parser.append(Data("beat HTTP/1.1\r\nHost: h\r".utf8))
        XCTAssertNil(try parser.next())
        parser.append(Data("\n\r\n".utf8))
        XCTAssertEqual(try parser.next()?.path, "/api/v2/heartbeat")
    }

    func testABodyThatHasNotArrivedYetIsNotAHalfRequest() throws {
        var parser = HTTPRequestParser()
        parser.append(Data("POST /x HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc".utf8))
        XCTAssertNil(try parser.next(), "неполное тело — это ещё не запрос")
        parser.append(Data("defghij".utf8))
        XCTAssertEqual(try parser.next()?.body.count, 10)
    }

    func testKeyIsTakenFromEitherHeader() throws {
        var bearer = HTTPRequestParser()
        bearer.append(request("/x", extra: "Authorization: Bearer secret-1\r\n"))
        XCTAssertEqual(try bearer.next()?.accessKey, "secret-1")

        var token = HTTPRequestParser()
        token.append(request("/x", extra: "X-Chroma-Token: secret-2\r\n"))
        XCTAssertEqual(try token.next()?.accessKey, "secret-2")

        var none = HTTPRequestParser()
        none.append(request("/x"))
        XCTAssertNil(try none.next()?.accessKey)
    }

    func testChunkedAndOversizedInputAreRefusedNotGuessedAt() {
        var chunked = HTTPRequestParser()
        chunked.append(Data("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\n\r\n".utf8))
        XCTAssertThrowsError(try chunked.next())

        var huge = HTTPRequestParser()
        huge.append(Data(repeating: 0x41, count: 100 * 1024))
        XCTAssertThrowsError(try huge.next(), "бесконечный заголовок не должен копиться в памяти")
    }
}

final class CollectionListFilterTests: XCTestCase {
    func testOnlyPermittedCollectionsSurvive() throws {
        let body = Data(#"[{"id":"1","name":"public"},{"id":"2","name":"secret"}]"#.utf8)
        let filtered = ProxyConnection.filterCollectionList(body, allowed: ["public"])
        let names = (try JSONSerialization.jsonObject(with: filtered) as? [[String: Any]])?
            .compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["public"], "ключ с whitelist из одной коллекции не должен видеть остальные")
    }

    func testAnEmptyWhitelistShowsNothing() throws {
        let body = Data(#"[{"id":"1","name":"public"}]"#.utf8)
        let filtered = ProxyConnection.filterCollectionList(body, allowed: [])
        XCTAssertEqual(String(data: filtered, encoding: .utf8), "[]")
    }
}

final class WritePayloadTests: XCTestCase {
    func testEmbeddingsArriveAsBase64FromTheRealClient() {
        // Captured verbatim: four float32 encode to 16 bytes of base64.
        let body = Data(#"{"ids":["a1"],"embeddings":["zczMPc3MTD6amZk+zczMPg=="],"documents":["кошка"]}"#.utf8)
        let payload = WritePayload.parse(body)
        XCTAssertEqual(payload?.dimensions, [4], "проверка размерности обязана понимать base64")
        XCTAssertEqual(payload?.documentCount, 1)
        XCTAssertEqual(payload?.largestDocumentBytes, "кошка".utf8.count)
    }

    func testEmbeddingsAlsoArriveAsPlainArrays() {
        let body = Data(#"{"ids":["a1","a2"],"embeddings":[[0.1,0.2,0.3],[0.4,0.5,0.6]]}"#.utf8)
        let payload = WritePayload.parse(body)
        XCTAssertEqual(payload?.dimensions, [3])
        XCTAssertEqual(payload?.documentCount, 2)
    }

    func testMixedDimensionsInOneRequestAreVisible() {
        let body = Data(#"{"ids":["a","b"],"embeddings":[[0.1,0.2],[0.3,0.4,0.5]]}"#.utf8)
        XCTAssertEqual(WritePayload.parse(body)?.dimensions, [2, 3])
    }

    func testDeleteBodyCarriesNoVectors() {
        let payload = WritePayload.parse(Data(#"{"ids":["a3"],"where":null}"#.utf8))
        XCTAssertEqual(payload?.dimensions, [])
        XCTAssertEqual(payload?.documentCount, 1)
    }
}

/// The matrix the spec's definition of done asks for: permission × operation.
final class AccessControllerTests: XCTestCase {
    private let allowedID = "11111111-1111-1111-1111-111111111111"
    private let secretID = "22222222-2222-2222-2222-222222222222"
    private let freshID = "33333333-3333-3333-3333-333333333333"
    private let tenant = "/api/v2/tenants/default_tenant/databases/default_database/collections"

    private func makeController(_ client: ExternalClient) async -> AccessController {
        let controller = AccessController()
        await controller.setClients([client])
        await controller.setCatalog([
            CollectionSnapshot(id: allowedID, name: "public", dimension: 4),
            CollectionSnapshot(id: secretID, name: "secret", dimension: 4),
            CollectionSnapshot(id: freshID, name: "fresh", dimension: nil),
        ])
        return controller
    }

    private func reader(_ key: String) -> ExternalClient {
        ExternalClient(
            name: "читатель", keyHash: ClientKey.hash(key), keyPrefix: ClientKey.prefix(of: key),
            permissions: ClientPermissions(collections: ["public"], allowsWrite: false)
        )
    }

    private func writer(_ key: String, limits: (perDay: Int?, bytes: Int?) = (nil, nil)) -> ExternalClient {
        ExternalClient(
            name: "писатель", keyHash: ClientKey.hash(key), keyPrefix: ClientKey.prefix(of: key),
            permissions: ClientPermissions(
                collections: ["public", "fresh"], allowsWrite: true,
                maxDocumentsPerDay: limits.perDay, maxDocumentBytes: limits.bytes
            )
        )
    }

    /// Status the proxy would answer with; 200 means «forwarded».
    private func code(
        _ controller: AccessController,
        key: String?,
        _ method: String,
        _ path: String,
        body: String = ""
    ) async -> Int {
        let decision = await controller.decide(
            key: key,
            route: ChromaRoute.parse(method: method, path: path),
            body: Data(body.utf8)
        )
        if case .reject(let status, _, _, _) = decision { return status }
        return 200
    }

    func testNoKeyAndUnknownKeyAreBothRefused() async {
        let controller = await makeController(reader("k"))
        let path = "\(tenant)/\(allowedID)/get"

        let missing = await code(controller, key: nil, "POST", path)
        let empty = await code(controller, key: "", "POST", path)
        let wrong = await code(controller, key: "wrong", "POST", path)
        let right = await code(controller, key: "k", "POST", path)
        XCTAssertEqual([missing, empty, wrong, right], [401, 401, 401, 200])
    }

    func testADisabledClientLosesEverything() async {
        var client = reader("k")
        client.isEnabled = false
        let controller = await makeController(client)
        let status = await code(controller, key: "k", "POST", "\(tenant)/\(allowedID)/get")
        XCTAssertEqual(status, 403)
    }

    func testAReadOnlyKeyIsRefusedOnEveryWriteAndPassesEveryRead() async {
        let controller = await makeController(reader("k"))
        for operation in ["add", "upsert", "update", "delete"] {
            let status = await code(controller, key: "k", "POST", "\(tenant)/\(allowedID)/\(operation)")
            XCTAssertEqual(status, 403, "операция \(operation) должна быть отклонена для ключа только на чтение")
        }
        for operation in ["get", "query"] {
            let status = await code(controller, key: "k", "POST", "\(tenant)/\(allowedID)/\(operation)")
            XCTAssertEqual(status, 200, operation)
        }
        let count = await code(controller, key: "k", "GET", "\(tenant)/\(allowedID)/count?read_level=index_and_wal")
        XCTAssertEqual(count, 200)
    }

    func testAWhitelistOfOneCollectionHidesTheRest() async {
        let controller = await makeController(reader("k"))
        let allowed = await code(controller, key: "k", "POST", "\(tenant)/\(allowedID)/get")
        // 404 rather than 403: a refusal that says «forbidden» still confirms
        // that the collection exists.
        let secret = await code(controller, key: "k", "POST", "\(tenant)/\(secretID)/get")
        XCTAssertEqual([allowed, secret], [200, 404])

        // The same check through the other kind of identifier: deleting a
        // collection names it instead of using its UUID.
        let byName = await code(controller, key: "k", "DELETE", "\(tenant)/secret")
        XCTAssertEqual(byName, 403, "запись запрещена раньше, чем проверяется список коллекций")
    }

    func testListingIsTrimmedRatherThanRefused() async {
        let controller = await makeController(reader("k"))
        let decision = await controller.decide(
            key: "k",
            route: ChromaRoute.parse(method: "GET", path: tenant),
            body: Data()
        )
        guard case .allow(_, _, let filter) = decision else {
            return XCTFail("список коллекций должен отдаваться, но урезанным")
        }
        XCTAssertEqual(filter, .collectionList(allowed: ["public"]))
    }

    func testServiceEndpointsPassForAValidKeyAndOnlyForOne() async {
        let controller = await makeController(reader("k"))
        for path in ["/api/v2/heartbeat", "/api/v2/auth/identity", "/api/v2/tenants/default_tenant"] {
            let status = await code(controller, key: "k", "GET", path)
            XCTAssertEqual(status, 200, path)
        }
        // An unauthenticated probe learns nothing at all.
        let anonymous = await code(controller, key: nil, "GET", "/api/v2/heartbeat")
        XCTAssertEqual(anonymous, 401)
    }

    func testResetIsNeverProxied() async {
        let controller = await makeController(writer("k"))
        let reset = await code(controller, key: "k", "POST", "/api/v2/reset")
        XCTAssertEqual(reset, 403)
    }

    /// `get_or_create_collection` in the official client is sent as a creation
    /// even for a collection that already exists, so refusing creation outright
    /// broke ordinary use (found against the live client).
    func testGetOrCreateIsALookupForAnExistingWhitelistedCollection() async {
        let readOnly = await makeController(reader("k"))
        let existing = await code(readOnly, key: "k", "POST", tenant, body: #"{"name":"public","get_or_create":true}"#)
        XCTAssertEqual(existing, 200, "клиент только на чтение должен получать существующую коллекцию")

        // A collection outside the whitelist stays invisible even here.
        let foreign = await code(readOnly, key: "k", "POST", tenant, body: #"{"name":"secret","get_or_create":true}"#)
        XCTAssertEqual(foreign, 404)

        // A whitelisted name that does not exist yet is a real creation.
        var permissive = reader("k")
        permissive.permissions.collections = ["public", "not_yet"]
        let controller = await makeController(permissive)
        let creation = await code(controller, key: "k", "POST", tenant, body: #"{"name":"not_yet","get_or_create":true}"#)
        XCTAssertEqual(creation, 403, "создание новой коллекции требует права на запись")

        let writing = await makeController(writer("k"))
        let allowed = await code(writing, key: "k", "POST", tenant, body: #"{"name":"fresh","get_or_create":true}"#)
        XCTAssertEqual(allowed, 200)
    }

    func testUnknownEndpointsPassForReadsAndAreRefusedForWrites() async {
        let controller = await makeController(writer("k"))
        let read = await code(controller, key: "k", "GET", "/api/v2/something/new")
        let write = await code(controller, key: "k", "POST", "/api/v2/something/new")
        XCTAssertEqual([read, write], [200, 403], "deny by default действует только на запись")
    }

    func testAVectorOfTheWrongSizeIsRefusedBeforeItReachesTheDatabase() async {
        let controller = await makeController(writer("k"))
        let path = "\(tenant)/\(allowedID)/add"

        let right = await code(controller, key: "k", "POST", path, body: #"{"ids":["a"],"embeddings":[[0.1,0.2,0.3,0.4]]}"#)
        XCTAssertEqual(right, 200)

        let decision = await controller.decide(
            key: "k",
            route: ChromaRoute.parse(method: "POST", path: path),
            body: Data(#"{"ids":["a"],"embeddings":[[0.1,0.2]]}"#.utf8)
        )
        guard case .reject(let status, let message, _, _) = decision else {
            return XCTFail("вектор другой размерности не должен уходить в базу")
        }
        XCTAssertEqual(status, 400)
        XCTAssertTrue(message.contains("4") && message.contains("2"), message)
    }

    func testBase64VectorsAreCheckedToo() async {
        // The official Python client sends them this way, and a check that only
        // understood arrays would wave every one of its requests through.
        let controller = await makeController(writer("k"))
        let path = "\(tenant)/\(allowedID)/add"
        let four = await code(controller, key: "k", "POST", path, body: #"{"ids":["a"],"embeddings":["zczMPc3MTD6amZk+zczMPg=="]}"#)
        XCTAssertEqual(four, 200)
        let two = await code(controller, key: "k", "POST", path, body: #"{"ids":["a"],"embeddings":["zczMPc3MTD4="]}"#)
        XCTAssertEqual(two, 400, "восемь байт — это два float32, а не четыре")
    }

    func testTheFirstWriteIntoAnEmptyCollectionSetsTheStandard() async {
        let controller = await makeController(writer("k"))
        let path = "\(tenant)/\(freshID)/add"

        let first = await code(controller, key: "k", "POST", path, body: #"{"ids":["a"],"embeddings":[[1,2,3,4,5,6,7,8]]}"#)
        XCTAssertEqual(first, 200)
        let stored = await controller.snapshot(forCollectionID: freshID)?.dimension
        XCTAssertEqual(stored, 8, "первая запись задаёт эталон и запоминается")

        let second = await code(controller, key: "k", "POST", path, body: #"{"ids":["b"],"embeddings":[[1,2,3,4]]}"#)
        XCTAssertEqual(second, 400)
    }

    func testDailyLimitCountsDocumentsAndThenRefuses() async {
        let client = writer("k", limits: (perDay: 3, bytes: nil))
        let controller = await makeController(client)
        let path = "\(tenant)/\(allowedID)/add"
        let two = #"{"ids":["a","b"],"embeddings":[[1,2,3,4],[1,2,3,4]]}"#

        let first = await code(controller, key: "k", "POST", path, body: two)
        XCTAssertEqual(first, 200)
        let used = await controller.usageToday(for: client.id)
        XCTAssertEqual(used, 2)

        let second = await code(controller, key: "k", "POST", path, body: two)
        XCTAssertEqual(second, 429, "четвёртый документ за сутки выходит за лимит в три")
    }

    func testDocumentSizeLimit() async {
        let controller = await makeController(writer("k", limits: (perDay: nil, bytes: 10)))
        let path = "\(tenant)/\(allowedID)/add"
        let big = await code(controller, key: "k", "POST", path,
                             body: #"{"ids":["a"],"documents":["ноль один два три"],"embeddings":[[1,2,3,4]]}"#)
        XCTAssertEqual(big, 429)

        let small = await code(controller, key: "k", "POST", path,
                               body: #"{"ids":["a"],"documents":["ок"],"embeddings":[[1,2,3,4]]}"#)
        XCTAssertEqual(small, 200)
    }
}

@MainActor
final class AuditLogTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-audit-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func entry(_ operation: String, access: ChromaRoute.Access, collection: String? = "docs") -> AuditEntry {
        AuditEntry(
            client: "127.0.0.1:50000",
            method: "POST",
            path: "/api/v2/…/\(operation)",
            operation: operation,
            access: access,
            collection: collection,
            requestBytes: 100,
            responseStatus: 200,
            responseBytes: 20,
            durationSeconds: 0.01
        )
    }

    func testEntriesSurviveARestartAndComeBackNewestFirst() async throws {
        let log = AuditLog(fileURL: fileURL)
        log.record(entry("add", access: .write))
        log.record(entry("query", access: .read))
        try await waitUntil { log.entries.count == 2 }
        XCTAssertEqual(log.entries.first?.operation, "query")

        try await Task.sleep(nanoseconds: 300_000_000)
        let reopened = AuditLog(fileURL: fileURL)
        XCTAssertEqual(reopened.entries.count, 2)
        XCTAssertEqual(reopened.entries.first?.operation, "query", "последняя операция должна быть сверху")
    }

    func testWritesOnlyFilterAndSearch() async throws {
        let log = AuditLog(fileURL: fileURL)
        log.record(entry("add", access: .write, collection: "docs"))
        log.record(entry("query", access: .read, collection: "notes"))
        try await waitUntil { log.entries.count == 2 }

        XCTAssertEqual(log.filtered(writesOnly: true, collection: nil, search: "").count, 1)
        XCTAssertEqual(log.filtered(writesOnly: false, collection: "notes", search: "").count, 1)
        XCTAssertEqual(log.filtered(writesOnly: false, collection: nil, search: "quer").count, 1)
        XCTAssertEqual(log.collections, ["docs", "notes"])
    }

    func testExportIsCSVWithAHeaderAndEscaping() async throws {
        let log = AuditLog(fileURL: fileURL)
        var row = entry("add", access: .write)
        row.note = "отказ, потому что \"нельзя\""
        log.record(row)
        try await waitUntil { !log.entries.isEmpty }

        let csv = log.exportCSV(log.entries)
        XCTAssertTrue(csv.hasPrefix("date,client,method,operation"))
        XCTAssertTrue(csv.contains("\"\"нельзя\"\""), "кавычки и запятые в поле должны экранироваться: \(csv)")
    }

    func testATruncatedLastLineDoesNotCostTheWholeFile() throws {
        let good = #"{"id":"3E3B4C24-0000-0000-0000-000000000001","date":"2026-07-30T10:00:00Z","client":"c","method":"POST","path":"/p","operation":"add","access":"write","requestBytes":1,"responseBytes":2,"durationSeconds":0.1}"#
        try (good + "\n" + #"{"id":"broken"#).write(to: fileURL, atomically: true, encoding: .utf8)
        let log = AuditLog(fileURL: fileURL)
        XCTAssertEqual(log.entries.count, 1)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("условие не выполнилось за отведённое время")
    }
}
