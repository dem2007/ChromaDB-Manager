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
    func testARecordedEntrySurvivesAFreshInstance() throws {
        let trash = TrashService(fileURL: fileURL)
        try trash.record(makeEntry(documentID: "doc-42"))
        waitForFile(fileURL)
        waitUntil { FileManager.default.fileExists(atPath: self.fileURL.path) }

        let reloaded = TrashService(fileURL: fileURL)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.first?.documentID, "doc-42")
        XCTAssertEqual(reloaded.entries.first?.embedding, [0.1, 0.2, 0.3])
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
