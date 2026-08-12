import XCTest
@testable import ChromaCore

/// End-to-end checks against a real `chroma run` server started by the app's
/// own process manager.
///
/// Skipped unless `CHROMA_IT=1` is set, so the normal test run needs neither
/// ChromaDB nor the network:
///
///     CHROMA_IT=1 xcodebuild -scheme ChromaDBManager-Package \
///       -destination 'platform=macOS' test
final class ChromaIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CHROMA_IT"] == "1",
            "Integration tests are opt-in: set CHROMA_IT=1"
        )
        try XCTSkipIf(
            ToolLocator().locate("chroma") == nil,
            "Chroma CLI is not installed on this machine"
        )
    }

    /// Server output goes to a throwaway directory: a test run must not write
    /// into the logs the user actually reads.
    static let logsDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cdbm-it-serverlogs-\(UUID().uuidString)")

    override class func tearDown() {
        try? FileManager.default.removeItem(at: logsDirectory)
        super.tearDown()
    }

    @MainActor
    private func makeManager() -> ChromaProcessManager {
        ChromaProcessManager(serverLog: ServerLogStore(directory: Self.logsDirectory, keepRuns: 50))
    }

    @MainActor
    func testServerLifecycleAndDataOperations() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        let endpoint = try await manager.start(
            ServerLaunchConfiguration(
                label: "integration",
                databasePath: directory,
                host: "127.0.0.1",
                port: PortUtility.freePort(),
                allowReset: true
            )
        )
        // Synchronous on purpose: a `Task` in a `defer` does not finish before
        // the test process exits, so a failing test used to leave a live server.
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }
        XCTAssertTrue(manager.isRunning)

        let client = ChromaClient(endpoint: endpoint)
        let info = try await client.connect()
        XCTAssertFalse(info.version.isEmpty)

        // Fresh database.
        let empty = try await client.listCollections()
        XCTAssertTrue(empty.isEmpty)

        // Create, write, read.
        let collection = try await client.createCollection(
            name: "integration_demo",
            metadata: [CollectionBindingKeys.model: .string("test-model"), CollectionBindingKeys.dimension: .int(4)],
            getOrCreate: true
        )
        let records = [
            EmbeddedRecord(id: "a1", document: "кошка", embedding: [0.1, 0.2, 0.3, 0.4], metadata: ["src": .string("a")]),
            EmbeddedRecord(id: "a2", document: "собака", embedding: [0.9, 0.8, 0.7, 0.6], metadata: ["src": .string("b")]),
        ]
        try await client.upsert(collectionID: collection.id, records: records)
        let countAfterFirstWrite = try await client.count(collectionID: collection.id)
        XCTAssertEqual(countAfterFirstWrite, 2)

        // Deterministic ids mean a repeat run must not duplicate rows.
        try await client.upsert(collectionID: collection.id, records: records)
        let countAfterRepeat = try await client.count(collectionID: collection.id)
        XCTAssertEqual(countAfterRepeat, 2)

        let documents = try await client.getDocuments(collectionID: collection.id, limit: 10)
        XCTAssertEqual(documents.count, 2)

        let hits = try await client.query(collectionID: collection.id, embedding: [0.1, 0.2, 0.3, 0.41], nResults: 2)
        XCTAssertEqual(hits.first?.id, "a1")

        // The server rejects a vector of the wrong size; the client must
        // surface that as a typed error, not a raw payload.
        do {
            try await client.upsert(collectionID: collection.id, records: [
                EmbeddedRecord(id: "bad", document: "x", embedding: [0.1, 0.2], metadata: [:])
            ])
            XCTFail("expected a dimension error")
        } catch ChromaError.dimensionMismatch(let expected, let got) {
            XCTAssertEqual(expected, 4)
            XCTAssertEqual(got, 2)
        }

        // The binding survives a metadata update.
        try await client.updateCollection(
            id: collection.id,
            metadata: collection.metadataBinding(model: "other", dimension: 4)
        )
        let updated = try await client.collection(named: "integration_demo")
        XCTAssertEqual(updated.boundModel, "other")

        // allow_reset: true was written into the generated config.
        try await client.reset()
        let afterReset = try await client.listCollections()
        XCTAssertTrue(afterReset.isEmpty)

        await manager.stop()
        XCTAssertFalse(manager.isRunning)
    }

    /// Without `allow_reset` the server refuses, and the app must say why.
    @MainActor
    func testResetIsRefusedWhenNotAllowed() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        let endpoint = try await manager.start(
            ServerLaunchConfiguration(
                label: "integration-noreset",
                databasePath: directory,
                host: "127.0.0.1",
                port: PortUtility.freePort(),
                allowReset: false
            )
        )
        // Synchronous on purpose: a `Task` in a `defer` does not finish before
        // the test process exits, so a failing test used to leave a live server.
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }

        let client = ChromaClient(endpoint: endpoint)
        try await client.connect()
        do {
            try await client.reset()
            XCTFail("expected the server to refuse a reset")
        } catch ChromaError.resetForbidden {
            // expected
        }
        await manager.stop()
    }

    /// Stage 2A against a real server: paging, `where` filters, partial
    /// updates and the fact that changing text does not move the vector.
    @MainActor
    func testPagingFilteringAndUpdates() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-2a-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        let endpoint = try await manager.start(
            ServerLaunchConfiguration(
                label: "integration-2a",
                databasePath: directory,
                host: "127.0.0.1",
                port: PortUtility.freePort(),
                allowReset: true
            )
        )
        // Synchronous on purpose: a `Task` in a `defer` does not finish before
        // the test process exits, so a failing test used to leave a live server.
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }

        let client = ChromaClient(endpoint: endpoint)
        try await client.connect()
        let collection = try await client.createCollection(name: "paging_demo", getOrCreate: true)

        // 250 documents: enough for three pages of 100.
        let records = (0..<250).map { index in
            EmbeddedRecord(
                id: "doc-\(String(format: "%03d", index))",
                document: "документ \(index) про тему \(index % 5)",
                embedding: [Double(index) / 250, 0.5, 0.25, 0.125],
                metadata: [
                    "topic": .string("t\(index % 5)"),
                    "n": .int(index),
                    "even": .bool(index % 2 == 0),
                ]
            )
        }
        for chunk in stride(from: 0, to: records.count, by: 100) {
            try await client.upsert(
                collectionID: collection.id,
                records: Array(records[chunk..<min(chunk + 100, records.count)])
            )
        }
        let total = try await client.count(collectionID: collection.id)
        XCTAssertEqual(total, 250)

        // Paging: three pages, no overlap, nothing loaded in one lump.
        let first = try await client.getDocuments(collectionID: collection.id, limit: 100, offset: 0)
        let second = try await client.getDocuments(collectionID: collection.id, limit: 100, offset: 100)
        let third = try await client.getDocuments(collectionID: collection.id, limit: 100, offset: 200)
        XCTAssertEqual(first.count, 100)
        XCTAssertEqual(second.count, 100)
        XCTAssertEqual(third.count, 50)
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: Set(second.map(\.id))))

        // Metadata filter, built by the condition builder the UI uses.
        let filter = DocumentFilter(conditions: [
            MetadataCondition(field: "topic", op: .equals, value: "t3"),
            MetadataCondition(field: "n", op: .greaterOrEqual, value: "200"),
        ])
        let filtered = try await client.getDocuments(
            collectionID: collection.id,
            limit: 100,
            offset: 0,
            filter: filter
        )
        XCTAssertFalse(filtered.isEmpty)
        for document in filtered {
            XCTAssertEqual(document.metadata?["topic"], .string("t3"))
            if case .int(let n)? = document.metadata?["n"] { XCTAssertGreaterThanOrEqual(n, 200) }
        }

        // Full-text filter.
        let contains = try await client.getDocuments(
            collectionID: collection.id,
            limit: 100,
            offset: 0,
            filter: DocumentFilter(documentContains: "тему 4")
        )
        XCTAssertFalse(contains.isEmpty)
        XCTAssertTrue(contains.allSatisfy { $0.document?.contains("тему 4") == true })

        // Metadata-only update leaves text and vector alone.
        let target = try XCTUnwrap(first.first)
        let vectorBefore = try await client.embeddings(collectionID: collection.id, ids: [target.id])[target.id]
        try await client.updateDocuments(collectionID: collection.id, updates: [
            DocumentUpdate(id: target.id, metadata: ["topic": .string("edited"), "n": .int(-1)])
        ])
        let afterMetadata = try await client.getDocuments(
            collectionID: collection.id,
            limit: 1,
            offset: 0,
            filter: DocumentFilter(conditions: [MetadataCondition(field: "topic", op: .equals, value: "edited")])
        )
        XCTAssertEqual(afterMetadata.first?.id, target.id)
        XCTAssertEqual(afterMetadata.first?.document, target.document, "metadata edit must not touch the text")
        let vectorAfterMetadata = try await client.embeddings(collectionID: collection.id, ids: [target.id])[target.id]
        XCTAssertEqual(vectorBefore, vectorAfterMetadata)

        // Text edit with a new vector — the app always sends both, because the
        // server keeps the old embedding otherwise.
        try await client.updateDocuments(collectionID: collection.id, updates: [
            DocumentUpdate(id: target.id, document: "переписанный текст", embedding: [0.9, 0.8, 0.7, 0.6])
        ])
        let afterText = try await client.getDocuments(collectionID: collection.id, limit: 300, offset: 0)
        XCTAssertEqual(afterText.first { $0.id == target.id }?.document, "переписанный текст")
        let vectorAfterText = try await client.embeddings(collectionID: collection.id, ids: [target.id])[target.id]
        XCTAssertEqual(vectorAfterText, [0.9, 0.8, 0.7, 0.6])

        try await client.deleteDocuments(collectionID: collection.id, ids: [target.id])
        let remaining = try await client.count(collectionID: collection.id)
        XCTAssertEqual(remaining, 249)

        await manager.stop()
    }

    /// Stage 2B against a real server: the compliance report walks the whole
    /// collection page by page and finds exactly the documents that break the
    /// rules, without touching anything.
    @MainActor
    func testSchemaComplianceReport() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-2b-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        let endpoint = try await manager.start(
            ServerLaunchConfiguration(
                label: "integration-2b",
                databasePath: directory,
                host: "127.0.0.1",
                port: PortUtility.freePort(),
                allowReset: true
            )
        )
        // Synchronous on purpose: a `Task` in a `defer` does not finish before
        // the test process exits, so a failing test used to leave a live server.
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }

        let client = ChromaClient(endpoint: endpoint)
        try await client.connect()
        let collection = try await client.createCollection(name: "schema_demo", getOrCreate: true)

        // 120 documents: 100 correct, 10 missing a required field, 10 with the
        // wrong type — and more than one page, so paging is exercised too.
        var records: [EmbeddedRecord] = []
        for index in 0..<120 {
            var metadata: ChromaMetadata = ["source": .string("manual"), "pages": .int(index)]
            if index >= 100 && index < 110 { metadata.removeValue(forKey: "source") }
            if index >= 110 { metadata["pages"] = .string("много") }
            records.append(EmbeddedRecord(
                id: "doc-\(index)",
                document: "документ \(index)",
                embedding: [Double(index) / 120, 0.5],
                metadata: metadata
            ))
        }
        for chunk in stride(from: 0, to: records.count, by: 60) {
            try await client.upsert(
                collectionID: collection.id,
                records: Array(records[chunk..<min(chunk + 60, records.count)])
            )
        }

        let schema = MetadataSchema(collectionName: "schema_demo", fields: [
            MetadataField(key: "source", type: .string, isRequired: true),
            MetadataField(key: "pages", type: .integer),
        ])

        var lastProgress = 0
        let report = try await SchemaComplianceChecker().check(
            collection: collection,
            schema: schema,
            chroma: client,
            pageSize: 50
        ) { progress in
            lastProgress = progress.checked
        }

        XCTAssertEqual(report.checked, 120)
        XCTAssertEqual(report.offending, 20, "10 missing required + 10 wrong type")
        XCTAssertEqual(lastProgress, 120, "progress must reach the end")
        XCTAssertTrue(report.violations.contains { $0.kind == .missingRequired })
        XCTAssertTrue(report.violations.contains { $0.kind == .wrongType })

        // The check is a report: nothing was rewritten.
        let after = try await client.count(collectionID: collection.id)
        XCTAssertEqual(after, 120)
        let sample = try await client.getDocuments(collectionID: collection.id, limit: 1, offset: 105)
        XCTAssertNil(sample.first?.metadata?["source"], "the checker must not fill anything in")

        await manager.stop()
    }

    // MARK: - Source sync (2C)

    /// Deterministic stand-in for LM Studio: the manifest logic is what this
    /// test is about, and requiring a running model server would make the most
    /// important check in 2C impossible to run.
    private struct StubEmbeddings: EmbeddingProvider {
        let dimension = 4
        func embed(texts: [String], model: String) async throws -> [[Double]] {
            texts.map { text in
                var vector = [Double](repeating: 0, count: dimension)
                for (index, scalar) in text.unicodeScalars.enumerated() {
                    vector[index % dimension] += Double(scalar.value % 97) / 97
                }
                return vector
            }
        }
    }

    @MainActor
    func testIncrementalSourceSync() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-sync-\(UUID().uuidString)")
        let folder = directory.appendingPathComponent("docs")
        let manifests = directory.appendingPathComponent("manifests")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func write(_ text: String, _ name: String) throws {
            try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        // Long enough to produce several chunks each.
        try write(String(repeating: "первый документ про договоры. ", count: 40), "a.md")
        try write(String(repeating: "второй документ про счета. ", count: 40), "b.md")
        try write(String(repeating: "третий документ про акты. ", count: 40), "c.md")

        let manager = makeManager()
        let endpoint = try await manager.start(
            ServerLaunchConfiguration(
                label: "integration-sync",
                databasePath: directory.appendingPathComponent("db"),
                host: "127.0.0.1",
                port: PortUtility.freePort(),
                allowReset: true
            )
        )
        // Synchronous on purpose: a `Task` in a `defer` does not finish before
        // the test process exits, so a failing test used to leave a live server.
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }

        let chroma = ChromaClient(endpoint: endpoint)
        try await chroma.connect()

        let service = SourceSyncService(manifests: ManifestStore(directory: manifests))
        let binding = ModelBindingService()
        let embeddings = StubEmbeddings()
        var source = DataSource(
            name: "docs",
            path: folder.path,
            fileExtensions: ["md"],
            recursive: true,
            collectionName: "sync_demo",
            chunking: ChunkingConfiguration(strategy: .fixed, chunkSize: 200, sizeUnit: .characters, overlapPercent: 10)
        )

        // 1. First run indexes everything with the expected auto metadata.
        let first = try await service.sync(
            source: source, embeddingModel: "stub", chroma: chroma,
            embeddings: embeddings, binding: binding
        ) { _ in }
        XCTAssertEqual(first.added, 3)
        XCTAssertEqual(first.updated, 0)
        XCTAssertGreaterThan(first.chunksWritten, 3)

        let collectionID = try await chroma.resolveID(of: "sync_demo")
        let totalAfterFirst = try await chroma.count(collectionID: collectionID)
        XCTAssertEqual(totalAfterFirst, first.chunksWritten)

        let sample = try await chroma.getDocuments(collectionID: collectionID, limit: 1)
        let metadata = sample.first?.metadata ?? [:]
        for key in SourceSyncService.autoMetadataKeys {
            XCTAssertNotNil(metadata[key], "автополе \(key) должно быть у каждого чанка")
        }

        // 2. Nothing changed on disk: no duplicates, no new vectors.
        let second = try await service.sync(
            source: source, embeddingModel: "stub", chroma: chroma,
            embeddings: embeddings, binding: binding
        ) { _ in }
        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(second.updated, 0)
        XCTAssertEqual(second.unchanged, 3)
        XCTAssertEqual(second.chunksWritten, 0, "повторный запуск не должен пересчитывать векторы")
        let totalAfterSecond = try await chroma.count(collectionID: collectionID)
        XCTAssertEqual(totalAfterSecond, totalAfterFirst)

        // 3. An edited file is re-indexed: old chunks go, new ones arrive, and
        // the total stays right even though the file got shorter.
        try write("короткий текст вместо длинного", "a.md")
        let third = try await service.sync(
            source: source, embeddingModel: "stub", chroma: chroma,
            embeddings: embeddings, binding: binding
        ) { _ in }
        XCTAssertEqual(third.updated, 1)
        XCTAssertEqual(third.added, 0)
        XCTAssertGreaterThan(third.chunksDeleted, 0)

        let aChunks = try await chroma.getDocuments(
            collectionID: collectionID,
            limit: 100,
            filter: DocumentFilter(conditions: [
                MetadataCondition(field: "source_file", op: .equals, value: "a.md")
            ])
        )
        XCTAssertEqual(aChunks.count, 1, "у короткого файла должен остаться один чанк, без хвоста от прошлой версии")
        XCTAssertEqual(aChunks.first?.document, "короткий текст вместо длинного")

        // Since A6 the new chunks are written first and only the tail is
        // deleted, so the written ones land on the ids they already occupied:
        // the total drops by exactly the tail and by nothing else.
        let expectedTotal = try await chroma.count(collectionID: collectionID)
        XCTAssertEqual(expectedTotal, totalAfterFirst - third.chunksDeleted)

        // 4. A file deleted from disk waits for a decision and stays in the base.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("b.md"))
        let fourth = try await service.sync(
            source: source, embeddingModel: "stub", chroma: chroma,
            embeddings: embeddings, binding: binding
        ) { _ in }
        XCTAssertEqual(fourth.needsDecision.map(\.relativePath), ["b.md"])
        let bStillThere = try await chroma.getDocuments(
            collectionID: collectionID,
            limit: 100,
            filter: DocumentFilter(conditions: [
                MetadataCondition(field: "source_file", op: .equals, value: "b.md")
            ])
        )
        XCTAssertFalse(bStillThere.isEmpty, "исчезнувший файл не должен удаляться автоматически")

        // …until the user says so.
        guard let removal = fourth.needsDecision.first else { return XCTFail("нет записи «требует решения»") }
        let deleted = try await service.resolve(
            removal: removal, decision: .deleteChunks, source: source, chroma: chroma
        )
        XCTAssertEqual(deleted, bStillThere.count)
        let bGone = try await chroma.getDocuments(
            collectionID: collectionID,
            limit: 100,
            filter: DocumentFilter(conditions: [
                MetadataCondition(field: "source_file", op: .equals, value: "b.md")
            ])
        )
        XCTAssertTrue(bGone.isEmpty)

        // 5. Changing the chunking parameters re-chunks everything on disk.
        source.chunking.chunkSize = 90
        let fifth = try await service.sync(
            source: source, embeddingModel: "stub", chroma: chroma,
            embeddings: embeddings, binding: binding
        ) { _ in }
        XCTAssertEqual(fifth.updated, 2, "оба оставшихся файла должны быть перечанкованы")
        XCTAssertEqual(fifth.added, 0)

        await manager.stop()
    }

    @MainActor
    func testSubfolderMappingCreatesOneCollectionPerSubfolder() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-map-\(UUID().uuidString)")
        let folder = directory.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("legal"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("finance"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try "договор аренды".write(to: folder.appendingPathComponent("legal/a.md"), atomically: true, encoding: .utf8)
        try "счёт на оплату".write(to: folder.appendingPathComponent("finance/b.md"), atomically: true, encoding: .utf8)
        try "заметка в корне".write(to: folder.appendingPathComponent("root.md"), atomically: true, encoding: .utf8)

        let manager = makeManager()
        let endpoint = try await manager.start(
            ServerLaunchConfiguration(
                label: "integration-map",
                databasePath: directory.appendingPathComponent("db"),
                host: "127.0.0.1",
                port: PortUtility.freePort(),
                allowReset: true
            )
        )
        // Synchronous on purpose: a `Task` in a `defer` does not finish before
        // the test process exits, so a failing test used to leave a live server.
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }

        let chroma = ChromaClient(endpoint: endpoint)
        try await chroma.connect()

        let service = SourceSyncService(manifests: ManifestStore(directory: directory.appendingPathComponent("manifests")))
        let source = DataSource(
            name: "docs",
            path: folder.path,
            fileExtensions: ["md"],
            recursive: true,
            mapping: .subfoldersToCollections,
            collectionName: "docs_root"
        )

        let summary = try await service.sync(
            source: source, embeddingModel: "stub", chroma: chroma,
            embeddings: StubEmbeddings(), binding: ModelBindingService()
        ) { _ in }
        XCTAssertEqual(summary.added, 3)
        XCTAssertEqual(Set(summary.collections), ["legal", "finance", "docs_root"])

        let names = try await chroma.listCollections(withCounts: true)
        XCTAssertEqual(names.count, 3)
        for collection in names {
            XCTAssertEqual(collection.documentCount, 1, "\(collection.name) должна содержать один чанк")
            XCTAssertEqual(collection.metadata?[CollectionBindingKeys.model], .string("stub"))
        }

        // The path survives as metadata even when the folder decided the collection.
        let legalID = try await chroma.resolveID(of: "legal")
        let documents = try await chroma.getDocuments(collectionID: legalID, limit: 10)
        XCTAssertEqual(documents.first?.metadata?["relative_path"], .string("legal/a.md"))

        await manager.stop()
    }

    @MainActor
    func testSchemaPolicyBlocksASourceThatCannotFillARequiredField() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-schema-\(UUID().uuidString)")
        let folder = directory.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "текст документа".write(to: folder.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)

        let manager = makeManager()
        let endpoint = try await manager.start(
            ServerLaunchConfiguration(
                label: "integration-schema",
                databasePath: directory.appendingPathComponent("db"),
                host: "127.0.0.1",
                port: PortUtility.freePort(),
                allowReset: true
            )
        )
        // Synchronous on purpose: a `Task` in a `defer` does not finish before
        // the test process exits, so a failing test used to leave a live server.
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }

        let chroma = ChromaClient(endpoint: endpoint)
        try await chroma.connect()

        let service = SourceSyncService(manifests: ManifestStore(directory: directory.appendingPathComponent("manifests")))
        var source = DataSource(
            name: "docs", path: folder.path, fileExtensions: ["md"],
            collectionName: "schema_gate", unresolvedSchemaPolicy: .block
        )
        let schema = MetadataSchema(collectionName: "schema_gate", fields: [
            MetadataField(key: "department", type: .string, isRequired: true),
        ])

        do {
            _ = try await service.sync(
                source: source, embeddingModel: "stub", chroma: chroma,
                embeddings: StubEmbeddings(), binding: ModelBindingService(),
                schemas: ["schema_gate": schema]
            ) { _ in }
            XCTFail("политика «не запускать» должна остановить синхронизацию")
        } catch let error as SyncError {
            guard case .schemaNotCovered(_, let fields) = error else {
                return XCTFail("ожидалась schemaNotCovered, получено \(error)")
            }
            XCTAssertEqual(fields, ["department"])
        }
        // Nothing was written before the refusal.
        let collections = try await chroma.listCollections()
        XCTAssertTrue(collections.isEmpty, "при отказе коллекция не должна создаваться")

        // With the other policy the documents arrive, marked.
        source.unresolvedSchemaPolicy = .markAttention
        let summary = try await service.sync(
            source: source, embeddingModel: "stub", chroma: chroma,
            embeddings: StubEmbeddings(), binding: ModelBindingService(),
            schemas: ["schema_gate": schema]
        ) { _ in }
        XCTAssertEqual(summary.added, 1)
        XCTAssertEqual(summary.markedForAttention, ["a.md"])

        let id = try await chroma.resolveID(of: "schema_gate")
        let documents = try await chroma.getDocuments(collectionID: id, limit: 5)
        XCTAssertNotNil(documents.first?.metadata?["_cdbm_attention"])

        await manager.stop()
    }

    /// The whole chain with the real thing: files → chunks → LM Studio → ChromaDB.
    /// Skipped when LM Studio is not running, so it never blocks a test run.
    @MainActor
    func testSourceSyncThroughRealLMStudio() async throws {
        let lmStudio = try LMStudioClient(baseURLString: "http://localhost:1234")
        guard let models = try? await lmStudio.models(),
              let model = models.first(where: { $0.kind == .embedding })
                  ?? models.first(where: { $0.id.contains("embed") }) else {
            throw XCTSkip("LM Studio не запущена или в ней нет эмбеддинг-модели")
        }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-lm-\(UUID().uuidString)")
        let folder = directory.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try String(repeating: "Порядок расчётов по договору оказания услуг. ", count: 30)
            .write(to: folder.appendingPathComponent("contract.md"), atomically: true, encoding: .utf8)

        let manager = makeManager()
        let endpoint = try await manager.start(
            ServerLaunchConfiguration(
                label: "integration-lm",
                databasePath: directory.appendingPathComponent("db"),
                host: "127.0.0.1",
                port: PortUtility.freePort(),
                allowReset: true
            )
        )
        // Synchronous on purpose: a `Task` in a `defer` does not finish before
        // the test process exits, so a failing test used to leave a live server.
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }

        let chroma = ChromaClient(endpoint: endpoint)
        try await chroma.connect()

        let service = SourceSyncService(manifests: ManifestStore(directory: directory.appendingPathComponent("manifests")))
        let source = DataSource(
            name: "docs", path: folder.path, fileExtensions: ["md"],
            collectionName: "lm_sync_demo",
            chunking: ChunkingConfiguration(strategy: .recursive, chunkSize: 300, sizeUnit: .characters)
        )

        let summary = try await service.sync(
            source: source, embeddingModel: model.id, chroma: chroma,
            embeddings: lmStudio, binding: ModelBindingService()
        ) { _ in }
        XCTAssertEqual(summary.added, 1)
        XCTAssertGreaterThan(summary.chunksWritten, 1)
        XCTAssertNotNil(summary.dimension)

        // The vectors are real, so a query must actually find the document.
        let id = try await chroma.resolveID(of: "lm_sync_demo")
        let vector = try await lmStudio.embed(text: "как считаются расчёты по договору", model: model.id)
        let hits = try await chroma.query(collectionID: id, embedding: vector, nResults: 3)
        XCTAssertFalse(hits.isEmpty)
        XCTAssertEqual(hits.first?.metadata?["source_file"], .string("contract.md"))

        // Second run must not call the model at all: same files, same recipe.
        let second = try await service.sync(
            source: source, embeddingModel: model.id, chroma: chroma,
            embeddings: FailingEmbeddings(), binding: ModelBindingService()
        ) { _ in }
        XCTAssertEqual(second.chunksWritten, 0)
        XCTAssertEqual(second.unchanged, 1)

        await manager.stop()
    }

    /// Throws if anyone asks it for a vector — used to prove that a no-op sync
    /// does not touch the embedding model.
    private struct FailingEmbeddings: EmbeddingProvider {
        func embed(texts: [String], model: String) async throws -> [[Double]] {
            XCTFail("синхронизация без изменений не должна обращаться к модели")
            throw LMStudioError.emptyResponse
        }
    }

    // MARK: - Advanced strategies (2D)

    /// Starts a private server and returns a client for it.
    @MainActor
    private func makeServer(
        label: String,
        directory: URL,
        manager: ChromaProcessManager
    ) async throws -> ChromaClient {
        let endpoint = try await manager.start(
            ServerLaunchConfiguration(
                label: label,
                databasePath: directory.appendingPathComponent("db"),
                host: "127.0.0.1",
                port: PortUtility.freePort(),
                allowReset: true
            )
        )
        let chroma = ChromaClient(endpoint: endpoint)
        try await chroma.connect()
        return chroma
    }

    @MainActor
    func testHierarchicalSyncWritesParentsAndChildren() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-hier-\(UUID().uuidString)")
        let folder = directory.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let text = (0..<8)
            .map { "Абзац \($0). " + String(repeating: "содержательное предложение о договоре. ", count: 10) }
            .joined(separator: "\n\n")
        try text.write(to: folder.appendingPathComponent("long.md"), atomically: true, encoding: .utf8)

        let manager = makeManager()
        let chroma = try await makeServer(label: "integration-hier", directory: directory, manager: manager)
        // Synchronous on purpose: a `Task` in a `defer` does not finish before
        // the test process exits, so a failing test used to leave a live server.
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }

        let service = SourceSyncService(manifests: ManifestStore(directory: directory.appendingPathComponent("manifests")))
        let source = DataSource(
            name: "docs", path: folder.path, fileExtensions: ["md"],
            collectionName: "hier_demo",
            chunking: ChunkingConfiguration(
                strategy: .hierarchical,
                sizeUnit: .characters,
                levels: 2,
                parentChunkSize: 900,
                childChunkSize: 250
            )
        )

        let summary = try await service.sync(
            source: source, embeddingModel: "stub", chroma: chroma,
            embeddings: StubEmbeddings(), binding: ModelBindingService()
        ) { _ in }
        XCTAssertEqual(summary.added, 1)

        let id = try await chroma.resolveID(of: "hier_demo")
        let parents = try await chroma.getDocuments(
            collectionID: id, limit: 200,
            filter: DocumentFilter(conditions: [MetadataCondition(field: "chunk_level", op: .equals, value: "1")])
        )
        let children = try await chroma.getDocuments(
            collectionID: id, limit: 200,
            filter: DocumentFilter(conditions: [MetadataCondition(field: "chunk_level", op: .equals, value: "0")])
        )
        XCTAssertFalse(parents.isEmpty)
        XCTAssertGreaterThan(children.count, parents.count)
        XCTAssertEqual(parents.count + children.count, summary.chunksWritten)

        // Every child points at a parent that really exists in the collection.
        let parentIDs = Set(parents.map(\.id))
        for child in children {
            guard case .string(let parentID)? = child.metadata?["parent_chunk_id"] else {
                return XCTFail("у дочернего чанка должен быть parent_chunk_id")
            }
            XCTAssertTrue(parentIDs.contains(parentID), "parent_chunk_id должен указывать на существующий документ")
        }

        await manager.stop()
    }

    @MainActor
    func testDocumentBasedSyncSplitsMarkdownBySections() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-doc-\(UUID().uuidString)")
        let folder = directory.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let markdown = """
        # Руководство

        ## Установка
        Скачайте и распакуйте архив.

        ## Настройка
        Откройте файл настроек и укажите путь.

        ## Обновление
        Запустите обновление из меню.
        """
        try markdown.write(to: folder.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)

        let manager = makeManager()
        let chroma = try await makeServer(label: "integration-doc", directory: directory, manager: manager)
        // Synchronous on purpose: a `Task` in a `defer` does not finish before
        // the test process exits, so a failing test used to leave a live server.
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }

        let service = SourceSyncService(manifests: ManifestStore(directory: directory.appendingPathComponent("manifests")))
        let source = DataSource(
            name: "docs", path: folder.path, fileExtensions: ["md"],
            collectionName: "doc_demo",
            chunking: ChunkingConfiguration(
                strategy: .documentBased,
                sizeUnit: .characters,
                sourceFormat: .auto,
                splitHeaderLevel: 2,
                maxSectionSize: 4096
            )
        )

        let summary = try await service.sync(
            source: source, embeddingModel: "stub", chroma: chroma,
            embeddings: StubEmbeddings(), binding: ModelBindingService()
        ) { _ in }
        XCTAssertEqual(summary.chunksWritten, 4, "заголовок документа плюс три раздела")

        let id = try await chroma.resolveID(of: "doc_demo")
        let documents = try await chroma.getDocuments(collectionID: id, limit: 20)
        XCTAssertTrue(documents.contains { $0.document?.contains("## Настройка") ?? false })
        XCTAssertTrue(documents.allSatisfy { $0.metadata?["chunk_level"] == .int(0) })

        await manager.stop()
    }

    /// Semantic chunking against the real model, then a real query over the result.
    @MainActor
    func testSemanticChunkingThroughRealLMStudio() async throws {
        let lmStudio = try LMStudioClient(baseURLString: "http://localhost:1234")
        guard let models = try? await lmStudio.models(),
              let model = models.first(where: { $0.kind == .embedding })
                  ?? models.first(where: { $0.id.contains("embed") }) else {
            throw XCTSkip("LM Studio не запущена или в ней нет эмбеддинг-модели")
        }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-sem-\(UUID().uuidString)")
        let folder = directory.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Two clearly different topics: the split should land between them.
        let text = """
        Кошка спит на подоконнике. Кошка ест сухой корм утром. Кошка любит играть с мячиком. \
        Счёт за электричество оплачен вчера. Счёт закрыт банком без ошибок. Счёт отправлен в архив бухгалтерии.
        """
        try text.write(to: folder.appendingPathComponent("mixed.md"), atomically: true, encoding: .utf8)

        let manager = makeManager()
        let chroma = try await makeServer(label: "integration-sem", directory: directory, manager: manager)
        // Synchronous on purpose: a `Task` in a `defer` does not finish before
        // the test process exits, so a failing test used to leave a live server.
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }

        let service = SourceSyncService(manifests: ManifestStore(directory: directory.appendingPathComponent("manifests")))
        let source = DataSource(
            name: "docs", path: folder.path, fileExtensions: ["md"],
            collectionName: "semantic_demo",
            chunking: ChunkingConfiguration(
                strategy: .semantic,
                sizeUnit: .characters,
                thresholdMode: .percentile,
                thresholdValue: 90,
                sentenceBuffer: 1,
                minChunkSize: 40,
                maxChunkSize: 2048
            )
        )

        let summary = try await service.sync(
            source: source, embeddingModel: model.id, chroma: chroma,
            embeddings: lmStudio, binding: ModelBindingService()
        ) { _ in }
        XCTAssertEqual(summary.added, 1)
        XCTAssertGreaterThan(summary.chunksWritten, 1, "две темы должны дать больше одного чанка")

        let id = try await chroma.resolveID(of: "semantic_demo")
        let vector = try await lmStudio.embed(text: "оплата счёта в банке", model: model.id)
        let hits = try await chroma.query(collectionID: id, embedding: vector, nResults: 1)
        XCTAssertTrue(hits.first?.document?.contains("Счёт") ?? false, "ближайший чанк должен быть про счета, а не про кошку")

        await manager.stop()
    }

    /// LLM-based chunking against a real chat model in LM Studio.
    @MainActor
    func testLLMChunkingThroughRealChatModel() async throws {
        let lmStudio = try LMStudioClient(baseURLString: "http://localhost:1234")
        guard let models = try? await lmStudio.models() else {
            throw XCTSkip("LM Studio не запущена")
        }
        guard let chatModel = ProcessInfo.processInfo.environment["CDBM_CHAT_MODEL"]
                ?? models.first(where: { $0.kind == .chat && $0.id.contains("4b") })?.id else {
            throw XCTSkip("нет подходящей чат-модели: укажите CDBM_CHAT_MODEL")
        }

        let configuration = ChunkingConfiguration(
            strategy: .llmBased,
            sizeUnit: .characters,
            maxChunkSize: 2048,
            chatModel: chatModel,
            granularity: .topical,
            llmMaxRetries: 1,
            onMalformedOutput: .fallbackToRecursive,
            llmTimeout: 240
        )
        let chunks = try await LLMChunker(configuration: configuration, chat: lmStudio)
            .chunks(from: "Кошка спит на окне. Кошка ест корм. Счёт оплачен вчера. Счёт закрыт банком.")

        XCTAssertFalse(chunks.isEmpty)
        // Either the model gave usable boundaries, or the documented fallback ran —
        // both are correct behaviour, and the mark tells them apart.
        if chunks.allSatisfy({ $0.note == nil }) {
            XCTAssertGreaterThan(chunks.count, 1, "модель должна была найти границу между темами")
        } else {
            XCTAssertTrue(chunks.allSatisfy { $0.note != nil }, "откат обязан быть помечен")
        }
    }

    ///, — предел ответа и предел по времени на живой LM Studio.
    ///
    /// Оба дефекта нашлись на настоящем прогоне, и проверять их двойниками
    /// мало: важно, что `max_tokens` доходит до LM Studio и что она отвечает
    /// на него именно `finish_reason: "length"`, а скорость письма вообще
    /// существует только на живой машине.
    @MainActor
    func testTokenLimitAndSpeedAgainstRealLMStudio() async throws {
        let lmStudio = try LMStudioClient(baseURLString: "http://localhost:1234")
        guard let models = try? await lmStudio.models() else {
            throw XCTSkip("LM Studio не запущена")
        }
        guard let chatModel = ProcessInfo.processInfo.environment["CDBM_CHAT_MODEL"]
                ?? models.first(where: { $0.kind == .chat && $0.loadedContextLength != nil })?.id else {
            throw XCTSkip("нет загруженной чат-модели: укажите CDBM_CHAT_MODEL")
        }

        // 1. Предел длины доходит до LM Studio и распознаётся как обрыв.
        do {
            _ = try await lmStudio.complete(
                prompt: "Перечисли числа от 1 до 2000 через запятую.",
                model: chatModel,
                settings: ChatGenerationSettings(temperature: 0, seed: nil, maxTokens: 32),
                schema: nil,
                timeout: 120
            )
            XCTFail("ответ в 32 токена обязан упереться в предел")
        } catch let error as LMStudioError {
            XCTAssertTrue(error.isTruncatedByTokenLimit, "получено \(error)")
        }

        // 2. Скорость измеряется и выглядит как скорость.
        let speed = await lmStudio.generationSpeed(of: chatModel)
        let measured = try XCTUnwrap(speed, "скорость обязана измеряться на живой модели")
        XCTAssertGreaterThan(measured, 1, "меньше токена в секунду — это не работа")
        XCTAssertLessThan(measured, 10_000, "быстрее десяти тысяч токенов в секунду не бывает")

        // 3. Предполётная проверка при заведомо коротком таймауте отказывает
        //    по времени, а не по контексту, и советует про время.
        var hurried = ChunkingConfiguration(
            strategy: .llmBased, sizeUnit: .characters, maxChunkSize: 4096, chatModel: chatModel
        )
        hurried.llmTimeout = 1
        let check = await LLMChunker.contextCheck(
            configuration: hurried, model: chatModel, chat: lmStudio
        )
        XCTAssertTrue(check.timeIsTheLimit, check.summary)
        XCTAssertFalse(check.fits, "за секунду не переписать даже минимальное окно: \(check.summary)")
        XCTAssertFalse(
            SyncError.chunkingWindowTooSmall(check).recoverySuggestion?.contains("перезагрузите") ?? true,
            "совет обязан быть про время, а не про контекст"
        )

        // 4. С обычным таймаутом нарезка работает и укладывается в него.
        var normal = hurried
        normal.llmTimeout = 120
        let started = Date()
        let chunks = try await LLMChunker(configuration: normal, chat: lmStudio)
            .chunks(from: String(repeating: "Счёт оплачен вчера. Кошка спит на окне. ", count: 20))
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 240,
            "окно считается от того, что модель успевает написать, — прогон не должен упираться в таймаут"
        )
    }

    // MARK: - Re-embedding (2E)

    /// Collects progress callbacks from whatever thread they arrive on.
    private final class ProgressWitness: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func observe(_ processed: Int) {
            lock.lock(); value = max(value, processed); lock.unlock()
        }
        var highest: Int {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    /// Same vector size as `StubEmbeddings` but different values — an in-place
    /// run can only ever be this: ChromaDB fixes a collection's dimension.
    private struct AltStubEmbeddings: EmbeddingProvider {
        let dimension = 4
        func embed(texts: [String], model: String) async throws -> [[Double]] {
            texts.map { text in
                var vector = [Double](repeating: 0, count: dimension)
                for (index, scalar) in text.unicodeScalars.enumerated() {
                    vector[(index + 1) % dimension] += Double(scalar.value % 53) / 53
                }
                return vector
            }
        }
    }

    /// A second stand-in model with a different vector size, so switching models
    /// visibly changes the dimension.
    private struct WideStubEmbeddings: EmbeddingProvider {
        let dimension = 8
        func embed(texts: [String], model: String) async throws -> [[Double]] {
            texts.map { text in
                var vector = [Double](repeating: 0, count: dimension)
                for (index, scalar) in text.unicodeScalars.enumerated() {
                    vector[index % dimension] += Double(scalar.value % 89) / 89
                }
                return vector
            }
        }
    }

    /// Fills a collection with a few documents through the normal write path.
    @MainActor
    private func seed(
        _ chroma: ChromaClient,
        name: String,
        documents: [String],
        model: String = "stub",
        dimension: Int = 4
    ) async throws -> ChromaCollection {
        let collection = try await chroma.createCollection(
            name: name,
            metadata: [
                CollectionBindingKeys.model: .string(model),
                CollectionBindingKeys.dimension: .int(dimension),
            ],
            getOrCreate: true
        )
        let embeddings = StubEmbeddings()
        let vectors = try await embeddings.embed(texts: documents, model: model)
        let records = zip(documents.enumerated(), vectors).map { pair, vector in
            EmbeddedRecord(
                id: "doc-\(pair.offset)",
                document: pair.element,
                embedding: vector,
                metadata: ["topic": .string("t\(pair.offset % 2)")]
            )
        }
        try await chroma.upsert(collectionID: collection.id, records: records)
        // Re-read with counts so the collection carries its real document count.
        guard let stored = try await chroma.listCollections(withCounts: true).first(where: { $0.name == name }) else {
            throw ChromaError.collectionNotFound(name)
        }
        return stored
    }

    /// Backup evidence for tests: the export path, which needs no server restart.
    /// Writes into a temporary folder — a test must never touch the user's own
    /// backups directory.
    @MainActor
    private func evidence(
        for collection: ChromaCollection,
        chroma: ChromaClient,
        directory: URL? = nil
    ) async throws -> BackupEvidence {
        let target = directory ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-test-backups-\(UUID().uuidString)")
        let service = BackupService(directory: target)
        return try await service.exportCollection(collection, from: chroma, note: "интеграционный тест")
    }

    @MainActor
    func testReembeddingIntoACloneLeavesTheOriginalAlone() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-clone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        let chroma = try await makeServer(label: "integration-clone", directory: directory, manager: manager)
        // Synchronous on purpose: a `Task` in a `defer` does not finish before
        // the test process exits, so a failing test used to leave a live server.
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }

        let documents = (0..<6).map { "Документ номер \($0) про договоры и расчёты." }
        let source = try await seed(chroma, name: "reembed_src", documents: documents)
        XCTAssertEqual(source.documentCount, 6)

        let journal = ReembeddingJournal(fileURL: directory.appendingPathComponent("journal.json"))
        let service = ReembeddingService(journal: journal)
        let request = ReembeddingRequest(
            collection: source,
            targetModel: "wide-stub",
            scenario: .clone,
            newCollectionName: "reembed_clone"
        )

        let progressSeen = ProgressWitness()
        let report = try await service.run(
            request,
            backup: try await evidence(for: source, chroma: chroma),
            chroma: chroma,
            embeddings: WideStubEmbeddings(),
            binding: ModelBindingService()
        ) { progress in
            progressSeen.observe(progress.processed)
        }

        XCTAssertEqual(report.processedDocuments, 6)
        XCTAssertEqual(report.writtenDocuments, 6)
        XCTAssertEqual(report.dimension, 8, "новая модель даёт вектор другой длины")
        XCTAssertTrue(report.verification.isClean, report.verification.line)
        XCTAssertGreaterThan(progressSeen.highest, 0, "прогресс должен доходить до вызывающего")

        // The original is untouched: same count, same model, same dimension.
        let original = try await chroma.collection(named: "reembed_src")
        let originalCount = try await chroma.count(collectionID: original.id)
        XCTAssertEqual(originalCount, 6)
        XCTAssertEqual(original.boundModel, "stub")
        XCTAssertEqual(original.effectiveDimension, 4)

        // The clone carries the new binding, the documents and the metadata.
        let clone = try await chroma.collection(named: "reembed_clone")
        XCTAssertEqual(clone.boundModel, "wide-stub")
        XCTAssertEqual(clone.effectiveDimension, 8)
        let cloneCount = try await chroma.count(collectionID: clone.id)
        XCTAssertEqual(cloneCount, 6)
        XCTAssertEqual(clone.metadata?["_cdbm_cloned_from"], .string("reembed_src"))

        let cloned = try await chroma.getDocuments(collectionID: clone.id, limit: 10)
        XCTAssertEqual(Set(cloned.map(\.id)), Set((0..<6).map { "doc-\($0)" }), "id документов сохраняются")
        XCTAssertTrue(cloned.allSatisfy { $0.metadata?["topic"] != nil }, "метаданные должны переехать в клон")
        let stored = try await chroma.storedDimension(collectionID: clone.id)
        XCTAssertEqual(stored, 8, "в клоне лежат векторы новой модели")

        // The operation is in the journal.
        let entries = await service.journalEntries()
        XCTAssertEqual(entries.first?.outcome, .finished)
        XCTAssertEqual(entries.first?.resultCollection, "reembed_clone")

        await manager.stop()
    }

    /// F1 against the real model: the second run of the same texts must not go
    /// to LM Studio at all, and must return exactly the same vectors.
    func testTheEmbeddingCacheAnswersTheSecondRunWithoutTheModel() async throws {
        let lmStudio = try LMStudioClient(baseURLString: "http://localhost:1234")
        guard let models = try? await lmStudio.models(),
              let model = models.first(where: { $0.kind == .embedding })
                  ?? models.first(where: { $0.id.contains("embed") }) else {
            throw XCTSkip("LM Studio не запущена или в ней нет эмбеддинг-модели")
        }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = EmbeddingCache(fileURL: directory.appendingPathComponent("cache.sqlite3"))
        await cache.open()
        let cached = try LMStudioClient(baseURLString: "http://localhost:1234", cache: cache)

        let texts = [
            "Порядок оплаты услуг по договору аренды помещения.",
            "Сроки поставки оборудования и ответственность сторон.",
        ]
        let first = try await cached.embed(texts: texts, model: model.id)
        XCTAssertEqual(first.count, 2)

        // Same client, same texts: this time nothing may reach the model.
        let second = try await cached.embed(texts: texts, model: model.id)
        XCTAssertEqual(second, first, "кэш обязан вернуть те же векторы, а не похожие")

        let statistics = await cache.statistics()
        XCTAssertEqual(statistics.hits, 2)
        XCTAssertEqual(statistics.entries, 2)

        // Proof that the second run needed no network: a client pointed at a
        // dead port answers from the cache alone.
        let offline = try LMStudioClient(baseURLString: "http://127.0.0.1:1", cache: cache)
        let third = try await offline.embed(texts: texts, model: model.id)
        XCTAssertEqual(third, first)

        // A partially known batch asks only for what is missing, and the order
        // of the answer still follows the order of the request.
        let mixed = ["Совсем новый текст про сроки согласования."] + texts
        let vectors = try await cached.embed(texts: mixed, model: model.id)
        XCTAssertEqual(vectors.count, 3)
        XCTAssertEqual(Array(vectors.dropFirst()), first, "порядок ответа обязан совпадать с порядком запроса")
    }

    /// the empty `include` the app relies on, and the server default it
    /// refuses to rely on, pinned against a live server.
    @MainActor
    func testAnEmptyIncludeReturnsIDsAndTheServerDefaultDoesNot() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-include-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        let chroma = try await makeServer(label: "integration-include", directory: directory, manager: manager)
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }

        let collection = try await seed(
            chroma, name: "include_demo",
            documents: ["Первый документ про оплату.", "Второй документ про доставку."]
        )

        // What the app sends: `include: []`. Accepted, and only ids come back.
        let existing = try await chroma.existingIDs(collectionID: collection.id, ids: ["doc-0", "doc-404"])
        XCTAssertEqual(existing, ["doc-0"])

        let endpoint = await chroma.endpoint
        let url = URL(string: "\(endpoint.baseURLString)\(endpoint.collectionsPath)/\(collection.id)/get")!
        func post(_ body: [String: Any]) async throws -> [String: Any] {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, String(decoding: data, as: UTF8.self))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        let empty = try await post(["limit": 2, "include": []])
        XCTAssertEqual((empty["ids"] as? [String])?.count, 2)
        for field in ["documents", "metadatas", "embeddings", "uris"] {
            XCTAssertTrue(empty[field] is NSNull, "при include: [] поле \(field) должно быть null")
        }

        // Why the default is never relied on: it carries the documents.
        let byDefault = try await post(["limit": 2])
        XCTAssertFalse(byDefault["documents"] is NSNull, "серверный дефолт всё-таки везёт тексты")
        XCTAssertTrue(byDefault["embeddings"] is NSNull, "векторов в дефолте нет — но полагаться на это нельзя")

        await manager.stop()
    }

    @MainActor
    func testInPlaceReembeddingOverwritesVectorsAndRebinds() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-inplace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        let chroma = try await makeServer(label: "integration-inplace", directory: directory, manager: manager)
        // Synchronous on purpose: a `Task` in a `defer` does not finish before
        // the test process exits, so a failing test used to leave a live server.
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }

        let documents = (0..<5).map { "Запись \($0) о порядке оплаты." }
        let collection = try await seed(chroma, name: "inplace_demo", documents: documents)

        let journal = ReembeddingJournal(fileURL: directory.appendingPathComponent("journal.json"))
        let service = ReembeddingService(journal: journal)
        let before = try await chroma.getDocuments(collectionID: collection.id, limit: 1, includeEmbeddings: true)
        let oldVector = try await chroma.embeddings(collectionID: collection.id, ids: ["doc-0"])["doc-0"]
        XCTAssertNotNil(oldVector)
        _ = before

        let report = try await service.run(
            ReembeddingRequest(collection: collection, targetModel: "alt-stub", scenario: .inPlace),
            backup: try await evidence(for: collection, chroma: chroma),
            chroma: chroma,
            embeddings: AltStubEmbeddings(),
            binding: ModelBindingService()
        ) { _ in }

        XCTAssertEqual(report.processedDocuments, 5)
        XCTAssertEqual(report.writtenDocuments, 5)
        XCTAssertTrue(report.verification.isClean, report.verification.line)

        // Same collection, same ids, same count — new vectors and a new binding.
        let after = try await chroma.collection(named: "inplace_demo")
        XCTAssertEqual(after.boundModel, "alt-stub", "привязка коллекции должна указывать на новую модель")
        let afterCount = try await chroma.count(collectionID: after.id)
        XCTAssertEqual(afterCount, 5)

        // The vectors really were overwritten, not merely re-declared.
        let newVector = try await chroma.embeddings(collectionID: after.id, ids: ["doc-0"])["doc-0"]
        XCTAssertNotNil(newVector)
        XCTAssertNotEqual(oldVector, newVector, "векторы должны быть пересчитаны, а не оставлены прежними")

        let rows = try await chroma.getDocuments(collectionID: after.id, limit: 10)
        XCTAssertEqual(Set(rows.map(\.id)), Set((0..<5).map { "doc-\($0)" }), "пересчёт на месте не переименовывает документы")
        XCTAssertTrue(rows.allSatisfy { $0.metadata?["topic"] != nil }, "метаданные не должны потеряться")

        // Nothing left to resume after a finished run.
        let checkpoint = await service.checkpoint(for: collection.id)
        XCTAssertNil(checkpoint)

        await manager.stop()
    }

    /// Cancellation must leave the database consistent: an unfinished
    /// clone is removed, an unfinished in-place run keeps its place.
    @MainActor
    func testCancelledCloneIsRemovedAndInPlaceKeepsACheckpoint() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        let chroma = try await makeServer(label: "integration-cancel", directory: directory, manager: manager)
        // Synchronous on purpose: a `Task` in a `defer` does not finish before
        // the test process exits, so a failing test used to leave a live server.
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }

        let documents = (0..<40).map { "Документ \($0) с некоторым текстом внутри." }
        let collection = try await seed(chroma, name: "cancel_demo", documents: documents)
        let journal = ReembeddingJournal(fileURL: directory.appendingPathComponent("journal.json"))
        let service = ReembeddingService(journal: journal)
        let backup = try await evidence(for: collection, chroma: chroma)

        // A provider that stalls, so there is time to cancel mid-run.
        struct SlowEmbeddings: EmbeddingProvider {
            func embed(texts: [String], model: String) async throws -> [[Double]] {
                try await Task.sleep(nanoseconds: 60_000_000)
                // Four components: the seeded collection is 4-dimensional, and
                // ChromaDB will not take anything else (see the refusal test).
                return texts.map { _ in [0.1, 0.2, 0.3, 0.4] }
            }
        }

        // 1. Clone: cancelling must not leave a half-built collection behind.
        let cloneTask = Task {
            try await service.run(
                ReembeddingRequest(
                    collection: collection, targetModel: "slow-stub",
                    scenario: .clone, newCollectionName: "cancel_clone"
                ),
                backup: backup, chroma: chroma,
                embeddings: SlowEmbeddings(), binding: ModelBindingService()
            ) { _ in }
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        cloneTask.cancel()
        do {
            _ = try await cloneTask.value
            XCTFail("отменённая операция не должна завершаться успешно")
        } catch {
            // expected
        }

        let names = try await chroma.listCollections(withCounts: false).map(\.name)
        XCTAssertFalse(names.contains("cancel_clone"), "незавершённый клон должен быть удалён")
        XCTAssertTrue(names.contains("cancel_demo"))

        let afterCancel = await service.journalEntries()
        XCTAssertEqual(afterCancel.first?.outcome, .cancelled)

        // 2. In place: cancelling keeps a checkpoint, and resuming finishes the job.
        let inPlaceRequest = ReembeddingRequest(collection: collection, targetModel: "alt-stub", scenario: .inPlace)
        let inPlaceTask = Task {
            try await service.run(
                inPlaceRequest, backup: backup, chroma: chroma,
                embeddings: SlowEmbeddings(), binding: ModelBindingService(), batchSize: 1
            ) { _ in }
        }
        try await Task.sleep(nanoseconds: 700_000_000)
        inPlaceTask.cancel()
        _ = try? await inPlaceTask.value

        guard let checkpoint = await service.checkpoint(for: collection.id) else {
            return XCTFail("после отмены пересчёта на месте должна остаться контрольная точка")
        }
        XCTAssertGreaterThan(checkpoint.processed, 0, "часть документов уже пересчитана")
        XCTAssertLessThan(checkpoint.processed, 40, "но не все — иначе отмена не сработала")
        XCTAssertEqual(checkpoint.totalIDs, 40)

        let alreadyDone = checkpoint.processed
        let report = try await service.run(
            inPlaceRequest, backup: backup, chroma: chroma,
            embeddings: AltStubEmbeddings(), binding: ModelBindingService(),
            resumeFromCheckpoint: true
        ) { _ in }

        XCTAssertEqual(report.processedDocuments, 40, "продолжение должно дойти до конца")
        XCTAssertLessThan(report.writtenDocuments, 40, "уже пересчитанные документы (\(alreadyDone)) не переписываются заново")
        let leftover = await service.checkpoint(for: collection.id)
        XCTAssertNil(leftover, "после завершения контрольная точка снимается")
        let finalCount = try await chroma.count(collectionID: collection.id)
        XCTAssertEqual(finalCount, 40)

        await manager.stop()
    }

    /// ChromaDB fixes a collection's vector size at its first write and keeps it
    /// even after the collection is emptied (verified against 1.4.4). So an
    /// in-place run to a differently sized model must be refused before it starts.
    @MainActor
    func testInPlaceIsRefusedWhenTheModelHasAnotherDimension() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-dim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        let chroma = try await makeServer(label: "integration-dim", directory: directory, manager: manager)
        // Synchronous on purpose: a `Task` in a `defer` does not finish before
        // the test process exits, so a failing test used to leave a live server.
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }

        let collection = try await seed(chroma, name: "dim_demo", documents: ["первый", "второй"])
        let service = ReembeddingService(journal: ReembeddingJournal(fileURL: directory.appendingPathComponent("journal.json")))

        do {
            _ = try await service.run(
                ReembeddingRequest(collection: collection, targetModel: "wide-stub", scenario: .inPlace),
                backup: try await evidence(for: collection, chroma: chroma),
                chroma: chroma,
                embeddings: WideStubEmbeddings(),
                binding: ModelBindingService()
            ) { _ in }
            XCTFail("пересчёт на месте с другой размерностью должен быть отклонён")
        } catch let error as ReembeddingError {
            guard case .dimensionChangeRequiresClone(_, let stored, let model) = error else {
                return XCTFail("ожидалась dimensionChangeRequiresClone, получено \(error)")
            }
            XCTAssertEqual(stored, 4)
            XCTAssertEqual(model, 8)
        }

        // Nothing was touched: same dimension, same vectors, same binding.
        let after = try await chroma.collection(named: "dim_demo")
        XCTAssertEqual(after.effectiveDimension, 4)
        XCTAssertEqual(after.boundModel, "stub")

        // And the server itself confirms the rule the refusal is based on.
        do {
            try await chroma.upsert(collectionID: collection.id, records: [
                EmbeddedRecord(id: "wide", document: "x", embedding: [1, 2, 3, 4, 5, 6, 7, 8], metadata: [:])
            ])
            XCTFail("сервер не должен принимать вектор другой размерности")
        } catch {
            // expected: "Collection expecting embedding with dimension of 4, got 8"
        }

        await manager.stop()
    }

    @MainActor
    func testCloneWithRechunkingSplitsDocumentsAndKeepsIdentityReadable() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-rechunk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        let chroma = try await makeServer(label: "integration-rechunk", directory: directory, manager: manager)
        // Synchronous on purpose: a `Task` in a `defer` does not finish before
        // the test process exits, so a failing test used to leave a live server.
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }

        let long = String(repeating: "Предложение про порядок расчётов между сторонами. ", count: 20)
        let collection = try await seed(chroma, name: "rechunk_src", documents: [long, long])

        let service = ReembeddingService(journal: ReembeddingJournal(fileURL: directory.appendingPathComponent("journal.json")))
        var request = ReembeddingRequest(
            collection: collection,
            targetModel: "wide-stub",
            scenario: .clone,
            newCollectionName: "rechunk_clone",
            rechunk: true
        )
        request.chunking = ChunkingConfiguration(strategy: .fixed, chunkSize: 200, sizeUnit: .characters, overlapPercent: 0)

        let report = try await service.run(
            request,
            backup: try await evidence(for: collection, chroma: chroma),
            chroma: chroma,
            embeddings: WideStubEmbeddings(),
            binding: ModelBindingService()
        ) { _ in }

        XCTAssertEqual(report.processedDocuments, 2)
        XCTAssertGreaterThan(report.writtenDocuments, 2, "каждый документ должен развалиться на несколько чанков")

        let clone = try await chroma.collection(named: "rechunk_clone")
        let rows = try await chroma.getDocuments(collectionID: clone.id, limit: 100)
        XCTAssertEqual(rows.count, report.writtenDocuments)
        // The first piece keeps the original id; the rest are visibly derived.
        XCTAssertTrue(rows.contains { $0.id == "doc-0" })
        XCTAssertTrue(rows.contains { $0.id.hasPrefix("doc-0#") })
        XCTAssertTrue(rows.allSatisfy { ($0.document?.count ?? 0) <= 220 })
        XCTAssertTrue(rows.contains { $0.metadata?["_cdbm_rechunked_from"] == .string("doc-0") })

        await manager.stop()
    }

    @MainActor
    func testExportBackupContainsDocumentsAndMetadataButNoVectors() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        let chroma = try await makeServer(label: "integration-export", directory: directory, manager: manager)
        // Synchronous on purpose: a `Task` in a `defer` does not finish before
        // the test process exits, so a failing test used to leave a live server.
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }

        let collection = try await seed(chroma, name: "export_demo", documents: ["первый", "второй", "третий"])
        let evidence = try await BackupService(directory: directory.appendingPathComponent("backups"))
            .exportCollection(collection, from: chroma, note: "тест")

        guard let url = evidence.exportURL else { return XCTFail("экспорт должен вернуть путь к файлу") }
        defer { try? FileManager.default.removeItem(at: url) }

        let payload = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(payload?["collection"] as? String, "export_demo")
        XCTAssertEqual(payload?["embeddings_included"] as? Bool, false)
        let rows = payload?["documents"] as? [[String: Any]]
        XCTAssertEqual(rows?.count, 3)
        XCTAssertNotNil(rows?.first?["document"])
        XCTAssertNotNil(rows?.first?["metadata"])
        XCTAssertNil(rows?.first?["embedding"], "векторы в экспорт не входят — их и пересчитывают")

        await manager.stop()
    }

    /// The whole 2E path on real models: fill a collection with one model, clone
    /// it onto another of a different size, and query the result.
    /// Skipped when LM Studio does not expose two embedding models.
    @MainActor
    func testReembeddingThroughTwoRealModels() async throws {
        let lmStudio = try LMStudioClient(baseURLString: "http://localhost:1234")
        guard let models = try? await lmStudio.models() else {
            throw XCTSkip("LM Studio не запущена")
        }
        let embedding = models.filter { $0.kind == .embedding || $0.id.contains("embed") }
        guard embedding.count >= 2 else {
            throw XCTSkip("нужны две эмбеддинг-модели в LM Studio")
        }

        // Two models of different vector size, so the change is visible.
        var pair: (first: String, second: String, firstDimension: Int, secondDimension: Int)?
        let binding = ModelBindingService()
        for candidate in embedding {
            for other in embedding where other.id != candidate.id {
                guard let a = try? await binding.dimension(of: candidate.id, lmStudio: lmStudio),
                      let b = try? await binding.dimension(of: other.id, lmStudio: lmStudio),
                      a != b else { continue }
                pair = (candidate.id, other.id, a, b)
                break
            }
            if pair != nil { break }
        }
        guard let pair else { throw XCTSkip("все доступные модели одной размерности") }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-real-reembed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        let chroma = try await makeServer(label: "integration-real-reembed", directory: directory, manager: manager)
        // Synchronous on purpose: a `Task` in a `defer` does not finish before
        // the test process exits, so a failing test used to leave a live server.
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }

        // Fill the collection with the first model, the way the app would.
        let documents = [
            "Порядок расчётов между сторонами договора.",
            "Счёт на оплату услуг за отчётный период.",
            "Кошка спит на подоконнике и не интересуется договорами.",
        ]
        let collection = try await chroma.createCollection(
            name: "real_reembed",
            metadata: [
                CollectionBindingKeys.model: .string(pair.first),
                CollectionBindingKeys.dimension: .int(pair.firstDimension),
            ],
            getOrCreate: true
        )
        let firstVectors = try await lmStudio.embed(texts: documents, model: pair.first)
        try await chroma.upsert(collectionID: collection.id, records: zip(documents.enumerated(), firstVectors).map {
            EmbeddedRecord(id: "d\($0.offset)", document: $0.element, embedding: $1, metadata: ["kind": .string("real")])
        })
        guard let stored = try await chroma.listCollections(withCounts: true).first(where: { $0.name == "real_reembed" }) else {
            return XCTFail("коллекция не найдена")
        }

        let service = ReembeddingService(journal: ReembeddingJournal(fileURL: directory.appendingPathComponent("journal.json")))
        let report = try await service.run(
            ReembeddingRequest(
                collection: stored,
                targetModel: pair.second,
                scenario: .clone,
                newCollectionName: "real_reembed_clone"
            ),
            backup: try await evidence(for: stored, chroma: chroma),
            chroma: chroma,
            embeddings: lmStudio,
            binding: binding
        ) { _ in }

        XCTAssertEqual(report.processedDocuments, 3)
        XCTAssertEqual(report.dimension, pair.secondDimension)
        XCTAssertTrue(report.verification.isClean, report.verification.line)

        // The clone answers questions with the new model's vectors.
        let clone = try await chroma.collection(named: "real_reembed_clone")
        XCTAssertEqual(clone.effectiveDimension, pair.secondDimension)
        let question = try await lmStudio.embed(text: "как оплатить счёт", model: pair.second)
        let hits = try await chroma.query(collectionID: clone.id, embedding: question, nResults: 1)
        XCTAssertTrue(hits.first?.document?.contains("Счёт") ?? false, "ближайшим должен быть документ про счёт, а не про кошку")

        // The original still holds the first model's vectors.
        let originalDimension = try await chroma.storedDimension(collectionID: stored.id)
        XCTAssertEqual(originalDimension, pair.firstDimension)

        await manager.stop()
    }
    // MARK: - Stage 3A: server management

    /// The point of the panic parser: a busy port must reach the user as a
    /// sentence about the port, not as a Rust backtrace.
    @MainActor
    func testStartingOnABusyPortReportsTheRealReason() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let port = PortUtility.freePort()
        let occupant = makeManager()
        _ = try await occupant.start(
            ServerLaunchConfiguration(label: "occupant", databasePath: directory, port: port)
        )
        let second = makeManager()
        let secondDirectory = directory.appendingPathComponent("second")
        do {
            _ = try await second.start(
                ServerLaunchConfiguration(label: "second", databasePath: secondDirectory, port: port),
                readinessTimeout: 20
            )
            XCTFail("второй сервер не должен занять тот же порт")
        } catch {
            XCTAssertEqual(second.lastFailure, .addressInUse(port: port))
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            XCTAssertTrue(text.contains(port.plainDigits), "в сообщении должен быть номер порта: \(text)")
            XCTAssertFalse(text.contains("RUST_BACKTRACE"), "внутренности паники наружу не идут: \(text)")
        }
        // Stopped explicitly, not in a `defer`: a detached task there does not
        // finish before the test process exits, and the server outlives the run.
        await second.stop()
        await occupant.stop()
    }

    /// Uptime ticks while it runs; a stop we asked for is not a failure.
    @MainActor
    func testUptimeRunsAndAGracefulStopIsNotReportedAsACrash() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        _ = try await manager.start(
            ServerLaunchConfiguration(label: "uptime", databasePath: directory, port: PortUtility.freePort())
        )
        let logFile = try XCTUnwrap(manager.serverLog.currentRunURL)
        XCTAssertNotNil(manager.uptime)

        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertGreaterThan(manager.uptime ?? 0, 0.9, "uptime должен идти сам")

        await manager.stop()
        XCTAssertEqual(manager.state, .stopped)
        XCTAssertNil(manager.lastFailure, "остановка по команде — не авария")
        XCTAssertNil(manager.uptime)

        // The banner the server printed is on disk, ready for a post-mortem.
        var text = ""
        for _ in 0..<40 {
            text = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
            if text.contains("остановлен по команде") { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(text.contains("Saving data to:"), "вывод сервера должен попадать в файл: \(text)")
        XCTAssertTrue(text.contains("chroma") , "команда запуска должна быть в файле")
    }
    // MARK: - Stage 3B: the proxy

    /// The point of 3B: traffic must survive the trip, and every request must
    /// land in the audit log with the right classification.
    @MainActor
    func testTrafficSurvivesTheProxyAndIsAudited() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }
        let upstream = try await manager.start(
            ServerLaunchConfiguration(label: "proxied", databasePath: directory, port: PortUtility.freePort())
        )

        let auditFile = directory.appendingPathComponent("audit.jsonl")
        let audit = AuditLog(fileURL: auditFile)
        // Since 3C the proxy denies everything that arrives without a key, so
        // even the «does traffic survive the trip» check needs one.
        let key = ClientKey.generate()
        let access = AccessController()
        await access.setClients([ExternalClient(
            name: "тест", keyHash: ClientKey.hash(key), keyPrefix: ClientKey.prefix(of: key),
            permissions: ClientPermissions(collections: ["through_proxy"], allowsWrite: true)
        )])
        // The same catalogue source the app hands it: names and vector sizes
        // come from ChromaDB itself.
        let catalogue = ChromaClient(endpoint: upstream)
        await access.setCatalogLoader {
            ((try? await catalogue.listCollections()) ?? []).map {
                CollectionSnapshot(id: $0.id, name: $0.name, dimension: $0.effectiveDimension)
            }
        }
        let proxy = ProxyServer(audit: audit, access: access)
        let proxyPort = PortUtility.freePort()
        try proxy.start(upstreamHost: upstream.host, upstreamPort: upstream.port, listenPort: proxyPort)
        defer { proxy.stop() }
        try await waitUntil { proxy.state.isRunning }

        // Everything below goes through the proxy, never to the server directly.
        let client = ChromaClient(endpoint: ChromaEndpoint(
            host: "127.0.0.1", port: proxyPort, headers: ["X-Chroma-Token": key]
        ))
        let info = try await client.connect()
        XCTAssertFalse(info.version.isEmpty)

        let collection = try await client.createCollection(
            name: "through_proxy",
            metadata: [CollectionBindingKeys.model: .string("m"), CollectionBindingKeys.dimension: .int(4)],
            getOrCreate: true
        )
        try await client.add(collectionID: collection.id, records: [
            EmbeddedRecord(id: "p1", document: "через прокси", embedding: [0.1, 0.2, 0.3, 0.4], metadata: [:]),
        ])
        let count = try await client.count(collectionID: collection.id)
        XCTAssertEqual(count, 1)
        let hits = try await client.query(collectionID: collection.id, embedding: [0.1, 0.2, 0.3, 0.4], nResults: 1)
        XCTAssertEqual(hits.first?.id, "p1")

        try await waitUntil { audit.entries.contains { $0.operation == "query" } }

        let operations = Set(audit.entries.map(\.operation))
        XCTAssertTrue(operations.contains("create_collection"), "\(operations)")
        XCTAssertTrue(operations.contains("add"), "\(operations)")
        XCTAssertTrue(operations.contains("query"), "\(operations)")

        let add = try XCTUnwrap(audit.entries.first { $0.operation == "add" })
        XCTAssertEqual(add.access, .write)
        XCTAssertEqual(add.responseStatus, 201)
        XCTAssertGreaterThan(add.requestBytes, 0, "объём запроса должен считаться")
        XCTAssertEqual(add.collection, collection.id)

        let query = try XCTUnwrap(audit.entries.first { $0.operation == "query" })
        XCTAssertEqual(query.access, .read, "поиск — это чтение, хотя и POST")
        XCTAssertGreaterThan(query.responseBytes, 0)

        // The proxy did not answer anything itself.
        XCTAssertTrue(audit.entries.allSatisfy { $0.responseStatus != nil })
        XCTAssertGreaterThan(proxy.totalRequests, 5)
    }

    /// The strongest check available: the official Python client, unmodified,
    /// pointed at the proxy.
    ///
    /// `waitUntilExit()` blocks the main thread for the whole run, so this also
    /// pins down the property that cost an afternoon: the proxy must keep
    /// serving while the main actor is busy. Accepting connections there made
    /// this test hang for ever.
    @MainActor
    func testTheRealPythonClientWorksThroughTheProxy() async throws {
        let venvPython = AppPaths.venvPython
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: venvPython.path),
            "нужен venv приложения с установленным chromadb"
        )

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }
        let upstream = try await manager.start(
            ServerLaunchConfiguration(label: "proxied-python", databasePath: directory, port: PortUtility.freePort())
        )

        let audit = AuditLog(fileURL: directory.appendingPathComponent("audit.jsonl"))
        let key = ClientKey.generate()
        let access = AccessController()
        await access.setClients([ExternalClient(
            name: "python", keyHash: ClientKey.hash(key), keyPrefix: ClientKey.prefix(of: key),
            permissions: ClientPermissions(collections: ["python_through_proxy"], allowsWrite: true)
        )])
        let catalogue = ChromaClient(endpoint: upstream)
        await access.setCatalogLoader {
            ((try? await catalogue.listCollections()) ?? []).map {
                CollectionSnapshot(id: $0.id, name: $0.name, dimension: $0.effectiveDimension)
            }
        }
        let proxy = ProxyServer(audit: audit, access: access)
        let proxyPort = PortUtility.freePort()
        try proxy.start(upstreamHost: upstream.host, upstreamPort: upstream.port, listenPort: proxyPort)
        defer { proxy.stop() }
        try await waitUntil { proxy.state.isRunning }

        let script = """
        import chromadb
        client = chromadb.HttpClient(
            host="127.0.0.1", port=\(proxyPort),
            headers={"X-Chroma-Token": "\(key)"},
        )
        client.heartbeat()
        c = client.get_or_create_collection("python_through_proxy")
        c.add(ids=["a1"], documents=["кошка"], embeddings=[[0.1, 0.2, 0.3, 0.4]])
        assert c.count() == 1, c.count()
        assert c.get(ids=["a1"])["documents"] == ["кошка"]
        assert c.query(query_embeddings=[[0.1, 0.2, 0.3, 0.4]], n_results=1)["ids"] == [["a1"]]
        client.delete_collection("python_through_proxy")
        print("PYTHON_OK")
        """
        let scriptURL = directory.appendingPathComponent("client.py")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        // Output goes to a file, not a pipe: reading a pipe to EOF from the
        // same process that also runs a server is a good way to deadlock.
        let outputURL = directory.appendingPathComponent("client.out")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        let process = Process()
        process.executableURL = venvPython
        process.arguments = [scriptURL.path]
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        try? handle.close()
        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""

        XCTAssertEqual(process.terminationStatus, 0, output)
        XCTAssertTrue(output.contains("PYTHON_OK"), output)

        try await waitUntil { audit.entries.contains { $0.operation == "delete_collection" } }

        // The client's very first call — a proxy that drops it breaks the client
        // before it does anything at all.
        XCTAssertTrue(audit.entries.contains { $0.operation == "auth_identity" })
        // Deleting a collection names it, while data operations use its UUID.
        let deletion = try XCTUnwrap(audit.entries.first { $0.operation == "delete_collection" })
        XCTAssertEqual(deletion.collection, "python_through_proxy")
        XCTAssertEqual(deletion.access, .write)

        let add = try XCTUnwrap(audit.entries.first { $0.operation == "add" })
        XCTAssertEqual(add.access, .write)
        XCTAssertNotNil(UUID(uuidString: add.collection ?? ""), "операции с данными идут по UUID")
        XCTAssertTrue(audit.entries.allSatisfy { ($0.responseStatus ?? 500) < 400 }, "ни один запрос не должен сломаться")
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("условие не выполнилось за отведённое время")
    }
    // MARK: - Stage 3C: keys and permissions through the real proxy

    /// The stage's definition of done, checked end to end against a live server:
    /// a read-only key is refused on writes, and a key whitelisted for one
    /// collection cannot see the others.
    @MainActor
    func testKeysRightsAndLimitsAgainstALiveServer() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }
        let upstream = try await manager.start(
            ServerLaunchConfiguration(label: "guarded", databasePath: directory, port: PortUtility.freePort())
        )

        // Two collections: one the key may touch, one it may not.
        let direct = ChromaClient(endpoint: upstream)
        let open = try await direct.createCollection(
            name: "open_col",
            metadata: [CollectionBindingKeys.model: .string("m"), CollectionBindingKeys.dimension: .int(4)],
            getOrCreate: true
        )
        let closed = try await direct.createCollection(
            name: "closed_col",
            metadata: [CollectionBindingKeys.model: .string("m"), CollectionBindingKeys.dimension: .int(4)],
            getOrCreate: true
        )
        try await direct.add(collectionID: open.id, records: [
            EmbeddedRecord(id: "seed", document: "начальный", embedding: [0.1, 0.2, 0.3, 0.4], metadata: [:]),
        ])
        try await direct.add(collectionID: closed.id, records: [
            EmbeddedRecord(id: "seed", document: "чужой", embedding: [0.1, 0.2, 0.3, 0.4], metadata: [:]),
        ])

        let readerKey = ClientKey.generate()
        let writerKey = ClientKey.generate()
        let reader = ExternalClient(
            name: "читатель",
            keyHash: ClientKey.hash(readerKey), keyPrefix: ClientKey.prefix(of: readerKey),
            permissions: ClientPermissions(collections: ["open_col"], allowsWrite: false)
        )
        let writer = ExternalClient(
            name: "писатель",
            keyHash: ClientKey.hash(writerKey), keyPrefix: ClientKey.prefix(of: writerKey),
            permissions: ClientPermissions(collections: ["open_col"], allowsWrite: true, maxDocumentsPerDay: 2)
        )

        let audit = AuditLog(fileURL: directory.appendingPathComponent("audit.jsonl"))
        let access = AccessController()
        await access.setClients([reader, writer])
        let proxy = ProxyServer(audit: audit, access: access)
        let proxyPort = PortUtility.freePort()
        try proxy.start(upstreamHost: upstream.host, upstreamPort: upstream.port, listenPort: proxyPort)
        defer { proxy.stop() }
        try await waitUntil { proxy.state.isRunning }
        await access.setCatalog([
            CollectionSnapshot(id: open.id, name: open.name, dimension: 4),
            CollectionSnapshot(id: closed.id, name: closed.name, dimension: 4),
        ])

        let base = "http://127.0.0.1:\(proxyPort)"
        let collections = "\(base)/api/v2/tenants/default_tenant/databases/default_database/collections"

        // No key at all.
        let anonymous = try await status(url: "\(base)/api/v2/heartbeat", key: nil)
        XCTAssertEqual(anonymous.code, 401, "без ключа прокси не должен пропускать ничего")

        // The read-only key reads.
        let read = try await status(
            url: "\(collections)/\(open.id)/get", key: readerKey, method: "POST",
            body: #"{"ids":["seed"],"include":["documents"]}"#
        )
        XCTAssertEqual(read.code, 200, read.text)
        XCTAssertTrue(read.text.contains("начальный"), read.text)

        // …and is refused on every write.
        let refusedWrite = try await status(
            url: "\(collections)/\(open.id)/add", key: readerKey, method: "POST",
            body: #"{"ids":["x1"],"embeddings":[[0.1,0.2,0.3,0.4]],"documents":["нельзя"]}"#
        )
        XCTAssertEqual(refusedWrite.code, 403, refusedWrite.text)

        // The collection outside the whitelist does not exist as far as it knows.
        let hidden = try await status(
            url: "\(collections)/\(closed.id)/get", key: readerKey, method: "POST",
            body: #"{"ids":["seed"]}"#
        )
        XCTAssertEqual(hidden.code, 404, hidden.text)

        // And the listing does not mention it either.
        let listed = try await status(url: collections, key: readerKey)
        XCTAssertTrue(listed.text.contains("open_col"), listed.text)
        XCTAssertFalse(listed.text.contains("closed_col"), "ключ не должен видеть чужие коллекции: \(listed.text)")

        // The writing key writes.
        let written = try await status(
            url: "\(collections)/\(open.id)/add", key: writerKey, method: "POST",
            body: #"{"ids":["w1"],"embeddings":[[0.5,0.5,0.5,0.5]],"documents":["записано"]}"#
        )
        XCTAssertLessThan(written.code, 300, written.text)

        // A vector of the wrong size never reaches the database.
        let wrongSize = try await status(
            url: "\(collections)/\(open.id)/add", key: writerKey, method: "POST",
            body: #"{"ids":["w2"],"embeddings":[[0.5,0.5]],"documents":["другая модель"]}"#
        )
        XCTAssertEqual(wrongSize.code, 400, wrongSize.text)

        // The daily limit stops the third document.
        let overLimit = try await status(
            url: "\(collections)/\(open.id)/add", key: writerKey, method: "POST",
            body: #"{"ids":["w3","w4"],"embeddings":[[0.5,0.5,0.5,0.5],[0.5,0.5,0.5,0.5]]}"#
        )
        XCTAssertEqual(overLimit.code, 429, overLimit.text)

        // Nothing forbidden reached the database.
        let stored = try await direct.getDocuments(collectionID: open.id, limit: 100, offset: 0).map(\.id).sorted()
        XCTAssertEqual(stored, ["seed", "w1"], "в базе должно быть только разрешённое")

        // Every refusal is in the audit log, with the client's name on it.
        try await waitUntil { audit.entries.contains { $0.responseStatus == 429 } }
        let refusals = audit.entries.filter { ($0.responseStatus ?? 0) >= 400 }
        XCTAssertTrue(refusals.contains { $0.responseStatus == 403 && $0.client == "читатель" })
        XCTAssertTrue(refusals.contains { $0.responseStatus == 400 && $0.client == "писатель" })
        XCTAssertTrue(refusals.allSatisfy { $0.note?.isEmpty == false }, "у отказа должна быть причина")
    }

    /// The official Python client, unmodified, with a key in its headers.
    @MainActor
    func testTheRealPythonClientWorksWithAKeyAndIsStoppedWithout() async throws {
        let venvPython = AppPaths.venvPython
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: venvPython.path),
            "нужен venv приложения с установленным chromadb"
        )

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }
        let upstream = try await manager.start(
            ServerLaunchConfiguration(label: "guarded-python", databasePath: directory, port: PortUtility.freePort())
        )

        let direct = ChromaClient(endpoint: upstream)
        let collection = try await direct.createCollection(
            name: "py_guarded",
            metadata: [CollectionBindingKeys.model: .string("m"), CollectionBindingKeys.dimension: .int(4)],
            getOrCreate: true
        )
        try await direct.add(collectionID: collection.id, records: [
            EmbeddedRecord(id: "seed", document: "начальный", embedding: [0.1, 0.2, 0.3, 0.4], metadata: [:]),
        ])

        let key = ClientKey.generate()
        let client = ExternalClient(
            name: "python",
            keyHash: ClientKey.hash(key), keyPrefix: ClientKey.prefix(of: key),
            permissions: ClientPermissions(collections: ["py_guarded"], allowsWrite: true)
        )
        let audit = AuditLog(fileURL: directory.appendingPathComponent("audit.jsonl"))
        let access = AccessController()
        await access.setClients([client])
        await access.setCatalog([CollectionSnapshot(id: collection.id, name: collection.name, dimension: 4)])
        let proxy = ProxyServer(audit: audit, access: access)
        let proxyPort = PortUtility.freePort()
        try proxy.start(upstreamHost: upstream.host, upstreamPort: upstream.port, listenPort: proxyPort)
        defer { proxy.stop() }
        try await waitUntil { proxy.state.isRunning }

        let script = """
        import chromadb
        ok = chromadb.HttpClient(
            host="127.0.0.1", port=\(proxyPort),
            headers={"X-Chroma-Token": "\(key)"},
        )
        col = ok.get_or_create_collection("py_guarded")
        col.add(ids=["p1"], documents=["через ключ"], embeddings=[[0.2, 0.3, 0.4, 0.5]])
        assert col.count() == 2, col.count()
        assert col.get(ids=["p1"])["documents"] == ["через ключ"]
        print("WITH_KEY_OK")

        try:
            bad = chromadb.HttpClient(host="127.0.0.1", port=\(proxyPort))
            bad.heartbeat()
            print("NO_KEY_PASSED")
        except Exception as error:
            print("NO_KEY_REFUSED", type(error).__name__)
        """
        let scriptURL = directory.appendingPathComponent("client.py")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        // Output goes to a file, not a pipe (see the note in the 3B test).
        let outputURL = directory.appendingPathComponent("client.out")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        let process = Process()
        process.executableURL = venvPython
        process.arguments = [scriptURL.path]
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        try? handle.close()
        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""

        XCTAssertTrue(output.contains("WITH_KEY_OK"), output)
        XCTAssertTrue(output.contains("NO_KEY_REFUSED"), "без ключа клиент не должен подключаться: \(output)")
        XCTAssertFalse(output.contains("NO_KEY_PASSED"), output)

        try await waitUntil { audit.entries.contains { $0.operation == "add" } }
        let add = try XCTUnwrap(audit.entries.first { $0.operation == "add" })
        XCTAssertEqual(add.client, "python", "в журнале должно стоять имя клиента, а не адрес")
    }

    // MARK: - Stage 3D: what the network can actually reach

    /// The definition of done for stage 3, checked against a real server: with
    /// the proxy deliberately opened to the network, the ChromaDB port must
    /// stay invisible from that very same address.
    @MainActor
    func testOnlyTheProxyPortIsReachableFromTheNetwork() async throws {
        guard let address = LocalNetwork.addresses().first else {
            throw XCTSkip("у машины нет сетевого адреса — проверять нечего")
        }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }
        let upstream = try await manager.start(
            ServerLaunchConfiguration(label: "exposed", databasePath: directory, port: PortUtility.freePort())
        )
        XCTAssertEqual(upstream.host, "127.0.0.1", "сервер приложение запускает только на loopback")

        let key = ClientKey.generate()
        let access = AccessController()
        await access.setClients([ExternalClient(
            name: "сетевой", keyHash: ClientKey.hash(key), keyPrefix: ClientKey.prefix(of: key),
            permissions: ClientPermissions(collections: ["exposed"])
        )])
        let audit = AuditLog(fileURL: directory.appendingPathComponent("audit.jsonl"))
        let proxy = ProxyServer(audit: audit, access: access)
        let proxyPort = PortUtility.freePort()
        try proxy.start(
            upstreamHost: upstream.host, upstreamPort: upstream.port,
            listenPort: proxyPort, exposure: .allInterfaces
        )
        defer { proxy.stop() }
        try await waitUntil { proxy.state.isRunning }

        // The proxy answers on the network address — with a key, and not without.
        let withKey = try await status(url: "http://\(address):\(proxyPort)/api/v2/heartbeat", key: key)
        XCTAssertEqual(withKey.code, 200, withKey.text)
        let withoutKey = try await status(url: "http://\(address):\(proxyPort)/api/v2/heartbeat", key: nil)
        XCTAssertEqual(withoutKey.code, 401, withoutKey.text)

        // The database's own port, from the same address, is not there at all.
        do {
            let leaked = try await status(
                url: "http://\(address):\(upstream.port)/api/v2/heartbeat", key: nil, timeout: 5
            )
            XCTFail("порт ChromaDB не должен отвечать по адресу \(address): \(leaked)")
        } catch {
            // Refused or dropped — either way it is unreachable.
        }
        // …while locally it is exactly where the app put it.
        let local = try await status(url: "http://127.0.0.1:\(upstream.port)/api/v2/heartbeat", key: nil)
        XCTAssertEqual(local.code, 200, local.text)

        // The first thing «Экстренная остановка» does: close the door.
        proxy.stop()
        do {
            let stillOpen = try await status(
                url: "http://\(address):\(proxyPort)/api/v2/heartbeat", key: key, timeout: 5
            )
            XCTFail("после остановки прокси порт не должен отвечать: \(stillOpen)")
        } catch {
            // Expected.
        }
    }

    // MARK: - Addendum A1: the metric a collection is actually created with

    /// 9 asks for this to be proven by reading the configuration back from
    /// the server, not by the request not failing.
    @MainActor
    func testTheMetricIsWrittenAndReadBackFromTheServer() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-a1-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }
        let endpoint = try await manager.start(
            ServerLaunchConfiguration(label: "integration-a1", databasePath: directory, port: PortUtility.freePort())
        )
        let client = ChromaClient(endpoint: endpoint)

        // What the app creates: cosine, plus two index parameters.
        let created = try await client.createCollection(
            name: "metric_cosine",
            configuration: CollectionConfiguration(
                metric: .cosine,
                hnsw: HNSWParameters(efConstruction: 200, maxNeighbors: 32)
            ),
            getOrCreate: true
        )
        XCTAssertEqual(created.space, .cosine)

        // Read back as a separate request — the create response could in
        // principle echo the request rather than the stored state.
        let reloaded = try await client.collection(named: "metric_cosine")
        XCTAssertEqual(reloaded.space, .cosine, "метрика должна остаться в коллекции, а не только в запросе")
        XCTAssertEqual(reloaded.hnsw?.efConstruction, 200)
        XCTAssertEqual(reloaded.hnsw?.maxNeighbors, 32)
        XCTAssertEqual(reloaded.metadata?[CollectionBindingKeys.space], .string("cosine"))

        // What somebody else's tool leaves behind: no configuration at all, so
        // the server's own default applies and the app reports it truthfully.
        var request = URLRequest(url: URL(string: "\(endpoint.baseURLString)/api/v2/tenants/\(endpoint.tenant)/databases/\(endpoint.database)/collections")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"name":"metric_default","get_or_create":true}"#.utf8)
        _ = try await URLSession(configuration: .ephemeral).data(for: request)

        let foreign = try await client.collection(named: "metric_default")
        XCTAssertEqual(foreign.space, .l2, "серверный дефолт — l2, и приложение показывает его как есть")

        // Both spellings on one server: the metadata form alone also lands in
        // the configuration, which is why the app sends it too.
        var legacy = URLRequest(url: URL(string: "\(endpoint.baseURLString)/api/v2/tenants/\(endpoint.tenant)/databases/\(endpoint.database)/collections")!)
        legacy.httpMethod = "POST"
        legacy.setValue("application/json", forHTTPHeaderField: "Content-Type")
        legacy.httpBody = Data(#"{"name":"metric_legacy","get_or_create":true,"metadata":{"hnsw:space":"cosine"}}"#.utf8)
        _ = try await URLSession(configuration: .ephemeral).data(for: legacy)

        let legacyCollection = try await client.collection(named: "metric_legacy")
        XCTAssertEqual(legacyCollection.space, .cosine, "старая форма записи метрики этой версией тоже применяется")

        // And the ranking actually differs, which is the whole reason to care.
        try await client.add(collectionID: created.id, records: [
            EmbeddedRecord(id: "a", document: "a", embedding: [1, 0, 0, 0], metadata: [:]),
            EmbeddedRecord(id: "b", document: "b", embedding: [10, 0, 0, 0], metadata: [:]),
        ])
        let hits = try await client.query(collectionID: created.id, embedding: [2, 0, 0, 0], nResults: 2)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(
            hits.first?.distance ?? 1, 0, accuracy: 0.0001,
            "при косинусной метрике коллинеарные векторы совпадают, каким бы ни был их масштаб"
        )
    }

    // MARK: - Addendum A6: an interrupted re-index, replayed against a real server

    /// The fake database proves the ordering; this proves the replay works on
    /// the thing it will actually run against — including the two facts checked
    /// on the live server first: deleting ids that are already gone is fine,
    /// and deleting nothing at all is a 400.
    @MainActor
    func testAnInterruptedReindexIsReplayedAgainstARealServer() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-a6-\(UUID().uuidString)")
        let folder = directory.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try String(repeating: "документ про договоры и счета. ", count: 40)
            .write(to: folder.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)

        let manager = makeManager()
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }
        let endpoint = try await manager.start(
            ServerLaunchConfiguration(
                label: "integration-a6",
                databasePath: directory.appendingPathComponent("db"),
                port: PortUtility.freePort()
            )
        )
        let chroma = ChromaClient(endpoint: endpoint)
        try await chroma.connect()

        let manifests = ManifestStore(directory: directory.appendingPathComponent("manifests"))
        let journal = SyncJournal(directory: directory.appendingPathComponent("journals"))
        let service = SourceSyncService(manifests: manifests, journal: journal)
        let source = DataSource(
            name: "docs", path: folder.path, fileExtensions: ["md"],
            collectionName: "a6_live",
            chunking: ChunkingConfiguration(strategy: .fixed, chunkSize: 200, sizeUnit: .characters, overlapPercent: 0)
        )

        let first = try await service.sync(
            source: source, embeddingModel: "stub", chroma: chroma,
            embeddings: StubEmbeddings(), binding: ModelBindingService()
        ) { _ in }
        XCTAssertEqual(first.added, 1)
        XCTAssertEqual(first.recoveredFiles, 0)
        let journalEmptyAtStart = await service.pendingRecovery(sourceID: source.id).isEmpty
        XCTAssertTrue(journalEmptyAtStart, "журнал в норме пуст")

        let collectionID = try await chroma.resolveID(of: "a6_live")
        let writtenIDs = manifests.load(sourceID: source.id).entries["a.md"]?.chunkIDs ?? []
        XCTAssertGreaterThan(writtenIDs.count, 2)

        // Stage the exact state a crash between the write and the cleanup
        // leaves: the collection holds everything, the journal says the tail is
        // still there, and the manifest has not been updated.
        let survivingIDs = Array(writtenIDs.prefix(2))
        var manifest = manifests.load(sourceID: source.id)
        let entry = try XCTUnwrap(manifest.entries["a.md"])
        manifest.forget(relativePath: "a.md")
        manifests.save(manifest)
        try journal.begin(
            SyncJournalEntry(
                relativePath: "a.md", collectionName: "a6_live",
                oldIDs: writtenIDs, newIDs: survivingIDs, state: .upserted,
                contentHash: entry.contentHash, modifiedAt: entry.modifiedAt, size: entry.size,
                chunkingSignature: entry.chunkingSignature, embeddingModel: entry.embeddingModel
            ),
            sourceID: source.id
        )

        let recovery = await service.recover(source: source, chroma: chroma)
        XCTAssertEqual(recovery.finished, ["a.md"])
        XCTAssertTrue(recovery.failures.isEmpty)

        let afterRecovery = try await chroma.count(collectionID: collectionID)
        XCTAssertEqual(afterRecovery, survivingIDs.count, "хвост удалён на живом сервере")
        XCTAssertEqual(manifests.load(sourceID: source.id).entries["a.md"]?.chunkIDs, survivingIDs)
        let journalEmptyAfterRecovery = await service.pendingRecovery(sourceID: source.id).isEmpty
        XCTAssertTrue(journalEmptyAfterRecovery)
        let blockReason = await service.recoveryBlockReason(sourceID: source.id)
        XCTAssertNil(blockReason)

        // Replaying a finished record is harmless: the ids are already gone and
        // the server answers 200 to deleting what is not there.
        try await chroma.deleteDocuments(collectionID: collectionID, ids: writtenIDs)
        let afterRepeat = try await chroma.count(collectionID: collectionID)
        XCTAssertEqual(afterRepeat, 0)
    }

    // MARK: - Acceptance: the definition-of-done items that need volume or a
    // database this app did not create

    /// Stage 2 asks for «коллекция на 10 000+ документов открывается без
    /// зависания UI и без загрузки всего в память». The load is real; what is
    /// checked is that opening it costs one page, not the whole collection.
    @MainActor
    func testACollectionOfTenThousandOpensByPages() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }
        let endpoint = try await manager.start(
            ServerLaunchConfiguration(label: "volume", databasePath: directory, port: PortUtility.freePort())
        )
        let client = ChromaClient(endpoint: endpoint)
        let collection = try await client.createCollection(
            name: "volume",
            metadata: [CollectionBindingKeys.model: .string("test"), CollectionBindingKeys.dimension: .int(4)],
            getOrCreate: true
        )

        // Deterministic pseudo-vectors: this test is about volume, not about
        // embeddings, and it must not need LM Studio.
        let total = 10_000
        for start in stride(from: 0, to: total, by: 500) {
            let records = (start..<min(start + 500, total)).map { index -> EmbeddedRecord in
                let value = Double(index % 97) / 97
                return EmbeddedRecord(
                    id: "doc-\(index)",
                    document: "документ номер \(index)",
                    embedding: [value, 1 - value, value / 2, 0.5],
                    metadata: ["bucket": .int(index % 10), "even": .bool(index % 2 == 0)]
                )
            }
            try await client.add(collectionID: collection.id, records: records)
        }

        let count = try await client.count(collectionID: collection.id)
        XCTAssertEqual(count, total)

        // One page, and only one page: the screen shows the first hundred.
        let firstPageStarted = Date()
        let firstPage = try await client.getDocuments(collectionID: collection.id, limit: 100)
        let firstPageSeconds = Date().timeIntervalSince(firstPageStarted)
        XCTAssertEqual(firstPage.count, 100)
        XCTAssertLessThan(firstPageSeconds, 3, "первая страница не должна собираться дольше трёх секунд")

        // «Показать ещё» is an offset, not a second copy of everything.
        let secondPage = try await client.getDocuments(collectionID: collection.id, limit: 100, offset: 100)
        XCTAssertEqual(secondPage.count, 100)
        XCTAssertTrue(Set(firstPage.map(\.id)).isDisjoint(with: Set(secondPage.map(\.id))))

        // A metadata filter is answered by the server, so the client never has
        // to hold ten thousand documents to find a hundred.
        let filtered = try await client.getDocuments(
            collectionID: collection.id,
            limit: 100,
            filter: DocumentFilter(conditions: [
                MetadataCondition(field: "bucket", op: .equals, value: "3"),
            ])
        )
        XCTAssertEqual(filtered.count, 100)
        XCTAssertTrue(filtered.allSatisfy { $0.metadata?["bucket"] == .int(3) })

        // …and the vectors are still searchable at this size.
        let hits = try await client.query(collectionID: collection.id, embedding: [0, 1, 0, 0.5], nResults: 5)
        XCTAssertEqual(hits.count, 5)
    }

    /// Stage 1 asks for a database filled by `Scripts/seed-demo-data.sh` —
    /// that is, by something other than this app — to open, show its documents,
    /// accept a model binding by hand and answer a query afterwards.
    @MainActor
    func testADatabaseFilledByTheSeedScriptOpensAndCanBeBound() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }
        let port = PortUtility.freePort()
        let endpoint = try await manager.start(
            ServerLaunchConfiguration(label: "foreign", databasePath: directory, port: port)
        )

        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ChromaCoreTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Scripts/seed-demo-data.sh")
        let seeding = Process()
        seeding.executableURL = URL(fileURLWithPath: "/bin/bash")
        seeding.arguments = [
            script.path, "--host", "127.0.0.1", "--port", String(port),
            "--collection", "cdbm_demo", "--dim", "8",
        ]
        seeding.standardOutput = FileHandle.nullDevice
        seeding.standardError = FileHandle.nullDevice
        try seeding.run()
        seeding.waitUntilExit()
        XCTAssertEqual(seeding.terminationStatus, 0, "скрипт наполнения должен отработать без ошибок")

        let client = ChromaClient(endpoint: endpoint)
        let collections = try await client.listCollections()
        let demo = try XCTUnwrap(collections.first { $0.name == "cdbm_demo" })
        XCTAssertGreaterThan(demo.documentCount ?? 0, 0, "документы чужой базы должны быть видны")
        // The app has to admit it does not know the model rather than guess one.
        XCTAssertNil(demo.boundModel, "у чужой коллекции модели не записано")
        XCTAssertEqual(demo.effectiveDimension, 8, "размерность выводится из самих векторов")

        let documents = try await client.getDocuments(collectionID: demo.id, limit: 5)
        XCTAssertFalse(documents.isEmpty)
        XCTAssertFalse(documents[0].document?.isEmpty ?? true)

        // Binding by hand: a model of another size is refused, the right one is
        // written into the collection's metadata.
        let binding = ModelBindingService()
        do {
            try await binding.validate(vectorLength: 384, for: demo)
            XCTFail("модель другой размерности не должна привязываться")
        } catch BindingError.dimensionConflict(_, let stored, let model) {
            XCTAssertEqual(stored, 8)
            XCTAssertEqual(model, 384)
        }
        try await client.updateCollection(
            id: demo.id,
            metadata: demo.metadataBinding(model: "seeded-model", dimension: 8)
        )
        let bound = try await client.collection(named: "cdbm_demo")
        XCTAssertEqual(bound.boundModel, "seeded-model")

        // And a query works against data this app never wrote.
        let dimension = try await client.storedDimension(collectionID: demo.id)
        XCTAssertEqual(dimension, 8)
        let hits = try await client.query(
            collectionID: demo.id,
            embedding: Array(repeating: 0.25, count: 8),
            nResults: 3
        )
        XCTAssertFalse(hits.isEmpty)
    }

    /// Stage 1 asks that an engine upgrade back the database up, verify it, and
    /// be restorable. The copy is only valid with the server stopped,
    /// so that ordering is part of what is checked.
    @MainActor
    func testBackupIsVerifiedAndRestoresADatabase() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-\(UUID().uuidString)")
        let data = root.appendingPathComponent("db")
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = makeManager()
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }
        let endpoint = try await manager.start(
            ServerLaunchConfiguration(label: "backup", databasePath: data, port: PortUtility.freePort())
        )
        let client = ChromaClient(endpoint: endpoint)
        let collection = try await client.createCollection(
            name: "before_upgrade",
            metadata: [CollectionBindingKeys.model: .string("test"), CollectionBindingKeys.dimension: .int(4)],
            getOrCreate: true
        )
        try await client.add(collectionID: collection.id, records: (0..<20).map {
            EmbeddedRecord(id: "b\($0)", document: "строка \($0)", embedding: [0.1, 0.2, 0.3, Double($0) / 20], metadata: [:])
        })

        // Stop first: copying a live SQLite file produces a broken copy.
        await manager.stop()
        XCTAssertFalse(manager.isRunning)

        let service = BackupService(directory: root.appendingPathComponent("backups"))
        let evidence = try service.backupLocalDatabase(at: data, note: "перед обновлением движка")
        let record = try XCTUnwrap(evidence.record, "для локальной базы копия — это каталог")
        XCTAssertGreaterThan(record.sizeBytes, 0)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: record.url.appendingPathComponent("chroma.sqlite3").path),
            "в копии должен быть файл базы"
        )

        // Lose the database the way a failed upgrade would.
        try FileManager.default.removeItem(at: data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.path))

        try service.restore(record, to: data)
        let restored = try await manager.start(
            ServerLaunchConfiguration(label: "restored", databasePath: data, port: PortUtility.freePort())
        )
        let afterRestore = ChromaClient(endpoint: restored)
        let collections = try await afterRestore.listCollections()
        let survivor = try XCTUnwrap(collections.first { $0.name == "before_upgrade" })
        let survivingCount = try await afterRestore.count(collectionID: survivor.id)
        XCTAssertEqual(survivingCount, 20)
        XCTAssertEqual(survivor.boundModel, "test", "привязка модели переживает восстановление")
    }

    /// Stage 2 asks that an import of a thousand CSV rows run with progress and
    /// stay cancellable. Both are only meaningful against the real thing: the
    /// slow part is LM Studio, and cancellation has to interrupt it mid-batch.
    @MainActor
    func testAThousandRowCSVImportReportsProgressAndCanBeCancelled() async throws {
        let lmStudio = try LMStudioClient(baseURLString: "http://localhost:1234")
        guard let models = try? await lmStudio.models(),
              let model = models.first(where: { $0.kind == .embedding })
                  ?? models.first(where: { $0.id.contains("embed") }) else {
            throw XCTSkip("LM Studio не запущена или в ней нет эмбеддинг-модели")
        }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }
        let endpoint = try await manager.start(
            ServerLaunchConfiguration(label: "import", databasePath: directory, port: PortUtility.freePort())
        )
        let chroma = ChromaClient(endpoint: endpoint)
        let binding = ModelBindingService()
        let dimension = try await binding.dimension(of: model.id, lmStudio: lmStudio)
        let collection = try await chroma.createCollection(
            name: "csv_import",
            metadata: [CollectionBindingKeys.model: .string(model.id), CollectionBindingKeys.dimension: .int(dimension)],
            getOrCreate: true
        )

        var csv = "id,text,topic\n"
        for index in 0..<1000 {
            csv += "row-\(index),\"Строка номер \(index) про тему \(index % 7)\",тема-\(index % 7)\n"
        }
        let table = try ImportService.parseDelimited(csv)
        XCTAssertEqual(table.rowCount, 1000)
        let (documents, skipped) = try ImportService.prepare(
            table,
            mapping: ImportMapping(documentColumn: "text", idColumn: "id", metadataColumns: ["topic"])
        )
        XCTAssertEqual(documents.count, 1000)

        // Cancellation first, on the same data: it has to stop mid-flight and
        // say so, rather than finish quietly or hang.
        let service = DocumentImportService()
        let cancellable = Task {
            try await service.importDocuments(
                documents, skippedEmpty: skipped, into: collection, model: model.id,
                chroma: chroma, lmStudio: lmStudio, binding: binding,
                progress: { _ in }
            )
        }
        // Cancel once it is genuinely in flight, not before it started.
        var writtenBeforeCancel = 0
        for _ in 0..<600 where writtenBeforeCancel == 0 {
            writtenBeforeCancel = (try? await chroma.count(collectionID: collection.id)) ?? 0
            if writtenBeforeCancel == 0 { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        XCTAssertGreaterThan(writtenBeforeCancel, 0, "хотя бы одна пачка должна успеть записаться")
        cancellable.cancel()
        do {
            _ = try await cancellable.value
            XCTFail("импорт должен был отмениться")
        } catch is CancellationError {
            // Expected.
        }
        let afterCancel = try await chroma.count(collectionID: collection.id)
        XCTAssertLessThan(afterCancel, 1000, "отменённый импорт не должен дописать всё до конца")

        // Then the whole thousand, watching the progress it reports.
        let reports = ProgressRecorder()
        let summary = try await service.importDocuments(
            documents, skippedEmpty: skipped, into: collection, model: model.id,
            chroma: chroma, lmStudio: lmStudio, binding: binding,
            progress: { reports.add($0) }
        )

        // Rows the cancelled run had already written are skipped rather than
        // re-embedded — that is the default duplicate policy — so the two
        // numbers together account for the file.
        XCTAssertEqual(summary.written + summary.skippedDuplicates.count, 1000)
        let finalCount = try await chroma.count(collectionID: collection.id)
        XCTAssertEqual(finalCount, 1000, "повторный импорт тех же id не плодит дубли")
        let fractions = reports.fractions
        XCTAssertGreaterThan(fractions.count, 10, "прогресс должен приходить по ходу, а не одним куском")
        XCTAssertEqual(fractions.first, 0)
        XCTAssertEqual(fractions.last, 1)
        XCTAssertEqual(fractions, fractions.sorted(), "прогресс не должен идти назад")

        let stored = try await chroma.getDocuments(collectionID: collection.id, limit: 1, ids: ["row-500"])
        XCTAssertEqual(stored.first?.metadata?["topic"], .string("тема-3"))
        // an imported document belongs to no source, and the field is what
        // says so — read back from the server, not from the prepared batch.
        XCTAssertEqual(DocumentOrigin.of(stored.first?.metadata), .imported)
    }

    /// an import that stopped part of the way through continues from
    /// there instead of embedding everything a second time.
    @MainActor
    func testAnInterruptedImportContinuesFromWhereItStopped() async throws {
        let lmStudio = try LMStudioClient(baseURLString: "http://localhost:1234")
        guard let models = try? await lmStudio.models(),
              let model = models.first(where: { $0.kind == .embedding })
                  ?? models.first(where: { $0.id.contains("embed") }) else {
            throw XCTSkip("LM Studio не запущена или в ней нет эмбеддинг-модели")
        }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }
        let endpoint = try await manager.start(
            ServerLaunchConfiguration(label: "import-resume", databasePath: directory, port: PortUtility.freePort())
        )
        let chroma = ChromaClient(endpoint: endpoint)
        let binding = ModelBindingService()
        let dimension = try await binding.dimension(of: model.id, lmStudio: lmStudio)
        let collection = try await chroma.createCollection(
            name: "import_resume",
            metadata: [CollectionBindingKeys.model: .string(model.id), CollectionBindingKeys.dimension: .int(dimension)],
            getOrCreate: true
        )

        let documents = (0..<100).map { index in
            PreparedDocument(id: "row-\(index)", text: "Строка номер \(index)", metadata: [:])
        }
        // Pretend the first sixty are already in: that is exactly the state an
        // interrupted run leaves behind.
        let summary = try await DocumentImportService().importDocuments(
            documents, into: collection, model: model.id,
            chroma: chroma, lmStudio: lmStudio, binding: binding,
            startingAt: 60,
            progress: { _ in }
        )

        XCTAssertEqual(summary.written, 100, "итог считает и то, что было записано до сбоя")
        let stored = try await chroma.count(collectionID: collection.id)
        XCTAssertEqual(stored, 40, "повторно отправляется только хвост")

        let tail = try await chroma.getDocuments(collectionID: collection.id, limit: 100)
        XCTAssertFalse(tail.contains { $0.id == "row-59" }, "уже записанные документы не пересчитываются")
        XCTAssertTrue(tail.contains { $0.id == "row-60" })
        XCTAssertTrue(tail.contains { $0.id == "row-99" })
    }

    /// Collects progress callbacks from whatever queue they arrive on.
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Double] = []

        func add(_ progress: ImportProgress) {
            lock.lock(); storage.append(progress.fraction); lock.unlock()
        }

        var fractions: [Double] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }

    // MARK: - A2: batch limits against a real server

    /// a write larger than the server's own batch limit goes through,
    /// and every row lands.
    @MainActor
    func testAWriteLargerThanTheServersLimitGoesThroughInParts() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-a2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }
        let endpoint = try await manager.start(
            ServerLaunchConfiguration(label: "integration-a2", databasePath: directory, port: PortUtility.freePort())
        )
        let client = ChromaClient(endpoint: endpoint)

        // The limit is the server's own answer, not our fallback.
        let limits = await client.writeLimits()
        XCTAssertTrue(limits.isReportedByServer, "сервер обязан отвечать на /pre-flight-checks")
        XCTAssertGreaterThan(limits.maxRecords, 0)

        let collection = try await client.createCollection(
            name: "a2_large_write",
            configuration: CollectionConfiguration(metric: .cosine)
        )

        // Deliberately more than one sub-batch.
        let total = limits.maxRecords + 500
        let records = (0..<total).map { index in
            EmbeddedRecord(
                id: "row-\(index)",
                document: "документ номер \(index)",
                embedding: [Double(index % 97) / 97.0, 0.5, 0.25, 0.125],
                metadata: ["n": .int(index)]
            )
        }
        try await client.upsert(collectionID: collection.id, records: records)

        let stored = try await client.count(collectionID: collection.id)
        XCTAssertEqual(stored, total, "все записи должны оказаться в коллекции")

        // Spot-check the boundary between sub-batches: an off-by-one in the
        // splitter would show up exactly here.
        let boundary = try await client.getDocuments(
            collectionID: collection.id,
            ids: ["row-0", "row-\(limits.maxRecords - 1)", "row-\(limits.maxRecords)", "row-\(total - 1)"]
        )
        XCTAssertEqual(Set(boundary.map(\.id)).count, 4)

        // Repeating the same write is safe: ids are deterministic and the
        // operation is an upsert, which is what makes «повторить» honest.
        try await client.upsert(collectionID: collection.id, records: Array(records.prefix(10)))
        let afterRepeat = try await client.count(collectionID: collection.id)
        XCTAssertEqual(afterRepeat, total)
    }

    /// where the server actually stops accepting a body, and how it says
    /// so. The app's own 32 MB cap sits below this on purpose.
    @MainActor
    func testTheServerRefusesABodyOverFortyMebibytes() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-a2b-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }
        let endpoint = try await manager.start(
            ServerLaunchConfiguration(label: "integration-a2b", databasePath: directory, port: PortUtility.freePort())
        )
        let client = ChromaClient(endpoint: endpoint)
        let collection = try await client.createCollection(name: "a2_body_limit")

        func upsertBody(documentBytes: Int) -> String {
            let text = String(repeating: "z", count: documentBytes)
            return #"{"ids":["big"],"embeddings":[[0.1,0.2,0.3,0.4]],"documents":["\#(text)"],"metadatas":[{"k":1}]}"#
        }
        let path = "\(endpoint.baseURLString)\(endpoint.collectionsPath)/\(collection.id)/upsert"

        let accepted = try await status(url: path, key: nil, method: "POST", body: upsertBody(documentBytes: 30_000_000), timeout: 120)
        XCTAssertEqual(accepted.code, 200, "30 МБ сервер принимает")

        let refused = try await status(url: path, key: nil, method: "POST", body: upsertBody(documentBytes: 42_000_000), timeout: 120)
        XCTAssertEqual(refused.code, 413, "выше 40 MiB — Payload too large, а не молчание")

        // And the app never gets that far: the splitter refuses the record.
        let oversized = EmbeddedRecord(
            id: "big",
            document: String(repeating: "z", count: 42_000_000),
            embedding: [0.1, 0.2, 0.3, 0.4],
            metadata: [:]
        )
        XCTAssertThrowsError(try BatchSplitter.split([oversized], limits: WriteLimits())) { error in
            guard case BatchSplitError.recordTooLarge = error else {
                return XCTFail("ожидалась recordTooLarge, получено \(error)")
            }
        }
    }

    // MARK: - A4/A5 against a real server

    /// a collection deleted and re-created outside the app must not break
    /// the next operation.
    @MainActor
    func testACollectionRecreatedBehindTheAppsBackKeepsWorking() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-a4-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }
        let endpoint = try await manager.start(
            ServerLaunchConfiguration(label: "integration-a4", databasePath: directory, port: PortUtility.freePort())
        )
        let app = ChromaClient(endpoint: endpoint)
        // A second client stands in for «another tool»: it has its own cache,
        // exactly like a script or a second window would.
        let other = ChromaClient(endpoint: endpoint)

        let created = try await app.createCollection(
            name: "a4_notes",
            configuration: CollectionConfiguration(metric: .cosine)
        )
        let originalID = try await app.resolveID(of: "a4_notes")
        XCTAssertEqual(originalID, created.id)
        try await app.upsert(
            collectionID: originalID,
            records: [EmbeddedRecord(id: "one", document: "первый", embedding: [0.1, 0.2], metadata: [:])]
        )

        // Someone else deletes it and makes a new one under the same name.
        try await other.deleteCollection(name: "a4_notes")
        let replacement = try await other.createCollection(
            name: "a4_notes",
            configuration: CollectionConfiguration(metric: .cosine)
        )
        XCTAssertNotEqual(replacement.id, originalID, "новая коллекция обязана иметь другой UUID")

        // The app still holds the old id. The operation must go through anyway.
        try await app.upsert(
            collectionID: originalID,
            records: [EmbeddedRecord(id: "two", document: "второй", embedding: [0.3, 0.4], metadata: [:])]
        )
        let count = try await app.count(collectionID: originalID)
        XCTAssertEqual(count, 1, "запись должна попасть в новую коллекцию, а не в исчезнувшую")
        let resolvedAfterRecreation = try await app.resolveID(of: "a4_notes")
        XCTAssertEqual(resolvedAfterRecreation, replacement.id)

        // A collection that is really gone still fails, and says so.
        try await other.deleteCollection(name: "a4_notes")
        do {
            _ = try await app.count(collectionID: replacement.id)
            XCTFail("удалённая коллекция должна давать ошибку")
        } catch ChromaError.collectionNotFound {
            // expected
        }
    }

    /// the validator agrees with the server on every boundary name.
    @MainActor
    func testTheNameValidatorAgreesWithTheServer() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-a5-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }
        let endpoint = try await manager.start(
            ServerLaunchConfiguration(label: "integration-a5", databasePath: directory, port: PortUtility.freePort())
        )
        let client = ChromaClient(endpoint: endpoint)

        let names = ["abc", "a.b", "a-b", "UPPER_case", "0abc", "256.1.1.1", "01.2.3.4", "192.168.0.1.5",
                     "ab", "-abc", "abc.", "a..b", "192.168.0.1", "1.2.3.4", "0.0.0.0", "с_кириллицей", "with space"]
        for name in names {
            let weAccept = CollectionNaming.isValid(name)
            var serverAccepts = false
            do {
                _ = try await client.createCollection(name: name)
                serverAccepts = true
            } catch ChromaError.api(let status, _, _) where status == 400 {
                serverAccepts = false
            }
            XCTAssertEqual(
                weAccept, serverAccepts,
                "«\(name)»: валидатор говорит \(weAccept), сервер — \(serverAccepts)"
            )
        }
    }

    // MARK: - A9/B8 against a real server

    /// every operator the builder offers, plus `where` and
    /// `where_document` together, against a real server and real data.
    @MainActor
    func testTheFilterBuilderProducesQueriesTheServerAnswers() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-a9-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }
        let endpoint = try await manager.start(
            ServerLaunchConfiguration(label: "integration-a9", databasePath: directory, port: PortUtility.freePort())
        )
        let client = ChromaClient(endpoint: endpoint)
        let collection = try await client.createCollection(
            name: "a9_filters",
            configuration: CollectionConfiguration(metric: .cosine)
        )
        try await client.upsert(collectionID: collection.id, records: [
            EmbeddedRecord(id: "d1", document: "Яблоко и груша в саду", embedding: [0.9, 0.1, 0, 0],
                           metadata: ["topic": .string("сад"), "n": .int(1), "ok": .bool(true)]),
            EmbeddedRecord(id: "d2", document: "Груша созрела рано", embedding: [0.8, 0.2, 0, 0],
                           metadata: ["topic": .string("сад"), "n": .int(5), "ok": .bool(false)]),
            EmbeddedRecord(id: "d3", document: "Квантовая хромодинамика", embedding: [0, 0, 0.9, 0.1],
                           metadata: ["topic": .string("физика"), "n": .int(10), "ok": .bool(true)]),
            EmbeddedRecord(id: "d4", document: "Текст без темы", embedding: [0, 0.1, 0, 0.9],
                           metadata: ["n": .int(3)]),
        ])

        func ids(_ filter: DocumentFilter) async throws -> [String] {
            try await client.getDocuments(collectionID: collection.id, limit: 100, filter: filter)
                .map(\.id).sorted()
        }
        func leaf(_ field: String, _ op: FilterOperator, _ value: String) -> FilterNode {
            .leaf(MetadataCondition(field: field, op: op, value: value))
        }

        let cases: [(String, DocumentFilter, [String])] = [
            ("$eq", DocumentFilter(root: .group(.and, [leaf("topic", .equals, "сад")])), ["d1", "d2"]),
            // `$ne` also matches documents that simply do not have the field —
            // worth knowing before writing a filter that «excludes» something.
            ("$ne", DocumentFilter(root: .group(.and, [leaf("topic", .notEquals, "сад")])), ["d3", "d4"]),
            ("$gt", DocumentFilter(root: .group(.and, [leaf("n", .greater, "3")])), ["d2", "d3"]),
            ("$lte", DocumentFilter(root: .group(.and, [leaf("n", .lessOrEqual, "3")])), ["d1", "d4"]),
            ("$in", DocumentFilter(root: .group(.and, [leaf("topic", .inList, "сад, физика")])), ["d1", "d2", "d3"]),
            ("$nin", DocumentFilter(root: .group(.and, [leaf("topic", .notInList, "сад")])), ["d3", "d4"]),
            ("bool", DocumentFilter(root: .group(.and, [leaf("ok", .equals, "true")])), ["d1", "d3"]),
            ("$and", DocumentFilter(root: .group(.and, [leaf("topic", .equals, "сад"), leaf("n", .greaterOrEqual, "5")])), ["d2"]),
            ("$or", DocumentFilter(root: .group(.or, [leaf("topic", .equals, "физика"), leaf("n", .less, "2")])), ["d1", "d3"]),
            ("вложенность", DocumentFilter(root: .group(.or, [
                .group(.and, [leaf("topic", .equals, "сад"), leaf("n", .equals, "1")]),
                leaf("topic", .equals, "физика"),
            ])), ["d1", "d3"]),
        ]
        for (label, filter, expected) in cases {
            let actual = try await ids(filter)
            XCTAssertEqual(actual, expected, "\(label): \(filter.whereJSONString() ?? "—")")
        }

        // where_document, including the operator the spec asks for by name.
        var contains = DocumentFilter()
        contains.textConditions = [DocumentTextCondition(op: .contains, text: "Груша")]
        let containsIDs = try await ids(contains)
        XCTAssertEqual(containsIDs, ["d2"])

        var notContains = DocumentFilter()
        notContains.textConditions = [DocumentTextCondition(op: .notContains, text: "Груша")]
        let notContainsIDs = try await ids(notContains)
        XCTAssertEqual(notContainsIDs, ["d1", "d3", "d4"])

        var bothText = DocumentFilter()
        bothText.textConditions = [
            DocumentTextCondition(op: .contains, text: "Груша"),
            DocumentTextCondition(op: .notContains, text: "созрела"),
        ]
        let bothTextIDs = try await ids(bothText)
        XCTAssertEqual(bothTextIDs, [])

        // The pair the whole feature exists for: metadata and text together.
        var combined = DocumentFilter(root: .group(.and, [leaf("topic", .equals, "сад")]))
        combined.textConditions = [DocumentTextCondition(op: .contains, text: "Груша")]
        let combinedIDs = try await ids(combined)
        XCTAssertEqual(combinedIDs, ["d2"])

        // And the same filter narrowing a semantic query.
        let hits = try await client.query(
            collectionID: collection.id,
            embedding: [0.85, 0.15, 0, 0],
            nResults: 10,
            filter: combined
        )
        XCTAssertEqual(hits.map(\.id), ["d2"])
    }

    /// `add` does not complain about a taken id — it answers 201 and keeps
    /// the old document. The app has to look before it writes.
    @MainActor
    func testAddSilentlyKeepsTheExistingDocument() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-b8-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }
        let endpoint = try await manager.start(
            ServerLaunchConfiguration(label: "integration-b8", databasePath: directory, port: PortUtility.freePort())
        )
        let client = ChromaClient(endpoint: endpoint)
        let collection = try await client.createCollection(name: "b8_conflicts")

        let original = EmbeddedRecord(id: "one", document: "исходный", embedding: [0.1, 0.2], metadata: [:])
        try await client.add(collectionID: collection.id, records: [original])

        // Same id, different text: no error, and the text does not change.
        try await client.add(collectionID: collection.id, records: [
            EmbeddedRecord(id: "one", document: "ПЕРЕЗАПИСАНО", embedding: [0.3, 0.4], metadata: [:]),
        ])
        let afterAdd = try await client.getDocuments(collectionID: collection.id, limit: 10, ids: ["one"])
        XCTAssertEqual(afterAdd.first?.document, "исходный", "add не сообщает о конфликте и ничего не меняет")

        // Which is why the app asks first.
        let taken = try await client.existingIDs(collectionID: collection.id, ids: ["one", "two"])
        XCTAssertEqual(taken, ["one"])

        // And an upsert is what actually replaces it.
        try await client.upsert(collectionID: collection.id, records: [
            EmbeddedRecord(id: "one", document: "ПЕРЕЗАПИСАНО", embedding: [0.3, 0.4], metadata: [:]),
        ])
        let afterUpsert = try await client.getDocuments(collectionID: collection.id, limit: 10, ids: ["one"])
        XCTAssertEqual(afterUpsert.first?.document, "ПЕРЕЗАПИСАНО")
        let total = try await client.count(collectionID: collection.id)
        XCTAssertEqual(total, 1, "перезапись не создаёт вторую строку")
    }

    // MARK: - B4/B6 against a real server

    /// the CLI has the command, it reclaims real space, and the database
    /// still opens with everything in it afterwards.
    @MainActor
    func testMaintenanceReclaimsSpaceAndLeavesTheDatabaseUsable() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-b4-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let maintenance = MaintenanceService()
        guard await maintenance.isAvailable() else {
            throw XCTSkip("установленная версия Chroma CLI не умеет vacuum")
        }

        let manager = makeManager()
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }
        let endpoint = try await manager.start(
            ServerLaunchConfiguration(label: "integration-b4", databasePath: directory, port: PortUtility.freePort())
        )
        let client = ChromaClient(endpoint: endpoint)
        let collection = try await client.createCollection(
            name: "b4_vacuum",
            configuration: CollectionConfiguration(metric: .cosine)
        )

        // Enough data for the file to grow measurably, then most of it deleted.
        let records = (0..<4000).map { index in
            EmbeddedRecord(
                id: "r\(index)",
                document: String(repeating: "текст ", count: 20),
                embedding: (0..<64).map { _ in 0.1 },
                metadata: ["n": .int(index)]
            )
        }
        try await client.upsert(collectionID: collection.id, records: records)
        try await client.deleteDocuments(collectionID: collection.id, ids: (0..<3800).map { "r\($0)" })
        let remaining = try await client.count(collectionID: collection.id)
        XCTAssertEqual(remaining, 200)

        // The server is stopped first — the app does the same.
        await manager.stop()
        let result = try await maintenance.vacuum(databaseAt: directory, timeout: 300)
        XCTAssertLessThan(result.bytesAfter, result.bytesBefore, "vacuum должен освободить место: \(result.summary)")

        // And the database is still a database.
        let restarted = try await manager.start(
            ServerLaunchConfiguration(label: "integration-b4b", databasePath: directory, port: PortUtility.freePort())
        )
        let after = ChromaClient(endpoint: restarted)
        let collections = try await after.listCollections(withCounts: false)
        XCTAssertEqual(collections.map(\.name), ["b4_vacuum"])
        let countAfter = try await after.count(collectionID: try await after.resolveID(of: "b4_vacuum"))
        XCTAssertEqual(countAfter, 200, "данные на месте")
    }

    /// databases can be listed and created; a missing one is recognised
    /// rather than showing up as an empty database.
    @MainActor
    func testDatabasesAreListedAndMissingOnesAreRecognised() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-b6-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }
        let endpoint = try await manager.start(
            ServerLaunchConfiguration(label: "integration-b6", databasePath: directory, port: PortUtility.freePort())
        )
        let client = ChromaClient(endpoint: endpoint)

        let initial = try await client.listDatabases()
        XCTAssertEqual(initial, [ChromaEndpoint.defaultDatabase])

        try await client.createDatabase(name: "second_db")
        let afterCreate = try await client.listDatabases()
        XCTAssertEqual(afterCreate, ["default_database", "second_db"])

        // The default pair verifies fine.
        try await client.verifyTenantAndDatabase()

        // A database that is not there: the collection listing would answer
        // «200 []», the verification does not.
        var missingEndpoint = endpoint
        missingEndpoint.database = "no_such_database"
        let missing = ChromaClient(endpoint: missingEndpoint)
        let collections = try await missing.listCollections(withCounts: false)
        XCTAssertTrue(collections.isEmpty, "сервер отвечает пустым списком, а не ошибкой")
        do {
            try await missing.verifyTenantAndDatabase()
            XCTFail("несуществующая база должна распознаваться")
        } catch ChromaError.databaseNotFound(let database, _) {
            XCTAssertEqual(database, "no_such_database")
        }

        var missingTenant = endpoint
        missingTenant.tenant = "no_such_tenant"
        do {
            try await ChromaClient(endpoint: missingTenant).verifyTenantAndDatabase()
            XCTFail("несуществующий тенант должен распознаваться")
        } catch ChromaError.tenantNotFound(let name) {
            XCTAssertEqual(name, "no_such_tenant")
        }

        // And a tenant the app creates itself becomes usable.
        try await client.createTenant(name: "probe_tenant")
        try await client.createDatabase(name: "probe_db", tenant: "probe_tenant")
        let inNewTenant = try await client.listDatabases(tenant: "probe_tenant")
        XCTAssertEqual(inNewTenant, ["probe_db"])
    }

    // MARK: - C3/C4 through the real proxy

    /// C3 and C4 end to end: a real listener, real HTTP, real headers.
    @MainActor
    func testTheProxyThrottlesAndAnswersPreflights() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-c3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }
        let upstream = try await manager.start(
            ServerLaunchConfiguration(label: "integration-c3", databasePath: directory.appendingPathComponent("db"), port: PortUtility.freePort())
        )
        let chroma = ChromaClient(endpoint: upstream)
        let collection = try await chroma.createCollection(name: "c3_col")

        let key = ClientKey.generate()
        let client = ExternalClient(
            name: "быстрый",
            keyHash: ClientKey.hash(key), keyPrefix: ClientKey.prefix(of: key),
            permissions: ClientPermissions(
                collections: ["c3_col"],
                requestsPerMinute: 60,
                burst: 3,
                allowedOrigins: ["https://app.example"]
            )
        )
        let audit = AuditLog(fileURL: directory.appendingPathComponent("audit.jsonl"))
        let access = AccessController()
        await access.setClients([client])
        await access.setCatalog([CollectionSnapshot(id: collection.id, name: collection.name, dimension: 4)])

        let proxy = ProxyServer(audit: audit, access: access)
        let proxyPort = PortUtility.freePort()
        try proxy.start(upstreamHost: upstream.host, upstreamPort: upstream.port, listenPort: proxyPort)
        defer { proxy.stop() }
        try await waitUntil { proxy.state.isRunning }

        let base = "http://127.0.0.1:\(proxyPort)"

        // Burst of three passes, the fourth is refused with Retry-After.
        var codes: [Int] = []
        var retryAfter: String?
        for _ in 0..<4 {
            let (code, headers) = try await statusWithHeaders(url: "\(base)/api/v2/heartbeat", key: key)
            codes.append(code)
            if code == 429 { retryAfter = headers["retry-after"] }
        }
        XCTAssertEqual(Array(codes.prefix(3)), [200, 200, 200], "всплеск в 3 запроса должен проходить")
        XCTAssertEqual(codes.last, 429, "четвёртый запрос подряд — 429")
        XCTAssertNotNil(retryAfter, "429 без Retry-After бесполезен клиенту")
        XCTAssertGreaterThan(Int(retryAfter ?? "0") ?? 0, 0)

        // A preflight is answered by the proxy itself, without a key.
        let (preflightCode, preflightHeaders) = try await statusWithHeaders(
            url: "\(base)/api/v2/heartbeat",
            key: nil,
            method: "OPTIONS",
            extraHeaders: ["Origin": "https://app.example", "Access-Control-Request-Method": "GET"]
        )
        XCTAssertEqual(preflightCode, 204)
        XCTAssertEqual(preflightHeaders["access-control-allow-origin"], "https://app.example")
        XCTAssertNotNil(preflightHeaders["access-control-allow-headers"])

        // An origin nobody allowed gets nothing.
        let (refusedCode, refusedHeaders) = try await statusWithHeaders(
            url: "\(base)/api/v2/heartbeat",
            key: nil,
            method: "OPTIONS",
            extraHeaders: ["Origin": "https://evil.example"]
        )
        XCTAssertEqual(refusedCode, 403)
        XCTAssertNil(refusedHeaders["access-control-allow-origin"])

        // And a request without an Origin header is a plain API call: no CORS
        // headers, no change in behaviour.
        let (plainCode, plainHeaders) = try await statusWithHeaders(url: "\(base)/api/v2/version", key: key)
        XCTAssertTrue(plainCode == 200 || plainCode == 429, "код \(plainCode)")
        XCTAssertNil(plainHeaders["access-control-allow-origin"])
    }

    /// Like `status`, but the headers are what the test is about.
    private func statusWithHeaders(
        url: String,
        key: String?,
        method: String = "GET",
        extraHeaders: [String: String] = [:],
        timeout: TimeInterval = 20
    ) async throws -> (code: Int, headers: [String: String]) {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let key { request.setValue(key, forHTTPHeaderField: "X-Chroma-Token") }
        for (name, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (name, value) in (http?.allHeaderFields ?? [:]) {
            headers["\(name)".lowercased()] = "\(value)"
        }
        return (http?.statusCode ?? -1, headers)
    }

    /// The native LM Studio endpoint is what makes the model list useful: it
    /// reports the type and the context length, and the OpenAI-compatible one
    /// reports neither.
    @MainActor
    func testTheModelListCarriesTypesAndContextLengths() async throws {
        let lmStudio = try LMStudioClient(baseURLString: "http://localhost:1234")
        guard let models = try? await lmStudio.models(), !models.isEmpty else {
            throw XCTSkip("LM Studio не запущена")
        }

        // Every model knows how much context it has…
        XCTAssertTrue(
            models.allSatisfy { ($0.contextLength ?? 0) > 0 },
            "без контекста: \(models.filter { $0.contextLength == nil }.map(\.id))"
        )
        // …and what it is, straight from the API rather than from a probe.
        XCTAssertTrue(
            models.allSatisfy { $0.kind != .unknown && !$0.kindIsInferred },
            "тип не определён у: \(models.filter { $0.kind == .unknown }.map(\.id))"
        )
        // A list with both kinds in it is the case the old path got wrong:
        // it answered «эмбеддинги» for chat models too.
        if models.contains(where: { $0.kind == .chat }) {
            XCTAssertTrue(models.contains { $0.kind == .embedding }
                          || models.allSatisfy { $0.kind == .chat })
        }
        XCTAssertTrue(models.allSatisfy { $0.rawType != nil })
    }

    /// §D3 на **настоящем** сервере: коллекция с внесёнными дефектами
    /// проверяется тем же клиентом, что и в приложении.
    ///
    /// Фейк здесь недостаточен: паги­нация, `include` и расстояния в `query` —
    /// это поведение сервера, и именно на нём проверка может разойтись
    /// с ожиданиями.
    @MainActor
    func testInspectorFindsRealDefectsInARealCollection() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        let endpoint = try await manager.start(
            ServerLaunchConfiguration(
                label: "inspector", databasePath: directory,
                host: "127.0.0.1", port: PortUtility.freePort(), allowReset: true
            )
        )
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }

        let client = ChromaClient(endpoint: endpoint)
        _ = try await client.connect()
        let sourceID = UUID().uuidString
        let collection = try await client.createCollection(
            name: "inspector_demo",
            metadata: [
                CollectionBindingKeys.model: .string("test-model"),
                CollectionBindingKeys.dimension: .int(4),
            ],
            configuration: CollectionConfiguration(metric: .cosine),
            getOrCreate: true
        )

        func record(_ id: String, _ text: String, _ vector: [Double], _ metadata: ChromaMetadata) -> EmbeddedRecord {
            EmbeddedRecord(id: id, document: text, embedding: vector, metadata: metadata)
        }
        let good: ChromaMetadata = ["source_id": .string(sourceID), "source_file": .string("книга.md")]
        try await client.upsert(collectionID: collection.id, records: [
            // Нормальный документ и его почти-двойник: векторы рядом.
            record("ok0", "Первый абзац книги, вполне содержательный и длинный.", [1, 0, 0, 0],
                   good.merging(["chunk_index": .int(0)]) { _, new in new }),
            record("near", "Первый абзац книги, вполне содержательный и длинный!", [0.999, 0.02, 0, 0],
                   good.merging(["chunk_index": .int(1)]) { _, new in new }),
            // Дыра: нет чанка 3.
            record("ok4", "Пятый абзац книги, тоже достаточно длинный для проверки.", [0, 1, 0, 0],
                   good.merging(["chunk_index": .int(4)]) { _, new in new }),
            // Слишком короткий.
            record("short", "ага", [0, 0, 1, 0], good.merging(["chunk_index": .int(2)]) { _, new in new }),
            // Без метаданных вовсе.
            record("bare", "Документ без единого поля метаданных, но с текстом.", [0, 0, 0, 1], [:]),
            // Сирота: источник записан, но такого источника нет.
            record("orphan", "Чанк от источника, которого больше нет в приложении.", [0.5, 0.5, 0, 0],
                   ["source_id": .string(UUID().uuidString), "source_file": .string("ушёл.md"), "chunk_index": .int(0)]),
            // Дубль по тексту.
            record("dup1", "Один и тот же текст в двух разных документах.", [0.2, 0.9, 0, 0], good),
            record("dup2", "Один и тот же текст в двух разных документах.", [0.9, 0.2, 0, 0], good),
        ])

        let report = try await CollectionInspector(reader: client).inspect(
            context: CollectionInspector.Context(
                collection: collection, knownSourceIDs: [sourceID]
            ),
            options: InspectionOptions(checksNearDuplicates: true)
        )

        XCTAssertEqual(report.examined, 8)
        XCTAssertEqual(report.findings(in: .emptyDocuments).flatMap(\.documentIDs), ["short"])
        XCTAssertEqual(report.findings(in: .withoutMetadata).flatMap(\.documentIDs), ["bare"])
        XCTAssertEqual(report.findings(in: .orphanChunks).flatMap(\.documentIDs), ["orphan"])
        XCTAssertEqual(report.findings(in: .outsideSources).flatMap(\.documentIDs), ["bare"])
        XCTAssertEqual(
            Set(report.findings(in: .duplicates).flatMap(\.documentIDs)), ["dup1", "dup2"]
        )
        let gap = try XCTUnwrap(report.findings(in: .chunkGaps).first { $0.subject == "книга.md" })
        XCTAssertTrue(gap.detail?.contains("3") ?? false, gap.detail ?? "")
        XCTAssertTrue(
            report.findings(in: .nearDuplicates).contains { $0.subject == CollectionInspector.pairKey("ok0", "near") },
            "почти одинаковые документы обязаны найтись по векторам из базы"
        )
        XCTAssertTrue(report.nearDuplicatesChecked)
        // Инспектор ничего не изменил: сколько было, столько и осталось.
        let after = try await client.count(collectionID: collection.id)
        XCTAssertEqual(after, 8)
    }

    /// §K1 на настоящем сервере: обзор считает состав коллекции.
    @MainActor
    func testOverviewCountsWhatIsActuallyInTheCollection() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = makeManager()
        let endpoint = try await manager.start(
            ServerLaunchConfiguration(
                label: "facets", databasePath: directory,
                host: "127.0.0.1", port: PortUtility.freePort(), allowReset: true
            )
        )
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }

        let client = ChromaClient(endpoint: endpoint)
        _ = try await client.connect()
        let collection = try await client.createCollection(
            name: "facets_demo", metadata: nil,
            configuration: CollectionConfiguration(metric: .cosine), getOrCreate: true
        )
        try await client.upsert(collectionID: collection.id, records: (0..<10).map { index in
            EmbeddedRecord(
                id: "d\(index)",
                document: String(repeating: "а", count: index < 5 ? 50 : 1500),
                embedding: [Double(index), 1, 0, 0],
                metadata: [
                    "file_ext": .string(index < 7 ? "md" : "pdf"),
                    "file_mtime": .string(index < 3 ? "2026-07-15T10:00:00Z" : "2026-08-01T10:00:00Z"),
                ]
            )
        })

        let overview = try await CollectionFacetBuilder(reader: client).overview(collection: collection)
        XCTAssertEqual(overview.examined, 10)
        XCTAssertFalse(overview.isSample)
        let extensions = try XCTUnwrap(overview.facets.first { $0.field == "file_ext" })
        XCTAssertEqual(extensions.values.map(\.text), ["md", "pdf"])
        XCTAssertEqual(extensions.values.map(\.count), [7, 3])
        let months = try XCTUnwrap(overview.facets.first { $0.field == "file_mtime" })
        XCTAssertEqual(Set(months.values.map(\.text)), ["2026-07", "2026-08"])
        let histogram = try XCTUnwrap(overview.lengths)
        XCTAssertEqual(histogram.buckets.reduce(0) { $0 + $1.count }, 10)
        XCTAssertEqual(histogram.median, 1500)
    }

    /// §D4: коллекция уезжает на **другой** сервер и приезжает там той же.
    ///
    /// Два настоящих сервера, а не два подключения к одному: смысл этапа —
    /// перенос между машинами, и подменять его копированием внутри одной базы
    /// значило бы не проверить ровно то, ради чего он сделан.
    @MainActor
    func testCollectionTravelsToAnotherServerUnchanged() async throws {
        let sourceDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-\(UUID().uuidString)")
        let targetDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-\(UUID().uuidString)")
        let box = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: targetDirectory)
            try? FileManager.default.removeItem(at: box)
        }

        let first = makeManager()
        let firstEndpoint = try await first.start(ServerLaunchConfiguration(
            label: "export-source", databasePath: sourceDirectory,
            host: "127.0.0.1", port: PortUtility.freePort(), allowReset: true
        ))
        defer { if let pid = first.state.pid { kill(pid, SIGTERM) } }

        let second = makeManager()
        let secondEndpoint = try await second.start(ServerLaunchConfiguration(
            label: "import-target", databasePath: targetDirectory,
            host: "127.0.0.1", port: PortUtility.freePort(), allowReset: true
        ))
        defer { if let pid = second.state.pid { kill(pid, SIGTERM) } }

        let origin = ChromaClient(endpoint: firstEndpoint)
        let destination = ChromaClient(endpoint: secondEndpoint)
        let originInfo = try await origin.connect()
        _ = try await destination.connect()

        let source = try await origin.createCollection(
            name: "travelling",
            metadata: [
                CollectionBindingKeys.model: .string("test-model"),
                CollectionBindingKeys.dimension: .int(4),
            ],
            configuration: CollectionConfiguration(metric: .cosine),
            getOrCreate: true
        )
        let originals = (0..<250).map { index in
            EmbeddedRecord(
                id: "doc\(index)",
                document: "Документ номер \(index) с текстом, который обязан доехать целым.",
                embedding: [Double(index) / 100, 0.5, -0.25, 0.125],
                metadata: ["группа": .string(index % 2 == 0 ? "чёт" : "нечет"), "номер": .int(index)]
            )
        }
        try await origin.upsert(collectionID: source.id, records: originals)

        // Экспорт.
        let package = box.appendingPathComponent("travelling.chromaexport")
        let exported = try await CollectionExporter(source: origin).export(
            collection: source,
            to: package,
            serverVersion: originInfo.version,
            tenant: firstEndpoint.tenant, database: firstEndpoint.database,
            options: .init(pageSize: 100)
        )
        XCTAssertEqual(exported.manifest.documentCount, 250)

        // Импорт на другой сервер.
        let manifest = try CollectionImporter.readManifest(at: package)
        try CollectionImporter.verifyChecksum(at: package, manifest: manifest)
        let target = try await destination.createCollection(
            name: manifest.collectionName,
            metadata: manifest.collectionMetadata,
            configuration: CollectionConfiguration(metric: DistanceMetric(rawValue: manifest.metric ?? "cosine") ?? .cosine),
            getOrCreate: true
        )
        let warnings = try CollectionImporter.problems(manifest: manifest, target: target)
        XCTAssertTrue(warnings.isEmpty, warnings.joined(separator: "; "))

        let report = try await CollectionImporter(
            destination: destination,
            checkpoints: ImportCheckpointStore(directory: box.appendingPathComponent("cp"))
        ).import(
            package: package, manifest: manifest,
            into: target.id, collectionName: target.name,
            options: .init(batchSize: 100)
        )
        XCTAssertEqual(report.written, 250)
        XCTAssertTrue(report.finished)

        // Сверка: тексты, метаданные и векторы.
        let importedCount = try await destination.count(collectionID: target.id)
        XCTAssertEqual(importedCount, 250)
        let ids = originals.map(\.id)
        let restored = try await destination.getDocuments(collectionID: target.id, limit: 250, ids: ids)
        let restoredVectors = try await destination.embeddings(collectionID: target.id, ids: ids)
        XCTAssertEqual(restored.count, 250)
        for original in originals {
            let copy = try XCTUnwrap(restored.first { $0.id == original.id })
            XCTAssertEqual(copy.document, original.document)
            XCTAssertEqual(copy.metadata?["номер"], original.metadata["номер"])
            let vector = try XCTUnwrap(restoredVectors[original.id])
            XCTAssertEqual(vector.count, original.embedding.count)
            for (left, right) in zip(vector, original.embedding) {
                // Допуск — точность float32, в которой ChromaDB хранит векторы.
                XCTAssertEqual(left, right, accuracy: 1e-6)
            }
        }
    }

    /// Small HTTP helper: the point is to speak to the proxy exactly as any
    /// client would, without a ChromaDB library in the way.
    private func status(
        url: String,
        key: String?,
        method: String = "GET",
        body: String? = nil,
        timeout: TimeInterval = 20
    ) async throws -> (code: Int, text: String) {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let key { request.setValue(key, forHTTPHeaderField: "X-Chroma-Token") }
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (code, String(data: data, encoding: .utf8) ?? "")
    }
}
