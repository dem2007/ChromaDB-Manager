import Foundation

/// Types a metadata field may take.
///
/// ChromaDB stores only scalars — string, int, float, bool (verified, see
///). There is deliberately no "list" or "object" type: the
/// server would reject them. A date is an ISO-8601 string, optionally mirrored
/// into a numeric unix-timestamp field so range filters work.
public enum MetadataFieldType: String, Codable, CaseIterable, Identifiable, Sendable {
    case string
    case integer
    case number
    case boolean
    case date

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .string: return String(localized: "строка")
        case .integer: return String(localized: "целое")
        case .number: return String(localized: "дробное")
        case .boolean: return String(localized: "булево")
        case .date: return String(localized: "дата (ISO-8601)")
        }
    }

    public var hint: String {
        switch self {
        case .string: return String(localized: "любой текст")
        case .integer: return "42"
        case .number: return "3.14"
        case .boolean: return "true / false"
        case .date: return "2026-07-29 или 2026-07-29T10:15:00Z"
        }
    }

    /// Parses user input into a stored value, or `nil` when it does not fit.
    public func parse(_ raw: String) -> MetadataValue? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        switch self {
        case .string:
            return .string(trimmed)
        case .integer:
            return Int(trimmed).map { .int($0) }
        case .number:
            // "3" is a valid float too; store it as a double so the type of the
            // column stays stable across rows.
            return Double(trimmed).map { .double($0) }
        case .boolean:
            switch trimmed.lowercased() {
            case "true", "yes", "1", "да": return .bool(true)
            case "false", "no", "0", "нет": return .bool(false)
            default: return nil
            }
        case .date:
            return Self.parseDate(trimmed).map { .string(Self.iso8601.string(from: $0)) }
        }
    }

    /// Does an already-stored value fit this type?
    public func accepts(_ value: MetadataValue) -> Bool {
        switch (self, value) {
        case (.string, .string): return true
        case (.integer, .int): return true
        case (.number, .double), (.number, .int): return true
        case (.boolean, .bool): return true
        case (.date, .string(let text)): return Self.parseDate(text) != nil
        default: return false
        }
    }

    /// Type inferred from an existing value — used to draft a schema from data.
    public static func inferred(from value: MetadataValue) -> MetadataFieldType {
        switch value {
        case .string(let text): return parseDate(text) != nil ? .date : .string
        case .int: return .integer
        case .double: return .number
        case .bool: return .boolean
        case .null: return .string
        }
    }

    public static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Accepts a full timestamp, a fractional-seconds timestamp, or a plain
    /// calendar date — all three turn up in exported data.
    public static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 8 else { return nil }

        if let date = iso8601.date(from: trimmed) { return date }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }

        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        return dateOnly.date(from: trimmed)
    }
}

public struct MetadataField: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var key: String
    public var type: MetadataFieldType
    public var isRequired: Bool
    /// Raw text, parsed with `type` when the value is missing.
    public var defaultValue: String
    public var note: String
    /// For dates: also write `<key>_ts` as unix seconds, so `$gt`/`$lt`
    /// filters can work on a value ChromaDB can actually compare.
    public var storesTimestamp: Bool

    public init(
        id: UUID = UUID(),
        key: String = "",
        type: MetadataFieldType = .string,
        isRequired: Bool = false,
        defaultValue: String = "",
        note: String = "",
        storesTimestamp: Bool = false
    ) {
        self.id = id
        self.key = key
        self.type = type
        self.isRequired = isRequired
        self.defaultValue = defaultValue
        self.note = note
        self.storesTimestamp = storesTimestamp
    }

    public var trimmedKey: String { key.trimmingCharacters(in: .whitespaces) }

    public var timestampKey: String { "\(trimmedKey)_ts" }

    public var parsedDefault: MetadataValue? {
        defaultValue.isEmpty ? nil : type.parse(defaultValue)
    }

    /// A default that does not parse is a trap: it would silently write nothing.
    public var defaultIsBroken: Bool {
        !defaultValue.isEmpty && type.parse(defaultValue) == nil
    }
}

/// Rules for one collection's metadata.
///
/// ChromaDB has no schema of its own, so this lives with the app. The same
/// rules are used for hand-typed documents and (from 2C) for documents that
/// arrive automatically from a data source — one model, two suppliers of
/// values, not two parallel schemas.
public struct MetadataSchema: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var collectionName: String
    public var fields: [MetadataField]
    /// Whether keys outside the schema are tolerated.
    public var allowsExtraFields: Bool
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        collectionName: String,
        fields: [MetadataField] = [],
        allowsExtraFields: Bool = true,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.collectionName = collectionName
        self.fields = fields
        self.allowsExtraFields = allowsExtraFields
        self.updatedAt = updatedAt
    }

    public var isEmpty: Bool { fields.allSatisfy { $0.trimmedKey.isEmpty } }

    public func field(for key: String) -> MetadataField? {
        fields.first { $0.trimmedKey == key }
    }

    /// Keys the app manages itself are never part of a user schema.
    public static func isReservedKey(_ key: String) -> Bool {
        key.hasPrefix("_cdbm_")
    }

    /// Auto fields the sync pipeline writes for every chunk.
    ///
    /// They are technical, not user data: a strict schema must not declare war on
    /// the source pipeline, and inferring a schema should not turn them into
    /// required fields that hand-typed documents can never satisfy.
    /// The extraction fields of belong here for the same reason: the spec
    /// requires the schema builder to know them as auto fields, and a document
    /// typed by hand cannot be expected to carry an `extractor_id`.
    public static let sourceProvidedKeys: Set<String> = [
        "source_id", "source_file", "file_id", "chunk_index", "chunk_count",
        "chunk_estimated_tokens", "chunk_level", "parent_chunk_id", "content_hash",
        "file_ext", "file_mtime", "file_size", "file_name", "relative_path",
        "extractor_id", "extractor_version", "container_format", "structure_source",
        "extraction_warnings", "page_number", "page_count", "heading_path", "has_tables", "tables_flat",
        "spine_index", "chapter_id", "slide_number", "ocr_used", "ocr_confidence_avg", "document_language", "document_identifier",
        "document_title", "document_author", "document_created",
        // Table sources. Here for the same reason as the rest — and for
        // one more: a spreadsheet column named «row_number» would otherwise
        // overwrite the field row-level synchronisation depends on.
        "sheet_name", "row_number", "row_key", "table_mode",
        // Покрытие книги: сколько её листов вообще размечено.
        "sheets_indexed", "sheets_total",
    ]

    public static func isTechnicalKey(_ key: String) -> Bool {
        isReservedKey(key) || key == DocumentOrigin.metadataKey || sourceProvidedKeys.contains(key)
    }

    /// Drafts a schema from documents already in the collection — faster than
    /// starting from an empty screen, and the result is editable.
    public static func inferred(collectionName: String, from documents: [DocumentRecord]) -> MetadataSchema {
        var types: [String: MetadataFieldType] = [:]
        var counts: [String: Int] = [:]

        for document in documents {
            for (key, value) in document.metadata ?? [:] where !isTechnicalKey(key) {
                counts[key, default: 0] += 1
                let inferred = MetadataFieldType.inferred(from: value)
                if let existing = types[key], existing != inferred {
                    // Mixed types in the same column: a string is the only
                    // description that fits every row.
                    types[key] = .string
                } else {
                    types[key] = inferred
                }
            }
        }

        let total = documents.count
        let fields = types.keys.sorted().map { key in
            MetadataField(
                key: key,
                type: types[key] ?? .string,
                // A field present in every document is very likely mandatory;
                // the user can always uncheck it.
                isRequired: total > 0 && counts[key] == total
            )
        }
        return MetadataSchema(collectionName: collectionName, fields: fields, allowsExtraFields: true)
    }

    /// Draft from a source's own key-values, offered when the target collection
    /// has no schema yet. Auto fields stay out: they are technical
    /// and describing them would only make hand-typed documents harder to add.
    public static func drafted(collectionName: String, from source: DataSource) -> MetadataSchema {
        var fields = source.customMetadata.keys.sorted()
            .filter { !$0.isEmpty && !isTechnicalKey($0) }
            .map { key in
                MetadataField(
                    key: key,
                    type: MetadataFieldType.inferred(from: .inferred(from: source.customMetadata[key] ?? "")),
                    isRequired: true,
                    defaultValue: source.customMetadata[key] ?? ""
                )
            }
        // Поля из пути — такие же поля источника, только значение у каждого
        // файла своё. Обязательными объявляются лишь те, у которых
        // есть значение по умолчанию: остальные бывают не у всех файлов,
        // и требовать их значило бы заранее записать часть папки в нарушители.
        // Ключ, заданный и уровнем, и ручным полем, даёт в схеме два поля
        // с одним именем: `field(for:)` вернёт первое, валидация проверит
        // дважды, а человеку придётся убирать дубль руками.
        var taken = Set(fields.map(\.trimmedKey))
        for level in source.pathLevels where level.isNamed {
            guard taken.insert(level.trimmedKey).inserted else { continue }
            fields.append(MetadataField(
                key: level.trimmedKey,
                type: level.type,
                isRequired: level.parsedFallback != nil,
                defaultValue: level.fallbackValue,
                note: String(localized: "значение берётся из названия папки")
            ))
        }
        return MetadataSchema(collectionName: collectionName, fields: fields, allowsExtraFields: true)
    }
}

public struct SchemaViolation: Identifiable, Hashable {
    public enum Kind: String, Sendable {
        case missingRequired
        case wrongType
        case unexpectedField
        case brokenDefault
    }

    public let id = UUID()
    public let documentID: String?
    public let field: String
    public let kind: Kind
    public let message: String

    public init(documentID: String? = nil, field: String, kind: Kind, message: String) {
        self.documentID = documentID
        self.field = field
        self.kind = kind
        self.message = message
    }
}

public struct SchemaValidationResult {
    public let violations: [SchemaViolation]
    public var isValid: Bool { violations.isEmpty }

    public init(violations: [SchemaViolation]) {
        self.violations = violations
    }
}

public struct MetadataSchemaValidator: Sendable {
    public init() {}

    /// Fills in defaults for missing fields and mirrors dates into `<key>_ts`.
    /// Applied before validation, so a default satisfies a required field.
    public func normalised(_ metadata: ChromaMetadata, schema: MetadataSchema) -> ChromaMetadata {
        var result = metadata
        for field in schema.fields {
            let key = field.trimmedKey
            guard !key.isEmpty else { continue }

            if result[key] == nil, let fallback = field.parsedDefault {
                result[key] = fallback
            }
            if field.type == .date, field.storesTimestamp,
               case .string(let text)? = result[key],
               let date = MetadataFieldType.parseDate(text) {
                result[field.timestampKey] = .int(Int(date.timeIntervalSince1970))
            }
        }
        return result
    }

    public func validate(
        _ metadata: ChromaMetadata,
        against schema: MetadataSchema,
        documentID: String? = nil
    ) -> SchemaValidationResult {
        var violations: [SchemaViolation] = []
        let schemaKeys = Set(schema.fields.map(\.trimmedKey).filter { !$0.isEmpty })

        for field in schema.fields {
            let key = field.trimmedKey
            guard !key.isEmpty else { continue }

            guard let value = metadata[key] else {
                if field.isRequired {
                    violations.append(SchemaViolation(
                        documentID: documentID,
                        field: key,
                        kind: .missingRequired,
                        message: String(localized: "Обязательное поле «\(key)» не заполнено.")
                    ))
                }
                continue
            }

            if !field.type.accepts(value) {
                violations.append(SchemaViolation(
                    documentID: documentID,
                    field: key,
                    kind: .wrongType,
                    message: String(localized: "Поле «\(key)»: ожидается \(field.type.title), а значение «\(value.displayString)» этому не соответствует.")
                ))
            }
        }

        if !schema.allowsExtraFields {
            for key in metadata.keys.sorted()
            where !schemaKeys.contains(key)
                && !MetadataSchema.isTechnicalKey(key)
                && !schema.fields.contains(where: { $0.type == .date && $0.storesTimestamp && $0.timestampKey == key }) {
                violations.append(SchemaViolation(
                    documentID: documentID,
                    field: key,
                    kind: .unexpectedField,
                    message: String(localized: "Поле «\(key)» не описано в схеме, а схема запрещает лишние поля.")
                ))
            }
        }

        return SchemaValidationResult(violations: violations)
    }

    /// Problems with the schema itself, shown while it is being edited.
    public func validateSchema(_ schema: MetadataSchema) -> [SchemaViolation] {
        var violations: [SchemaViolation] = []
        var seen = Set<String>()

        for field in schema.fields {
            let key = field.trimmedKey
            if key.isEmpty { continue }

            if MetadataSchema.isReservedKey(key) {
                violations.append(SchemaViolation(
                    field: key,
                    kind: .unexpectedField,
                    message: String(localized: "Префикс _cdbm_ занят приложением — выберите другое имя поля.")
                ))
            }
            if key == DocumentOrigin.metadataKey {
                violations.append(SchemaViolation(
                    field: key,
                    kind: .unexpectedField,
                    message: String(localized: "Поле «origin» приложение заполняет само — выберите другое имя поля.")
                ))
            }
            if !seen.insert(key).inserted {
                violations.append(SchemaViolation(
                    field: key,
                    kind: .unexpectedField,
                    message: String(localized: "Поле «\(key)» описано дважды.")
                ))
            }
            if field.defaultIsBroken {
                violations.append(SchemaViolation(
                    field: key,
                    kind: .brokenDefault,
                    message: String(localized: "Значение по умолчанию «\(field.defaultValue)» не разбирается как \(field.type.title).")
                ))
            }
            if field.isRequired && field.parsedDefault == nil && field.defaultValue.isEmpty {
                // Not an error — just worth knowing that every document will
                // have to supply this field by hand.
                continue
            }
        }
        return violations
    }
}
