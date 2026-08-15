import Foundation

/// How one sheet is to be understood.
///
/// Chosen by the user. Detection only proposes a default — a sheet that looks
/// like a data table but is really a formatted report would otherwise be turned
/// into thousands of meaningless documents without anyone being asked.
public enum SheetMode: String, Codable, Sendable, CaseIterable, Identifiable {
    public var id: String { rawValue }

    /// Header row plus homogeneous rows. One row becomes one document — the
    /// main mode, and the reason this stage exists.
    case dataTable
    /// Free layout: notes, a report, merged cells, text among numbers. Rendered
    /// to text and put through the ordinary chunking of stage 2.
    case document
    /// Service sheets, look-up tables, sheets of formulas.
    case skip

    public var title: String {
        switch self {
        case .dataTable: return String(localized: "Таблица данных")
        case .document: return String(localized: "Документ")
        case .skip: return String(localized: "Не индексировать")
        }
    }

    public var explanation: String {
        switch self {
        case .dataTable:
            return String(localized: "Строка → отдельный документ, значения колонок → метаданные. Поиск работает фильтрами по колонкам плюс текст из выбранных полей.")
        case .document:
            return String(localized: "Лист целиком превращается в текст и режется обычной стратегией чанкинга. Строка заголовков повторяется в каждом чанке.")
        case .skip:
            return String(localized: "Лист не читается вовсе.")
        }
    }
}

/// What the detector saw in a sheet, and what it therefore proposes.
public struct SheetShape: Hashable, Sendable {
    public let mode: SheetMode
    /// 1-based row number of the header, as the file numbers rows. `nil` when
    /// no row looks like a header.
    public let headerRow: Int?
    /// Column titles from that row, in column order, with gaps filled in.
    public let columns: [String]
    /// Why this mode was proposed — shown next to the choice, so the user can
    /// disagree with a reason rather than with a guess.
    public let reason: String

    public init(mode: SheetMode, headerRow: Int?, columns: [String], reason: String) {
        self.mode = mode
        self.headerRow = headerRow
        self.columns = columns
        self.reason = reason
    }
}

/// Proposes a mode for a sheet by looking at its first rows.
///
/// Deliberately conservative: everything it is not sure about becomes
/// «документ», which loses nothing — the text is still indexed — while a wrong
/// «таблица данных» would produce a document per row of a report.
public enum SheetModeDetector {
    /// How many rows are enough to judge. A header and a handful of rows under
    /// it say as much as ten thousand.
    public static let sampleSize = 20

    public static func suggest(rows: [SheetRow], isHidden: Bool = false) -> SheetShape {
        // hidden sheets are skipped by default. They are hidden because
        // somebody decided they are not for reading.
        if isHidden {
            return SheetShape(
                mode: .skip, headerRow: nil, columns: [],
                reason: String(localized: "лист скрыт — скрытые листы по умолчанию не индексируются")
            )
        }

        let filled = rows.filter { !$0.isEmpty }
        guard let header = filled.first else {
            return SheetShape(
                mode: .skip, headerRow: nil, columns: [],
                reason: String(localized: "лист пуст")
            )
        }

        let width = filled.prefix(sampleSize).map { $0.lastColumn + 1 }.max() ?? 0
        let body = Array(filled.dropFirst().prefix(sampleSize))
        let titles = headerTitles(header, width: width)
        // Columns that are empty everywhere — the narrow spacer column real
        // spreadsheets are full of. They are not columns of the table, and
        // judging the header row by them rejected perfectly ordinary files.
        let used = usedColumns(header: header, body: body, width: width)

        guard used.count > 1 else {
            return SheetShape(
                mode: .document, headerRow: nil, columns: [],
                reason: String(localized: "одна колонка — это текст, а не таблица записей")
            )
        }
        guard isHeaderRow(header, columns: used) else {
            return SheetShape(
                mode: .document, headerRow: nil, columns: [],
                reason: String(localized: "в первой строке есть пустые или числовые ячейки — на строку заголовков не похоже")
            )
        }
        guard !body.isEmpty else {
            return SheetShape(
                mode: .document, headerRow: header.number, columns: titles,
                reason: String(localized: "под заголовками нет строк с данными")
            )
        }
        guard columnsAreHomogeneous(body, width: width) else {
            return SheetShape(
                mode: .document, headerRow: header.number, columns: titles,
                reason: String(localized: "типы значений в колонках неоднородны — похоже на отчёт, а не на таблицу записей")
            )
        }

        return SheetShape(
            mode: .dataTable, headerRow: header.number, columns: titles,
            reason: String(localized: "строка заголовков и \(body.count) однородных строк под ней")
        )
    }

    /// Форма листа с заголовком в строке, которую указали руками.
    ///
    /// Автоопределение берёт первую непустую строку — и на файле, где над
    /// таблицей стоят название отчёта, дата и подпись, «заголовками»
    /// становится название отчёта. Угадать тут нечего: ячейка «Отчёт за март»
    /// ничем не отличается от подписи колонки, а строк над таблицей бывает
    /// и одна, и пять. Поэтому строка называется человеком, а форма считается
    /// от неё.
    ///
    /// `nil` — заголовков в этой строке нет: строки нет в листе, она пуста,
    /// в ней одни числа или названия повторяются. Молча съезжать на
    /// автоопределение нельзя: человек указал строку, и «не вышло» должно быть
    /// видно, а не спрятано за разбором, которого он не просил.
    public static func shape(rows: [SheetRow], headerRow: Int) -> SheetShape? {
        guard case .headers(let titles) = TableProfileMatcher.headers(in: rows, headerRow: headerRow),
              let header = rows.first(where: { $0.number == headerRow })
        else { return nil }

        let width = titles.count
        // Данные — только под заголовком. Всё, что выше, — шапка отчёта:
        // название, дата, автор. Строками таблицы они не являются, и судить
        // по ним об однородности колонок тем более нельзя.
        let body = Array(rows.filter { $0.number > headerRow && !$0.isEmpty }.prefix(sampleSize))
        let used = usedColumns(header: header, body: body, width: width)

        func shape(_ mode: SheetMode, _ reason: String) -> SheetShape {
            SheetShape(
                mode: mode, headerRow: headerRow, columns: titles,
                reason: String(localized: "заголовок взят из строки \(headerRow): \(reason)")
            )
        }

        guard used.count > 1 else {
            return shape(.document, String(localized: "одна колонка — это текст, а не таблица записей"))
        }
        guard !body.isEmpty else {
            return shape(.document, String(localized: "под ним нет строк с данными"))
        }
        guard columnsAreHomogeneous(body, width: width) else {
            return shape(.document, String(localized: "типы значений в колонках неоднородны"))
        }
        return shape(.dataTable, String(localized: "под ним однородные строки"))
    }

    /// Форма листа, у которого заголовков нет вовсе: колонки называются
    /// буквами, как в самой таблице.
    ///
    /// Нужна там, где на листе одни данные — без шапки, или с шапкой, которую
    /// не прочитать: объединённые ячейки, пустая строка, номера столбцов.
    /// Автоопределение такой лист объявляет «документом», и разметить его
    /// построчно было нечем. Названия человек задаёт сам, полем «Своё
    /// название»: буква — это адрес колонки, а не её смысл.
    ///
    /// `headerRow == 0` означает «заголовка нет, данные с первой строки»:
    /// строки с номером ноль в файле не бывает, и это единственное значение,
    /// которое нельзя перепутать с настоящей строкой.
    public static func lettered(rows: [SheetRow], headerRow: Int) -> SheetShape {
        let width = rows.map { $0.lastColumn + 1 }.max() ?? 0
        return SheetShape(
            mode: .dataTable,
            headerRow: headerRow,
            columns: (0..<max(0, width)).map(XLSXReader.columnName),
            reason: headerRow == 0
                ? String(localized: "заголовков нет — колонки названы буквами, данные с первой строки")
                : String(localized: "заголовков в строке \(headerRow) нет — колонки названы буквами")
        )
    }

    /// Column titles, with unnamed columns given their spreadsheet letter rather
    /// than an empty name — an empty key would be unusable downstream.
    ///
    /// Line breaks inside a title are collapsed to spaces: Excel wraps long
    /// headers by putting a real newline in the cell, and «Цена единицы,\nрубл»
    /// as a metadata key is a key nobody can type into a filter.
    public static func headerTitles(_ row: SheetRow, width: Int) -> [String] {
        (0..<max(0, width)).map { column in
            let text = row.value(at: column).displayText
                .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                .joined(separator: " ")
            return text.isEmpty ? XLSXReader.columnName(column) : text
        }
    }

    /// Columns the sheet actually uses: those with something in them in the
    /// header or in any sampled row.
    ///
    /// A column empty from top to bottom is a spacer — the narrow one people put
    /// between blocks, or the one Excel leaves at the left when a table is not
    /// flush against the edge. Counting it as a column of the table is what made
    /// an ordinary price list «не похоже на строку заголовков».
    static func usedColumns(header: SheetRow, body: [SheetRow], width: Int) -> [Int] {
        (0..<max(0, width)).filter { column in
            if !header.value(at: column).isEmpty { return true }
            return body.contains { !$0.value(at: column).isEmpty }
        }
    }

    /// a header row is textual and mostly filled.
    ///
    /// Two rules, and they are not the same one. **A number, a date or a boolean
    /// disqualifies it outright**: those are data, and a row of data is not a
    /// title row. **Empty cells are counted rather than fatal**: a title left off
    /// one column of twenty is a slip, while requiring every single cell rejected
    /// whole files over a single blank.
    ///
    /// The threshold is the same three quarters `columnsAreHomogeneous` uses —
    /// one rule of thumb in this file, not two.
    static func isHeaderRow(_ row: SheetRow, columns: [Int]) -> Bool {
        guard columns.count > 1 else { return false }
        var named = 0
        for column in columns {
            switch row.value(at: column) {
            case .number, .measured, .date, .boolean:
                return false
            case .text(let value):
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { named += 1 }
            case .empty:
                continue
            }
        }
        return Double(named) / Double(columns.count) >= 0.75
    }

    /// rows below the header have the same type down each column.
    ///
    /// Empty cells do not count against a column — real tables have gaps — and a
    /// column that is empty all the way down is not evidence either way.
    static func columnsAreHomogeneous(_ rows: [SheetRow], width: Int) -> Bool {
        guard width > 0, !rows.isEmpty else { return false }
        var agreeing = 0
        var judged = 0
        for column in 0..<width {
            var kinds: Set<String> = []
            for row in rows {
                let value = row.value(at: column)
                guard !value.isEmpty else { continue }
                kinds.insert(kind(of: value))
            }
            guard !kinds.isEmpty else { continue }
            judged += 1
            if kinds.count == 1 { agreeing += 1 }
        }
        guard judged > 0 else { return false }
        // Not «every column»: one messy column in a otherwise regular table —
        // a comment field with a stray number in it — should not turn a
        // catalogue of ten thousand products into one blob of text.
        return Double(agreeing) / Double(judged) >= 0.75
    }

    private static func kind(of value: CellValue) -> String {
        switch value {
        case .text: return "text"
        // Число с единицей — то же число: колонка, где половина ячеек
        // с процентом, а половина без, однородна.
        case .number, .measured: return "number"
        case .date: return "date"
        case .boolean: return "boolean"
        case .empty: return "empty"
        }
    }
}

extension XLSXReader {
    /// A proposed mode for every sheet of the workbook.
    ///
    /// Reads only the first rows of each sheet and stops: judging a workbook
    /// must not cost a full parse of a fifty-thousand-row sheet, and a header
    /// plus a handful of rows says as much as all of them.
    public func shapes(sampleSize: Int = SheetModeDetector.sampleSize) throws -> [(sheet: SheetInfo, shape: SheetShape)] {
        try sheets.map { sheet in
            var sample: [SheetRow] = []
            try forEachRow(of: sheet) { row in
                sample.append(row)
                return sample.count < sampleSize + 1
            }
            return (sheet, SheetModeDetector.suggest(rows: sample, isHidden: sheet.isHidden))
        }
    }
}
