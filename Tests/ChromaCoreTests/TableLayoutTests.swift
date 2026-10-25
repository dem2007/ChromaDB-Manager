import XCTest
@testable import ChromaCore

/// Таблица или форма: бланк без колонок пишется строками текста,
/// таблица с шапкой — сеткой, как и прежде.
final class TableLayoutTests: XCTestCase {
    private typealias Cell = SpannedTable.Cell

    // MARK: - Формы

    /// Бланк на мелкой сетке: подписи и значения растянуты на десятки
    /// колонок, и каждая строка устроена по-своему.
    private func wideForm() -> SpannedTable {
        SpannedTable(cells: [
            Cell(text: "Расчёт стоимости работ", row: 0, column: 10, columnSpan: 40),
            Cell(text: "Коды", row: 0, column: 60, columnSpan: 10),
            Cell(text: "Вид документа", row: 1, column: 0, columnSpan: 20),
            Cell(text: "Приказ по организации", row: 1, column: 20, columnSpan: 50),
            Cell(text: "Единица измерения", row: 2, column: 0, columnSpan: 12),
            Cell(text: "руб.", row: 2, column: 12, columnSpan: 28),
            Cell(text: "по ОКЕИ", row: 2, column: 45, columnSpan: 10),
            Cell(text: "383", row: 2, column: 63, columnSpan: 7),
            Cell(text: "Дата", row: 3, column: 5, columnSpan: 30),
            Cell(text: "01.01.2030", row: 3, column: 52, columnSpan: 18),
            Cell(text: "Наименование программы", row: 4, column: 0, columnSpan: 33),
            Cell(text: "Развитие связи", row: 4, column: 33, columnSpan: 20),
            Cell(text: "по БК", row: 4, column: 55, columnSpan: 6),
        ])
    }

    func testAWideGridFormIsWrittenAsLines() {
        let table = wideForm()
        XCTAssertEqual(table.layout, .form)
        XCTAssertEqual(table.rendered(), """
        Расчёт стоимости работ | Коды
        Вид документа | Приказ по организации
        Единица измерения | руб. | по ОКЕИ | 383
        Дата | 01.01.2030
        Наименование программы | Развитие связи | по БК
        """)
    }

    /// Подпись, растянутая вниз, — у каждой своей строки; длинный текст,
    /// растянутый вниз, — один раз; одинаковые значения разных ячеек
    /// остаются оба.
    func testAShortLabelIsCarriedDownAndEqualValuesStay() {
        let long = String(repeating: "Пояснение к форме, которое занимает много места. ", count: 3)
        let table = SpannedTable(cells: [
            Cell(text: "Основание", row: 0, column: 0, rowSpan: 2),
            Cell(text: "Федеральный закон", row: 0, column: 1),
            Cell(text: "Дата", row: 0, column: 2),
            Cell(text: "28.11.2025", row: 0, column: 3),
            Cell(text: "Постановление", row: 1, column: 1),
            Cell(text: "100", row: 1, column: 2),
            Cell(text: "100", row: 1, column: 3),
            Cell(text: long, row: 2, column: 0, rowSpan: 2),
            Cell(text: "Итог", row: 2, column: 1),
            Cell(text: "Подпись", row: 3, column: 1),
        ])
        let lines = table.formLines()
        XCTAssertEqual(lines[0], "Основание | Федеральный закон | Дата | 28.11.2025")
        XCTAssertEqual(lines[1], "Основание | Постановление | 100 | 100", "«100 | 100» — два значения, а не повтор")
        XCTAssertEqual(lines.filter { $0.contains("Пояснение") }.count, 1, "длинный текст вниз не повторяется")
        XCTAssertTrue(lines.contains("Подпись"))
    }

    /// Ячейка бланка на всю высоту не в первой колонке — адресат справа
    /// от реквизитов — не повторяется (как и в таблице).
    func testAFullHeightSideCellIsNotRepeated() {
        let table = SpannedTable(cells: [
            Cell(text: "Исх. №", row: 0, column: 0),
            Cell(text: "Директору", row: 0, column: 2, rowSpan: 3),
            Cell(text: "от", row: 1, column: 0),
            Cell(text: "На №", row: 2, column: 0),
        ])
        XCTAssertEqual(table.formLines().filter { $0.contains("Директору") }.count, 1)
    }

    // MARK: - Таблицы — как были

    func testATableWithAHeaderStaysATable() {
        let table = SpannedTable(cells: [
            Cell(text: "№", row: 0, column: 0), Cell(text: "Наименование", row: 0, column: 1),
            Cell(text: "Цена", row: 0, column: 2),
            Cell(text: "1", row: 1, column: 0), Cell(text: "Болт", row: 1, column: 1),
            Cell(text: "12,50", row: 1, column: 2),
            Cell(text: "2", row: 2, column: 0), Cell(text: "Гайка", row: 2, column: 1),
        ])
        XCTAssertEqual(table.layout, .table)
        XCTAssertTrue(table.rendered().contains("| --- |"))
    }

    /// Название над шапкой — не шапка: шапка — первая строка из двух ячеек
    /// и больше (перечень, где название стоит не на всю ширину).
    func testATitleAboveTheHeaderDoesNotHideIt() {
        var cells = [Cell(text: "Перечень информационных систем", row: 0, column: 1, columnSpan: 2)]
        cells += [Cell(text: "№ п/п", row: 1, column: 0), Cell(text: "Ведомство", row: 1, column: 1),
                  Cell(text: "Система", row: 1, column: 2)]
        for row in 2..<8 {
            cells += [Cell(text: "\(row - 1)", row: row, column: 0), Cell(text: "Росархив", row: row, column: 1),
                      Cell(text: "Система \(row)", row: row, column: 2)]
        }
        XCTAssertEqual(SpannedTable(cells: cells).layout, .table)
    }

    /// Шапка в три яруса с годами — год → команда → графа — таблица.
    func testAMultiLevelHeaderWithYearsIsATable() {
        var cells = [
            Cell(text: "2026", row: 0, column: 2, columnSpan: 3), Cell(text: "2027", row: 0, column: 5, columnSpan: 3),
        ]
        for column in 2..<8 { cells.append(Cell(text: "Команда \(column % 3)", row: 1, column: column)) }
        cells += [Cell(text: "№", row: 2, column: 0), Cell(text: "Работа", row: 2, column: 1)]
        for column in 2..<8 { cells.append(Cell(text: "чел-мес", row: 2, column: column)) }
        for row in 3..<6 {
            cells += [Cell(text: "\(row)", row: row, column: 0), Cell(text: "Задача \(row)", row: row, column: 1)]
            for column in 2..<8 { cells.append(Cell(text: "0,5", row: row, column: column)) }
        }
        XCTAssertEqual(SpannedTable(cells: cells).layout, .table)
    }

    /// Плотная сетка без шапки — числа с первой строки — таблица.
    func testADenseGridWithoutAHeaderIsATable() {
        var cells: [Cell] = []
        for row in 0..<5 { for column in 0..<6 { cells.append(Cell(text: "\(row * 10 + column)", row: row, column: column)) } }
        XCTAssertEqual(SpannedTable(cells: cells).layout, .table)
    }

    /// Небольшая таблица без шапки, сетка которой ничего не раздувает, —
    /// таблица, даже если похожа на бланк: менять там нечего.
    func testASmallGridIsLeftAlone() {
        let table = SpannedTable(cells: [
            Cell(text: "1.", row: 0, column: 0), Cell(text: "Заказчик", row: 0, column: 1),
            Cell(text: "Указывается имя", row: 0, column: 2),
            Cell(text: "2.", row: 1, column: 0), Cell(text: "Исполнитель", row: 1, column: 1),
        ])
        XCTAssertEqual(table.layout, .table)
    }

    /// Редкая, но настоящая сетка — график по неделям: у отметки смысл даёт
    /// её колонка, и шапка из узких подписей это говорит.
    func testASparseScheduleWithAHeaderIsATable() {
        var cells = [Cell(text: "Работа", row: 0, column: 0)]
        for week in 1...30 { cells.append(Cell(text: "Нед. \(week)", row: 0, column: week)) }
        for task in 1...8 {
            cells.append(Cell(text: "Задача \(task)", row: task, column: 0))
            cells.append(Cell(text: "+", row: task, column: task * 3))
        }
        XCTAssertEqual(SpannedTable(cells: cells).layout, .table)
    }

    /// Две колонки — всегда таблица: такая сетка ничего не раздувает.
    func testATwoColumnTableIsATable() {
        let table = SpannedTable(cells: [
            Cell(text: "Заказчик", row: 0, column: 0), Cell(text: "ООО «Ромашка»", row: 0, column: 1),
            Cell(text: "Срок", row: 1, column: 0), Cell(text: "30 дней", row: 1, column: 1),
        ])
        XCTAssertEqual(table.layout, .table)
    }

    /// Объединение вниз — содержание, а не лишнее: таблица
    /// «Узел Тип 2 | 16 | 128 | 2500», растянутая на пять строк, остаётся
    /// таблицей, и каждая строка несёт свои параметры. Найдено на живом ТЗ:
    /// первая редакция считала повтор вниз раздувом, и строки
    /// становились «3 | 3,5».
    func testVerticalMergesAreContentNotWaste() {
        var cells = ["Тип", "Узлов", "vCPU", "vRAM", "SSD", "Объём", "Пользователей"].enumerated().map {
            Cell(text: $0.element, row: 0, column: $0.offset)
        }
        for (column, value) in ["Узел Тип 2", "", "16", "128", "2500", "", "1 – 12"].enumerated() where !value.isEmpty {
            cells.append(Cell(text: value, row: 1, column: column, rowSpan: 5))
        }
        for line in 0..<5 {
            cells.append(Cell(text: "\(line + 2)", row: 1 + line, column: 1))
            cells.append(Cell(text: "\(line + 2),5", row: 1 + line, column: 5))
        }
        let table = SpannedTable(cells: cells)
        XCTAssertEqual(table.layout, .table)
        XCTAssertTrue(table.rendered().contains("| Узел Тип 2 | 4 | 16 | 128 | 2500 | 4,5 | 1 – 12 |"), table.rendered())
    }

    // MARK: - Полосы: форма с таблицей внутри

    /// Счёт-фактура: реквизиты бланка строками, таблица товаров — сеткой.
    /// Шапка в «подпись | значение | код» таблицей не считается (строка в
    /// три ячейки — строка бланка).
    private func invoice() -> SpannedTable {
        var cells: [Cell] = [Cell(text: "Счёт-фактура № 1 от 23.12.2024", row: 0, column: 0, columnSpan: 21)]
        let requisites = [("Продавец", "ПАО «Телеком-Пример»", "(2)"), ("Адрес", "Москва, ул. Примерная, д. 1", "(2а)"),
                          ("ИНН/КПП продавца", "7700000001/770001001", "(2б)"), ("Покупатель", "Ведомство А", "(6)")]
        for (index, requisite) in requisites.enumerated() {
            cells += [Cell(text: requisite.0, row: index + 1, column: 0, columnSpan: 4),
                      Cell(text: requisite.1, row: index + 1, column: 4, columnSpan: 15),
                      Cell(text: requisite.2, row: index + 1, column: 19, columnSpan: 2)]
        }
        let header = ["Код", "№", "Наименование", "Единица", "Количество", "Цена", "Стоимость"]
        for (column, label) in header.enumerated() { cells.append(Cell(text: label, row: 5, column: column * 3, columnSpan: 3)) }
        for line in 0..<3 {
            let values = ["63.11", "\(line + 1)", "Услуга \(line + 1)", "усл. ед.", "1", "100,00", "100,00"]
            for (column, value) in values.enumerated() { cells.append(Cell(text: value, row: 6 + line, column: column * 3, columnSpan: 3)) }
        }
        cells.append(Cell(text: "Руководитель организации", row: 9, column: 0, columnSpan: 8))
        cells.append(Cell(text: "Иванов И. И.", row: 9, column: 12, columnSpan: 9))
        return SpannedTable(cells: cells)
    }

    func testAFormWithATableInsideIsSplitIntoBands() {
        let table = invoice()
        XCTAssertEqual(table.segments().map(\.layout), [.form, .table, .form])
        XCTAssertEqual(table.layout, .mixed)
        let text = table.rendered()
        XCTAssertTrue(text.contains("Продавец | ПАО «Телеком-Пример» | (2)"), text)
        XCTAssertEqual(text.components(separatedBy: "ПАО «Телеком-Пример»").count - 1, 1, "реквизит не размножен вбок")
        XCTAssertTrue(text.contains("| Код | № | Наименование | Единица | Количество | Цена | Стоимость |"), text)
        XCTAssertTrue(text.contains("| 63.11 | 2 | Услуга 2 | усл. ед. | 1 | 100,00 | 100,00 |"), text)
        XCTAssertTrue(text.hasSuffix("Руководитель организации | Иванов И. И."), text)
    }

    /// Обрывок шапки бланка на мелкой сетке: колонки собираются по её
    /// подписям, и сетка в 140 клеток становится четырьмя колонками без
    /// повторов — расточительной она больше не считается.
    func testAHeaderFragmentOnAFineGridIsGroupedByItsLabels() {
        var cells = [Cell(text: "Расчёт стоимости работ", row: 0, column: 0, columnSpan: 140)]
        for (index, label) in ["Источник", "Код строки", "Всего", "на 2031 г."].enumerated() {
            cells.append(Cell(text: label, row: 1, column: index * 35, columnSpan: 35))
        }
        for index in 0..<4 { cells.append(Cell(text: "\(index + 1)", row: 2, column: index * 35, columnSpan: 35)) }
        cells.append(Cell(text: "Общий объём, всего", row: 3, column: 0, columnSpan: 90))
        cells.append(Cell(text: "0100", row: 3, column: 90, columnSpan: 50))
        cells.append(Cell(text: "Подпись руководителя", row: 4, column: 20, columnSpan: 60))
        cells.append(Cell(text: "Иванов И. И.", row: 4, column: 100, columnSpan: 40))
        let text = SpannedTable(cells: cells).rendered()
        XCTAssertTrue(text.contains("| Источник | Код строки | Всего | на 2031 г. |"), text)
        // Ячейка, накрывшая две графы целиком, стоит в обеих — правило
        // таблиц; пятьдесят копий на мелкой сетке стали двумя.
        XCTAssertLessThanOrEqual(text.components(separatedBy: "Общий объём, всего").count - 1, 2, text)
        XCTAssertLessThan(text.count, 400, text)
    }

    /// Шапка, объединённая вниз на две строки, — одна строка подписей:
    /// вторая строка сетки её продолжает, а не повторяет записью.
    func testATallHeaderIsNotRepeatedAsARecord() {
        var cells: [Cell] = []
        for (column, label) in ["№", "Наименование", "Количество", "Цена"].enumerated() {
            cells.append(Cell(text: label, row: 0, column: column, rowSpan: 2))
        }
        for line in 0..<3 {
            for (column, value) in ["\(line + 1)", "Болт \(line)", "10", "5,00"].enumerated() {
                cells.append(Cell(text: value, row: 2 + line, column: column))
            }
        }
        let text = SpannedTable(cells: cells).rendered()
        XCTAssertEqual(text.components(separatedBy: "Наименование").count - 1, 1, text)
        XCTAssertTrue(text.contains("| 1 | Болт 0 | 10 | 5,00 |"), text)
    }

    /// То же в таблице внутри формы.
    func testATallHeaderInsideAFormIsNotRepeated() {
        var cells = invoice().cells.filter { $0.row < 5 }
        let header = ["Код", "№", "Наименование", "Единица", "Количество", "Цена", "Стоимость"]
        for (column, label) in header.enumerated() {
            cells.append(Cell(text: label, row: 5, column: column * 3, rowSpan: 2, columnSpan: 3))
        }
        for line in 0..<3 {
            let values = ["63.11", "\(line + 1)", "Услуга \(line + 1)", "усл. ед.", "1", "100,00", "100,00"]
            for (column, value) in values.enumerated() { cells.append(Cell(text: value, row: 7 + line, column: column * 3, columnSpan: 3)) }
        }
        let table = SpannedTable(cells: cells)
        XCTAssertEqual(table.segments().map(\.layout), [.form, .table])
        let text = table.rendered()
        XCTAssertEqual(text.components(separatedBy: "| Код | № |").count - 1, 1, text)
    }

    /// Название бланка во всю ширину над таблицей — строка формы, а не ярус
    /// шапки: иначе оно вставало в имя каждой колонки.
    func testAFullWidthTitleIsNotAHeaderLevel() {
        var cells = [Cell(text: "Акт приёма-передачи документов", row: 0, column: 0, columnSpan: 40),
                     Cell(text: "Основание: договор", row: 1, column: 0, columnSpan: 40)]
        for (column, label) in ["№", "Документ", "Вид", "Листов", "Примечание"].enumerated() {
            cells.append(Cell(text: label, row: 2, column: column * 8, columnSpan: 8))
        }
        for line in 0..<3 {
            for (column, value) in ["\(line + 1)", "Паспорт \(line)", "копия", "\(line + 2)", "нет"].enumerated() {
                cells.append(Cell(text: value, row: 3 + line, column: column * 8, columnSpan: 8))
            }
        }
        cells.append(Cell(text: "Сдал", row: 6, column: 0, columnSpan: 10))
        cells.append(Cell(text: "Принял", row: 6, column: 20, columnSpan: 10))
        let text = SpannedTable(cells: cells).rendered()
        XCTAssertTrue(text.hasPrefix("Акт приёма-передачи документов\nОснование: договор\n"), text)
        XCTAssertTrue(text.contains("| № | Документ | Вид | Листов | Примечание |"), text)
        XCTAssertEqual(text.components(separatedBy: "Основание").count - 1, 1, text)
    }

    /// Пустая строка между ярусами шапки не делает её глубже трёх строк:
    /// нижний ярус остаётся подписями, а не первой записью.
    func testAnEmptyRowInsideTheHeaderDoesNotPushLabelsIntoData() {
        var cells = invoice().cells.filter { $0.row < 5 }
        cells.append(Cell(text: "Товар", row: 5, column: 0, columnSpan: 9))
        cells.append(Cell(text: "Учёт", row: 5, column: 9, columnSpan: 12))
        cells.append(Cell(text: "", row: 6, column: 0, columnSpan: 21))
        let header = ["Код", "№", "Наименование", "Единица", "Количество", "Цена", "Стоимость"]
        for (column, label) in header.enumerated() { cells.append(Cell(text: label, row: 7, column: column * 3, columnSpan: 3)) }
        for (column, label) in ["а", "б", "в", "г", "д", "е", "ж"].enumerated() {
            cells.append(Cell(text: label, row: 8, column: column * 3, columnSpan: 3))
        }
        for line in 0..<3 {
            let values = ["63.11", "\(line + 1)", "Услуга \(line + 1)", "усл. ед.", "1", "100,00", "100,00"]
            for (column, value) in values.enumerated() { cells.append(Cell(text: value, row: 9 + line, column: column * 3, columnSpan: 3)) }
        }
        let text = SpannedTable(cells: cells).rendered()
        XCTAssertTrue(text.contains("| Код / а | № / б |"), text)
        XCTAssertFalse(text.contains("| а | б |"), text)
    }

    /// Большая сетка без шапки, где каждая строка устроена по-своему, —
    /// за доли секунды, а не за секунды.
    func testAManyPatternGridIsCheckedQuickly() {
        var cells: [Cell] = []
        var seed: UInt64 = 42
        func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
        for row in 0..<3000 {
            var used: Set<Int> = []
            while used.count < 3 { used.insert(next() % 30) }
            for column in used { cells.append(Cell(text: "v\(next() % 100)", row: row, column: column)) }
        }
        let start = Date()
        XCTAssertEqual(SpannedTable(cells: cells).layout, .form)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    /// «Во всю ширину» — по колонкам с содержимым: объединение над
    /// таблицей шире её, колонки за таблицей пусты, и название на все
    /// непустые колонки пишется один раз.
    func testATitleOverEveryFilledColumnIsWrittenOnce() {
        let table = SpannedTable(cells: [
            Cell(text: "Приложение 1", row: 0, column: 0, columnSpan: 6),
            Cell(text: "Расчет стоимости человеко-месяца", row: 1, column: 0, columnSpan: 4),
            Cell(text: "Показатели", row: 2, column: 1), Cell(text: "2026", row: 2, column: 2), Cell(text: "2027", row: 2, column: 3),
            Cell(text: "Прибыль", row: 3, column: 1), Cell(text: "21.56", row: 3, column: 2), Cell(text: "22.42", row: 3, column: 3),
            Cell(text: "НДС", row: 4, column: 1), Cell(text: "99.6", row: 4, column: 2), Cell(text: "103.58", row: 4, column: 3),
        ], headerRows: 1)
        let text = table.rendered()
        XCTAssertEqual(text.components(separatedBy: "Расчет стоимости человеко-месяца").count - 1, 1, text)
    }

    /// Бланк, чью расточительность даёт подпись во всю ширину, бланком и
    /// остаётся: мера — по сетке, где подпись повторена в каждой
    /// колонке, а запись её один раз — решение о выводе. Мерь по выводу —
    /// счёт-фактура становился сеткой с «ПАО Телеком-Пример» девять раз подряд.
    func testAFullWidthCellStillMakesAForm() {
        let note = String(repeating: "Документ подписан усиленной квалифицированной электронной подписью. ", count: 4)
        let table = SpannedTable(cells: [
            Cell(text: "Продавец", row: 0, column: 0), Cell(text: "ПАО «Телеком-Пример»", row: 0, column: 5),
            Cell(text: "Адрес", row: 1, column: 1), Cell(text: "Санкт-Петербург", row: 1, column: 9),
            Cell(text: "ИНН/КПП", row: 2, column: 2), Cell(text: "7700000001", row: 2, column: 12),
            Cell(text: note, row: 3, column: 0, columnSpan: 16),
        ])
        XCTAssertEqual(table.layout, .form)
        XCTAssertTrue(table.rendered().contains("Продавец | ПАО «Телеком-Пример»"), table.rendered())
    }

    // MARK: - Лист книги

    /// Лист-бланк книги: строками, без шапки в кусках, с меткой формы.
    func testAFormSheetIsMarked() throws {
        let merges = ["B1:AO1", "AP1:AZ1", "A2:T2", "U2:BX2", "A3:L3", "M3:AN3", "F4:AI4", "BA4:BR4"]
            .compactMap(XLSXReader.MergedRange.init(reference:))
        XCTAssertEqual(merges.count, 8)
        let rows = MergeFill.filling([
            SheetRow(number: 1, cells: [1: .text("Расчёт стоимости работ"), 41: .text("Коды")]),
            SheetRow(number: 2, cells: [0: .text("Вид документа"), 20: .text("Приказ по организации")]),
            SheetRow(number: 3, cells: [0: .text("Единица измерения"), 12: .text("руб."), 60: .text("383")]),
            SheetRow(number: 4, cells: [5: .text("Дата"), 52: .text("01.01.2030")]),
        ], merges: merges)
        let rendered = SheetRenderer.render(rows: rows, headerRow: nil, merges: merges)
        XCTAssertTrue(rendered.isForm)
        XCTAssertNil(rendered.header, "у формы нет шапки, которую повторять в кусках")
        XCTAssertFalse(rendered.text.contains("| --- |"))
        XCTAssertEqual(rendered.text.components(separatedBy: "Приказ по организации").count - 1, 1, rendered.text)
    }
}
