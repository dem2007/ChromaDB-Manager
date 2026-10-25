import Foundation

/// Which tabular format a file is, and what can be done with it.
public enum TabularFormat: String, Sendable, CaseIterable {
    case workbook      // .xlsx, .xlsm
    case delimited     // .csv, .tsv
    case openDocument  // .ods
    case numbers //.numbers — through the application, as in
    /// `.xls` — the old binary Excel format (BIFF), read the same way
    /// `.numbers` is: by asking Numbers to convert it.
    ///
    /// Numbers declares `com.microsoft.excel.xls` as a type it **edits**, so
    /// the converter already in the app covers it and no BIFF parser has to be
    /// written — which, without third-party libraries (правило 6), would mean
    /// an OLE2 container reader plus a record stream whose shared-string table
    /// and date formats fail quietly rather than loudly.
    case legacyExcel
    /// `.xlsb`: binary OOXML, and Numbers does not open it either. Named and
    /// refused rather than half-parsed.
    case legacyBinary

    /// Формат книги — по содержимому, а не по имени файла.
    ///
    /// Имя — обещание, подпись — факт. Тот же принцип уже записан у офисных
    /// документов: «`.docx`, переименованный в `.doc`, остался `.docx`».
    /// У книг он не соблюдался, и это стоило заказчику 49 файлов: все они
    /// названы `.xlsx`, а внутри — старый двоичный Excel, и отказ звучал как
    /// «файл не похож на ZIP-архив», то есть не называл ни причины, ни выхода.
    public static func of(_ url: URL) -> TabularFormat? {
        guard let named = named(url.pathExtension.lowercased()) else { return nil }
        switch (named, signature(of: url)) {
        // Старая книга под именем новой: читается через приложение, как `.xls`.
        case (.workbook, .ole2): return .legacyExcel
        // И наоборот: `.xlsx`, переименованный в `.xls`, читается своей
        // читалкой — просить у Numbers то, что умеем сами, незачем.
        case (.legacyExcel, .zip), (.legacyBinary, .zip): return .workbook
        default: return named
        }
    }

    static func named(_ extension: String) -> TabularFormat? {
        switch `extension` {
        case "xlsx", "xlsm": return .workbook
        case "csv", "tsv": return .delimited
        case "ods": return .openDocument
        case "numbers": return .numbers
        case "xls": return .legacyExcel
        case "xlsb": return .legacyBinary
        default: return nil
        }
    }

    /// Что за файл на самом деле — по первым байтам.
    enum Signature {
        case zip, ole2, other
    }

    static func signature(of url: URL) -> Signature {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .other }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8), head.count >= 8 else { return .other }
        if head.prefix(4).elementsEqual([0x50, 0x4B, 0x03, 0x04]) { return .zip }
        if head.elementsEqual([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) { return .ole2 }
        return .other
    }

    /// Formats read by asking the application that owns them — off by default,
    /// and never in an automatic run.
    ///
    /// `.xls` остаётся в списке как **запасной** путь: с старые книги
    /// читаются своей читалкой, и приложение спрашивают только про те,
    /// что сохранены Excel 5.0 и старше.
    public static let applicationExportExtensions = ["numbers", "xls"]

    public static var allExtensions: [String] {
        ["xlsx", "xlsm", "csv", "tsv", "ods", "numbers", "xls"]
    }
}

public enum TabularError: LocalizedError, Equatable {
    /// A format that is a spreadsheet but not one this app reads.
    case legacyBinaryFormat(String)
    case empty
    case undecodable

    public var errorDescription: String? {
        switch self {
        case .legacyBinaryFormat(let ext):
            return String(localized: "формат .\(ext) не поддерживается — это двоичный формат Excel, а не вариант .xlsx, и Numbers его тоже не открывает; пересохраните файл как .xlsx")
        case .empty:
            return String(localized: "файл пуст")
        case .undecodable:
            return String(localized: "не удалось определить кодировку файла")
        }
    }
}

/// The encodings a CSV actually turns up in.
public enum TextEncodingGuess: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    public var id: String { rawValue }

    case utf8
    case utf8WithBOM
    case windows1251
    case utf16LE
    case utf16BE
    /// Старые русские кодировки: KOI8-R — почта и Unix, CP866 — DOS и
    /// выгрузки старых учётных программ.
    case koi8R
    case cp866

    public var encoding: String.Encoding {
        switch self {
        case .utf8, .utf8WithBOM: return .utf8
        case .windows1251: return .windowsCP1251
        case .koi8R: return Self.legacy(.KOI8_R)
        case .cp866: return Self.legacy(.dosRussian)
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        }
    }

    public var title: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8WithBOM: return String(localized: "UTF-8 с BOM")
        case .windows1251: return "Windows-1251"
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        case .koi8R: return "KOI8-R"
        case .cp866: return "CP866 (DOS)"
        }
    }

    private static func legacy(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }
}

/// How a delimited file is to be read — detected, and overridable by hand
/// ( requires both).
public struct DelimitedFormat: Codable, Hashable, Sendable {
    public var encoding: TextEncodingGuess
    public var delimiter: String
    /// Why these were chosen. Shown next to the choice so the user can disagree
    /// with a reason.
    public var reason: String

    public init(encoding: TextEncodingGuess, delimiter: String, reason: String = "") {
        self.encoding = encoding
        self.delimiter = delimiter
        self.reason = reason
    }

    public var delimiterTitle: String {
        switch delimiter {
        case "\t": return String(localized: "табуляция")
        case ",": return String(localized: "запятая")
        case ";": return String(localized: "точка с запятой")
        case "|": return String(localized: "вертикальная черта")
        default: return delimiter
        }
    }
}

/// Reads `.csv` and `.tsv` into the same rows a workbook produces.
///
/// Converging on `SheetRow` is the point: everything downstream — sheet modes,
/// the mapping, row identity — is then shared between a spreadsheet and a CSV
/// instead of existing twice.
public enum DelimitedTableReader {
    public static let candidateDelimiters = [",", ";", "\t", "|"]

    // MARK: - Encoding

    public static func detectEncoding(_ data: Data) -> TextEncodingGuess? {
        // A BOM is a statement, not a guess.
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8WithBOM }
        if data.starts(with: [0xFF, 0xFE]) { return .utf16LE }
        if data.starts(with: [0xFE, 0xFF]) { return .utf16BE }

        // Valid UTF-8 is almost never valid by accident: the multi-byte
        // sequences are too constrained.
        if String(data: data, encoding: .utf8) != nil { return .utf8 }

        // Windows-1251 rather than Latin-1. Latin-1 decodes *any* byte, so it
        // never fails and silently turns Cyrillic into «Ïðèâåò» — a fallback
        // that always succeeds is a fallback that hides the problem.
        return singleByteCyrillic(data)
    }

    /// Однобайтовая русская кодировка — по тому, какой из прочтений текст
    /// похож на русский.
    ///
    /// Windows-1251, KOI8-R и CP866 принимают почти любой байт, поэтому
    /// «прочиталось» ничего не говорит: файл в KOI8-R, прочитанный как
    /// Windows-1251, — «рТЙЧЕФ, НЙТ!» вместо «Привет, мир!», и такой текст
    /// индексировался и не находился ни по одному слову. Верное прочтение
    /// узнаётся по самому тексту: в русском тексте буквы в основном строчные,
    /// частые буквы — «о», «е», «а», «и», «н», «т», а заглавная посреди
    /// слова и псевдографика — признак чужой кодировки. При равенстве —
    /// Windows-1251, самая частая.
    static func singleByteCyrillic(_ data: Data) -> TextEncodingGuess? {
        // Оценки хватает по началу файла: кодировка у файла одна.
        let sample = data.prefix(64 * 1024)
        var best: (guess: TextEncodingGuess, score: Int)?
        for guess in [TextEncodingGuess.windows1251, .koi8R, .cp866] {
            guard let text = String(data: sample, encoding: guess.encoding) else { continue }
            let score = russianScore(text)
            // KOI8-R и CP866 — только по явным признакам русского текста:
            // без них (английский текст в cp1252 с «умными» кавычками) CP866
            // читал кавычки заглавными «У», «Ф» и выигрывал у Windows-1251,
            // для которой кавычки на тех же местах.
            if guess != .windows1251, score <= 0 { continue }
            if best == nil || score > best!.score { best = (guess, score) }
        }
        // Обрезанная выборка могла разрезать знак — весь файл проверяется
        // отдельно.
        guard let best, String(data: data, encoding: best.guess.encoding) != nil else {
            return String(data: data, encoding: .windowsCP1251) != nil ? .windows1251 : nil
        }
        return best.guess
    }

    /// Насколько текст похож на русский: частые строчные буквы — в плюс,
    /// заглавная после строчной и знаки вне букв и пунктуации — в минус.
    static func russianScore(_ text: String) -> Int {
        let frequent = Set("оеаинтсрвлкмдпу")
        var score = 0
        var previousLower = false
        for scalar in text.unicodeScalars {
            let value = scalar.value
            guard value >= 0x80 else { previousLower = false; continue }
            let isCyrillic = (0x0410...0x044F).contains(value) || value == 0x0401 || value == 0x0451
            if isCyrillic {
                let character = Character(scalar)
                if character.isLowercase {
                    score += frequent.contains(character) ? 2 : 1
                    previousLower = true
                } else {
                    if previousLower { score -= 3 }
                    previousLower = false
                }
            } else {
                // Псевдографика, «Ґ», «ў», «Џ» и прочее, чем чужая кодировка
                // читает русские буквы. Кавычки «» и тире — обычный текст.
                if !"«»—–…№".unicodeScalars.contains(scalar) { score -= 2 }
                previousLower = false
            }
        }
        return score
    }

    public static func decode(_ data: Data, as guess: TextEncodingGuess) -> String? {
        var payload = data
        switch guess {
        case .utf8WithBOM: payload = data.dropFirst(3)
        case .utf16LE, .utf16BE: payload = data.dropFirst(2)
        default: break
        }
        return String(data: payload, encoding: guess.encoding)
    }

    // MARK: - Delimiter

    /// The delimiter, chosen by which candidate divides the first lines into the
    /// same number of fields every time.
    ///
    /// Not by file extension: Excel in a Russian locale writes `.csv` with
    /// **semicolons**, and reading that as comma-separated yields one column
    /// containing the whole row — a failure that looks like a successful import.
    public static func detectDelimiter(in text: String, extensionHint: String? = nil) -> (delimiter: String, reason: String) {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .prefix(20)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        if let extensionHint, extensionHint.lowercased() == "tsv" {
            return ("\t", String(localized: "по расширению .tsv"))
        }
        guard !lines.isEmpty else { return (",", String(localized: "файл пуст — взята запятая")) }

        var best: (delimiter: String, fields: Int, consistent: Bool)?
        for candidate in candidateDelimiters {
            let counts = lines.map { countOutsideQuotes(candidate, in: $0) }
            guard let first = counts.first, first > 0 else { continue }
            let consistent = counts.allSatisfy { $0 == first }
            // A consistent candidate always beats an inconsistent one; among
            // equals, more fields wins — a line split into six columns by
            // semicolons is a better reading than two by commas.
            let better: Bool
            if let best {
                better = (consistent && !best.consistent) || (consistent == best.consistent && first + 1 > best.fields)
            } else {
                better = true
            }
            if better { best = (candidate, first + 1, consistent) }
        }

        guard let best else {
            return (",", String(localized: "разделителей не найдено — файл читается как одна колонка"))
        }
        let name = DelimitedFormat(encoding: .utf8, delimiter: best.delimiter).delimiterTitle
        return (
            best.delimiter,
            best.consistent
                ? String(localized: "\(name): одинаковое число колонок (\(best.fields)) во всех проверенных строках")
                : String(localized: "\(name): встречается чаще прочих, но число колонок в строках расходится")
        )
    }

    /// Counts a delimiter only where it separates fields — a semicolon inside
    /// `"Иванов; Пётр"` is part of the value.
    static func countOutsideQuotes(_ delimiter: String, in line: String) -> Int {
        guard let character = delimiter.first else { return 0 }
        var count = 0
        var inQuotes = false
        for symbol in line {
            if symbol == "\"" { inQuotes.toggle() }
            else if symbol == character, !inQuotes { count += 1 }
        }
        return count
    }

    // MARK: - Reading

    public static func detect(url: URL) throws -> DelimitedFormat {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw TabularError.empty }
        guard let encoding = detectEncoding(data) else { throw TabularError.undecodable }
        guard let text = decode(data, as: encoding) else { throw TabularError.undecodable }
        let delimiter = detectDelimiter(in: text, extensionHint: url.pathExtension)
        return DelimitedFormat(
            encoding: encoding,
            delimiter: delimiter.delimiter,
            reason: String(localized: "\(encoding.title); \(delimiter.reason)")
        )
    }

    /// Rows in the same shape a workbook produces.
    public static func rows(url: URL, format: DelimitedFormat? = nil) throws -> (rows: [SheetRow], format: DelimitedFormat) {
        let resolved = try format ?? detect(url: url)
        let data = try Data(contentsOf: url)
        guard let text = decode(data, as: resolved.encoding) else { throw TabularError.undecodable }
        guard let separator = resolved.delimiter.first else { throw TabularError.undecodable }

        let grid = try ImportService.parseRows(text, separator: separator)
        let rows = grid.enumerated().map { offset, fields in
            var cells: [Int: CellValue] = [:]
            for (column, field) in fields.enumerated() {
                let value = inferred(field)
                if !value.isEmpty { cells[column] = value }
            }
            return SheetRow(number: offset + 1, cells: cells)
        }
        return (rows, resolved)
    }

    /// A CSV carries no types, so they have to be inferred — carefully.
    ///
    /// Numbers and booleans only. A date is **not** inferred from anything but a
    /// full ISO-8601 day: `03.04.2024` is a date in one country and another date
    /// in the next, and guessing wrong is worse than leaving text.
    static func inferred(_ field: String) -> CellValue {
        let trimmed = field.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .empty }

        switch trimmed.lowercased() {
        case "true", "истина": return .boolean(true)
        case "false", "ложь": return .boolean(false)
        default: break
        }

        // A leading zero is part of the value, not a number: postal codes,
        // article numbers and phone numbers lose their meaning as integers.
        let digits = trimmed.hasPrefix("-") ? String(trimmed.dropFirst()) : trimmed
        if digits.count > 1, digits.hasPrefix("0"), !digits.hasPrefix("0.") {
            return .text(trimmed)
        }
        // Длинный ряд цифр — номер, а не количество: расчётный счёт
        // в двадцать цифр уходил в базу как «4.070281090000001e+19», номер
        // карты в шестнадцать — с потерей последних цифр. Точнее пятнадцати
        // знаков число с плавающей точкой не держит.
        if digits.count > 15, digits.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return .text(trimmed)
        }
        if let value = Int(trimmed) { return .number(Double(value)) }
        // Only a plain decimal: `1e5` and `0x10` are more likely part numbers
        // than quantities, and `1,5` is ambiguous with the delimiter.
        if trimmed.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }),
           let value = Double(trimmed) {
            return .number(value)
        }
        if let date = isoDay(trimmed) { return .date(date) }
        return .text(trimmed)
    }

    static func isoDay(_ text: String) -> Date? {
        guard text.count == 10 else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: text)
    }
}
