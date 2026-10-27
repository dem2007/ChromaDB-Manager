import XCTest
@testable import ChromaCore

/// the local recycle bin for documents and collections deleted from the UI.
final class TrashServiceTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("trash.jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeEntry(
        documentID: String = "doc-1",
        deletedAt: Date = Date(),
        collectionName: String = "notes",
        reason: TrashEntry.Reason = .document,
        embedding: [Double]? = [0.1, 0.2, 0.3]
    ) -> TrashEntry {
        TrashEntry(
            deletedAt: deletedAt,
            documentID: documentID,
            document: "текст документа",
            metadata: ["k": .string("v")],
            embedding: embedding,
            collectionName: collectionName,
            collectionMetric: .cosine,
            collectionModel: "some-model",
            collectionServer: "ollama",
            collectionDimension: 3,
            reason: reason
        )
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !FileManager.default.fileExists(atPath: url.path) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    // MARK: - Recording and reloading

    /// The whole point of J3: a delete that already happened by accident must
    /// still be readable afterwards, from a fresh instance (i.e. after a
    /// restart), exactly like the audit log survives one.
    @MainActor
    func testARecordedEntrySurvivesAFreshInstance() async throws {
        let trash = TrashService(fileURL: fileURL)
        try trash.record(makeEntry(documentID: "doc-42"))
        waitForFile(fileURL)
        waitUntil { FileManager.default.fileExists(atPath: self.fileURL.path) }

        let reloaded = TrashService(fileURL: fileURL)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.first?.documentID, "doc-42")
        // В памяти — без вектора, целиком — из файла.
        XCTAssertNil(reloaded.entries.first?.embedding)
        XCTAssertTrue(reloaded.entries.first?.hasEmbedding ?? false)
        let full = await reloaded.fullEntries(withIDs: Set(reloaded.entries.map(\.id)))
        XCTAssertEqual(full.first?.embedding, [0.1, 0.2, 0.3])
        XCTAssertEqual(full.first?.metadata?["k"], .string("v"))
        // Сервер модели переживает перезапуск — восстановленная коллекция
        // привязывается к нему, а не к одноимённой модели другого.
        XCTAssertEqual(reloaded.entries.first?.collectionServer, "ollama")
        XCTAssertEqual(full.first?.collectionServer, "ollama")
    }

    /// перезапись после восстановления берёт строки из файла —
    /// у оставшихся записей векторы не пропадают, хотя в памяти их нет.
    @MainActor
    func testRewritingKeepsTheVectorsOfTheRemainingEntries() async throws {
        let trash = TrashService(fileURL: fileURL)
        let kept = makeEntry(documentID: "остаётся")
        let gone = makeEntry(documentID: "уходит")
        try trash.record([kept, gone])
        trash.forget(ids: [gone.id])
        waitUntil {
            JSONLines.read(at: self.fileURL).count == 1
        }
        let reloaded = TrashService(fileURL: fileURL)
        XCTAssertEqual(reloaded.entries.map(\.documentID), ["остаётся"])
        let keptFull = await reloaded.fullEntries(withIDs: [kept.id])
        XCTAssertEqual(keptFull.first?.embedding, [0.1, 0.2, 0.3])
        let goneFull = await reloaded.fullEntries(withIDs: [gone.id])
        XCTAssertTrue(goneFull.isEmpty)
    }

    /// Идентификатор ищется и тогда, когда «"id":"» встречается в тексте.
    @MainActor
    func testAnIDInsideTheTextDoesNotConfuseTheLookup() async throws {
        let trash = TrashService(fileURL: fileURL)
        let tricky = TrashEntry(
            documentID: "d", document: #"в тексте "id":"не-uuid" и ещё"#, metadata: nil,
            embedding: [1], collectionName: "c", collectionMetric: nil, collectionModel: nil, collectionServer: nil,
            collectionDimension: nil, reason: .document
        )
        try trash.record(tricky)
        let found = await trash.fullEntries(withIDs: [tricky.id])
        XCTAssertEqual(found.first?.document, tricky.document)
    }

    /// A batch (whole-collection capture) writes every line, not just the last.
    @MainActor
    func testABatchIsRecordedInOneGo() throws {
        let trash = TrashService(fileURL: fileURL)
        let batch = (0..<5).map { makeEntry(documentID: "doc-\($0)", reason: .collection) }
        try trash.record(batch)
        XCTAssertEqual(trash.entries.count, 5)
        waitUntil { (try? String(contentsOf: self.fileURL, encoding: .utf8))?.split(separator: "\n").count == 5 }
    }

    // MARK: - Restore removes the entry

    /// `forget` is what a successful restore calls: the copy is not a backup
    /// of anything once it is back in the live database.
    @MainActor
    func testForgetRemovesTheEntryFromMemoryAndDisk() throws {
        let trash = TrashService(fileURL: fileURL)
        let kept = makeEntry(documentID: "kept")
        let restored = makeEntry(documentID: "restored")
        try trash.record([kept, restored])
        waitUntil { trash.entries.count == 2 }

        trash.forget(ids: [restored.id])
        XCTAssertEqual(trash.entries.map(\.documentID), ["kept"])

        waitUntil {
            let reloaded = TrashService(fileURL: self.fileURL)
            return reloaded.entries.count == 1
        }
        let reloaded = TrashService(fileURL: fileURL)
        XCTAssertEqual(reloaded.entries.first?.documentID, "kept")
    }

    // MARK: - Retention by age

    @MainActor
    func testEntriesOlderThanRetentionAreSweptAutomatically() throws {
        let old = makeEntry(deletedAt: Date().addingTimeInterval(-20 * 86400))
        let fresh = makeEntry(documentID: "fresh", deletedAt: Date())
        let trash = TrashService(fileURL: fileURL, retentionDays: 14)
        try trash.record([old, fresh])
        // `record` re-runs the sweep, so the aged-out entry never has to wait
        // for the next launch.
        XCTAssertEqual(trash.entries.map(\.documentID), ["fresh"])
    }

    @MainActor
    func testZeroRetentionDaysMeansKeepForever() throws {
        let old = makeEntry(deletedAt: Date().addingTimeInterval(-999 * 86400))
        let trash = TrashService(fileURL: fileURL, retentionDays: 0)
        try trash.record(old)
        XCTAssertEqual(trash.entries.count, 1)
    }

    // MARK: - Retention by volume

    /// Oldest first: whatever was deleted most recently is the one still
    /// worth keeping around.
    @MainActor
    func testOverTheVolumeLimitTheOldestEntriesGoFirst() throws {
        let big = Array(repeating: 1.0, count: 1000) // ~8 KB per entry
        let oldest = makeEntry(documentID: "oldest", deletedAt: Date().addingTimeInterval(-300), embedding: big)
        let middle = makeEntry(documentID: "middle", deletedAt: Date().addingTimeInterval(-200), embedding: big)
        let newest = makeEntry(documentID: "newest", deletedAt: Date().addingTimeInterval(-100), embedding: big)

        // Big enough for two entries, not three.
        let trash = TrashService(fileURL: fileURL, retentionDays: 0, limitBytes: 17_000)
        try trash.record([oldest, middle, newest])

        XCTAssertFalse(trash.entries.contains { $0.documentID == "oldest" }, "самая старая запись должна быть вытеснена первой")
        XCTAssertTrue(trash.entries.contains { $0.documentID == "newest" })
    }

    /// Tightening the limit from settings sweeps immediately, not on the next delete.
    @MainActor
    func testUpdateRetentionReSweepsRightAway() throws {
        let big = Array(repeating: 1.0, count: 1000)
        let trash = TrashService(fileURL: fileURL, retentionDays: 0, limitBytes: 10_000_000)
        try trash.record([
            makeEntry(documentID: "a", deletedAt: Date().addingTimeInterval(-200), embedding: big),
            makeEntry(documentID: "b", deletedAt: Date().addingTimeInterval(-100), embedding: big),
        ])
        XCTAssertEqual(trash.entries.count, 2)

        trash.updateRetention(days: 0, limitBytes: 8_500)
        XCTAssertEqual(trash.entries.map(\.documentID), ["b"])
    }

    // MARK: - Emptying

    /// The one place that throws everything away for good, and only on an
    /// explicit call — same standing as `AuditLog.removeArchive`.
    @MainActor
    func testEmptyTrashRemovesEverythingForGood() throws {
        let trash = TrashService(fileURL: fileURL)
        try trash.record(makeEntry())
        waitForFile(fileURL)

        trash.emptyTrash()
        XCTAssertTrue(trash.entries.isEmpty)
        waitUntil { !FileManager.default.fileExists(atPath: self.fileURL.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - Damaged file

    /// A truncated last line (crash mid-write) must cost only that line, the
    /// same recovery `AuditLog` already relies on.
    @MainActor
    func testATruncatedLastLineDoesNotLoseTheRestOfTheFile() throws {
        let trash = TrashService(fileURL: fileURL)
        try trash.record([makeEntry(documentID: "a"), makeEntry(documentID: "b")])
        waitUntil { (try? String(contentsOf: self.fileURL, encoding: .utf8))?.split(separator: "\n").count == 2 }

        try "not json at all\n".appendToFile(at: fileURL)

        let reloaded = TrashService(fileURL: fileURL)
        XCTAssertEqual(reloaded.entries.count, 2)
    }
    // MARK: - Отказ захвата останавливает удаление

    /// Главный тест этой гарантии: пока `record` возвращал Void и писал файл
    /// асинхронно, узнать об отказе было нечем — и все четыре пути удаления
    /// шли дальше. Теперь отказ обязан быть слышен.
    @MainActor
    func testACaptureThatCannotReachDiskIsReported() throws {
        let trash = TrashService(fileURL: fileURL)
        try trash.record(makeEntry(documentID: "первый"))

        // Файл корзины больше не пишется — так выглядит и полный диск,
        // и потерянные права на файл.
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path) }

        XCTAssertThrowsError(try trash.record(makeEntry(documentID: "второй"))) { error in
            let text = error.localizedDescription
            XCTAssertTrue(
                text.contains("корзин") && text.contains("отменено"),
                "человеку надо сказать, что удаление отменено и почему: \(text)"
            )
        }
    }

    /// Неудачный захват не должен оставлять след в памяти: иначе окно
    /// показывает копии, которых на диске нет, — то же враньё, только тише.
    @MainActor
    func testAFailedCaptureLeavesNothingBehindInMemory() throws {
        let trash = TrashService(fileURL: fileURL)
        try trash.record(makeEntry(documentID: "первый"))
        XCTAssertEqual(trash.entries.count, 1)

        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path) }

        XCTAssertThrowsError(try trash.record(makeEntry(documentID: "второй")))
        XCTAssertEqual(trash.entries.map(\.documentID), ["первый"], "непойманная копия не должна числиться пойманной")
    }

    /// Первая запись в несуществующий файл тоже обязана сообщать об отказе:
    /// раньше здесь стоял `FileManager.createFile`, который возвращает Bool
    /// и причину не называет вовсе.
    @MainActor
    func testTheVeryFirstCaptureAlsoReportsFailure() throws {
        let readOnlyDirectory = directory.appendingPathComponent("закрыто")
        try FileManager.default.createDirectory(at: readOnlyDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnlyDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlyDirectory.path) }

        let trash = TrashService(fileURL: readOnlyDirectory.appendingPathComponent("trash.jsonl"))
        XCTAssertThrowsError(try trash.record(makeEntry()))
        XCTAssertTrue(trash.entries.isEmpty)
    }

    /// После возврата из `record` копия уже на диске — ждать нечего.
    /// Асинхронная запись означала, что «захвачено» и «сохранено» — разные
    /// моменты, а удаление происходило между ними.
    @MainActor
    func testTheCaptureIsOnDiskBeforeRecordReturns() throws {
        let trash = TrashService(fileURL: fileURL)
        try trash.record(makeEntry(documentID: "сразу"))

        // Никаких ожиданий: читаем файл тут же.
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("сразу"), "копия обязана быть на диске к моменту возврата")
        XCTAssertEqual(TrashService(fileURL: fileURL).entries.count, 1)
    }

}

private extension String {
    func appendToFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(utf8))
    }

}

/// корзина читается в фоне и не теряет того, что изменилось за это время.
final class TrashBackgroundLoadTests: XCTestCase {
    @MainActor
    func testWhatChangedDuringLoadingSurvivesIt() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trash-bg-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        func entry(_ name: String) -> TrashEntry {
            TrashEntry(documentID: name, document: name, metadata: ["k": .string("v")], embedding: [1, 2, 3],
                       collectionName: "c", collectionMetric: nil, collectionModel: nil, collectionServer: nil,
                       collectionDimension: nil, reason: .document)
        }
        let old = entry("старая"), gone = entry("снятая")
        try TrashService(fileURL: url).record([old, gone])

        let trash = TrashService(fileURL: url, loadsInBackground: true)
        let fresh = entry("новая")
        try trash.record(fresh)
        trash.forget(ids: [gone.id])
        for _ in 0..<200 where trash.isLoading { try await Task.sleep(nanoseconds: 10_000_000) }

        XCTAssertFalse(trash.isLoading)
        XCTAssertEqual(Set(trash.entries.map(\.documentID)), ["старая", "новая"])
        let oldFull = await trash.fullEntries(withIDs: [old.id])
        XCTAssertEqual(oldFull.first?.embedding, [1, 2, 3], "вектор остался в файле")
        XCTAssertEqual(trash.entries.first { $0.id == old.id }?.embeddingLength, 3)
        var goneFull = await trash.fullEntries(withIDs: [gone.id])
        for _ in 0..<200 where !goneFull.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
            goneFull = await trash.fullEntries(withIDs: [gone.id])
        }
        XCTAssertTrue(goneFull.isEmpty, "снятая за время чтения ушла и из файла")
    }
}

/// в памяти корзины только начало текста; файлы удалённого источника.
final class TrashPreviewTests: XCTestCase {
    @MainActor
    func testOnlyTheStartOfTheTextIsKeptInMemory() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trash-preview-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let long = String(repeating: "абв ", count: 1000)
        let entry = TrashEntry(documentID: "d", document: long, metadata: nil, embedding: [1],
                               collectionName: "c", collectionMetric: nil, collectionModel: nil, collectionServer: nil,
                               collectionDimension: nil, reason: .document)
        let trash = TrashService(fileURL: url)
        try trash.record(entry)
        let kept = try XCTUnwrap(trash.entries.first)
        XCTAssertEqual(kept.document?.count, TrashEntry.previewCharacters)
        XCTAssertTrue(kept.isDocumentTruncated)
        let full = await trash.fullEntries(withIDs: [entry.id])
        XCTAssertEqual(full.first?.document, long)

        let reloaded = TrashService(fileURL: url)
        XCTAssertEqual(reloaded.entries.first?.document?.count, TrashEntry.previewCharacters)
        XCTAssertEqual(reloaded.totalBytes, trash.totalBytes, "оценка объёма — по полному тексту")
    }

    func testOrphanedStateFilesAreFoundButOnlyForMissingSources() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("orphans-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let alive = UUID(), gone = UUID()
        func files(_ id: UUID) -> [URL] {
            ["\(id).json", "\(id).previous.json", "\(id)-tables.json", "\(id)-tables.previous.json"]
                .map { directory.appendingPathComponent($0) }
        }
        for url in files(alive) + files(gone) {
            try Data("{}".utf8).write(to: url)
        }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("прочее.json"))
        let orphans = SourceStateFiles.orphans(keeping: [alive], in: directory)
        XCTAssertEqual(Set(orphans.files.map(\.lastPathComponent)), Set(files(gone).map(\.lastPathComponent)))
        XCTAssertEqual(orphans.bytes, 8)
    }

    /// Удаление источника стирает и прежние версии манифестов — каждое
    /// хранилище своё.
    func testRemovingASourceRemovesThePreviousVersionsToo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("manifests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let manifests = ManifestStore(directory: directory)
        let tables = TableManifestStore(directory: directory)
        for url in [manifests.fileURL(for: id), tables.fileURL(for: id)] {
            try Data("{}".utf8).write(to: url)
            try Data("{}".utf8).write(to: JSONFileVersions.previousVersionURL(of: url))
        }
        manifests.remove(sourceID: id)
        tables.remove(sourceID: id)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }
}


/// из корзины в коллекцию ложатся только векторы её модели и сервера.
final class TrashRestorePlanTests: XCTestCase {
    private func entry(_ id: String, model: String?, server: String?) -> TrashEntry {
        TrashEntry(
            documentID: id, document: "текст", metadata: nil, embedding: [1, 2],
            collectionName: "notes", collectionMetric: .cosine,
            collectionModel: model, collectionServer: server, collectionDimension: 2,
            reason: .document
        )
    }

    func testOnlyVectorsOfTheCollectionsModelGoBack() throws {
        let studio = entry("a", model: "nomic-embed-text", server: "lmStudio")
        let ollama = entry("b", model: "nomic-embed-text", server: "ollama")
        let plan = TrashRestorePlan(
            entries: [studio, ollama],
            existing: .some(BoundModel(model: "nomic-embed-text", server: .ollama))
        )
        XCTAssertEqual(plan.restorable.map(\.documentID), ["b"])
        XCTAssertEqual(plan.left.map(\.documentID), ["a"])
        let conflict = try XCTUnwrap(plan.conflict(collection: "notes"))
        XCTAssertTrue((conflict.errorDescription ?? "").contains("LM Studio"), conflict.errorDescription ?? "")
    }

    /// Записи до сервера не знают — это LM Studio.
    func testAnOldEntryIsLMStudios() {
        let old = entry("a", model: "text-embedding-bge-m3", server: nil)
        let plan = TrashRestorePlan(
            entries: [old], existing: .some(BoundModel(model: "text-embedding-bge-m3", server: .lmStudio))
        )
        XCTAssertEqual(plan.restorable.count, 1)
        XCTAssertNil(plan.conflict(collection: "notes"))
    }

    /// Коллекции нет — создаётся с привязкой первой записи, у которой модель
    /// есть, и записи другой модели в неё не идут.
    func testARecreatedCollectionTakesTheFirstModelAndOnlyIt() {
        let bare = entry("a", model: nil, server: nil)
        let first = entry("b", model: "bge-m3:latest", server: "ollama")
        let other = entry("c", model: "text-embedding-bge-m3", server: "lmStudio")
        let plan = TrashRestorePlan(entries: [bare, first, other], existing: .none)
        XCTAssertEqual(plan.target, BoundModel(model: "bge-m3:latest", server: .ollama))
        XCTAssertEqual(plan.template?.documentID, "b", "коллекция создаётся с моделью, а не без неё")
        XCTAssertEqual(plan.restorable.map(\.documentID), ["a", "b"])
        XCTAssertEqual(plan.left.map(\.documentID), ["c"])
    }

    /// Коллекция без модели — сверять не с чем, как и раньше.
    func testAnUnboundCollectionTakesEverything() {
        let plan = TrashRestorePlan(
            entries: [entry("a", model: "m", server: "lmStudio"), entry("b", model: "n", server: "ollama")],
            existing: .some(nil)
        )
        XCTAssertEqual(plan.restorable.count, 2)
        XCTAssertNil(plan.conflict(collection: "notes"))
    }
}
