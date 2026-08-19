import XCTest
@testable import ChromaCore

/// §E6 — every query that was run, kept locally.
final class QueryHistoryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store(limit: Int = QueryHistoryStore.defaultLimit) -> QueryHistoryStore {
        QueryHistoryStore(directory: directory, limit: limit)
    }

    private func entry(
        _ text: String, collection: String = "заметки", at: Date = Date(), results: Int = 5
    ) -> QueryHistoryEntry {
        QueryHistoryEntry(
            text: text, collectionName: collection, profileName: "По умолчанию",
            ranAt: at, resultCount: results, duration: 0.012
        )
    }

    // MARK: - Recording

    func testAQueryIsRemembered() {
        let store = store()
        store.record(entry("требования к оборудованию"))
        XCTAssertEqual(store.all().map(\.text), ["требования к оборудованию"])
    }

    /// A history where one query appears forty times is a history nobody
    /// scrolls.
    func testTheSameQueryTwiceIsOneEntry() {
        let store = store()
        store.record(entry("одно и то же", at: Date(timeIntervalSince1970: 1000)))
        store.record(entry("одно и то же", at: Date(timeIntervalSince1970: 2000), results: 9))
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(store.all().first?.resultCount, 9, "запись обновилась последним прогоном")
    }

    func testTheSameTextInAnotherCollectionIsAnotherEntry() {
        let store = store()
        store.record(entry("текст", collection: "заметки"))
        store.record(entry("текст", collection: "книги"))
        XCTAssertEqual(store.all().count, 2)
    }

    func testTheSameTextWithAnotherFilterIsAnotherEntry() {
        let store = store()
        var withFilter = entry("текст")
        withFilter.filter = DocumentFilter(conditions: [
            MetadataCondition(field: "page_number", op: .greater, value: "3"),
        ])
        store.record(entry("текст"))
        store.record(withFilter)
        XCTAssertEqual(store.all().count, 2, "фильтр — часть запроса, а не украшение")
    }

    func testAnEmptyQueryIsNotRecorded() {
        let store = store()
        store.record(entry("   "))
        XCTAssertTrue(store.all().isEmpty)
    }

    func testNewestComesFirst() {
        let store = store()
        store.record(entry("старый", at: Date(timeIntervalSince1970: 1000)))
        store.record(entry("новый", at: Date(timeIntervalSince1970: 2000)))
        XCTAssertEqual(store.all().map(\.text), ["новый", "старый"])
    }

    // MARK: - Pinning

    func testPinnedEntriesSortToTheTop() {
        let store = store()
        let old = store.record(entry("старый", at: Date(timeIntervalSince1970: 1000)))
        store.record(entry("новый", at: Date(timeIntervalSince1970: 2000)))
        store.setPinned(true, id: old.id)
        XCTAssertEqual(store.all().map(\.text), ["старый", "новый"])
    }

    func testRepeatingAPinnedQueryKeepsItPinned() {
        let store = store()
        let first = store.record(entry("важный", at: Date(timeIntervalSince1970: 1000)))
        store.setPinned(true, id: first.id)
        store.setChosenForEvaluation(true, id: first.id)

        store.record(entry("важный", at: Date(timeIntervalSince1970: 2000)))

        let stored = try? XCTUnwrap(store.all().first)
        XCTAssertEqual(stored?.isPinned, true)
        XCTAssertEqual(stored?.isChosenForEvaluation, true, "отметки пользователя переживают повтор")
    }

    // MARK: - Eviction

    func testTheOldestFallOffTheEnd() {
        let store = store(limit: 3)
        for index in 0..<5 {
            store.record(entry("запрос \(index)", at: Date(timeIntervalSince1970: Double(index))))
        }
        XCTAssertEqual(store.all().count, 3)
        XCTAssertEqual(Set(store.all().map(\.text)), ["запрос 2", "запрос 3", "запрос 4"])
    }

    /// Eviction is housekeeping. What the user deliberately kept is not
    /// housekeeping's to remove.
    func testPinnedAndChosenSurviveEviction() {
        let store = store(limit: 2)
        let first = store.record(entry("первый", at: Date(timeIntervalSince1970: 1)))
        let second = store.record(entry("второй", at: Date(timeIntervalSince1970: 2)))
        store.setPinned(true, id: first.id)
        store.setChosenForEvaluation(true, id: second.id)

        for index in 3..<8 {
            store.record(entry("новый \(index)", at: Date(timeIntervalSince1970: Double(index))))
        }

        let texts = Set(store.all().map(\.text))
        XCTAssertTrue(texts.contains("первый"))
        XCTAssertTrue(texts.contains("второй"))
    }

    // MARK: - Search over the history

    func testTheHistoryIsSearchable() {
        let store = store()
        store.record(entry("требования к оборудованию"))
        store.record(entry("порядок приёмки"))
        XCTAssertEqual(store.search("ОБОРУД").map(\.text), ["требования к оборудованию"])
        XCTAssertEqual(store.search("").count, 2)
    }

    func testSearchCanBeNarrowedToOneCollection() {
        let store = store()
        store.record(entry("текст", collection: "заметки"))
        store.record(entry("текст", collection: "книги"))
        XCTAssertEqual(store.search("текст", in: "книги").count, 1)
    }

    // MARK: - The query set for the evaluation stand

    func testMarkedQueriesAreCollectedForTheStand() {
        let store = store()
        let chosen = store.record(entry("важный вопрос"))
        store.record(entry("случайный"))
        store.setChosenForEvaluation(true, id: chosen.id)

        XCTAssertEqual(store.chosenForEvaluation().map(\.text), ["важный вопрос"])
        XCTAssertEqual(store.chosenForEvaluation(in: "книги").count, 0)
    }

    // MARK: - Clearing and persistence

    func testClearingIsPerCollectionWhenAsked() {
        let store = store()
        store.record(entry("а", collection: "заметки"))
        store.record(entry("б", collection: "книги"))
        store.clear(collectionName: "заметки")
        XCTAssertEqual(store.all().map(\.text), ["б"])
    }

    func testClearingEverythingLeavesNothing() {
        let store = store()
        store.record(entry("а"))
        store.record(entry("б"))
        store.clear()
        XCTAssertTrue(store.all().isEmpty)
    }

    func testTheHistorySurvivesReopening() {
        let first = store()
        let recorded = first.record(entry("переживёт перезапуск"))
        first.setPinned(true, id: recorded.id)

        let reopened = store()
        XCTAssertEqual(reopened.all().map(\.text), ["переживёт перезапуск"])
        XCTAssertEqual(reopened.all().first?.isPinned, true)
    }

    /// Dates are written one way and must be read the same way — a mismatch
    /// fails silently and answers «истории нет» — the shape the bug took.
    func testDatesSurviveTheRoundTrip() {
        let moment = Date(timeIntervalSince1970: 1_780_000_000)
        store().record(entry("когда-то", at: moment))
        let restored = store().all().first
        XCTAssertEqual(restored?.ranAt.timeIntervalSince1970 ?? 0, moment.timeIntervalSince1970, accuracy: 1)
    }

    func testAFileFromANewerBuildIsAnEmptyHistoryRatherThanACrash() throws {
        try Data("не json".utf8).write(to: directory.appendingPathComponent("query-history.json"))
        XCTAssertTrue(store().all().isEmpty)
    }

    // MARK: - What a row says

    func testTheLineNamesResultsTimeAndProfile() {
        var entry = self.entry("з", results: 7)
        entry.duration = 0.012
        XCTAssertEqual(entry.line, "7 результатов · 12 мс · профиль «По умолчанию»")
        entry.duration = 5.4
        XCTAssertEqual(entry.line, "7 результатов · 5.4 с · профиль «По умолчанию»")
    }
}
