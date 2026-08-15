import Foundation
@testable import ChromaCore

/// Builds `.xlsx` workbooks in memory, the way asks for them: by a script
/// rather than by committing somebody's spreadsheet.
///
/// Every trap of has to be expressible here, so the builder writes the XML
/// parts directly instead of going through a convenience layer — a fixture that
/// cannot produce a sparse row or a formula without a cached value would not be
/// able to test the reader at all.
struct XLSXFixtureBuilder {
    /// One cell, spelled the way the file spells it.
    enum Cell {
        /// Text through the shared-strings table — how Excel normally stores it.
        case shared(String)
        /// Text inside the cell (`t="inlineStr"`).
        case inline(String)
        case number(Double)
        case boolean(Bool)
        /// An error value: `#N/A`, `#DIV/0!`.
        case error(String)
        /// A number rendered by a date format — the only thing that makes it
        /// a date rather than a number.
        case date(serial: Double)
        /// A formula; `cached` nil means the workbook was never recalculated.
        case formula(String, cached: Double?)
        /// Число под маской из `customNumberMask` — проценты, деньги, единицы.
        case measured(Double)
        /// Число под встроенным форматом (9 — `0%`, 10 — `0.00%`).
        case builtInFormat(Double, id: Int)
        /// Written as no cell at all, so the row is genuinely sparse.
        case absent
    }

    struct Sheet {
        var name: String
        var isHidden = false
        /// Rows of cells. `nil` row numbers are numbered consecutively.
        var rows: [[Cell]]
        /// Row numbers to write, when they should not be 1, 2, 3…
        var rowNumbers: [Int]?
        /// Merge ranges, written after the data as the format puts them.
        var merges: [String] = []
    }

    var sheets: [Sheet] = []
    var uses1904 = false
    /// Extra custom number format, id → mask, so a custom date mask can be tested.
    var customDateMask: String?
    /// Своя числовая маска — `0%`, `#,##0" ₽"`.
    var customNumberMask: String?

    private static let dateStyleIndex = 1
    private static let customStyleIndex = 2
    private static let numberMaskStyleIndex = 3
    /// Стили 4 и 5 — встроенные проценты 9 и 10.
    private static let builtInPercentStyles: [Int: Int] = [9: 4, 10: 5]

    func build() -> Data {
        var shared: [String] = []
        var sharedIndex: [String: Int] = [:]
        func indexOf(_ text: String) -> Int {
            if let existing = sharedIndex[text] { return existing }
            shared.append(text)
            sharedIndex[text] = shared.count - 1
            return shared.count - 1
        }

        var sheetParts: [(name: String, xml: String)] = []
        for (position, sheet) in sheets.enumerated() {
            var rows = ""
            for (offset, cells) in sheet.rows.enumerated() {
                let number = sheet.rowNumbers?[offset] ?? (offset + 1)
                var body = ""
                for (column, cell) in cells.enumerated() {
                    let reference = XLSXReader.columnName(column) + String(number)
                    switch cell {
                    case .absent:
                        continue
                    case .shared(let text):
                        body += "<c r=\"\(reference)\" t=\"s\"><v>\(indexOf(text))</v></c>"
                    case .inline(let text):
                        body += "<c r=\"\(reference)\" t=\"inlineStr\"><is><t>\(Self.escape(text))</t></is></c>"
                    case .number(let value):
                        body += "<c r=\"\(reference)\"><v>\(Self.plain(value))</v></c>"
                    case .boolean(let value):
                        body += "<c r=\"\(reference)\" t=\"b\"><v>\(value ? 1 : 0)</v></c>"
                    case .error(let code):
                        body += "<c r=\"\(reference)\" t=\"e\"><v>\(Self.escape(code))</v></c>"
                    case .date(let serial):
                        let style = customDateMask == nil ? Self.dateStyleIndex : Self.customStyleIndex
                        body += "<c r=\"\(reference)\" s=\"\(style)\"><v>\(Self.plain(serial))</v></c>"
                    case .formula(let formula, let cached):
                        let value = cached.map { "<v>\(Self.plain($0))</v>" } ?? ""
                        body += "<c r=\"\(reference)\"><f>\(Self.escape(formula))</f>\(value)</c>"
                    case .measured(let value):
                        body += "<c r=\"\(reference)\" s=\"\(Self.numberMaskStyleIndex)\"><v>\(Self.plain(value))</v></c>"
                    case .builtInFormat(let value, let id):
                        let style = Self.builtInPercentStyles[id] ?? 0
                        body += "<c r=\"\(reference)\" s=\"\(style)\"><v>\(Self.plain(value))</v></c>"
                    }
                }
                rows += "<row r=\"\(number)\">\(body)</row>"
            }
            let merges = sheet.merges.isEmpty ? "" :
                "<mergeCells count=\"\(sheet.merges.count)\">"
                + sheet.merges.map { "<mergeCell ref=\"\($0)\"/>" }.joined()
                + "</mergeCells>"
            let xml = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
            <sheetData>\(rows)</sheetData>\(merges)</worksheet>
            """
            sheetParts.append((sheet.name, xml))
            _ = position
        }

        var builder = ZIPFixtureBuilder()
        builder.entries.append(.init(path: "[Content_Types].xml", contents: Data(Self.contentTypes(count: sheets.count).utf8), deflated: true))
        builder.entries.append(.init(path: "_rels/.rels", contents: Data(Self.rootRels.utf8), deflated: true))
        builder.entries.append(.init(path: "xl/workbook.xml", contents: Data(workbookXML.utf8), deflated: true))
        builder.entries.append(.init(path: "xl/_rels/workbook.xml.rels", contents: Data(Self.workbookRels(count: sheets.count).utf8), deflated: true))
        builder.entries.append(.init(path: "xl/styles.xml", contents: Data(stylesXML.utf8), deflated: true))
        if !shared.isEmpty {
            builder.entries.append(.init(path: "xl/sharedStrings.xml", contents: Data(Self.sharedStringsXML(shared).utf8), deflated: true))
        }
        for (index, part) in sheetParts.enumerated() {
            builder.entries.append(.init(path: "xl/worksheets/sheet\(index + 1).xml", contents: Data(part.xml.utf8), deflated: true))
        }
        return builder.build()
    }

    // MARK: - Parts

    private var workbookXML: String {
        let entries = sheets.enumerated().map { index, sheet in
            let state = sheet.isHidden ? " state=\"hidden\"" : ""
            return "<sheet name=\"\(Self.escape(sheet.name))\" sheetId=\"\(index + 1)\"\(state) r:id=\"rId\(index + 1)\"/>"
        }.joined()
        let properties = uses1904 ? "<workbookPr date1904=\"1\"/>" : ""
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        \(properties)<sheets>\(entries)</sheets></workbook>
        """
    }

    /// Style 0 is General, style 1 is a built-in date format (14 = `m/d/yy`),
    /// style 2 uses the custom mask when one is asked for.
    private var stylesXML: String {
        var formats: [String] = []
        if let customDateMask {
            formats.append("<numFmt numFmtId=\"164\" formatCode=\"\(Self.escape(customDateMask))\"/>")
        }
        if let customNumberMask {
            formats.append("<numFmt numFmtId=\"165\" formatCode=\"\(Self.escape(customNumberMask))\"/>")
        }
        let custom = formats.isEmpty ? "" :
            "<numFmts count=\"\(formats.count)\">" + formats.joined() + "</numFmts>"
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\(custom)\
        <cellStyleXfs count="1"><xf numFmtId="0"/></cellStyleXfs>\
        <cellXfs count="6"><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="164"/>\
        <xf numFmtId="165"/><xf numFmtId="9"/><xf numFmtId="10"/></cellXfs>\
        </styleSheet>
        """
    }

    private static func sharedStringsXML(_ strings: [String]) -> String {
        let items = strings.map { "<si><t>\(escape($0))</t></si>" }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        count="\(strings.count)" uniqueCount="\(strings.count)">\(items)</sst>
        """
    }

    private static func workbookRels(count: Int) -> String {
        let entries = (1...max(1, count)).map {
            "<Relationship Id=\"rId\($0)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0).xml\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(entries)</Relationships>
        """
    }

    private static let rootRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
    </Relationships>
    """

    private static func contentTypes(count: Int) -> String {
        let sheets = (1...max(1, count)).map {
            "<Override PartName=\"/xl/worksheets/sheet\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        \(sheets)</Types>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Without exponent notation: `1.0E+15` in a `<v>` is not what Excel writes.
    private static func plain(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15
            ? String(Int64(value))
            : String(format: "%.10g", value)
    }
}
