import Foundation

public enum ImportFormat: String {
    case csv, json

    public var title: String {
        switch self {
        case .csv: return "CSV"
        case .json: return "JSON"
        }
    }
}

public enum ImportError: LocalizedError {
    case unsupportedFormat(String)
    case unreadable(String)
    case emptyFile
    case noDocumentColumn
    case jsonNotAnArray
    /// The write stopped part of the way through. `written` counts documents
    /// that are already in the collection, so the import can go on from there
    /// instead of starting over.
    case interrupted(written: Int, total: Int, reason: String)
    /// «Прервать импорт» chosen in the wizard and a taken id met.
    case duplicateID(String, written: Int, total: Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return String(localized: "Формат «\(ext)» не поддерживается: нужен CSV или JSON.")
        case .unreadable(let reason):
            return String(localized: "Не удалось прочитать файл: \(reason)")
        case .emptyFile:
            return String(localized: "Файл пуст или содержит только заголовок.")
        case .noDocumentColumn:
            return String(localized: "Не выбрана колонка с текстом документа.")
        case .jsonNotAnArray:
            return String(localized: "Ожидался JSON-массив объектов вида [{\"text\": …}, …].")
        case .interrupted(let written, let total, let reason):
            return String(localized: "Импорт прерван: обработано \(written) из \(total). Причина: \(reason)")
        case .duplicateID(let identifier, let written, let total):
            return String(localized: "Импорт остановлен: документ «\(identifier)» уже есть в коллекции. Обработано \(written) из \(total).")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .interrupted:
            return String(localized: "Продолжить можно с места сбоя — уже записанные документы повторно не отправляются.")
        case .duplicateID:
            return String(localized: "Выберите «пропустить дубли» или «перезаписать» в настройках импорта.")
        default:
            return nil
        }
    }
}

/// A table read from a file: columns plus rows, whatever the source format.
public struct ImportTable {
    public let format: ImportFormat
    public let columns: [String]
    public let rows: [[String: String]]

    public init(format: ImportFormat, columns: [String], rows: [[String: String]]) {
        self.format = format
        self.columns = columns
        self.rows = rows
    }

    public var rowCount: Int { rows.count }

    public func preview(_ count: Int = 10) -> [[String: String]] {
        Array(rows.prefix(count))
    }
}

/// Which column becomes what.
public struct ImportMapping {
    public var documentColumn: String
    public var idColumn: String?
    /// Columns copied into metadata; everything else is dropped.
    public var metadataColumns: Set<String>

    public init(documentColumn: String = "", idColumn: String? = nil, metadataColumns: Set<String> = []) {
        self.documentColumn = documentColumn
        self.idColumn = idColumn
        self.metadataColumns = metadataColumns
    }

    /// Sensible defaults: the first column that looks like text is the
    /// document, a column called id/ID becomes the id, the rest is metadata.
    public static func suggested(for table: ImportTable) -> ImportMapping {
        let idColumn = table.columns.first { ["id", "_id", "uuid", "key"].contains($0.lowercased()) }
        let documentColumn = table.columns.first {
            ["text", "document", "content", "body", "текст", "документ"].contains($0.lowercased())
        } ?? table.columns.first { $0 != idColumn } ?? table.columns.first ?? ""

        var metadata = Set(table.columns)
        metadata.remove(documentColumn)
        if let idColumn { metadata.remove(idColumn) }

        return ImportMapping(documentColumn: documentColumn, idColumn: idColumn, metadataColumns: metadata)
    }
}

/// One row turned into something ready to embed and write.
public struct PreparedDocument: Sendable {
    public let id: String?
    public let text: String
    public let metadata: ChromaMetadata

    public init(id: String?, text: String, metadata: ChromaMetadata) {
        self.id = id
        self.text = text
        self.metadata = metadata
    }
}

/// Reads CSV and JSON files into a uniform table.
///
/// The CSV parser is written here rather than pulled in: quoted fields with
/// commas and newlines inside them are exactly what breaks a naive split, and
/// exported data is full of them.
public struct ImportService {
    public init() {}

    public static let supportedExtensions = ["csv", "tsv", "json"]

    public func readTable(at url: URL) throws -> ImportTable {
        let ext = url.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            throw ImportError.unsupportedFormat(ext.isEmpty ? url.lastPathComponent : ext)
        }

        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            guard let fallback = try? String(contentsOf: url, encoding: .isoLatin1) else {
                throw ImportError.unreadable(error.localizedDescription)
            }
            text = fallback
        }

        switch ext {
        case "json": return try Self.parseJSON(text)
        case "tsv": return try Self.parseDelimited(text, separator: "\t", format: .csv)
        default: return try Self.parseDelimited(text, separator: ",", format: .csv)
        }
    }

    // MARK: - CSV

    /// RFC 4180-ish: quoted fields, doubled quotes inside them, newlines inside
    /// quotes, and CRLF line endings.
    ///
    /// Split out from `parseDelimited` so the table sources of stage 5 parse a
    /// CSV with exactly this code rather than a second copy of it — two CSV
    /// parsers in one app disagree eventually, and always about quoting.
    public static func parseRows(_ text: String, separator: Character = ",") throws -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?

        func endField() {
            row.append(field)
            field = ""
        }
        func endRow() {
            endField()
            // A trailing newline must not produce a phantom empty row.
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while let character = pending ?? iterator.next() {
            pending = nil

            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    // Swift reads CRLF as a single Character; normalise it so a
                    // quoted multi-line value does not carry stray carriage
                    // returns into the database.
                    field.append(character == "\r\n" ? "\n" : character)
                }
                continue
            }

            switch character {
            case "\"": inQuotes = true
            case separator: endField()
            // "\r\n" is one grapheme cluster in Swift, so it needs its own case:
            // matching only "\r" or "\n" silently swallows every CRLF line break.
            case "\n", "\r", "\r\n": endRow()
            default: field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    public static func parseDelimited(_ text: String, separator: Character = ",", format: ImportFormat = .csv) throws -> ImportTable {
        let rows = try parseRows(text, separator: separator)
        guard let header = rows.first, rows.count > 1 else { throw ImportError.emptyFile }
        let columns = header.enumerated().map { index, name in
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "column\(index + 1)" : trimmed
        }

        let dataRows = rows.dropFirst().map { values -> [String: String] in
            var record: [String: String] = [:]
            for (index, column) in columns.enumerated() {
                record[column] = index < values.count ? values[index] : ""
            }
            return record
        }
        return ImportTable(format: format, columns: columns, rows: dataRows)
    }

    // MARK: - JSON

    public static func parseJSON(_ text: String) throws -> ImportTable {
        guard let data = text.data(using: .utf8) else { throw ImportError.unreadable("не UTF-8") }
        let object = try JSONSerialization.jsonObject(with: data)

        let array: [[String: Any]]
        if let list = object as? [[String: Any]] {
            array = list
        } else if let wrapper = object as? [String: Any],
                  let list = (wrapper["documents"] ?? wrapper["items"] ?? wrapper["rows"]) as? [[String: Any]] {
            array = list
        } else {
            throw ImportError.jsonNotAnArray
        }
        guard !array.isEmpty else { throw ImportError.emptyFile }

        // Union of keys, in first-seen order, so the mapping UI is stable.
        var columns: [String] = []
        var seen = Set<String>()
        for element in array {
            for key in element.keys.sorted() where seen.insert(key).inserted {
                columns.append(key)
            }
        }

        let rows = array.map { element -> [String: String] in
            var record: [String: String] = [:]
            for column in columns {
                record[column] = element[column].map(Self.stringify) ?? ""
            }
            return record
        }
        return ImportTable(format: .json, columns: columns, rows: rows)
    }

    private static func stringify(_ value: Any) -> String {
        switch value {
        case let text as String: return text
        case let number as NSNumber:
            // NSNumber does not distinguish Bool from Int on its own.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        case is NSNull: return ""
        default:
            if let data = try? JSONSerialization.data(withJSONObject: value),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return String(describing: value)
        }
    }

    // MARK: - Mapping

    /// Applies a mapping to the table. Rows without text are skipped, because
    /// an empty document cannot be embedded.
    public static func prepare(_ table: ImportTable, mapping: ImportMapping) throws -> (documents: [PreparedDocument], skipped: Int) {
        guard !mapping.documentColumn.isEmpty else { throw ImportError.noDocumentColumn }

        var documents: [PreparedDocument] = []
        var skipped = 0
        for row in table.rows {
            let text = (row[mapping.documentColumn] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { skipped += 1; continue }

            var metadata: ChromaMetadata = [:]
            for column in mapping.metadataColumns.sorted() {
                let raw = (row[column] ?? "").trimmingCharacters(in: .whitespaces)
                guard !raw.isEmpty else { continue }
                metadata[column] = .inferred(from: raw)
            }
            // Stamped here rather than at the call site: this is the single
            // funnel every imported row passes through. A column of the
            // same name in the file loses to it — provenance is ours to state.
            metadata.stamp(origin: .imported)

            let id = mapping.idColumn.flatMap { column -> String? in
                let value = (row[column] ?? "").trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
            documents.append(PreparedDocument(id: id, text: text, metadata: metadata))
        }
        return (documents, skipped)
    }
}
