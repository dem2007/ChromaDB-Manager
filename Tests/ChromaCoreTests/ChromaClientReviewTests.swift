import XCTest
@testable import ChromaCore

/// Разбор ревью `ChromaClient`: деление правок, устаревшие идентификаторы
/// удалённых и пересозданных коллекций, имена в адресе.

/// Сервер, у которого коллекции можно удалять и пересоздавать на ходу.
private final class LiveTransport: HTTPTransport, @unchecked Sendable {
    private var live: [String: String]
    private var calls: [(path: String, body: [String: Any])] = []
    private let lock = NSLock()
    /// Задержка ответа на список коллекций — чтобы два вызова успели
    /// разойтись на ожидании.
    var listDelay: TimeInterval = 0
    let maxBatch: Int

    init(live: [String: String], maxBatch: Int = 100) {
        self.live = live
        self.maxBatch = maxBatch
    }

    func replace(_ name: String, with id: String) {
        lock.lock(); defer { lock.unlock() }
        live[name] = id
    }

    func remove(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        live.removeValue(forKey: name)
    }

    func bodies(_ suffix: String) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return calls.filter { $0.path.hasSuffix(suffix) }.map(\.body)
    }

    var paths: [String] {
        lock.lock(); defer { lock.unlock() }
        return calls.map(\.path)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        lock.lock()
        calls.append((path, body))
        let known = live
        lock.unlock()

        func reply(_ status: Int, _ text: String) -> (Data, HTTPURLResponse) {
            (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        if path.hasSuffix("/pre-flight-checks") { return reply(200, #"{"max_batch_size": \#(maxBatch)}"#) }
        if path.hasSuffix("/collections") {
            if listDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(listDelay * 1_000_000_000)) }
            let items = known.map { #"{"id":"\#($0.value)","name":"\#($0.key)"}"# }
            return reply(200, "[\(items.joined(separator: ","))]")
        }
        let parts = path.split(separator: "/")
        guard let index = parts.firstIndex(of: "collections"), index + 1 < parts.count else {
            return reply(404, "")
        }
        let id = String(parts[index + 1])
        guard known.values.contains(id) else {
            return reply(404, #"{"error":"NotFoundError","message":"Collection [\#(id)] does not exist."}"#)
        }
        if path.hasSuffix("/count") { return reply(200, "7") }
        if path.hasSuffix("/delete") { return reply(200, #"{"deleted":1}"#) }
        return reply(200, "{}")
    }
}

final class ChromaClientReviewTests: XCTestCase {
    private func client(_ transport: LiveTransport, endpoint: ChromaEndpoint = ChromaEndpoint()) -> ChromaClient {
        ChromaClient(endpoint: endpoint, retries: .never, transport: transport)
    }

    /// Правка документов делится по пределу сервера, как запись и удаление.
    func testUpdatesAreCutIntoRequestsTheServerAccepts() async throws {
        let transport = LiveTransport(live: ["notes": "id-1"], maxBatch: 100)
        let subject = client(transport)
        let updates = (0..<250).map { DocumentUpdate(id: "d\($0)", metadata: ["k": .int($0)]) }
        try await subject.updateDocuments(collectionID: "id-1", updates: updates)

        let sent = transport.bodies("/update")
        XCTAssertEqual(sent.count, 3)
        XCTAssertTrue(sent.allSatisfy { ($0["ids"] as? [String])?.count ?? 0 <= 100 })
        XCTAssertEqual(sent.flatMap { $0["ids"] as? [String] ?? [] }, updates.map(\.id))
        XCTAssertEqual(sent.map { ($0["metadatas"] as? [Any])?.count ?? 0 }, [100, 100, 50])
    }

    /// Коллекцию удалили мимо приложения, а её идентификатор ещё в памяти:
    /// «Удалить из базы» для её исчезнувших файлов — не ошибка, а «удалять
    /// нечего», и файл забывается.
    func testRemovingFilesOfACollectionDeletedElsewhereSucceeds() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cdbm-gone-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ManifestStore(directory: root)
        let service = SourceSyncService(manifests: store, tableManifests: TableManifestStore(directory: root))
        let source = DataSource(name: "docs", path: root.path, fileExtensions: ["md"], collectionName: "docs_col")
        var manifest = store.load(sourceID: source.id)
        manifest.record(ManifestEntry(
            relativePath: "a.md", contentHash: "h", modifiedAt: Date(), size: 1,
            chunkIDs: ["x-0"], collectionName: "docs_col",
            chunkingSignature: source.chunking.signature, embeddingModel: "m"
        ))
        store.save(manifest)

        let transport = LiveTransport(live: ["docs_col": "id-1"])
        let subject = client(transport)
        _ = try await subject.resolveID(of: "docs_col")
        transport.remove("docs_col")

        let deleted = try await service.resolve(
            removal: PendingRemoval(relativePath: "a.md", collectionName: "docs_col", chunkIDs: ["x-0"]),
            decision: .deleteChunks, source: source, chroma: subject
        )
        XCTAssertEqual(deleted, 0)
        XCTAssertNil(store.load(sourceID: source.id).entries["a.md"])
    }

    /// Два вызова по одному устаревшему идентификатору одновременно —
    /// оба проходят на новом, а не второй падает, пока первый спасает.
    func testConcurrentCallsOnAStaleIDAreBothRescued() async throws {
        let transport = LiveTransport(live: ["notes": "id-1"])
        let subject = client(transport)
        _ = try await subject.resolveID(of: "notes")
        transport.replace("notes", with: "id-2")
        transport.listDelay = 0.05

        async let first = subject.count(collectionID: "id-1")
        async let second = subject.count(collectionID: "id-1")
        let counts = try await [first, second]
        XCTAssertEqual(counts, [7, 7])
    }

    /// Пересоздали две коллекции — спасаются старые идентификаторы обеих,
    /// и не только при первом обращении.
    func testEveryRetiredIDKeepsItsName() async throws {
        let transport = LiveTransport(live: ["a": "a-1", "b": "b-1"])
        let subject = client(transport)
        _ = try await subject.resolveID(of: "a")
        _ = try await subject.resolveID(of: "b")
        transport.replace("a", with: "a-2")
        transport.replace("b", with: "b-2")

        let a = try await subject.count(collectionID: "a-1")
        let b = try await subject.count(collectionID: "b-1")
        let again = try await subject.count(collectionID: "a-1")
        XCTAssertEqual([a, b, again], [7, 7, 7])
    }

    /// Тенант с пробелом или кириллицей — допустимое на сервере имя, а не
    /// «некорректный URL» под видом недоступного сервера.
    func testTenantAndDatabaseAreEncodedInThePath() async throws {
        let transport = LiveTransport(live: [:])
        let subject = client(transport, endpoint: ChromaEndpoint(tenant: "мой тенант", database: "ok_db"))
        _ = try await subject.listCollections(withCounts: false)
        XCTAssertEqual(transport.paths.last, "/api/v2/tenants/мой тенант/databases/ok_db/collections")
    }

    /// Счёт документов приходит к каждой коллекции списка, если его попросили;
    /// по умолчанию — нет: `count` поднимает индекс коллекции в память сервера
    ///.
    func testEveryCollectionGetsItsCount() async throws {
        let transport = LiveTransport(live: (0..<12).reduce(into: [:]) { $0["c\($1)"] = "id-\($1)" })
        let subject = client(transport)
        let collections = try await subject.listCollections(withCounts: true)
        XCTAssertEqual(collections.count, 12)
        XCTAssertTrue(collections.allSatisfy { $0.documentCount == 7 })
    }
}

/// последнее известное число документов коллекции.
final class CollectionCountStoreTests: XCTestCase {
    func testCountsSurviveARestartAndVanishedCollectionsAreForgotten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("counts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CollectionCountStore(fileURL: url)
        store.record(187_319, for: "a")
        store.record(5, for: "b")
        let reopened = CollectionCountStore(fileURL: url)
        XCTAssertEqual(reopened.count(for: "a"), 187_319)
        reopened.forget(["a"])
        XCTAssertNil(CollectionCountStore(fileURL: url).count(for: "a"))
        XCTAssertEqual(CollectionCountStore(fileURL: url).count(for: "b"), 5)
    }
}
