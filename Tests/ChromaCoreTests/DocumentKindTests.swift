import XCTest
@testable import ChromaCore

/// Тип файла человеческим словом.
///
/// Агенту нужно «данные из Excel», а в базе лежит `file_ext` с шестью
/// разными значениями. Без перевода агент поставил бы `file_ext = "xlsx"`
/// и молча потерял бы `xls`, `ods` и остальное.
final class DocumentKindTests: XCTestCase {

    private func extensions(_ names: [String]) throws -> [String] {
        switch DocumentKind.extensions(for: names) {
        case .extensions(let list): return list
        case .unknown(let message): throw XCTSkip("не разобрано: \(message)")
        }
    }

    // MARK: - Перевод

    func testExcelMeansEveryTableFormatRatherThanOne() throws {
        let list = try extensions(["excel"])
        for expected in ["xlsx", "xls", "ods", "numbers", "csv"] {
            XCTAssertTrue(list.contains(expected), "«\(expected)» тоже таблица: \(list)")
        }
    }

    func testWordMeansEveryTextDocumentFormat() throws {
        let list = try extensions(["word"])
        for expected in ["docx", "doc", "odt", "rtf"] {
            XCTAssertTrue(list.contains(expected), "«\(expected)» тоже документ: \(list)")
        }
    }

    /// Несколько типов складываются по «или».
    func testSeveralKindsAreJoined() throws {
        let list = try extensions(["word", "pdf"])
        XCTAssertTrue(list.contains("docx"))
        XCTAssertTrue(list.contains("pdf"))
    }

    /// Расширение принимается как есть: агент видит его в выдаче, в поле
    /// `file_ext`, и запретить передать обратно показанное было бы странно.
    func testABareExtensionIsAccepted() throws {
        XCTAssertEqual(try extensions(["docx"]), ["docx"])
    }

    /// Точка в начале — не ошибка, а привычка.
    func testALeadingDotIsForgiven() throws {
        XCTAssertEqual(try extensions([".pdf"]), ["pdf"])
    }

    func testTheCaseDoesNotMatter() throws {
        XCTAssertEqual(try extensions(["EXCEL"]), try extensions(["excel"]))
    }

    /// «excel, xlsx» не должно давать условие с двумя одинаковыми значениями.
    func testRepeatsAreRemovedAndOrderKept() throws {
        let list = try extensions(["excel", "xlsx"])
        XCTAssertEqual(list.count, Set(list).count, "повторы: \(list)")
        XCTAssertEqual(list.first, "xlsx", "порядок первого типа сохраняется")
    }

    // MARK: - Отказ, который можно прочитать

    func testAnUnknownKindIsRefusedWithAdvice() {
        guard case .unknown(let message) = DocumentKind.extensions(for: ["табличка"]) else {
            return XCTFail("«табличка» — не тип файла и не расширение")
        }
        XCTAssertTrue(message.contains("табличка"), message)
        XCTAssertTrue(message.contains("excel"), "в отказе перечислены возможные значения: \(message)")
    }

    /// Пустая строка — не повод для отказа, но и не условие.
    func testEmptyNamesAreSkipped() throws {
        XCTAssertEqual(try extensions(["", "  "]), [])
        XCTAssertNil(DocumentKind.whereClause(extensions: []))
    }

    // MARK: - Условие для базы

    func testTheClauseAsksTheFieldIndexingWrites() throws {
        let clause = try XCTUnwrap(DocumentKind.whereClause(extensions: try extensions(["pdf"])))
        XCTAssertEqual(clause, "{\"file_ext\": {\"$in\": [\"pdf\"]}}")
    }

    /// Условие обязано быть настоящим JSON: оно уходит в базу как есть.
    func testTheClauseIsValidJSON() throws {
        let clause = try XCTUnwrap(DocumentKind.whereClause(extensions: try extensions(["excel", "word"])))
        let parsed = try JSONSerialization.jsonObject(with: Data(clause.utf8)) as? [String: Any]
        XCTAssertNotNil(parsed?["file_ext"], clause)
    }

    /// Каждый тип что-то значит: пустой список расширений сделал бы фильтр,
    /// который ничего не находит.
    func testEveryKindHasExtensions() {
        for kind in DocumentKind.allCases {
            XCTAssertFalse(kind.extensions.isEmpty, "\(kind.rawValue) без расширений")
            XCTAssertFalse(kind.title.isEmpty, "\(kind.rawValue) без названия")
        }
    }

    /// Тип не вправе обещать то, чего сборка не читает: агент получил бы
    /// пустую выдачу и решил, что таких файлов в коллекции нет.
    func testNoKindPromisesAFormatTheBuildCannotRead() {
        let readable = Set(TextExtractor.supportedExtensions)
        for kind in DocumentKind.allCases {
            let empty = kind.extensions.filter { !readable.contains($0) }
            XCTAssertTrue(empty.isEmpty, "\(kind.rawValue) обещает нечитаемое: \(empty)")
        }
    }

    /// И обратное: `pptx` не должен молча превращаться в условие поиска —
    /// ни через тип, ни расширением напрямую.
    func testAFormatTheBuildCannotReadIsNotOfferedAtAll() throws {
        XCTAssertFalse(try extensions(["presentation"]).contains("pptx"))
        XCTAssertFalse(TextExtractor.supportedExtensions.contains("pptx"),
                       "если сборка научилась читать pptx — перечень типов пора пересмотреть")
    }
}

/// Как параметр `file_types` доходит до базы.
final class FileTypesInMCPTests: XCTestCase {

    private func filter(_ arguments: [String: JSONValue]) throws -> DocumentFilter? {
        switch MCPToolService.filterForTesting(JSONValue.object(arguments)) {
        case .success(let filter): return filter
        case .failure(let error): throw XCTSkip("отказ: \(error)")
        }
    }

    func testTheTypeBecomesAConditionOnTheIndexedField() throws {
        let filter = try XCTUnwrap(try filter(["file_types": .array([.string("excel")])]))
        let clause = try XCTUnwrap(filter.rawWhereJSON)
        XCTAssertTrue(clause.contains("file_ext"), clause)
        XCTAssertTrue(clause.contains("xlsx"), clause)
        XCTAssertTrue(clause.contains("ods"), clause)
    }

    /// Своё условие агента и наше по типу файла складываются, а не затирают
    /// друг друга: «таблицы за 2024 год» — это оба сразу.
    func testTheAgentFilterAndTheTypeAreCombined() throws {
        let filter = try XCTUnwrap(try filter([
            "filter": .object(["year": .object(["$eq": .int(2024)])]),
            "file_types": .array([.string("excel")]),
        ]))
        let clause = try XCTUnwrap(filter.rawWhereJSON)
        XCTAssertTrue(clause.contains("$and"), clause)
        XCTAssertTrue(clause.contains("year"), clause)
        XCTAssertTrue(clause.contains("file_ext"), clause)
        let parsed = try JSONSerialization.jsonObject(with: Data(clause.utf8)) as? [String: Any]
        XCTAssertEqual((parsed?["$and"] as? [Any])?.count, 2, "оба условия на месте: \(clause)")
    }

    /// Один агентский фильтр остаётся собой — без лишней обёртки в `$and`.
    func testASingleConditionIsNotWrapped() throws {
        let filter = try XCTUnwrap(try filter(["filter": .object(["year": .object(["$eq": .int(2024)])])]))
        XCTAssertFalse(try XCTUnwrap(filter.rawWhereJSON).contains("$and"))
    }

    func testNothingAskedMeansNoFilter() throws {
        XCTAssertNil(try filter([:]))
    }

    func testAnUnknownTypeIsAnErrorRatherThanAnEmptyAnswer() {
        guard case .failure = MCPToolService.filterForTesting(JSONValue.object(["file_types": .array([.string("табличка")])])) else {
            return XCTFail("непонятный тип должен давать внятный отказ, а не пустую выдачу")
        }
    }

    func testTheParameterMustBeAList() {
        guard case .failure = MCPToolService.filterForTesting(JSONValue.object(["file_types": .string("excel")])) else {
            return XCTFail("строка вместо списка — ошибка параметра")
        }
    }
}
