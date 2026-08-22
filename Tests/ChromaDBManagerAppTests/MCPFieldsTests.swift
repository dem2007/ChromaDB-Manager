import XCTest
import ChromaCore
@testable import ChromaDBManagerApp

/// Описание коллекции обязано показать поля, по которым агент будет
/// фильтровать.
///
/// Живой случай: у коллекции из 5765 чанков 1290 — строки таблиц, и их
/// колонки («стоимость_тыс_руб», «итого», «2026») лежат только в них.
/// В первых пятидесяти документах строк таблиц не оказалось ни одной, и
/// агент не мог узнать, что цены вообще есть в метаданных.
final class MCPFieldsTests: XCTestCase {

    private func record(_ id: String, _ metadata: [String: MetadataValue]) -> DocumentRecord {
        DocumentRecord(id: id, document: "текст", metadata: metadata)
    }

    /// Имена отрезанных полей называются, а не пропадают молча.
    func testFieldsBeyondTheLimitAreNamed() {
        var sample: [DocumentRecord] = []
        // Сорок полей: больше предела в тридцать.
        var metadata: [String: MetadataValue] = [:]
        for index in 0..<40 { metadata["поле_\(String(format: "%02d", index))"] = .string("значение") }
        sample.append(record("d1", metadata))

        let result = MCPFieldSummary.fields(schema: nil, sample: sample)
        XCTAssertEqual(result.shown.count, 30)
        XCTAssertEqual(result.hidden.count, 10)
        XCTAssertEqual(result.hidden.first, "поле_30", "отрезанное обязано называться")
    }

    /// Служебные поля приложения агенту не нужны ни в показанных, ни
    /// в названных: фильтровать по ним он не станет.
    func testServiceFieldsStayHidden() {
        let result = MCPFieldSummary.fields(
            schema: nil,
            sample: [record("d1", ["_cdbm_model": .string("x"), "цена": .double(10)])]
        )
        XCTAssertEqual(result.shown.map(\.key), ["цена"])
        XCTAssertTrue(result.hidden.isEmpty)
    }

    /// Со схемой поля берутся из неё, но встреченное в документах и не
    /// объявленное — тоже называется: схема бывает неполной.
    func testFieldsOutsideTheSchemaAreStillNamed() {
        let schema = MetadataSchema(
            collectionName: "к", fields: [MetadataField(key: "doc_type", type: .string)]
        )
        let result = MCPFieldSummary.fields(
            schema: schema,
            sample: [record("d1", ["doc_type": .string("ТЗ"), "стоимость_тыс_руб": .double(4608.5)])]
        )
        XCTAssertEqual(result.shown.map(\.key), ["doc_type"])
        XCTAssertEqual(result.hidden, ["стоимость_тыс_руб"])
    }
}
