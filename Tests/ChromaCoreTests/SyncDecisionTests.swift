import XCTest
@testable import ChromaCore

/// The table of, which the spec itself calls the easiest part of stage 4
/// to get quietly wrong.
final class SyncDecisionTests: XCTestCase {
    private let pdfkit1 = ExtractorStamp(id: "pdfkit", version: 1)
    private let pdfkit2 = ExtractorStamp(id: "pdfkit", version: 2)

    private func entry(
        contentHash: String = "text-a",
        fileHash: String = "bytes-a",
        extractor: ExtractorStamp? = nil,
        size: Int64 = 100,
        modifiedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> ManifestEntry {
        ManifestEntry(
            relativePath: "book.pdf",
            contentHash: contentHash,
            fileHash: fileHash,
            modifiedAt: modifiedAt,
            size: size,
            chunkIDs: ["id-0"],
            collectionName: "docs",
            chunkingSignature: "sig",
            embeddingModel: "model",
            extractorID: extractor?.id ?? "pdfkit",
            extractorVersion: extractor?.version ?? 1
        )
    }

    // MARK: - Row 1 and 2: the bytes moved

    func testBytesAndTextChangedMeansReindex() {
        let decision = SyncDecisionRules.decideRead(
            entry: entry(), contentHash: "text-b", recipeMismatch: nil
        )
        XCTAssertEqual(decision, .reindex(reason: "содержимое файла изменилось"))
    }

    /// The row that saves hours on large folders: a re-saved file whose text is
    /// identical must not cost a single embedding call.
    func testBytesChangedButTextIdenticalDoesNotRecomputeVectors() {
        let decision = SyncDecisionRules.decideRead(
            entry: entry(), contentHash: "text-a", recipeMismatch: nil
        )
        XCTAssertEqual(decision, .touch)
    }

    /// The same rule one step earlier: if the bytes hash to what they hashed to
    /// last time, the file is not even opened.
    func testIdenticalBytesUnderANewTimestampAreNotEvenRead() {
        let decision = SyncDecisionRules.decideUnread(
            entry: entry(), sizeMatches: true, timeMatches: false,
            fileHash: "bytes-a", recipeMismatch: nil, current: pdfkit1
        )
        XCTAssertEqual(decision, .touch)
    }

    func testDifferentBytesSendTheFileToBeRead() {
        let decision = SyncDecisionRules.decideUnread(
            entry: entry(), sizeMatches: true, timeMatches: false,
            fileHash: "bytes-b", recipeMismatch: nil, current: pdfkit1
        )
        XCTAssertNil(decision, "решение по неоткрытому файлу здесь невозможно")
    }

    // MARK: - Row 3: the extractor moved

    func testANewerExtractorMarksTheFileAndDoesNotQueueIt() {
        let decision = SyncDecisionRules.decideUnread(
            entry: entry(extractor: pdfkit1), sizeMatches: true, timeMatches: true,
            fileHash: nil, recipeMismatch: nil, current: pdfkit2
        )
        XCTAssertEqual(decision, .needsReextraction(previous: pdfkit1))
    }

    /// A manifest written before extractor stamps existed says nothing about
    /// which version produced its text. Unknown is not stale: guessing would
    /// either nag about files that are fine or stay silent about files that
    /// are not.
    func testAnUnknownExtractorIsNotReportedAsStale() {
        XCTAssertFalse(SyncDecisionRules.isStale(stored: ExtractorStamp(id: "", version: 0), current: pdfkit2))
        let decision = SyncDecisionRules.decideUnread(
            entry: entry(extractor: ExtractorStamp(id: "", version: 0)),
            sizeMatches: true, timeMatches: true,
            fileHash: nil, recipeMismatch: nil, current: pdfkit2
        )
        XCTAssertEqual(decision, .skip)
    }

    /// A file that went through a fallback extractor keeps working. Claiming it
    /// is stale because a *different* extractor claims the type today would
    /// flag it on every sync forever.
    func testADifferentExtractorIsNotStaleness() {
        XCTAssertFalse(SyncDecisionRules.isStale(
            stored: ExtractorStamp(id: "vision-ocr", version: 1), current: pdfkit2
        ))
    }

    /// Downgrading the app offers to re-extract with *older* code. Nobody asked
    /// for that.
    func testAnOlderExtractorThanTheStoredOneIsNotStaleness() {
        XCTAssertFalse(SyncDecisionRules.isStale(stored: pdfkit2, current: pdfkit1))
    }

    /// The file changed **and** the extractor changed: re-indexing uses the
    /// current extractor anyway, so there is nothing to mark and nothing to ask.
    func testAChangedFileIsNotAlsoReportedAsNeedingReextraction() {
        let decision = SyncDecisionRules.decideUnread(
            entry: entry(extractor: pdfkit1), sizeMatches: false, timeMatches: false,
            fileHash: "bytes-b", recipeMismatch: nil, current: pdfkit2
        )
        XCTAssertNil(decision)
        XCTAssertEqual(
            SyncDecisionRules.decideRead(entry: entry(), contentHash: "text-b", recipeMismatch: nil),
            .reindex(reason: "содержимое файла изменилось")
        )
    }

    // MARK: - Row 4 and the recipe

    func testNothingChangedMeansSkip() {
        let decision = SyncDecisionRules.decideUnread(
            entry: entry(extractor: pdfkit1), sizeMatches: true, timeMatches: true,
            fileHash: nil, recipeMismatch: nil, current: pdfkit1
        )
        XCTAssertEqual(decision, .skip)
    }

    func testAChangedRecipeAlwaysSendsTheFileToBeRead() {
        let decision = SyncDecisionRules.decideUnread(
            entry: entry(), sizeMatches: true, timeMatches: true,
            fileHash: nil, recipeMismatch: "изменились параметры чанкинга", current: pdfkit1
        )
        XCTAssertNil(decision)
        XCTAssertEqual(
            SyncDecisionRules.decideRead(
                entry: entry(), contentHash: "text-a",
                recipeMismatch: "изменились параметры чанкинга"
            ),
            .reindex(reason: "изменились параметры чанкинга")
        )
    }

    func testAFileWithNoManifestEntryIsNew() {
        XCTAssertNil(SyncDecisionRules.decideUnread(
            entry: nil, sizeMatches: false, timeMatches: false,
            fileHash: nil, recipeMismatch: nil, current: pdfkit1
        ))
        XCTAssertEqual(
            SyncDecisionRules.decideRead(entry: nil, contentHash: "text-a", recipeMismatch: nil),
            .new
        )
    }

    /// An entry from before file hashes were recorded fills the field in without
    /// re-embedding anything.
    func testAnEntryWithoutAFileHashIsRefreshedNotReindexed() {
        let decision = SyncDecisionRules.decideUnread(
            entry: entry(fileHash: ""), sizeMatches: true, timeMatches: true,
            fileHash: "bytes-a", recipeMismatch: nil, current: pdfkit1
        )
        XCTAssertEqual(decision, .touch)
    }
}

// MARK: - What a refresh records

final class ManifestRefreshTests: XCTestCase {
    private func entry() -> ManifestEntry {
        ManifestEntry(
            relativePath: "book.pdf", contentHash: "text-a", fileHash: "",
            modifiedAt: Date(timeIntervalSince1970: 1_000), size: 100,
            chunkIDs: ["id-0"], collectionName: "docs",
            chunkingSignature: "sig", embeddingModel: "model"
        )
    }

    func testARefreshKeepsTheChunksAndTheirIdentity() {
        let updated = entry().applying(ManifestRefresh(
            fileHash: "bytes-b", modifiedAt: Date(timeIntervalSince1970: 2_000), size: 120
        ))
        XCTAssertEqual(updated.fileHash, "bytes-b")
        XCTAssertEqual(updated.size, 120)
        XCTAssertEqual(updated.chunkIDs, ["id-0"], "векторы не трогали — идентификаторы чанков те же")
        XCTAssertEqual(updated.contentHash, "text-a")
    }

    /// A file that was not opened cannot be stamped with the extractor that did
    /// not run on it.
    func testARefreshWithoutAnExtractorLeavesTheStampAlone() {
        let updated = entry().applying(ManifestRefresh(
            fileHash: "bytes-b", modifiedAt: Date(), size: 100
        ))
        XCTAssertTrue(updated.extractorStamp.isUnknown)
    }

    func testARefreshAfterReadingRecordsTheExtractorThatDidRead() {
        let updated = entry().applying(ManifestRefresh(
            fileHash: "bytes-b", contentHash: "text-a",
            extractor: ExtractorStamp(id: "pdfkit", version: 2),
            modifiedAt: Date(), size: 100
        ))
        XCTAssertEqual(updated.extractorID, "pdfkit")
        XCTAssertEqual(updated.extractorVersion, 2)
    }
}

// MARK: - Old files on disk keep working

final class ManifestCompatibilityTests: XCTestCase {
    /// A manifest written by an earlier build has none of the stage-4 fields.
    /// It must load — and must not claim its files were extracted by version 0
    /// of something.
    func testAManifestFromBeforeStageFourLoads() throws {
        let json = """
        {
          "sourceID": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
          "version": 1,
          "entries": {
            "book.pdf": {
              "relativePath": "book.pdf",
              "contentHash": "text-a",
              "modifiedAt": "2026-01-01T00:00:00Z",
              "size": 100,
              "chunkIDs": ["id-0"],
              "collectionName": "docs",
              "chunkingSignature": "sig",
              "embeddingModel": "model"
            }
          },
          "pendingRemovals": []
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(SourceManifest.self, from: Data(json.utf8))
        let entry = try XCTUnwrap(manifest.entries["book.pdf"])

        XCTAssertEqual(entry.contentHash, "text-a")
        XCTAssertTrue(entry.fileHash.isEmpty)
        XCTAssertTrue(entry.extractorStamp.isUnknown)
    }

    /// The journal is the recovery record of a run in flight. A line written by
    /// the build that was replaced mid-sync has to survive the update, or the
    /// interrupted file is never finished.
    func testAJournalLineFromBeforeStageFourStillDecodes() throws {
        let json = """
        {
          "relativePath": "book.pdf",
          "collectionName": "docs",
          "oldIDs": [],
          "newIDs": ["id-0"],
          "state": "upserted",
          "contentHash": "text-a",
          "modifiedAt": "2026-01-01T00:00:00Z",
          "size": 100,
          "chunkingSignature": "sig",
          "embeddingModel": "model",
          "startedAt": "2026-01-01T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(SyncJournalEntry.self, from: Data(json.utf8))

        XCTAssertEqual(entry.state, .upserted)
        XCTAssertEqual(entry.newIDs, ["id-0"])
        XCTAssertTrue(entry.manifestEntry().extractorStamp.isUnknown)
    }
}

// MARK: - Turning the mark into work

final class ReextractionPlanTests: XCTestCase {
    private func plan(stale: [String]) -> SyncPlan {
        let items = ["a.pdf", "b.pdf", "c.md"].map { path in
            SyncPlanItem(
                relativePath: path, url: URL(fileURLWithPath: "/tmp/\(path)"),
                kind: .unchanged, collectionName: "docs", size: 10, modifiedAt: Date()
            )
        }
        return SyncPlan(
            sourceID: UUID(), sourceName: "src", items: items,
            newlyMissing: [], pendingRemovals: [],
            staleExtraction: stale.map {
                StaleExtraction(
                    relativePath: $0, collectionName: "docs",
                    previous: ExtractorStamp(id: "pdfkit", version: 1),
                    current: ExtractorStamp(id: "pdfkit", version: 2)
                )
            }
        )
    }

    func testOnlyTheNamedFilesBecomeWork() {
        let forced = SourceSyncService.forcing(["a.pdf", "b.pdf"], in: plan(stale: ["a.pdf", "b.pdf"]))
        XCTAssertEqual(forced.writeItems.map(\.relativePath), ["a.pdf", "b.pdf"])
        XCTAssertEqual(forced.unchangedCount, 1)
    }

    /// Re-extracting part of the list must not make the rest disappear from the
    /// report — the files nobody has dealt with are still there.
    func testFilesLeftOutStayOnTheList() {
        let forced = SourceSyncService.forcing(["a.pdf"], in: plan(stale: ["a.pdf", "b.pdf"]))
        XCTAssertEqual(forced.staleExtraction.map(\.relativePath), ["b.pdf"])
    }

    func testAnEmptyRequestChangesNothing() {
        let original = plan(stale: ["a.pdf"])
        let forced = SourceSyncService.forcing([], in: original)
        XCTAssertTrue(forced.writeItems.isEmpty)
        XCTAssertEqual(forced.staleExtraction.count, 1)
    }
}

// MARK: - The rule end to end asks for this one by name)

final class ExtractionCurrencyEndToEndTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var manifests: ManifestStore!
    private var journal: SyncJournal!
    private var source: DataSource!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cdbm-118-\(UUID().uuidString)")
        folder = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        manifests = ManifestStore(directory: root.appendingPathComponent("manifests"))
        journal = SyncJournal(directory: root.appendingPathComponent("journals"))
        source = DataSource(
            name: "тест",
            path: folder.path,
            fileExtensions: ["md"],
            mapping: .folderToCollection,
            collectionName: "notes",
            chunking: ChunkingConfiguration(strategy: .fixed, chunkSize: 40, sizeUnit: .characters, overlapPercent: 0)
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to name: String = "note.md") throws {
        try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func sync(_ service: SourceSyncService, _ database: FailingDatabase, _ embeddings: CountingEmbeddings) async throws -> SyncSummary {
        try await service.sync(
            source: source, embeddingModel: "test-model", chroma: database,
            embeddings: embeddings, binding: ModelBindingService(), progress: { _ in }
        )
    }

    /// «`file_hash` изменился, `content_hash` нет → пересчёта векторов нет».
    func testAReSavedFileWithTheSameTextCostsNoEmbeddingCalls() async throws {
        let text = String(repeating: "текст, который не менялся. ", count: 20)
        try write(text)
        let database = FailingDatabase()
        let service = SourceSyncService(manifests: manifests, journal: journal)

        let first = try await sync(service, database, CountingEmbeddings())
        XCTAssertEqual(first.added, 1)
        let stored = try XCTUnwrap(manifests.load(sourceID: source.id).entries["note.md"])
        XCTAssertFalse(stored.fileHash.isEmpty, "хэш байтов должен быть записан")
        XCTAssertEqual(stored.extractorID, "plaintext")

        // Re-saved: new timestamp, new bytes on disk, identical text. A plain
        // text file re-written with a trailing newline is exactly the case.
        try write(text + "\n")

        let embeddings = CountingEmbeddings()
        let second = try await sync(service, database, embeddings)

        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(second.updated, 0, "текст тот же — переиндексации быть не должно")
        let calls = await embeddings.calls
        XCTAssertEqual(calls, 0, "ни одного обращения к модели")

        // And the manifest learned the new bytes, so the next run does not even
        // open the file.
        let after = try XCTUnwrap(manifests.load(sourceID: source.id).entries["note.md"])
        XCTAssertNotEqual(after.fileHash, stored.fileHash)
        XCTAssertEqual(after.chunkIDs, stored.chunkIDs)
    }

    /// A file that really did change is still re-indexed — the optimisation must
    /// not swallow a genuine edit.
    func testAnEditedFileIsStillReindexed() async throws {
        try write(String(repeating: "первая версия. ", count: 20))
        let database = FailingDatabase()
        let service = SourceSyncService(manifests: manifests, journal: journal)
        try await sync(service, database, CountingEmbeddings())

        try write(String(repeating: "вторая версия совсем другая. ", count: 20))
        let embeddings = CountingEmbeddings()
        let summary = try await sync(service, database, embeddings)

        XCTAssertEqual(summary.updated, 1)
        let calls = await embeddings.calls
        XCTAssertGreaterThan(calls, 0)
    }

    /// An extractor that moved on marks the file and stops there. The spec is
    /// explicit: an app update must not start the recount by itself.
    func testAStaleExtractorIsReportedButNotIndexed() async throws {
        try write(String(repeating: "текст. ", count: 20))
        let database = FailingDatabase()
        let service = SourceSyncService(manifests: manifests, journal: journal)
        try await sync(service, database, CountingEmbeddings())

        // Pretend the file was indexed by an older version of the same extractor.
        var manifest = manifests.load(sourceID: source.id)
        var entry = try XCTUnwrap(manifest.entries["note.md"])
        entry.extractorVersion = entry.extractorVersion - 1
        manifest.entries["note.md"] = entry
        manifests.save(manifest)

        let embeddings = CountingEmbeddings()
        let summary = try await sync(service, database, embeddings)

        XCTAssertEqual(summary.staleExtraction.map(\.relativePath), ["note.md"])
        XCTAssertEqual(summary.updated, 0, "пометка — не работа")
        let calls = await embeddings.calls
        XCTAssertEqual(calls, 0)
        XCTAssertNotNil(summary.staleExtractionLine)
    }

    /// And the operation the user starts by hand does exactly the work the mark
    /// described — no more.
    func testTheManualReextractionIndexesTheMarkedFile() async throws {
        try write(String(repeating: "текст. ", count: 20))
        try write(String(repeating: "другой. ", count: 20), to: "other.md")
        let database = FailingDatabase()
        let service = SourceSyncService(manifests: manifests, journal: journal)
        try await sync(service, database, CountingEmbeddings())

        var manifest = manifests.load(sourceID: source.id)
        var entry = try XCTUnwrap(manifest.entries["note.md"])
        entry.extractorVersion = entry.extractorVersion - 1
        manifest.entries["note.md"] = entry
        manifests.save(manifest)

        let embeddings = CountingEmbeddings()
        let summary = try await service.sync(
            source: source, embeddingModel: "test-model", chroma: database,
            embeddings: embeddings, binding: ModelBindingService(),
            reextraction: SourceSyncService.ReextractionRequest(
                paths: ["note.md"],
                backup: BackupEvidence(record: nil, exportURL: nil, describedAs: "тестовый бэкап")
            ),
            progress: { _ in }
        )

        XCTAssertEqual(summary.updated, 1)
        XCTAssertTrue(summary.staleExtraction.isEmpty, "файл переизвлечён — на списке ему делать нечего")
        let after = try XCTUnwrap(manifests.load(sourceID: source.id).entries["note.md"])
        XCTAssertEqual(after.extractorVersion, PlainTextExtractor().version)
    }
}

// MARK: - Extraction options are part of the per-file recipe

final class ExtractionOptionSignatureTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var manifests: ManifestStore!
    private var journal: SyncJournal!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cdbm-opt-\(UUID().uuidString)")
        folder = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        manifests = ManifestStore(directory: root.appendingPathComponent("manifests"))
        journal = SyncJournal(directory: root.appendingPathComponent("journals"))
        try "# Заметка\n\nТекст, который не меняется.".write(
            to: folder.appendingPathComponent("note.md"), atomically: true, encoding: .utf8
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func source(includeDocumentMetadata: Bool) -> DataSource {
        DataSource(
            id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
            name: "тест", path: folder.path, fileExtensions: ["md"],
            mapping: .folderToCollection, collectionName: "notes",
            chunking: ChunkingConfiguration(strategy: .fixed, chunkSize: 200, sizeUnit: .characters, overlapPercent: 0),
            includeDocumentMetadata: includeDocumentMetadata
        )
    }

    /// Turning the setting on has to actually do something. Without this the
    /// checkbox would change the configuration and nothing else, and the user
    /// would be told the files are «без изменений» — rule 2 of Приложение 5.
    func testTurningDocumentMetadataOnReindexesTheSource() async throws {
        let service = SourceSyncService(manifests: manifests, journal: journal)
        let database = FailingDatabase()
        _ = try await service.sync(
            source: source(includeDocumentMetadata: false), embeddingModel: "test-model",
            chroma: database, embeddings: CountingEmbeddings(), binding: ModelBindingService(), progress: { _ in }
        )
        let stored = try XCTUnwrap(manifests.load(sourceID: source(includeDocumentMetadata: false).id).entries["note.md"])
        // Not the literal signature: it grows with every extraction option, and
        // a test that pins the exact string breaks for a reason that is not a
        // defect. What matters is that the setting is *in* there.
        XCTAssertTrue(stored.extractionSignature.contains("meta:0"), stored.extractionSignature)

        let summary = try await service.sync(
            source: source(includeDocumentMetadata: true), embeddingModel: "test-model",
            chroma: database, embeddings: CountingEmbeddings(), binding: ModelBindingService(), progress: { _ in }
        )
        XCTAssertEqual(summary.updated, 1, "включение метаданных документа должно переиндексировать файл")
        let after = try XCTUnwrap(manifests.load(sourceID: source(includeDocumentMetadata: true).id).entries["note.md"])
        XCTAssertTrue(after.extractionSignature.contains("meta:1"), after.extractionSignature)
        XCTAssertNotEqual(after.extractionSignature, stored.extractionSignature)
    }

    /// And leaving it alone must not.
    func testAnUnchangedSettingChangesNothing() async throws {
        let service = SourceSyncService(manifests: manifests, journal: journal)
        let database = FailingDatabase()
        _ = try await service.sync(
            source: source(includeDocumentMetadata: true), embeddingModel: "test-model",
            chroma: database, embeddings: CountingEmbeddings(), binding: ModelBindingService(), progress: { _ in }
        )
        let embeddings = CountingEmbeddings()
        let summary = try await service.sync(
            source: source(includeDocumentMetadata: true), embeddingModel: "test-model",
            chroma: database, embeddings: embeddings, binding: ModelBindingService(), progress: { _ in }
        )
        XCTAssertEqual(summary.updated, 0)
        let calls = await embeddings.calls
        XCTAssertEqual(calls, 0)
    }

    /// An entry written before extraction options existed knows nothing about
    /// them, and «unknown» must not become «changed» on the first launch after
    /// an update.
    func testAnOldEntryWithoutASignatureIsNotReindexed() async throws {
        let service = SourceSyncService(manifests: manifests, journal: journal)
        let database = FailingDatabase()
        _ = try await service.sync(
            source: source(includeDocumentMetadata: false), embeddingModel: "test-model",
            chroma: database, embeddings: CountingEmbeddings(), binding: ModelBindingService(), progress: { _ in }
        )
        var manifest = manifests.load(sourceID: source(includeDocumentMetadata: false).id)
        var entry = try XCTUnwrap(manifest.entries["note.md"])
        entry.extractionSignature = ""
        manifest.entries["note.md"] = entry
        manifests.save(manifest)

        let summary = try await service.sync(
            source: source(includeDocumentMetadata: true), embeddingModel: "test-model",
            chroma: database, embeddings: CountingEmbeddings(), binding: ModelBindingService(), progress: { _ in }
        )
        XCTAssertEqual(summary.updated, 0)
    }
}
