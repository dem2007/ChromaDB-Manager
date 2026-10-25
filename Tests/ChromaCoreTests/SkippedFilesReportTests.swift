import XCTest
@testable import ChromaCore

/// что по итогам прогона сказано о файлах, не взятых в базу.
final class SkippedFilesReportTests: XCTestCase {
    private var root: URL!
    private var service: SourceSyncService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("skipped-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        service = SourceSyncService(manifests: ManifestStore(directory: root.appendingPathComponent("manifests")))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var folder: URL { root.appendingPathComponent("docs") }

    private func put(_ name: String, _ data: Data) throws {
        try data.write(to: folder.appendingPathComponent(name))
    }

    /// Файлы не того расширения больше не пропадают молча: сосчитаны
    /// по расширениям, а неподдерживаемые форматы отделены от невыбранных.
    func testFilesOfOtherExtensionsAreCountedNotDropped() async throws {
        try put("договор.md", Data("Текст договора.".utf8))
        try put("скан1.jpg", Data([1, 2, 3]))
        try put("sub/скан2.jpg", Data([1, 2, 3]))
        try put("слайды.ppt", Data([1, 2, 3]))
        try put("заметки.txt", Data("Заметки.".utf8))
        try put("README", Data("без расширения".utf8))
        try put("~$договор.docx", Data([1]))
        try put(".скрытый.jpg", Data([1]))

        let source = DataSource(name: "d", path: folder.path, fileExtensions: ["md"], recursive: true, collectionName: "c")
        let plan = try await service.plan(source: source, embeddingModel: "m")
        XCTAssertEqual(plan.items.map(\.relativePath), ["договор.md"])
        XCTAssertEqual(plan.ignored.byExtension, ["jpg": 2, "ppt": 1, "txt": 1, "": 1])
        XCTAssertEqual(plan.ignored.unsupported.map(\.fileExtension), ["jpg", "", "ppt"])
        XCTAssertEqual(plan.ignored.notSelected.map(\.fileExtension), ["txt"])
        XCTAssertEqual(
            plan.ignored.line,
            "не взяты по расширению 5 файлов: формат не поддерживается — .jpg 2, без расширения 1, .ppt 1; не выбрано в источнике — .txt 1"
        )
    }

    /// Двоичное содержимое под `.txt` — не «пустой файл».
    func testABinaryTextFileIsNotCalledEmpty() async throws {
        try put("двоичный.txt", Data((0..<4000).map { UInt8($0 % 7) }))
        try put("пустой.txt", Data())
        let source = DataSource(name: "d", path: folder.path, fileExtensions: ["txt"], recursive: true, collectionName: "c")
        let plan = try await service.plan(source: source, embeddingModel: "m")
        let reasons = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.relativePath, $0.kind.detail ?? "") })
        XCTAssertEqual(reasons["двоичный.txt"], "файл не читается: двоичный файл, а не текст")
        XCTAssertEqual(reasons["пустой.txt"], "файл пустой")
    }

    /// Файл, которому правило не нашло коллекцию, попадает в диагностику —
    /// своим разрядом, с подсказкой поправить правило.
    func testAnUnroutableFileReachesDiagnostics() async throws {
        try put("отчёт.md", Data("Текст.".utf8))
        let source = DataSource(
            name: "d", path: folder.path, fileExtensions: ["md"], recursive: true,
            mapping: .manualRule, collectionName: "c", rulePattern: "^никогда/(.*)$", ruleTemplate: "$1"
        )
        let plan = try await service.plan(source: source, embeddingModel: "m")
        let problems = SourceSyncService.plannedProblems(of: plan)
        XCTAssertEqual(problems.map(\.relativePath), ["отчёт.md"])
        XCTAssertEqual(problems.first?.remedy, .fixRule)
        XCTAssertEqual(problems.first?.reason, "путь не подошёл под правило")
    }

    /// Число пропущенных — в самой строке итога, а не только жёлтым значком.
    func testTheSummaryLineNamesSkippedAndIgnoredFiles() {
        var summary = SyncSummary(
            sourceName: "d", added: 1, updated: 0, unchanged: 0, chunksWritten: 3, chunksDeleted: 0,
            skipped: [("битый.pdf", "PDF не открывается")], needsDecision: [], markedForAttention: [],
            collections: ["c"], duration: 1, embeddingModel: "m", dimension: 768
        )
        summary.ignored = IgnoredFiles(byExtension: ["zip": 2])
        XCTAssertTrue(summary.line.contains("пропущено файлов 1"), summary.line)
        XCTAssertTrue(summary.line.contains("не взяты по расширению 2 файла: формат не поддерживается — .zip 2"), summary.line)
        // Не взятые по расширению — не проблема прогона: уведомление о них
        // не тревожит.
        XCTAssertEqual(summary.notice.problems, ["пропущено файлов: 1"])
    }

    /// одинаковые причины — одной строкой, частые первыми, при
    /// равенстве — в порядке прогона.
    func testSkippedFilesAreGroupedByReason() {
        let summary = SyncSummary(
            sourceName: "docs", added: 0, updated: 0, unchanged: 0,
            chunksWritten: 0, chunksDeleted: 0,
            skipped: [
                ("a.pdf", "пароль"),
                ("b.xlsx → Лист1", "нет профиля"),
                ("c.xlsx → Лист1", "нет профиля"),
                ("d.doc", "пустой"),
            ],
            needsDecision: [], markedForAttention: [],
            collections: ["c"], duration: 1, embeddingModel: "m", dimension: nil
        )
        let groups = summary.skippedByReason
        XCTAssertEqual(groups.map(\.reason), ["нет профиля", "пароль", "пустой"])
        XCTAssertEqual(groups.first?.files, ["b.xlsx → Лист1", "c.xlsx → Лист1"])
    }
}
