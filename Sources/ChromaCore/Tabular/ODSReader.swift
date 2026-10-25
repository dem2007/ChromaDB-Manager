import Foundation

/// Reads `.ods` — the OpenDocument spreadsheet.
///
/// Simpler than XLSX in one way and harder in another. Simpler: values carry
/// their own type (`office:value-type`), so there is no styles table to consult
/// and no serial-number arithmetic. Harder: emptiness is expressed by
/// **repetition** rather than by omission, and a sheet's last cell routinely
/// claims to repeat sixteen thousand times.
public struct ODSReader {
    private let container: ZIPContainerReader
    public let sheets: [SheetInfo]

    public static let supportedExtensions = ["ods"]

    public init(url: URL) throws {
        let archive: ZIPContainerReader
        do {
            archive = try ZIPContainerReader(url: url)
        } catch {
            throw XLSXError.notAWorkbook(error.localizedDescription)
        }
        guard archive.contains("content.xml") else {
            throw XLSXError.notAWorkbook(String(localized: "нет content.xml"))
        }
        let names = Self.tableNames(try archive.read("content.xml"))
        guard !names.isEmpty else { throw XLSXError.noSheets }
        sheets = names.map { SheetInfo(name: $0.name, isHidden: $0.isHidden, path: "content.xml") }
        container = archive
    }

    public func sheet(named name: String) throws -> SheetInfo {
        guard let sheet = sheets.first(where: { $0.name == name }) else {
            throw XLSXError.sheetMissing(name)
        }
        return sheet
    }

    /// Streams one table's rows.
    ///
    /// All tables of an `.ods` live in a single `content.xml`, so reaching the
    /// third sheet means parsing past the first two — but parsing stops as soon
    /// as the requested table ends, and rows of other tables are never built.
    @discardableResult
    public func forEachRow(
        of sheet: SheetInfo,
        limits: XLSXReader.Limits = XLSXReader.Limits(),
        _ onRow: @escaping (SheetRow) -> Bool
    ) throws -> [XLSXWarning] {
        try parse(sheet, limit: limits.maxRows, onRow: onRow).warnings
    }

    public func rows(of sheet: SheetInfo, limits: XLSXReader.Limits = XLSXReader.Limits()) throws -> (rows: [SheetRow], warnings: [XLSXWarning]) {
        let read = try rowsAndMerges(of: sheet, limits: limits)
        return (read.rows, read.warnings)
    }

    /// Строки листа и его объединения — за один разбор `content.xml`
    ///. У ODS объединения объявлены на верхней левой ячейке —
    /// `number-rows-spanned` и `number-columns-spanned`; все листы лежат
    /// в одном файле, и разбирать его ради объединений второй раз на каждый
    /// лист незачем.
    public func rowsAndMerges(
        of sheet: SheetInfo, limits: XLSXReader.Limits = XLSXReader.Limits()
    ) throws -> (rows: [SheetRow], warnings: [XLSXWarning], merges: [XLSXReader.MergedRange]) {
        var result: [SheetRow] = []
        let delegate = try parse(sheet, limit: limits.maxRows) { result.append($0); return true }
        return (result, delegate.warnings, delegate.merges)
    }

    private func parse(_ sheet: SheetInfo, limit: Int, onRow: @escaping (SheetRow) -> Bool) throws -> ODSParser {
        let data = try container.read("content.xml")
        let delegate = ODSParser(tableName: sheet.name, limit: limit, onRow: onRow)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.parse()
        try XLSXReader.checkParsed(parser, stopped: delegate.finished, sheet: sheet.name)
        return delegate
    }

    // MARK: - Table list

    /// Листы книги и скрыт ли каждый.
    ///
    /// Скрытость листа ODF пишет не на самом листе, а в его стиле —
    /// `style:table-properties table:display="false"`. Атрибута
    /// `table:visibility` у листа ODF не знает (он бывает у строк
    /// и колонок), и по нему каждый лист читался видимым: служебный лист,
    /// скрытый в LibreOffice, индексировался вопреки
    static func tableNames(_ data: Data) -> [(name: String, isHidden: Bool)] {
        final class Delegate: NSObject, XMLParserDelegate {
            var tables: [(name: String, style: String?, visibility: String)] = []
            var hiddenStyles: Set<String> = []
            private var tableStyle: String?

            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String]) {
                switch name {
                case "style:style":
                    tableStyle = attributes["style:family"] == "table" ? attributes["style:name"] : nil
                case "style:table-properties":
                    if let tableStyle, attributes["table:display"] == "false" { hiddenStyles.insert(tableStyle) }
                case "table:table":
                    tables.append((
                        attributes["table:name"] ?? "", attributes["table:style-name"],
                        attributes["table:visibility"] ?? "visible"
                    ))
                default:
                    break
                }
            }

            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                        qualifiedName: String?) {
                if name == "style:style" { tableStyle = nil }
            }
        }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.parse()
        return delegate.tables.map { table in
            let hidden = table.visibility != "visible" || table.style.map(delegate.hiddenStyles.contains) == true
            return (table.name, hidden)
        }
    }
}

/// Streaming parser for one table inside `content.xml`.
final class ODSParser: NSObject, XMLParserDelegate {
    /// A row that claims to repeat more than this is padding to the sheet's
    /// nominal size, not data. ODS writers routinely end a sheet with
    /// `number-rows-repeated="1048576"`, and materialising that is how a
    /// three-row file becomes a million empty rows.
    static let repetitionLimit = 1024

    private let tableName: String
    private let limit: Int
    private let onRow: (SheetRow) -> Bool

    private(set) var warnings: [XLSXWarning] = []
    private var insideTable = false
    /// Разбор остановлен нами: лист кончился, предел строк или вызывающий.
    private(set) var finished = false
    private var rowsEmitted = 0
    /// Внутри примечания к ячейке: его абзацы — не значение ячейки.
    private var annotationDepth = 0

    private var rowNumber = 0
    private var cells: [Int: CellValue] = [:]
    private var column = 0
    private var rowRepeat = 1

    private var cellValue: CellValue = .empty
    private var cellRepeat = 1
    private var rowSpan = 1
    /// Объединения, ещё действующие. ODS объявляет их на
    /// верхней ячейке — `table:number-rows-spanned` и
    /// `number-columns-spanned`, — а строки идут по порядку, так что
    /// запомнить и подставлять хватает.
    private var mergeFill = MergeFill()
    /// Объединения листа — для шапки в несколько строк.
    private(set) var merges: [XLSXReader.MergedRange] = []
    private var capturingText = false
    private var paragraphs: [String] = []
    private var text = ""

    init(tableName: String, limit: Int, onRow: @escaping (SheetRow) -> Bool) {
        self.tableName = tableName
        self.limit = limit
        self.onRow = onRow
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        guard !finished else { return }
        switch name {
        case "table:table":
            insideTable = (attributes["table:name"] ?? "") == tableName

        case "table:table-row":
            guard insideTable else { return }
            cells = [:]
            column = 0
            // Повтор — полностью: предел ограничивает, сколько строк
            // выдаётся, а не насколько сдвигается счёт.
            rowRepeat = Self.repetition(attributes["table:number-rows-repeated"])

        case "table:table-cell", "table:covered-table-cell":
            guard insideTable else { return }
            cellRepeat = Self.repetition(attributes["table:number-columns-repeated"])
            paragraphs = []
            // A covered cell is the part of a merge that is not the top-left:
            // its value lives in the anchor, and reading it as a value of its
            // own would duplicate the anchor's across the range.
            cellValue = name == "table:covered-table-cell" ? .empty : Self.value(of: attributes)
            rowSpan = Self.repetition(attributes["table:number-rows-spanned"])
            let columnSpan = Self.repetition(attributes["table:number-columns-spanned"])
            if rowSpan > 1 || columnSpan > 1 {
                // Строка ячейки — следующая за уже выданными.
                let range = XLSXReader.MergedRange(
                    firstRow: rowNumber + 1, lastRow: rowNumber + rowSpan,
                    firstColumn: column, lastColumn: column + columnSpan - 1
                )
                merges.append(range)
                mergeFill.add(range)
            }

        case "office:annotation":
            annotationDepth += 1

        case "text:p":
            guard insideTable, annotationDepth == 0 else { return }
            text = ""
            capturingText = true

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturingText { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard !finished else { return }
        switch name {
        case "office:annotation":
            annotationDepth = max(0, annotationDepth - 1)

        case "text:p":
            // Примечание к ячейке LibreOffice пишет внутрь ячейки, перед её
            // текстом, и оно приклеивалось к значению: «примечание\nзначение»
            // — в тексте, метаданных, названии колонки и ключе строки.
            guard insideTable, annotationDepth == 0 else { return }
            capturingText = false
            paragraphs.append(text)
            text = ""

        case "table:table-cell", "table:covered-table-cell":
            guard insideTable else { return }
            // A string cell holds its text in `<text:p>` elements rather than
            // in an attribute; several of them are several lines.
            if case .text = cellValue {
                let joined = paragraphs.joined(separator: "\n")
                cellValue = joined.isEmpty ? .empty : .text(joined)
            }
            if !cellValue.isEmpty {
                for offset in 0..<min(cellRepeat, Self.repetitionLimit) { cells[column + offset] = cellValue }
            }
            rowSpan = 1
            column += cellRepeat

        case "table:table-row":
            guard insideTable else { return }
            // Выдаётся не больше предела, а счёт строк идёт на весь повтор:
            // после трёх тысяч пустых строк данные стояли под номером 1035
            // вместо 3011 — и `row_number`, и просмотр указывали не туда.
            let emitted = min(rowRepeat, Self.repetitionLimit)
            defer { rowNumber += rowRepeat - emitted }
            for _ in 0..<emitted {
                rowNumber += 1
                guard !finished else { break }
                rowsEmitted += 1
                // Действующие объединения подставляются в строку до её
                // выдачи — вниз и вбок; истёкшие забываются.
                // В копию: у повторённой строки подставленное в первую из
                // повторов иначе оставалось и в следующих — за концом
                // объединения.
                var cells = cells
                mergeFill.fill(row: rowNumber, cells: &cells)
                if rowsEmitted > limit {
                    finished = true
                    warnings.append(.rowLimitReached(limit: limit))
                    parser.abortParsing()
                    return
                }
                if !onRow(SheetRow(number: rowNumber, cells: cells)) {
                    finished = true
                    parser.abortParsing()
                    return
                }
            }
            cells = [:]

        case "table:table":
            // The requested table is over; nothing after it is of interest.
            if insideTable {
                insideTable = false
                finished = true
                parser.abortParsing()
            }

        default:
            break
        }
    }

    static func repetition(_ raw: String?) -> Int {
        guard let raw, let value = Int(raw), value > 0 else { return 1 }
        return value
    }

    /// The value from the cell's own attributes — ODS says what it is, which is
    /// the one place it is simpler than XLSX.
    static func value(of attributes: [String: String]) -> CellValue {
        switch attributes["office:value-type"] {
        case "float":
            return attributes["office:value"].flatMap(Double.init).map(CellValue.number) ?? .empty
        case "percentage":
            // ODS честно говорит, что это проценты, — и раньше это знание
            // выбрасывалось: 0.15 уходило в текст числом.
            return attributes["office:value"].flatMap(Double.init)
                .map { CellValue.measured($0, .percent) } ?? .empty
        case "currency":
            // Код валюты стоит рядом: `office:currency="RUB"`. Его и пишем —
            // символа в файле нет, а «1234 RUB» человек прочтёт.
            let code = attributes["office:currency"] ?? ""
            guard let value = attributes["office:value"].flatMap(Double.init) else { return .empty }
            return code.isEmpty ? .number(value) : .measured(value, NumberUnit(suffix: code))
        case "boolean":
            let raw = attributes["office:boolean-value"]?.lowercased()
            return raw.map { CellValue.boolean($0 == "true" || $0 == "1") } ?? .empty
        case "date":
            return attributes["office:date-value"].flatMap(Self.date(from:)).map(CellValue.date) ?? .empty
        case "time":
            // A duration, not a moment: kept as the text the file wrote.
            return attributes["office:time-value"].map(CellValue.text) ?? .empty
        case "string":
            // Filled from `<text:p>` when the element closes.
            return .text("")
        case nil:
            return .empty
        default:
            return .text("")
        }
    }

    static func date(from raw: String) -> Date? {
        let withTime = ISO8601DateFormatter()
        withTime.formatOptions = [.withInternetDateTime]
        if let date = withTime.date(from: raw) { return date }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}
