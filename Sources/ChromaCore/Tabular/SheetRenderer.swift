import Foundation

/// Turns a whole sheet into text for «документ» mode.
///
/// The output is a Markdown table rather than tab-separated lines: a chunk of it
/// still reads as a table to a person and to a model, and the header can be
/// repeated at the top of every chunk in a form that means something.
public enum SheetRenderer {
    /// Версия вида листа-«документа». Входит в подпись профилей:
    /// сменилась — каждая книга перечитывается один раз. Строки «Таблицы
    /// данных» и листы, которые остались таблицами, дают тот же текст, и
    /// векторы у них не пересчитываются; переписываются только формы.
    ///
    /// 3 — числа без хвоста двоичной дроби, подпись во всю ширину
    /// один раз.
    /// 4 — знаки после запятой по формату ячейки, «во всю ширину» — по
    /// колонкам с содержимым.
    public static let version = 4

    /// Поле метаданных куска: как записан лист.
    public static let layoutKey = "table_layout"

    /// Значение поля: «form» — лист-форма, «mixed» — форма с таблицей.
    public static func layoutValue(_ layout: SpannedTable.Layout) -> String? {
        switch layout {
        case .table: return nil
        case .form: return "form"
        case .mixed: return "mixed"
        }
    }

    /// A rendered sheet, with its header kept separate — the header is needed
    /// again once the text is cut into chunks.
    public struct Rendered: Hashable, Sendable {
        public let text: String
        /// The header lines (title row plus the Markdown separator), or `nil`
        /// for a sheet rendered as plain lines.
        public let header: String?
        /// Таблица, форма или форма с таблицей внутри.
        public let layout: SpannedTable.Layout

        /// Есть ли в листе строки формы.
        public var isForm: Bool { layout != .table }

        public init(text: String, header: String?, layout: SpannedTable.Layout = .table) {
            self.text = text
            self.header = header
            self.layout = layout
        }
    }

    /// Лист — через то же правило объединённых ячеек, что таблица Word,
    /// HTML и PDF.
    ///
    /// **Что было.** Лист в режиме документа выводился строками как есть.
    /// Одна и та же таблица давала разный текст в зависимости от того, в чём
    /// её сохранили, — ровно то, что запрещает. На расчётах трудозатрат:
    /// - шапка не находилась (детектор смотрит только первую строку), и строки
    ///   `| --- |` не было — шапка не повторялась ни в одном куске;
    /// - название, строки-подсказки «2026 | 2026 | …» и ряд граф 1…108 шли
    ///   строками данных;
    /// - пустые колонки оставались, объединения не учитывались.
    ///
    /// **Как теперь.**
    /// - Шапка — строка, переданная вызывающим, а если её нет — первая строка,
    ///   где подписана хотя бы половина колонок, занятых строками ниже, и нет
    ///   чисел.
    /// - Над ней — строки групп с объединениями вбок, под ней — её
    ///   продолжение, объединённое вниз (`SheetHeaderLabels`). Вместе они —
    ///   многоуровневая шапка `SpannedTable`.
    /// - Строки выше — название, строкой над таблицей. Строка, все значения
    ///   которой уже стоят в шапке, — подсказка для формул, и она уходит.
    /// - Дальше всё как у документа: объединения, пустые колонки, разделы,
    ///   ряд граф, записи нумерованной таблицы.
    public static func render(
        rows: [SheetRow], headerRow: Int?, merges: [XLSXReader.MergedRange] = []
    ) -> Rendered {
        let filled = rows.filter { !$0.isEmpty }
        guard !filled.isEmpty else { return Rendered(text: "", header: nil) }

        let width = filled.map { $0.lastColumn + 1 }.max() ?? 0
        // One column is a list of lines, not a table. A one-column Markdown
        // table is noise around the text.
        guard width > 1 else {
            let lines = filled.map { $0.value(at: 0).displayText }
            return Rendered(text: lines.joined(separator: "\n"), header: nil)
        }

        let header = headerRow.flatMap { number in filled.contains { $0.number == number } ? number : nil }
            ?? detectedHeader(in: filled)
        var blockStart = filled[0].number
        var blockEnd: Int?
        if let header {
            let parents = SheetHeaderLabels.parentRows(rows: filled, headerRow: header, merges: merges, width: width)
            let end = SheetHeaderLabels.continuationEnd(headerRow: header, merges: merges)
            blockEnd = end
            // Шапка таблицы — не глубже трёх строк (`SpannedTable`): сверх
            // них она обрезается снизу, и настоящая строка подписей уходила
            // в данные. Лишние верхние строки групп становятся названием
            // над таблицей.
            var block = filled.filter { ($0.number >= (parents.first ?? header)) && $0.number <= end }.map(\.number)
            while block.count > SpannedTable.maximumHeaderRows, let top = block.first, top < header {
                block.removeFirst()
            }
            blockStart = block.first ?? header
        }
        let preamble = filled.filter { $0.number < blockStart }
        let body = filled.filter { $0.number >= blockStart }

        // Ячейки — якорями объединений; накрытые объединением клетки уходят:
        // читалка книги повторяет в них значение якоря. Только в пределах
        // занятых строк и ширины листа: объединённая целиком колонка
        // (A1:A1048576) иначе разворачивалась в миллион клеток.
        let lastRow = body.last?.number ?? blockStart
        var anchors: [Int: [Int: XLSXReader.MergedRange]] = [:]
        var covered: Set<[Int]> = []
        // Объединение, начатое выше таблицы (строка групп, срезанная до трёх
        // строк шапки), — якорем в её первой строке: иначе клетки под ним
        // уходили как накрытые, а сам якорь не выводился нигде.
        let byNumber = Dictionary(filled.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        for range in merges where range.lastRow >= blockStart && range.firstRow <= lastRow && range.firstColumn < width {
            let top = max(range.firstRow, blockStart)
            anchors[top, default: [:]][range.firstColumn] = range
            for row in top...min(range.lastRow, lastRow) {
                for column in range.firstColumn...min(range.lastColumn, width - 1)
                where !(row == top && column == range.firstColumn) {
                    covered.insert([row, column])
                }
            }
        }
        var cells: [SpannedTable.Cell] = []
        for (position, row) in body.enumerated() {
            for column in 0..<width where !covered.contains([row.number, column]) {
                var text = row.value(at: column).displayText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let range = anchors[row.number]?[column] {
                    if text.isEmpty, range.firstRow < row.number {
                        text = (byNumber[range.firstRow]?.value(at: column).displayText ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    let rowSpan = body[position...].prefix { $0.number <= range.lastRow }.count
                    cells.append(SpannedTable.Cell(
                        text: text, row: position, column: column,
                        rowSpan: max(1, rowSpan), columnSpan: min(width, range.lastColumn + 1) - column
                    ))
                } else if !text.isEmpty {
                    cells.append(SpannedTable.Cell(text: text, row: position, column: column))
                }
            }
        }
        let headerRows = blockEnd.map { end in body.filter { $0.number <= end }.count }
        let table = SpannedTable(cells: cells, headerRows: headerRows)

        // Название над таблицей; подсказка, повторяющая шапку, — нет.
        let headerTexts = cells.filter { cell in headerRows.map { cell.row < $0 } ?? false }.map(\.text)
        let captions = preamble.compactMap { row -> String? in
            var values: [String] = []
            for column in 0...max(0, row.lastColumn) {
                let text = row.value(at: column).displayText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty, !values.contains(text) { values.append(text) }
            }
            let repeatsHeader = !headerTexts.isEmpty && values.allSatisfy { value in
                headerTexts.contains { $0.contains(value) }
            }
            return values.isEmpty || repeatsHeader ? nil : values.joined(separator: " ")
        }

        let (rendered, layout) = table.renderedWithLayout()
        let text = (captions + [rendered]).filter { !$0.isEmpty }.joined(separator: "\n")
        let lines = text.components(separatedBy: "\n")
        let headerLines = lines.indices.dropFirst().first { TableText.isSeparator(lines[$0]) }
            .map { lines[$0 - 1] + "\n" + lines[$0] }
        // У формы шапки нет, а у формы с таблицей внутри шапка — только
        // у таблицы: дописанная ко всем кускам листа, она встала бы и над
        // строками формы. Таблицам внутри шапку дописывает нарезка, каждой
        // свою.
        return Rendered(text: text, header: layout == .table ? headerLines : nil, layout: layout)
    }

    /// Строка шапки листа без подсказки: первая строка, где подписана хотя
    /// бы половина колонок, занятых строками ниже, и нет ни одного числа.
    static func detectedHeader(in filled: [SheetRow]) -> Int? {
        for (position, row) in filled.prefix(15).enumerated() {
            let below = filled[(position + 1)...].prefix(20)
            guard !below.isEmpty else { return nil }
            let used = Set(below.flatMap { line in (0...max(0, line.lastColumn)).filter { !line.value(at: $0).isEmpty } })
            guard used.count >= 2 else { continue }
            var named = 0
            var numeric = false
            for column in 0...max(0, row.lastColumn) {
                switch row.value(at: column) {
                case .text(let value):
                    if used.contains(column), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { named += 1 }
                case .empty: continue
                default: numeric = true
                }
            }
            if !numeric, named >= 2, Double(named) >= Double(used.count) * 0.5 { return row.number }
        }
        return nil
    }

    /// 1, and it is not optional: **the header row repeats in every chunk.**
    ///
    /// Without it the second and every later chunk is a grid of values with no
    /// column names — rows of numbers that mean nothing on their own, which is
    /// exactly the failure this whole stage exists to avoid.
    public static func repeatingHeader(_ header: String?, in chunks: [TextChunk]) -> [TextChunk] {
        guard let header, !header.isEmpty else { return chunks }
        // Дописывание — общее с остальными источниками: у листа шапка
        // известна заранее, у документа её приходится узнавать по разделителю,
        // но кусок в обоих случаях получается один и тот же.
        // Кусок, в котором шапка уже есть (первый — после названия
        // таблицы), второй не получает.
        return chunks.map { $0.text.contains(header) ? $0 : TableChunkHeaders.prepending(header, to: $0) }
    }

    // MARK: - Markdown

    /// Вид таблицы у книги и у всех остальных источников — общий:
    /// одна и та же таблица обязана давать один и тот же текст независимо
    /// от того, в чём её сохранили.
    static func row(_ values: [String]) -> String { TableText.row(values) }

    static func separator(width: Int) -> String { TableText.separator(width: width) }

    static func escape(_ value: String) -> String { TableText.escape(value) }
}
