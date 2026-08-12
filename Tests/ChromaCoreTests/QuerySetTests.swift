import XCTest
@testable import ChromaCore

/// §D1.1 — наборы запросов и эталон, который переживает смену стратегии.
final class QuerySetTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("query-sets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> QuerySetStore { QuerySetStore(directory: directory) }

    // MARK: - Эталон подстроками

    /// Главное свойство эталона-подстроки: он не зависит от того, как нарезан
    /// текст. Один и тот же абзац, разрезанный в другом месте, всё равно
    /// содержит фрагмент.
    func testAFragmentMatchesTheSamePassageCutDifferently() {
        let expectation = ExpectedFragment(fragment: "срок действия лицензии: бессрочная")

        let asOneChunk = "Программный комплекс 1 ALD Pro. Срок действия лицензии: бессрочная. Обновления 36 месяцев."
        let asAnotherChunk = "…комплекс 1 ALD Pro.\nСрок действия\nлицензии: бессрочная.\n"

        XCTAssertTrue(expectation.matches(asOneChunk))
        XCTAssertTrue(expectation.matches(asAnotherChunk), "перенос строки не должен ломать совпадение")
    }

    func testCaseAndAccentsDoNotMatter() {
        let expectation = ExpectedFragment(fragment: "ЁЛКА зелёная")
        XCTAssertTrue(expectation.matches("в лесу росла елка зеленая"))
    }

    func testAnEmptyFragmentMatchesNothing() {
        XCTAssertFalse(ExpectedFragment(fragment: "").matches("любой текст"))
        XCTAssertFalse(ExpectedFragment(fragment: "что-то").matches(nil))
    }

    // MARK: - Оценка результата

    func testTheStrongestMatchingGradeWins() {
        var query = EvaluationQuery(text: "лицензия")
        query.fragments = [
            ExpectedFragment(fragment: "бессрочная", grade: .partial),
            ExpectedFragment(fragment: "срок действия лицензии", grade: .relevant),
        ]
        XCTAssertEqual(
            query.grade(forDocument: "любой", text: "Срок действия лицензии: бессрочная."),
            .relevant
        )
    }

    /// Неразмеченный результат — это не «нерелевантен». Разница принципиальна:
    /// на ней стоит показатель покрытия разметки.
    func testAnUnmarkedResultHasNoGradeRatherThanAZero() {
        let query = EvaluationQuery(text: "лицензия", fragments: [ExpectedFragment(fragment: "бессрочная")])
        XCTAssertNil(query.grade(forDocument: "x", text: "совсем про другое"))
    }

    func testIDsAreConsultedWhenNoFragmentMatches() {
        var query = EvaluationQuery(text: "z")
        query.documents = [ExpectedDocument(id: "chunk-7", grade: .partial)]
        XCTAssertEqual(query.grade(forDocument: "chunk-7", text: "любой текст"), .partial)
        XCTAssertNil(query.grade(forDocument: "chunk-8", text: "любой текст"))
    }

    /// Полнота считается только там, где список релевантных полон, а полным
    /// его делают только идентификаторы: фрагменты говорят «это должно быть
    /// найдено», но никогда — «и больше ничего».
    func testRecallHasNoDenominatorWithFragmentsAlone() {
        var query = EvaluationQuery(text: "z", fragments: [ExpectedFragment(fragment: "а")])
        XCTAssertNil(query.knownRelevantCount)

        query.documents = [
            ExpectedDocument(id: "1", grade: .relevant),
            ExpectedDocument(id: "2", grade: .irrelevant),
        ]
        XCTAssertEqual(query.knownRelevantCount, 1)
    }

    // MARK: - Хранилище

    func testASetSurvivesReopening() {
        let saved = store().save(QuerySet(name: "приёмка", queries: [EvaluationQuery(text: "порядок приёмки")]))
        let reopened = store().set(id: saved.id)
        XCTAssertEqual(reopened?.name, "приёмка")
        XCTAssertEqual(reopened?.queries.first?.text, "порядок приёмки")
    }

    /// Правка запроса руками не должна стоить эталона: опечатка в тексте —
    /// не повод выбросить часы разметки.
    func testEditingTheTextOfAQueryKeepsItsGroundTruth() {
        let store = self.store()
        var set = store.save(QuerySet(name: "приёмка", queries: [EvaluationQuery(text: "порядок приёмик")]))
        let queryID = set.queries[0].id
        XCTAssertTrue(store.mark(
            queryID: queryID, in: set.id,
            documentID: "d1", text: "Порядок приёмки услуг описан в разделе 4.",
            grade: .relevant
        ))

        // Так правит карточка набора: меняет поля запроса и сохраняет набор.
        set = store.set(id: set.id)!
        set.queries[0].text = "порядок приёмки"
        set.queries[0].tags = ["приёмка", "услуги"]
        store.save(set)

        let reopened = QuerySetStore(directory: directory).set(id: set.id)
        XCTAssertEqual(reopened?.queries.first?.text, "порядок приёмки")
        XCTAssertEqual(reopened?.queries.first?.tags, ["приёмка", "услуги"])
        XCTAssertEqual(reopened?.queries.first?.fragments.count, 1)
        XCTAssertEqual(
            reopened?.queries.first?.grade(forDocument: "d1", text: "Порядок приёмки услуг описан в разделе 4."),
            .relevant
        )
    }

    /// `save` пишет набор целиком — значит устаревшая копия затирает разметку,
    /// сделанную после того, как копию сняли. Карточка набора поэтому
    /// перечитывает набор из хранилища перед записью; тест держит это свойство,
    /// показывая, чем оно оборачивается, если про него забыть.
    func testWritingAStaleCopyOfASetLosesGroundTruthMadeMeanwhile() {
        let store = self.store()
        let set = store.save(QuerySet(name: "набор", queries: [EvaluationQuery(text: "запрос")]))
        let staleCopy = set
        let queryID = set.queries[0].id

        // Разметка ушла в хранилище — в снятой копии её нет.
        XCTAssertTrue(store.mark(
            queryID: queryID, in: set.id, documentID: "d1",
            text: "Порядок приёмки услуг описан в разделе 4.", grade: .relevant
        ))
        XCTAssertTrue(staleCopy.queries[0].fragments.isEmpty)

        // Так делать нельзя — и вот что при этом теряется.
        store.save(staleCopy)
        XCTAssertTrue(store.set(id: set.id)?.queries[0].fragments.isEmpty == true)

        // А так — правильно: перечитать, поправить, записать.
        XCTAssertTrue(store.mark(
            queryID: queryID, in: set.id, documentID: "d1",
            text: "Порядок приёмки услуг описан в разделе 4.", grade: .relevant
        ))
        var fresh = store.set(id: set.id)!
        fresh.queries[0].text = "порядок приёмки"
        store.save(fresh)
        XCTAssertEqual(store.set(id: set.id)?.queries[0].fragments.count, 1)
    }

    /// Удалённый набор не возвращается после перезапуска — и не уносит с собой
    /// другие наборы.
    func testARemovedSetStaysRemoved() {
        let store = self.store()
        let kept = store.save(QuerySet(name: "оставить"))
        let doomed = store.save(QuerySet(name: "удалить"))
        store.remove(id: doomed.id)

        let reopened = QuerySetStore(directory: directory)
        XCTAssertNil(reopened.set(id: doomed.id))
        XCTAssertEqual(reopened.set(id: kept.id)?.name, "оставить")
    }

    /// Запрос, вписанный руками, — полноценный: его можно разметить так же,
    /// как пришедший из истории.
    func testAHandWrittenQueryCanBeMarkedLikeAnyOther() {
        let store = self.store()
        var set = store.save(QuerySet(name: "набор"))
        set.queries.append(EvaluationQuery(
            text: "сроки восстановления", tags: ["sla"], comment: "вписан руками"
        ))
        set = store.save(set)

        XCTAssertTrue(store.mark(
            queryID: set.queries[0].id, in: set.id,
            documentID: "d7", text: "Неисправность считается устранённой после проверки.",
            grade: .partial
        ))
        let reopened = QuerySetStore(directory: directory).set(id: set.id)
        XCTAssertEqual(reopened?.queries.first?.fragments.first?.grade, .partial)
        XCTAssertEqual(reopened?.markedQueryCount, 1)
    }

    func testASetIsNotTiedToACollection() {
        // У набора нет поля коллекции вовсе — прогнать его по клону обязано
        // быть возможным. Тест держит это свойство: добавление такого поля
        // сломает его.
        let data = try? store().exportData(QuerySet(name: "н"))
        let json = String(data: data ?? Data(), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("collection"), json)
    }

    func testAddingFromHistorySkipsWhatIsAlreadyThere() {
        let store = store()
        let set = store.save(QuerySet(name: "н"))
        let first = EvaluationQuery(text: "требования к серверу")
        XCTAssertEqual(store.add([first], to: set.id), 1)
        XCTAssertEqual(store.add([EvaluationQuery(text: "  требования к серверу ")], to: set.id), 0)
        XCTAssertEqual(store.set(id: set.id)?.queries.count, 1)
    }

    /// Тот же текст с другим фильтром — другой запрос, как и в истории.
    func testTheSameTextWithAnotherFilterIsAnotherQuery() {
        let store = store()
        let set = store.save(QuerySet(name: "н"))
        var filtered = EvaluationQuery(text: "текст")
        filtered.filter = DocumentFilter(conditions: [
            MetadataCondition(field: "page_number", op: .greater, value: "3"),
        ])
        XCTAssertEqual(store.add([EvaluationQuery(text: "текст")], to: set.id), 1)
        XCTAssertEqual(store.add([filtered], to: set.id), 1)
    }

    func testAHistoryEntryBecomesAQuery() {
        let entry = QueryHistoryEntry(
            text: "IOPS", collectionName: "заметки", profileName: "По умолчанию"
        )
        let query = EvaluationQuery(entry)
        XCTAssertEqual(query.text, "IOPS")
        XCTAssertTrue(query.comment.contains("заметки"))
    }

    // MARK: - Разметка

    func testMarkingWritesAFragmentOfTheFoundText() {
        let store = store()
        let query = EvaluationQuery(text: "лицензия")
        let set = store.save(QuerySet(name: "н", queries: [query]))

        XCTAssertTrue(store.mark(
            queryID: query.id, in: set.id, documentID: "chunk-1",
            text: "Срок действия лицензии: бессрочная. Обновления предоставляются 36 месяцев.",
            grade: .relevant
        ))

        let stored = store.set(id: set.id)?.queries.first
        XCTAssertEqual(stored?.fragments.count, 1)
        XCTAssertEqual(stored?.fragments.first?.grade, .relevant)
        XCTAssertTrue(stored?.fragments.first?.fragment.hasPrefix("Срок действия лицензии") == true)
        XCTAssertTrue(stored?.hasGroundTruth == true)
    }

    func testRemarkingTheSamePassageReplacesTheGrade() {
        let store = store()
        let query = EvaluationQuery(text: "л")
        let set = store.save(QuerySet(name: "н", queries: [query]))
        let text = "Срок действия лицензии: бессрочная. Обновления 36 месяцев."

        store.mark(queryID: query.id, in: set.id, documentID: "c1", text: text, grade: .relevant)
        store.mark(queryID: query.id, in: set.id, documentID: "c1", text: text, grade: .partial)

        let fragments = store.set(id: set.id)?.queries.first?.fragments ?? []
        XCTAssertEqual(fragments.count, 1, "второе мнение заменяет первое, а не копится рядом")
        XCTAssertEqual(fragments.first?.grade, .partial)
    }

    /// Результат без текста разметить всё равно можно — по идентификатору,
    /// с оговоркой, что он работает только внутри этой коллекции.
    func testAResultWithoutTextFallsBackToItsID() {
        let store = store()
        let query = EvaluationQuery(text: "л")
        let set = store.save(QuerySet(name: "н", queries: [query]))

        store.mark(queryID: query.id, in: set.id, documentID: "chunk-9", text: nil, grade: .relevant)

        XCTAssertEqual(store.set(id: set.id)?.queries.first?.documents.first?.id, "chunk-9")
    }

    /// Ошибочную отметку нужно уметь снять: неверный эталон хуже отсутствующего,
    /// потому что по нему считаются все последующие прогоны.
    func testAMistakenMarkCanBeTakenBack() {
        let store = store()
        let query = EvaluationQuery(text: "л")
        let set = store.save(QuerySet(name: "н", queries: [query]))
        let text = "Срок действия лицензии: бессрочная. Обновления 36 месяцев."

        store.mark(queryID: query.id, in: set.id, documentID: "c1", text: text, grade: .relevant)
        XCTAssertTrue(store.unmark(queryID: query.id, in: set.id, documentID: "c1", text: text))

        let stored = store.set(id: set.id)?.queries.first
        XCTAssertTrue(stored?.fragments.isEmpty ?? false)
        XCTAssertFalse(stored?.hasGroundTruth ?? true)
        // Снимать нечего — и это не ошибка, а «уже снято».
        XCTAssertFalse(store.unmark(queryID: query.id, in: set.id, documentID: "c1", text: text))
    }

    func testTakingBackAMarkGivenByIDWorksToo() {
        let store = store()
        let query = EvaluationQuery(text: "л")
        let set = store.save(QuerySet(name: "н", queries: [query]))

        store.mark(queryID: query.id, in: set.id, documentID: "chunk-9", text: nil, grade: .relevant)
        XCTAssertTrue(store.unmark(queryID: query.id, in: set.id, documentID: "chunk-9", text: nil))
        XCTAssertTrue(store.set(id: set.id)?.queries.first?.documents.isEmpty ?? false)
    }

    func testTheFragmentIsBoundedInLength() {
        let long = String(repeating: "слово ", count: 200)
        let fragment = QuerySetStore.fragment(from: long) ?? ""
        XCTAssertLessThanOrEqual(fragment.count, QuerySetStore.fragmentLength)
        XCTAssertFalse(fragment.contains("\n"))
    }

    // MARK: - Перенос

    func testASetTravelsThroughJSONAndArrivesWithNewIdentifiers() throws {
        let store = store()
        var query = EvaluationQuery(text: "запрос")
        query.fragments = [ExpectedFragment(fragment: "кусок текста", grade: .partial)]
        let original = store.save(QuerySet(name: "перенос", queries: [query]))

        let imported = try store.importing(try store.exportData(original))

        XCTAssertEqual(imported.name, "перенос")
        XCTAssertEqual(imported.queries.first?.fragments.first?.grade, .partial)
        XCTAssertNotEqual(imported.id, original.id, "импорт добавляет, а не перезаписывает")
        XCTAssertNotEqual(imported.queries.first?.id, original.queries.first?.id)
    }

    func testAFileFromANewerBuildIsAnEmptyListRatherThanACrash() throws {
        try Data("не json".utf8).write(to: directory.appendingPathComponent("query-sets.json"))
        XCTAssertTrue(store().all().isEmpty)
    }

    func testTheLineCountsQueriesAndGroundTruth() {
        var withTruth = EvaluationQuery(text: "а")
        withTruth.fragments = [ExpectedFragment(fragment: "ф")]
        let set = QuerySet(name: "н", queries: [withTruth, EvaluationQuery(text: "б")])
        XCTAssertEqual(set.line, "2 запроса, с эталоном 1")
    }
}
