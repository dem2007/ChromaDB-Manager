import XCTest
import ChromaCore
@testable import ChromaDBManagerApp

/// Разбор слоя экранов: то, что проверяется без окна.
@MainActor
final class ViewsReviewTests: XCTestCase {
    /// Правка одной заметки не переписывает тип остальных полей: строка
    /// «2023» остаётся строкой, индекс «01234» не теряет ноль, число — число.
    func testTheMetadataDraftKeepsFieldTypes() {
        var draft = MetadataDraft(metadata: [
            "sheet_name": .string("2023"),
            "zip": .string("01234"),
            "pages": .int(12),
            "note": .string("старая"),
        ])
        if let index = draft.rows.firstIndex(where: { $0.key == "note" }) {
            draft.rows[index].value = "новая"
        }
        if let index = draft.rows.firstIndex(where: { $0.key == "sheet_name" }) {
            draft.rows[index].value = "2024"
        }
        let saved = draft.metadata()
        XCTAssertEqual(saved["sheet_name"], .string("2024"), "строка осталась строкой и после правки")
        XCTAssertEqual(saved["zip"], .string("01234"))
        XCTAssertEqual(saved["pages"], .int(12))
        XCTAssertEqual(saved["note"], .string("новая"))

        // У нового поля тип по-прежнему угадывается.
        draft.addRow()
        draft.rows[draft.rows.count - 1].key = "year"
        draft.rows[draft.rows.count - 1].value = "2025"
        XCTAssertEqual(draft.metadata()["year"], .int(2025))
    }

    /// Слово подтверждения — на языке интерфейса, и русское принимается тоже.
    func testTheConfirmationWordFollowsTheInterface() {
        XCTAssertTrue(CollectionsViewModel.confirms("RESET", word: "RESET", russian: "СБРОС"))
        XCTAssertTrue(CollectionsViewModel.confirms("СБРОС ", word: "RESET", russian: "СБРОС"))
        XCTAssertFalse(CollectionsViewModel.confirms("reset", word: "RESET", russian: "СБРОС"))
    }

    /// Начало названия задачи берётся из того же шаблона, что само название:
    /// переведённое название обязано начинаться с переведённого начала.
    func testTaskTitlePrefixesComeFromTheSameTemplates() {
        let sync = String(localized: "Синхронизация «\("Документы")»")
        XCTAssertTrue(sync.hasPrefix(QueueMirror.TitlePrefix.sync), sync)
        XCTAssertFalse(QueueMirror.TitlePrefix.sync.isEmpty)
        let recompute = String(localized: "Пересчёт коллекции «\("база")»")
        XCTAssertTrue(recompute.hasPrefix(QueueMirror.TitlePrefix.recompute), recompute)
        let imported = String(localized: "Импорт в «\("база")»")
        XCTAssertTrue(imported.hasPrefix(QueueMirror.TitlePrefix.import), imported)
    }
}
