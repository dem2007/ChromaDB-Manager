import XCTest
@testable import ChromaCore

/// Уровни вложенности папки — то, что показывается человеку до того, как он
/// начнёт их называть.
final class FolderLevelsTests: XCTestCase {
    private let corpus = [
        "2025/Система 1/устав.docx",
        "2025/Система 1/акт.pdf",
        "2025/Система 2/устав.docx",
        "2026/Система 1/устав.docx",
        "2026/Система 3/приказ.docx",
    ]

    func testLevelsAreCountedByDistinctFolderNames() {
        let levels = FolderLevels.of(paths: corpus)
        XCTAssertEqual(levels.depth, 2)
        XCTAssertEqual(levels.levels[0].folderCount, 2)
        XCTAssertEqual(levels.levels[0].examples, ["2025", "2026"])
        XCTAssertEqual(levels.levels[1].folderCount, 3, "«Система 1» из двух годов — одно имя")
        XCTAssertEqual(levels.levels[1].examples, ["Система 1", "Система 2", "Система 3"])
        XCTAssertEqual(levels.fileCount, 5)
    }

    /// Главное число для схемы коллекции: сколько файлов до уровня не достают.
    /// Ноль — поле будет у каждого чанка; больше нуля — надо сказать заранее.
    func testFilesAboveALevelAreCounted() {
        let levels = FolderLevels.of(paths: corpus + ["в корне.md", "2025/без системы.md"])
        XCTAssertEqual(levels.levels[0].filesAbove, 1, "файл в корне не достаёт до первого уровня")
        XCTAssertEqual(levels.levels[1].filesAbove, 2, "и файл прямо в «2025» — до второго")
    }

    /// Предпросмотр строится на настоящих путях: показать, что получится,
    /// на выдуманном «folder/file.txt» — значит показать не то.
    func testSamplesComeFromTheDeepestPaths() {
        let levels = FolderLevels.of(paths: ["в корне.md"] + corpus)
        XCTAssertEqual(levels.samplePaths.first?.split(separator: "/").count, 3)
        XCTAssertTrue(levels.samplePaths.allSatisfy { corpus.contains($0) || $0 == "в корне.md" })
    }

    /// Папка без подходящих файлов уровнем не является: её содержимое в базу
    /// не попадает, и спрашивать про неё значит спрашивать о том, чего не будет.
    func testAnEmptyBranchIsNotALevel() {
        let levels = FolderLevels.of(paths: ["2025/устав.docx"])
        XCTAssertEqual(levels.depth, 1)
    }

    func testAFlatFolderHasNoLevels() {
        let levels = FolderLevels.of(paths: ["устав.docx", "акт.pdf"])
        XCTAssertTrue(levels.isEmpty)
        XCTAssertEqual(levels.fileCount, 2)
    }

    func testNoFilesNoLevels() {
        XCTAssertTrue(FolderLevels.of(paths: []).isEmpty)
    }

    /// Дерево глубже, чем можно назвать: об этом надо знать — предел в восьми
    /// уровнях наш, а папки чужие.
    func testDeeperThanTheLimitIsReported() {
        let deep = (1...10).map { "f\($0)" }.joined(separator: "/") + "/файл.md"
        let levels = FolderLevels.of(paths: [deep])
        XCTAssertTrue(levels.deeperThanLimit)
        XCTAssertFalse(FolderLevels.of(paths: corpus).deeperThanLimit)
    }

    /// Один и тот же список путей обязан давать один и тот же ответ: редактор
    /// и синхронизация считают уровни одним кодом и не должны спорить.
    func testTheAnswerDoesNotDependOnOrder() {
        XCTAssertEqual(FolderLevels.of(paths: corpus), FolderLevels.of(paths: corpus.reversed()))
    }

    // MARK: - Через службу, на настоящей папке

    func testTheServiceCountsLevelsOfARealFolder() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-levels-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in corpus.filter({ $0.hasSuffix(".docx") }) {
            let file = root.appendingPathComponent(path.replacingOccurrences(of: ".docx", with: ".md"))
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try "текст".write(to: file, atomically: true, encoding: .utf8)
        }
        let source = DataSource(
            name: "Системы", path: root.path, fileExtensions: ["md"],
            mapping: .folderToCollection, collectionName: "systems"
        )
        let service = SourceSyncService(
            manifests: ManifestStore(directory: root.appendingPathComponent(".manifests")),
            journal: SyncJournal(directory: root.appendingPathComponent(".journals"))
        )

        let levels = try await service.folderLevels(source: source)
        XCTAssertEqual(levels.depth, 2)
        XCTAssertEqual(levels.levels[0].examples, ["2025", "2026"])
        XCTAssertEqual(levels.fileCount, 4)
    }
}
