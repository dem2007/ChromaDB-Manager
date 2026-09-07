import XCTest
@testable import ChromaCore

/// Фильтр агента проверяется до отправки в базу.
///
/// Разбор журнала: 28 августа агент трижды подряд послал
/// `{"heading_path": {"$regex": "1.1 Предмет закупки"}}` и трижды получил от
/// ChromaDB «Invalid where clause» — без имени поля, без имени оператора,
/// без единой подсказки, что чинить. Исправить такой отказ агент не может,
/// поэтому и повторил его дословно.
final class MCPFilterOperatorTests: XCTestCase {

    private func outcome(_ filter: JSONValue) -> Result<DocumentFilter?, JSONRPCError> {
        MCPToolService.filterForTesting(JSONValue.object(["filter": filter]))
    }

    private func refusal(_ filter: JSONValue, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard case .failure(let error) = outcome(filter) else {
            XCTFail("оператор должен быть отклонён здесь, а не в базе", file: file, line: line)
            return ""
        }
        return error.message
    }

    // MARK: - Отказ вместо чужого «Invalid where clause»

    func testRegexIsRefusedByNameWithWhatToUseInstead() {
        let message = refusal(.object(["heading_path": .object(["$regex": .string("1.1")])]))
        XCTAssertTrue(message.contains("$regex"), "отказ обязан назвать оператор: \(message)")
        XCTAssertTrue(message.contains("contains"), "и то, чем его заменить: \(message)")
    }

    /// Опечатка в имени оператора — тот же случай: база отвечает так же
    /// невнятно, а исправление очевидно, если сказать, что принято.
    func testAMisspelledOperatorIsRefusedWithTheSupportedList() {
        let message = refusal(.object(["year": .object(["$equals": .int(2024)])]))
        XCTAssertTrue(message.contains("$equals"), message)
        XCTAssertTrue(message.contains("$eq"), "список принятых операторов — часть отказа: \(message)")
    }

    /// Худший из трёх: база его **принимает** и не находит ничего.
    ///
    /// Замерено на живой базе (chroma 1.4.4): у 1699 документов
    /// `doc_type` = «ГК ПР10 001_24_01 от 01.01.2024», а
    /// `{"doc_type": {"$contains": "ПР10"}}` возвращает ноль записей и код 200.
    /// Пустая выдача без ошибки — это ответ «в базе такого нет», и агент
    /// уходит искать в другое место.
    func testContainsOnMetadataIsRefusedBecauseTheBaseAnswersItSilentlyEmpty() {
        let message = refusal(.object(["doc_type": .object(["$contains": .string("ПР10")])]))
        XCTAssertTrue(message.contains("$contains"), message)
        XCTAssertTrue(message.contains("contains"), "у поиска по тексту есть свой параметр: \(message)")
    }

    func testNotContainsIsRefusedForTheSameReason() {
        XCTAssertTrue(refusal(.object(["doc_type": .object(["$not_contains": .string("ПР10")])]))
            .contains("$not_contains"))
    }

    /// Проверка идёт вглубь: внутри `$and` оператор ровно так же не сработает.
    func testTheGuardLooksInsideAndOr() {
        let message = refusal(.object([
            "$and": .array([
                .object(["year": .object(["$eq": .int(2024)])]),
                .object(["heading_path": .object(["$regex": .string("1.1")])]),
            ]),
        ]))
        XCTAssertTrue(message.contains("$regex"), message)
    }

    // MARK: - Работающее не трогаем

    /// Список принятых операторов снят с живой базы запросами, а не с
    /// документации: каждый из них там отвечает кодом 200 и осмысленной
    /// выборкой.
    func testEverySupportedOperatorPassesThrough() {
        let cases: [String: JSONValue] = [
            "$eq": .string("pdf"),
            "$ne": .string("pdf"),
            "$gt": .int(3),
            "$gte": .int(3),
            "$lt": .int(3),
            "$lte": .int(3),
            "$in": .array([.string("pdf")]),
            "$nin": .array([.string("pdf")]),
        ]
        for (op, value) in cases {
            guard case .success(let filter) = outcome(.object(["field": .object([op: value])])) else {
                XCTFail("\(op) база понимает — пропускать обязаны")
                continue
            }
            XCTAssertNotNil(filter?.rawWhereJSON, "\(op): условие должно доехать до базы")
        }
    }

    func testAPlainFieldWithoutOperatorsIsNotTouched() {
        guard case .success(let filter) = outcome(.object(["year": .int(2024)])) else {
            return XCTFail("короткая запись без оператора — законная")
        }
        XCTAssertNotNil(filter?.rawWhereJSON)
    }

    /// Поле, чьё **значение** похоже на оператор, — не оператор.
    func testAValueThatLooksLikeAnOperatorIsNotMistakenForOne() {
        guard case .success = outcome(.object(["note": .object(["$eq": .string("$regex")])])) else {
            return XCTFail("«$regex» здесь — искомый текст, а не оператор")
        }
    }
}
