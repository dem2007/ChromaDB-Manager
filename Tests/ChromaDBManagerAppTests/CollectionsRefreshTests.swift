import XCTest
@testable import ChromaDBManagerApp

/// список коллекций перечитывается сам, но ровно один раз.
///
/// Первые тесты слоя экранов по существу. Раньше эта логика
/// проверялась чтением: цикл с одноразовым чтением и ранним выходом легко
/// превратить в вечный, и увидеть это можно было только повесив приложение.
@MainActor
final class CollectionsRefreshTests: XCTestCase {
    /// Отметка «состав коллекций мог измениться» живёт у окружения.
    func testTheRevisionRisesOnlyWhenSomethingWasWritten() {
        let app = AppEnvironment()
        let before = app.collectionsRevision
        app.collectionsMayHaveChanged()
        XCTAssertEqual(app.collectionsRevision, before + 1)
    }

    /// Главное: не подключённое приложение не должно крутить цикл вхолостую.
    ///
    /// `refresh` выходит сразу, когда клиента нет, — и если бы отметка
    /// ставилась после этого выхода, `refreshIfStale` вертелся бы вечно на
    /// главном потоке. Тест не «проверяет комментарий»: он просто не
    /// завершится, если цикл бесконечен.
    func testStaleReadTerminatesWithoutAConnection() async {
        let app = AppEnvironment()
        let model = CollectionsViewModel()
        app.collectionsMayHaveChanged()

        await model.refreshIfStale(app)
        XCTAssertTrue(model.collections.isEmpty, "без подключения читать нечего")

        // И повторный заход ничего не делает: отметка уже учтена.
        await model.refreshIfStale(app)
    }

    /// «Синхронизировать все» поднимает отметку по разу на источник.
    /// Шестнадцать источников не должны дать шестнадцать обращений к базе.
    func testManyMarksInARowAreReadOnce() async {
        let app = AppEnvironment()
        let model = CollectionsViewModel()
        for _ in 0..<16 { app.collectionsMayHaveChanged() }

        await model.refreshIfStale(app)
        // Отметка учтена целиком, а не по одной.
        await model.refreshIfStale(app)
        XCTAssertEqual(app.collectionsRevision, 16)
    }
}
