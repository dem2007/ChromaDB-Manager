import Foundation

/// Записи нумерованной таблицы: строка с номером и всё, что под ней до
/// следующего номера, — одна строка.
///
/// **Зачем.** В нумерованной таблице номер и есть граница позиции. Строки
/// под ним без номера — её продолжение: комплектующие сервера («CPU…» под
/// «3. Сервер Тип 3… в составе:»), примечание под характеристикой, хвост
/// длинного названия, перенесённый сборкой отдельной строкой. Отдельными
/// строками они уходили в разные куски, в каждом без названия своей
/// позиции, а агент, которому сказано «одна строка таблицы — одна
/// позиция», насчитывал по ним лишние позиции без цен.
///
/// **Как.** Ничего не придумывается — ни новых колонок, ни подписей, ни
/// единиц. Строки записи вливаются в ячейки той же таблицы:
///
/// - обрывок (одна непустая ячейка) дописывается к своей ячейке через
///   пробел — это перенос текста; строка, заполняющая только пустые ячейки
///   предыдущей, — её же продолжение, и значения встают в эти ячейки;
/// - остальная строка дописывается в главную текстовую колонку через «;»,
///   а её значения из других колонок — в скобках, под подписями этих колонок
///   из шапки: «CPU Intel Xeon… (Кол-во, шт.: 2)». Перечисление через «;»
///   внутри ячейки агент уже читает как одну позицию.
///
/// **Чего не трогает.** Итог («Итого», «Всего») закрывает запись и остаётся
/// строкой. Строка без номера, где заполнено всё, что заполнено у строки
/// с номером, — полная позиция с непроставленным номером, а не часть
/// предыдущей; она тоже остаётся строкой. Таблица без колонки номера
/// не меняется вовсе.
enum TableRecords {
    /// Колонка номера и главная текстовая колонка.
    struct Layout: Equatable {
        var number: Int
        var main: Int
        /// Колонка «Раздел», если её добавила нормализация.
        var section: Int?
    }

    /// Номер позиции: «3», «3.», «1.2», «1.10.» — не длиннее этого.
    static let maximumNumberLength = 8

    /// Строки таблицы (первая — шапка) с записями, слитыми в строки.
    static func merged(_ rows: [[String]]) -> [[String]] {
        // Строки бывают неровными — сборка по координатам, не нашедшая общих
        // колонок, отдаёт ячейки как есть. Все строки, шапка тоже, — по самой
        // длинной: иначе подпись колонки бралась бы за пределами шапки.
        let width = rows.map(\.count).max() ?? 0
        var rows = rows.map { padded($0, to: width) }
        // Ряд нумерации граф под шапкой — не данные.
        if rows.count >= 2, TableText.isColumnNumbering(rows[1]) { rows.remove(at: 1) }
        guard rows.count >= 3, let layout = layout(of: rows) else { return rows }
        let header = rows[0]
        var result: [[String]] = [header]
        var record: [String]?
        var parts: [[String]] = []

        func close() {
            if let head = record { result.append(absorbing(parts, into: head, header: header, layout: layout)) }
            record = nil
            parts = []
        }
        for row in rows.dropFirst() {
            let cells = padded(row, to: header.count)
            if isNumber(cells[layout.number]) {
                close()
                record = cells
            } else if let head = record, isPart(cells, of: head, layout: layout) {
                parts.append(cells)
            } else {
                close()
                result.append(cells)
            }
        }
        close()
        return result
    }

    /// Колонка номера и главная колонка, или `nil`, если таблица не нумерованная.
    ///
    /// Номер — колонка с подписью «№», «N», «No» или такая, где значения
    /// почти всех строк — номера, идущие по возрастанию. Возрастание
    /// отличает номер от количества: у колонки «Кол-во» тоже одни числа,
    /// но «1, 1, 4, 3, 2» номером не бывают. Колонка «Раздел», которую
    /// добавляет нормализация, номером не считается.
    /// - Parameter serviceSection: колонка «Раздел» — служебная, её добавила
    /// нормализация документа. У листа книги «Раздел» — обычная
    ///   колонка файла, и там это выключается.
    static func layout(of rows: [[String]], serviceSection: Bool = true) -> Layout? {
        let header = rows[0]
        let body = rows.dropFirst().map { padded($0, to: header.count) }
        // Подпись, которой у колонки быть не может, — когда служебной нет.
        let section = serviceSection ? String(localized: "Раздел") : "\u{0}"
        var number: Int?
        let first = header.indices.first { header[$0] != section }
        for column in header.indices where header[column] != section {
            let values = body.map { $0[column] }.filter { !$0.isEmpty }
            let numbers = values.filter(isNumber)
            // Подпись «№» сама говорит, что это номер, — хватит и одной
            // позиции: таблица из одного сервера с комплектующими бывает.
            // Без подписи номером может быть только первая колонка, и
            // номеров нужно хотя бы два, идущих по порядку: иначе за номер
            // сходила колонка значений, где числа случайно шли по возрастанию.
            let labelled = isNumberLabel(header[column])
            guard numbers.count >= (labelled ? 1 : 2), numbers.count < 2 || ascending(numbers) else { continue }
            let mostly = Double(numbers.count) >= Double(values.count) * 0.6
            guard labelled || (column == first && mostly) else { continue }
            number = column
            break
        }
        guard let number else { return nil }
        // Главная — колонка с самым длинным текстом у строк с номером.
        let heads = body.filter { isNumber($0[number]) }
        var main: Int?
        var longest = 0
        for column in header.indices where column != number && header[column] != section {
            let length = heads.reduce(0) { $0 + $1[column].count }
            if length > longest {
                longest = length
                main = column
            }
        }
        guard let main else { return nil }
        return Layout(number: number, main: main, section: header.firstIndex(of: section))
    }

    /// Строка — часть записи, а не своя позиция, не итог и не примечание.
    static func isPart(_ row: [String], of head: [String], layout: Layout) -> Bool {
        guard row[layout.number].isEmpty, !isTotal(row), !isNote(row, layout: layout) else { return false }
        // Другой раздел — другая позиция: строка-раздел ушла в колонку, и без
        // этой проверки первая строка без номера нового раздела вливалась
        // в последнюю запись прежнего.
        if let section = layout.section, row[section] != head[section] { return false }
        // Колонка «Раздел» — служебная: она одинакова у всей записи, и
        // в счёт заполненного не идёт. Текст только в ней — примечание под
        // таблицей, оставленное нормализацией строкой.
        let filled = row.indices.filter { $0 != layout.section && !row[$0].isEmpty }
        guard !filled.isEmpty else { return false }
        // Обрывок переноса — всегда часть.
        if filled.count == 1 { return true }
        // Полная позиция: заполнено всё, что заполнено у строки с номером
        // (кроме самого номера), — это отдельная позиция без номера.
        let headFilled = head.indices.filter { $0 != layout.number && $0 != layout.section && !head[$0].isEmpty }
        let complete = headFilled.count >= 2 && headFilled.allSatisfy { !row[$0].isEmpty }
        return !complete
    }

    /// Строка-итог: «Итого», «Всего», «Total» в любой ячейке.
    static func isTotal(_ row: [String]) -> Bool {
        row.contains { cell in
            let text = cell.lowercased().trimmingCharacters(in: .whitespaces)
            return totalWords.contains { text.hasPrefix($0) }
        }
    }

    static let totalWords = ["итого", "всего", "итог:", "total", "subtotal", "grand total"]

    /// Строка-примечание: сноска со звёздочкой или «Примечание». Относится
    /// она к отмеченным позициям, а не к последней, — и остаётся строкой.
    static func isNote(_ row: [String], layout: Layout) -> Bool {
        guard let text = row.indices.first(where: { $0 != layout.section && !row[$0].isEmpty }).map({ row[$0] })
        else { return false }
        let lowered = text.lowercased()
        return text.hasPrefix("*") || noteWords.contains { lowered.hasPrefix($0) }
    }

    static let noteWords = ["примечани", "сноск", "note"]

    /// Строки записи — в строку её начала.
    static func absorbing(_ parts: [[String]], into head: [String], header: [String], layout: Layout) -> [String] {
        var row = head
        // Последняя строка, к которой приклеится обрывок: сама запись или
        // последняя влитая часть.
        var lastPart: Int?
        var entries: [[String]] = []
        for part in parts {
            let filled = part.indices.filter { $0 != layout.section && !part[$0].isEmpty }
            let target = lastPart.map { entries[$0] } ?? row
            // Обрывок — перенос текста своей ячейки. Строка, которая заполняет
            // только пустые ячейки предыдущей, — продолжение той же строки:
            // сборка разрезала её надвое (номер и название — в одной, цена
            // и сумма — в другой), и значения встают на свои места.
            let fillsGaps = filled.allSatisfy { target[$0].isEmpty }
            if filled.count == 1 || fillsGaps {
                for column in filled {
                    if let index = lastPart {
                        entries[index][column] = joinedText(entries[index][column], part[column])
                    } else {
                        row[column] = joinedText(row[column], part[column])
                    }
                }
                continue
            }
            entries.append(part)
            lastPart = entries.count - 1
        }
        for entry in entries {
            var text = entry[layout.main]
            let values = entry.indices
                .filter { $0 != layout.main && $0 != layout.number && $0 != layout.section && !entry[$0].isEmpty }
                .map { column in header[column].isEmpty ? entry[column] : "\(header[column]): \(entry[column])" }
            if !values.isEmpty {
                text += (text.isEmpty ? "" : " ") + "(" + values.joined(separator: ", ") + ")"
            }
            guard !text.isEmpty else { continue }
            let current = row[layout.main]
            row[layout.main] = current.isEmpty ? text
                : current.hasSuffix(":") ? current + " " + text
                : current + "; " + text
        }
        return row
    }

    // MARK: - Мелочи

    static func isNumber(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= maximumNumberLength, text.first?.isNumber == true else { return false }
        var sawDigit = false
        for character in text {
            if character.isNumber { sawDigit = true; continue }
            if character == "." { continue }
            return false
        }
        return sawDigit
    }

    static func isNumberLabel(_ text: String) -> Bool {
        let label = text.lowercased().trimmingCharacters(in: .whitespaces)
        return ["№", "n", "no", "no.", "nº", "n°"].contains { label == $0 || label.hasPrefix($0 + " ") }
            || label.hasPrefix("№")
    }

    /// Номера идут по порядку — почти везде: опечатка в одном номере
    /// таблицу ненумерованной не делает. По порядку — это по возрастанию
    /// и без скачков: у номера следующий отличается на единицу-другую
    /// («3» → «4», «1.9» → «1.10» → «2»), а количества и значения
    /// характеристик скачут — «40», «110», «200».
    static func ascending(_ numbers: [String]) -> Bool {
        guard numbers.count >= 2 else { return false }
        let pairs = zip(numbers, numbers.dropFirst())
        let ordered = pairs.filter { left, right in
            guard left.localizedStandardCompare(right) == .orderedAscending else { return false }
            let a = leading(left), b = leading(right)
            return b - a <= maximumStep
        }.count
        return Double(ordered) >= Double(numbers.count - 1) * 0.8
    }

    /// Наибольший скачок номера между соседними позициями.
    static let maximumStep = 5

    /// Первое число номера: «12.3» → 12.
    static func leading(_ text: String) -> Int {
        Int(text.prefix { $0.isNumber }) ?? 0
    }

    static func joinedText(_ left: String, _ right: String) -> String {
        guard !left.isEmpty else { return right }
        // Дефис на стыке — часть слова: «ИТ-» и «инфраструктуры».
        return left.hasSuffix("-") ? left + right : left + " " + right
    }

    static func padded(_ row: [String], to width: Int) -> [String] {
        row.count >= width ? row : row + Array(repeating: "", count: width - row.count)
    }
}
