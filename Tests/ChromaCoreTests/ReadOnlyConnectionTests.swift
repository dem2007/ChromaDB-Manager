import XCTest
@testable import ChromaCore

/// Counts every request that reaches the network.
private final class CountingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sent: [(method: String, path: String)] = []
    var reply = "{}"

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return sent.count
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        sent.append((request.httpMethod ?? "GET", request.url?.path ?? ""))
        lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(reply.utf8), response)
    }
}

/// a connection opened for reading refuses writes at the client, before a
/// request exists. Hiding buttons is not enough — writes also arrive from
/// synchronisation, from import and (later) from MCP.
final class ReadOnlyConnectionTests: XCTestCase {
    private func client(_ transport: CountingTransport, readOnly: Bool) -> ChromaClient {
        ChromaClient(
            endpoint: ChromaEndpoint(host: "127.0.0.1", port: 8000),
            log: noopLogHandler,
            retries: .never,
            transport: transport,
            isReadOnly: readOnly
        )
    }

    private func record(_ id: String = "d1") -> EmbeddedRecord {
        EmbeddedRecord(id: id, document: "текст", embedding: [0.1, 0.2, 0.3, 0.4], metadata: [:])
    }

    /// Every write path in one test: the point is the total, not each case.
    func testNoWriteScenarioSendsAnything() async throws {
        let transport = CountingTransport()
        let subject = client(transport, readOnly: true)

        var refused = 0
        func expectRefusal(_ operation: String, _ body: () async throws -> Void) async {
            do {
                try await body()
                XCTFail("«\(operation)» должна была быть отклонена")
            } catch ChromaError.readOnly(let named) {
                XCTAssertEqual(named, operation)
                refused += 1
            } catch {
                XCTFail("«\(operation)»: неожиданная ошибка \(error)")
            }
        }

        await expectRefusal("создание коллекции") { _ = try await subject.createCollection(name: "новая") }
        await expectRefusal("изменение коллекции") { try await subject.updateCollection(id: "id", metadata: [:]) }
        await expectRefusal("удаление коллекции") { try await subject.deleteCollection(name: "старая") }
        await expectRefusal("запись документов") { try await subject.add(collectionID: "id", records: [self.record()]) }
        await expectRefusal("запись документов") { try await subject.upsert(collectionID: "id", records: [self.record()]) }
        await expectRefusal("правка документов") {
            try await subject.updateDocuments(collectionID: "id", updates: [DocumentUpdate(id: "d1", document: "новый")])
        }
        await expectRefusal("удаление документов") { try await subject.deleteDocuments(collectionID: "id", ids: ["d1"]) }
        await expectRefusal("удаление документов по фильтру") {
            _ = try await subject.deleteDocuments(collectionID: "id", filter: DocumentFilter(documentContains: "текст"))
        }
        await expectRefusal("сброс базы") { try await subject.reset() }
        await expectRefusal("создание тенанта") { try await subject.createTenant(name: "t") }
        await expectRefusal("создание базы") { try await subject.createDatabase(name: "db") }

        XCTAssertEqual(refused, 11)
        XCTAssertEqual(transport.count, 0, "ни один запрос не должен был уйти: \(transport.sent)")
    }

    func testReadingIsUntouched() async throws {
        let transport = CountingTransport()
        transport.reply = #"{"ids":["a"],"documents":["текст"],"metadatas":[null],"embeddings":null}"#
        let subject = client(transport, readOnly: true)

        let records = try await subject.getDocuments(collectionID: "id", limit: 10)
        XCTAssertEqual(records.map(\.id), ["a"])
        XCTAssertEqual(transport.count, 1)
    }

    /// The same operations on an ordinary connection go out as before — the
    /// guard must not be a permanent brake.
    func testAWritableConnectionStillWrites() async throws {
        let transport = CountingTransport()
        transport.reply = #"{"ids":["d1"]}"#
        let subject = client(transport, readOnly: false)

        try await subject.upsert(collectionID: "id", records: [record()])
        XCTAssertGreaterThan(transport.count, 0)
    }

    func testTheFlagIsFixedAtCreation() async {
        let transport = CountingTransport()
        let readOnly = client(transport, readOnly: true)
        let writable = client(transport, readOnly: false)
        // A10: two clients to the same address, each with its own rules; there
        // is no setter to flip one into the other.
        let readOnlyFlag = await readOnly.isReadOnly
        let writableFlag = await writable.isReadOnly
        XCTAssertTrue(readOnlyFlag)
        XCTAssertFalse(writableFlag)
    }

    func testTheErrorSaysWhatWasRefusedAndHowToAllowIt() {
        let error = ChromaError.readOnly(operation: "запись документов")
        XCTAssertTrue(error.errorDescription?.contains("только для чтения") == true)
        XCTAssertTrue(error.errorDescription?.contains("запись документов") == true)
        XCTAssertTrue(error.recoverySuggestion?.contains("профиле подключения") == true)
    }
}
