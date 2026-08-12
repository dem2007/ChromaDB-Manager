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

    public init(id: String, text: String, metadata: ChromaMetadata, rowKey: String?) {
        self.id = id
        self.text = text
        self.metadata = metadata
        self.rowKey = rowKey
    }
}

/// Turns rows into documents.
public enum RowMapper {
    /// Auto fields every table row carries (Приложение 4).
    public static let autoMetadataKeys = ["source_file", "sheet_name", "row_number", "row_key", "table_mode"]

    // MARK: - Text

    /// The document's text.
    ///
    /// The template matters more than it looks: it is what the vector is
    /// computed from, so search quality depends on it directly — which is why
    /// 8 insists it be previewable before a run rather than tuned by
    /// re-indexing.
    public static func text(
        for row: SheetRow,
        mapping: TableMapping,
        layout: SheetLayout
    ) -> String {
        func value(_ column: String) -> String {
            guard let index = layout.index(of: column) else { return "" }
            return row.value(at: index).displayText
        }

        let template = mapping.textTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else {
            // Default: «Колонка: значение», one per line, and only for columns
            // the user marked as carrying meaning.
            // Подпись — выбранное человеком имя: она уходит в текст документа
            // и попадает в поиск, поэтому «Столбец 3» там ни к чему.
            return mapping.textColumns
                .map { (mapping.title(of: $0), value($0)) }
                .filter { !$0.1.isEmpty }
                .map { "\($0.0): \($0.1)" }
                .joined(separator: "\n")
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
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
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
            if value == value.rounded(), abs(value) < 9e15 { return .int(Int(value)) }
            return .double(value)
        case .date(let value):
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return .string(formatter.string(from: value))
        }
    }

    public static func metadata(
        for row: SheetRow,
        mapping: TableMapping,
        layout: SheetLayout,
        sourceFile: String,
        rowKey: String?
    ) -> ChromaMetadata {
        var result: ChromaMetadata = [
            "source_file": .string(sourceFile),
            "sheet_name": .string(mapping.sheetName),
            "row_number": .int(row.number),
            "table_mode": .string(mapping.mode.rawValue),
        ]
        if let rowKey, !rowKey.isEmpty { result["row_key"] = .string(rowKey) }

        // The key names come from the mapping and the positions from the file:
        // two files writing «Цена» and «цена » must end up filterable by one
        // key, and must each be read from their own column.
        let keys = mapping.keyMap
        for column in mapping.metadataColumns {
            // Позиция — по заголовку **из файла**, ключ — по тому имени,
            // которое человек выбрал. Это разные строки, когда
            // колонку переименовали.
            guard let index = layout.index(of: column),
                  let key = keys.key(for: mapping.title(of: column))
            else { continue }
            guard let value = metadataValue(row.value(at: index)) else { continue }
            result[key] = value
        }
        return result
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
        sourceFile: String
    ) -> TableRowDocument? {
        let text = text(for: row, mapping: mapping, layout: layout)
        // A row whose text columns are all empty has nothing to embed. It is
        // not an error and not a silent drop — the caller counts it.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

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
        return TableRowDocument(
            id: id,
            text: text,
            metadata: metadata(
                for: row, mapping: mapping, layout: layout,
                sourceFile: sourceFile, rowKey: rowKey
            ),
            rowKey: rowKey
        )
    }
}
