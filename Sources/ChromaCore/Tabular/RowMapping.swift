import Foundation
import CryptoKit

/// How one sheet's rows become documents.
///
/// Saved with the source, not asked again per file: a folder that indexes itself
/// on a timer cannot stop to ask which column is the key.
public struct TableMapping: Codable, Hashable, Sendable {
    public var sheetName: String
    public var mode: SheetMode
    /// 1-based row number of the header, as the file numbers rows.
    public var headerRow: Int?
    /// Column titles in column order — the identity of this mapping.
    public var columns: [String]
    public var roles: [String: ColumnRole]
    /// The column whose value identifies a row across edits.
    public var keyColumn: String?
    /// `{Название}. {Описание}`; empty means the default «Колонка: значение».
    public var textTemplate: String
    /// Свои названия колонок: заголовок из файла → как его называть.
    ///
    /// Заголовки в рабочих таблицах часто либо служебные («Столбец 3»), либо
    /// длинные на полстроки, либо отсутствуют вовсе. По ним же строятся ключи
    /// метаданных, то есть имя из файла уезжает в базу и остаётся там навсегда.
    /// Переименование — здесь, а не правкой файла: файл чужой.
    ///
    /// Пусто для колонки — берётся её заголовок из файла.
    public var titles: [String: String]

    public init(
        sheetName: String,
        mode: SheetMode = .dataTable,
        headerRow: Int? = 1,
        columns: [String] = [],
        roles: [String: ColumnRole] = [:],
        keyColumn: String? = nil,
        textTemplate: String = "",
        titles: [String: String] = [:]
    ) {
        self.sheetName = sheetName
        self.mode = mode
        self.headerRow = headerRow
        self.columns = columns
        self.roles = roles
        self.keyColumn = keyColumn
        self.textTemplate = textTemplate
        self.titles = titles
    }

    /// Та же разметка, но на колонках **этого** файла.
    ///
    /// Роли, свои названия и ключ переносятся по именам, которые уцелели;
    /// колонка, которой в профиле не было, получает роль из первого
    /// предположения. Профиль говорит, что колонки значат, файл — какие они
    /// и где.
    ///
    /// Без этого пересчёта разметка, подставленная из профиля, показывала
    /// колонки профиля: колонок, которые есть в файле и которых профиль
    /// не знает, в редакторе не было вовсе, и добавить их было нечем.
    public func rebased(on shape: SheetShape) -> TableMapping {
        let suggested = TableMapping.suggested(sheetName: sheetName, shape: shape)
        var result = self
        result.headerRow = shape.headerRow
        result.columns = shape.columns
        result.roles = shape.columns.reduce(into: [:]) { roles, column in
            roles[column] = self.roles[column] ?? suggested.role(of: column)
        }
        result.titles = titles.filter { shape.columns.contains($0.key) }
        if let key = keyColumn, !shape.columns.contains(key) {
            result.keyColumn = suggested.keyColumn
        }
        return result
    }

    /// Размечено ли по буквам колонок, а не по прочитанным заголовкам.
    ///
    /// Выводится из самих колонок, а не хранится отдельным полем: лишний
    /// признак в формате профиля потребовал бы миграции всех сохранённых
    /// и выгруженных файлов ради того, что и так видно.
    public var usesColumnLetters: Bool {
        !columns.isEmpty && columns.enumerated().allSatisfy { $1 == XLSXReader.columnName($0) }
    }

    public func role(of column: String) -> ColumnRole { roles[column] ?? .ignore }

    /// Как называть колонку: своё имя, если задано, иначе заголовок из файла.
    public func title(of column: String) -> String {
        let own = (titles[column] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? column : own
    }

    public var textColumns: [String] { columns.filter { role(of: $0) == .text } }
    public var metadataColumns: [String] { columns.filter { role(of: $0) == .metadata } }

    /// Keys for the metadata columns, collisions resolved.
    ///
    /// Считаются по **отображаемым** названиям: переименование колонки для
    /// того и нужно, чтобы в метаданных стояло выбранное человеком имя,
    /// а не «Столбец 3» из файла.
    public var keyMap: ColumnKeyMap { ColumnKeyNormaliser.map(titles: columns.map(title(of:))) }

    /// A first guess: text-looking columns become the text, everything else
    /// becomes filterable, and a column that looks like an identifier is
    /// proposed as the key.
    public static func suggested(sheetName: String, shape: SheetShape) -> TableMapping {
        var roles: [String: ColumnRole] = [:]
        for column in shape.columns {
            roles[column] = looksLikeText(column) ? .text : .metadata
        }
        // Nothing looked like prose: the first column carries the text, or the
        // documents would have no text at all.
        if !roles.values.contains(.text), let first = shape.columns.first {
            roles[first] = .text
        }
        return TableMapping(
            sheetName: sheetName,
            mode: shape.mode,
            headerRow: shape.headerRow,
            columns: shape.columns,
            roles: roles,
            keyColumn: shape.columns.first(where: looksLikeKey),
            textTemplate: ""
        )
    }

    static func looksLikeKey(_ title: String) -> Bool {
        let lower = title.lowercased()
        return ["id", "код", "артикул", "sku", "uuid", "ключ", "key", "email", "номер"]
            .contains { lower == $0 || lower.hasPrefix($0 + " ") || lower.hasSuffix(" " + $0) }
    }

    static func looksLikeText(_ title: String) -> Bool {
        let lower = title.lowercased()
        return ["название", "наименование", "описание", "текст", "комментарий", "примечание",
                "name", "title", "description", "text", "comment", "summary", "body"]
            .contains { lower.contains($0) }
    }
}

/// Where a mapping's columns actually sit **in the file being read**.
///
/// A profile records what the columns mean; it must not be allowed to record
/// where they are. Profiles are matched by the *set* of headers, so the same
/// profile legitimately covers a file whose columns were reordered, renamed in
/// case, or padded with spaces — and a file whose title rows push the header
/// down. Reading such a file by the profile's own column order puts the article
/// number in the name and the name in the key, and nothing anywhere says so.
///
/// So the rule is: **the file is read with the same header the matcher matched**
/// — this layout — and the profile supplies only meaning.
public struct SheetLayout: Hashable, Sendable {
    /// The header row as this file numbers it.
    public let headerRow: Int?
    /// Header titles in this file's column order, as this file writes them.
    public let columns: [String]
    /// Normalised title → column index. Built once per sheet, not per row.
    public let indices: [String: Int]

    public var width: Int { columns.count }

    public init(headerRow: Int?, columns: [String]) {
        self.headerRow = headerRow
        self.columns = columns
        var indices: [String: Int] = [:]
        for (index, title) in columns.enumerated() {
            let key = SheetLayout.normalised(title)
            if indices[key] == nil { indices[key] = index }
        }
        self.indices = indices
    }

    /// The layout as found in the file the detector looked at.
    public init(shape: SheetShape) {
        self.init(headerRow: shape.headerRow, columns: shape.columns)
    }

    /// The layout of the very file a mapping was built from — the editor's
    /// preview, where the mapping's columns *are* the file's columns.
    public init(mapping: TableMapping) {
        self.init(headerRow: mapping.headerRow, columns: mapping.columns)
    }

    public func index(of title: String) -> Int? { indices[SheetLayout.normalised(title)] }

    /// Mapping columns this file has no column for. Empty whenever a profile
    /// matched — and checked anyway, because «сопоставилось» must not be taken
    /// on trust when the cost of being wrong is silently empty fields.
    public func missing(from columns: [String]) -> [String] {
        columns.filter { index(of: $0) == nil }
    }

    /// Case and space are not a different column — the same rule
    /// `TableProfileMatcher` matches profiles by, so what matched is what is
    /// read.
    ///
    /// Whitespace **inside** a title is collapsed as well, because Excel wraps
    /// long headers and the line break lands in the cell: «Цена единицы,\nрубл»
    /// and «Цена единицы, рубл» are one column with one name. Collapsing here
    /// rather than only at reading also keeps profiles saved by earlier builds
    /// matching — both sides come through this function.
    public static func normalised(_ title: String) -> String {
        title
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
            .lowercased()
    }
}

/// One row, ready to embed and write.
public struct TableRowDocument: Hashable, Sendable {
    public let id: String
    public let text: String
    public let metadata: ChromaMetadata
    /// The key value this row was identified by, when there is a key column.
    public let rowKey: String?
    /// Колонки, чьё значение не поместилось в предел метаданных.
    public let truncatedColumns: [String]

    public init(
        id: String, text: String, metadata: ChromaMetadata, rowKey: String?,
        truncatedColumns: [String] = []
    ) {
        self.id = id
        self.text = text
        self.metadata = metadata
        self.rowKey = rowKey
        self.truncatedColumns = truncatedColumns
    }
}

/// Сколько листов книги вообще попало в базу.
///
/// Живой случай: в книге четырнадцать листов, размечено пять — в базу попали
/// 73 строки из полутора тысяч, а лист с ценами не попал вовсе. Строка,
/// пришедшая из такой книги, обязана нести это с собой: агент, считающий
/// по ней смету, должен знать, что перед ним часть, а не всё.
public struct SheetCoverage: Sendable, Hashable {
    public var indexed: Int
    public var total: Int

    public init(indexed: Int, total: Int) {
        self.indexed = indexed
        self.total = total
    }

    /// Книга в базе не целиком. Только в этом случае поля и пишутся: у книги,
    /// размеченной полностью, они были бы шумом в каждой строке.
    public var isPartial: Bool { indexed < total && total > 0 }
}

/// Turns rows into documents.
public enum RowMapper {
    /// Auto fields every table row carries (Приложение 4).
    public static let autoMetadataKeys = [
        "source_file", "file_id", "sheet_name", "row_number", "row_key", "table_mode",
        "sheets_indexed", "sheets_total",
    ]

    // MARK: - Text

    /// The document's text.
    ///
    /// The template matters more than it looks: it is what the vector is
    /// computed from, so search quality depends on it directly — which is why
    /// 8 insists it be previewable before a run rather than tuned by
    /// re-indexing.
    /// - Parameter includingKey: дописывать ли ключ строки впереди.
    ///   Выключается там, где нужен **свой** текст строки: строка, у которой
    ///   заполнен один артикул, документом не становится, и решать это
    ///   по тексту с дописанным артикулом нельзя — он не пуст никогда.
    public static func text(
        for row: SheetRow,
        mapping: TableMapping,
        layout: SheetLayout,
        includingKey: Bool = true
    ) -> String {
        func value(_ column: String) -> String {
            guard let index = layout.index(of: column) else { return "" }
            return row.value(at: index).displayText
        }

        /// Ключ строки — впереди её текста.
        ///
        /// Артикул, шифр, инвентарный номер почти всегда получают роль
        /// метаданного: они короткие и на текст не похожи. А ищут строку
        /// **именно по ним** — и не находили ни вектором, ни текстовой
        /// стадией, потому что в тексте документа ключа не было вовсе;
        /// работал только фильтр по метаданным, о чём человек знать не обязан.
        ///
        /// Дописывается только тогда, когда значения ключа в тексте ещё нет:
        /// шаблон, в котором человек уже вывел артикул, не должен получить
        /// его дважды.
        func withKey(_ body: String) -> String {
            guard includingKey else { return body }
            return keyed(body, for: row, mapping: mapping, layout: layout)
        }

        let template = mapping.textTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else {
            // Default: «Колонка: значение», one per line, and only for columns
            // the user marked as carrying meaning.
            // Подпись — выбранное человеком имя: она уходит в текст документа
            // и попадает в поиск, поэтому «Столбец 3» там ни к чему.
            return withKey(
                mapping.textColumns
                    .map { (mapping.title(of: $0), value($0)) }
                    .filter { !$0.1.isEmpty }
                    .map { "\($0.0): \($0.1)" }
                    .joined(separator: "\n")
            )
        }

        var result = template
        // Longest first, so `{Название}` is not eaten by `{Наз}`.
        //
        // В шаблоне работают оба имени — и заголовок из файла, и своё:
        // человек, переименовавший колонку, ожидает писать `{Группа ПО}`,
        // а уже написанные шаблоны не должны сломаться от переименования.
        let names = mapping.columns.flatMap { column -> [(String, String)] in
            let own = mapping.title(of: column)
            return own == column ? [(column, column)] : [(own, column), (column, column)]
        }
        for (placeholder, column) in names.sorted(by: { $0.0.count > $1.0.count }) {
            result = result.replacingOccurrences(of: "{\(placeholder)}", with: value(column))
        }
        return withKey(result.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Текст строки с её ключом впереди.
    ///
    /// Отдельно от `text(for:...)`, потому что тот же ключ дописывается
    /// и там, где текст уже посчитан: считать его дважды ради одной строки
    /// значит удвоить работу на каждой строке таблицы.
    static func keyed(
        _ body: String, for row: SheetRow, mapping: TableMapping, layout: SheetLayout
    ) -> String {
        guard let key = mapping.keyColumn, let index = layout.index(of: key) else { return body }
        let value = row.value(at: index).displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !mentions(value, in: body) else { return body }
        let line = "\(mapping.title(of: key)): \(value)"
        return body.isEmpty ? line : line + "\n" + body
    }

    /// Стоит ли значение в тексте **отдельным** словом.
    ///
    /// Простое вхождение подстроки отвечало неправдой: артикул «12» есть
    /// внутри «уровень 12А» и внутри «2012», и строка оставалась без своего
    /// ключа — то есть ненаходимой ровно тем запросом, ради которого ключ
    /// и дописывается.
    static func mentions(_ value: String, in text: String) -> Bool {
        var search = text.startIndex..<text.endIndex
        while let range = text.range(of: value, range: search) {
            let before = range.lowerBound == text.startIndex
                ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            let touching = { (character: Character?) in
                character.map { $0.isLetter || $0.isNumber } ?? false
            }
            if !touching(before), !touching(after) { return true }
            guard range.upperBound < text.endIndex else { return false }
            search = range.upperBound..<text.endIndex
        }
        return false
    }

    /// Плейсхолдеры шаблона, которым не соответствует ни одна колонка этого
    /// сопоставления.
    ///
    /// Спрашивать надо именно у сопоставления, а не у списка колонок: в шаблоне
    /// работают оба имени — и заголовок из файла, и своё, — поэтому проверка по
    /// одним заголовкам объявляла бы `{Группа ПО}` опечаткой и не давала бы
    /// сохранить профиль, в котором колонку только что переименовали.
    public static func unknownPlaceholders(in template: String, mapping: TableMapping) -> [String] {
        unknownPlaceholders(
            in: template,
            columns: mapping.columns + mapping.columns.map(mapping.title(of:))
        )
    }

    /// Placeholders in a template that name no column — shown while editing, so
    /// a typo does not quietly become an empty document.
    public static func unknownPlaceholders(in template: String, columns: [String]) -> [String] {
        var found: [String] = []
        var current: String?
        for character in template {
            if character == "{" { current = "" }
            else if character == "}", let name = current {
                if !columns.contains(name), !found.contains(name) { found.append(name) }
                current = nil
            } else if current != nil {
                current!.append(character)
            }
        }
        return found
    }

    // MARK: - Metadata

    private static func numeric(_ value: Double) -> MetadataValue {
        if value == value.rounded(), abs(value) < 9e15 { return .int(Int(value)) }
        return .double(value)
    }

    /// ChromaDB metadata holds only string, int, float and bool. A date goes
    /// out as an ISO-8601 string, the form this project uses everywhere.
    public static func metadataValue(_ cell: CellValue) -> MetadataValue? {
        switch cell {
        case .empty:
            // Not written at all rather than written as an empty string: an
            // absent value must not match a filter for «empty».
            return nil
        case .text(let value):
            return value.isEmpty ? nil : .string(value)
        case .boolean(let value):
            return .bool(value)
        case .number(let value):
            return numeric(value)
        case .measured(let value, let unit):
            // В метаданные идёт **показанное** число: в книге стоит
            // «15 %», и фильтр человек напишет `= 15`, а не `= 0.15`. Единица
            // остаётся в тексте документа — метаданные хранят числа, с
            // которыми считают.
            return numeric(unit.displayed(value))
        case .date(let value):
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return .string(formatter.string(from: value))
        }
    }

    /// Предел длины одного значения в метаданных.
    ///
    /// Для текста документа предел есть — контекст модели; для метаданных
    /// не было никакого, и колонка с примечанием на сорок тысяч знаков уезжала
    /// в базу целиком, а потом возвращалась в каждом результате поиска.
    /// Две тысячи — с запасом на любое осмысленное поле, по которому фильтруют,
    /// и в двадцать раз меньше того случая.
    public static let metadataValueLimit = 2000

    /// Чем оканчивается поле с единицей измерения колонки: у колонки
    /// `цена` это `цена_unit` со значением `₽`.
    public static let unitKeySuffix = "_unit"

    /// Значение с обрезкой по пределу. `nil` во втором члене — обрезки не было.
    static func fitting(_ value: MetadataValue) -> (value: MetadataValue, truncated: Bool) {
        guard case .string(let text) = value, text.count > metadataValueLimit else {
            return (value, false)
        }
        // Многоточие в конце — чтобы обрезка была видна в самом значении,
        // а не только в отчёте прогона.
        return (.string(String(text.prefix(metadataValueLimit)) + "…"), true)
    }

    public static func metadata(
        for row: SheetRow,
        mapping: TableMapping,
        layout: SheetLayout,
        sourceFile: String,
        rowKey: String?
    ) -> ChromaMetadata {
        metadataAndTruncations(
            for: row, mapping: mapping, layout: layout, sourceFile: sourceFile, rowKey: rowKey
        ).metadata
    }

    static func metadataAndTruncations(
        for row: SheetRow,
        mapping: TableMapping,
        layout: SheetLayout,
        sourceFile: String,
        rowKey: String?,
        coverage: SheetCoverage? = nil
    ) -> (metadata: ChromaMetadata, truncated: [String]) {
        var result: ChromaMetadata = [
            "source_file": .string(sourceFile),
            // Тот же отпечаток файла, что и у обычных документов:
            // строка таблицы — тоже часть файла, и просить её целиком агент
            // должен тем же способом.
            "file_id": .string(SourceSyncService.fileFingerprint(sourceFile)),
            "sheet_name": .string(mapping.sheetName),
            "row_number": .int(row.number),
            "table_mode": .string(mapping.mode.rawValue),
        ]
        if let rowKey, !rowKey.isEmpty { result["row_key"] = .string(rowKey) }

        // Книга в базе не целиком: строка несёт это с собой, чтобы
        // тот, кто по ней считает, знал, что видит часть.
        if let coverage, coverage.isPartial {
            result["sheets_indexed"] = .int(coverage.indexed)
            result["sheets_total"] = .int(coverage.total)
        }

        // The key names come from the mapping and the positions from the file:
        // two files writing «Цена» and «цена » must end up filterable by one
        // key, and must each be read from their own column.
        let keys = mapping.keyMap
        var truncated: [String] = []
        // Единицы дописываются после всех колонок, чтобы настоящая колонка
        // с именем вроде «цена_unit» всегда выигрывала у нашего поля.
        var units: [String: MetadataValue] = [:]
        for column in mapping.metadataColumns {
            // Позиция — по заголовку **из файла**, ключ — по тому имени,
            // которое человек выбрал. Это разные строки, когда
            // колонку переименовали.
            guard let index = layout.index(of: column),
                  let key = keys.key(for: mapping.title(of: column))
            else { continue }
            let cell = row.value(at: index)
            guard let value = metadataValue(cell) else { continue }
            let fitted = fitting(value)
            if fitted.truncated { truncated.append(mapping.title(of: column)) }
            result[key] = fitted.value
            // В метаданные идёт показанное число, а единица — отдельным
            // полем рядом. оставлял её тексту документа, и это
            // работает, только пока колонка помечена как текст: у колонки
            // с процентами, помеченной метаданными, «4 %» не оставалось
            // нигде — ни в тексте, ни в полях. Число без единицы
            // неотличимо от рублей и штук, и «инфляция 4 %» такую строку
            // не находило.
            //
            // Отдельным полем, а не строкой «4 %» в самом поле: строкой
            // сломались бы числовые сравнения, ради которых метаданные
            // и заводились. Приём в проекте уже принят — так же рядом
            // с датой пишется `<ключ>_ts`.
            if case .measured(_, let unit) = cell, let label = unit.label {
                units["\(key)\(Self.unitKeySuffix)"] = .string(label)
            }
        }
        // Имя, занятое колонкой файла, наше поле не занимает — какой бы роли
        // та колонка ни была. Колонка, помеченная текстом, метаданных не пишет,
        // и «свободным» её ключ выглядит только на первый взгляд: человек уже
        // назвал этим словом свою колонку, и два разных смысла под одним
        // именем — это путаница, которую потом не распутать.
        //
        // Считается только когда есть что дописывать: эта функция зовётся
        // на **каждую** строку листа, а лист без процентов и валюты платил бы
        // за проход по всем колонкам, ответ которого никому не нужен.
        if !units.isEmpty {
            let taken = Set(mapping.columns.compactMap { keys.key(for: mapping.title(of: $0)) })
            for (key, value) in units where result[key] == nil && !taken.contains(key) {
                result[key] = value
            }
        }
        return (result, truncated)
    }

    // MARK: - Identity

    /// The row's document id — the one decision here that is expensive
    /// to change later.
    ///
    /// With a key column the id follows the key: editing a row updates the same
    /// document, and inserting rows above it changes nothing. Without one the id
    /// follows the row's **contents**, so inserting is still safe but any edit
    /// produces a new document and the old one has to be deleted by explicit id
    /// from the manifest.
    ///
    /// The row *number* is never the id on its own: inserting one row in the
    /// middle would shift everything below it and re-index the whole sheet.
    public static func identifier(
        sourceID: UUID,
        sheetName: String,
        key: String?,
        rowContent: String
    ) -> String {
        let seed = key.map { "\(sourceID.uuidString)\u{0}\(sheetName)\u{0}key\u{0}\($0)" }
            ?? "\(sourceID.uuidString)\u{0}\(sheetName)\u{0}row\u{0}\(rowContent)"
        return SHA256.hash(data: Data(seed.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
    }

    /// Everything in the row that identifies it when there is no key column:
    /// every value, in column order, so two rows differing in one cell differ
    /// in their id.
    public static func contentSeed(for row: SheetRow, width: Int) -> String {
        row.values(width: width).map(\.displayText).joined(separator: "\u{1}")
    }

    // MARK: - Whole document

    public static func document(
        for row: SheetRow,
        mapping: TableMapping,
        layout: SheetLayout,
        sourceID: UUID,
        sourceFile: String,
        coverage: SheetCoverage? = nil
    ) -> TableRowDocument? {
        // A row whose text columns are all empty has nothing to embed. It is
        // not an error and not a silent drop — the caller counts it. Считается
        // это по тексту **без** ключа: с дописанным артикулом пустых
        // строк не бывает вовсе, и такая строка молча становилась документом
        // из одного артикула.
        //
        // Текст считается **один раз**: ключ дописывается к готовому телу,
        // а не вторым проходом по шаблону.
        let body = text(for: row, mapping: mapping, layout: layout, includingKey: false)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let text = keyed(body, for: row, mapping: mapping, layout: layout)

        let rowKey = mapping.keyColumn
            .flatMap { layout.index(of: $0) }
            .map { row.value(at: $0).displayText }
            .flatMap { $0.isEmpty ? nil : $0 }

        let width = layout.width
        let id = identifier(
            sourceID: sourceID,
            sheetName: mapping.sheetName,
            key: rowKey,
            rowContent: contentSeed(for: row, width: width)
        )
        let fields = metadataAndTruncations(
            for: row, mapping: mapping, layout: layout,
            sourceFile: sourceFile, rowKey: rowKey, coverage: coverage
        )
        return TableRowDocument(
            id: id,
            text: text,
            metadata: fields.metadata,
            rowKey: rowKey,
            truncatedColumns: fields.truncated
        )
    }
}
