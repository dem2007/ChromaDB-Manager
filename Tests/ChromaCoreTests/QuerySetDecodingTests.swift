import XCTest
@testable import ChromaCore

/// Разбор набора запросов терпим к недостающим полям.
///
/// Живой случай: набор, дописанный в файл без `tags`, `comment`, `documents`,
/// `note` и дат, дал «Не удалось прочитать данные, так как они отсутствуют» —
/// и экран остался **без единого набора**, включая те, что несут ручную
/// разметку. Один пропущенный ключ стоил всей работы человека.
final class QuerySetDecodingTests: XCTestCase {

    private func decoded<T: Decodable>(_ json: String, as type: T.Type = T.self) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(json.utf8))
    }

    // MARK: - Чего может не быть

    func testAQueryWithoutTheOptionalFieldsStillDecodes() throws {
        let query: EvaluationQuery = try decoded("""
        {"id":"\(UUID().uuidString)","text":"сервер"}
        """)
        XCTAssertEqual(query.text, "сервер")
        XCTAssertEqual(query.tags, [])
        XCTAssertEqual(query.comment, "")
        XCTAssertTrue(query.fragments.isEmpty)
        XCTAssertTrue(query.documents.isEmpty)
        XCTAssertNil(query.filter)
    }

    func testASetWithoutNoteAndDatesStillDecodes() throws {
        let set: QuerySet = try decoded("""
        {"id":"\(UUID().uuidString)","name":"набор",
         "queries":[{"id":"\(UUID().uuidString)","text":"сервер"}]}
        """)
        XCTAssertEqual(set.name, "набор")
        XCTAssertEqual(set.note, "")
        XCTAssertEqual(set.queries.count, 1)
        XCTAssertEqual(set.updatedAt, set.createdAt, "без обеих дат они совпадают")
    }

    /// Набор без единого запроса — это пустой набор, а не испорченный файл.
    func testASetWithoutQueriesIsEmptyRatherThanBroken() throws {
        let set: QuerySet = try decoded("""
        {"id":"\(UUID().uuidString)","name":"пустой"}
        """)
        XCTAssertTrue(set.queries.isEmpty)
    }

    /// Один неполный набор не должен утаскивать за собой остальные — ради
    /// этого всё и делалось: в соседних наборах лежит разметка.
    func testAnIncompleteSetDoesNotTakeTheMarkedOnesWithIt() throws {
        let sets: [QuerySet] = try decoded("""
        [{"id":"\(UUID().uuidString)","name":"с разметкой","note":"","createdAt":"2026-08-01T00:00:00Z",
          "updatedAt":"2026-08-01T00:00:00Z","queries":[{"id":"\(UUID().uuidString)","text":"запрос",
          "tags":[],"comment":"","documents":[],
          "fragments":[{"id":"\(UUID().uuidString)","fragment":"ответ","grade":"relevant"}]}]},
         {"id":"\(UUID().uuidString)","name":"дописанный руками","queries":[]}]
        """)
        XCTAssertEqual(sets.count, 2)
        XCTAssertEqual(sets[0].markedQueryCount, 1, "разметка соседа уцелела")
        XCTAssertEqual(sets[1].name, "дописанный руками")
    }

    // MARK: - Чего не может не быть

    /// Запрос без текста — не запрос. Пустая строка вместо него спрятала бы
    /// испорченный файл вместо того, чтобы о нём сказать.
    func testAQueryWithoutTextIsStillAnError() {
        XCTAssertThrowsError(try decoded("{\"id\":\"\(UUID().uuidString)\"}", as: EvaluationQuery.self))
    }

    func testASetWithoutNameIsStillAnError() {
        XCTAssertThrowsError(try decoded("{\"id\":\"\(UUID().uuidString)\"}", as: QuerySet.self))
    }

    /// Полный файл читается как прежде — терпимость не должна ничего терять.
    func testAFullyWrittenSetKeepsEveryField() throws {
        let stamp = "2026-08-19T16:48:30Z"
        let set: QuerySet = try decoded("""
        {"id":"\(UUID().uuidString)","name":"полный","note":"заметка",
         "createdAt":"\(stamp)","updatedAt":"\(stamp)",
         "queries":[{"id":"\(UUID().uuidString)","text":"сервер","tags":["а"],"comment":"к",
         "fragments":[],"documents":[]}]}
        """)
        XCTAssertEqual(set.note, "заметка")
        XCTAssertEqual(set.queries[0].tags, ["а"])
        XCTAssertEqual(set.queries[0].comment, "к")
        XCTAssertEqual(ISO8601DateFormatter().string(from: set.createdAt), stamp)
    }
}
