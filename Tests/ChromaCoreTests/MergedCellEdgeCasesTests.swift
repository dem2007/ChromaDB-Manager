import XCTest
@testable import ChromaCore

/// Разбор ревью ветки объединённых ячеек: границы разделов, цепочки
/// продолжений, шапка выше трёх строк, итог страницы, обратная черта,
/// ключи со знаками.
final class MergedCellEdgeCasesTests: XCTestCase {
    private typealias Cell = SpannedTable.Cell
    private let header = ["№", "Наименование", "Кол-во, шт.", "Поставщик", "Цена"]

    private func row(_ number: Int, _ values: [String]) -> SheetRow {
        var cells: [Int: CellValue] = [:]
        for (index, value) in values.enumerated() where !value.isEmpty { cells[index] = .text(value) }
        return SheetRow(number: number, cells: cells)
    }

    // MARK: - Записи

    /// Строка без номера в начале другого раздела — своя позиция, а не
    /// часть последней записи прежнего.
    func testARecordDoesNotCrossASection() {
        let rows = TableRecords.merged([
            ["Раздел", "№", "Позиция", "Кол-во", "Цена"],
            ["Энск", "1.10", "Сервер", "1", "100"],
            ["Москва", "", "Доставка", "1", ""],
            ["Москва", "2.1", "Стойка", "1", "30"],
        ])
        XCTAssertEqual(rows[1], ["Энск", "1.10", "Сервер", "1", "100"])
        XCTAssertEqual(rows[2], ["Москва", "", "Доставка", "1", ""])
    }

    /// Части записи со следующей страницы встают к записи, а не за итог
    /// страницы под ней.
    func testCarriedPartsGoBeforeThePageTotal() {
        let edges = [40.0, 80, 300, 360, 420, 500]
        var blocks: [Int: [TableGeometry.PageBlock]] = [
            0: [.table(rows: [header, ["1", "Сервер в составе:", "1", "РФ", "100"],
                              ["", "Итого по странице", "", "", "100"]], edges: edges)],
            1: [.table(rows: [["", "RAM", "16", "", ""], ["2", "Стойка", "1", "РФ", "30"]], edges: edges)],
        ]
        PDFExtractor.continueTables(&blocks, pageCount: 2)
        guard case .table(let first, _) = blocks[0]?.first else { return XCTFail("\(blocks)") }
        let merged = TableRecords.merged(first)
        XCTAssertEqual(merged[1][1], "Сервер в составе: RAM (Кол-во, шт.: 16)")
        XCTAssertEqual(merged.last?[1], "Итого по странице")
    }

    /// Страница, выведенная текстом OCR, продолжения не принимает и не
    /// передаёт: перенесённое в её блоки не попало бы в текст.
    func testARecognisedPageTakesNoContinuation() {
        let edges = [40.0, 80, 300, 360, 420, 500]
        let original: [Int: [TableGeometry.PageBlock]] = [
            0: [.table(rows: [header, ["1", "Сервер в составе:", "1", "РФ", "100"]], edges: edges)],
            1: [.table(rows: [["", "RAM", "16", "", ""], ["2", "Стойка", "1", "РФ", "30"]], edges: edges)],
        ]
        var blocks = original
        PDFExtractor.continueTables(&blocks, pageCount: 2, skipping: [0])
        XCTAssertEqual(blocks, original)
    }

    // MARK: - Разделы и продолжения

    /// Верхний уровень кончается, когда раздел другого вида: «Прочие работы»
    /// после «1 Ресурсы» — не подраздел «Облака».
    func testATopLevelSectionEndsAtADifferentKind() {
        let table = SpannedTable(cells: [
            Cell(text: "№", row: 0, column: 0), Cell(text: "Услуга", row: 0, column: 1),
            Cell(text: "Цена", row: 0, column: 2),
            Cell(text: "Облако", row: 1, column: 0, columnSpan: 3),
            Cell(text: "1", row: 2, column: 0), Cell(text: "Ресурсы", row: 2, column: 1, columnSpan: 2),
            Cell(text: "", row: 3, column: 0), Cell(text: "vCPU", row: 3, column: 1),
            Cell(text: "21,83", row: 3, column: 2),
            Cell(text: "Прочие работы", row: 4, column: 0, columnSpan: 3),
            Cell(text: "", row: 5, column: 0), Cell(text: "Монтаж", row: 5, column: 1),
            Cell(text: "5", row: 5, column: 2),
        ])
        XCTAssertEqual(table.rows(), [
            ["Раздел", "№", "Услуга", "Цена"],
            ["Облако / 1 Ресурсы", "", "vCPU", "21,83"],
            ["Прочие работы", "", "Монтаж", "5"],
        ])
    }

    /// Цепочка продолжений без начала — каждая клетка со своим текстом.
    func testAChainOfOrphanContinuationsKeepsItsText() {
        let table = SpannedTable.fromContinuations([
            (0, 0, 1, "Болт", false), (0, 1, 1, "М8", false),
            (1, 0, 1, "Гайка", false), (1, 1, 1, "М6", false), (1, 2, 1, "оцинк.", true),
            (2, 0, 1, "Шайба", false), (2, 1, 1, "М4", false), (2, 2, 1, "латунь", true),
        ])
        let texts = table.cells.map(\.text)
        XCTAssertTrue(texts.contains("оцинк."), "\(texts)")
        XCTAssertTrue(texts.contains("латунь"), "\(texts)")
    }

    // MARK: - Лист

    /// Подпись, объединённая вниз на все четыре строки шапки, остаётся
    /// подписью, когда верх шапки срезан до трёх строк.
    func testALabelMergedOverATallHeaderSurvivesTheCut() throws {
        let rows = [
            row(1, ["№", "Всего", "", "", ""]),
            row(2, ["", "2026", "", "2027", ""]),
            row(3, ["", "Команда", "", "Команда", ""]),
            row(4, ["", "Архитектор", "Аналитик", "Архитектор", "Аналитик"]),
            row(5, ["1", "8", "16", "4", "2"]),
        ]
        let merges = ["A1:A4", "B1:E1", "B2:C2", "D2:E2", "B3:C3", "D3:E3"]
            .compactMap(XLSXReader.MergedRange.init(reference:))
        let rendered = SheetRenderer.render(rows: rows, headerRow: 4, merges: merges)
        let labels = try XCTUnwrap(rendered.header?.components(separatedBy: "\n").first)
        XCTAssertEqual(TableText.cells(of: labels).first, "№", rendered.text)
    }

    /// «№» и «%» меняют ключ метаданных — и подпись листа, чтобы была
    /// предложена переиндексация. У прочих листов подпись прежняя.
    func testSpelledSignsChangeTheSignature() {
        let signed = TableMapping(sheetName: "s", columns: ["№", "Скидка %"], textTemplate: "")
        XCTAssertTrue(signed.signature.contains("keys:номер,скидка_процент"), signed.signature)
        let plain = TableMapping(sheetName: "s", columns: ["Номер", "Скидка"], textTemplate: "")
        XCTAssertFalse(plain.signature.contains("keys:"), plain.signature)
    }

    // MARK: - Текст таблицы

    /// Обратная черта переживает строку таблицы и обратно; путь Windows
    /// остаётся как был.
    func testBackslashesRoundTrip() {
        let values = ["a\\|b", "C:\\Users", "end\\", "x\\\\y", "|"]
        XCTAssertEqual(TableText.cells(of: TableText.row(values)), values)
        XCTAssertEqual(TableText.escape("C:\\Users"), "C:\\Users")
    }
}
