import Foundation

/// Путь записи листа — в её главной колонке.
///
/// **Зачем.** Строка листа — отдельная запись, её не слить с соседями: у
/// каждой свой номер строки, по нему идёт синхронизация. Но и прочитать её
/// по соседям нельзя. «2.2.1.1 Прикладная программная подсистема 1» не
/// знает, что она внутри «2.2 Разработка или адаптация программного
/// обеспечения» и «2.2.1 Группа прикладных программных подсистем»; строка
/// без номера под позицией — к какой позиции относится. В документе то же
/// самое решают строка-раздел и сведение записей, здесь —
/// путь.
///
/// **Как.** Ничего не придумывается: в текст записи, в ту же главную
/// колонку под её собственной подписью, впереди своего значения встают
/// значения предков через « / ». Предки по номеру — строки с номерами-
/// префиксами («2.2.1» и «2.2» для «2.2.1.1»), найденные выше по листу;
/// строка без номера — часть позиции над ней по тому же правилу, что
/// у документа (`TableRecords.isPart`). Метаданные не меняются.
public enum RecordPaths {
    /// Подпись предка — не длиннее этого: путь нужен, чтобы узнать место
    /// записи, а не пересказать всю позицию.
    static let maximumLabel = 160

    /// Номер строки листа → значения колонок для текста записи.
    public static func overrides(
        rows: [SheetRow], mapping: TableMapping, layout: SheetLayout
    ) -> [Int: [String: String]] {
        let columns = mapping.columns
        let textColumns = Set(mapping.textColumns)
        guard !rows.isEmpty, !textColumns.isEmpty else { return [:] }

        func clean(_ text: String) -> String {
            text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        }
        let grid = rows.map { row in
            columns.map { column in layout.index(of: column).map { clean(row.value(at: $0).displayText) } ?? "" }
        }
        guard var shape = TableRecords.layout(of: [columns] + grid, serviceSection: false) else { return [:] }
        // Главная — текстовая колонка (путь виден только в тексте записи),
        // заполненная у большинства строк с номером: у раздела «4» название
        // стоит в «Наименовании», а «Результаты этапа» пусты — путь в них
        // выходил бы голым номером. При равенстве — с текстом длиннее.
        let heads = grid.filter { TableRecords.isNumber($0[shape.number]) }
        let candidates = columns.indices.filter { textColumns.contains(columns[$0]) && $0 != shape.number }
        guard let best = candidates.max(by: { left, right in
            let filled = (heads.filter { !$0[left].isEmpty }.count, heads.filter { !$0[right].isEmpty }.count)
            if filled.0 != filled.1 { return filled.0 < filled.1 }
            return heads.reduce(0) { $0 + $1[left].count } < heads.reduce(0) { $0 + $1[right].count }
        }) else { return [:] }
        shape.main = best
        let main = columns[shape.main]

        // Подпись предка — номер и название; пустая главная ячейка — номер
        // и самый длинный текст строки.
        func label(_ cells: [String]) -> String {
            let name = cells[shape.main].isEmpty
                ? candidates.map { cells[$0] }.max { $0.count < $1.count } ?? ""
                : cells[shape.main]
            let text = [cells[shape.number], name].filter { !$0.isEmpty }.joined(separator: " ")
            return text.count > maximumLabel ? String(text.prefix(maximumLabel)) + "…" : text
        }
        func key(_ number: String) -> String {
            String(number.drop { $0 == " " }.reversed().drop { $0 == "." }.reversed())
        }

        var known: [String: String] = [:]
        var head: (cells: [String], path: [String])?
        var result: [Int: [String: String]] = [:]
        for (index, row) in rows.enumerated() {
            let cells = grid[index]
            var path: [String] = []
            let number = cells[shape.number]
            if TableRecords.isNumber(number) {
                let parts = key(number).split(separator: ".").map(String.init)
                for depth in stride(from: 1, to: parts.count, by: 1) {
                    if let ancestor = known[parts.prefix(depth).joined(separator: ".")] { path.append(ancestor) }
                }
                known[key(number)] = label(cells)
                head = (cells, path)
            } else if let current = head, TableRecords.isPart(cells, of: current.cells, layout: shape) {
                path = current.path + [label(current.cells)]
            } else {
                head = nil
            }
            guard !path.isEmpty else { continue }
            let own = cells[shape.main]
            result[row.number] = [main: (path + (own.isEmpty ? [] : [own])).joined(separator: " / ")]
        }
        return result
    }
}
