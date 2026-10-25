import XCTest
import ChromaCore
@testable import ChromaDBManagerApp

/// Окно копии источника: нарезка копии — её собственная, папка
/// меняется без чужих исключений.
@MainActor
final class SourceCopyEditorTests: XCTestCase {
    private func original() -> DataSource {
        var source = DataSource(
            name: "base2_docs_4b", path: "/tmp/База 2", mapping: .folderToCollection,
            collectionName: "base2_docs_4b",
            chunking: ChunkingConfiguration(strategy: .adaptive, contextPrefix: true, baseChunkSize: 2048)
        )
        source.excludedPaths = ["Документ/Приложение.docx"]
        source.tableProfileAssignments = ["Документ/ФЭО.xlsx": UUID()]
        return source
    }

    /// Сменили у копии стратегию — остальная нарезка осталась оригинальной:
    /// умолчание стратегии заменило бы её целиком, вместе с контекстом в
    /// вектор, и копия отличалась бы от оригинала не одним параметром.
    func testSwitchingStrategyKeepsTheCopiedChunking() {
        let model = SourcesViewModel()
        let app = AppEnvironment()
        model.beginCopying(original(), app: app)
        model.draft?.chunking.strategy = .recursive
        model.chunkingStrategyChanged(to: .recursive, app: app)
        XCTAssertEqual(model.draft?.chunking.strategy, .recursive)
        XCTAssertEqual(model.draft?.chunking.contextPrefix, true)
        XCTAssertEqual(model.draft?.chunking.baseChunkSize, 2048)
    }

    /// Другая папка — исключённые файлы и профили файлов прежней папки
    /// уходят: в новой они назвали бы чужие файлы с теми же путями.
    func testAnotherFolderDropsTheOriginalsFileExclusions() {
        let model = SourcesViewModel()
        model.beginCopying(original(), app: AppEnvironment())
        model.setDraftFolder("/tmp/База 2")
        XCTAssertEqual(model.draft?.excludedPaths, ["Документ/Приложение.docx"], "та же папка — исключения те же")
        model.setDraftFolder("/tmp/База 3")
        XCTAssertEqual(model.draft?.excludedPaths, [])
        XCTAssertEqual(model.draft?.tableProfileAssignments, [:])
        XCTAssertEqual(model.draft?.path, "/tmp/База 3")
    }
}
