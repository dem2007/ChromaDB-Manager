import XCTest
@testable import ChromaCore

/// Поля переписываются без пересчёта векторов.
///
/// Это главный ответ на вопрос «а что делать с уже проиндексированным»:
/// текст файлов не менялся — менялись подписи к нему, и звать ради этого
/// модель значит потратить половину суток там, где хватает минуты.
final class MetadataRefreshTests: XCTestCase {
    /// База, которая помнит, что ей велели сделать, и не умеет ничего лишнего.
    private actor RecordingDatabase: SyncDatabase {
        var updates: [(collectionID: String, updates: [DocumentUpdate])] = []
        var upserts = 0
        var failOn: String?

        func createCollection(name: String, metadata: ChromaMetadata?, configuration: CollectionConfiguration?, getOrCreate: Bool) async throws -> ChromaCollection {
            ChromaCollection(id: "id-\(name)", name: name, metadata: nil)
        }
        func resolveID(of name: String) async throws -> String { "id-\(name)" }
        func updateCollection(id: String, newName: String?, metadata: ChromaMetadata?) async throws {}
        func upsert(collectionID: String, records: [EmbeddedRecord]) async throws { upserts += 1 }
        func updateDocuments(collectionID: String, updates: [DocumentUpdate]) async throws {
            if let failOn, updates.contains(where: { $0.id.contains(failOn) }) {
                throw ExtractionError.empty
            }
            self.updates.append((collectionID, updates))
        }
        func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord] { [] }
        func embeddings(collectionID: String, ids: [String]) async throws -> [String: [Double]] { [:] }
        func deleteDocuments(collectionID: String, ids: [String]) async throws {}
        func deleteDocuments(collectionID: String, filter: DocumentFilter) async throws -> Int { 0 }

        func fail(on marker: String) { failOn = marker }
        var allUpdates: [DocumentUpdate] { updates.flatMap(\.updates) }
    }

    private var root: URL!
    private var manifests: ManifestStore!
    private var service: SourceSyncService!
    private let backup = BackupEvidence(record: nil, exportURL: nil, describedAs: "тестовый бэкап")

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cdbm-refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        manifests = ManifestStore(directory: root.appendingPathComponent("manifests"))
        service = SourceSyncService(
            manifests: manifests, journal: SyncJournal(directory: root.appendingPathComponent("journals"))
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func source(_ levels: [PathLevel], custom: [String: String] = [:]) -> DataSource {
        DataSource(
            name: "Системы", path: root.path, mapping: .folderToCollection,
            collectionName: "systems", pathLevels: levels, customMetadata: custom
        )
    }

    /// Манифест, записанный источником с этими настройками.
    private func fill(_ source: DataSource, paths: [String]) {
        var manifest = SourceManifest(sourceID: source.id)
        for path in paths {
            manifest.record(ManifestEntry(
                relativePath: path, contentHash: "h", fileHash: "b",
                modifiedAt: Date(timeIntervalSince1970: 1_000), size: 10,
                chunkIDs: ["\(path)-0", "\(path)-1"], collectionName: "systems",
                chunkingSignature: "sig", embeddingModel: "model",
                metadataSignature: source.metadataSignature
            ))
        }
        manifests.save(manifest)
    }

    // MARK: - Кого обновлять

    func testFilesWrittenWithTheSameSettingsAreLeftAlone() async {
        let source = self.source([PathLevel(key: "year", type: .integer)])
        fill(source, paths: ["2025/устав.md"])
        let outdated = await service.filesWithOutdatedMetadata(source: source)
        XCTAssertTrue(outdated.isEmpty)
        _ = outdated
    }

    func testChangingALevelMarksTheFiles() async {
        let before = source([PathLevel(key: "year", type: .integer)])
        fill(before, paths: ["2025/устав.md", "2026/акт.md"])
        var after = before
        after.pathLevels = [PathLevel(key: "year", type: .integer), PathLevel(key: "system")]
        let outdated = await service.filesWithOutdatedMetadata(source: after)
        XCTAssertEqual(outdated, ["2025/устав.md", "2026/акт.md"])
    }

    /// Запись прежней сборки подписи не имеет. Пока источник полями из пути
    /// не пользуется, обновлять нечего — иначе кнопка «обновить поля»
    /// появилась бы у каждого источника после первого же обновления приложения.
    func testEntriesWithoutASignatureAreSilentUntilLevelsExist() async {
        // (значения читаются до XCTAssert: актор внутри автозамыкания не живёт)
        var manifest = SourceManifest(sourceID: UUID())
        let plain = DataSource(name: "т", path: root.path, mapping: .folderToCollection, collectionName: "systems")
        manifest.record(ManifestEntry(
            relativePath: "устав.md", contentHash: "h", modifiedAt: Date(), size: 1,
            chunkIDs: ["x-0"], collectionName: "systems", chunkingSignature: "s", embeddingModel: "m"
        ))
        let silent = await service.filesWithOutdatedMetadata(in: manifest, source: plain)
        XCTAssertTrue(silent.isEmpty)

        var withLevels = plain
        withLevels.pathLevels = [PathLevel(key: "year", type: .integer)]
        let noticed = await service.filesWithOutdatedMetadata(in: manifest, source: withLevels)
        XCTAssertEqual(noticed, ["устав.md"])
    }

    // MARK: - Как обновляет

    /// Ни одного вектора: только `update` метаданных.
    func testFieldsAreRewrittenWithoutTouchingVectors() async throws {
        let before = source([PathLevel(key: "year", type: .integer)])
        fill(before, paths: ["2025/Система 1/устав.md"])
        var after = before
        after.pathLevels = [PathLevel(key: "year", type: .integer), PathLevel(key: "system")]

        let database = RecordingDatabase()
        let report = try await service.refreshMetadata(source: after, chroma: database, backup: backup)

        XCTAssertEqual(report.filesUpdated, 1)
        XCTAssertEqual(report.chunksUpdated, 2, "оба чанка файла")
        let upserts = await database.upserts
        XCTAssertEqual(upserts, 0, "модель не звалась и векторы не переписывались")

        let updates = await database.allUpdates
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates.first?.metadata?["year"], .int(2025))
        XCTAssertEqual(updates.first?.metadata?["system"], .string("Система 1"))
    }

    /// Поле, выброшенное из настроек, убирается явно: `update` у ChromaDB
    /// метаданные сливает, и оно осталось бы в базе навсегда.
    func testARemovedFieldIsDeletedExplicitly() async throws {
        let before = source([PathLevel(key: "year", type: .integer), PathLevel(key: "system")])
        fill(before, paths: ["2025/Система 1/устав.md"])
        var after = before
        after.pathLevels = [PathLevel(key: "year", type: .integer)]

        let database = RecordingDatabase()
        let report = try await service.refreshMetadata(source: after, chroma: database, backup: backup)

        XCTAssertEqual(report.keysRemoved, ["system"])
        let updates = await database.allUpdates
        XCTAssertEqual(updates.first?.removedMetadataKeys, ["system"])
        XCTAssertNil(updates.first?.metadata?["system"])
    }

    /// Файл, до которого уровень не достаёт, поля не получает — и старое
    /// значение у него тоже убирается, иначе в базе останется вчерашняя правда.
    func testAFileAboveTheLevelLosesTheField() async throws {
        let before = source([PathLevel(key: "year", type: .integer)])
        fill(before, paths: ["устав.md"])
        var after = before
        after.pathLevels = [PathLevel(key: "year", type: .integer), PathLevel(key: "system")]

        let database = RecordingDatabase()
        _ = try await service.refreshMetadata(source: after, chroma: database, backup: backup)

        let updates = await database.allUpdates
        XCTAssertEqual(updates.first?.removedMetadataKeys, ["system", "year"])
    }

    /// Обновлённый файл больше не в списке: подпись записана в манифест.
    func testTheManifestRemembersTheNewSignature() async throws {
        let before = source([PathLevel(key: "year", type: .integer)])
        fill(before, paths: ["2025/устав.md"])
        var after = before
        after.pathLevels = [PathLevel(key: "year", type: .integer), PathLevel(key: "system")]

        _ = try await service.refreshMetadata(source: after, chroma: RecordingDatabase(), backup: backup)
        let left = await service.filesWithOutdatedMetadata(source: after)
        XCTAssertTrue(left.isEmpty)
    }

    /// Один упавший файл не отменяет остальные — и попадает в отчёт с причиной.
    func testOneFailureDoesNotStopTheRest() async throws {
        let before = source([PathLevel(key: "year", type: .integer)])
        fill(before, paths: ["2025/устав.md", "2026/акт.md"])
        var after = before
        after.pathLevels = [PathLevel(key: "year", type: .integer), PathLevel(key: "system")]

        let database = RecordingDatabase()
        await database.fail(on: "акт")
        let report = try await service.refreshMetadata(source: after, chroma: database, backup: backup)

        XCTAssertEqual(report.filesUpdated, 1)
        XCTAssertEqual(report.failures.map(\.file), ["2026/акт.md"])
        // Упавший файл остаётся в списке — его никто не обновил.
        let left = await service.filesWithOutdatedMetadata(source: after)
        XCTAssertEqual(left, ["2026/акт.md"])
    }

    func testNothingToDoIsNotAnError() async throws {
        let source = self.source([PathLevel(key: "year", type: .integer)])
        fill(source, paths: ["2025/устав.md"])
        let report = try await service.refreshMetadata(source: source, chroma: RecordingDatabase(), backup: backup)
        XCTAssertTrue(report.isEmpty)
    }

    // MARK: - Подпись

    /// Ключ ручного поля человек вводит как хочет, и запятая в нём разобралась
    /// бы обратно как два чужих ключа — которые обновление полей послушно
    /// удалило бы из чанков всей коллекции.
    func testAKeyWithASeparatorSurvivesTheSignature() {
        let source = self.source([], custom: ["tag,note": "закупки", "plain": "да"])
        XCTAssertEqual(MetadataSignature.of(source).writtenKeys, ["tag,note", "plain"])
    }

    func testTheSignatureCarriesItsKeys() {
        let source = self.source(
            [PathLevel(key: "year", type: .integer), PathLevel(key: "")],
            custom: ["owner": "закупки"]
        )
        let signature = MetadataSignature.of(source)
        XCTAssertEqual(signature.writtenKeys, ["year", "owner"])
        XCTAssertTrue(MetadataSignature("").writtenKeys.isEmpty, "подписи нет — удалять по догадке нельзя")
    }
}
