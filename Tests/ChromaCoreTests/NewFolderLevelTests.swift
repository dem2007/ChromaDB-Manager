import XCTest
@testable import ChromaCore

/// Уровень, появившийся в папке: замечен, назван человеком, не выдуман
/// приложением.
final class NewFolderLevelTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var manifests: ManifestStore!
    private var service: SourceSyncService!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cdbm-newlevel-\(UUID().uuidString)")
        folder = root.appendingPathComponent("Системы")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        manifests = ManifestStore(directory: root.appendingPathComponent("manifests"))
        service = SourceSyncService(
            manifests: manifests, journal: SyncJournal(directory: root.appendingPathComponent("journals"))
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String) throws {
        let file = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "текст".write(to: file, atomically: true, encoding: .utf8)
    }

    private func source(_ levels: [PathLevel]) -> DataSource {
        DataSource(
            name: "Системы", path: folder.path, fileExtensions: ["md"],
            mapping: .folderToCollection, collectionName: "systems", pathLevels: levels
        )
    }

    // MARK: - По списку путей

    func testALevelDeeperThanNamedIsReported() {
        let levels = FolderLevels.of(paths: ["2025/Система 1/договоры/акт.md"])
        let unnamed = levels.unnamed(beyond: 2)
        XCTAssertEqual(unnamed.map(\.number), [3])
        XCTAssertEqual(unnamed.first?.examples, ["договоры"])
    }

    /// Источник, который полями из пути не пользуется, молчит: подпапки есть
    /// у кого угодно, и предлагать их назвать каждому — это шум.
    func testASourceWithoutLevelsSaysNothing() {
        let levels = FolderLevels.of(paths: ["2025/Система 1/акт.md"])
        XCTAssertTrue(levels.unnamed(beyond: 0).isEmpty)
    }

    /// Пропущенный посередине уровень — решение человека («год не нужен»),
    /// и спорить с ним каждый прогон приложение не будет.
    func testAGapInTheMiddleIsNotReported() {
        let levels = FolderLevels.of(paths: ["2025/Система 1/акт.md"])
        XCTAssertTrue(levels.unnamed(beyond: 2).isEmpty)
    }

    func testNothingDeeperMeansNothingToSay() {
        let levels = FolderLevels.of(paths: ["2025/Система 1/акт.md"])
        XCTAssertTrue(levels.unnamed(beyond: 2).isEmpty)
    }

    // MARK: - В плане и в манифесте

    /// План замечает уровень тем же обходом, что уже сделал: отдельной
    /// прогулки по папке это не стоит.
    func testThePlanNoticesTheNewLevel() async throws {
        try write("2025/Система 1/договоры/акт.md")
        let plan = try await service.plan(
            source: source([PathLevel(key: "year", type: .integer), PathLevel(key: "system")]),
            embeddingModel: "test-model"
        )
        XCTAssertEqual(plan.newFolderLevels.map(\.number), [3])
    }

    func testThePlanIsSilentWhenEveryLevelIsNamed() async throws {
        try write("2025/Система 1/акт.md")
        let plan = try await service.plan(
            source: source([PathLevel(key: "year", type: .integer), PathLevel(key: "system")]),
            embeddingModel: "test-model"
        )
        XCTAssertTrue(plan.newFolderLevels.isEmpty)
    }

    /// Сводка говорит об этом словами — и не превращает в работу.
    func testTheSummaryLineNamesTheLevel() async throws {
        try write("2025/Система 1/договоры/акт.md")
        let plan = try await service.plan(
            source: source([PathLevel(key: "year", type: .integer), PathLevel(key: "system")]),
            embeddingModel: "test-model"
        )
        var summary = SyncSummary(
            sourceName: "Системы", added: 0, updated: 0, unchanged: 1,
            chunksWritten: 0, chunksDeleted: 0, skipped: [], needsDecision: [],
            markedForAttention: [], collections: [], duration: 0,
            embeddingModel: "test-model", dimension: nil
        )
        summary.newFolderLevels = plan.newFolderLevels

        let line = try XCTUnwrap(summary.newFolderLevelsLine)
        XCTAssertTrue(line.contains("3"), line)
        XCTAssertTrue(line.contains("договоры"), line)
        XCTAssertTrue(summary.line.contains("уровень вложенности"), summary.line)
    }
}
