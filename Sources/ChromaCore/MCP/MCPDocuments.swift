import Foundation

/// Потолки выдачи агенту.
///
/// Ограничения здесь не про экономию трафика: всё, что сервер вернул, попадает
/// в контекст модели целиком и вытесняет оттуда сам разговор. Поэтому потолка
/// три, и каждый закрывает свой способ переполнить ответ: слишком много
/// результатов, один слишком длинный документ и сумма из многих средних.
/// Число со словом по-английски — для ответов MCP.
///
/// Ответы этого слоя читает модель, а не человек, и язык у них один
/// независимо от языка приложения. Русский `RussianCount` остаётся экранам.
enum EnglishCount {
    /// Число пишется без разделителя разрядов: `formatted()` берёт его из
    /// текущей локали, и на русской машине счётчик приезжал как «1 234» —
    /// с неразрывным пробелом, посреди английской фразы, рядом с соседним
    /// числом через `plainDigits` в той же строке.
    static func grouped(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count.plainDigits) \(count == 1 ? one : many)"
    }
}

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
        // Ключу можно выписать меньше общего предела, но не больше: конвейер
        // всё равно обрежет, и настройка обещала бы то, чего не бывает.
        self.ceiling = min(RetrievalLimits.maximumResults, max(1, ceiling))
        self.documentCharacters = max(1, documentCharacters)
        self.responseCharacters = max(1, responseCharacters)
        self.collections = max(1, collections)
    }

    /// Сколько коллекций взять из запрошенных и что сказать, если урезали.
    public func resolvedCollections(_ requested: [String]) -> (names: [String], note: String?) {
        guard requested.count > collections else { return (requested, nil) }
        return (
            Array(requested.prefix(collections)),
            "Collections asked for: \(requested.count.plainDigits), searched \(collections.plainDigits) — the ceiling set by the key's rights. The rest come with the next call."
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
        return (ceiling, "Results asked for: \(asked.plainDigits), returned \(ceiling.plainDigits) — the ceiling set by the key's rights.")
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

    /// Оставляет в метаданных только запрошенные поля.
    ///
    /// Проекция нужна не для красоты ответа, а для его объёма: строка таблицы
    /// тащит в выдачу **все свои колонки**, и бюджет ответа уходит на те,
    /// которые вопроса не касаются.
    ///
    /// **Замер на живой коллекции** (1290 строк таблиц, `MCPProjectionLiveTests`):
    ///
    /// | выборка | метаданных на строку | строк в ответ на 24 000 |
    /// |---|---|---|
    /// | сто самых широких строк | 1883 → **94** | 8 → **56** |
    /// | сто строк вразброс | 419 → **87** | 49 → **100** |
    ///
    /// Обычная строка весит около 270 знаков метаданных, широкая — до 2848:
    /// поэтому проекция и нужна, и поэтому её не включают по умолчанию.
    ///
    /// Отбор идёт **на выдаче, а не в запросе к базе**: предупреждения
    /// (плоская таблица, неполная книга) и отпечаток файла читаются из полных
    /// метаданных, и агент, попросивший одну колонку, не должен из-за этого
    /// перестать узнавать, что таблица пришла плоской.
    ///
    /// Имена сравниваются буквально: `describe_collection` называет их точно,
    /// а угаданное «почти то же самое» лучше назвать вслух, чем молча отдать
    /// пустоту.
    static func projected(_ metadata: ChromaMetadata?, to fields: Set<String>?) -> ChromaMetadata? {
        guard let fields, !fields.isEmpty else { return metadata }
        guard let metadata else { return nil }
        return metadata.filter { fields.contains($0.key) }
    }

    /// Метаданные одной строкой — в том виде, в каком их читает модель.
    static func metadataLine(_ metadata: ChromaMetadata?) -> String {
        guard let metadata, !metadata.isEmpty else { return "" }
        return metadata.keys.sorted()
            .map { "\($0)=\(metadata[$0]?.displayString ?? "")" }
            .joined(separator: ", ")
    }

    /// Запас под обвязку, которую этот рендер не строит: заголовок ответа,
    /// пометки под ним и объект-обёртка `structuredContent` с его ключами.
    /// Без запаса ответ переваливал за объявленный потолок на несколько сотен
    /// символов — немного, но обещание либо держится, либо нет.
    static let envelopeReserve = 1024

    /// Словарь вызывающего: чем листают его выдачу и как её называть.
    ///
    /// Рендер один на пять инструментов, а имена у них разные: `search`
    /// уменьшают «n_results», остальных — «limit». Пометка об урезании
    /// печаталась одна на всех и называла «n_results» там, где такого
    /// параметра нет вовсе: четыре инструмента из пяти советовали агенту
    /// невыполнимое. Знать своё имя может только вызывающий — он его и
    /// передаёт.
    public struct Vocabulary: Sendable, Hashable {
        /// Как назвать показанное. У поиска это документы, у файла — куски,
        /// у сбора упоминаний — образцы: там урезаются именно они, а перечень
        /// файлов приходит целым, и «the list was cut» рядом с полным
        /// перечнем читается как пропавший файл.
        public let items: String
        /// То же в единственном числе.
        ///
        /// Полем, а не отрезанием последней буквы у `items`: приём
        /// работает ровно на тех трёх словах, что здесь лежат, и на первом же
        /// «entries» даёт «entrie». В этом файле для единственного и
        /// множественного уже есть свой способ — `EnglishCount.grouped`,
        /// которому оба слова передают целиком.
        public let item: String
        /// Что сделать, чтобы влезло, — целой фразой.
        ///
        /// Фразой, а не одним именем параметра: у выборки по идентификаторам
        /// «limit» не действует вовсе — двенадцать идентификаторов с limit 12,
        /// 3 и 1 дают побайтно один и тот же ответ, — и совет «попроси
        /// меньше» там означает «передай меньше ids», а не «уменьши limit»
        ///.
        public let advice: String

        public init(items: String, item: String, advice: String) {
            self.items = items
            self.item = item
            self.advice = advice
        }

        public static let documents = Vocabulary(
            items: "documents",
            item: "document",
            advice: "For the rest use get_documents by id, or call again with a smaller «limit»."
        )
        public static let searchResults = Vocabulary(
            items: "documents",
            item: "document",
            advice: "For the rest use get_documents by id, or call again with a smaller «n_results»."
        )
        public static let chunks = Vocabulary(
            items: "chunks",
            item: "chunk",
            advice: "For the rest use get_documents by id, or call again with a smaller «limit»."
        )
        public static let mentionSamples = Vocabulary(
            items: "samples",
            item: "sample",
            advice: "For the rest use get_documents by id, or call again with a smaller «limit»."
        )
        /// Выборка по идентификаторам: «limit» на неё не действует.
        public static let identifiedDocuments = Vocabulary(
            items: "documents",
            item: "document",
            advice: "Ask for fewer «ids» at a time — «limit» does not apply to a call by identifiers."
        )
    }

    /// Пометка об урезании списка — одной сборкой на оба места, где она
    /// нужна: в оплате наперёд и в самом ответе.
    static func cutNote(shown: Int, total: Int, vocabulary: Vocabulary) -> String {
        "The list of \(vocabulary.items) was cut by total answer size: "
            + "\(shown.plainDigits) of \(total.plainDigits) shown. \(vocabulary.advice)"
    }

    /// Пометки, которые зависят только от пришедшего, а не от поместившегося.
    ///
    /// Собраны до цикла — тогда их можно оплатить наравне с документами
    ///. Порядок сохранён: он читается сверху вниз.
    static func tailNotes(
        _ payloads: [MCPDocumentPayload], limits: MCPOutputLimits, fields: [String]?
    ) -> [String] {
        var collected: [String] = []
        // Имя поля, которого нет ни у одного документа, называется вслух
        //: агент берёт его из describe_collection, и опечатка иначе
        // выглядит как «в базе про это пусто» — то есть как ответ, а не как
        // промах.
        // Пустая выдача сюда не попадает: сказать «полей нет ни у одного
        // документа», когда документов нет вовсе, значит увести агента
        // от настоящей причины — запроса или фильтра — к именам колонок.
        if let fields, !fields.isEmpty, !payloads.isEmpty {
            var present: Set<String> = []
            for payload in payloads {
                if let metadata = payload.metadata { present.formUnion(metadata.keys) }
            }
            let missing = fields.filter { !present.contains($0) }
            if !missing.isEmpty {
                collected.append(String(
                    "Not one document in this answer carries the requested fields: \(missing.joined(separator: ", ")). The exact names are in describe_collection."
                ))
            }
        }

        // Таблица в этом фрагменте осталась плоским текстом: колонки
        // не разделены, и по числам оттуда нельзя сказать, где цена, а где
        // итог. Живой случай: агент посчитал по такой странице смету и
        // выдал одну позицию двумя, каждую с полной ценой.
        if payloads.contains(where: { document in
            if case .bool(true)? = document.metadata?["tables_flat"] { return true }
            return false
        }) {
            collected.append("Warning: in some of these fragments the table stayed flat text — its columns are not separated. Numbers from there must not be assigned to columns or summed; check against the source file.")
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
            collected.append("Warning: the workbook is not indexed whole — \(indexed.plainDigits) sheets of \(total.plainDigits) are mapped. Rows from unmapped sheets are not in the base, and no total may be built on this answer.")
        }

        if payloads.contains(where: { ($0.text?.count ?? 0) > limits.documentCharacters }) {
            collected.append("Long documents are cut to \(limits.documentCharacters.plainDigits) characters — take the full text with get_documents by id.")
        }

        return collected
    }

    /// Во что обойдётся обвязка ответа: заголовок, пометки и их зеркало.
    ///
    /// Считается по готовым строкам, а не плоским запасом: запас
    /// в тысячу знаков «на конверт» покрывал обвязку, пока она была короткой,
    /// и переставал, когда у карты появилась третья пометка. Вызывающий
    /// собирает свою шапку и свои пометки до рендера и передаёт их цену сюда.
    public static func overhead(header: String, notes: [String]) -> Int {
        var size = header.isEmpty ? 0 : header.count + 1
        size += notes.reduce(0) { $0 + $1.count + 1 }
        if !notes.isEmpty {
            size += JSONValue.array(notes.map(JSONValue.string)).deliveredSize
        }
        return size
    }

    public static func render(
        _ payloads: [MCPDocumentPayload],
        limits: MCPOutputLimits,
        metric: String? = nil,
        fields: [String]? = nil,
        budget: Int? = nil,
        reserve: Int = 0,
        vocabulary: Vocabulary = .documents
    ) -> Output {
        var documents: [JSONValue] = []
        var lines: [String] = []
        // Пометки самого рендера собираются **до** цикла: они зависят только
        // от того, что пришло, а не от того, сколько поместилось, — и потому
        // могут быть оплачены наравне со всем остальным.
        let tailNotes = Self.tailNotes(payloads, limits: limits, fields: fields)
        // Пометка об урезании — по верхней оценке: чисел в ней два, и оба
        // не длиннее общего счёта.
        let cutNote = Self.cutNote(shown: payloads.count, total: payloads.count, vocabulary: vocabulary)
        var notes: [String] = []
        /// Сколько занял первый документ, если ответ из-за него вышел
        /// за объявленный потолок.
        var overflowed: Int?
        var budget = max(
            1,
            (budget ?? limits.responseCharacters)
                - Self.envelopeReserve
                - reserve
                - Self.overhead(header: "", notes: tailNotes + [cutNote])
        )
        // Множество собирается один раз на весь ответ: полей у документа
        // бывает под две сотни, а искать каждое из них по списку — это работа
        // на ровном месте.
        let wanted: Set<String>? = fields.flatMap { $0.isEmpty ? nil : Set($0) }

        for (index, payload) in payloads.enumerated() {
            let full = payload.text ?? ""
            // Метаданные считаются вместе с текстом: у документа из настоящей
            // коллекции их набирается на полтора килобайта, и бюджет, который
            // их не видит, ограничивает ответ только на бумаге.
            let visible = Self.projected(payload.metadata, to: wanted)
            let metadataLine = Self.metadataLine(visible)

            /// Готовый документ — строкой и зеркалом сразу.
            ///
            /// Одна сборка на оба вида, и зовётся она дважды: сперва с пустым
            /// текстом, чтобы узнать постоянную часть, потом с настоящим.
            /// Прежде допуск вычитал метаданные **один** раз, а списание шло
            /// за два — строкой и зеркалом, — и последний впущенный документ
            /// переваливал за бюджет примерно на свой же блок метаданных
            ///.
            func assemble(_ shownText: String) -> (body: String, mirror: JSONValue) {
                let wasCut = shownText.count < full.count
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
                if let metadata = visible, !metadata.isEmpty {
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
                var header = payload.role == .context
                    ? "— context, id «\(payload.id)»"
                    : "\((index + 1).plainDigits). id «\(payload.id)»"
                // То же, что и в структурированном ответе, и по той же причине:
                // модель читает текст, а в строке метаданных отпечаток теряется
                // среди трёх десятков полей.
                if case .string(let fileID)? = payload.metadata?["file_id"], !fileID.isEmpty {
                    header += ", whole file — get_file with file_id \(fileID)"
                }
                if let distance = payload.distance {
                    let value = String(format: "%.4f", distance)
                    header += metric.map { ", distance \(value) (\($0))" }
                        ?? ", distance \(value)"
                }
                if let collection = payload.collection {
                    header += ", collection «\(collection)»"
                }
                if let note = payload.note { header += ", \(note)" }
                if !metadataLine.isEmpty { header += "\n   " + metadataLine }
                var body = header
                if payload.text != nil {
                    body += "\n" + shownText
                    if wasCut {
                        body += "\n" + "[text cut: \(shownText.count.plainDigits) of \(full.count.plainDigits) characters shown; the whole document — get_documents with id «\(payload.id)»]"
                    }
                }
                return (body, .object(object))
            }
            // С бюджета списывается **всё, что уезжает**: готовая строка со
            // своей обвязкой — заголовком, отпечатком, расстоянием, пометкой
            // об обрезке — и зеркало в `structuredContent`. Считать один голый
            // текст было мало: обещанные «24 000 символов на ответ»
            // оборачивались 42 281, и агент планировал по числу вдвое меньше
            // правды.
            func cost(_ piece: (body: String, mirror: JSONValue)) -> Int {
                piece.body.count + 1 + piece.mirror.deliveredSize
            }

            // Постоянная часть — всё, кроме самого текста. Место под текст
            // делится надвое: он уезжает и строкой, и зеркалом.
            let room = budget - cost(assemble(""))

            // Первый документ отдаётся всегда, даже если он один съедает весь
            // бюджет: ответ без единого результата хуже, чем ответ с одним.
            // Дальше список обрывается, не дожидаясь нуля: результат, которому
            // осталось полста символов текста, — это не результат, а шум.
            if index > 0, room < 2 * Self.minimumUsefulText {
                notes.append(Self.cutNote(shown: index, total: payloads.count, vocabulary: vocabulary))
                break
            }

            let shareOfRoom = max(0, room) / 2
            let allowance = index == 0
                // Первый документ отдаётся всегда: ответ без единого
                // результата хуже урезанного. Но и он теперь считается — не
                // больше того, что влезет вдвоём с зеркалом.
                ? min(limits.documentCharacters, max(Self.minimumUsefulText, shareOfRoom))
                : min(limits.documentCharacters, shareOfRoom)
            let shownText = full.count > allowance ? String(full.prefix(allowance)) : full
            let piece = assemble(shownText)
            let spend = cost(piece)
            // Проверка по **готовому**, а не по оценке: экранирование в JSON
            // добавляет знаков — кавычка и перевод строки уезжают двумя, — и
            // на тексте, богатом ими, оценка промахнулась бы в большую сторону.
            if index > 0, spend > budget {
                notes.append(Self.cutNote(shown: index, total: payloads.count, vocabulary: vocabulary))
                break
            }
            // Первый документ мог не влезть и всё равно уехать — это
            // обещанное поведение, но молчать о нём нельзя: у ключа
            // с малым потолком метаданные одного куска бывают больше всего
            // бюджета, и ответ выходит за объявленное. Сплошной текст про
            // такой случай говорит с; список — не говорил.
            //
            //
            // Сравнение с рабочим остатком, а не с потолком, — не описка
            //. Место под текст первого документа выводится из того же
            // остатка, так что перевалить через него он может **только**
            // когда остатка почти нет, а тогда и потолок уже пройден: два
            // сравнения совпадают всюду, где вообще срабатывают. Отдельная
            // проверка держит соседний случай — ответ, который уложился,
            // не должен утверждать обратное.
            if index == 0, spend > budget {
                overflowed = spend
            }
            documents.append(piece.mirror)
            lines.append(piece.body)
            budget -= spend
        }
        if let overflowed {
            notes.append("This answer is longer than the key's ceiling of \(limits.responseCharacters.plainDigits) characters: the first \(vocabulary.item) alone takes \(overflowed.plainDigits) with its metadata, and an answer with nothing in it would be useless. Ask for a key with a larger ceiling, or name fewer fields in «fields».")
        }

        notes += tailNotes

        return Output(
            documents: documents, lines: lines, notes: notes,
            shown: documents.count, total: payloads.count
        )
    }
}
