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

/// Разделители нарезки и поле редактора.
@MainActor
final class SeparatorFieldTests: XCTestCase {
    /// Разделители по умолчанию переживают поле без потерь: прежде «. »
    /// становилось «.», а « » пропадал.
    func testTheDefaultsSurviveTheField() {
        let defaults = ChunkingConfiguration.defaultSeparators
        let text = SourcesViewModel.formatSeparators(defaults)
        XCTAssertEqual(SourcesViewModel.parseSeparators(text, fallback: []), defaults)
    }

    /// Пробел по краю разделителя виден: такой разделитель — в кавычках.
    func testASpacedSeparatorIsShownInQuotes() {
        XCTAssertEqual(SourcesViewModel.formatSeparators(ChunkingConfiguration.defaultSeparators),
                       #"\n\n | \n | ". " | " ""#)
    }

    /// Строку, перепечатанную так, как она выглядит, разбор понимает так же.
    func testWhatIsSeenIsWhatIsSaved() {
        XCTAssertEqual(SourcesViewModel.parseSeparators(#"\n\n | \n | ". " | " ""#, fallback: []),
                       ChunkingConfiguration.defaultSeparators)
    }

    func testTypedSeparatorsAreSplitOnTheBar() {
        XCTAssertEqual(SourcesViewModel.parseSeparators("a | b|c |d", fallback: []), ["a", "b", "c", "d"])
        XCTAssertEqual(SourcesViewModel.parseSeparators(#"\n\n | ; "#, fallback: []), ["\n\n", ";"],
                       "пробел без кавычек — от набора")
        XCTAssertEqual(SourcesViewModel.parseSeparators(#"\n\n | "; ""#, fallback: []), ["\n\n", "; "])
        XCTAssertEqual(SourcesViewModel.parseSeparators("  ", fallback: ["x"]), ["x"], "одни пробелы — поле пусто")
        XCTAssertEqual(SourcesViewModel.parseSeparators("", fallback: ["x"]), ["x"])
    }
}

/// Другой подключённый диск — вопрос, отключённый — нет.
@MainActor
final class VolumeMismatchPromptTests: XCTestCase {
    private let old = SourceVolume(uuid: "A", name: "Backup", mountPoint: "/Volumes/Backup")
    private let new = SourceVolume(uuid: "B", name: "Backup", mountPoint: "/Volumes/Backup")

    private func source(_ name: String, volume: SourceVolume?) -> DataSource {
        var source = DataSource(name: name, path: "/Volumes/Backup/\(name)", collectionName: name)
        source.volume = volume
        return source
    }

    func testOnlyAnotherMountedDiskIsAsked() {
        let docs = source("Документы", volume: old)
        let prompt = SourcesViewModel.VolumeMismatchPrompt(
            SyncError.volumeChanged(expected: "Backup", found: "Backup"), source: docs, volumeAt: { _ in self.new }
        )
        XCTAssertEqual(prompt?.found, new)
        XCTAssertNil(SourcesViewModel.VolumeMismatchPrompt(
            SyncError.volumeChanged(expected: "Backup", found: nil), source: docs, volumeAt: { _ in nil }
        ), "отключённый диск принимать нечего")
        XCTAssertNil(SourcesViewModel.VolumeMismatchPrompt(SyncError.noExtensions, source: docs, volumeAt: { _ in self.new }))
    }

    /// Два диска с одним именем — вопрос так и говорит, а не «Backup вместо
    /// Backup»; источники на том же диске названы числом.
    func testTheQuestionReadsWhenNamesCoincide() throws {
        let docs = source("Документы", volume: old)
        let photos = source("Фото", volume: old)
        let prompt = try XCTUnwrap(SourcesViewModel.VolumeMismatchPrompt(
            SyncError.volumeChanged(expected: "Backup", found: "Backup"), source: docs,
            among: [docs, photos], volumeAt: { _ in self.new }
        ))
        XCTAssertTrue(prompt.message.contains("другой диск с тем же именем"), prompt.message)
        XCTAssertEqual(prompt.alsoMoving, 1)
    }
}

/// Что делать с прогоном, упёршимся в диск.
@MainActor
final class VolumeQuestionTests: XCTestCase {
    private let old = SourceVolume(uuid: "A", name: "Backup")
    private let new = SourceVolume(uuid: "B", name: "Backup")
    private let other = SourceVolume(uuid: "C", name: "Archive")
    private let failure = SyncError.volumeChanged(expected: "Backup", found: "Backup")

    private func source(_ name: String, volume: SourceVolume?) -> DataSource {
        var source = DataSource(name: name, path: "/Volumes/Backup/\(name)", collectionName: name)
        source.volume = volume
        return source
    }

    private func question(
        _ snapshot: DataSource, settings: [DataSource], shown: SourcesViewModel.VolumeMismatchPrompt? = nil,
        at volume: SourceVolume?
    ) -> SourcesViewModel.VolumeQuestion {
        SourcesViewModel.volumeQuestion(failure, source: snapshot, sources: settings, shown: shown, volumeAt: { _ in volume })
    }

    func testAnotherMountedDiskIsAsked() {
        let docs = source("Документы", volume: old)
        guard case .ask(let prompt) = question(docs, settings: [docs], at: new) else { return XCTFail("вопрос не задан") }
        XCTAssertEqual(prompt.found, new)
    }

    /// Прогон начался до ответа и упёрся в прежний диск из своей копии —
    /// в настройках диск уже принят, и спрашивать второй раз не о чем.
    func testARunThatStartedBeforeTheAnswerIsNotAskedAgain() {
        let snapshot = source("Документы", volume: old)
        var settled = snapshot
        settled.volume = new
        XCTAssertEqual(question(snapshot, settings: [settled], at: new), .alreadySettled)
    }

    /// Показанный вопрос не подменяется: тот же диск — его ответ примет и
    /// этот источник, другой — строкой ошибки.
    func testTheShownQuestionIsNotReplaced() throws {
        let docs = source("Документы", volume: old)
        let photos = source("Фото", volume: old)
        guard case .ask(let shown) = question(docs, settings: [docs, photos], at: new) else { return XCTFail() }
        XCTAssertEqual(question(photos, settings: [docs, photos], shown: shown, at: new), .covered)
        let archive = source("Архив", volume: other)
        XCTAssertEqual(question(archive, settings: [docs, photos, archive], shown: shown, at: new), .asError)
    }

    func testOtherErrorsAreNotAboutTheDisk() {
        let docs = source("Документы", volume: old)
        XCTAssertEqual(SourcesViewModel.volumeQuestion(
            SyncError.noExtensions, source: docs, sources: [docs], shown: nil, volumeAt: { _ in self.new }
        ), .notAboutDisk)
        XCTAssertEqual(SourcesViewModel.volumeQuestion(
            SyncError.volumeChanged(expected: "Backup", found: nil), source: docs, sources: [docs], shown: nil,
            volumeAt: { _ in nil }
        ), .notAboutDisk, "отключённый диск принимать нечего")
    }
}

/// Разделители: одно правило пробела на оба направления.
@MainActor
final class SeparatorEdgeTests: XCTestCase {
    func testAnyKindOfSpaceAtTheEdgeIsQuoted() {
        let separators = [".\u{00A0}", "\u{202F}", "\t"]
        let text = SourcesViewModel.formatSeparators(separators)
        XCTAssertEqual(SourcesViewModel.parseSeparators(text, fallback: []), separators, text)
    }

    func testASeparatorInQuotesKeepsItsQuotes() {
        let separators = [#""x""#, #"""#, #""abc"#]
        let text = SourcesViewModel.formatSeparators(separators)
        XCTAssertEqual(SourcesViewModel.parseSeparators(text, fallback: []), separators, text)
    }
}
