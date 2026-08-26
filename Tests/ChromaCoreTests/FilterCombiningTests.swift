import XCTest
@testable import ChromaCore

/// Приложение дописывает свои условия к фильтру человека.
///
/// Уровень иерархии и пометка «закреплено» — это условия, которых человек
/// не писал: их добавляет конвейер. Добавлять их нужно так, чтобы фильтр,
/// собранный руками, остался собой.
final class FilterCombiningTests: XCTestCase {

    private func fileCondition(_ name: String) -> MetadataCondition {
        MetadataCondition(field: "source_file", op: .equals, value: name)
    }

    private let level = MetadataCondition(field: "chunk_level", op: .equals, value: "1")

    /// Главное: «ИЛИ» человека остаётся «ИЛИ».
    ///
    /// Прежде брались **дети** корня и подкладывались под новый «И»: фильтр
    /// «файл A ИЛИ файл Б» превращался в «A И Б И уровень». У документа одно
    /// значение `source_file`, поэтому такой запрос невыполним — поиск
    /// возвращал пусто, ни слова не сказав о причине.
    func testAnOrChosenByThePersonSurvives() throws {
        var filter = DocumentFilter()
        filter.root = .group(.or, [.leaf(fileCondition("а.pdf")), .leaf(fileCondition("б.pdf"))])

        let clause = try XCTUnwrap(filter.adding(level).whereClause())
        let parts = try XCTUnwrap(clause["$and"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2, "условие приложения кладётся рядом с корнем: \(clause)")
        XCTAssertNotNil(parts.first?["$or"], "выбор человека обязан остаться «ИЛИ»: \(clause)")
        XCTAssertNotNil(parts.last?["chunk_level"])
    }

    /// Пустой фильтр — обычный случай, и лишней вложенности он давать
    /// не должен: пустая группа условия не даёт и схлопывается.
    func testAnEmptyFilterYieldsTheConditionAlone() throws {
        let clause = try XCTUnwrap(DocumentFilter().adding(level).whereClause())
        XCTAssertNotNil(clause["chunk_level"], "лишняя обёртка вокруг единственного условия: \(clause)")
    }

    /// Корень с «И» ведёт себя как прежде — правка не должна менять то,
    /// что и так работало.
    func testAnAndRootKeepsWorkingAsBefore() throws {
        var filter = DocumentFilter()
        filter.root = .group(.and, [.leaf(fileCondition("а.pdf"))])
        let clause = try XCTUnwrap(filter.adding(level).whereClause())
        let parts = try XCTUnwrap(clause["$and"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        XCTAssertNotNil(parts.first?["source_file"])
        XCTAssertNotNil(parts.last?["chunk_level"])
    }

    /// Вложенное «ИЛИ» глубже первого уровня тоже остаётся собой.
    func testANestedOrIsUntouched() throws {
        var filter = DocumentFilter()
        filter.root = .group(.and, [
            .leaf(MetadataCondition(field: "gis", op: .equals, value: "ЦОД")),
            .group(.or, [.leaf(fileCondition("а.pdf")), .leaf(fileCondition("б.pdf"))]),
        ])
        let clause = try XCTUnwrap(filter.adding(level).whereClause())
        let parts = try XCTUnwrap(clause["$and"] as? [[String: Any]])
        let inner = try XCTUnwrap(parts.first?["$and"] as? [[String: Any]])
        XCTAssertNotNil(inner.last?["$or"], "вложенное «ИЛИ» потеряно: \(clause)")
    }
}
