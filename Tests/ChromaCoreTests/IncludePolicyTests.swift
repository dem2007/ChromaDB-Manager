import XCTest
@testable import ChromaCore

/// `include` is always sent explicitly, and never asks for more than the
/// screen shows. The server default is not a safe fallback.
private final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [(path: String, json: [String: Any])] = []
    var reply: String = #"{"ids":[]}"#

    func body(forPathSuffix suffix: String) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return bodies.last { $0.path.hasSuffix(suffix) }?.json
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        if let data = request.httpBody,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            lock.lock()
            bodies.append((path, json))
            lock.unlock()
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(reply.utf8), response)
    }
}

final class IncludePolicyTests: XCTestCase {
    private func makeClient(_ transport: RecordingTransport, log: @escaping LogHandler = noopLogHandler) -> ChromaClient {
        ChromaClient(
            endpoint: ChromaEndpoint(host: "127.0.0.1", port: 8000),
            log: log,
            transport: transport
        )
    }

    private func include(_ body: [String: Any]?) -> [String]? {
        body?["include"] as? [String]
    }

    // MARK: - The table in A3.2

    func testAPageOfDocumentsAsksForTextAndMetadataOnly() async throws {
        let transport = RecordingTransport()
        transport.reply = #"{"ids":["a"],"documents":["текст"],"metadatas":[null],"embeddings":null}"#
        _ = try await makeClient(transport).getDocuments(collectionID: "c", limit: 100)
        XCTAssertEqual(include(transport.body(forPathSuffix: "/get")), ["documents", "metadatas"])
    }

    func testAQueryAsksForDistancesAsWell() async throws {
        let transport = RecordingTransport()
        transport.reply = #"{"ids":[["a"]],"documents":[["текст"]],"metadatas":[[null]],"distances":[[0.25]]}"#
        _ = try await makeClient(transport).query(collectionID: "c", embedding: [0.1, 0.2], nResults: 3)
        XCTAssertEqual(include(transport.body(forPathSuffix: "/query")), ["documents", "metadatas", "distances"])
    }

    /// An existence check needs the ids and nothing else — verified against a
    /// live server before being relied on.
    func testAnExistenceCheckAsksForNothing() async throws {
        let transport = RecordingTransport()
        transport.reply = #"{"ids":["a"],"documents":null,"metadatas":null,"embeddings":null}"#
        _ = try await makeClient(transport).existingIDs(collectionID: "c", ids: ["a", "b"])
        let body = transport.body(forPathSuffix: "/get")
        XCTAssertEqual(include(body), [])
        XCTAssertEqual(body?["ids"] as? [String], ["a", "b"])
    }

    func testOneDocumentsVectorIsAskedForByIDAlone() async throws {
        let transport = RecordingTransport()
        transport.reply = #"{"ids":["a"],"embeddings":[[0.1,0.2]],"documents":null,"metadatas":null}"#
        _ = try await makeClient(transport).embeddings(collectionID: "c", ids: ["a"])
        let body = transport.body(forPathSuffix: "/get")
        XCTAssertEqual(include(body), ["embeddings"])
        XCTAssertEqual(body?["ids"] as? [String], ["a"])
        XCTAssertNil(body?["limit"], "вектор одного документа берётся по id, а не страницей")
    }

    func testNothingEverAsksForURIsOrData() async throws {
        let transport = RecordingTransport()
        transport.reply = #"{"ids":["a"],"documents":["текст"],"metadatas":[null],"embeddings":null}"#
        let client = makeClient(transport)
        _ = try await client.getDocuments(collectionID: "c", limit: 10)
        let requested = include(transport.body(forPathSuffix: "/get")) ?? []
        XCTAssertFalse(requested.contains("uris"))
        XCTAssertFalse(requested.contains("data"))
    }

    // MARK: - A3.3: the beacon

    func testAskingForAPageOfVectorsIsReportedInTheLog() async throws {
        let transport = RecordingTransport()
        transport.reply = #"{"ids":["a"],"documents":["текст"],"metadatas":[null],"embeddings":[[0.1]]}"#
        let warnings = Warnings()
        let client = makeClient(transport, log: { level, _, message in
            if level == .warning { warnings.add(message) }
        })
        _ = try await client.getDocuments(collectionID: "c", limit: 100, includeEmbeddings: true)
        let messages = warnings.all
        XCTAssertEqual(messages.count, 1, "маячок должен сработать ровно один раз")
        XCTAssertTrue(messages.first?.contains("векторы страницей") == true, messages.first ?? "")
        // "с указанием места вызова" — the caller, not this file's internals.
        XCTAssertTrue(messages.first?.contains("IncludePolicyTests") == true, messages.first ?? "")
    }

    func testAskingForOneDocumentsVectorIsSilent() async throws {
        let transport = RecordingTransport()
        transport.reply = #"{"ids":["a"],"documents":["текст"],"metadatas":[null],"embeddings":[[0.1]]}"#
        let warnings = Warnings()
        let client = makeClient(transport, log: { level, _, message in
            if level == .warning { warnings.add(message) }
        })
        _ = try await client.getDocuments(
            collectionID: "c", limit: 1, includeEmbeddings: true, ids: ["a"]
        )
        XCTAssertTrue(warnings.all.isEmpty, warnings.all.joined(separator: "; "))
    }

    func testAPageWithoutVectorsIsSilent() async throws {
        let transport = RecordingTransport()
        transport.reply = #"{"ids":["a"],"documents":["текст"],"metadatas":[null],"embeddings":null}"#
        let warnings = Warnings()
        let client = makeClient(transport, log: { level, _, message in
            if level == .warning { warnings.add(message) }
        })
        _ = try await client.getDocuments(collectionID: "c", limit: 500)
        XCTAssertTrue(warnings.all.isEmpty, warnings.all.joined(separator: "; "))
    }

    // MARK: - Reading what comes back

    /// `embeddings: null` is the normal answer, not a parsing failure — this is
    /// exactly where naive clients break.
    func testAResponseWithoutEmbeddingsIsRead() async throws {
        let transport = RecordingTransport()
        transport.reply = #"{"ids":["a","b"],"documents":["первый","второй"],"metadatas":[{"k":"v"},null],"embeddings":null,"uris":null}"#
        let records = try await makeClient(transport).getDocuments(collectionID: "c", limit: 2)
        XCTAssertEqual(records.map(\.id), ["a", "b"])
        XCTAssertEqual(records.first?.document, "первый")
        XCTAssertEqual(records.first?.metadata?["k"], .string("v"))
        XCTAssertNil(records.last?.metadata, "документ без метаданных — законная ситуация")
        XCTAssertNil(records.first?.embeddingDimension)
    }

    func testAResponseWithoutDocumentsOrMetadataIsRead() async throws {
        let transport = RecordingTransport()
        transport.reply = #"{"ids":["a"],"documents":null,"metadatas":null,"embeddings":null}"#
        let records = try await makeClient(transport).getDocuments(collectionID: "c", limit: 1)
        XCTAssertEqual(records.map(\.id), ["a"])
        XCTAssertNil(records.first?.document)
        XCTAssertNil(records.first?.metadata)
    }

    /// `query` groups its answer one level deeper than `get` — the usual place
    /// to get the shape wrong.
    func testTheQueryAnswerIsNestedOneLevelDeeper() async throws {
        let transport = RecordingTransport()
        transport.reply = #"""
        {"ids":[["a","b"]],"documents":[["первый","второй"]],
         "metadatas":[[{"k":"v"},null]],"distances":[[0.1,0.4]]}
        """#
        let hits = try await makeClient(transport).query(collectionID: "c", embedding: [0.1], nResults: 2)
        XCTAssertEqual(hits.map(\.id), ["a", "b"])
        XCTAssertEqual(hits.first?.distance, 0.1)
        XCTAssertEqual(hits.last?.document, "второй")
        XCTAssertNil(hits.last?.metadata)
    }
}

/// Collects log lines from the client's own log handler, which is called from
/// inside an actor.
private final class Warnings: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: String) {
        lock.lock(); lines.append(line); lock.unlock()
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}
