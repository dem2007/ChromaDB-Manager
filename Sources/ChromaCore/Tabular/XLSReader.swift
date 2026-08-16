import Foundation

public enum XLSError: LocalizedError, Equatable {
    case notAWorkbook(String)
    /// Word 5/7 и старше: другой формат потока, и делать вид, что понял, нельзя.
    case tooOld
    case encrypted
    case corrupted(String)

    public var errorDescription: String? {
        switch self {
        case .notAWorkbook(let detail):
            return String(localized: "файл не читается как старая книга Excel: \(detail)")
        case .tooOld:
            return String(localized: "книга сохранена Excel 5.0 или старше — этот формат не читается")
        case .encrypted:
            return String(localized: "книга защищена паролем")
        case .corrupted(let detail):
            return String(localized: "книга повреждена: \(detail)")
        }
    }
}

/// Старая книга Excel (BIFF8, Excel 97–2003) — своей читалкой.
///
/// **Зачем своя.** До этого `.xls` читался через Numbers: приложение просили
/// экспортировать книгу в `.xlsx`, а дальше работала читалка 5.1. Это внешняя
/// зависимость в самом неудобном виде — чужая программа, разрешение
/// на автоматизацию и невозможность прочитать файл в автоматическом прогоне
///. Читалка OLE2 у проекта уже есть, а `.xls` — тот же
/// контейнер: внутри поток `Workbook` из записей BIFF.
///
/// **Что читается.** Имена и скрытость листов, общие строки, числа, даты,
/// логические значения, ошибки, кэшированные значения формул — всё, из чего
/// состоит табличный источник. Формулы **не вычисляются**: берётся
/// значение, записанное Excel при сохранении, ровно как у `.xlsx`.
public struct XLSReader {
    public struct Limits: Sendable {
        public var maxRows: Int
        public init(maxRows: Int = 1_000_000) { self.maxRows = maxRows }
    }

    public let sheets: [SheetInfo]
    /// True для старых книг, где ноль — это 1904-01-01.
    public let uses1904Dates: Bool

    private let stream: Data
    private let sharedStrings: [String]
    private let styles: XLSXReader.StyleTable
    private let epoch: Date
    /// Имя листа → смещение его подпотока в `Workbook`.
    private let offsets: [String: Int]

    public init(url: URL) throws {
        let container: CFBContainerReader
        do {
            container = try CFBContainerReader(url: url)
        } catch {
            throw XLSError.notAWorkbook(error.localizedDescription)
        }
        // `Workbook` — BIFF8; `Book` — BIFF5/7, другой формат записей.
        guard let stream = try? container.read("Workbook") else {
            if container.entry(named: "Book") != nil { throw XLSError.tooOld }
            throw XLSError.notAWorkbook(String(localized: "в контейнере нет потока книги"))
        }
        self.stream = stream

        let globals = try Self.readGlobals(stream)
        sharedStrings = globals.sharedStrings
        styles = globals.styles
        uses1904Dates = globals.uses1904
        epoch = XLSXReader.epochDate(uses1904: globals.uses1904)
        sheets = globals.sheets.map { SheetInfo(name: $0.name, isHidden: $0.isHidden, path: $0.name) }
        offsets = Dictionary(globals.sheets.map { ($0.name, $0.offset) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Записи BIFF

    /// Одна запись потока: тип, содержимое и где искать следующую.
    struct Record {
        let type: UInt16
        let payload: Data
        let next: Int
    }

    enum Kind {
        static let formula: UInt16 = 0x0006
        static let eof: UInt16 = 0x000A
        static let dateMode: UInt16 = 0x0022
        static let continued: UInt16 = 0x003C
        static let boundSheet: UInt16 = 0x0085
        static let multipleRK: UInt16 = 0x00BD
        static let multipleBlank: UInt16 = 0x00BE
        static let richString: UInt16 = 0x00D6
        static let extendedFormat: UInt16 = 0x00E0
        static let sharedStrings: UInt16 = 0x00FC
        static let labelSST: UInt16 = 0x00FD
        static let blank: UInt16 = 0x0201
        static let number: UInt16 = 0x0203
        static let label: UInt16 = 0x0204
        static let boolOrError: UInt16 = 0x0205
        static let string: UInt16 = 0x0207
        static let bof: UInt16 = 0x0809
        static let filePass: UInt16 = 0x002F
        static let format: UInt16 = 0x041E
        static let rk: UInt16 = 0x027E
    }

    static func record(in stream: Data, at offset: Int) -> Record? {
        guard offset >= 0, offset + 4 <= stream.count else { return nil }
        let type = CFBContainerReader.u16(stream, offset)
        let length = Int(CFBContainerReader.u16(stream, offset + 2))
        let start = offset + 4
        guard start + length <= stream.count else { return nil }
        return Record(
            type: type,
            payload: stream[(stream.startIndex + start)..<(stream.startIndex + start + length)],
            next: start + length
        )
    }

    // MARK: - Глобальный подпоток

    struct Globals {
        var sheets: [(name: String, offset: Int, isHidden: Bool)] = []
        var sharedStrings: [String] = []
        var styles = XLSXReader.StyleTable()
        var uses1904 = false
    }

    static func readGlobals(_ stream: Data) throws -> Globals {
        var result = Globals()
        var formats: [Int: String] = [:]
        var cellFormats: [Int] = []
        var offset = 0

        while let record = self.record(in: stream, at: offset) {
            offset = record.next
            switch record.type {
            case Kind.eof:
                // Глобальный подпоток кончился — дальше идут листы.
                var styles = XLSXReader.StyleTable()
                for (index, formatID) in cellFormats.enumerated() {
                    let mask = formats[formatID]
                    if XLSXReader.builtInDateFormats.contains(formatID) || mask.map(XLSXReader.maskIsDate) == true {
                        styles.dateStyles.insert(index)
                        continue
                    }
                    if let mask, let unit = XLSXReader.maskUnit(mask) { styles.units[index] = unit }
                }
                result.styles = styles
                return result
            case Kind.filePass:
                throw XLSError.encrypted
            case Kind.dateMode:
                result.uses1904 = CFBContainerReader.u16(record.payload, 0) == 1
            case Kind.format:
                let id = Int(CFBContainerReader.u16(record.payload, 0))
                formats[id] = string(in: record.payload, at: 2).text
            case Kind.extendedFormat:
                cellFormats.append(Int(CFBContainerReader.u16(record.payload, 2)))
            case Kind.boundSheet:
                let position = Int(CFBContainerReader.u32(record.payload, 0))
                let visibility = CFBContainerReader.byte(record.payload, 4) & 0x03
                let name = shortString(in: record.payload, at: 6)
                guard !name.isEmpty else { break }
                result.sheets.append((name: name, offset: position, isHidden: visibility != 0))
            case Kind.sharedStrings:
                // Таблица общих строк не помещается в одну запись: продолжения
                // идут следом, и строка может рваться прямо посередине.
                var chunks = [record.payload]
                var next = record.next
                while let continued = self.record(in: stream, at: next), continued.type == Kind.continued {
                    chunks.append(continued.payload)
                    next = continued.next
                }
                offset = next
                result.sharedStrings = sharedStrings(in: chunks)
            default:
                break
            }
        }
        throw XLSError.corrupted(String(localized: "глобальный подпоток не закончился"))
    }

    // MARK: - Лист

    public func rows(of sheet: SheetInfo, limits: Limits = Limits()) throws -> (rows: [SheetRow], warnings: [XLSXWarning]) {
        guard let start = offsets[sheet.name] else { return ([], []) }
        var cells: [Int: [Int: CellValue]] = [:]
        var warnings: [XLSXWarning] = []
        var formulasWithoutValue = 0
        var phantomDays = 0
        var truncated = false
        /// Ячейка, чьё значение придёт следующей записью `STRING`.
        var pendingFormula: (row: Int, column: Int)?
        var offset = start

        func put(_ row: Int, _ column: Int, _ value: CellValue) {
            guard !truncated else { return }
            if cells[row] == nil, cells.count >= limits.maxRows {
                truncated = true
                warnings.append(.rowLimitReached(limit: limits.maxRows))
                return
            }
            cells[row, default: [:]][column] = value
        }

        /// Число под стилем ячейки: дата, величина с единицей или просто число.
        func numeric(_ value: Double, style: Int) -> CellValue {
            if styles.dateStyles.contains(style) {
                guard let date = XLSXReader.date(fromSerial: value, epoch: epoch, uses1904: uses1904Dates) else {
                    phantomDays += 1
                    return .empty
                }
                return .date(date)
            }
            if let unit = styles.units[style] { return .measured(value, unit) }
            return .number(value)
        }

        while let record = Self.record(in: stream, at: offset) {
            offset = record.next
            let payload = record.payload
            switch record.type {
            case Kind.eof:
                if formulasWithoutValue > 0 { warnings.append(.formulaWithoutValue(cells: formulasWithoutValue)) }
                if phantomDays > 0 { warnings.append(.phantomLeapDay(cells: phantomDays)) }
                let result = cells.keys.sorted().map { number in
                    SheetRow(number: number + 1, cells: cells[number] ?? [:])
                }
                return (result, warnings)
            case Kind.labelSST:
                let index = Int(CFBContainerReader.u32(payload, 6))
                let text = index < sharedStrings.count ? sharedStrings[index] : ""
                if !text.isEmpty { put(Self.row(payload), Self.column(payload), .text(text)) }
            case Kind.label, Kind.richString:
                let text = Self.string(in: payload, at: 6).text
                if !text.isEmpty { put(Self.row(payload), Self.column(payload), .text(text)) }
            case Kind.number:
                let bits = UInt64(CFBContainerReader.u32(payload, 6)) | (UInt64(CFBContainerReader.u32(payload, 10)) << 32)
                put(Self.row(payload), Self.column(payload), numeric(Double(bitPattern: bits), style: Self.style(payload)))
            case Kind.rk:
                put(Self.row(payload), Self.column(payload),
                    numeric(Self.rk(CFBContainerReader.u32(payload, 6)), style: Self.style(payload)))
            case Kind.multipleRK:
                // Одна запись на несколько подряд идущих ячеек строки.
                let row = Self.row(payload)
                let first = Int(CFBContainerReader.u16(payload, 2))
                let count = max(0, (payload.count - 6) / 6)
                for index in 0..<count {
                    let base = 4 + index * 6
                    let style = Int(CFBContainerReader.u16(payload, base))
                    put(row, first + index, numeric(Self.rk(CFBContainerReader.u32(payload, base + 2)), style: style))
                }
            case Kind.boolOrError:
                // Ошибка — это «нечего писать», а не строка «#Н/Д».
                if CFBContainerReader.byte(payload, 7) == 0 {
                    put(Self.row(payload), Self.column(payload), .boolean(CFBContainerReader.byte(payload, 6) != 0))
                }
            case Kind.formula:
                let row = Self.row(payload), column = Self.column(payload)
                // Формулы не вычисляются: берётся значение, записанное Excel.
                if CFBContainerReader.u16(payload, 12) == 0xFFFF {
                    switch CFBContainerReader.byte(payload, 6) {
                    case 0: pendingFormula = (row, column)      // строка — в следующей записи
                    case 1: put(row, column, .boolean(CFBContainerReader.byte(payload, 8) != 0))
                    case 2, 3: break                            // ошибка или пусто
                    default: formulasWithoutValue += 1
                    }
                } else {
                    let bits = UInt64(CFBContainerReader.u32(payload, 6)) | (UInt64(CFBContainerReader.u32(payload, 10)) << 32)
                    put(row, column, numeric(Double(bitPattern: bits), style: Self.style(payload)))
                }
            case Kind.string:
                if let pending = pendingFormula {
                    let text = Self.string(in: payload, at: 0).text
                    if !text.isEmpty { put(pending.row, pending.column, .text(text)) }
                    pendingFormula = nil
                }
            case Kind.blank, Kind.multipleBlank:
                break
            default:
                break
            }
        }
        throw XLSError.corrupted(String(localized: "подпоток листа «\(sheet.name)» не закончился"))
    }

    // MARK: - Разбор значений

    static func row(_ payload: Data) -> Int { Int(CFBContainerReader.u16(payload, 0)) }
    static func column(_ payload: Data) -> Int { Int(CFBContainerReader.u16(payload, 2)) }
    static func style(_ payload: Data) -> Int { Int(CFBContainerReader.u16(payload, 4)) }

    /// Сжатое число: два младших бита говорят, целое оно и делить ли на сто.
    static func rk(_ value: UInt32) -> Double {
        var number: Double
        if value & 0x02 != 0 {
            number = Double(Int32(bitPattern: value) >> 2)
        } else {
            number = Double(bitPattern: UInt64(value & 0xFFFF_FFFC) << 32)
        }
        if value & 0x01 != 0 { number /= 100 }
        return number
    }

    /// Строка с однобайтовой длиной — так записаны имена листов.
    static func shortString(in data: Data, at offset: Int) -> String {
        let count = Int(CFBContainerReader.byte(data, offset))
        guard count > 0 else { return "" }
        let compressed = CFBContainerReader.byte(data, offset + 1) & 0x01 == 0
        var units: [UInt16] = []
        for index in 0..<count {
            units.append(compressed
                ? UInt16(CFBContainerReader.byte(data, offset + 2 + index))
                : CFBContainerReader.u16(data, offset + 2 + index * 2))
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Строка с двухбайтовой длиной и её длина в байтах.
    static func string(in data: Data, at offset: Int) -> (text: String, length: Int) {
        let count = Int(CFBContainerReader.u16(data, offset))
        guard count > 0 else { return ("", 3) }
        let flags = CFBContainerReader.byte(data, offset + 2)
        let compressed = flags & 0x01 == 0
        var cursor = offset + 3
        // Богатый текст и фонетика дописывают свои размеры **перед** знаками.
        let runs = flags & 0x08 != 0 ? Int(CFBContainerReader.u16(data, cursor)) : 0
        if flags & 0x08 != 0 { cursor += 2 }
        let phonetic = flags & 0x04 != 0 ? Int(CFBContainerReader.u32(data, cursor)) : 0
        if flags & 0x04 != 0 { cursor += 4 }

        var units: [UInt16] = []
        for index in 0..<count {
            units.append(compressed
                ? UInt16(CFBContainerReader.byte(data, cursor + index))
                : CFBContainerReader.u16(data, cursor + index * 2))
        }
        let bytes = compressed ? count : count * 2
        return (String(decoding: units, as: UTF16.self), cursor - offset + bytes + runs * 4 + phonetic)
    }

    /// Таблица общих строк, собранная по кускам.
    ///
    /// Строка рвётся границей записи, **и признак сжатия у продолжения свой**:
    /// половина строки может лежать однобайтовой, а вторая — двухбайтовой.
    /// Это первая ловушка формата, и она молчаливая — текст просто выходит
    /// крякозябрами.
    static func sharedStrings(in chunks: [Data]) -> [String] {
        var result: [String] = []
        guard let first = chunks.first else { return result }
        let total = Int(CFBContainerReader.u32(first, 4))
        let capacity = chunks.reduce(0) { $0 + $1.count }
        var chunk = 0
        var offset = 8
        var consumed = 8

        /// Следующий байт, или `nil`, если куски кончились. Переход к новому
        /// куску — только здесь: тогда «где мы» знает одно место.
        func byte() -> UInt8? {
            while chunk < chunks.count, offset >= chunks[chunk].count {
                chunk += 1
                offset = 0
            }
            guard chunk < chunks.count else { return nil }
            defer { offset += 1; consumed += 1 }
            return CFBContainerReader.byte(chunks[chunk], offset)
        }

        func number(_ count: Int) -> Int {
            var value = 0
            for shift in 0..<count { value |= Int(byte() ?? 0) << (8 * shift) }
            return value
        }

        /// Пропустить столько байт, сколько **осталось**, а не сколько
        /// написано. Мусорная длина из рассинхронизованного разбора доходила
        /// до четырёх миллиардов, и пропуск такого хвоста занимал минуты
        /// на файле в семьдесят килобайт — разбор не падал, он замирал.
        func skip(_ count: Int) {
            for _ in 0..<min(max(0, count), capacity - consumed) { _ = byte() }
        }

        /// Строка кончилась на границе куска — у продолжения свой признак
        /// сжатия: половина строки может лежать однобайтовой, а вторая
        /// двухбайтовой. Это первая ловушка формата, и она молчаливая:
        /// текст просто выходит крякозябрами.
        func crossedBoundary() -> Bool {
            chunk < chunks.count && offset >= chunks[chunk].count
        }

        for _ in 0..<max(0, min(total, 1_000_000)) {
            guard chunk < chunks.count else { break }
            let count = number(2)
            // Длиннее этого строк в формате не бывает: значит, разбор сбился,
            // и продолжать — читать мусор.
            guard count >= 0, count <= 32_767, let flags = byte() else { break }
            var compressed = flags & 0x01 == 0
            let runs = flags & 0x08 != 0 ? number(2) : 0
            let phonetic = flags & 0x04 != 0 ? number(4) : 0

            var units: [UInt16] = []
            units.reserveCapacity(count)
            var read = 0
            while read < count {
                if crossedBoundary() {
                    chunk += 1
                    offset = 0
                    guard chunk < chunks.count, let next = byte() else { break }
                    compressed = next & 0x01 == 0
                }
                guard let low = byte() else { break }
                units.append(compressed ? UInt16(low) : UInt16(low) | (UInt16(byte() ?? 0) << 8))
                read += 1
            }
            skip(runs * 4 + phonetic)
            result.append(String(decoding: units, as: UTF16.self))
        }
        return result
    }
}
