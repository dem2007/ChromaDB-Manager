import XCTest
@testable import ChromaCore

/// Разбор ревью модулей: что теряется, когда что-то идёт не так, —
/// удаление при сбое связи, восстановление копии, пропавшие и переехавшие
/// таблицы, контрольная точка перенарезки.
final class DataSafetyTests: XCTestCase {
    private var root: URL!
    private var store: ManifestStore!
    private var tables: TableManifestStore!
    private var service: SourceSyncService!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = ManifestStore(directory: root.appendingPathComponent("manifests"))
        tables = TableManifestStore(directory: root.appendingPathComponent("manifests"))
        service = SourceSyncService(manifests: store, tableManifests: tables)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var folder: URL { root.appendingPathComponent("docs") }

    private func source(extensions: [String] = ["md"]) -> DataSource {
        DataSource(name: "docs", path: folder.path, fileExtensions: extensions, collectionName: "docs_col")
    }

    // MARK: - Удаление при сбое связи

    /// Сбой связи — не «коллекции нет»: файл не забывается, и решение
    /// остаётся на месте до следующей попытки.
    func testATransientErrorDoesNotForgetTheFile() async throws {
        let source = source()
        var manifest = store.load(sourceID: source.id)
        manifest.record(ManifestEntry(
            relativePath: "a.md", contentHash: "h", modifiedAt: Date(), size: 1,
            chunkIDs: ["x-0"], collectionName: "docs_col",
            chunkingSignature: source.chunking.signature, embeddingModel: "m"
        ))
        store.save(manifest)

        let database = FailingDatabase()
        _ = try await database.createCollection(name: "docs_col", metadata: nil, configuration: nil, getOrCreate: true)
        await database.failNext(.resolve)
        do {
            _ = try await service.resolve(
                removal: PendingRemoval(relativePath: "a.md", collectionName: "docs_col", chunkIDs: ["x-0"]),
                decision: .deleteChunks, source: source, chroma: database
            )
            XCTFail("сбой связи должен дойти до вызывающего")
        } catch {}
        XCTAssertNotNil(store.load(sourceID: source.id).entries["a.md"], "файл не должен забываться")

        // Коллекции действительно нет — удалять нечего, и это не ошибка.
        let empty = FailingDatabase()
        let deleted = try await service.resolve(
            removal: PendingRemoval(relativePath: "a.md", collectionName: "docs_col", chunkIDs: ["x-0"]),
            decision: .deleteChunks, source: source, chroma: empty
        )
        XCTAssertEqual(deleted, 0)
        XCTAssertNil(store.load(sourceID: source.id).entries["a.md"])
    }

    // MARK: - Файлы, вышедшие из источника

    /// Проиндексированный файл, переросший предел, — вне источника: его
    /// чанки ждут решения, а не остаются в поиске молча. И это не массовая
    /// пропажа — файлы на диске, диск на месте.
    func testAnIndexedFileThatLeftTheSourceAwaitsADecision() async throws {
        var source = source()
        source.maxFileSizeMB = 1
        var manifest = store.load(sourceID: source.id)
        let big = String(repeating: "x", count: 1_100_000)
        for index in 0..<10 {
            let name = "f\(index).md"
            let url = folder.appendingPathComponent(name)
            try big.write(to: url, atomically: true, encoding: .utf8)
            // Только что записанный файл план считает растущим и откладывает.
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: url.path
            )
            manifest.record(ManifestEntry(
                relativePath: name, contentHash: "h", modifiedAt: Date(), size: 1,
                chunkIDs: ["\(name)-0"], collectionName: "docs_col",
                chunkingSignature: source.chunking.signature, embeddingModel: "m"
            ))
        }
        store.save(manifest)

        let plan = try await service.plan(source: source, embeddingModel: "m")
        XCTAssertNil(plan.massDisappearance)
        XCTAssertEqual(plan.newlyMissing.map(\.relativePath).sorted(), (0..<10).map { "f\($0).md" })
        XCTAssertEqual(plan.outOfScope.count, 10)
    }

    // MARK: - Копия при живом сервере

    /// Сервер, переживший остановку, держит папку — копия и восстановление
    /// отказывают, а не снимают файлы из-под живого процесса.
    func testABackupRefusesAFolderAServerStillHolds() throws {
        let database = root.appendingPathComponent("held")
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        let me = try XCTUnwrap(ProcessInspector.identity(of: getpid()))
        let live = RunningServerRecord(
            pid: getpid(), port: 1, host: "127.0.0.1", path: database.path,
            label: "тест", startedAt: me.startedAt, executablePath: me.executablePath
        )
        XCTAssertEqual(BackupService.liveServer(holding: database, records: [live])?.pid, getpid())

        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        let gone = RunningServerRecord(
            pid: finished.processIdentifier, port: 1, host: "127.0.0.1", path: database.path,
            label: "тест", startedAt: Date(), executablePath: "/usr/bin/true"
        )
        XCTAssertNil(BackupService.liveServer(holding: database, records: [gone]))
        XCTAssertNil(BackupService.liveServer(holding: root.appendingPathComponent("other"), records: [live]))
    }

    // MARK: - Выгрузка коллекции

    /// Две выгрузки в одну секунду — два файла, а не один затёртый.
    func testExportsInTheSameSecondDoNotOverwriteEachOther() throws {
        let backups = BackupService(directory: root.appendingPathComponent("exports"))
        try AppPaths.ensureDirectory(root.appendingPathComponent("exports"))
        let first = try backups.place(Data("первая".utf8), named: "notes_2026-10-08_12-00-00")
        let second = try backups.place(Data("вторая".utf8), named: "notes_2026-10-08_12-00-00")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "первая")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "вторая")
        XCTAssertEqual(second.lastPathComponent, "notes_2026-10-08_12-00-00-2.json")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("exports").path)
        XCTAssertEqual(leftovers.filter { $0.hasSuffix(".partial") }, [])
    }

    // MARK: - Восстановление копии

    /// Копия базы, путь к которой записан не тем регистром, что на диске,
    /// проходит проверку: обход отдаёт настоящий регистр, и ключи описи,
    /// срезанные строкой по записанному пути, не сходились никогда.
    func testABackupOfAPathTypedInAnotherCaseIsVerified() throws {
        let base = root.appendingPathComponent("case")
        let database = base.appendingPathComponent("chroma")
        try FileManager.default.createDirectory(
            at: database.appendingPathComponent("segment"), withIntermediateDirectories: true
        )
        try Data("база".utf8).write(to: database.appendingPathComponent("chroma.sqlite3"))
        try Data("сегмент".utf8).write(to: database.appendingPathComponent("segment/data.bin"))

        let backups = BackupService(directory: root.appendingPathComponent("backups"))
        XCTAssertNoThrow(try backups.backup(databaseAt: base.appendingPathComponent("Chroma"), note: nil))
    }

    /// Восстановленная база — ровно копия, без её заметки, а прежняя
    /// отложена в сторону, а не стёрта.
    func testRestoreReplacesTheDatabaseWholeAndKeepsTheOldOne() throws {
        let database = root.appendingPathComponent("chroma")
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        try Data("было".utf8).write(to: database.appendingPathComponent("chroma.sqlite3"))

        let backups = BackupService(directory: root.appendingPathComponent("backups"))
        let record = try backups.backup(databaseAt: database, note: "до правки")
        try Data("стало".utf8).write(to: database.appendingPathComponent("chroma.sqlite3"))

        try backups.restore(record, to: database)

        XCTAssertEqual(try String(contentsOf: database.appendingPathComponent("chroma.sqlite3"), encoding: .utf8), "было")
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.appendingPathComponent(BackupService.noteFile).path),
                       "заметка копии в базу не попадает")
        let aside = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("backups").path)
            .filter { $0.hasPrefix("chroma_before_restore_") }
        XCTAssertEqual(aside.count, 1)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains("_restoring_") }
        XCTAssertTrue(leftovers.isEmpty, "временная папка восстановления убрана")

        // Следующая копия той же базы проходит проверку и не несёт чужой заметки.
        let next = try backups.backup(databaseAt: database)
        XCTAssertFalse(next.isIncomplete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: next.url.appendingPathComponent(BackupService.noteFile).path))
    }

    // MARK: - Таблицы

    private func tableFile(
        _ path: String, collection: String = "docs_col", size: Int64 = 1, modifiedAt: Date = Date(),
        metadataSignature: String = ""
    ) -> TableFileManifest {
        TableFileManifest(
            relativePath: path, collectionName: collection,
            sheets: ["Лист1": SheetManifest(sheetName: "Лист1", rows: [
                "1": TableRowRecord(documentID: "r1", rowNumber: 2, rowKey: nil, textHash: "a", metadataHash: "a"),
                "2": TableRowRecord(documentID: "r2", rowNumber: 3, rowKey: nil, textHash: "b", metadataHash: "b", isOrphaned: true),
            ])],
            modifiedAt: modifiedAt, size: size,
            profilesSignature: TableSyncService.profilesSignature([], unmatchedSheetsAsText: true),
            metadataSignature: metadataSignature
        )
    }

    /// Книга, исчезнувшая с диска, — её строки ждут решения, кроме
    /// оставленных человеком; вернётся — план её перечитает.
    func testRowsOfAVanishedTableAwaitADecision() {
        let id = UUID()
        tables.save(["прайс.xlsx": tableFile("прайс.xlsx"), "есть.csv": tableFile("есть.csv")], sourceID: id)

        SourceSyncService.markVanishedTables(present: ["есть.csv"], store: tables, sourceID: id, log: noopLogHandler)

        let files = tables.load(sourceID: id)
        XCTAssertEqual(files["прайс.xlsx"]?.pendingRemovals["Лист1"]?.rows.map(\.documentID), ["r1"])
        XCTAssertEqual(files["прайс.xlsx"]?.size, -1, "вернувшийся файл должен быть прочитан")
        XCTAssertEqual(files["есть.csv"]?.pendingRemovals, [:])
        XCTAssertEqual(tables.pendingRemovals(sourceID: id).count, 1)
    }

    /// Таблица, которую увели в другую коллекцию, — не «без изменений».
    func testATableWithANewCollectionIsWork() async throws {
        let source = source(extensions: ["csv"])
        let url = folder.appendingPathComponent("a.csv")
        try "Название;Цена\nБолт;5\n".write(to: url, atomically: true, encoding: .utf8)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let known = tableFile(
            "a.csv", collection: "old_col",
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modifiedAt: (attributes[.modificationDate] as? Date) ?? Date(),
            metadataSignature: source.metadataSignature
        )
        tables.save(["a.csv": known], sourceID: source.id)

        let plan = try await service.plan(source: source, embeddingModel: "m")
        let item = try XCTUnwrap(plan.items.first { $0.relativePath == "a.csv" })
        XCTAssertTrue(item.kind.writesDocuments, "\(item.kind)")

        var same = known
        same.collectionName = "docs_col"
        tables.save(["a.csv": same], sourceID: source.id)
        let again = try await service.plan(source: source, embeddingModel: "m")
        XCTAssertEqual(again.items.first { $0.relativePath == "a.csv" }?.kind, .unchanged)
    }

    // MARK: - Перенарезка

    /// Метка прогона переживает запись контрольной точки, а точка без неё —
    /// записанная прежней сборкой — читается.
    func testTheCheckpointRemembersItsRun() throws {
        let journal = ReembeddingJournal(fileURL: root.appendingPathComponent("reembedding.json"))
        journal.save(ReembeddingCheckpoint(
            collectionID: "c", collectionName: "c", targetModel: "m", chunkingSignature: "s",
            rechunk: true, doneIDs: ["a"], totalIDs: 2, startedAt: Date(), runStamp: "run-1"
        ))
        XCTAssertEqual(journal.checkpoint(for: "c")?.runStamp, "run-1")

        let legacy = #"{"collectionID":"c","collectionName":"c","targetModel":"m","chunkingSignature":"s","rechunk":true,"doneIDs":[],"totalIDs":1,"startedAt":"2026-01-01T00:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertNil(try decoder.decode(ReembeddingCheckpoint.self, from: Data(legacy.utf8)).runStamp)
    }
}
