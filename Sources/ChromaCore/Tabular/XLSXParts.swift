import Foundation

// The XML halves of `XLSXReader`, kept apart so the reader itself stays about
// what a workbook *is* rather than about how OOXML spells it.

extension XLSXReader {
    // MARK: - xl/workbook.xml

    struct WorkbookSheet {
        let name: String
        let isHidden: Bool
        let relationshipID: String
    }

    struct Workbook {
        let sheets: [WorkbookSheet]
        let uses1904: Bool
    }

    static func parseWorkbook(_ data: Data) throws -> Workbook {
        final class Delegate: NSObject, XMLParserDelegate {
            var sheets: [WorkbookSheet] = []
            var uses1904 = false

            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String]) {
                switch Self.localName(name) {
                case "sheet":
                    // The relationship id carries a namespace prefix that
                    // workbooks spell differently; match on the local name.
                    let relationship = attributes.first { Self.localName($0.key) == "id" }?.value
                    sheets.append(WorkbookSheet(
                        name: attributes["name"] ?? "",
                        // «hidden» and «veryHidden» are both hidden to a person.
                        isHidden: (attributes["state"] ?? "visible") != "visible",
                        relationshipID: relationship ?? ""
                    ))
                case "workbookPr":
                    let value = attributes["date1904"] ?? attributes["dateCompatibility"] ?? "0"
                    uses1904 = value == "1" || value.lowercased() == "true"
                default:
                    break
                }
            }

            static func localName(_ name: String) -> String {
                name.split(separator: ":").last.map(String.init) ?? name
            }
        }

        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else {
            throw XLSXError.notAWorkbook(String(localized: "xl/workbook.xml не разбирается"))
        }
        return Workbook(sheets: delegate.sheets, uses1904: delegate.uses1904)
    }

    // MARK: - xl/_rels/workbook.xml.rels

    static func parseRelationships(_ data: Data) -> [String: String] {
        final class Delegate: NSObject, XMLParserDelegate {
            var map: [String: String] = [:]
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String]) {
                guard name.hasSuffix("Relationship"),
                      let id = attributes["Id"], let target = attributes["Target"] else { return }
                map[id] = target
            }
        }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.parse()
        return delegate.map
    }

    // MARK: - xl/sharedStrings.xml

    /// Text cells usually hold an **index into this table**, not text. Without
    /// it a sheet of names reads back as a column of integers.
    ///
    /// A shared string can be split into several `<r>` runs by formatting; the
    /// runs are concatenated, and `<rPh>` (phonetic guides on Japanese text) is
    /// skipped, or the reading would be interleaved with the word.
    static func parseSharedStrings(_ data: Data) -> [String] {
        final class Delegate: NSObject, XMLParserDelegate {
            var strings: [String] = []
            private var current: String?
            private var text = ""
            private var insidePhonetic = false

            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String]) {
                switch localName(name) {
                case "si": current = ""
                case "rPh": insidePhonetic = true
                case "t": text = ""
                default: break
                }
            }

            func parser(_ parser: XMLParser, foundCharacters string: String) {
                text += string
            }

            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                        qualifiedName: String?) {
                switch localName(name) {
                case "t":
                    if !insidePhonetic { current = (current ?? "") + text }
                    text = ""
                case "rPh": insidePhonetic = false
                case "si":
                    strings.append(current ?? "")
                    current = nil
                default: break
                }
            }

            private func localName(_ name: String) -> String {
                name.split(separator: ":").last.map(String.init) ?? name
            }
        }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.parse()
        return delegate.strings
    }

    // MARK: - Объединения ячеек

    /// Объединённые диапазоны листа — **до** разбора его строк.
    ///
    /// В файле `<mergeCells>` стоит после `<sheetData>`, поэтому потоковый
    /// проход узнаёт о них, когда строки уже ушли. Отдельный разбор всего
    /// XML ради двух десятков ссылок — расточительство, поэтому кусок
    /// находится поиском по байтам: литеральный `<mergeCells` не может
    /// оказаться внутри значения, там `<` записан как `&lt;`.
    static func mergeRanges(in data: Data) -> [MergedRange] {
        let open = Data("<mergeCells".utf8)
        let close = Data("</mergeCells>".utf8)
        guard let start = data.range(of: open) else { return [] }
        let tail = data[start.lowerBound...]
        let end = tail.range(of: close)?.upperBound ?? tail.endIndex
        guard let fragment = String(data: data[start.lowerBound..<end], encoding: .utf8) else { return [] }

        var ranges: [MergedRange] = []
        var rest = Substring(fragment)
        while let reference = rest.range(of: "ref=\"") {
            rest = rest[reference.upperBound...]
            guard let quote = rest.firstIndex(of: "\"") else { break }
            if let range = MergedRange(reference: String(rest[..<quote])) { ranges.append(range) }
            rest = rest[quote...]
        }
        return ranges
    }

    // MARK: - xl/styles.xml

    /// Built-in number formats that mean «this is a date or a time».
    static let builtInDateFormats: Set<Int> = Set(14...22).union(Set(45...47))

    /// Что стиль говорит о числе: дата это или число с единицей.
    struct StyleTable {
        /// Which style indices format their number as a date.
        var dateStyles: Set<Int> = []
        /// Индекс стиля → единица измерения, если формат её называет.
        var units: [Int: NumberUnit] = [:]
    }

    /// Which style indices format their number as a date, and which carry a unit.
    ///
    /// The date part is the only way to tell a date from a number in XLSX: both
    /// are stored as a serial number, and only the cell's format says which.
    static func parseStyles(_ data: Data) -> StyleTable {
        final class Delegate: NSObject, XMLParserDelegate {
            /// Custom format id → its mask.
            var customFormats: [Int: String] = [:]
            var cellFormats: [Int] = []
            private var insideCellXfs = false

            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String]) {
                switch localName(name) {
                case "numFmt":
                    if let id = attributes["numFmtId"].flatMap(Int.init) {
                        customFormats[id] = attributes["formatCode"] ?? ""
                    }
                case "cellXfs":
                    insideCellXfs = true
                case "xf":
                    // `cellStyleXfs` holds the same element and must not be
                    // counted: cell styles are indexed into `cellXfs` alone.
                    guard insideCellXfs else { return }
                    cellFormats.append(attributes["numFmtId"].flatMap(Int.init) ?? 0)
                default: break
                }
            }

            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                        qualifiedName: String?) {
                if localName(name) == "cellXfs" { insideCellXfs = false }
            }

            private func localName(_ name: String) -> String {
                name.split(separator: ":").last.map(String.init) ?? name
            }
        }

        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.parse()

        var result = StyleTable()
        for (index, formatID) in delegate.cellFormats.enumerated() {
            let mask = delegate.customFormats[formatID]
            if builtInDateFormats.contains(formatID) || mask.map(maskIsDate) == true {
                result.dateStyles.insert(index)
                continue
            }
            // Своя маска главнее встроенной: id перекрыт именно ради неё.
            if let mask, let unit = maskUnit(mask) {
                result.units[index] = unit
            } else if let unit = builtInUnits[formatID] {
                result.units[index] = unit
            }
        }
        return result
    }

    /// Whether a number-format mask describes a date or a time.
    ///
    /// Literals in quotes and locale/colour brackets are stripped first: a mask
    /// like `0" дней"` contains a `д`, and `[Red]0` a `d`, and neither is a date.
    static func maskIsDate(_ mask: String) -> Bool {
        guard !mask.isEmpty, mask != "General" else { return false }
        var stripped = ""
        var insideQuotes = false
        var insideBrackets = false
        var escaped = false
        for character in mask {
            if escaped { escaped = false; continue }
            switch character {
            case "\\": escaped = true
            case "\"": insideQuotes.toggle()
            case "[": insideBrackets = true
            case "]": insideBrackets = false
            default:
                if !insideQuotes && !insideBrackets { stripped.append(character) }
            }
        }
        // `m` alone is ambiguous — minutes in `h:mm` — but any mask that has a
        // date component also has y, d, or a repeated m next to y/d.
        let lower = stripped.lowercased()
        if lower.contains("y") || lower.contains("d") { return true }
        if lower.contains("h") || lower.contains("s") { return true }
        return false
    }

    /// Единицы всех встроенных форматов, где они есть.
    ///
    /// 9 и 10 — проценты; 5–8 и 37–44 — деньги, но символ там зависит от
    /// локали книги и в самом файле не записан. Поэтому денежные встроенные
    /// форматы здесь не значатся: подпись, взятая с потолка, хуже её
    /// отсутствия. Формат с явной маской — `#,##0" ₽"` или `[$₽-419]` —
    /// разбирается как обычно.
    static let builtInUnits: [Int: NumberUnit] = [9: .percent, 10: .percent]

    /// Единица измерения из маски формата.
    ///
    /// Берётся первая секция маски: секции за `;` описывают отрицательные
    /// числа, ноль и текст, а единица у них та же.
    static func maskUnit(_ mask: String) -> NumberUnit? {
        guard !mask.isEmpty, mask != "General", !maskIsDate(mask) else { return nil }
        let section = mask.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? mask

        var isPercent = false
        var before = ""
        var after = ""
        /// Числовая часть встретилась — дальше литералы идут в подпись.
        var sawNumber = false
        var insideQuotes = false
        var bracket = ""
        var insideBrackets = false
        var escaped = false

        func append(_ text: String) {
            if sawNumber { after += text } else { before += text }
        }

        for character in section {
            if escaped {
                escaped = false
                // Экранированный символ — литерал: `\ ` или `\-`.
                append(String(character))
                continue
            }
            if insideBrackets {
                if character == "]" {
                    insideBrackets = false
                    // `[$₽-419]` — символ валюты между `$` и дефисом. Всё
                    // остальное в скобках — цвет или условие, и это не подпись.
                    if bracket.hasPrefix("$") {
                        let body = bracket.dropFirst()
                        let symbol = body.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
                        if !symbol.isEmpty { append(symbol) }
                    }
                    bracket = ""
                } else {
                    bracket.append(character)
                }
                continue
            }
            switch character {
            case "\\": escaped = true
            case "\"": insideQuotes.toggle()
            case "[": insideBrackets = true
            case "%":
                if insideQuotes { append("%") } else { isPercent = true }
            case "0", "#", "?":
                if insideQuotes { append(String(character)) } else { sawNumber = true }
            case ".", ",", "E", "e", "+", "-", "/":
                if insideQuotes { append(String(character)) }
            case "*", "_":
                // Заполнение и отступ шириной символа — оформление, не подпись.
                // Следующий символ относится к ним и в подпись не идёт.
                escaped = true
            default:
                if insideQuotes { append(String(character)) }
                else if !character.isWhitespace, !character.isNumber { append(String(character)) }
            }
        }

        let prefix = before.trimmingCharacters(in: .whitespaces)
        var suffix = after.trimmingCharacters(in: .whitespaces)
        if isPercent { suffix = suffix.isEmpty ? "%" : "% " + suffix }
        guard !prefix.isEmpty || !suffix.isEmpty else { return nil }
        return NumberUnit(scale: isPercent ? 100 : 1, prefix: prefix, suffix: suffix)
    }
}

// MARK: - The sheet itself

/// Streaming parser for one `xl/worksheets/sheetN.xml`.
///
/// A class rather than a struct because `XMLParserDelegate` is a class protocol,
/// and streaming is the whole point: rows leave through the callback as they are
/// finished, so a sheet is never held in memory in full.
final class SheetParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private let dateStyles: Set<Int>
    /// Индекс стиля → единица измерения.
    private let unitStyles: [Int: NumberUnit]
    /// Объединения вниз, найденные до разбора строк: в файле они
    /// объявлены **после** данных, и потоковый проход о них иначе не узнал бы.
    private let verticalMerges: [Int: [XLSXReader.MergedRange]]
    /// Действующие объединения: колонка → (значение, последняя строка).
    private var spans: [Int: (value: CellValue, lastRow: Int)] = [:]
    private let epoch: Date
    private let uses1904: Bool
    private let limit: Int
    private let onRow: (SheetRow) -> Bool

    private(set) var warnings: [XLSXWarning] = []
    /// Declared after the data, which is why only the buffered read can use them.
    private(set) var mergedRanges: [XLSXReader.MergedRange] = []
    private var formulasWithoutValue = 0
    private var phantomDates = 0
    private var rowsEmitted = 0
    private var stopped = false

    private var rowNumber = 0
    private var cells: [Int: CellValue] = [:]
    private var columnIndex = 0
    private var cellType = ""
    private var styleIndex: Int?
    private var sawFormula = false
    private var text = ""
    private var capturing = false

    init(sharedStrings: [String], dateStyles: Set<Int>, unitStyles: [Int: NumberUnit] = [:],
         verticalMerges: [XLSXReader.MergedRange] = [],
         epoch: Date, uses1904: Bool,
         limit: Int, onRow: @escaping (SheetRow) -> Bool) {
        self.verticalMerges = Dictionary(grouping: verticalMerges, by: \.firstRow)
        self.sharedStrings = sharedStrings
        self.dateStyles = dateStyles
        self.unitStyles = unitStyles
        self.epoch = epoch
        self.uses1904 = uses1904
        self.limit = limit
        self.onRow = onRow
    }

    private func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        switch localName(name) {
        case "row":
            cells = [:]
            rowNumber = attributes["r"].flatMap(Int.init) ?? (rowNumber + 1)
        case "c":
            // The column comes from the **reference**, never from the order the
            // cells appear in: empty cells are simply absent.
            columnIndex = attributes["r"].flatMap(XLSXReader.columnIndex(ofReference:)) ?? columnIndex + 1
            cellType = attributes["t"] ?? "n"
            styleIndex = attributes["s"].flatMap(Int.init)
            sawFormula = false
        case "f":
            sawFormula = true
        case "mergeCell":
            if let reference = attributes["ref"], let range = XLSXReader.MergedRange(reference: reference) {
                mergedRanges.append(range)
            }
        case "v", "t":
            text = ""
            capturing = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        switch localName(name) {
        case "v", "t":
            capturing = false
            cells[columnIndex] = value(from: text)
            text = ""
        case "c":
            // A formula whose cached value the file does not carry. Said once
            // per sheet, counted — never silently read as blank.
            if sawFormula, cells[columnIndex] == nil { formulasWithoutValue += 1 }
        case "row":
            guard !stopped else { return }
            rowsEmitted += 1
            if rowsEmitted > limit {
                stopped = true
                warnings.append(.rowLimitReached(limit: limit))
                parser.abortParsing()
                return
            }
            // Объединение вниз относится к каждой строке диапазона.
            // Верхняя ячейка приходит первой, поэтому запомнить её и
            // подставлять дальше — всё, что нужно.
            for range in verticalMerges[rowNumber] ?? [] {
                if let value = cells[range.firstColumn], !value.isEmpty {
                    spans[range.firstColumn] = (value, range.lastRow)
                }
            }
            if !spans.isEmpty {
                spans = spans.filter { $0.value.lastRow >= rowNumber }
                for (column, span) in spans where cells[column] == nil {
                    cells[column] = span.value
                }
            }
            if !onRow(SheetRow(number: rowNumber, cells: cells)) {
                stopped = true
                parser.abortParsing()
            }
            cells = [:]
        default:
            break
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) { finish() }
    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { finish() }

    private func finish() {
        if formulasWithoutValue > 0 {
            warnings.append(.formulaWithoutValue(cells: formulasWithoutValue))
        }
        if phantomDates > 0 {
            warnings.append(.phantomLeapDay(cells: phantomDates))
        }
    }

    private func value(from raw: String) -> CellValue {
        switch cellType {
        case "s":
            // An index into the shared table, not text.
            guard let index = Int(raw), index >= 0, index < sharedStrings.count else { return .empty }
            return .text(sharedStrings[index])
        case "inlineStr", "str":
            // `inlineStr` keeps its text in the cell; `str` is a formula whose
            // result is text. Either way it is already text, not an index.
            return raw.isEmpty ? .empty : .text(raw)
        case "b":
            return .boolean(raw == "1" || raw.lowercased() == "true")
        case "e":
            // `#N/A`, `#DIV/0!` — an error is not a value.
            return .empty
        default:
            guard let number = Double(raw) else {
                return raw.isEmpty ? .empty : .text(raw)
            }
            guard let styleIndex, dateStyles.contains(styleIndex) else {
                // Единица — часть смысла числа: 0.15 при формате `0%`
                // человек читает как «15 %», и искать он будет именно это.
                if let styleIndex, let unit = unitStyles[styleIndex] {
                    return .measured(number, unit)
                }
                return .number(number)
            }
            guard let date = XLSXReader.date(fromSerial: number, epoch: epoch, uses1904: uses1904) else {
                phantomDates += 1
                return .number(number)
            }
            return .date(date)
        }
    }
}
