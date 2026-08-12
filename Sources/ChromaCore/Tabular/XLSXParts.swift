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

    // MARK: - xl/styles.xml

    /// Built-in number formats that mean «this is a date or a time».
    static let builtInDateFormats: Set<Int> = Set(14...22).union(Set(45...47))

    /// Which style indices format their number as a date.
    ///
    /// This is the only way to tell a date from a number in XLSX: both are
    /// stored as a serial number, and only the cell's format says which.
    static func parseDateStyles(_ data: Data) -> Set<Int> {
        final class Delegate: NSObject, XMLParserDelegate {
            /// Custom format id → whether its mask is a date mask.
            var customDateFormats: [Int: Bool] = [:]
            var cellFormats: [Int] = []
            private var insideCellXfs = false

            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String]) {
                switch localName(name) {
                case "numFmt":
                    if let id = attributes["numFmtId"].flatMap(Int.init) {
                        customDateFormats[id] = XLSXReader.maskIsDate(attributes["formatCode"] ?? "")
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

        var result: Set<Int> = []
        for (index, formatID) in delegate.cellFormats.enumerated() {
            if builtInDateFormats.contains(formatID) || delegate.customDateFormats[formatID] == true {
                result.insert(index)
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

    init(sharedStrings: [String], dateStyles: Set<Int>, epoch: Date, uses1904: Bool,
         limit: Int, onRow: @escaping (SheetRow) -> Bool) {
        self.sharedStrings = sharedStrings
        self.dateStyles = dateStyles
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
            guard let styleIndex, dateStyles.contains(styleIndex) else { return .number(number) }
            guard let date = XLSXReader.date(fromSerial: number, epoch: epoch, uses1904: uses1904) else {
                phantomDates += 1
                return .number(number)
            }
            return .date(date)
        }
    }
}
