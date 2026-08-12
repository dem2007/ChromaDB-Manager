import XCTest
@testable import ChromaCore

/// A database that keeps everything in memory and dies exactly where the test
/// asks it to.
///
/// The failures A6 exists for — dying between the write and the cleanup — cannot
/// be provoked against a real server on demand, and a run that only ever
/// succeeds proves nothing about what happens when it does not.
actor FailingDatabase: SyncDatabase {
    enum Step: Hashable {
        case upsert
        case delete
    }

    /// Collection name → document id → document text.
    private var storage: [String: [String: String]] = [:]
    private var ids: [String: String] = [:]
    /// Fail on the n-th call of this step (1 = the very first).
    private var failAt: (step: Step, call: Int)?
    private var calls: [Step: Int] = [:]
    private(set) var upsertCalls = 0
    private(set) var deleteCalls = 0
    /// Set when the code under test asks to delete nothing — the live server
    /// answers 400 to that, so it is a defect, not a no-op.
    private(set) var askedToDeleteNothing = false
    private(set) var deletedByFilter = false

    struct Boom: Error, LocalizedError {
        var errorDescription: String? { "тестовый сбой базы" }
    }

    /// Counting starts now, not from the beginning of time: a test arms the
    /// failure after some successful work has already happened.
    func failNext(_ step: Step, call: Int = 1) {
        calls[step] = 0
        failAt = (step, call)
    }

    func stopFailing() { failAt = nil }

    func documents(in collection: String) -> [String: String] { storage[collection] ?? [:] }

    // MARK: - SyncDatabase

    /// Remembers what metric was asked for, the way a real server would.
    private(set) var metrics: [String: DistanceMetric] = [:]
    /// Same for metadata: `get_or_create` on an existing collection answers with
    /// what is stored, not with what the caller offered.
    private(set) var metadatas: [String: ChromaMetadata] = [:]

    func metadata(of collection: String) -> ChromaMetadata? { metadatas[collection] }

    func seedMetadata(_ metadata: ChromaMetadata, for collection: String) {
        ids[collection] = ids[collection] ?? UUID().uuidString
        storage[collection] = storage[collection] ?? [:]
        metadatas[collection] = metadata
    }

    func createCollection(
        name: String,
        metadata: ChromaMetadata?,
        configuration: CollectionConfiguration?,
        getOrCreate: Bool
    ) async throws -> ChromaCollection {
        let existed = ids[name] != nil
        let id = ids[name] ?? UUID().uuidString
        ids[name] = id
        storage[name] = storage[name] ?? [:]
        if let configuration, metrics[name] == nil { metrics[name] = configuration.metric }
        if !existed { metadatas[name] = metadata ?? [:] }
        return ChromaCollection(id: id, name: name, metadata: metadatas[name], space: metrics[name])
    }

    func updateCollection(id collectionID: String, newName: String?, metadata: ChromaMetadata?) async throws {
        guard let name = ids.first(where: { $0.value == collectionID })?.key else { return }
        if let metadata { metadatas[name] = metadata }
    }

    func resolveID(of name: String) async throws -> String {
        guard let id = ids[name] else { throw ChromaError.collectionNotFound(name) }
        return id
    }

    func upsert(collectionID: String, records: [EmbeddedRecord]) async throws {
        try checkFailure(.upsert)
        upsertCalls += 1
        guard let name = ids.first(where: { $0.value == collectionID })?.key else { return }
        for record in records { storage[name, default: [:]][record.id] = record.document }
    }

    /// The text pipeline never edits metadata on its own — only table sources do
    /// — so reaching this from a file sync would itself be the bug.
    func updateDocuments(collectionID: String, updates: [DocumentUpdate]) async throws {
        XCTFail("синхронизация файлов не должна править документы частично")
    }

    /// Переносом чанков при переименовании этот стенд не занимается.
    func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord] { [] }
    func embeddings(collectionID: String, ids: [String]) async throws -> [String: [Double]] { [:] }

    func deleteDocuments(collectionID: String, ids identifiers: [String]) async throws {
        if identifiers.isEmpty { askedToDeleteNothing = true }
        try checkFailure(.delete)
        deleteCalls += 1
        guard let name = ids.first(where: { $0.value == collectionID })?.key else { return }
        for identifier in identifiers { storage[name]?.removeValue(forKey: identifier) }
    }

    func deleteDocuments(collectionID: String, filter: DocumentFilter) async throws -> Int {
        deletedByFilter = true
        return 0
    }

    private func checkFailure(_ step: Step) throws {
        calls[step, default: 0] += 1
        guard let target = failAt, target.step == step, target.call == calls[step] else { return }
        throw Boom()
    }
}

/// Counts embedding calls: recovery that recomputes vectors it did not have to
/// is a defect of its own.
actor CountingEmbeddings: EmbeddingProvider {
    private(set) var calls = 0
    private(set) var texts = 0

    func embed(texts input: [String], model: String) async throws -> [[Double]] {
        calls += 1
        texts += input.count
        // Deterministic pseudo-vectors: this suite is about ordering, not maths.
        return input.map { text in
            let value = Double(text.count % 17) / 17
            return [value, 1 - value, 0.5, 0.25]
        }
    }
}

/// Addendum A6: the order of operations when a file is re-indexed, and what
/// happens when the run dies in the middle of it.
final class SyncOrderAndJournalTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var manifests: ManifestStore!
    private var journal: SyncJournal!
    private var source: DataSource!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cdbm-a6-\(UUID().uuidString)")
        folder = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        manifests = ManifestStore(directory: root.appendingPathComponent("manifests"))
        journal = SyncJournal(directory: root.appendingPathComponent("journals"))
        source = DataSource(
            name: "тест",
            path: folder.path,
            fileExtensions: ["md"],
            mapping: .singleCollectionWithRelativePath,
            collectionName: "a6notes",
            chunking: ChunkingConfiguration(strategy: .fixed, chunkSize: 40, sizeUnit: .characters, overlapPercent: 0)
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeService() -> SourceSyncService {
        SourceSyncService(manifests: manifests, journal: journal)
    }

    private func write(_ text: String, to name: String = "note.md") throws {
        try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func sync(
        _ service: SourceSyncService,
        database: FailingDatabase,
        embeddings: CountingEmbeddings
    ) async throws -> SyncSummary {
        try await service.sync(
            source: source,
            embeddingModel: "test-model",
            chroma: database,
            embeddings: embeddings,
            binding: ModelBindingService(),
            progress: { _ in }
        )
    }

    // MARK: - The happy path still works

    func testAFirstRunWritesEverythingAndLeavesAnEmptyJournal() async throws {
        try write(String(repeating: "первый текст. ", count: 12))
        let database = FailingDatabase()
        let service = makeService()

        let summary = try await sync(service, database: database, embeddings: CountingEmbeddings())

        XCTAssertEqual(summary.added, 1)
        let probe1 = await database.documents(in: "a6notes").count
        XCTAssertGreaterThan(probe1, 1, "текст должен разбиться на несколько чанков")
        let probe2 = await database.deleteCalls
        XCTAssertEqual(probe2, 0, "удалять нечего при первой записи")
        let probe3 = await service.pendingRecovery(sourceID: source.id).isEmpty
        XCTAssertTrue(probe3, "журнал в норме пуст")
    }

    /// The core of A6.2: the write happens first, the deletion second.
    func testNothingIsDeletedBeforeTheNewChunksAreWritten() async throws {
        try write(String(repeating: "длинный исходный текст. ", count: 12))
        let database = FailingDatabase()
        let service = makeService()
        try await sync(service, database: database, embeddings: CountingEmbeddings())
        let before = await database.documents(in: "a6notes").count
        XCTAssertGreaterThan(before, 3)

        // Now the file becomes much shorter, and the first upsert fails.
        try write("коротко")
        await database.failNext(.upsert)
        do {
            try await sync(service, database: database, embeddings: CountingEmbeddings())
            XCTFail("сбой записи должен был выйти наружу")
        } catch {}

        let afterFailedWrite = await database.documents(in: "a6notes").count
        XCTAssertEqual(
            afterFailedWrite, before,
            "запись не удалась — старые чанки обязаны остаться на месте"
        )
    }

    // MARK: - Recovery

    /// Failure between step 3 and step 4: the new chunks are in, the tail is
    /// not gone yet. The next run finishes the job without a single vector.
    func testFailureAfterTheWriteIsFinishedWithoutRecomputingVectors() async throws {
        try write(String(repeating: "исходный текст для чанков. ", count: 12))
        let database = FailingDatabase()
        let service = makeService()
        try await sync(service, database: database, embeddings: CountingEmbeddings())
        let longCount = await database.documents(in: "a6notes").count

        // Shorter file → there will be a tail to remove; the deletion dies.
        try write("совсем короткий текст")
        await database.failNext(.delete)
        do {
            try await sync(service, database: database, embeddings: CountingEmbeddings())
            XCTFail("сбой удаления должен был выйти наружу")
        } catch {}

        let pending = await service.pendingRecovery(sourceID: source.id)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.state, .upserted, "запись должна остаться в состоянии «записано»")

        // The next run replays it: no text is read, no vector computed.
        await database.stopFailing()
        let embeddings = CountingEmbeddings()
        let recovery = await service.recover(source: source, chroma: database)

        XCTAssertEqual(recovery.finished, ["note.md"])
        XCTAssertTrue(recovery.failures.isEmpty)
        let probe4 = await embeddings.calls
        XCTAssertEqual(probe4, 0, "доигрывание не пересчитывает векторы")
        let probe5 = await database.documents(in: "a6notes").count
        XCTAssertLessThan(probe5, longCount, "хвост удалён")
        let probe6 = await service.pendingRecovery(sourceID: source.id).isEmpty
        XCTAssertTrue(probe6)

        // And the manifest now matches reality: a repeat run has nothing to do.
        let summary = try await sync(service, database: database, embeddings: embeddings)
        XCTAssertEqual(summary.added + summary.updated, 0, "файл уже в актуальном состоянии")
        let probe7 = await embeddings.calls
        XCTAssertEqual(probe7, 0)
    }

    /// Failure between step 4 and step 5: only the manifest is missing. Replay
    /// touches neither vectors nor the database.
    func testFailureBeforeTheManifestIsFinishedWithoutTouchingTheDatabase() async throws {
        try write(String(repeating: "текст один. ", count: 12))
        let database = FailingDatabase()
        let service = makeService()
        try await sync(service, database: database, embeddings: CountingEmbeddings())

        // Simulate the crash by hand: the journal says the tail is gone but the
        // manifest never got written.
        var manifest = manifests.load(sourceID: source.id)
        let entry = try XCTUnwrap(manifest.entries["note.md"])
        manifest.forget(relativePath: "note.md")
        manifests.save(manifest)
        try journal.begin(
            SyncJournalEntry(
                relativePath: "note.md",
                collectionName: "a6notes",
                oldIDs: entry.chunkIDs,
                newIDs: entry.chunkIDs,
                state: .cleaned,
                contentHash: entry.contentHash,
                modifiedAt: entry.modifiedAt,
                size: entry.size,
                chunkingSignature: entry.chunkingSignature,
                embeddingModel: entry.embeddingModel
            ),
            sourceID: source.id
        )

        let deletesBefore = await database.deleteCalls
        let embeddings = CountingEmbeddings()
        let recovery = await service.recover(source: source, chroma: database)

        XCTAssertEqual(recovery.finished, ["note.md"])
        let probe8 = await database.deleteCalls
        XCTAssertEqual(probe8, deletesBefore, "повторного удаления быть не должно")
        let probe9 = await embeddings.calls
        XCTAssertEqual(probe9, 0)
        XCTAssertEqual(manifests.load(sourceID: source.id).entries["note.md"]?.chunkIDs, entry.chunkIDs)
    }

    /// Failure at step 3 with no way to know how much landed: the file is
    /// re-indexed, and the partial write does not survive it.
    func testAnInterruptedWriteForcesAReindexAndLeavesNoStrays() async throws {
        // Long enough to be written in several batches — a partial write is
        // only possible when there is more than one.
        try write(String(repeating: "очень длинная первая версия текста. ", count: 120))
        let database = FailingDatabase()
        let service = makeService()
        try await sync(service, database: database, embeddings: CountingEmbeddings())
        let originalIDs = Set(await database.documents(in: "a6notes").keys)
        XCTAssertGreaterThan(originalIDs.count, 60)

        // Shorter, but still several batches: the run dies with part of the new
        // version already written.
        try write(String(repeating: "вторая версия. ", count: 120))
        await database.failNext(.upsert, call: 2)
        _ = try? await sync(service, database: database, embeddings: CountingEmbeddings())

        let partial = Set(await database.documents(in: "a6notes").keys)
        XCTAssertEqual(partial.count, originalIDs.count, "часть новых чанков перезаписала старые по тем же id")

        // Nothing says how much of the write landed, so the file is re-done.
        let pending = await service.pendingRecovery(sourceID: source.id)
        XCTAssertEqual(pending.first?.state, .started)

        await database.stopFailing()
        let recovery = await service.recover(source: source, chroma: database)
        XCTAssertEqual(recovery.toReindex, ["note.md"], "файл должен быть переиндексирован целиком")

        // The re-index runs even though the file itself has not changed since,
        // and it leaves exactly the chunks of the current version.
        let summary = try await sync(service, database: database, embeddings: CountingEmbeddings())
        XCTAssertEqual(summary.updated, 1)
        let remaining = Set(await database.documents(in: "a6notes").keys)
        let recorded = manifests.load(sourceID: source.id).entries["note.md"]?.chunkIDs ?? []
        XCTAssertEqual(remaining, Set(recorded), "в базе ровно то, что записано в манифесте")
        XCTAssertLessThan(remaining.count, originalIDs.count, "хвост первой версии удалён")
        let probe10 = await service.pendingRecovery(sourceID: source.id).isEmpty
        XCTAssertTrue(probe10)
    }

    /// a file that got shorter leaves no tail, a file that got longer
    /// gets all of its chunks and no duplicates.
    func testShrinkingAndGrowingFilesEndUpWithExactlyTheirOwnChunks() async throws {
        let database = FailingDatabase()
        let service = makeService()

        try write(String(repeating: "раз два три четыре пять. ", count: 20))
        try await sync(service, database: database, embeddings: CountingEmbeddings())
        let many = await database.documents(in: "a6notes").count
        XCTAssertGreaterThan(many, 5)

        try write("одна строка")
        try await sync(service, database: database, embeddings: CountingEmbeddings())
        let probe11 = await database.documents(in: "a6notes").count
        XCTAssertEqual(probe11, 1, "хвост длинной версии удалён")

        try write(String(repeating: "снова длинный текст здесь. ", count: 20))
        try await sync(service, database: database, embeddings: CountingEmbeddings())
        let grown = await database.documents(in: "a6notes").count
        XCTAssertGreaterThan(grown, 5)
        let uniqueIDs = Set(await database.documents(in: "a6notes").keys).count
        XCTAssertEqual(grown, uniqueIDs, "дублей быть не может")
        XCTAssertEqual(manifests.load(sourceID: source.id).entries["note.md"]?.chunkIDs.count, grown)
    }

    func testAnUnchangedFileWritesNothingAndEmbedsNothing() async throws {
        try write(String(repeating: "неизменный текст. ", count: 10))
        let database = FailingDatabase()
        let service = makeService()
        try await sync(service, database: database, embeddings: CountingEmbeddings())

        let embeddings = CountingEmbeddings()
        let upsertsBefore = await database.upsertCalls
        let summary = try await sync(service, database: database, embeddings: embeddings)

        XCTAssertEqual(summary.added + summary.updated, 0)
        XCTAssertEqual(summary.unchanged, 1)
        let probe12 = await embeddings.calls
        XCTAssertEqual(probe12, 0, "неизменный файл не эмбеддится")
        let probe13 = await database.upsertCalls
        XCTAssertEqual(probe13, upsertsBefore, "и не пишется")
    }

    /// The file was touched but its text is the same — 8.4 says that is not a
    /// change, and A6.5 asks for it to be proven.
    func testATouchedFileWithTheSameTextIsNotReindexed() async throws {
        try write(String(repeating: "то же самое содержимое. ", count: 10))
        let database = FailingDatabase()
        let service = makeService()
        try await sync(service, database: database, embeddings: CountingEmbeddings())

        // Same bytes, new modification date.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: folder.appendingPathComponent("note.md").path
        )

        let embeddings = CountingEmbeddings()
        let summary = try await sync(service, database: database, embeddings: embeddings)
        XCTAssertEqual(summary.unchanged, 1)
        let probe14 = await embeddings.calls
        XCTAssertEqual(probe14, 0)
    }

    /// recovery that fails blocks the automatic modes until someone runs
    /// the source by hand.
    func testAFailedRecoveryBlocksAutomaticRunsAndUnblocksAfterASuccessfulOne() async throws {
        try write(String(repeating: "текст для блокировки. ", count: 12))
        let database = FailingDatabase()
        let service = makeService()
        try await sync(service, database: database, embeddings: CountingEmbeddings())

        try write("короткий")
        await database.failNext(.delete)
        _ = try? await sync(service, database: database, embeddings: CountingEmbeddings())

        // Recovery runs into the same broken database.
        await database.failNext(.delete)
        let failed = await service.recover(source: source, chroma: database)
        XCTAssertEqual(failed.failures.count, 1)
        let blocked = await service.recoveryBlockReason(sourceID: source.id)
        XCTAssertNotNil(blocked, "источник должен быть помечен как требующий вмешательства")
        XCTAssertTrue(blocked?.contains("note.md") == true)

        // …and a working one clears the mark.
        await database.stopFailing()
        let recovered = await service.recover(source: source, chroma: database)
        XCTAssertTrue(recovered.failures.isEmpty)
        let probe15 = await service.recoveryBlockReason(sourceID: source.id)
        XCTAssertNil(probe15)
    }

    /// Метка, которую не удалось поставить, — не мелочь, и молчать о ней
    /// нельзя.
    ///
    /// Она единственное, что удерживает таймер от источника с недоигранным
    /// восстановлением. Не записалась — и через час автоматический прогон
    /// пойдёт индексировать поверх состояния, которого никто не понимает.
    /// Отказ записи маловероятен, но цена его — ровно то, ради чего метка
    /// заведена.
    func testAMarkThatCouldNotBeWrittenIsReportedRatherThanSwallowed() throws {
        var complaints: [String] = []
        // Каталог, которого нет и который создать нельзя: путь идёт сквозь
        // обычный файл.
        let barrier = FileManager.default.temporaryDirectory
            .appendingPathComponent("block-barrier-\(UUID().uuidString)")
        try Data("не каталог".utf8).write(to: barrier)
        defer { try? FileManager.default.removeItem(at: barrier) }

        let journal = SyncJournal(
            directory: barrier.appendingPathComponent("journals"),
            log: { level, _, message in if level == .error { complaints.append(message) } }
        )
        let sourceID = UUID()

        XCTAssertFalse(
            journal.block(sourceID: sourceID, reason: "не доиграно восстановление note.md"),
            "невозможность поставить метку обязана быть видна вызывающему"
        )
        XCTAssertEqual(complaints.count, 1, "и сказана вслух")
        XCTAssertTrue(complaints[0].contains("note.md"), complaints[0])
        // Метки действительно нет — значит про неё и надо было кричать.
        XCTAssertNil(journal.blockReason(sourceID: sourceID))
    }

    /// В обычном случае метка ставится и подтверждается.
    func testAMarkThatWasWrittenReportsSuccess() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("journals-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = SyncJournal(directory: directory)
        let sourceID = UUID()

        XCTAssertTrue(journal.block(sourceID: sourceID, reason: "причина"))
        XCTAssertEqual(journal.blockReason(sourceID: sourceID), "причина")
    }

    /// Two sources are two journals. A6.5 asks explicitly.
    func testJournalsOfTwoSourcesDoNotMix() throws {
        let first = UUID()
        let second = UUID()
        let entry = SyncJournalEntry(
            relativePath: "a.md", collectionName: "one", oldIDs: [], newIDs: ["1"],
            contentHash: "h", modifiedAt: Date(), size: 1,
            chunkingSignature: "s", embeddingModel: "m"
        )
        var other = entry
        other.relativePath = "b.md"
        other.collectionName = "two"

        try journal.begin(entry, sourceID: first)
        try journal.begin(other, sourceID: second)

        XCTAssertEqual(journal.pending(sourceID: first).map(\.relativePath), ["a.md"])
        XCTAssertEqual(journal.pending(sourceID: second).map(\.relativePath), ["b.md"])

        try journal.finish(sourceID: first, relativePath: "a.md")
        XCTAssertTrue(journal.pending(sourceID: first).isEmpty)
        XCTAssertEqual(journal.pending(sourceID: second).count, 1, "чужой журнал не тронут")
    }

    func testTheJournalKeepsTheLastStateAndForgetsFinishedFiles() throws {
        let sourceID = UUID()
        let entry = SyncJournalEntry(
            relativePath: "a.md", collectionName: "one", oldIDs: ["old"], newIDs: ["new"],
            contentHash: "h", modifiedAt: Date(), size: 1,
            chunkingSignature: "s", embeddingModel: "m"
        )
        try journal.begin(entry, sourceID: sourceID)
        try journal.advance(sourceID: sourceID, relativePath: "a.md", to: .upserted)
        try journal.advance(sourceID: sourceID, relativePath: "a.md", to: .cleaned)

        let pending = journal.pending(sourceID: sourceID)
        XCTAssertEqual(pending.count, 1, "один файл — одна актуальная запись, а не три")
        XCTAssertEqual(pending.first?.state, .cleaned)
        XCTAssertEqual(pending.first?.tailIDs, ["old"], "хвост — то, что было и чего больше нет")

        try journal.finish(sourceID: sourceID, relativePath: "a.md")
        XCTAssertTrue(journal.pending(sourceID: sourceID).isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: journal.fileURL(for: sourceID).path),
            "в норме журнал не просто пуст, а отсутствует"
        )
    }
}

/// the manifest must be readable or absent, never half-written, and never
/// read as if a newer format were this one.
final class ManifestDurabilityTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cdbm-manifest-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSavedManifestCarriesItsVersionAndComesBackWhole() throws {
        let store = ManifestStore(directory: directory)
        let id = UUID()
        var manifest = SourceManifest(sourceID: id)
        manifest.record(ManifestEntry(
            relativePath: "a.md", contentHash: "h", modifiedAt: Date(), size: 10,
            chunkIDs: ["a-0", "a-1"], collectionName: "c", chunkingSignature: "s", embeddingModel: "m"
        ))
        store.save(manifest)

        let reloaded = store.load(sourceID: id)
        XCTAssertEqual(reloaded.version, SourceManifest.currentVersion)
        XCTAssertEqual(reloaded.entries["a.md"]?.chunkIDs, ["a-0", "a-1"])
        XCTAssertNil(
            try? FileManager.default.contentsOfDirectory(atPath: directory.path).first { $0.hasSuffix(".tmp") },
            "временный файл не должен оставаться рядом с манифестом"
        )
    }

    func testAManifestFromANewerVersionIsNotReadAtAll() throws {
        let store = ManifestStore(directory: directory)
        let id = UUID()
        var manifest = SourceManifest(sourceID: id)
        manifest.version = SourceManifest.currentVersion + 1
        manifest.record(ManifestEntry(
            relativePath: "a.md", contentHash: "h", modifiedAt: Date(), size: 10,
            chunkIDs: ["a-0"], collectionName: "c", chunkingSignature: "s", embeddingModel: "m"
        ))
        try AppPaths.ensureDirectory(directory)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: store.fileURL(for: id))

        let loaded = store.load(sourceID: id)
        XCTAssertTrue(loaded.entries.isEmpty, "чужой формат читается как «манифеста нет», а не наполовину")
    }

    func testAManifestWrittenBeforeVersionsExistedIsStillOurs() throws {
        let store = ManifestStore(directory: directory)
        let id = UUID()
        let legacy = """
        {"sourceID":"\(id.uuidString)","entries":{},"pendingRemovals":[]}
        """
        try AppPaths.ensureDirectory(directory)
        try Data(legacy.utf8).write(to: store.fileURL(for: id))

        XCTAssertEqual(store.load(sourceID: id).version, 1)
    }
}

/// G6 through a real sync: what the collection ends up carrying, and what the
/// user is told when the recipe changes under a collection that is already full.
final class StrategyParamsDuringSyncTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var manifests: ManifestStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cdbm-g6-\(UUID().uuidString)")
        folder = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        manifests = ManifestStore(directory: root.appendingPathComponent("manifests"))
        try String(repeating: "текст про оплату. ", count: 20)
            .write(to: folder.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func source(chunkSize: Int) -> DataSource {
        DataSource(
            name: "тест",
            path: folder.path,
            fileExtensions: ["md"],
            mapping: .singleCollectionWithRelativePath,
            collectionName: "g6notes",
            chunking: ChunkingConfiguration(
                strategy: .fixed, chunkSize: chunkSize, sizeUnit: .characters, overlapPercent: 0
            )
        )
    }

    @discardableResult
    private func sync(
        _ source: DataSource,
        database: FailingDatabase,
        warnings: WarningCollector? = nil
    ) async throws -> SyncSummary {
        let service = SourceSyncService(
            manifests: manifests,
            journal: SyncJournal(directory: root.appendingPathComponent("journals")),
            log: { level, _, message in
                if level == .warning { warnings?.add(message) }
            }
        )
        return try await service.sync(
            source: source, embeddingModel: "test-model", chroma: database,
            embeddings: CountingEmbeddings(), binding: ModelBindingService(), progress: { _ in }
        )
    }

    func testAFreshCollectionCarriesTheVersionedHash() async throws {
        let database = FailingDatabase()
        let summary = try await sync(source(chunkSize: 60), database: database)
        XCTAssertTrue(summary.heterogeneousCollections.isEmpty)

        let metadata = await database.metadata(of: "g6notes")
        XCTAssertEqual(
            StrategyParamsHash.parse(metadata),
            StrategyParamsHash.of(source(chunkSize: 60).chunking)
        )
        XCTAssertEqual(metadata?[CollectionBindingKeys.chunkingStrategy], .string("fixed"))
        XCTAssertNil(metadata?[CollectionBindingKeys.legacyChunking], "новое поле пишется вместо старого, а не рядом")
    }

    /// A collection filled before the field existed: brought up to date without
    /// a word, because nothing about its contents changed.
    func testACollectionFilledBeforeTheFieldIsMigratedSilently() async throws {
        let database = FailingDatabase()
        await database.seedMetadata(
            [CollectionBindingKeys.legacyChunking: .string("fixed/60c/ov0")],
            for: "g6notes"
        )
        let warnings = WarningCollector()
        let summary = try await sync(source(chunkSize: 60), database: database, warnings: warnings)

        XCTAssertTrue(summary.heterogeneousCollections.isEmpty)
        XCTAssertTrue(warnings.all.filter { $0.contains("неоднородн") }.isEmpty, warnings.all.joined(separator: "; "))
        let metadata = await database.metadata(of: "g6notes")
        XCTAssertEqual(StrategyParamsHash.parse(metadata)?.schemaVersion, StrategyParamsHash.currentSchemaVersion)
    }

    /// The real thing: the recipe changed under a collection that already has
    /// documents in it.
    func testChangingTheRecipeIsReportedAndNotActedOn() async throws {
        let database = FailingDatabase()
        try await sync(source(chunkSize: 60), database: database)
        let stored = StrategyParamsHash.parse(await database.metadata(of: "g6notes"))

        let warnings = WarningCollector()
        let summary = try await sync(source(chunkSize: 200), database: database, warnings: warnings)

        XCTAssertEqual(summary.heterogeneousCollections, ["g6notes"])
        XCTAssertTrue(summary.line.contains("неоднородным"), summary.line)
        XCTAssertTrue(
            warnings.all.contains { $0.contains("переиндексация или клонирование") },
            warnings.all.joined(separator: "; ")
        )
        // The stored value keeps describing what the collection was filled with,
        // so the warning comes back on the next run too.
        let after = await database.metadata(of: "g6notes")
        XCTAssertEqual(StrategyParamsHash.parse(after), stored)
    }

    func testAnUnchangedRecipeSaysNothing() async throws {
        let database = FailingDatabase()
        try await sync(source(chunkSize: 60), database: database)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("note.md"))
        try String(repeating: "другой текст про доставку. ", count: 20)
            .write(to: folder.appendingPathComponent("second.md"), atomically: true, encoding: .utf8)

        let warnings = WarningCollector()
        let summary = try await sync(source(chunkSize: 60), database: database, warnings: warnings)
        XCTAssertTrue(summary.heterogeneousCollections.isEmpty)
        XCTAssertTrue(warnings.all.filter { $0.contains("неоднородн") }.isEmpty)
    }
}

final class WarningCollector: @unchecked Sendable {
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
