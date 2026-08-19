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
    /// Сколько коллекций можно обыскать одним вызовом.
    ///
    /// Пять: столько человек ещё держит в голове, а десять поисков на один
    /// вызов — это уже не поиск, а обход базы.
    public static let defaultCollections = 5

    public var ceiling: Int
    public var documentCharacters: Int
    public var responseCharacters: Int
    public var collections: Int

    public init(
        ceiling: Int = defaultCeiling,
        documentCharacters: Int = defaultDocumentCharacters,
        responseCharacters: Int = defaultResponseCharacters,
        collections: Int = defaultCollections
    ) {
        self.ceiling = max(1, ceiling)
        self.documentCharacters = max(1, documentCharacters)
        self.responseCharacters = max(1, responseCharacters)
        self.collections = max(1, collections)
    }

    /// Сколько коллекций взять из запрошенных и что сказать, если урезали.
    public func resolvedCollections(_ requested: [String]) -> (names: [String], note: String?) {
        guard requested.count > collections else { return (requested, nil) }
        return (
            Array(requested.prefix(collections)),
            String(localized: "Запрошено коллекций: \(requested.count.plainDigits), обыскано \(collections.plainDigits) — это потолок, заданный правами ключа. Остальные — следующим вызовом.")
        )
    }

    public static func forClient(_ permissions: ClientPermissions) -> MCPOutputLimits {
        MCPOutputLimits(
            ceiling: permissions.maxSearchResults ?? defaultCeiling,
            // Символьные потолки тоже принадлежат ключу. Раньше они
            // были константами, и «отдай мне файл целиком» упиралось в них
            // молча: счётчик результатов подняли, а ответ всё равно обрывался
            // на двадцати четырёх тысячах символов.
            documentCharacters: permissions.maxDocumentCharacters ?? defaultDocumentCharacters,
            responseCharacters: permissions.maxResponseCharacters ?? defaultResponseCharacters,
            collections: permissions.maxSearchCollections ?? defaultCollections
        )
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

/// Чанки одного файла — по порядку и страницами.
///
/// Почему это отдельная забота, а не «фильтр по `source_file`»: `get`
/// у ChromaDB **порядок не гарантирует**, а листание `offset`-ом по
/// неупорядоченной выдаче может и пропустить документ, и показать дважды.
/// Агенту, который собирает файл обратно, нужен порядок чанков — тот самый,
/// в котором файл был нарезан.
public enum MCPFileChunks {
    /// Сколько чанков одного файла приложение готово упорядочить.
    ///
    /// Порядок требует **всех** чанков файла: отсортировать половину, взятую
    /// в произвольном порядке, значит уверенно отдать не те. Предел выбран
    /// с запасом — файл на двадцать тысяч чанков это книга страниц на пять
    /// тысяч, — а что делать сверх него, сказано словами, а не молчанием.
    public static let maximumOrdered = 20_000

    /// Ключ метаданных, по которому чанки идут в порядке файла.
    public static let orderKey = "chunk_index"

    /// Сколько чанков спрашивается у базы за раз при перечислении файла.
    public static let scanBatch = 1000

    /// Перечисляет все чанки файла — страницами, пока они не кончатся.
    ///
    /// Отдельно от того, кто их достаёт: алгоритм один и тот же в приложении
    /// и в живой проверке, а живая проверка тут и нужна — предположения
    /// о поведении `get` (что `offset` листает, что метаданные приходят без
    /// текстов) проверяются на настоящем сервере, а не додумываются.
    ///
    /// Возвращает `overflowed`, когда файл длиннее `maximumOrdered`: тогда
    /// порядок не гарантируется, и об этом говорится вслух.
    public static func collect(
        batch: Int = scanBatch,
        fetch: (_ limit: Int, _ offset: Int) async throws -> [MCPDocumentPayload]
    ) async rethrows -> (documents: [MCPDocumentPayload], overflowed: Bool) {
        var collected: [MCPDocumentPayload] = []
        var offset = 0
        while true {
            let page = try await fetch(batch, offset)
            collected += page
            offset += page.count
            if page.count < batch { return (collected, false) }
            if collected.count >= maximumOrdered { return (collected, true) }
        }
    }

    /// Чанки в порядке файла.
    ///
    /// Без `chunk_index` — в конец, по идентификатору: документ, записанный
    /// не нашей синхронизацией (агентом через `add_documents`, импортом),
    /// номера чанка не имеет, и притворяться, что имеет, нельзя.
    public static func ordered(_ documents: [MCPDocumentPayload]) -> [MCPDocumentPayload] {
        documents.sorted { left, right in
            switch (index(of: left), index(of: right)) {
            case let (l?, r?): return l == r ? left.id < right.id : l < r
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return left.id < right.id
            }
        }
    }

    /// Страница упорядоченного списка и ответ на вопрос «есть ли ещё».
    public static func page(
        _ documents: [MCPDocumentPayload], offset: Int, limit: Int
    ) -> (page: [MCPDocumentPayload], hasMore: Bool) {
        let start = max(0, offset)
        guard start < documents.count else { return ([], false) }
        let end = min(documents.count, start + max(1, limit))
        return (Array(documents[start..<end]), end < documents.count)
    }

    static func index(of document: MCPDocumentPayload) -> Int? {
        guard case .int(let value)? = document.metadata?[orderKey] else { return nil }
        return value
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
    /// Коллекция, из которой пришёл результат.
    ///
    /// `nil` при поиске по одной коллекции: агент назвал её сам и знает.
    /// При поиске по нескольким — обязателен: без него агент не сможет ни
    /// дочитать документ через `get_file`, ни объяснить человеку, откуда
    /// он это взял.
    public let collection: String?

    public init(
        id: String,
        text: String?,
        metadata: ChromaMetadata?,
        distance: Double? = nil,
        role: HitRole = .match,
        note: String? = nil,
        collection: String? = nil
    ) {
        self.id = id
        self.text = text
        self.metadata = metadata
        self.distance = distance
        self.role = role
        self.note = note
        self.collection = collection
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
            // Отпечаток файла отдельным полем, а не только среди трёх десятков
            // метаданных: им агент просит документ целиком, и увидеть
            // его он должен сразу, а не вычитывать из общей строки.
            if case .string(let fileID)? = payload.metadata?["file_id"], !fileID.isEmpty {
                object["fileId"] = .string(fileID)
            }
            // Из какой коллекции результат. Без этого агент, искавший
            // по трём, не сможет ни дочитать документ, ни сказать человеку,
            // откуда он это взял.
            if let collection = payload.collection { object["collection"] = .string(collection) }
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
            // То же, что и в структурированном ответе, и по той же причине:
            // модель читает текст, а в строке метаданных отпечаток теряется
            // среди трёх десятков полей.
            if case .string(let fileID)? = payload.metadata?["file_id"], !fileID.isEmpty {
                header += String(localized: ", файл целиком — get_file с file_id \(fileID)")
            }
            if let distance = payload.distance {
                let value = String(format: "%.4f", distance)
                header += metric.map { String(localized: ", расстояние \(value) (\($0))") }
                    ?? String(localized: ", расстояние \(value)")
            }
            if let collection = payload.collection {
                header += String(localized: ", коллекция «\(collection)»")
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

        // Таблица в этом фрагменте осталась плоским текстом: колонки
        // не разделены, и по числам оттуда нельзя сказать, где цена, а где
        // итог. Живой случай: агент посчитал по такой странице смету и
        // выдал одну позицию двумя, каждую с полной ценой.
        if payloads.contains(where: { document in
            if case .bool(true)? = document.metadata?["tables_flat"] { return true }
            return false
        }) {
            notes.append(String(
                localized: "Внимание: в части этих фрагментов таблица осталась плоским текстом — колонки в ней не разделены. Числа оттуда нельзя раскладывать по колонкам и складывать; сверься с исходным файлом."
            ))
        }

        // Книга попала в базу не целиком: у строки записано, сколько
        // листов размечено из скольких. Живой случай — из четырнадцати листов
        // сметы размечены пять, и лист с ценами в базу не попал вовсе;
        // агент, считавший по остальным, об этом не знал.
        let partial = payloads.compactMap { document -> (Int, Int)? in
            guard case .int(let indexed)? = document.metadata?["sheets_indexed"],
                  case .int(let total)? = document.metadata?["sheets_total"],
                  indexed < total
            else { return nil }
            return (indexed, total)
        }
        if let (indexed, total) = partial.first {
            notes.append(String(
                localized: "Внимание: книга проиндексирована не целиком — размечено листов \(indexed.plainDigits) из \(total.plainDigits). Строк с неразмеченных листов в базе нет, и считать по этой выдаче итоги нельзя."
            ))
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
