import XCTest
@testable import ChromaCore

/// Листы книги, до которых разметка не дотянулась, называются вслух.
///
/// Живой случай: в книге четырнадцать листов, размечено пять; в базу попали
/// 73 строки из полутора тысяч, а лист с ценами не попал вовсе. Приложение
/// об этом молчало, и агент, искавший цифры сметы, брал их откуда придётся.
final class SheetCoverageTests: XCTestCase {
    func testTheReportNamesSheetsNobodyMapped() {
        var report = TableSyncReport()
        report.sheetsIndexed = ["1", "2"]
        report.sheetsWithoutMapping = ["Товары (ПО и ОС)", "Услуги", "ФЭО"]

        XCTAssertTrue(report.line.contains("листов без разметки"), report.line)
        XCTAssertTrue(report.line.contains("Товары (ПО и ОС)"), report.line)
        XCTAssertTrue(report.line.contains("в базу не попали"), report.line)
    }

    /// Книга размечена целиком — лишней строки в отчёте нет: оговорка,
    /// которая стоит всегда, перестаёт читаться.
    func testAFullyMappedWorkbookSaysNothingExtra() {
        var report = TableSyncReport()
        report.sheetsIndexed = ["1", "2"]
        XCTAssertFalse(report.line.contains("без разметки"), report.line)
    }
}

/// Покрытие книги доходит до строки и до агента.
final class SheetCoverageMetadataTests: XCTestCase {
    private func row(_ number: Int) -> SheetRow {
        SheetRow(number: number, cells: [0: .text("Комплект лицензий"), 1: .number(31_585_738)])
    }
    private var mapping: TableMapping {
        TableMapping(
            sheetName: "Товары", mode: .dataTable, headerRow: 1,
            columns: ["Наименование", "Цена"],
            roles: ["Наименование": .text, "Цена": .metadata]
        )
    }
    private var layout: SheetLayout {
        SheetLayout(headerRow: 1, columns: ["Наименование", "Цена"])
    }

    /// Книга размечена не целиком — строка несёт это с собой.
    func testAPartialWorkbookIsRecordedOnTheRow() throws {
        let fields = RowMapper.metadataAndTruncations(
            for: row(2), mapping: mapping, layout: layout,
            sourceFile: "смета.xlsx", rowKey: nil,
            coverage: SheetCoverage(indexed: 5, total: 14)
        )
        XCTAssertEqual(fields.metadata["sheets_indexed"], .int(5))
        XCTAssertEqual(fields.metadata["sheets_total"], .int(14))
    }

    /// Книга размечена целиком — полей нет: оговорка в каждой строке всей
    /// базы стоила бы места и перестала бы читаться.
    func testAFullyMappedWorkbookCarriesNoSuchFields() throws {
        let fields = RowMapper.metadataAndTruncations(
            for: row(2), mapping: mapping, layout: layout,
            sourceFile: "смета.xlsx", rowKey: nil,
            coverage: SheetCoverage(indexed: 14, total: 14)
        )
        XCTAssertNil(fields.metadata["sheets_indexed"])
        XCTAssertNil(fields.metadata["sheets_total"])
    }

    /// И то же самое видит агент — словами, а не одними метаданными.
    func testTheAgentIsToldTheWorkbookIsPartial() {
        let payload = MCPDocumentPayload(
            id: "1", text: "Комплект лицензий",
            metadata: ["sheets_indexed": .int(5), "sheets_total": .int(14)]
        )
        let output = MCPDocumentRendering.render([payload], limits: MCPOutputLimits())
        XCTAssertTrue(
            output.notes.contains { $0.contains("размечено листов") && $0.contains("итоги нельзя") },
            "\(output.notes)"
        )
    }

    func testAFullWorkbookIsNotWarnedAbout() {
        let payload = MCPDocumentPayload(
            id: "1", text: "Комплект лицензий",
            metadata: ["sheets_indexed": .int(14), "sheets_total": .int(14)]
        )
        let output = MCPDocumentRendering.render([payload], limits: MCPOutputLimits())
        XCTAssertFalse(output.notes.contains { $0.contains("размечено листов") }, "\(output.notes)")
    }
}
