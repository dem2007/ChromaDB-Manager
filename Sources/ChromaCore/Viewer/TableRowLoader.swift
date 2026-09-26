import Foundation

/// Строка таблицы для просмотрщика (H1.1: «переход к строке — показ листа
/// с выделенной строкой и заголовками»).
///
/// **Читается не весь лист, а окно вокруг нужной строки.** У таблиц,
/// которые люди индексируют, десятки тысяч строк; показывать их все, чтобы
/// человек посмотрел на одну, — это секунды ожидания и мегабайты памяти
/// ради ничего. Плюс заголовок листа: без него строка из полутора десятков
/// значений не читается вовсе.
public enum TableRowLoader {

    /// Сколько строк показывать вокруг искомой.
    ///
    /// Соседи нужны: строка таблицы почти всегда понимается в сравнении
    /// с соседними — те же колонки, другие значения.
    public static let contextRows = 12

    public struct Window: Sendable {
        public let sheetName: String
        /// Строка заголовков листа, если они там есть.
        public let header: [String]?
        public let rows: [Row]
        /// Номер искомой строки, как её нумерует файл.
        public let targetRow: Int?
        public let totalRowsScanned: Int

        public init(
            sheetName: String, header: [String]?, rows: [Row],
            targetRow: Int?, totalRowsScanned: Int
        ) {
            self.sheetName = sheetName
            self.header = header
            self.rows = rows
            self.targetRow = targetRow
            self.totalRowsScanned = totalRowsScanned
        }

        public var line: String {
            var parts = [String(localized: "лист «\(sheetName)»")]
            if let targetRow { parts.append(String(localized: "строка \(targetRow)")) }
            parts.append(String(localized: "показано строк: \(rows.count)"))
            return parts.joined(separator: " · ")
        }
    }

    public struct Row: Sendable, Identifiable {
        public let number: Int
        public let values: [String]
        /// Та самая строка, из которой был сделан чанк.
        public let isTarget: Bool

        public var id: Int { number }

        public init(number: Int, values: [String], isTarget: Bool) {
            self.number = number
            self.values = values
            self.isTarget = isTarget
        }
    }

    public enum LoadError: LocalizedError {
        case unsupported
        case sheetMissing(String)

        public var errorDescription: String? {
            switch self {
            case .unsupported:
                return String(localized: "Этот табличный формат панель не читает — откройте файл во внешнем приложении.")
            case .sheetMissing(let name):
                return String(localized: "Листа «\(name)» в книге больше нет.")
            }
        }
    }

    /// Окно вокруг строки. Лист выбирается по имени; без имени — первый.
    ///
    /// - Parameter headerRow: строка заголовков, с которой этот лист
    ///   индексировался (`SheetManifest.viewerHeaderRow`). Над таблицей бывает
    ///   шапка отчёта — название, дата, — и заголовки тогда ниже первой
    ///   строки. `nil` — первая непустая строка, как у автоопределения.
    public static func window(at url: URL, sheetName: String?, row: Int?, headerRow: Int? = nil) throws -> Window {
        guard url.pathExtension.lowercased() == "xlsx" else { throw LoadError.unsupported }
        let reader = try XLSXReader(url: url)
        let sheet: SheetInfo
        if let sheetName {
            guard let found = try? reader.sheet(named: sheetName) else {
                throw LoadError.sheetMissing(sheetName)
            }
            sheet = found
        } else if let first = reader.sheets.first {
            sheet = first
        } else {
            throw LoadError.unsupported
        }

        // Верхняя граница чтения: строка плюс окно. Дальше листа не читаем —
        // ради одной строки перебирать пятьдесят тысяч незачем.
        let upperBound = row.map { $0 + contextRows } ?? contextRows * 2
        var header: [String]?
        var headerPassed = false
        var collected: [Row] = []
        var scanned = 0
        var width = 0

        try reader.forEachRow(of: sheet) { sheetRow in
            scanned += 1
            width = max(width, sheetRow.lastColumn + 1)
            let values = sheetRow.values(width: max(width, sheetRow.lastColumn + 1)).map(\.displayText)

            // Заголовки — та строка, с которой лист индексировался, а без
            // неё первая непустая: просмотрщик повторяет соглашение
            // табличного этапа, а не выдумывает своё. Строки над заголовком —
            // шапка отчёта, записями они не были и в окно не идут.
            if !headerPassed {
                if let headerRow {
                    if sheetRow.number < headerRow { return true }
                    headerPassed = true
                    if sheetRow.number == headerRow {
                        header = values
                        return sheetRow.number < upperBound
                    }
                    // Строки заголовков в файле не оказалось (пустая или
                    // файл поменялся) — дальше данные, без подписей.
                } else {
                    headerPassed = true
                    header = values
                    return sheetRow.number < upperBound
                }
            }
            if let row {
                guard sheetRow.number >= row - contextRows else { return true }
                guard sheetRow.number <= row + contextRows else { return false }
            } else if collected.count >= contextRows * 2 {
                return false
            }
            collected.append(Row(
                number: sheetRow.number,
                values: values,
                isTarget: row == sheetRow.number
            ))
            return true
        }

        return Window(
            sheetName: sheet.name,
            header: header,
            rows: collected,
            targetRow: collected.contains(where: \.isTarget) ? row : nil,
            totalRowsScanned: scanned
        )
    }
}
