import XCTest
@testable import ChromaCore

// MARK: - B2: what is kept and what is thrown away

final class LogRetentionTests: XCTestCase {
    func testDefaultsAreTheOnesTheAddendumNames() {
        let retention = LogRetention()
        XCTAssertEqual(retention.megabytesPerFile, 10)
        XCTAssertEqual(retention.filesKept, 5)
        XCTAssertEqual(retention.inMemoryLines, 5000)
        XCTAssertEqual(retention.bytesPerFile, 10 * 1024 * 1024)
    }

    /// A hand-edited config must not be able to ask for an unbounded file or an
    /// empty screen buffer.
    func testNonsenseValuesFallBackToTheDefaults() throws {
        let json = #"{"megabytesPerFile": 0, "filesKept": -3, "inMemoryLines": 1000}"#
        let decoded = try JSONDecoder().decode(LogRetention.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.megabytesPerFile, 10)
        XCTAssertEqual(decoded.filesKept, 5)
        XCTAssertEqual(decoded.inMemoryLines, 1000, "разумное значение сохраняется")
    }
}

final class AuditArchivingTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("access.jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func entry(_ path: String = "/api/v2/heartbeat") -> AuditEntry {
        AuditEntry(
            client: "тест", method: "GET", path: path, operation: "heartbeat",
            access: .read, collection: nil, requestBytes: 10,
            responseStatus: 200, responseBytes: 20, durationSeconds: 0.01
        )
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !FileManager.default.fileExists(atPath: url.path) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// The whole point of B2: «очистить» must not mean «стереть».
    @MainActor
    func testArchivingKeepsTheRecordAndClearsTheScreen() throws {
        let audit = AuditLog(fileURL: fileURL)
        audit.record(entry())
        waitForFile(fileURL)

        audit.archiveCurrent()
        XCTAssertTrue(audit.entries.isEmpty, "экран очищается")

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, audit.archives().isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let archives = audit.archives()
        XCTAssertEqual(archives.count, 1, "запись сохранена в архиве, а не удалена")
        XCTAssertTrue(archives[0].url.lastPathComponent.contains("access-"), archives[0].url.lastPathComponent)
        XCTAssertGreaterThan(archives[0].bytes, 0)
    }

    /// Rotation by size archives too — the previous behaviour overwrote the
    /// only backup file it kept.
    @MainActor
    func testRotationArchivesRatherThanOverwrites() throws {
        let audit = AuditLog(fileURL: fileURL, maximumFileBytes: 400)
        for index in 0..<12 {
            audit.record(entry("/api/v2/collections/\(index)"))
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, audit.archives().isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(audit.archives().isEmpty, "переполнение файла должно давать архив")
    }

    /// An archive goes only when the user says so.
    @MainActor
    func testArchivesAreRemovedOnlyOnRequest() throws {
        let audit = AuditLog(fileURL: fileURL)
        audit.record(entry())
        waitForFile(fileURL)
        audit.archiveCurrent()

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, audit.archives().isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let archive = try XCTUnwrap(audit.archives().first)
        audit.removeArchive(archive)
        XCTAssertTrue(audit.archives().isEmpty)
    }

    @MainActor
    func testJSONExportIsValidJSON() throws {
        let audit = AuditLog(fileURL: fileURL)
        let text = audit.exportJSON([entry(), entry("/api/v2/version")])
        let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]]
        XCTAssertEqual(parsed?.count, 2)
        XCTAssertEqual(parsed?.first?["method"] as? String, "GET")
    }

    /// Masking happens on the way in, so an archive can never hold what the
    /// live view would have hidden.
    @MainActor
    func testSecretsAreMaskedBeforeAnythingIsStored() throws {
        SecretRegistry.shared.register("s3cret-token-value")
        defer { SecretRegistry.shared.forget("s3cret-token-value") }

        let audit = AuditLog(fileURL: fileURL)
        audit.record(AuditEntry(
            client: "cdbm_0123456789abcdef0123", method: "GET",
            path: "/api/v2/x?token=s3cret-token-value", operation: "get",
            access: .read, collection: nil, requestBytes: 0,
            responseStatus: 200, responseBytes: 0, durationSeconds: 0,
            note: "ключ s3cret-token-value отклонён"
        ))
        waitForFile(fileURL)

        let deadline = Date().addingTimeInterval(3)
        var text = ""
        while Date() < deadline {
            text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            if text.contains("•") { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(text.contains("s3cret-token-value"), text)
        XCTAssertFalse(text.contains("cdbm_0123456789abcdef0123"), text)
    }
}

// MARK: - B3: space and unfinished copies

final class BackupSafetyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeDatabase(bytes: Int = 4096) throws -> URL {
        let source = root.appendingPathComponent("db")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let data = Data(repeating: 0x41, count: bytes)
        try data.write(to: source.appendingPathComponent("chroma.sqlite3"))
        return source
    }

    func testTheSpaceCheckAsksForTheDatabasePlusHeadroom() throws {
        let source = try makeDatabase(bytes: 10_000)
        let service = BackupService(directory: root.appendingPathComponent("backups"))
        let check = service.spaceCheck(for: source)
        XCTAssertEqual(check.requiredBytes, 12_000, "размер базы плюс 20 %")
        XCTAssertGreaterThan(check.availableBytes, 0, "свободное место на томе должно определяться")
        XCTAssertTrue(check.fits)
    }

    /// The failure that B3 exists to prevent: a copy that dies half-way and
    /// looks like a restore point afterwards.
    func testAnUnfinishedCopyIsShownAsBrokenAndCannotBeRestored() throws {
        let source = try makeDatabase()
        let backups = root.appendingPathComponent("backups")
        let service = BackupService(directory: backups)
        let record = try service.backup(databaseAt: source, note: "тест")
        XCTAssertFalse(record.isIncomplete)

        // Simulate an interrupted copy by putting the marker back.
        FileManager.default.createFile(
            atPath: record.url.appendingPathComponent(BackupService.incompleteMarker).path,
            contents: Data("copy in progress\n".utf8)
        )
        let listed = try XCTUnwrap(service.list().first)
        XCTAssertTrue(listed.isIncomplete)

        XCTAssertThrowsError(try service.restore(listed, to: root.appendingPathComponent("restored"))) { error in
            guard case BackupError.incompleteBackup = error else {
                return XCTFail("ожидалась incompleteBackup, получено \(error)")
            }
        }
    }

    func testACompletedBackupLeavesNoMarkerBehind() throws {
        let source = try makeDatabase()
        let service = BackupService(directory: root.appendingPathComponent("backups"))
        let record = try service.backup(databaseAt: source, note: "тест")
        let marker = record.url.appendingPathComponent(BackupService.incompleteMarker)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testTheCopyIsCheckedFileByFile() throws {
        let source = try makeDatabase()
        try Data(repeating: 0x42, count: 100).write(to: source.appendingPathComponent("index.bin"))
        let service = BackupService(directory: root.appendingPathComponent("backups"))
        let record = try service.backup(databaseAt: source, note: "тест")

        let copied = try FileManager.default.contentsOfDirectory(atPath: record.url.path)
        XCTAssertTrue(copied.contains("chroma.sqlite3"))
        XCTAssertTrue(copied.contains("index.bin"))
    }

    func testTheErrorSaysBothNumbers() {
        let error = BackupError.notEnoughSpace(required: 42_000_000_000, available: 1_000_000_000, directory: "/tmp")
        let text = error.errorDescription ?? ""
        XCTAssertTrue(text.contains("42"), text)
        XCTAssertTrue(text.contains("/tmp"), text)
        XCTAssertNotNil(error.recoverySuggestion)
    }
}

// MARK: - B7: what a wipe promises

final class DataWipePlanTests: XCTestCase {
    func testThePlanNamesEveryPlaceTheAppWritesTo() {
        let plan = DataWipeService().plan()
        let details = plan.map(\.detail)
        XCTAssertTrue(details.contains(AppPaths.supportDirectory.path))
        XCTAssertTrue(details.contains(AppPaths.logsDirectory.path))
        XCTAssertTrue(details.contains(AppPaths.backupsDirectory.path))
        XCTAssertTrue(details.contains(DataWipeService.defaultsDomain))
    }

    /// Backups are the one thing here that may be irreplaceable, so they are
    /// the one thing that is opt-in.
    func testBackupsAreTheOnlyOptionalItem() {
        let plan = DataWipeService().plan()
        let optional = plan.filter(\.isOptional)
        XCTAssertEqual(optional.count, 1)
        XCTAssertEqual(optional.first?.detail, AppPaths.backupsDirectory.path)
    }

    /// The dialog promises the user's databases are safe; that promise is built
    /// from the same paths the app connects to.
    func testUserDatabasesAreListedAsUntouched() {
        let local = URL(fileURLWithPath: "/Users/tester/chroma_data")
        let profile = URL(fileURLWithPath: "/Volumes/Work/db")
        let untouched = DataWipeService().untouched(localDatabasePath: local, profilePaths: [profile])
        XCTAssertTrue(untouched.contains(local.path))
        XCTAssertTrue(untouched.contains(profile.path))
    }

    func testKeychainServicesAreListedInOnePlace() {
        XCTAssertTrue(KeychainStore.allServices.contains(KeychainStore().service))
        // Пароли документов лежат в своём сервисе — и «удалить всё» обязано
        // забрать и их. Пока этой строки не было, они переживали стирание.
        XCTAssertTrue(KeychainStore.allServices.contains(DocumentPasswordStore.service))
    }

    /// Ключ сертификата — запись класса «ключ», а не «пароль»: по сервису она
    /// не ищется и пережила бы стирание, если бы её не удаляли отдельно.
    func testTheProxyCertificateKeyIsWipedToo() throws {
        let tag = "io.github.chromadbmanager.tls"
        XCTAssertTrue(KeychainStore.allKeyTags.contains(tag))

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wipe-tls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = TLSCertificateService(file: directory.appendingPathComponent("certificate.der"))
        defer { service.remove() }
        do {
            _ = try service.issue(hosts: ["localhost"])
        } catch {
            throw XCTSkip("Keychain недоступен: \(error.localizedDescription)")
        }
        XCTAssertNoThrow(try service.identity(), "ключ есть, идентичность собирается")

        KeychainStore().removeAllAppItems()

        // Файл сертификата остался (он лежит в каталоге приложения и стирается
        // вместе с ним), но ключа больше нет — а значит и идентичности.
        XCTAssertThrowsError(try service.identity(), "после стирания ключ не должен находиться")
    }

    // MARK: - The engine goes with the data

    /// Both installation paths (2.4) live inside the directory being wiped, so
    /// the dialog has to say that the engine is going too.
    func testTheDialogSaysTheEngineWillBeUninstalled() {
        let venvOnly = try? XCTUnwrap(DataWipeService.engineNote(hasStandalone: false, hasVenv: true))
        XCTAssertTrue(venvOnly?.contains("venv") == true, venvOnly ?? "нет строки")
        XCTAssertTrue(venvOnly?.contains("установить заново") == true, venvOnly ?? "нет строки")

        let standaloneOnly = try? XCTUnwrap(DataWipeService.engineNote(hasStandalone: true, hasVenv: false))
        XCTAssertTrue(standaloneOnly?.contains("bin/chroma") == true, standaloneOnly ?? "нет строки")

        let both = try? XCTUnwrap(DataWipeService.engineNote(hasStandalone: true, hasVenv: true))
        XCTAssertTrue(both?.contains("venv") == true && both?.contains("bin/chroma") == true, both ?? "нет строки")
    }

    /// An engine installed by Homebrew or pipx is outside the wiped directory
    /// and survives, so the warning would be a lie.
    func testNothingIsSaidWhenTheEngineLivesElsewhere() {
        XCTAssertNil(DataWipeService.engineNote(hasStandalone: false, hasVenv: false))
    }

    func testTheWarningHangsOnTheItemThatCarriesTheEngine() {
        let plan = DataWipeService().plan()
        let carriers = plan.filter { $0.note != nil }
        XCTAssertTrue(
            carriers.allSatisfy { $0.detail == AppPaths.supportDirectory.path },
            "предупреждение о движке относится только к каталогу данных приложения"
        )
    }
}

// MARK: - Log markers

final class LogMarkerTests: XCTestCase {
    /// Plain glyphs, not emoji: the same string goes to the clipboard and into
    /// the log file, and colour carries the meaning on screen.
    func testEveryLevelHasAPlainGlyph() {
        let symbols = LogEntry.Level.allCases.map(\.symbol)
        XCTAssertEqual(symbols, ["·", "•", "✓", "!", "×"])
        for symbol in symbols {
            XCTAssertEqual(symbol.count, 1, "маркер — один символ, а не эмодзи-последовательность: \(symbol)")
            XCTAssertFalse(
                symbol.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 0x2600 },
                "в маркере не должно быть эмодзи: \(symbol)"
            )
        }
    }

    func testTheFormattedLineCarriesTheGlyph() {
        let entry = LogEntry(level: .success, category: "Тест", message: "готово")
        XCTAssertTrue(entry.formatted.contains("✓ [Тест] готово"), entry.formatted)
    }

    /// The file keeps the level as a word, so grepping a log does not depend on
    /// glyphs at all.
    func testTheFileLineStillNamesTheLevel() {
        let entry = LogEntry(level: .error, category: "Тест", message: "сломалось")
        XCTAssertTrue(entry.fileLine.contains("ERROR"), entry.fileLine)
    }
}
