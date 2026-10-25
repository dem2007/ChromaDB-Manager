import XCTest
@testable import ChromaCore

/// объединённые ячейки: в каждой строке всё, что к ней относится.
final class SpannedTableTests: XCTestCase {
    private typealias Cell = SpannedTable.Cell

    /// Расчёт коммерческого предложения, как он приходит в КП: номер и
    /// описание работ объединены на все позиции.
    private var offer: SpannedTable {
        var cells = [
            Cell(text: "№", row: 0, column: 0),
            Cell(text: "Наименование", row: 0, column: 1),
            Cell(text: "Позиция", row: 0, column: 2),
            Cell(text: "Цена", row: 0, column: 3),
            Cell(text: "1", row: 1, column: 0, rowSpan: 3),
            Cell(text: "Поставка оборудования в г. Энск", row: 1, column: 1, rowSpan: 3),
        ]
        for (offset, item) in [("Узел управления #1", "123 456 789"), ("Узел хранения #1", "112 233 445"),
                               ("Пусконаладочные работы #1", "101 202 303")].enumerated() {
            cells.append(Cell(text: item.0, row: 1 + offset, column: 2))
            cells.append(Cell(text: item.1, row: 1 + offset, column: 3))
        }
        cells.append(Cell(text: "Итого:", row: 4, column: 0, columnSpan: 3))
        cells.append(Cell(text: "731 905 303", row: 4, column: 3))
        return SpannedTable(cells: cells)
    }

    /// Главное: значение, объединённое вниз, стоит в каждой строке.
    func testAValueMergedDownIsInEveryRow() {
        let rows = offer.rows()
        XCTAssertEqual(rows[0], ["№", "Наименование", "Позиция", "Цена"])
        XCTAssertEqual(rows[1], ["1", "Поставка оборудования в г. Энск", "Узел управления #1", "123 456 789"])
        XCTAssertEqual(rows[3], ["1", "Поставка оборудования в г. Энск", "Пусконаладочные работы #1", "101 202 303"])
    }

    /// Вбок — значение в каждой колонке, которую накрывает объединение
    ///: у «Итого:» на три колонки они все общие.
    func testAValueMergedSidewaysIsInEveryColumn() {
        XCTAssertEqual(offer.rows()[4], ["Итого:", "Итого:", "Итого:", "731 905 303"])
    }

    /// Двухуровневая шапка — одной строкой, подпись над подписью.
    func testATwoLevelHeaderBecomesOneRow() {
        let table = SpannedTable(cells: [
            Cell(text: "№ п/п", row: 0, column: 0, rowSpan: 2),
            Cell(text: "Единица измерения", row: 0, column: 1, columnSpan: 2),
            Cell(text: "Количество", row: 0, column: 3, rowSpan: 2),
            Cell(text: "код", row: 1, column: 1),
            Cell(text: "обозначение", row: 1, column: 2),
            Cell(text: "1", row: 2, column: 0),
            Cell(text: "876", row: 2, column: 1),
            Cell(text: "усл. ед.", row: 2, column: 2),
            Cell(text: "1", row: 2, column: 3),
        ])
        XCTAssertEqual(table.rows(), [
            ["№ п/п", "Единица измерения / код", "Единица измерения / обозначение", "Количество"],
            ["1", "876", "усл. ед.", "1"],
        ])
    }

    /// Колонки — по шапке: два значения под одной подписью — одна ячейка.
    func testValuesUnderOneHeadingShareAColumn() {
        let table = SpannedTable(cells: [
            Cell(text: "Наименование", row: 0, column: 0),
            Cell(text: "Цена", row: 0, column: 1, columnSpan: 2),
            Cell(text: "Болт", row: 1, column: 0),
            Cell(text: "12", row: 1, column: 1),
            Cell(text: "руб.", row: 1, column: 2),
        ])
        XCTAssertEqual(table.rows(), [["Наименование", "Цена"], ["Болт", "12 руб."]])
    }

    /// Неровная сетка Word: «шт.» начинается под «Ед. измерения», хотя
    /// в другой строке эта колонка сетки — часть «Состава».
    func testAnIrregularGridFollowsTheHeader() {
        let table = SpannedTable(cells: [
            Cell(text: "Услуга", row: 0, column: 0), Cell(text: "Состав", row: 0, column: 1),
            Cell(text: "Ед. измерения", row: 0, column: 2, columnSpan: 2),
            Cell(text: "ВМ", row: 1, column: 0), Cell(text: "vCPU", row: 1, column: 1),
            Cell(text: "шт.", row: 1, column: 2, columnSpan: 2),
            Cell(text: "K8s", row: 2, column: 0), Cell(text: "узел", row: 2, column: 1, columnSpan: 2),
            Cell(text: "шт.", row: 2, column: 3),
        ])
        XCTAssertEqual(table.rows(), [
            ["Услуга", "Состав", "Ед. измерения"], ["ВМ", "vCPU", "шт."], ["K8s", "узел", "шт."],
        ])
    }

    /// Бланк письма не становится «шапкой»: название ведомства на всю
    /// ширину — одна колонка, и сетка остаётся как есть.
    func testATitleRowDoesNotCollapseColumns() {
        let table = SpannedTable(cells: [
            Cell(text: "Перечень оборудования", row: 0, column: 0, columnSpan: 3),
            Cell(text: "Сервер", row: 1, column: 0), Cell(text: "2", row: 1, column: 1),
            Cell(text: "шт.", row: 1, column: 2),
        ])
        XCTAssertEqual(table.rows()[1], ["Сервер", "2", "шт."])
    }

    /// Строка-раздел становится колонкой «Раздел» у своих строк.
    func testASectionRowBecomesAColumn() {
        let table = SpannedTable(cells: [
            Cell(text: "№", row: 0, column: 0), Cell(text: "Позиция", row: 0, column: 1),
            Cell(text: "Цена", row: 0, column: 2),
            Cell(text: "1.", row: 1, column: 0), Cell(text: "Энск, этап 1", row: 1, column: 1, columnSpan: 2),
            Cell(text: "1.1", row: 2, column: 0), Cell(text: "Сертификат #1", row: 2, column: 1),
            Cell(text: "100", row: 2, column: 2),
            Cell(text: "2.", row: 3, column: 0), Cell(text: "Городец, этап 1", row: 3, column: 1, columnSpan: 2),
            Cell(text: "2.1", row: 4, column: 0), Cell(text: "Сертификат #2", row: 4, column: 1),
            Cell(text: "200", row: 4, column: 2),
            Cell(text: "Цены указаны с НДС", row: 5, column: 0, columnSpan: 3),
        ])
        XCTAssertEqual(table.rows(), [
            ["Раздел", "№", "Позиция", "Цена"],
            ["1. Энск, этап 1", "1.1", "Сертификат #1", "100"],
            ["2. Городец, этап 1", "2.1", "Сертификат #2", "200"],
            // Раздел без строк — примечание под таблицей: остаётся.
            ["Цены указаны с НДС", "", "", ""],
        ])
    }

    /// Раздел над разделом — оба в колонке, через « / ».
    func testANestedSectionKeepsItsParent() {
        let table = SpannedTable(cells: [
            Cell(text: "№", row: 0, column: 0), Cell(text: "Услуга", row: 0, column: 1),
            Cell(text: "Цена", row: 0, column: 2),
            Cell(text: "Облако", row: 1, column: 0, columnSpan: 3),
            Cell(text: "1", row: 2, column: 0), Cell(text: "Ресурсы", row: 2, column: 1, columnSpan: 2),
            Cell(text: "", row: 3, column: 0), Cell(text: "vCPU", row: 3, column: 1),
            Cell(text: "21,83", row: 3, column: 2),
            Cell(text: "2", row: 4, column: 0), Cell(text: "Kubernetes", row: 4, column: 1, columnSpan: 2),
            Cell(text: "", row: 5, column: 0), Cell(text: "vRAM", row: 5, column: 1),
            Cell(text: "12,94", row: 5, column: 2),
        ])
        XCTAssertEqual(table.rows(), [
            ["Раздел", "№", "Услуга", "Цена"],
            ["Облако / 1 Ресурсы", "", "vCPU", "21,83"],
            ["Облако / 2 Kubernetes", "", "vRAM", "12,94"],
        ])
    }

    /// Бланк письма: адресат справа на всю высоту не повторяется в строках
    /// реквизитов, а «Крепёж» слева на две строки — повторяется.
    func testALetterheadAddresseeIsNotRepeated() {
        let letterhead = SpannedTable(cells: [
            Cell(text: "Ведомство", row: 0, column: 0),
            Cell(text: "АО «Адресат»", row: 0, column: 1, rowSpan: 3),
            Cell(text: "ФКУ «Пример-Сервис»", row: 1, column: 0),
            Cell(text: "Москва", row: 2, column: 0),
        ])
        XCTAssertEqual(letterhead.rows(), [["Ведомство", "АО «Адресат»"], ["ФКУ «Пример-Сервис»", ""], ["Москва", ""]])

        let grouped = SpannedTable(cells: [
            Cell(text: "Крепёж", row: 0, column: 0, rowSpan: 2),
            Cell(text: "Болт", row: 0, column: 1),
            Cell(text: "Гайка", row: 1, column: 1),
            Cell(text: "Профиль", row: 2, column: 0),
            Cell(text: "Уголок", row: 2, column: 1),
        ])
        XCTAssertEqual(grouped.rows()[1], ["Крепёж", "Гайка"])
    }

    /// Пустая необъединённая ячейка остаётся пустой.
    func testAnEmptyCellStaysEmpty() {
        let table = SpannedTable(cells: [
            Cell(text: "Позиция", row: 0, column: 0), Cell(text: "Цена", row: 0, column: 1),
            Cell(text: "Болт", row: 1, column: 0), Cell(text: "12", row: 1, column: 1),
            Cell(text: "Гайка", row: 2, column: 0),
        ])
        XCTAssertEqual(table.rows()[2], ["Гайка", ""])
    }

    /// Отметки продолжения (Word, `.doc`) — в размах.
    func testContinuationMarksBecomeSpans() {
        let table = SpannedTable.fromContinuations([
            (0, 0, 1, "Крепёж", false), (0, 1, 1, "Болт", false),
            (1, 0, 1, "", true), (1, 1, 1, "Гайка", false),
            (2, 0, 1, "", true), (2, 1, 1, "Шайба", false),
        ])
        XCTAssertEqual(table.cells.first { $0.text == "Крепёж" }?.rowSpan, 3)
        XCTAssertEqual(table.rows()[2], ["Крепёж", "Шайба"])
    }

    // MARK: - Ячейка во всю ширину

    /// Подпись группы строк во всю ширину узкой таблицы — один раз, а не в
    /// каждой колонке: «| Процессор |  |», а не «| Процессор | Процессор |».
    func testAFullWidthCellIsWrittenOnce() {
        let table = SpannedTable(cells: [
            Cell(text: "Параметр", row: 0, column: 0), Cell(text: "Тип 6", row: 0, column: 1),
            Cell(text: "Процессор", row: 1, column: 0, columnSpan: 2),
            Cell(text: "Кол-во процессоров, шт.", row: 2, column: 0), Cell(text: "2", row: 2, column: 1),
            Cell(text: "ОЗУ", row: 3, column: 0, columnSpan: 2),
            Cell(text: "Объем GB, не менее", row: 4, column: 0), Cell(text: "384", row: 4, column: 1),
        ], headerRows: 1)
        let rows = table.rows()
        XCTAssertEqual(rows[1], ["Процессор", ""])
        XCTAssertEqual(rows[3], ["ОЗУ", ""])
        XCTAssertEqual(rows[2], ["Кол-во процессоров, шт.", "2"])
    }

    /// Объединение вбок не на всю ширину — по-прежнему в каждой колонке
    /// размаха.
    func testAPartialWidthMergeIsStillRepeated() {
        let table = SpannedTable(cells: [
            Cell(text: "Наименование", row: 0, column: 0), Cell(text: "Ед.", row: 0, column: 1),
            Cell(text: "Цена", row: 0, column: 2), Cell(text: "Сумма", row: 0, column: 3),
            Cell(text: "Болт оцинкованный", row: 1, column: 0), Cell(text: "шт.", row: 1, column: 1),
            Cell(text: "по запросу", row: 1, column: 2, columnSpan: 2),
            Cell(text: "Гайка", row: 2, column: 0), Cell(text: "шт.", row: 2, column: 1),
            Cell(text: "5", row: 2, column: 2), Cell(text: "10", row: 2, column: 3),
        ], headerRows: 1)
        XCTAssertEqual(table.rows()[1], ["Болт оцинкованный", "шт.", "по запросу", "по запросу"])
    }

    /// Пометка «шапка» на всю таблицу — не шапка: девять помеченных
    /// строк обрезались до трёх, и первая запись уходила в подписи колонок.
    /// Шапка тогда угадывается по форме.
    func testAHeaderMarkOverTheWholeTableIsNotAHeader() {
        var cells: [Cell] = [
            Cell(text: "Тип услуги", row: 0, column: 0, rowSpan: 2),
            Cell(text: "Количество узлов", row: 0, column: 1, rowSpan: 2),
            Cell(text: "Параметры узлов", row: 0, column: 2, columnSpan: 2),
            Cell(text: "vCPU", row: 1, column: 2), Cell(text: "vRAM, ГБ", row: 1, column: 3),
        ]
        for line in 0..<6 {
            cells += [Cell(text: "Базовая Тип \(line + 1)", row: 2 + line, column: 0),
                      Cell(text: "\(line + 1)", row: 2 + line, column: 1),
                      Cell(text: "8", row: 2 + line, column: 2), Cell(text: "64", row: 2 + line, column: 3)]
        }
        let rows = SpannedTable(cells: cells, headerRows: 8).rows()
        XCTAssertEqual(rows[0], ["Тип услуги", "Количество узлов", "Параметры узлов / vCPU", "Параметры узлов / vRAM, ГБ"])
        XCTAssertEqual(rows[1], ["Базовая Тип 1", "1", "8", "64"])
    }
}

