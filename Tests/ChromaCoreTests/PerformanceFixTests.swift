import XCTest
@testable import ChromaCore

/// Разбор ревью модулей, производительность: то, что можно проверить без
/// живого сервера.
final class PerformanceFixTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Контрольная точка пересчёта

    /// Готовое дописывается построчно и читается вместе с точкой; снятая
    /// точка уносит и список.
    func testDoneIDsAreAppendedBesideTheCheckpoint() {
        let journal = ReembeddingJournal(fileURL: root.appendingPathComponent("reembedding.json"))
        journal.save(ReembeddingCheckpoint(
            collectionID: "c-1", collectionName: "c", targetModel: "m", chunkingSignature: "",
            rechunk: false, doneIDs: ["old"], totalIDs: 4, startedAt: Date(), runStamp: "r"
        ))
        journal.appendDone(["a", "b\nс переводом"], collectionID: "c-1")
        journal.appendDone(["a", "c"], collectionID: "c-1")

        let checkpoint = journal.checkpoint(for: "c-1")
        XCTAssertEqual(checkpoint?.doneIDs, ["old", "a", "b\nс переводом", "c"])
        XCTAssertEqual(checkpoint?.processed, 4)

        journal.clearCheckpoint(collectionID: "c-1")
        XCTAssertNil(journal.checkpoint(for: "c-1"))
        XCTAssertTrue(journal.doneIDs(collectionID: "c-1").isEmpty)
    }

    // MARK: - Потолок ответа прокси

    /// Ответ, вылезший за предел, обрывается, а не дочитывается в память.
    func testAnOversizedUpstreamAnswerIsRefused() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BigAnswer.self]
        let downloads = CappedDownloads(limit: 100)
        let session = URLSession(configuration: configuration, delegate: downloads, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await downloads.data(for: URLRequest(url: URL(string: "http://upstream.test/big")!), in: session)
            XCTFail("ответ больше предела должен оборваться")
        } catch {
            XCTAssertTrue(error is CappedDownloads.TooLarge, "\(error)")
        }

        let (data, response) = try await downloads.data(
            for: URLRequest(url: URL(string: "http://upstream.test/small")!), in: session
        )
        XCTAssertEqual(data.count, 10)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    // MARK: - Тяжёлые вызовы MCP

    func testOneHeavyCallPerKey() async {
        let access = AccessController()
        let id = UUID()
        let first = await access.beginHeavyCall(for: id)
        let second = await access.beginHeavyCall(for: id)
        let other = await access.beginHeavyCall(for: UUID())
        XCTAssertTrue(first)
        XCTAssertFalse(second, "второй обход того же ключа ждёт первого")
        XCTAssertTrue(other)
        await access.endHeavyCall(for: id)
        let again = await access.beginHeavyCall(for: id)
        XCTAssertTrue(again)
    }

    // MARK: - Хеш файла из плана

    /// Хеш, посчитанный планом, едет в элементе — прогон не читает файл заново.
    func testThePlanCarriesTheFileHashItComputed() async throws {
        let folder = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = ManifestStore(directory: root.appendingPathComponent("manifests"))
        let service = SourceSyncService(
            manifests: store, tableManifests: TableManifestStore(directory: root.appendingPathComponent("manifests"))
        )
        let source = DataSource(name: "docs", path: folder.path, fileExtensions: ["md"], collectionName: "docs_col")
        let file = folder.appendingPathComponent("a.md")
        try "новый текст".write(to: file, atomically: true, encoding: .utf8)
        var manifest = store.load(sourceID: source.id)
        manifest.record(ManifestEntry(
            relativePath: "a.md", contentHash: "прежний", modifiedAt: .distantPast, size: 1,
            chunkIDs: ["x-0"], collectionName: "docs_col",
            chunkingSignature: source.chunking.signature, embeddingModel: "m"
        ))
        store.save(manifest)

        let plan = try await service.plan(source: source, embeddingModel: "m")
        let item = try XCTUnwrap(plan.items.first)
        XCTAssertTrue(item.kind.writesDocuments)
        XCTAssertEqual(item.fileHash, SourceSyncService.fileHash(of: file))
    }
}

/// Сервер, который отвечает тысячей байт на /big и десятью на /small.
final class BigAnswer: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let size = request.url?.path == "/big" ? 1000 : 10
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(size)"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 65, count: size))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
