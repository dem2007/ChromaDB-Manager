import XCTest
@testable import ChromaCore

/// Records every request so a test can assert what was *not* sent.
private final class WatchingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [(method: String, path: String)] = []
    /// path suffix → body; the first match answers.
    var replies: [(suffix: String, json: String)] = []

    var calls: [(method: String, path: String)] {
        lock.lock(); defer { lock.unlock() }
        return sent
    }

    var writes: [(method: String, path: String)] {
        calls.filter { call in
            // Reads in this API are POSTs to /get and /query; everything that
            // changes state is a PUT, a DELETE, or a POST to a writing path.
            switch call.method {
            case "PUT", "DELETE", "PATCH": return true
            case "POST":
                return !(call.path.hasSuffix("/get")
                    || call.path.hasSuffix("/query")
                    || call.path.hasSuffix("/count"))
            default: return false
            }
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        lock.lock()
        sent.append((request.httpMethod ?? "GET", path))
        lock.unlock()
        let json = replies.first { path.hasSuffix($0.suffix) }?.json ?? "{}"
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(json.utf8), response)
    }
}

/// 6 + J1: a collection made by someone else is read, described and queried,
/// and nothing is written back into it — not the metric, not the model, not the
/// dimension. "Пришёл посмотреть чужую базу" is a read-only scenario even
/// before the read-only connection of J1 exists.
final class ForeignCollectionTests: XCTestCase {
    /// No `_cdbm_*` metadata at all, and the metric only in the server's own
    /// configuration — the normal shape of a collection built elsewhere.
    private let foreign = #"""
    [{"id":"11111111-2222-3333-4444-555555555555","name":"чужая",
      "metadata":{"note":"сделано другим клиентом"},
      "configuration_json":{"hnsw":{"space":"ip","ef_construction":100}}}]
    """#

    private func makeClient(_ transport: WatchingTransport) -> ChromaClient {
        ChromaClient(
            endpoint: ChromaEndpoint(host: "127.0.0.1", port: 8000),
            log: noopLogHandler,
            transport: transport
        )
    }

    func testLookingAtAForeignCollectionWritesNothing() async throws {
        let transport = WatchingTransport()
        transport.replies = [
            ("/collections", foreign),
            ("/get", #"{"ids":["a"],"documents":["текст"],"metadatas":[{"note":"своё"}],"embeddings":null}"#),
            ("/query", #"{"ids":[["a"]],"documents":[["текст"]],"metadatas":[[null]],"distances":[[0.3]]}"#),
            ("/count", "1"),
        ]
        let client = makeClient(transport)

        let collection = try await client.collection(named: "чужая")
        _ = try await client.getDocuments(collectionID: collection.id, limit: 100)
        _ = try await client.query(collectionID: collection.id, embedding: [0.1, 0.2], nResults: 5)
        _ = try await client.count(collectionID: collection.id)

        XCTAssertTrue(
            transport.writes.isEmpty,
            "просмотр не должен ничего записывать, а отправлено: \(transport.writes)"
        )
    }

    /// The metric is shown as the server reports it — and only there. Writing it
    /// into `_cdbm_space` "at the first write" would collide with J1.
    func testTheMetricIsReadFromTheServerAndNotCopiedIntoMetadata() async throws {
        let transport = WatchingTransport()
        transport.replies = [("/collections", foreign)]
        let collection = try await makeClient(transport).collection(named: "чужая")

        XCTAssertEqual(collection.space, .ip)
        XCTAssertNil(collection.metadata?[CollectionBindingKeys.space], "метрика не дублируется в метаданные чужой коллекции")
        XCTAssertTrue(transport.writes.isEmpty)
    }

    func testTheModelAndDimensionAreNotInventedEither() async throws {
        let transport = WatchingTransport()
        transport.replies = [("/collections", foreign)]
        let collection = try await makeClient(transport).collection(named: "чужая")

        XCTAssertNil(collection.dimension, "размерность чужой коллекции неизвестна, а не «по умолчанию»")
        XCTAssertNil(collection.metadata?[CollectionBindingKeys.model])
        XCTAssertNil(collection.metadata?[CollectionBindingKeys.dimension])
    }

    /// A collection whose metric nobody stated stays unknown: guessing `cosine`
    /// is forbidden, and the app has no other way to know.
    func testACollectionWithoutAMetricIsNotGivenOne() async throws {
        let transport = WatchingTransport()
        transport.replies = [("/collections", #"""
        [{"id":"66666666-7777-8888-9999-000000000000","name":"безымянная","metadata":{}}]
        """#)]
        let collection = try await makeClient(transport).collection(named: "безымянная")

        XCTAssertNil(collection.space)
        XCTAssertTrue(transport.writes.isEmpty)
    }

    /// Binding a model by hand is a different thing entirely: the user asked for
    /// it, so it writes — and that is the only path that may (5.5).
    func testBindingAModelByHandIsTheOnlyWayMetadataGetsWritten() async throws {
        let transport = WatchingTransport()
        transport.replies = [
            ("/collections", foreign),
            ("/get", #"{"ids":["a"],"documents":null,"metadatas":null,"embeddings":[[0.1,0.2,0.3,0.4]]}"#),
        ]
        let client = makeClient(transport)
        let collection = try await client.collection(named: "чужая")
        XCTAssertTrue(transport.writes.isEmpty, "до явного действия — ни одной записи")

        try await client.updateCollection(
            id: collection.id,
            metadata: collection.metadataBinding(model: "nomic-embed", dimension: 4)
        )
        XCTAssertEqual(transport.writes.count, 1)
        XCTAssertEqual(transport.writes.first?.method, "PUT")
    }
}
