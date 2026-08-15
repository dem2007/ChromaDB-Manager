import XCTest
@testable import ChromaCore

/// `get_file` на живой базе.
///
/// Здесь проверяются не формулы, а предположения о ChromaDB, на которых
/// держится упорядоченная выдача: что `offset` действительно листает выборку
/// по фильтру, что метаданные приходят без текстов, и что выборка по списку
/// идентификаторов возвращает именно то, что спрошено. Всё это можно
/// проверить только на настоящем сервере.
///
///     CHROMA_IT=1 swift test --filter MCPFileLiveTests
final class MCPFileLiveTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CHROMA_IT"] == "1",
            "Живая проверка включается CHROMA_IT=1"
        )
        try XCTSkipIf(ToolLocator().locate("chroma") == nil, "chroma не установлен")
    }

    @MainActor
    func testAWholeFileComesBackInOrderFromARealServer() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-file-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = ChromaProcessManager()
        let endpoint = try await manager.start(ServerLaunchConfiguration(
            label: "file", databasePath: directory,
            host: "127.0.0.1", port: PortUtility.freePort(), allowReset: true
        ))
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }

        let client = ChromaClient(endpoint: endpoint)
        let collection = try await client.createCollection(
            name: "file-live", configuration: CollectionConfiguration(metric: .cosine)
        )

        // Два файла в одной коллекции: чанки соседа не должны попасть в выдачу.
        let ours = "папка/наш файл.md"
        let theirs = "папка/соседний.md"
        var records: [EmbeddedRecord] = []
        for index in 0..<25 {
            records.append(EmbeddedRecord(
                id: "our-\(index)", document: "кусок номер \(index)",
                embedding: [Double(index), 1, 0],
                metadata: ["source_file": .string(ours), "chunk_index": .int(index)]
            ))
        }
        for index in 0..<5 {
            records.append(EmbeddedRecord(
                id: "their-\(index)", document: "чужой кусок \(index)",
                embedding: [0, Double(index), 1],
                metadata: ["source_file": .string(theirs), "chunk_index": .int(index)]
            ))
        }
        // Вперемешку: если порядок в базе случайно совпадёт с порядком записи,
        // проверка ничего не докажет.
        try await client.upsert(collectionID: collection.id, records: records.shuffled())

        var filter = DocumentFilter()
        filter.conditions = [MetadataCondition(field: "source_file", op: .equals, value: ours)]

        // Перечисление — маленькими страницами, чтобы листание проверилось
        // по-настоящему, а не уместилось в один запрос.
        let (scanned, overflowed) = try await MCPFileChunks.collect(batch: 10) { limit, offset in
            try await client.getDocuments(
                collectionID: collection.id, limit: limit, offset: offset,
                filter: filter, includeDocuments: false
            ).map { MCPDocumentPayload(id: $0.id, text: $0.document, metadata: $0.metadata) }
        }
        XCTAssertFalse(overflowed)
        XCTAssertEqual(scanned.count, 25, "листание по offset обязано обойти весь файл и только его")
        XCTAssertTrue(
            scanned.allSatisfy { $0.text == nil || $0.text?.isEmpty == true },
            "перечисление просило только метаданные — тексты приезжать не должны"
        )

        let ordered = MCPFileChunks.ordered(scanned)
        XCTAssertEqual(
            ordered.compactMap { MCPFileChunks.index(of: $0) }, Array(0..<25),
            "порядок восстанавливается по chunk_index"
        )

        // Окно и тексты к нему — тем же путём, каким это делает приложение.
        let window = MCPFileChunks.page(ordered, offset: 20, limit: 10)
        XCTAssertTrue(window.hasMore == false)
        let ids = window.page.map(\.id)
        let texts = try await client.getDocuments(
            collectionID: collection.id, limit: ids.count, ids: ids
        )
        let byID = Dictionary(texts.map { ($0.id, $0.document ?? "") }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(
            ids.compactMap { byID[$0] },
            (20..<25).map { "кусок номер \($0)" },
            "тексты обязаны встать в том же порядке, в каком спрошены идентификаторы"
        )

        try await client.deleteCollection(name: collection.name)
    }
}
