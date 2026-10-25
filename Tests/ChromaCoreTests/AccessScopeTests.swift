import XCTest
@testable import ChromaCore

/// Разбор ревью прокси и MCP: что ключ видит за пределами своих коллекций.
final class AccessScopeTests: XCTestCase {
    private func controller(allowsWrite: Bool = false) async -> (AccessController, String) {
        let (client, key) = ExternalClient.issue(
            name: "тест",
            permissions: ClientPermissions(collections: ["notes"], allowsWrite: allowsWrite, requestsPerMinute: 600, burst: 600)
        )
        let controller = AccessController()
        await controller.setClients([client])
        await controller.setCatalog([
            CollectionSnapshot(id: "id-notes", name: "notes", dimension: 4),
            CollectionSnapshot(id: "id-secret", name: "secret", dimension: 4),
        ])
        return (controller, key)
    }

    private let base = "/api/v2/tenants/default_tenant/databases/default_database"

    private func code(
        _ access: AccessController, _ key: String, _ route: ChromaRoute, _ body: Data = Data()
    ) async -> Int? {
        if case .reject(let status, _, _, _) = await access.decide(key: key, route: route, body: body) { return status }
        return nil
    }

    /// Неизвестное чтение внутри коллекции проходит проверку коллекции.
    func testAnUnknownReadInsideACollectionHonoursTheWhitelist() async {
        let (access, key) = await controller()
        let secret = ChromaRoute.parse(method: "GET", path: "\(base)/collections/id-secret/indexing_status")
        let c1 = await code(access, key, secret, Data())
        XCTAssertEqual(c1, 404)
        let mine = ChromaRoute.parse(method: "GET", path: "\(base)/collections/id-notes/indexing_status")
        let c2 = await code(access, key, mine, Data())
        XCTAssertNil(c2)
    }

    /// Неизвестное чтение уровня базы отвечает про все коллекции — отказ;
    /// неизвестная служебная ручка вне тенанта — проходит.
    func testAnUnknownDatabaseLevelReadIsRefused() async {
        let (access, key) = await controller()
        let count = ChromaRoute.parse(method: "GET", path: "\(base)/collections_count")
        let c3 = await code(access, key, count, Data())
        XCTAssertEqual(c3, 403)
        let databases = ChromaRoute.parse(method: "GET", path: "/api/v2/tenants/default_tenant/databases")
        let c4 = await code(access, key, databases, Data())
        XCTAssertEqual(c4, 403)
        let service = ChromaRoute.parse(method: "GET", path: "/api/v2/something_new")
        let c5 = await code(access, key, service, Data())
        XCTAssertNil(c5)
    }

    /// Чужая база с тем же именем коллекции — не здешняя коллекция.
    func testAnotherDatabaseIsNotReachedByName() async {
        let (access, key) = await controller()
        let other = ChromaRoute.parse(
            method: "POST", path: "/api/v2/tenants/default_tenant/databases/hr/collections/notes/get"
        )
        let c6 = await code(access, key, other, Data())
        XCTAssertEqual(c6, 404)
        let create = ChromaRoute.parse(method: "POST", path: "/api/v2/tenants/default_tenant/databases/hr/collections")
        let c7 = await code(access, key, create, Data(#"{"name":"notes"}"#.utf8))
        XCTAssertEqual(c7, 404)
        // Своя база — как прежде.
        let mine = ChromaRoute.parse(method: "POST", path: "\(base)/collections/notes/get")
        let c8 = await code(access, key, mine, Data())
        XCTAssertNil(c8)
    }

    /// Тело записи, которое не разбирается, — отказ: иначе лимиты молчат.
    func testAnUnreadableWriteBodyIsRefused() async {
        let (access, key) = await controller(allowsWrite: true)
        let upsert = ChromaRoute.parse(method: "POST", path: "\(base)/collections/id-notes/upsert")
        let c9 = await code(access, key, upsert, Data("[1,2]".utf8))
        XCTAssertEqual(c9, 400)
        let c10 = await code(access, key, upsert, Data(#"{"ids":["a"],"documents":["текст"],"embeddings":[[0.1,0.2,0.3,0.4]]}"#.utf8))
        XCTAssertNil(c10)
    }

    /// Пересчитываемая коллекция закрыта для записи снаружи — и прокси,
    /// и MCP; чтение идёт как прежде, после пересчёта запись открывается.
    func testWritesToACollectionBeingReembeddedAreRefused() async {
        let (access, key) = await controller(allowsWrite: true)
        let upsert = ChromaRoute.parse(method: "POST", path: "\(base)/collections/id-notes/upsert")
        let body = Data(#"{"ids":["a"],"documents":["текст"],"embeddings":[[0.1,0.2,0.3,0.4]]}"#.utf8)
        let read = ChromaRoute.parse(method: "POST", path: "\(base)/collections/id-notes/get")

        await access.freezeWrites(to: ["notes"])
        let frozenWrite = await code(access, key, upsert, body)
        XCTAssertEqual(frozenWrite, 409)
        let frozenRead = await code(access, key, read)
        XCTAssertNil(frozenRead)
        let tool = await access.decideTool(key: key, permission: .write, collection: "notes", isReadOnlyServer: false)
        XCTAssertNil(tool.client)
        let toolRead = await access.decideTool(key: key, permission: .read, collection: "notes", isReadOnlyServer: false)
        XCTAssertNotNil(toolRead.client)

        await access.thawWrites(to: ["notes"])
        let thawed = await code(access, key, upsert, body)
        XCTAssertNil(thawed)
    }

    /// Перебор ключей упирается в предел: сверх запаса — 429, и в журнал
    /// попадает первый отказ окна, а не каждый.
    func testRequestsWithoutAValidKeyAreThrottled() async {
        let (access, _) = await controller()
        let read = ChromaRoute.parse(method: "POST", path: "\(base)/collections/id-notes/get")
        var statuses: [Int?] = []
        for index in 0...AccessController.anonymousBurst {
            statuses.append(await code(access, "подбор-\(index)", read))
        }
        XCTAssertEqual(Set(statuses.dropLast()), [401])
        XCTAssertEqual(statuses.last, 429)
        let noKey = await code(access, "", read)
        XCTAssertEqual(noKey, 429)

        let start = Date()
        let first = await access.reportAnonymousRefusal(now: start)
        XCTAssertEqual(first, 0)
        let quiet = await access.reportAnonymousRefusal(now: start.addingTimeInterval(10))
        XCTAssertNil(quiet)
        let next = await access.reportAnonymousRefusal(now: start.addingTimeInterval(61))
        XCTAssertEqual(next, 1)
    }

    /// Ответ, которого фильтр не понял, — пустой список, а не всё подряд.
    func testTheCollectionFilterFailsClosed() throws {
        let wrapped = Data(#"{"collections":[{"name":"secret"}],"total":1}"#.utf8)
        let filtered = ProxyConnection.filterCollectionList(wrapped, allowed: ["notes"])
        XCTAssertEqual(String(decoding: filtered, as: UTF8.self), "[]")
    }

    /// Строка статуса называет сам код, а не «OK» всему ниже 400.
    func testStatusLinesNameTheirCode() {
        XCTAssertEqual(ProxyConnection.reason(for: 204), "No Content")
        XCTAssertEqual(ProxyConnection.reason(for: 304), "Not Modified")
        XCTAssertEqual(ProxyConnection.reason(for: 409), "Conflict")
        XCTAssertEqual(ProxyConnection.reason(for: 503), "Service Unavailable")
        XCTAssertEqual(ProxyConnection.reason(for: 299), "Success")
    }

    /// Служебные поля метаданных агент не пишет.
    func testReservedMetadataKeysAreRecognised() {
        for key in ["source_file", "file_id", "source_id", "chunk_index", "_cdbm_mark", "_cdbm_origin", "parent_chunk_id"] {
            XCTAssertTrue(MCPToolService.isReservedMetadataKey(key), key)
        }
        for key in ["author", "year", "topic"] {
            XCTAssertFalse(MCPToolService.isReservedMetadataKey(key), key)
        }
    }
}
