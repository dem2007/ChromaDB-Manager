import Foundation
import ChromaCore

/// Editable key-value rows behind the metadata editor.
///
/// A dictionary cannot be edited directly in SwiftUI without keys jumping
/// around as they are typed, so editing works on an ordered list and is
/// converted back only on save.
struct MetadataDraft {
    struct Row: Identifiable, Hashable {
        let id = UUID()
        var key: String
        var value: String
        /// Значение, с которым поле пришло из документа. По нему сохраняется
        /// **тип**: см. `metadata()`.
        var original: MetadataValue? = nil
    }

    var rows: [Row]

    init(rows: [Row] = []) {
        self.rows = rows
    }

    init(metadata: ChromaMetadata?) {
        rows = (metadata ?? [:])
            .sorted { $0.key < $1.key }
            .map { Row(key: $0.key, value: $0.value.displayString, original: $0.value) }
    }

    /// Rows the app manages itself are shown read-only: editing
    /// `_cdbm_model` by hand would quietly break the binding, and `origin`
    /// states where the document came from — not something to retype.
    static func isReserved(_ key: String) -> Bool {
        key.hasPrefix("_cdbm_") || key == DocumentOrigin.metadataKey
    }

    var editableRows: [Row] { rows.filter { !Self.isReserved($0.key) } }
    var reservedRows: [Row] { rows.filter { Self.isReserved($0.key) } }

    /// Rows in schema order first (with defaults filled in), then whatever else
    /// the document already carries — so the form reads like the schema.
    static func seeded(from schema: MetadataSchema?, existing: ChromaMetadata?) -> MetadataDraft {
        guard let schema, !schema.isEmpty else { return MetadataDraft(metadata: existing) }

        var rows: [Row] = []
        var used = Set<String>()
        for field in schema.fields where !field.trimmedKey.isEmpty {
            let key = field.trimmedKey
            used.insert(key)
            let value = existing?[key]?.displayString ?? field.defaultValue
            rows.append(Row(key: key, value: value, original: existing?[key]))
        }
        for (key, value) in (existing ?? [:]).sorted(by: { $0.key < $1.key }) where !used.contains(key) {
            rows.append(Row(key: key, value: value.displayString, original: value))
        }
        return MetadataDraft(rows: rows)
    }

    mutating func addRow() {
        rows.append(Row(key: "", value: ""))
    }

    mutating func remove(_ row: Row) {
        rows.removeAll { $0.id == row.id }
    }

    /// Empty keys are dropped; values keep their type (5 stays a number).
    ///
    /// **Тип поля, пришедшего из документа, не выводится заново.** Прежде
    /// каждое значение превращалось в текст и при сохранении угадывалось
    /// обратно: правка одной заметки переписывала `sheet_name` «2023» числом
    /// и индекс «01234» числом 1234 без нуля — и строковые фильтры по ним
    /// переставали находить. Нетронутое поле сохраняется как было; строка
    /// остаётся строкой и после правки. Угадывается тип только у новых полей
    /// и у тех, что были числом или логическим значением.
    func metadata() -> ChromaMetadata {
        var result: ChromaMetadata = [:]
        for row in rows {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if let original = row.original, original.displayString == row.value {
                result[key] = original
            } else if let original = row.original, original.isString {
                result[key] = .string(row.value)
            } else {
                result[key] = .inferred(from: row.value)
            }
        }
        return result
    }

    var duplicateKeys: [String] {
        let keys = rows
            .map { $0.key.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Dictionary(grouping: keys, by: { $0 })
            .filter { $0.value.count > 1 }
            .keys
            .sorted()
    }
}
