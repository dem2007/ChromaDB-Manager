import XCTest
@testable import ChromaCore

/// группы расширений в редакторе источника.
final class ExtensionGroupTests: XCTestCase {
    /// Каждое поддерживаемое расширение — ровно в одной группе: забытое
    /// не появилось бы в редакторе вовсе, а повторённое отмечалось бы дважды.
    func testGroupsCoverEverySupportedExtensionOnce() {
        let grouped = ExtensionGroup.allCases.flatMap(\.extensions)
        XCTAssertEqual(grouped.count, Set(grouped).count, "расширение в двух группах")
        XCTAssertEqual(Set(grouped), Set(TextExtractor.supportedExtensions))
        XCTAssertNil(ExtensionGroup.of("log"))
        XCTAssertEqual(ExtensionGroup.of("pptx"), .presentations)
    }

    /// Один обход — и уровни, и счёт расширений, выбранных и нет.
    func testTheOverviewCountsEveryExtension() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("2024"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["2024/а.md", "2024/б.md", "2024/в.pdf", "г.ppt"] {
            try "текст".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let service = SourceSyncService(manifests: ManifestStore(directory: root.appendingPathComponent(".m")))
        let source = DataSource(name: "п", path: root.path, fileExtensions: ["md"], collectionName: "c")
        let overview = try await service.folderOverview(source: source)
        XCTAssertEqual(overview.extensionCounts["md"], 2)
        XCTAssertEqual(overview.extensionCounts["pdf"], 1)
        XCTAssertEqual(overview.extensionCounts["ppt"], 1)

        var none = source
        none.fileExtensions = []
        let empty = try await service.folderOverview(source: none)
        XCTAssertEqual(empty.extensionCounts["md"], 2, "без выбранных расширений счёт нужен тем более")
    }
}
