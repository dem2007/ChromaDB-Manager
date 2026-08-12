import XCTest
@testable import ChromaCore

/// Golden tests for the filter tree.
///
/// Every expected string here was sent to a live 1.4.4 server first and gave
/// the documents it should; these tests keep the builder producing that
/// exact shape.
final class FilterTreeGoldenTests: XCTestCase {
    private func json(_ filter: DocumentFilter) -> String? { filter.whereJSONString() }

    private func condition(_ field: String, _ op: FilterOperator, _ value: String) -> FilterNode {
        .leaf(MetadataCondition(field: field, op: op, value: value))
    }

    func testEveryOperatorHasItsOwnShape() {
        let cases: [(FilterOperator, String, String)] = [
            (.equals, "сад", #"{"topic":{"$eq":"сад"}}"#),
            (.notEquals, "сад", #"{"topic":{"$ne":"сад"}}"#),
            (.greater, "3", #"{"topic":{"$gt":3}}"#),
            (.greaterOrEqual, "3", #"{"topic":{"$gte":3}}"#),
            (.less, "3", #"{"topic":{"$lt":3}}"#),
            (.lessOrEqual, "3", #"{"topic":{"$lte":3}}"#),
            (.inList, "a, b", #"{"topic":{"$in":["a","b"]}}"#),
            (.notInList, "a, b", #"{"topic":{"$nin":["a","b"]}}"#),
        ]
        for (op, value, expected) in cases {
            let filter = DocumentFilter(root: .group(.and, [condition("topic", op, value)]))
            XCTAssertEqual(json(filter), expected, "\(op.rawValue)")
        }
    }

    func testValuesKeepTheirType() {
        XCTAssertEqual(json(DocumentFilter(root: .group(.and, [condition("n", .equals, "42")]))), #"{"n":{"$eq":42}}"#)
        XCTAssertEqual(json(DocumentFilter(root: .group(.and, [condition("r", .equals, "1.5")]))), #"{"r":{"$eq":1.5}}"#)
        XCTAssertEqual(json(DocumentFilter(root: .group(.and, [condition("ok", .equals, "true")]))), #"{"ok":{"$eq":true}}"#)
        XCTAssertEqual(json(DocumentFilter(root: .group(.and, [condition("s", .equals, "42a")]))), #"{"s":{"$eq":"42a"}}"#)
    }

    /// A group of one is unwrapped: the JSON is shown to the user, and
    /// `{"$and":[x]}` reads worse than `x` for the same result.
    func testASingleConditionNeedsNoWrapper() {
        let filter = DocumentFilter(root: .group(.and, [condition("topic", .equals, "сад")]))
        XCTAssertEqual(json(filter), #"{"topic":{"$eq":"сад"}}"#)
    }

    func testTwoConditionsAreJoinedByTheGroupsLogic() {
        let and = DocumentFilter(root: .group(.and, [condition("topic", .equals, "сад"), condition("n", .greaterOrEqual, "5")]))
        XCTAssertEqual(json(and), #"{"$and":[{"topic":{"$eq":"сад"}},{"n":{"$gte":5}}]}"#)

        let or = DocumentFilter(root: .group(.or, [condition("topic", .equals, "физика"), condition("n", .less, "2")]))
        XCTAssertEqual(json(or), #"{"$or":[{"topic":{"$eq":"физика"}},{"n":{"$lt":2}}]}"#)
    }

    /// Two levels — the shape the interface can build and the server accepts.
    func testNestedGroups() {
        let filter = DocumentFilter(root: .group(.or, [
            .group(.and, [condition("topic", .equals, "сад"), condition("n", .equals, "1")]),
            condition("topic", .equals, "физика"),
        ]))
        XCTAssertEqual(
            json(filter),
            #"{"$or":[{"$and":[{"topic":{"$eq":"сад"}},{"n":{"$eq":1}}]},{"topic":{"$eq":"физика"}}]}"#
        )
    }

    /// Empty means «no parameter»: the server answers 400 to `{}`.
    func testAnEmptyFilterProducesNothingAtAll() throws {
        XCTAssertTrue(DocumentFilter().isEmpty)
        XCTAssertNil(try DocumentFilter().whereClause())
        XCTAssertNil(DocumentFilter().whereDocumentClause())

        let halfTyped = DocumentFilter(root: .group(.and, [condition("field", .equals, "")]))
        XCTAssertNil(try halfTyped.whereClause(), "недописанное условие не отправляется")
    }

    func testDocumentTextConditions() {
        var filter = DocumentFilter()
        filter.textConditions = [DocumentTextCondition(op: .contains, text: " кошек ")]
        XCTAssertEqual(filter.whereDocumentJSONString(), #"{"$contains":"кошек"}"#)

        filter.textConditions.append(DocumentTextCondition(op: .notContains, text: "черновик"))
        XCTAssertEqual(
            filter.whereDocumentJSONString(),
            #"{"$and":[{"$contains":"кошек"},{"$not_contains":"черновик"}]}"#
        )

        filter.textLogic = .or
        XCTAssertEqual(
            filter.whereDocumentJSONString(),
            #"{"$or":[{"$contains":"кошек"},{"$not_contains":"черновик"}]}"#
        )
    }

    func testRawJSONWins() throws {
        var filter = DocumentFilter(root: .group(.and, [condition("topic", .equals, "сад")]))
        filter.rawWhereJSON = #"{"n": {"$gt": 10}}"#
        let clause = try XCTUnwrap(try filter.whereClause())
        XCTAssertEqual(clause.keys.first, "n")
    }

    func testBrokenRawJSONIsRefusedBeforeSending() {
        var filter = DocumentFilter()
        filter.rawWhereJSON = "{не json"
        XCTAssertThrowsError(try filter.whereClause())
    }
}

final class FilterTreeParsingTests: XCTestCase {
    private func parse(_ text: String) -> FilterNode? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return FilterNode.parse(object)
    }

    func testRoundTripThroughJSONKeepsTheTree() throws {
        let original = DocumentFilter(root: .group(.or, [
            .group(.and, [
                .leaf(MetadataCondition(field: "topic", op: .equals, value: "сад")),
                .leaf(MetadataCondition(field: "n", op: .greaterOrEqual, value: "5")),
            ]),
            .leaf(MetadataCondition(field: "tag", op: .inList, value: "a, b")),
        ]))
        let text = try XCTUnwrap(original.whereJSONString())

        var reloaded = DocumentFilter()
        reloaded.rawWhereJSON = text
        XCTAssertTrue(reloaded.adoptRawWhereIntoTree())
        XCTAssertEqual(reloaded.whereJSONString(), text, "дерево → JSON → дерево должно давать тот же запрос")
        XCTAssertTrue(reloaded.rawWhereJSON.isEmpty, "после разбора сырой текст больше не нужен")
    }

    /// The shorthand the server also accepts.
    func testTheImplicitEqualsFormIsUnderstood() throws {
        let node = try XCTUnwrap(parse(#"{"topic": "сад"}"#))
        XCTAssertEqual(node.condition?.op, .equals)
        XCTAssertEqual(node.condition?.value, "сад")
    }

    /// A filter the editor cannot show must not be silently dropped: raw mode
    /// stays, and the query still runs.
    func testWhatCannotBeShownStaysRaw() {
        XCTAssertNil(parse(#"{"$not": {"topic": {"$eq": "сад"}}}"#), "неизвестный оператор")
        XCTAssertNil(parse(#"{"topic": {"$eq": "a", "$ne": "b"}}"#), "два оператора в одном объекте")
        XCTAssertNil(parse(#"{"a": {"$eq": 1}, "b": {"$eq": 2}}"#), "две пары верхнего уровня")

        var filter = DocumentFilter()
        filter.rawWhereJSON = #"{"$not": {"topic": {"$eq": "сад"}}}"#
        XCTAssertFalse(filter.adoptRawWhereIntoTree())
        XCTAssertFalse(filter.rawWhereJSON.isEmpty, "фильтр остаётся на месте")
    }

    func testSwitchingToJSONAndBackKeepsEverything() throws {
        var filter = DocumentFilter(root: .group(.and, [
            .leaf(MetadataCondition(field: "topic", op: .equals, value: "сад")),
        ]))
        filter.textConditions = [DocumentTextCondition(op: .notContains, text: "черновик")]
        let whereJSON = try XCTUnwrap(filter.whereJSONString())
        let textJSON = try XCTUnwrap(filter.whereDocumentJSONString())

        filter.moveTreeIntoRawJSON()
        XCTAssertEqual(filter.rawWhereJSON, whereJSON)
        XCTAssertEqual(filter.rawWhereDocumentJSON, textJSON)

        XCTAssertTrue(filter.adoptRawWhereIntoTree())
        XCTAssertTrue(filter.adoptRawWhereDocumentIntoTree())
        XCTAssertEqual(filter.whereJSONString(), whereJSON)
        XCTAssertEqual(filter.whereDocumentJSONString(), textJSON)
        XCTAssertEqual(filter.textConditions.first?.op, .notContains)
    }

    func testDocumentClausesParseBack() throws {
        var filter = DocumentFilter()
        filter.rawWhereDocumentJSON = #"{"$or":[{"$contains":"a"},{"$not_contains":"b"}]}"#
        XCTAssertTrue(filter.adoptRawWhereDocumentIntoTree())
        XCTAssertEqual(filter.textLogic, .or)
        XCTAssertEqual(filter.textConditions.count, 2)

        var deeper = DocumentFilter()
        deeper.rawWhereDocumentJSON = #"{"$or":[{"$and":[{"$contains":"a"}]},{"$contains":"b"}]}"#
        XCTAssertFalse(deeper.adoptRawWhereDocumentIntoTree(), "вложенность глубже одного уровня остаётся в JSON")
    }
}

final class FilterValidationTests: XCTestCase {
    /// The server answers 400 to `$gt` on anything but a number — including ISO
    /// dates, which are strings. Saying so with the field name beats
    /// «Invalid where clause».
    func testComparingAStringIsRefusedWithTheFieldNamed() {
        let filter = DocumentFilter(root: .group(.and, [
            .leaf(MetadataCondition(field: "date", op: .greater, value: "2024-05-01")),
        ]))
        let problem = filter.problems.first
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.contains("date") == true, problem ?? "")
        XCTAssertTrue(problem?.contains("числ") == true, problem ?? "")
    }

    func testComparingNumbersIsFine() {
        let filter = DocumentFilter(root: .group(.and, [
            .leaf(MetadataCondition(field: "n", op: .greater, value: "10")),
            .leaf(MetadataCondition(field: "r", op: .lessOrEqual, value: "1.5")),
        ]))
        XCTAssertTrue(filter.problems.isEmpty)
    }

    func testAListOfMixedTypesIsRefused() {
        let filter = DocumentFilter(root: .group(.and, [
            .leaf(MetadataCondition(field: "n", op: .inList, value: "1, сад")),
        ]))
        XCTAssertEqual(filter.problems.count, 1)
    }

    func testAHomogeneousListPasses() {
        let numbers = DocumentFilter(root: .group(.and, [
            .leaf(MetadataCondition(field: "n", op: .inList, value: "1, 2, 3")),
        ]))
        XCTAssertTrue(numbers.problems.isEmpty)

        let strings = DocumentFilter(root: .group(.and, [
            .leaf(MetadataCondition(field: "t", op: .notInList, value: "сад, физика")),
        ]))
        XCTAssertTrue(strings.problems.isEmpty)
    }

    func testProblemsAreFoundAtAnyDepth() {
        let filter = DocumentFilter(root: .group(.or, [
            .group(.and, [.leaf(MetadataCondition(field: "date", op: .less, value: "вчера"))]),
        ]))
        XCTAssertEqual(filter.problems.count, 1)
    }
}

final class SavedFilterStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-filters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A saved filter that does not survive a restart is not saved.
    func testFiltersSurviveANewStore() {
        let filter = DocumentFilter(root: .group(.and, [
            .leaf(MetadataCondition(field: "topic", op: .equals, value: "сад")),
        ]))
        SavedFilterStore(directory: directory).save(name: "Сад", filter: filter, collectionName: "notes")

        let reopened = SavedFilterStore(directory: directory)
        let saved = reopened.filters(for: "notes")
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.name, "Сад")
        XCTAssertEqual(saved.first?.filter.whereJSONString(), #"{"topic":{"$eq":"сад"}}"#)
    }

    func testFiltersAreKeptPerCollection() {
        let store = SavedFilterStore(directory: directory)
        store.save(name: "A", filter: DocumentFilter(documentContains: "a"), collectionName: "one")
        store.save(name: "B", filter: DocumentFilter(documentContains: "b"), collectionName: "two")

        XCTAssertEqual(store.filters(for: "one").map(\.name), ["A"])
        XCTAssertEqual(store.filters(for: "two").map(\.name), ["B"])
    }

    func testSavingUnderTheSameNameReplacesInsteadOfDuplicating() {
        let store = SavedFilterStore(directory: directory)
        store.save(name: "Один", filter: DocumentFilter(documentContains: "старое"), collectionName: "notes")
        store.save(name: "Один", filter: DocumentFilter(documentContains: "новое"), collectionName: "notes")

        let saved = store.filters(for: "notes")
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.filter.textConditions.first?.text, "новое")
    }

    func testRemoval() {
        let store = SavedFilterStore(directory: directory)
        let saved = store.save(name: "X", filter: DocumentFilter(documentContains: "x"), collectionName: "notes")
        store.remove(id: saved.id)
        XCTAssertTrue(store.filters(for: "notes").isEmpty)
    }
}
