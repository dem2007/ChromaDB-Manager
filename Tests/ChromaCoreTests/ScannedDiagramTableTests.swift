import XCTest
@testable import ChromaCore

/// распознанная схема не становится таблицей.
final class ScannedDiagramTableTests: XCTestCase {
    /// Блоки схемы, разрезанные строками сетки поперёк: подпись блока
    /// уходит в несколько строк «таблицы».
    private let diagram = [
        [" Предостав-", " Формирование", " Сервис"],
        ["ление услуг", "отчетов по", "подписания"],
        [" Ведение", "результатам", " Учет"],
        ["справочника", "поиска", "контрагентов"],
    ]

    func testRowsSplitAcrossTheGridAreADiagram() {
        XCTAssertTrue(TableGeometry.isSplitAcrossRows(diagram))
        XCTAssertFalse(TableGeometry.isSplitAcrossRows([
            ["№", "Наименование", "Срок"],
            ["1", "Поставка серверов", "2026"],
            ["2", "Монтаж стоек", "2026"],
            ["3", "Пусконаладка", "2027"],
        ]))
    }

    /// Прайс со скана: распознавание срезало заглавные, строки начинаются
    /// со строчной, — но колонка чисел говорит, что это таблица.
    func testANumericColumnKeepsAScannedPriceList() {
        let prices = [
            ["Наименование", "Кол-во", "Цена"],
            ["програмное обеспечение #6.1", "1", "2 345 678,00"],
            ["программное обеспечение #6.2", "1", "3 456 789,00"],
            ["ммное обеспечение #6.3", "1", "4 567 890,00"],
            ["поддержки #6", "1", "1 234 567,00"],
        ]
        XCTAssertTrue(TableGeometry.hasNumericColumn(prices))
        XCTAssertFalse(TableGeometry.isSplitAcrossRows(prices))
    }

    /// Сетка из рамок схемы: со скана её слова остаются строками текста,
    /// у векторного PDF правило не действует.
    func testAScannedDiagramGridStaysText() throws {
        let tops: [Double] = [400, 380, 360, 340, 320]
        let lefts: [Double] = [0, 100, 200, 300]
        let rulings = TableLattice.Rulings(
            horizontal: tops.map { TableLattice.Segment(position: $0, from: 0, to: 300) },
            vertical: lefts.map { TableLattice.Segment(position: $0, from: 320, to: 400) }
        )
        let grids = TableLattice.grids(from: rulings, tolerance: 2.5)
        XCTAssertEqual(grids.count, 1)
        var words: [TableGeometry.Word] = []
        for (row, cells) in diagram.enumerated() {
            for (column, text) in cells.enumerated() {
                words.append(TableGeometry.Word(
                    box: CGRect(x: lefts[column] + 5, y: tops[row] - 15, width: 80, height: 8), text: text
                ))
            }
        }
        func hasTable(separated: Bool) -> Bool {
            let blocks = TableGeometry.page(words: words, grids: grids, height: 8, separated: separated).blocks ?? []
            return blocks.contains { if case .table = $0 { true } else { false } }
        }
        XCTAssertFalse(hasTable(separated: true))
        XCTAssertTrue(hasTable(separated: false))
    }
}
