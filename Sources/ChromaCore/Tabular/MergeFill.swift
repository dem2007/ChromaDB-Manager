import Foundation

/// Значение объединённой ячейки — в каждой клетке объединения, и вниз,
/// и вбок.
///
/// Одно правило на все книги — `.xlsx` (и `.numbers` через его выгрузку),
/// `.xls`, `.ods`. Раньше вниз значение повторялось всегда,
/// а вбок — только по особому флагу у `.xlsx` и `.xls` и никогда у `.ods`:
/// строка с «Итого», объединённым на три колонки, попадала в запись одной
/// колонкой, а у блока «две колонки на восемь строк» вторая колонка
/// оставалась пустой во всех восьми строках. Объединив ячейки, автор сказал,
/// что значение у всех клеток общее, — так оно и читается.
///
/// Заполняются только **пустые** клетки и только в **строках, которые есть
/// в файле**: колонка, объединённая на весь лист, не должна порождать
/// миллион строк из одного значения.
struct MergeFill {
    /// Шире этого объединение вбок не раскладывается: строка, объединённая
    /// «на весь лист» (16 384 колонки), — оформление, а не шестнадцать тысяч
    /// значений. Деловые таблицы в это не упираются.
    static let maximumColumns = 512

    private var startingAt: [Int: [XLSXReader.MergedRange]] = [:]
    /// Действующие объединения: колонка → (значение, последняя строка).
    private var active: [Int: (value: CellValue, lastRow: Int)] = [:]

    init(_ merges: [XLSXReader.MergedRange] = []) {
        for range in merges { add(range) }
    }

    /// Объединение, о котором стало известно по ходу чтения (`.ods`
    /// объявляет его на верхней левой ячейке).
    mutating func add(_ range: XLSXReader.MergedRange) {
        startingAt[range.firstRow, default: []].append(range)
    }

    /// Подставляет значения объединений в строку `number`. Строки — по
    /// возрастанию номеров: значение берётся из верхней левой клетки,
    /// когда до неё доходит чтение.
    mutating func fill(row number: Int, cells: inout [Int: CellValue]) {
        for range in startingAt.removeValue(forKey: number) ?? [] {
            guard let value = cells[range.firstColumn], !value.isEmpty else { continue }
            let last = min(range.lastColumn, range.firstColumn + Self.maximumColumns - 1)
            for column in range.firstColumn...last {
                active[column] = (value, range.lastRow)
            }
        }
        guard !active.isEmpty else { return }
        active = active.filter { $0.value.lastRow >= number }
        for (column, span) in active where cells[column]?.isEmpty ?? true {
            cells[column] = span.value
        }
    }

    /// То же для уже прочитанных строк.
    static func filling(_ rows: [SheetRow], merges: [XLSXReader.MergedRange]) -> [SheetRow] {
        guard !merges.isEmpty else { return rows }
        var fill = MergeFill(merges)
        return rows.sorted { $0.number < $1.number }.map { row in
            var cells = row.cells
            fill.fill(row: row.number, cells: &cells)
            return SheetRow(number: row.number, cells: cells)
        }
    }
}
