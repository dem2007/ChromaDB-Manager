import XCTest
@testable import ChromaCore

/// Уборка путей на живой базе.
///
/// Здесь проверяется главное предположение всей работы: что ChromaDB
/// сравнивает строки **байтами**, а не канонически, — то есть что файл,
/// записанный в разложенной форме, действительно не находится по слитному
/// пути, а после уборки находится. Сам Swift этой разницы не видит, поэтому
/// доказать её можно только на настоящем сервере.
///
///     CHROMA_IT=1 swift test --filter FilePathRepairLiveTests
final class FilePathRepairLiveTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CHROMA_IT"] == "1",
            "Живая проверка включается CHROMA_IT=1"
        )
        try XCTSkipIf(ToolLocator().locate("chroma") == nil, "chroma не установлен")
    }

    @MainActor
    func testAPathInTheOldFormIsFoundOnlyAfterTheRepair() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-repair-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = ChromaProcessManager()
        let endpoint = try await manager.start(ServerLaunchConfiguration(
            label: "repair", databasePath: directory,
            host: "127.0.0.1", port: PortUtility.freePort(), allowReset: true
        ))
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }

        let client = ChromaClient(endpoint: endpoint)
        let collection = try await client.createCollection(
            name: "repair-live", configuration: CollectionConfiguration(metric: .cosine)
        )

        // Так путь отдаёт файловая система, и так он попадал в базу.
        let typed = "Отчёты/Первый/Договор поставки.pdf"
        let stored = FilePathKey.fileSystemDecomposed(typed)
        XCTAssertNotEqual(Array(stored.utf8), Array(typed.utf8), "иначе проверять нечего")

        let records = (0..<3).map { index in
            EmbeddedRecord(
                id: "chunk-\(index)", document: "кусок \(index)",
                embedding: [Double(index), 1, 0],
                metadata: [
                    "source_file": .string(stored),
                    "file_name": .string((stored as NSString).lastPathComponent),
                    "chunk_index": .int(index),
                ]
            )
        }
        try await client.upsert(collectionID: collection.id, records: records)

        func found(_ field: String, _ value: String) async throws -> Int {
            var filter = DocumentFilter()
            filter.conditions = [MetadataCondition(field: field, op: .equals, value: value)]
            return try await client.getDocuments(
                collectionID: collection.id, limit: 100, filter: filter, includeDocuments: false
            ).count
        }

        // Вот она, беда целиком: файл в коллекции есть, а по своему пути
        // не находится.
        let beforeTyped = try await found("source_file", typed)
        XCTAssertEqual(beforeTyped, 0, "база сравнивает байты — слитный путь не должен найтись")
        let beforeStored = try await found("source_file", stored)
        XCTAssertEqual(beforeStored, 3, "а форма из файловой системы находится")

        // Уборка — теми же средствами, какими её делает приложение.
        let page = try await client.getDocuments(collectionID: collection.id, limit: 100)
        let updates = FilePathRepair.updates(for: page)
        XCTAssertEqual(updates.count, 3)
        try await client.updateDocuments(collectionID: collection.id, updates: updates)

        let afterTyped = try await found("source_file", typed)
        XCTAssertEqual(afterTyped, 3, "после уборки файл находится по набранному пути")
        let byFingerprint = try await found("file_id", SourceSyncService.fileFingerprint(typed))
        XCTAssertEqual(byFingerprint, 3, "и по отпечатку — им агент просит файл целиком")

        // Текст не тронут: уборка обещает не пересчитывать векторы, а для
        // этого текст обязан остаться прежним.
        let after = try await client.getDocuments(collectionID: collection.id, limit: 100)
        XCTAssertEqual(
            after.sorted { $0.id < $1.id }.map { $0.document ?? "" },
            ["кусок 0", "кусок 1", "кусок 2"]
        )

        // Повторный прогон ничего не делает: уборка не должна ходить по
        // коллекции кругами при каждом нажатии.
        XCTAssertTrue(FilePathRepair.updates(for: after).isEmpty)

        try await client.deleteCollection(name: collection.name)
    }
}
