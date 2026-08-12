import Foundation

/// One cell's value, already typed.
///
/// Typed here rather than downstream because the type question can only be
/// answered while the workbook is open: a date in XLSX is a number, and the only
/// thing that says otherwise is the cell's format in `styles.xml`.
public enum CellValue: Hashable, Sendable {
    case text(String)
    case number(Double)
    case date(Date)
    case boolean(Bool)
    /// Missing, blank, or an error value like `#N/A` — all of which are «nothing
    /// to write», never a string saying «#N/A».
    case empty

    public var isEmpty: Bool { self == .empty }

    /// What the user sees in a preview. Dates go out in ISO-8601, the format
    /// this project uses everywhere for dates in metadata.
    public var displayText: String {
        switch self {
        case .text(let value): return value
        case .number(let value):
            // 4820 rather than 4820.0: a whole number that came from a
            // spreadsheet is a whole number to the person reading it.
            if value == value.rounded(), abs(value) < 1e15 {
                return String(Int64(value))
            }
            return String(value)
        case .date(let value): return ISO8601DateFormatter().string(from: value)
        case .boolean(let value): return value ? "true" : "false"
        case .empty: return ""
        }
    }
}

/// One row of a sheet, sparse on purpose.
///
/// Cells are keyed by **column index**, not by position in the file: XLSX omits
/// empty cells entirely, so a row that reads `A1, C1` in the file has nothing in
/// column B, and laying values out in the order they appear would shift every
/// value after the first gap one column to the left.
public struct SheetRow: Hashable, Sendable {
    /// 1-based, as the file numbers it — and not necessarily contiguous.
    public let number: Int
    public let cells: [Int: CellValue]

    public init(number: Int, cells: [Int: CellValue]) {
        self.number = number
        self.cells = cells
    }

    public func value(at column: Int) -> CellValue { cells[column] ?? .empty }

    public var lastColumn: Int { cells.keys.max() ?? -1 }

    public var isEmpty: Bool { cells.values.allSatisfy(\.isEmpty) }

    /// The row as a dense array, `width` cells wide.
    public func values(width: Int) -> [CellValue] {
        (0..<max(0, width)).map { value(at: $0) }
    }
}

public struct SheetInfo: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let isHidden: Bool
    /// Path of the sheet part inside the container.
    let path: String

    public init(name: String, isHidden: Bool, path: String) {
        self.name = name
        self.isHidden = isHidden
        self.path = path
    }
}

/// Something the reader noticed that the user should know about.
public enum XLSXWarning: Hashable, Sendable {
    /// A formula whose cached value the file does not carry: the workbook was
    /// never recalculated after that cell was written.
    case formulaWithoutValue(cells: Int)
    /// The sheet is longer than the limit and was cut.
    case rowLimitReached(limit: Int)
    /// Excel's non-existent 29 February 1900.
    case phantomLeapDay(cells: Int)

    public var text: String {
        switch self {
        case .formulaWithoutValue(let count):
            return String(localized: "формул без сохранённого значения: \(count) — файл не пересчитывался, ячейки прочитаны как пустые")
        case .rowLimitReached(let limit):
            return String(localized: "прочитаны первые \(limit) строк — лист длиннее предела")
        case .phantomLeapDay(let count):
            return String(localized: "ячеек с 29 февраля 1900 года: \(count) — такой даты не было, это известная ошибка Excel; значения оставлены числами")
        }
    }
}

public enum XLSXError: LocalizedError, Equatable {
    case notAWorkbook(String)
    case noSheets
    case sheetMissing(String)

    public var errorDescription: String? {
        switch self {
        case .notAWorkbook(let detail):
            return String(localized: "файл не читается как книга XLSX: \(detail)")
        case .noSheets:
            return String(localized: "в книге нет листов")
        case .sheetMissing(let name):
            return String(localized: "лист «\(name)» не найден в книге")
        }
    }
}

/// Reads `.xlsx` and `.xlsm` — the OOXML spreadsheet container.
///
/// **Not a `DocumentTextExtractor`, and deliberately not in the extraction
/// registry.** is emphatic: flattening a table into text produces rows
/// like `2024-03-15 | 4820 | Москва`, whose vectors mean nothing, and a user
/// given that would rightly conclude the search is broken. A table is a set of
/// records; it goes through its own pipeline, related to CSV import.
///
/// Parsing is streaming (`XMLParser`, not `XMLDocument`): a sheet with a million
/// rows must not be assembled in memory to be read.
public struct XLSXReader {
    private let container: ZIPContainerReader
    public let sheets: [SheetInfo]
    /// Shared strings, indexed as the cells reference them.
    private let sharedStrings: [String]
    /// Style index → whether that style formats its number as a date.
    private let dateStyles: Set<Int>
    private let epoch: Date
    /// True for the old 1904 workbooks, where serial 0 is 1904-01-01.
    public let uses1904Dates: Bool

    public static let supportedExtensions = ["xlsx", "xlsm"]
    /// Formats that look like spreadsheets and are not OOXML at all.
    public static let refusedExtensions = ["xls", "xlsb"]

    public struct Limits: Sendable {
        public var maxRows: Int
        /// Copy a merged cell's value into every cell of its range.
        ///
        /// Off by default, as asks: in a data table a merged cell usually
        /// means a heading spanning columns, and repeating it into every row
        /// would invent values nobody typed. It earns its keep in «document»
        /// mode, where the sheet is rendered as a whole.
        ///
        /// Only honoured by `rows(of:)`. The merge ranges are declared *after*
        /// the data in the sheet part, so a streaming pass cannot know about
        /// them while the rows go by.
        public var spreadMergedCells: Bool
        public init(maxRows: Int = 200_000, spreadMergedCells: Bool = false) {
            self.maxRows = maxRows
            self.spreadMergedCells = spreadMergedCells
        }
    }

    public init(url: URL) throws {
        let archive: ZIPContainerReader
        do {
            archive = try ZIPContainerReader(url: url)
        } catch {
            throw XLSXError.notAWorkbook(error.localizedDescription)
        }
        guard archive.contains("xl/workbook.xml") else {
            throw XLSXError.notAWorkbook(String(localized: "нет xl/workbook.xml"))
        }

        let workbook = try Self.parseWorkbook(try archive.read("xl/workbook.xml"))
        uses1904Dates = workbook.uses1904
        epoch = Self.epochDate(uses1904: workbook.uses1904)

        let relationships = (try? archive.read("xl/_rels/workbook.xml.rels"))
            .map(Self.parseRelationships) ?? [:]
        sheets = workbook.sheets.compactMap { sheet in
            guard let target = relationships[sheet.relationshipID] else { return nil }
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            guard archive.contains(path) else { return nil }
            return SheetInfo(name: sheet.name, isHidden: sheet.isHidden, path: path)
        }
        guard !sheets.isEmpty else { throw XLSXError.noSheets }

        sharedStrings = (try? archive.read("xl/sharedStrings.xml"))
            .map(Self.parseSharedStrings) ?? []
        dateStyles = (try? archive.read("xl/styles.xml"))
            .map(Self.parseDateStyles) ?? []
        container = archive
    }

    public func sheet(named name: String) throws -> SheetInfo {
        guard let sheet = sheets.first(where: { $0.name == name }) else {
            throw XLSXError.sheetMissing(name)
        }
        return sheet
    }

    /// Streams the rows of one sheet.
    ///
    /// `onRow` returns `false` to stop early — which is what the preview uses to
    /// read twenty rows out of fifty thousand without paying for the rest.
    @discardableResult
    public func forEachRow(
        of sheet: SheetInfo,
        limits: Limits = Limits(),
        _ onRow: @escaping (SheetRow) -> Bool
    ) throws -> [XLSXWarning] {
        let data = try container.read(sheet.path)
        let delegate = SheetParser(
            sharedStrings: sharedStrings,
            dateStyles: dateStyles,
            epoch: epoch,
            uses1904: uses1904Dates,
            limit: limits.maxRows,
            onRow: onRow
        )
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.warnings
    }

    /// All rows of a sheet, for callers small enough not to care.
    public func rows(of sheet: SheetInfo, limits: Limits = Limits()) throws -> (rows: [SheetRow], warnings: [XLSXWarning]) {
        var result: [SheetRow] = []
        let data = try container.read(sheet.path)
        let delegate = SheetParser(
            sharedStrings: sharedStrings, dateStyles: dateStyles, epoch: epoch,
            uses1904: uses1904Dates, limit: limits.maxRows,
            onRow: { result.append($0); return true }
        )
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()

        if limits.spreadMergedCells, !delegate.mergedRanges.isEmpty {
            result = Self.spreading(delegate.mergedRanges, over: result)
        }
        return (result, delegate.warnings)
    }

    /// Copies each merged range's top-left value across the range.
    static func spreading(_ ranges: [MergedRange], over rows: [SheetRow]) -> [SheetRow] {
        var byNumber = Dictionary(uniqueKeysWithValues: rows.map { ($0.number, $0.cells) })
        for range in ranges {
            guard let source = byNumber[range.firstRow]?[range.firstColumn], !source.isEmpty else { continue }
            for row in range.firstRow...range.lastRow {
                for column in range.firstColumn...range.lastColumn where !(row == range.firstRow && column == range.firstColumn) {
                    byNumber[row, default: [:]][column] = source
                }
            }
        }
        return byNumber.keys.sorted().map { SheetRow(number: $0, cells: byNumber[$0] ?? [:]) }
    }

    /// `A1:B3` as numbers. Rows are 1-based as the file writes them, columns
    /// 0-based as `SheetRow` keys them.
    public struct MergedRange: Hashable, Sendable {
        public let firstRow: Int, lastRow: Int, firstColumn: Int, lastColumn: Int

        public init?(reference: String) {
            let parts = reference.split(separator: ":")
            guard parts.count == 2,
                  let fromColumn = XLSXReader.columnIndex(ofReference: String(parts[0])),
                  let toColumn = XLSXReader.columnIndex(ofReference: String(parts[1])),
                  let fromRow = Int(parts[0].filter(\.isNumber)),
                  let toRow = Int(parts[1].filter(\.isNumber)) else { return nil }
            firstRow = min(fromRow, toRow)
            lastRow = max(fromRow, toRow)
            firstColumn = min(fromColumn, toColumn)
            lastColumn = max(fromColumn, toColumn)
        }
    }

    // MARK: - Column addressing

    /// `A` → 0, `Z` → 25, `AA` → 26. The letters of a cell reference like `BC12`.
    public static func columnIndex(ofReference reference: String) -> Int? {
        var index = 0
        var sawLetter = false
        for character in reference.uppercased() {
            guard let ascii = character.asciiValue else { return nil }
            if ascii >= 65, ascii <= 90 {
                index = index * 26 + Int(ascii - 64)
                sawLetter = true
            } else if character.isNumber {
                break
            } else {
                return nil
            }
        }
        return sawLetter ? index - 1 : nil
    }

    /// The inverse, for showing a column to the user.
    public static func columnName(_ index: Int) -> String {
        guard index >= 0 else { return "" }
        var value = index + 1
        var name = ""
        while value > 0 {
            let remainder = (value - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + remainder))) + name
            value = (value - 1) / 26
        }
        return name
    }

    // MARK: - Dates

    static func epochDate(uses1904: Bool) -> Date {
        var components = DateComponents()
        components.year = uses1904 ? 1904 : 1899
        components.month = uses1904 ? 1 : 12
        components.day = uses1904 ? 1 : 30
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: components)!
    }

    /// A serial number as a date, or `nil` for the day Excel invented.
    ///
    /// Excel treats 1900 as a leap year, so serial 60 is «29 February 1900» — a
    /// day that never existed. Everything after it is shifted by one, which is
    /// why the epoch is 30 December 1899 rather than 31 December: the phantom
    /// day absorbs the difference. Below serial 60 there is no phantom yet, so
    /// the epoch has to move back a day.
    static func date(fromSerial serial: Double, epoch: Date, uses1904: Bool) -> Date? {
        if uses1904 {
            return epoch.addingTimeInterval(serial * 86_400)
        }
        let whole = floor(serial)
        if whole == 60 { return nil }
        let correction: Double = whole < 60 ? 86_400 : 0
        return epoch.addingTimeInterval(serial * 86_400 + correction)
    }
}
