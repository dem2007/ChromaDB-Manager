import Foundation

/// Потолки выдачи агенту.
///
/// Ограничения здесь не про экономию трафика: всё, что сервер вернул, попадает
/// в контекст модели целиком и вытесняет оттуда сам разговор. Поэтому потолка
/// три, и каждый закрывает свой способ переполнить ответ: слишком много
/// результатов, один слишком длинный документ и сумма из многих средних.
public struct MCPOutputLimits: Sendable, Hashable {
    /// Сколько результатов отдаётся, когда агент не попросил иначе.
    public static let defaultResults = 5
    /// Потолок числа результатов по умолчанию — из D2.4; права ключа его меняют.
    public static let defaultCeiling = 10
    /// Потолок длины текста одного документа — из D2.4.
    public static let defaultDocumentCharacters = 4000
    /// Потолок суммарного объёма текста в ответе.
    ///
    /// Десять документов по четыре тысячи символов — это уже около десяти
    /// тысяч токенов на один вызов инструмента. Предел ниже произведения
    /// двух других намеренно: он и должен срабатывать раньше них.
    public static let defaultResponseCharacters = 24_000

    public var ceiling: Int
    public var documentCharacters: Int
    public var responseCharacters: Int

    public init(
        ceiling: Int = defaultCeiling,
        documentCharacters: Int = defaultDocumentCharacters,
        responseCharacters: Int = defaultResponseCharacters
    ) {
        self.ceiling = max(1, ceiling)
        self.documentCharacters = max(1, documentCharacters)
        self.responseCharacters = max(1, responseCharacters)
    }

    public static func forClient(_ permissions: ClientPermissions) -> MCPOutputLimits {
        MCPOutputLimits(ceiling: permissions.maxSearchResults ?? defaultCeiling)
    }

    /// Сколько результатов просить у базы и что сказать агенту, если его
    /// просьбу урезали.
    ///
    /// Урезание **называется вслух** (правило 3 приложения 5): иначе агент
    /// попросил пятьдесят, получил десять и решил, что в коллекции больше
    /// ничего нет.
    public func resolved(requested: Int?) -> (count: Int, note: String?) {
        guard let requested else { return (min(Self.defaultResults, ceiling), nil) }
        let asked = max(1, requested)
        guard asked > ceiling else { return (asked, nil) }
        return (ceiling, String(
            localized: "Запрошено результатов: \(asked.plainDigits), отдано \(ceiling.plainDigits) — это потолок, заданный правами ключа."
        ))
    }
}

/// Один документ в выдаче агенту.
///
/// Отдельный тип, а не `RetrievalHit`: в нём нет вектора и не может появиться.
/// 4 требует «векторы не возвращаются никогда», и надёжнее всего это
/// обеспечивает тип, которому вектор просто некуда положить.
public struct MCPDocumentPayload: Sendable, Hashable {
    public let id: String
    public let text: String?
    public let metadata: ChromaMetadata?
    /// Расстояние, как его сообщила база. `nil` у контекста и у выдачи
    /// `get_documents`, где поиска не было вовсе.
    public let distance: Double?
    /// Совпадение или приложенный к нему контекст.
    public let role: HitRole
    /// Одна строка о том, откуда взялся этот результат: «раздел, к которому
    /// относится совпадение», «ещё 3 совпадения в этом разделе».
    public let note: String?

    public init(
        id: String,
        text: String?,
        metadata: ChromaMetadata?,
        distance: Double? = nil,
        role: HitRole = .match,
        note: String? = nil
    ) {
        self.id = id
        self.text = text
        self.metadata = metadata
        self.distance = distance
        self.role = role
        self.note = note
    }
}

extension MetadataValue {
    /// Значение метаданных как JSON — с сохранением типа.
    ///
    /// Число остаётся числом: агент строит по выдаче фильтр, и `2024`,
    /// превратившееся в `"2024"`, вернёт ему пустой результат без объяснений.
    public var json: JSONValue {
        switch self {
        case .string(let value): return .string(value)
        case .int(let value): return .int(value)
        case .double(let value): return .double(value)
        case .bool(let value): return .bool(value)
        case .null: return .null
        }
    }
}

/// Сборка выдачи документов под потолки D2.4.
///
/// Общая на `search` и `get_documents`: обрезка, которая в одном инструменте
/// помечается, а в другом молчит, — это ровно тот случай, когда агент уверенно
/// пересказывает человеку половину документа.
public enum MCPDocumentRendering {
    public struct Output: Sendable, Hashable {
        /// Документы для `structuredContent`.
        public var documents: [JSONValue]
        /// Текст для модели — то же самое словами.
        public var lines: [String]
        /// Пометки об урезании: сколько показано из скольких и почему.
        public var notes: [String]
        public var shown: Int
        public var total: Int

        public var isTruncated: Bool { shown < total }
    }

    /// Сколько текста должно остаться, чтобы очередной документ стоило
    /// показывать вообще.
    static let minimumUsefulText = 200

    /// Метаданные одной строкой — в том виде, в каком их читает модель.
    static func metadataLine(_ metadata: ChromaMetadata?) -> String {
        guard let metadata, !metadata.isEmpty else { return "" }
        return metadata.keys.sorted()
            .map { "\($0)=\(metadata[$0]?.displayString ?? "")" }
            .joined(separator: ", ")
    }

    public static func render(
        _ payloads: [MCPDocumentPayload],
        limits: MCPOutputLimits,
        metric: String? = nil
    ) -> Output {
        var documents: [JSONValue] = []
        var lines: [String] = []
        var notes: [String] = []
        var budget = limits.responseCharacters

        for (index, payload) in payloads.enumerated() {
            let full = payload.text ?? ""
            // Метаданные считаются вместе с текстом: у документа из настоящей
            // коллекции их набирается на полтора килобайта, и бюджет, который
            // их не видит, ограничивает ответ только на бумаге.
            let metadataLine = Self.metadataLine(payload.metadata)
            let room = budget - metadataLine.count

            // Первый документ отдаётся всегда, даже если он один съедает весь
            // бюджет: ответ без единого результата хуже, чем ответ с одним.
            // Дальше список обрывается, не дожидаясь нуля: результат, которому
            // осталось полста символов текста, — это не результат, а шум.
            if index > 0, room < minimumUsefulText {
                notes.append(String(
                    localized: "Список усечён по суммарному размеру ответа: показано \(index.plainDigits) из \(payloads.count.plainDigits). Остальное — get_documents по id или повторный вызов с меньшим n_results."
                ))
                break
            }

            let allowance = index == 0
                ? limits.documentCharacters
                : min(limits.documentCharacters, max(0, room))
            let shownText = full.count > allowance ? String(full.prefix(allowance)) : full
            let wasCut = shownText.count < full.count
            budget -= shownText.count + metadataLine.count

            var object: [String: JSONValue] = ["id": .string(payload.id)]
            if payload.text != nil { object["text"] = .string(shownText) }
            if let metadata = payload.metadata, !metadata.isEmpty {
                object["metadata"] = .object(metadata.mapValues(\.json))
            }
            if let distance = payload.distance { object["distance"] = .double(distance) }
            if let metric { object["metric"] = .string(metric) }
            if payload.role == .context { object["role"] = .string("context") }
            if let note = payload.note { object["note"] = .string(note) }
            if wasCut {
                // Пометка не только словами: клиент, читающий структурированный
                // ответ, слов не увидит вовсе.
                object["truncated"] = .bool(true)
                object["textCharacters"] = .int(full.count)
                object["shownCharacters"] = .int(shownText.count)
            }
            documents.append(.object(object))

            var header = payload.role == .context
                ? String(localized: "— контекст, id «\(payload.id)»")
                : String(localized: "\((index + 1).plainDigits). id «\(payload.id)»")
            if let distance = payload.distance {
                let value = String(format: "%.4f", distance)
                header += metric.map { String(localized: ", расстояние \(value) (\($0))") }
                    ?? String(localized: ", расстояние \(value)")
            }
            if let note = payload.note { header += ", \(note)" }
            if !metadataLine.isEmpty { header += "\n   " + metadataLine }
            var body = header
            if payload.text != nil {
                body += "\n" + shownText
                if wasCut {
                    body += "\n" + String(
                        localized: "[текст обрезан: показано \(shownText.count.plainDigits) \(RussianCount.word(shownText.count, "символ", "символа", "символов")) из \(full.count.plainDigits); полный документ — get_documents с id «\(payload.id)»]"
                    )
                }
            }
            lines.append(body)
        }

        if payloads.contains(where: { ($0.text?.count ?? 0) > limits.documentCharacters }) {
            notes.append(String(
                localized: "Длинные документы обрезаны до \(limits.documentCharacters.plainDigits) \(RussianCount.word(limits.documentCharacters, "символа", "символов", "символов")) — полный текст берётся через get_documents по id."
            ))
        }

        return Output(
            documents: documents, lines: lines, notes: notes,
            shown: documents.count, total: payloads.count
        )
    }
}
