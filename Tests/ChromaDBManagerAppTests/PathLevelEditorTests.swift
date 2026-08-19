import XCTest
import ChromaCore
@testable import ChromaDBManagerApp

/// Редактор полей из пути: что он не даёт сохранить и что подгоняет сам
///.
@MainActor
final class PathLevelEditorTests: XCTestCase {
    private func model(levels: [PathLevel], metadata: [SourcesViewModel.MetadataRow] = []) -> SourcesViewModel {
        let model = SourcesViewModel()
        model.beginEditing(
            DataSource(
                name: "Системы", path: "/tmp/Системы", mapping: .folderToCollection,
                collectionName: "systems", pathLevels: levels
            )
        )
        if !metadata.isEmpty { model.draftMetadataRows = metadata }
        return model
    }

    // MARK: - Что не даёт сохранить

    func testAGoodSetOfLevelsHasNoProblem() {
        XCTAssertNil(model(levels: [PathLevel(key: "year", type: .integer), PathLevel(key: "system")]).pathLevelProblem)
    }

    func testACyrillicKeyIsRefused() {
        let problem = model(levels: [PathLevel(key: "год")]).pathLevelProblem
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.contains("Уровень 1") == true, "человеку сказано, какой именно уровень")
    }

    /// Два уровня с одним ключом: второй затёр бы первый, и «год» стал бы
    /// названием системы.
    func testTwoLevelsWithOneKeyAreRefused() {
        XCTAssertNotNil(model(levels: [PathLevel(key: "code"), PathLevel(key: "code")]).pathLevelProblem)
    }

    /// Ручные метаданные источника пишутся **после** полей из пути и молча
    /// затирают их. Тихо — это хуже, чем отказ.
    func testAClashWithSourceMetadataIsRefused() {
        let clashing = model(
            levels: [PathLevel(key: "year", type: .integer)],
            metadata: [SourcesViewModel.MetadataRow(key: "year", value: "2020")]
        )
        XCTAssertNotNil(clashing.pathLevelProblem)
    }

    func testABrokenFallbackIsRefused() {
        XCTAssertNotNil(
            model(levels: [PathLevel(key: "year", type: .integer, fallbackValue: "давно")]).pathLevelProblem
        )
        XCTAssertNil(
            model(levels: [PathLevel(key: "year", type: .integer, fallbackValue: "0")]).pathLevelProblem
        )
    }

    /// Безымянный уровень — это «не назвали», а не ошибка: между названными
    /// уровнями он занимает своё место в нумерации.
    func testAnUnnamedLevelIsNotAProblem() {
        XCTAssertNil(model(levels: [PathLevel(), PathLevel(key: "system")]).pathLevelProblem)
    }

    // MARK: - Строки уровней

    /// Строк ровно столько, сколько уровней в папке.
    func testRowsFollowTheFolderDepth() {
        let model = self.model(levels: [])
        model.draftFolderLevels = FolderLevels.of(paths: ["2025/Система 1/устав.md"])
        model.alignDraftLevels()
        XCTAssertEqual(model.draft?.pathLevels.count, 2)
    }

    /// Названный уровень не исчезает оттого, что папка сейчас мельче: поле
    /// уже есть в базе, и молча выбросить его нельзя.
    func testANamedLevelSurvivesAShallowerFolder() {
        let model = self.model(levels: [PathLevel(key: "year"), PathLevel(key: "system")])
        model.draftFolderLevels = FolderLevels.of(paths: ["устав.md"])
        model.alignDraftLevels()
        XCTAssertEqual(model.draft?.pathLevels.map { $0.trimmedKey }, ["year", "system"])
    }

    /// А безымянный хвост подрезается: пустые строки на экране не нужны.
    func testUnnamedTailIsTrimmed() {
        let model = self.model(levels: [PathLevel(key: "year"), PathLevel(), PathLevel()])
        model.draftFolderLevels = FolderLevels.of(paths: ["2025/устав.md"])
        model.alignDraftLevels()
        XCTAssertEqual(model.draft?.pathLevels.count, 1)
    }

    func testRowsNeverExceedTheLimit() {
        let model = self.model(levels: [])
        let deep = (1...12).map { "f\($0)" }.joined(separator: "/") + "/файл.md"
        model.draftFolderLevels = FolderLevels.of(paths: [deep])
        model.alignDraftLevels()
        XCTAssertEqual(model.draft?.pathLevels.count, PathLevel.maximumLevels)
    }
}
