import XCTest
@testable import ChromaCore

/// Разбор ревью redesign-native: что видит после обновления то, что записали
/// прежние сборки, — отпечатки файлов, имена коллекций, копии базы.
final class UpgradeCompatibilityTests: XCTestCase {
    private let sourceID = UUID(uuidString: "00000000-0000-0000-0000-0000000000CD")!

    // MARK: - Отпечаток файла

    /// Чанк прежней сборки: источник в метаданных есть, отпечаток — от одного
    /// пути. Уборки он не требует: на этом же отпечатке построены его id.
    func testALegacyFingerprintWithASourceNeedsNoRepair() {
        let path = "docs/readme.md"
        let legacy: ChromaMetadata = [
            "source_id": .string(sourceID.uuidString),
            "source_file": .string(path),
            "file_id": .string(SourceSyncService.fileFingerprint(path, sourceID: nil)),
        ]
        XCTAssertFalse(FilePathRepair.needsRepair(legacy))

        var current = legacy
        current["file_id"] = .string(SourceSyncService.fileFingerprint(path, sourceID: sourceID))
        XCTAssertFalse(FilePathRepair.needsRepair(current))

        var broken = legacy
        broken["file_id"] = .string("0000000000000000")
        XCTAssertTrue(FilePathRepair.needsRepair(broken))
    }

    // MARK: - Имена коллекций

    private func source(transliterates: Bool) -> DataSource {
        DataSource(
            name: "Архив", path: "/tmp/Архив", mapping: .subfoldersToCollections,
            collectionName: "archive", transliteratesCollectionNames: transliterates
        )
    }

    /// Новый источник раскладывает кириллические подпапки по разным
    /// коллекциям; источник прежней сборки — туда же, куда раньше.
    func testOnlyNewSourcesTransliterateSubfolderNames() {
        let router = CollectionRouter()
        XCTAssertEqual(
            router.route(relativePath: "Договоры/a.md", source: source(transliterates: true)).route?.collectionName,
            "Dogovory"
        )
        XCTAssertEqual(
            router.route(relativePath: "Договоры/a.md", source: source(transliterates: false)).route?.collectionName,
            CollectionNaming.sanitize("Договоры", transliterating: false)
        )
    }

    /// Источник, записанный до настройки, читается с прежним правилом.
    func testASourceSavedBeforeTheSettingKeepsTheOldRule() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(source(transliterates: true))) as! [String: Any]
        json.removeValue(forKey: "transliteratesCollectionNames")
        let decoded = try JSONDecoder().decode(DataSource.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(decoded.transliteratesCollectionNames)
    }

    // MARK: - Копии базы

    /// Две копии в одну секунду — две папки, и первая остаётся годной.
    func testTwoBackupsInOneSecondDoNotShareAFolder() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-backup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("chroma")
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        try Data("sqlite".utf8).write(to: database.appendingPathComponent("chroma.sqlite3"))

        let service = BackupService(directory: root.appendingPathComponent("backups"))
        let first = try service.backup(databaseAt: database)
        let second = try service.backup(databaseAt: database)
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertTrue(service.list().allSatisfy { !$0.isIncomplete }, "\(service.list())")
    }
}
