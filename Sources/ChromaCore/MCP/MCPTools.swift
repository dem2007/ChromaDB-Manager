import Foundation

/// Какое право нужно инструменту.
///
/// Ничего нового: те же три уровня, что у ключа внешнего клиента этапа 3.
/// Второй модели прав не заводим — разошедшись, они дали бы дыру именно там,
/// где её никто не ищет.
public enum MCPToolPermission: String, Sendable, Hashable {
    case read
    case write
    /// Удаление отдельным правом: снести коллекцию одним неудачным вызовом
    /// слишком легко, чтобы это право ехало вместе с обычной записью.
    case delete
}

/// Описание инструмента — то, что читает модель.
///
/// «Описания инструментов и параметров пишутся для модели, а не для человека»,
/// и плохое описание — функциональный дефект этапа, а не косметика. Поэтому
/// в тексте каждого инструмента сказано: что делает, когда применять, чего
/// не делает и какие ограничения.
public struct MCPToolDefinition: Sendable, Hashable {
    public let name: String
    public let title: String
    public let description: String
    /// JSON Schema параметров. По спецификации обязана быть объектом-схемой,
    /// а не `null`; у инструмента без параметров — `additionalProperties: false`.
    public let inputSchema: JSONValue
    /// Объявляется не для красоты: объявив её, сервер **обязан** возвращать
    /// `structuredContent` по ней. Поэтому она есть только там, где выдача
    /// действительно машинная.
    public let outputSchema: JSONValue?
    public let permission: MCPToolPermission

    public init(
        name: String,
        title: String,
        description: String,
        inputSchema: JSONValue,
        outputSchema: JSONValue? = nil,
        permission: MCPToolPermission
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.permission = permission
    }

    /// Вид инструмента в ответе `tools/list`, сверенный со спецификацией
    /// ревизии 2026-07-28.
    public var listing: JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
        ]
        if let outputSchema { object["outputSchema"] = outputSchema }
        return .object(object)
    }
}

/// Результат вызова инструмента.
///
/// **Отказ — это `isError: true`, а не ошибка JSON-RPC.** Спецификация делит
/// «запрос сформирован неправильно» (ошибка протокола, модель её не исправит)
/// и «инструмент отработал и не смог» (ошибка выполнения, модель читает
/// причину и исправляется). Отказ по правам — второе: D2.5 требует, чтобы
/// агент мог объяснить причину человеку, а не показать пустой результат.
public struct MCPToolOutcome: Sendable, Hashable {
    public var text: String
    public var structured: JSONValue?
    public var isError: Bool

    public init(text: String, structured: JSONValue? = nil, isError: Bool = false) {
        self.text = text
        self.structured = structured
        self.isError = isError
    }

    public static func failure(_ text: String) -> MCPToolOutcome {
        MCPToolOutcome(text: text, isError: true)
    }

    /// Ответ в форме `tools/call`.
    ///
    /// Текстовый блок есть всегда, даже когда есть структурированный: этого
    /// прямо просит спецификация ради совместимости, и он же — то, что модель
    /// прочитает, если клиент не умеет `structuredContent`.
    public var result: JSONValue {
        var object: [String: JSONValue] = [
            "resultType": .string("complete"),
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "isError": .bool(isError),
        ]
        if let structured { object["structuredContent"] = structured }
        return .object(object)
    }
}

/// Коллекция, как её видит агент (`list_collections`).
public struct MCPCollectionSummary: Sendable, Hashable {
    public let name: String
    public let documentCount: Int?
    public let model: String?
    public let metric: String?
    public let dimension: Int?

    public init(
        name: String, documentCount: Int?, model: String?, metric: String?, dimension: Int?
    ) {
        self.name = name
        self.documentCount = documentCount
        self.model = model
        self.metric = metric
        self.dimension = dimension
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = ["name": .string(name)]
        if let documentCount { object["documents"] = .int(documentCount) }
        if let model { object["model"] = .string(model) }
        if let metric { object["metric"] = .string(metric) }
        if let dimension { object["dimension"] = .int(dimension) }
        return .object(object)
    }
}

/// Поле метаданных с примерами значений (`describe_collection`).
public struct MCPFieldDescription: Sendable, Hashable {
    public let key: String
    public let type: String
    public let isRequired: Bool
    public let note: String?
    /// Несколько настоящих значений из коллекции: без них модель фильтрует
    /// наугад и получает пустую выдачу, не понимая почему.
    public let examples: [String]

    public init(key: String, type: String, isRequired: Bool, note: String?, examples: [String]) {
        self.key = key
        self.type = type
        self.isRequired = isRequired
        self.note = note
        self.examples = examples
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = [
            "field": .string(key),
            "type": .string(type),
            "required": .bool(isRequired),
        ]
        if let note, !note.isEmpty { object["note"] = .string(note) }
        if !examples.isEmpty { object["examples"] = .array(examples.map(JSONValue.string)) }
        return .object(object)
    }
}

public struct MCPCollectionDescription: Sendable, Hashable {
    public let summary: MCPCollectionSummary
    public let fields: [MCPFieldDescription]
    /// Есть ли у коллекции схема вообще. «Схемы нет» и «схема пустая» — разные
    /// новости: в первом случае фильтровать можно по любому полю, какое там
    /// окажется, во втором кто-то её завёл и оставил пустой.
    public let hasSchema: Bool
    public let allowsExtraFields: Bool
    /// Поля, которые в выборку попали, но в описание не поместились —
    /// **одними именами**, без примеров.
    ///
    /// Имя стоит десяток знаков, а примеры — сотни, и режется ради контекста
    /// модели именно второе. Само имя агенту нужнее всего: без него он не
    /// составит фильтр, а с ним — спросит примеры отдельным вызовом. Молчать
    /// же нельзя: колонки таблиц («стоимость_тыс_руб», «итого») отрезались
    /// первыми, потому что кириллица сортируется после латиницы, и агент
    /// не мог узнать, что цены вообще есть в метаданных.
    public let otherFields: [String]

    public init(
        summary: MCPCollectionSummary,
        fields: [MCPFieldDescription],
        hasSchema: Bool,
        allowsExtraFields: Bool,
        otherFields: [String] = []
    ) {
        self.summary = summary
        self.fields = fields
        self.hasSchema = hasSchema
        self.allowsExtraFields = allowsExtraFields
        self.otherFields = otherFields
    }

    public var json: JSONValue {
        .object([
            "collection": summary.json,
            "hasSchema": .bool(hasSchema),
            "allowsExtraFields": .bool(allowsExtraFields),
            "fields": .array(fields.map(\.json)),
        ]
        .merging(otherFields.isEmpty ? [:] : ["otherFields": .array(otherFields.map(JSONValue.string))]) { a, _ in a })
    }
}

/// Поиск, как его просит агент.
///
/// Текст, а не вектор — в этом весь смысл этапа: эмбеддинг считает приложение
/// моделью, привязанной к коллекции, и агент физически не может обратиться
/// к базе вектором от чужой модели.
public struct MCPSearchRequest: Sendable {
    /// Коллекции, по которым идёт поиск. Одна — обычный случай.
    ///
    /// Список, а не одно имя: агент, которому нужны документация, код
    /// и заметки сразу, иначе платил бы тремя вызовами и тремя векторами
    /// одного и того же запроса.
    public let collections: [String]
    public let query: String
    public let nResults: Int
    public let filter: DocumentFilter?
    /// Умный поиск для этого ключа: `nil` — как настроено у коллекции.
    /// Решает владелец базы в правах ключа, а не агент: иначе настройка,
    /// которую человек выключил, включалась бы обратно чужим запросом.
    public let smartSearch: Bool?

    /// Первая из коллекций — она же единственная в обычном случае.
    public var collection: String { collections.first ?? "" }
    /// Искать ли больше чем в одной.
    public var isMultiCollection: Bool { collections.count > 1 }

    public init(
        collection: String, query: String, nResults: Int, filter: DocumentFilter?,
        smartSearch: Bool? = nil
    ) {
        self.init(
            collections: [collection], query: query, nResults: nResults,
            filter: filter, smartSearch: smartSearch
        )
    }

    public init(
        collections: [String], query: String, nResults: Int, filter: DocumentFilter?,
        smartSearch: Bool? = nil
    ) {
        self.collections = collections
        self.query = query
        self.nResults = nResults
        self.filter = filter
        self.smartSearch = smartSearch
    }
}

public struct MCPSearchAnswer: Sendable {
    public let documents: [MCPDocumentPayload]
    /// Метрика коллекции: без неё число «0.42» ничего не значит — у одной
    /// метрики это близко, у другой далеко.
    public let metric: String?
    public let model: String?
    /// Чем именно искали — одной строкой. Правило 2 приложения 5: настройки
    /// поиска меняют выдачу, и агент вправе знать, какие из них сработали.
    public let note: String?

    public init(
        documents: [MCPDocumentPayload], metric: String?, model: String?, note: String? = nil
    ) {
        self.documents = documents
        self.metric = metric
        self.model = model
        self.note = note
    }
}

/// Выборка документов без поиска (`get_documents`).
public struct MCPDocumentsRequest: Sendable {
    public let collection: String
    public let ids: [String]
    public let filter: DocumentFilter?
    public let limit: Int
    public let offset: Int
    /// Отдавать чанки в порядке файла, а не как придётся.
    ///
    /// Просит `get_file`. Обычный `get_documents` этого не просит и получает
    /// то же, что и раньше: у произвольной выборки по фильтру порядка нет
    /// и быть не может, а обещать его — хуже, чем не обещать.
    public let orderedByChunkIndex: Bool

    public init(
        collection: String,
        ids: [String],
        filter: DocumentFilter?,
        limit: Int,
        offset: Int,
        orderedByChunkIndex: Bool = false
    ) {
        self.collection = collection
        self.ids = ids
        self.filter = filter
        self.limit = limit
        self.offset = offset
        self.orderedByChunkIndex = orderedByChunkIndex
    }
}

public struct MCPDocumentsAnswer: Sendable {
    public let documents: [MCPDocumentPayload]
    /// Есть ли что-то за этой страницей. Устанавливается по запросу на один
    /// документ больше потолка: иначе «ровно limit документов» и «дальше есть
    /// ещё» неотличимы, и агент останавливается на середине коллекции.
    public let hasMore: Bool
    /// Сколько всего документов подошло под запрос. Известно только там, где
    /// выборка считалась целиком, — то есть у упорядоченной выдачи `get_file`.
    public let total: Int?
    /// Файл оказался длиннее, чем приложение готово упорядочить
    /// (`MCPFileChunks.maximumOrdered`), и порядок не гарантируется.
    ///
    /// Отдельным полем, а не молчанием: агент, собирающий файл обратно,
    /// обязан узнать, что склеивает куски в неизвестном порядке.
    public let orderUnavailable: Bool

    public init(
        documents: [MCPDocumentPayload],
        hasMore: Bool,
        total: Int? = nil,
        orderUnavailable: Bool = false
    ) {
        self.documents = documents
        self.hasMore = hasMore
        self.total = total
        self.orderUnavailable = orderUnavailable
    }
}

/// Документ, который агент просит записать (`add_documents`).
public struct MCPIncomingDocument: Sendable {
    /// Идентификатор. `nil` — приложение придумает его само.
    public let id: String?
    public let text: String
    public let metadata: ChromaMetadata?

    public init(id: String?, text: String, metadata: ChromaMetadata?) {
        self.id = id
        self.text = text
        self.metadata = metadata
    }
}

public struct MCPAddRequest: Sendable {
    public let collection: String
    public let documents: [MCPIncomingDocument]

    public init(collection: String, documents: [MCPIncomingDocument]) {
        self.collection = collection
        self.documents = documents
    }

    /// Что из этого нужно проверке лимитов ключа.
    public var payload: MCPWritePayload {
        MCPWritePayload(
            documentCount: documents.count,
            largestDocumentBytes: documents.map { $0.text.utf8.count }.max() ?? 0
        )
    }
}

public struct MCPAddAnswer: Sendable {
    public let ids: [String]
    /// Модель, которой посчитаны векторы, — её называют агенту: коллекция
    /// привязана к одной модели, и это то, чем его текст стал.
    public let model: String?
    public let note: String?

    public init(ids: [String], model: String?, note: String? = nil) {
        self.ids = ids
        self.model = model
        self.note = note
    }
}

/// Удаление документов (`delete_documents`).
///
/// Только по явному списку — фильтра здесь нет и не будет: удалить полколлекции
/// одним неточным условием слишком легко, а восстанавливать нечего.
public struct MCPDeleteRequest: Sendable {
    public let collection: String
    public let ids: [String]

    public init(collection: String, ids: [String]) {
        self.collection = collection
        self.ids = ids
    }
}

public struct MCPDeleteAnswer: Sendable {
    public let deleted: [String]
    /// Идентификаторы, которых в коллекции не было. Называются отдельно:
    /// «удалено 2 из 5» без перечисления оставляет агента гадать, какие три.
    public let missing: [String]
    /// Сохранена ли копия в корзине. Агент вправе знать, обратимо ли то,
    /// что он сделал.
    public let keptInTrash: Bool

    public init(deleted: [String], missing: [String], keptInTrash: Bool) {
        self.deleted = deleted
        self.missing = missing
        self.keptInTrash = keptInTrash
    }
}

/// Ошибка, у которой есть причина **для модели**.
///
/// Тексты ошибок в приложении написаны по-русски: их читает человек у экрана.
/// Поверхность MCP английская, и подставлять в неё русскую причину нельзя —
/// но и молчать о причине нельзя тоже: «LM Studio не запущена» агент обязан
/// узнать, иначе он сообщит человеку «инструмент не сработал» и на этом
/// остановится. Поэтому у ошибки два текста: `errorDescription` человеку
/// и `mcpReason` модели.
public protocol MCPReadableError: Error {
    /// Причина по-английски, без кириллицы.
    var mcpReason: String { get }
}

/// Отказ, сформулированный для модели.
///
/// Отдельный тип, чтобы служба не оборачивала такое сообщение в «инструмент не
/// отработал»: причина уже написана так, чтобы агент по ней исправился.
public struct MCPToolFailure: LocalizedError, Sendable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}

/// Объём записи — то, по чему проверяются лимиты ключа (7.4).
public struct MCPWritePayload: Sendable, Hashable {
    public let documentCount: Int
    public let largestDocumentBytes: Int

    public init(documentCount: Int, largestDocumentBytes: Int) {
        self.documentCount = documentCount
        self.largestDocumentBytes = largestDocumentBytes
    }
}

/// Что инструментам нужно от приложения.
///
/// Протокол, а не прямые вызовы клиента ChromaDB: инструменты живут в ядре и
/// закрываются тестами, а база, очередь и модель остаются в приложении.
public protocol MCPToolBackend: Sendable {
    /// Каталог, уже ограниченный именами из whitelist ключа.
    func collections(allowed: [String]) async throws -> [MCPCollectionSummary]
    /// Описание одной коллекции: схема метаданных и примеры значений.
    func describe(collection: String) async throws -> MCPCollectionDescription
    /// Поиск. Реализация обязана идти через единый `RetrievalPipeline`:
    /// вторая реализация поиска означала бы, что настройки, которые человек
    /// подкрутил на экране, к запросам агента не применяются.
    func search(_ request: MCPSearchRequest) async throws -> MCPSearchAnswer
    /// Документы по идентификаторам или по фильтру.
    func documents(_ request: MCPDocumentsRequest) async throws -> MCPDocumentsAnswer
    /// Запись документов. Чанкинг не применяется: что прислали, то и
    /// стало одним документом с одним вектором.
    func add(_ request: MCPAddRequest) async throws -> MCPAddAnswer
    /// Удаление по явному списку идентификаторов.
    func delete(_ request: MCPDeleteRequest) async throws -> MCPDeleteAnswer
}

/// Реестр инструментов этапа 7.
public enum MCPToolCatalogue {
    public static let listCollections = MCPToolDefinition(
        name: "list_collections",
        title: "List collections",
        description: """
        Lists the ChromaDB collections this key may reach. Call it first when \
        you do not know where to look: every other tool needs a collection name. \
        For each collection you get its name, document count, embedding model and \
        distance metric. **The answer also states this key's limits** — how many \
        results one search may return, how many collections one search may cover, \
        and the character budgets. Read them before you choose `n_results`: the \
        ceiling is a property of the key, not a constant. Collections outside the \
        key's list are not shown at all; their absence does not mean they are not \
        in the database. Collections cannot be created or deleted over MCP.
        """,
        inputSchema: .object([
            "type": .string("object"),
            // Пустой список свойств пишется явно. По JSON Schema объект без
            // `properties` полностью законен, но клиенты перекладывают схему
            // инструмента в вызов функции у своего поставщика модели, и там
            // отсутствие ключа и пустой ключ — разные вещи: часть слоёв на
            // первом спотыкается. Стоит это ровно одну строку, а спотыкается
            // на ней тот самый инструмент, которым агент начинает разговор.
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ]),
        outputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "collections": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("object")]),
                ]),
            ]),
            "required": .array([.string("collections")]),
        ]),
        permission: .read
    )

    public static let describeCollection = MCPToolDefinition(
        name: "describe_collection",
        title: "Describe collection",
        description: """
        Explains how one collection is built: which metadata fields exist, their \
        types, which are required and which values occur in them. Call it before \
        writing a filter — without it a filter is a guess, and a wrong field name \
        returns an empty answer rather than an error. \
        If the collection has no schema the fields are still listed, taken from \
        what the documents actually carry. \
        **Table columns are fields too.** A table row is stored as its own \
        document, and its columns become metadata fields named after the header: \
        «стоимость_тыс_руб», «итого», «2026». You can filter and compare numbers \
        on them — that is how you collect every price of one item across dozens of \
        files without reading their text. \
        Fields that did not fit in the description are listed by **name only** in \
        «otherFields»: a name is all a filter needs, and example values for it can \
        be fetched with one get_documents call.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "collection": .object([
                    "type": .string("string"),
                    "description": .string("Collection name from list_collections."),
                ]),
            ]),
            "required": .array([.string("collection")]),
            "additionalProperties": .bool(false),
        ]),
        outputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "collection": .object(["type": .string("object")]),
                "fields": .object(["type": .string("array")]),
            ]),
            "required": .array([.string("collection"), .string("fields")]),
        ]),
        permission: .read
    )

    /// Общие описания параметров фильтра — слово в слово одинаковые в обоих
    /// инструментах. Разойдясь, они рассказали бы модели про два разных
    /// фильтра там, где он один.
    private static let filterProperty = JSONValue.object([
        "type": .string("object"),
        "description": .string("""
        Metadata filter in ChromaDB syntax: {"field": {"$eq": value}}. \
        Supported: $eq, $ne, $gt, $gte, $lt, $lte, $in, $nin, and $and / $or with a \
        list of conditions. Take field names and their types from \
        describe_collection: comparing against the number 2024 and against the \
        string «2024» are different conditions, and the second returns nothing.
        """),
    ])

    /// Тип исходного файла человеческим словом.
    ///
    /// Без него агенту пришлось бы знать наизусть, что «Excel» в базе — это
    /// шесть разных расширений, и он ставил бы `file_ext = "xlsx"`, молча
    /// теряя `xls`, `ods` и остальное.
    private static let fileTypesProperty = JSONValue.object([
        "type": .string("array"),
        "items": .object(["type": .string("string")]),
        "description": .string("""
        Keep only documents that came from files of this kind. \
        Values: word — .docx, .doc, .odt, .rtf, .pages; excel — .xlsx, .xls, \
        .xlsm, .ods, .numbers, .csv, .tsv; pdf; presentation — .key (Keynote); \
        text — .txt, .md; web; book; code; data. A bare extension works too, \
        «docx» for instance: every result carries it in file_ext. Several values \
        combine with «or»: ["word", "pdf"] returns both. Combines with «filter» \
        by «and», so a file kind and a metadata condition can be set together.
        """),
    ])

    private static let containsProperty = JSONValue.object([
        "type": .string("string"),
        "description": .string("""
        A substring that must occur in the document text. Case need not be \
        matched: the usual spellings are tried (as given, lowercase, Capitalised, \
        and UPPERCASE for short words), so «astra» finds «Astra». A spelling like \
        «AsTrA» will not be found this way — the database compares substrings \
        literally.
        """),
    ])

    /// Проекция метаданных: какие поля попадут в ответ.
    private static let fieldsProperty = JSONValue.object([
        "type": .string("array"),
        "items": .object(["type": .string("string")]),
        "description": .string("""
        Which metadata fields to return. Unset — all of them. Set it when table \
        rows are in the answer: a row drags **all of its columns** along, and the \
        answer budget goes on the ones the question never asked about. Measured on \
        a live base: the hundred widest rows carried 1883 characters of metadata \
        each and eight rows fitted in one answer; with a projection of four fields \
        it was 94 characters and fifty-six rows. \
        Names exactly as in describe_collection; a field no document carries is \
        named in the answer. This does not affect which documents are selected: \
        the filter still works over every field, only the shown ones are limited.
        """),
    ])

    public static let search = MCPToolDefinition(
        name: "search",
        title: "Search by meaning",
        description: """
        Finds documents by meaning in one collection. Treat it as the main way to \
        find something: write the query as an ordinary phrase or question — the \
        application computes the vector with the model bound to the collection, so \
        an embedding must not be passed. Results run from nearest to furthest; the \
        distance comes with the collection's metric, and smaller means closer. \
        A result may carry its parent section marked as context: it does not take \
        one of the requested places. Long documents are cut with an explicit note — \
        take the full text with get_file or get_documents by the same id. \
        You can search **several collections at once**: pass them as a list in \
        «collections» instead of «collection». The query vector is computed once, \
        each result says which collection it came from, and the merged list is \
        reranked as a whole, so candidates compete across collections. Passing both \
        parameters at once is refused. Collections outside the key's list are not \
        searched. \
        **Semantic search does not answer «is it in every file».** Proximity keeps \
        returning neighbouring chunks of the same documents: measured on a live \
        base, a topic gave chunks of three files out of thirteen at any number of \
        results. For coverage use collect_mentions. \
        If a table is in the answer: one table row is one position, and its price \
        belongs to the whole row. An enumeration inside a cell (two goods separated \
        by «;») adds no positions and does not double the price. Counting from \
        fragments is unreliable in general — a fragment is a piece of a file, not \
        the file; for arithmetic take whole files with get_file.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "collection": .object([
                    "type": .string("string"),
                    "description": .string("Collection name from list_collections. To search several, use «collections» instead."),
                ]),
                "collections": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("""
                    Several collections from list_collections. Use it when the answer may lie \
                    in different places — documentation, code, notes: one call and one \
                    query vector instead of three. The number of collections is capped by \
                    the key's rights; the extra ones are not searched and the answer says so.
                    """),
                ]),
                "query": .object([
                    "type": .string("string"),
                    "description": .string("""
                    The query: a phrase or a question in natural language. Separate keywords \
                    work worse — the search is by meaning.
                    """),
                ]),
                "n_results": .object([
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "description": .string("""
                    How many results to return. **Choose this number, do not leave it \
                    to the default.** Without it you get 5 — enough to look at, not \
                    enough to count with. The ceiling belongs to the key and is stated \
                    by list_collections; it is often far above 5, so ask for what the \
                    question needs: a handful to read, dozens to compare or to be sure \
                    nothing was missed. Asking above the ceiling is not refused — the \
                    answer is trimmed and says so.
                    """),
                ]),
                "filter": filterProperty,
                "file_types": fileTypesProperty,
                "contains": containsProperty,
                "fields": fieldsProperty,
            ]),
            "required": .array([.string("query")]),
            "additionalProperties": .bool(false),
        ]),
        outputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "collection": .object(["type": .string("string")]),
                "collections": .object(["type": .string("array")]),
                "documents": .object(["type": .string("array")]),
            ]),
            "required": .array([.string("documents")]),
        ]),
        permission: .read
    )

    public static let getDocuments = MCPToolDefinition(
        name: "get_documents",
        title: "Get documents",
        description: """
        Returns whole documents — by a list of identifiers or by a filter, with no \
        search by meaning. Use it when the ids are already known: to finish reading \
        a document search had cut, for example. It also walks a collection page by \
        page — then no filter is needed and pages are turned with «offset». If you \
        are looking for «something like this», it is the wrong tool: there are no \
        distances here and the order is arbitrary, take search. \
        Vectors are never returned.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "collection": .object([
                    "type": .string("string"),
                    "description": .string("Collection name from list_collections."),
                ]),
                "ids": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("""
                    Document identifiers. When the list is given, filter and offset are not \
                    applied: exactly what was asked for is returned.
                    """),
                ]),
                "filter": filterProperty,
                "file_types": fileTypesProperty,
                "contains": containsProperty,
                "limit": .object([
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "description": .string("""
                    How many documents to return. Default 5; the ceiling is the same as for \
                    search and is stated by list_collections — choose it deliberately.
                    """),
                ]),
                "offset": .object([
                    "type": .string("integer"),
                    "minimum": .int(0),
                    "description": .string("How many documents to skip — for paging."),
                ]),
                "fields": fieldsProperty,
            ]),
            "required": .array([.string("collection")]),
            "additionalProperties": .bool(false),
        ]),
        outputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "collection": .object(["type": .string("string")]),
                "documents": .object(["type": .string("array")]),
            ]),
            "required": .array([.string("collection"), .string("documents")]),
        ]),
        permission: .read
    )

    /// файл целиком, по порядку и страницами.
    ///
    /// Отдельный инструмент, а не флаг у `get_documents`: намерение другое.
    /// «Дай мне весь файл» — это не «выбери документы по условию», и агент,
    /// собиравший файл фильтром по `source_file`, вынужден был сам знать про
    /// `chunk_index`, сам сортировать и надеяться, что листание по
    /// неупорядоченной выдаче ничего не пропустит.
    public static let getFile = MCPToolDefinition(
        name: "get_file",
        title: "Whole file",
        description: """
        Returns every chunk of one file **in order** — the order the file was cut \
        into. Use it when search found a fragment but the whole document is needed. \
        Ask by file_id: a short fingerprint carried in the metadata of any result. \
        A path is accepted too, but it is easy to spoil when retyped. The order is \
        guaranteed by this tool and only by it: get_documents by filter returns an \
        arbitrary order. A file is almost always longer than one answer — the answer \
        says how many chunks there are and which offset to ask next; read pages until \
        hasMore is false and join them in sequence. The full path of the file is in \
        the answer as well. Long chunks are cut with a note, and the ceilings belong \
        to the key. If the file holds a table: one row is one position, its price \
        belongs to the whole row, and an enumeration inside a cell adds no positions.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "collection": .object([
                    "type": .string("string"),
                    "description": .string("Collection name from list_collections."),
                ]),
                "file_id": .object([
                    "type": .string("string"),
                    "description": .string("""
                    The file fingerprint — the file_id metadata value of any of its chunks. \
                    Safer than a path: sixteen characters with nothing to spoil. \
                    When given, the «file» parameter is not needed.
                    """),
                ]),
                "file": .object([
                    "type": .string("string"),
                    "description": .string("""
                    The source_file metadata value — the file path relative to the source \
                    folder, exactly as written in the document that was found. \
                    Not a file name and not an absolute path. Use it when file_id \
                    is absent from the metadata: collections filled by earlier builds \
                    do not carry it yet.
                    """),
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "description": .string("How many chunks to return at once. Default 5; the ceiling belongs to the key."),
                ]),
                "offset": .object([
                    "type": .string("integer"),
                    "minimum": .int(0),
                    "description": .string("Which chunk to continue from — the number given by the previous answer."),
                ]),
                "fields": fieldsProperty,
            ]),
            // Обязательна только коллекция: файл называют либо отпечатком,
            // либо путём, и требовать оба значит требовать невозможного.
            "required": .array([.string("collection")]),
            "additionalProperties": .bool(false),
        ]),
        outputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "collection": .object(["type": .string("string")]),
                "file": .object(["type": .string("string")]),
                "fileId": .object(["type": .string("string")]),
                "documents": .object(["type": .string("array")]),
                "total": .object(["type": .string("integer")]),
                "hasMore": .object(["type": .string("boolean")]),
            ]),
            "required": .array([.string("collection"), .string("documents")]),
        ]),
        permission: .read
    )

    public static let addDocuments = MCPToolDefinition(
        name: "add_documents",
        title: "Add documents",
        description: """
        Writes documents into a collection. Send text — the application computes the \
        vector with the model bound to the collection. The text is **not split**: \
        what arrives as one document becomes one document with one vector, so cut \
        long text into meaningful pieces yourself. Text longer than the model's \
        context is refused, naming the document that did not pass. The identifier may \
        be omitted and the application will invent one; a given identifier that is \
        already taken is refused outright — nothing is overwritten, and this tool \
        never touches an existing document. Metadata is a flat object: strings, \
        numbers, booleans; the database accepts neither nested objects nor lists. If \
        the collection has a schema, the metadata is checked against it. Every written \
        document gets the field «origin» set to «mcp», so it is visible that the \
        document came from an agent.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "collection": .object([
                    "type": .string("string"),
                    "description": .string("Collection name from list_collections."),
                ]),
                "documents": .object([
                    "type": .string("array"),
                    "minItems": .int(1),
                    "description": .string("Documents; each an object with text, id (optional) and metadata (optional)."),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "text": .object([
                                "type": .string("string"),
                                "description": .string("The document text. This is what gets indexed."),
                            ]),
                            "id": .object([
                                "type": .string("string"),
                                "description": .string("Identifier. Unset — the application invents one."),
                            ]),
                            "metadata": .object([
                                "type": .string("object"),
                                "description": .string("A flat object: strings, numbers, booleans. Take the fields from describe_collection."),
                            ]),
                        ]),
                        "required": .array([.string("text")]),
                        "additionalProperties": .bool(false),
                    ]),
                ]),
            ]),
            "required": .array([.string("collection"), .string("documents")]),
            "additionalProperties": .bool(false),
        ]),
        outputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "collection": .object(["type": .string("string")]),
                "ids": .object(["type": .string("array")]),
            ]),
            "required": .array([.string("collection"), .string("ids")]),
        ]),
        permission: .write
    )

    public static let deleteDocuments = MCPToolDefinition(
        name: "delete_documents",
        title: "Delete documents",
        description: """
        Deletes documents by an explicit list of identifiers. Deletion by filter is \
        deliberately absent: one imprecise condition takes out half a collection and \
        nothing can undo it. To delete a group, first find it with get_documents using \
        that same filter, look at what came back, and pass the identifiers here. \
        Requires a delete right of its own, separate from the write right: a key \
        allowed to write cannot delete by default. Identifiers that are not in the \
        collection are not an error — they are listed separately in the answer. \
        This tool does not delete collections and cannot: over MCP they can be \
        neither created nor deleted.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "collection": .object([
                    "type": .string("string"),
                    "description": .string("Collection name from list_collections."),
                ]),
                "ids": .object([
                    "type": .string("array"),
                    "minItems": .int(1),
                    "items": .object(["type": .string("string")]),
                    "description": .string("Identifiers of the documents to delete."),
                ]),
            ]),
            "required": .array([.string("collection"), .string("ids")]),
            "additionalProperties": .bool(false),
        ]),
        outputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "collection": .object(["type": .string("string")]),
                "deleted": .object(["type": .string("array")]),
            ]),
            "required": .array([.string("collection"), .string("deleted")]),
        ]),
        permission: .delete
    )

    /// «Собери по теме»: все места, где встречается слово, по файлам.
    public static let collectMentions = MCPToolDefinition(
        name: "collect_mentions",
        title: "All mentions by file",
        description: """
        Collects **every** place where a word occurs and groups them by file: each \
        file says how many matches it holds and shows a sample of the text. This is \
        the coverage tool — «show every document that describes acceptance of work», \
        «is backup required in all of the specifications». Semantic search does not \
        answer that: measured on a live base, a topic gave chunks of three files out \
        of thirteen at any number of results, because proximity returns neighbouring \
        chunks of the same documents. \
        Give the word as a stem without the ending: «приемк» finds both «приемка» \
        and «приемки». Case does not matter, but the comparison is literal — the tool \
        finds no synonyms; that is what search is for. \
        Files run from the most frequent to the rarest and are paged with «offset»; \
        the answer says how many files are shown out of how many.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "collection": .object([
                    "type": .string("string"),
                    "description": .string("Collection name from list_collections."),
                ]),
                "contains": .object([
                    "type": .string("string"),
                    "description": .string("""
                    A word or its stem without the ending: «приемк», «резервн». The usual \
                    spellings are tried, but the comparison is literal — only what \
                    is really in the texts is found.
                    """),
                ]),
                "filter": filterProperty,
                "file_types": fileTypesProperty,
                "fields": fieldsProperty,
                "per_file": .object([
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "description": .string("""
                    How many text samples to show from each file. Default 1: the job is \
                    usually to compare wording across documents, not to read one \
                    of them. No more than three are returned.
                    """),
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "description": .string("""
                    How many **files** to show at once. Default 5; the ceiling belongs to the \
                    key. Files are counted here, not chunks.
                    """),
                ]),
                "offset": .object([
                    "type": .string("integer"),
                    "minimum": .int(0),
                    "description": .string("How many files to skip — for paging."),
                ]),
            ]),
            "required": .array([.string("collection"), .string("contains")]),
            "additionalProperties": .bool(false),
        ]),
        outputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "collection": .object(["type": .string("string")]),
                "contains": .object(["type": .string("string")]),
                "files": .object(["type": .string("array")]),
                "documents": .object(["type": .string("array")]),
                "totalMatches": .object(["type": .string("integer")]),
                "totalFiles": .object(["type": .string("integer")]),
                "hasMore": .object(["type": .string("boolean")]),
            ]),
            "required": .array([.string("collection"), .string("files")]),
        ]),
        permission: .read
    )

    /// Все инструменты сервера в постоянном порядке.
    ///
    /// Порядок именно постоянный, а не «какой получится»: спецификация просит
    /// детерминированный список, потому что на нём клиент строит кэш, а модель
    /// — свой контекст.
    public static let all: [MCPToolDefinition] = [
        listCollections, describeCollection, search, getDocuments, getFile, collectMentions,
        addDocuments, deleteDocuments,
    ]

    /// Инструменты, которым коллекция обязательна. Список, а не флаг у
    /// определения: он же и отвечает на вопрос «по чему проверять whitelist».
    public static let collectionRequired: Set<String> = [
        describeCollection.name, search.name, getDocuments.name, getFile.name,
        collectMentions.name, addDocuments.name, deleteDocuments.name,
    ]

    /// Инструменты, доступные ключу с такими правами.
    ///
    /// Список **сокращается** под права, а не отдаётся целиком: спецификация
    /// это прямо разрешает («MAY vary by the authorization presented on the
    /// request»), а инструмент, который заведомо ответит отказом, — это
    /// приглашение модели потратить вызов впустую. Проверка прав при самом
    /// вызове от этого не отменяется: она остаётся второй линией.
    public static func available(
        for permissions: ClientPermissions, readOnlyServer: Bool
    ) -> [MCPToolDefinition] {
        all.filter { tool in
            switch tool.permission {
            case .read: return true
            case .write: return permissions.allowsWrite && !readOnlyServer
            case .delete: return permissions.allowsWrite && permissions.allowsDelete && !readOnlyServer
            }
        }
    }
}

/// Исполнение инструментов: права, вызов, форма ответа.
public struct MCPToolService: Sendable {
    private let backend: any MCPToolBackend
    private let access: AccessController
    /// Переключатель «весь сервер только на чтение». Замыканием, а не
    /// значением: его переключают на ходу, и сервис обязан узнать об этом
    /// без пересоздания.
    private let isReadOnlyServer: @Sendable () -> Bool
    /// Куда записывается каждый вызов. Тот же журнал, что у прокси:
    /// вопрос «что делали с базой чужими руками» один, и разводить его по двум
    /// файлам значило бы заставить владельца сверять их глазами.
    private let audit: (@Sendable (AuditEntry) -> Void)?
    /// Ключ только что поработал.
    ///
    /// Тот же обработчик, что у прокси, и по той же причине: карточка клиента
    /// показывает «когда его видели в последний раз», и «ещё не подключался»
    /// у ключа, которым минуту назад искали, — это неправда на экране.
    /// Отдельно от журнала: журнал пишет **события**, а это состояние ключа,
    /// и живёт оно в настройках.
    private let onClientSeen: (@Sendable (UUID) -> Void)?

    public init(
        backend: any MCPToolBackend,
        access: AccessController,
        isReadOnlyServer: @escaping @Sendable () -> Bool = { false },
        audit: (@Sendable (AuditEntry) -> Void)? = nil,
        onClientSeen: (@Sendable (UUID) -> Void)? = nil
    ) {
        self.backend = backend
        self.access = access
        self.isReadOnlyServer = isReadOnlyServer
        self.audit = audit
        self.onClientSeen = onClientSeen
    }

    /// Сколько текста параметров уходит в журнал.
    ///
    /// 5 просит полный текст, и он записывается полностью — до предела,
    /// за которым один вызов с мегабайтным документом вытеснил бы из файла всю
    /// историю. Обрезка помечается: журнал, молча теряющий часть записи, хуже
    /// журнала, признающего это.
    static let auditParameterLimit = 20_000

    private func record(
        tool: MCPToolDefinition,
        key: String?,
        clientName: String?,
        collection: String?,
        arguments: JSONValue?,
        note: String?,
        responseBytes: Int,
        started: Date
    ) {
        guard let audit else { return }
        var text = arguments?.jsonString ?? ""
        if text.count > Self.auditParameterLimit {
            text = String(text.prefix(Self.auditParameterLimit))
                + "… [parameters truncated in the log]"
        }
        audit(AuditEntry(
            client: clientName ?? key.map { "\(ClientKey.prefix(of: $0))…" } ?? "no key",
            method: MCPProtocol.callToolMethod,
            path: tool.name,
            operation: tool.name,
            access: tool.permission == .read ? .read : .write,
            collection: collection,
            requestBytes: text.utf8.count,
            responseStatus: nil,
            responseBytes: responseBytes,
            durationSeconds: Date().timeIntervalSince(started),
            note: note,
            transport: .mcp,
            parameters: text
        ))
    }

    /// Ответ на `tools/list`.
    ///
    /// Незарегистрированный ключ получает **не ошибку, а список инструментов
    /// чтения**. Отказ на этом шаге выглядел бы как «сервер сломан»: клиент
    /// вызывает `tools/list` первым делом и покажет человеку именно это.
    /// Пусть лучше сервер отвечает, а точную причину («ключ не зарегистрирован»)
    /// человек прочитает из первого же вызова — она сформулирована для чтения.
    public func list(key: String?) async -> JSONValue {
        let readOnly = isReadOnlyServer()
        let decision = await access.decideTool(
            key: key, permission: .read, collection: nil, isReadOnlyServer: readOnly
        )
        let tools = decision.client.map {
            MCPToolCatalogue.available(for: $0.permissions, readOnlyServer: readOnly)
        } ?? MCPToolCatalogue.all.filter { $0.permission == .read }

        return .object([
            "resultType": .string("complete"),
            "tools": .array(tools.map(\.listing)),
        ])
    }

    /// Ответ на `tools/call`.
    ///
    /// `Result` с ошибкой JSON-RPC — только для того, чего модель исправить не
    /// может: неизвестного инструмента и неразобранных параметров. Всё
    /// остальное — отказ по правам, отсутствующая коллекция, сбой базы —
    /// возвращается как `isError: true` с причиной словами.
    public func call(name: String, arguments: JSONValue?, key: String?) async -> Result<JSONValue, JSONRPCError> {
        let started = Date()
        guard let tool = MCPToolCatalogue.all.first(where: { $0.name == name }) else {
            return .failure(JSONRPCError(
                code: JSONRPCError.methodNotFound,
                message: "Unknown tool: \(name)"
            ))
        }

        // Коллекция нужна до проверки прав: без неё whitelist проверить не по
        // чему, а после — уже поздно.
        // Пустая строка — это тоже «не указана»: проверка на `nil` её
        // пропускала, и вызов уходил дальше без имени коллекции.
        let collection = arguments?["collection"]?.stringValue
        // У поиска коллекция может приехать списком — тогда «collection»
        // пуст законно, а имена проверяются по одному ниже, после разбора.
        // **Только у поиска**: остальные инструменты списка не принимают, и
        // послабление для них означало бы вызов, ушедший дальше с пустым
        // именем и упавший как «Коллекция «» не найдена».
        let named = tool.name == MCPToolCatalogue.search.name
            && (arguments?["collections"]?.arrayValue?.first?.stringValue).map { !$0.isEmpty } ?? false
        if MCPToolCatalogue.collectionRequired.contains(tool.name),
           collection?.isEmpty != false, !named {
            return .failure(.invalidParams(
                tool.name == MCPToolCatalogue.search.name
                    ? "No collection given: pass «collection» or a list in «collections»."
                    : "No collection given: the «collection» parameter is required."
            ))
        }

        // Вектор не принимается ни одним инструментом (DoD этапа 7). Схема его
        // и так не описывает, но молчаливо выброшенный параметр агент примет
        // за применённый: он обязан узнать, что запрос ушёл не таким, как он
        // его составил.
        if let rejected = Self.vectorParameter(in: arguments) {
            return .success(MCPToolOutcome.failure("The «\(rejected)» parameter is not supported: vectors are not passed over MCP. Write the query as text in «query» — ChromaDB Manager computes the embedding with the model bound to the collection.").result)
        }

        // Запись разбирается **до** решения: по её объёму проверяются суточный
        // лимит документов и предельный размер одного из них, а после решения
        // проверять было бы уже поздно.
        var writing: MCPAddRequest?
        if tool.name == MCPToolCatalogue.addDocuments.name {
            switch Self.addRequest(collection ?? "", arguments) {
            case .failure(let error): return .failure(error)
            case .success(let parsed): writing = parsed
            }
        }

        let decision = await access.decideTool(
            key: key,
            permission: tool.permission,
            collection: collection,
            isReadOnlyServer: isReadOnlyServer(),
            writing: writing?.payload
        )
        // Объём ответа для журнала. Считается там, где ответ уже собран,
        // и хранится в переменной: возвратов у вызова полтора десятка, а запись
        // в журнал одна и идёт через `defer` — прочитать из неё возвращаемое
        // значение нельзя. До этой починки в журнал уходил ноль, и столбец
        // «Объём» показывал один только запрос, выдавая ответ на мегабайт за
        // ответ ни на что.
        var responseBytes = 0
        func answered(_ value: JSONValue) -> Result<JSONValue, JSONRPCError> {
            responseBytes = value.jsonString?.utf8.count ?? 0
            return .success(value)
        }
        // У протокольного отказа ответ тоже есть, и он тоже занимает место:
        // считаем его по тем полям, которые уедут клиенту.
        func refused(_ error: JSONRPCError) -> Result<JSONValue, JSONRPCError> {
            responseBytes = JSONValue.object([
                "code": .int(error.code),
                "message": .string(error.message),
            ]).jsonString?.utf8.count ?? 0
            return .failure(error)
        }

        guard let client = decision.client else {
            // Ключ опознан, но вызов ему не разрешён — это всё равно работа
            // по ключу, и на карточке она обязана быть видна.
            // Незарегистрированный и выключенный ключи следов не оставляют:
            // иначе перебор чужих ключей выглядел бы активностью клиента.
            if let known = await access.activeClient(withKey: key) {
                onClientSeen?(known.id)
            }
            let outcome = MCPToolOutcome.failure(decision.refusal ?? "Refused.").result
            record(
                tool: tool, key: key, clientName: decision.clientName, collection: collection,
                arguments: arguments, note: decision.refusal,
                responseBytes: outcome.jsonString?.utf8.count ?? 0, started: started
            )
            return .success(outcome)
        }

        // Ключ узнан и допущен — значит агент по нему работает **сейчас**,
        // чем бы вызов ни кончился дальше.
        onClientSeen?(client.id)

        let limits = MCPOutputLimits.forClient(client.permissions)
        // Вызов записывается в журнал независимо от того, чем он кончится:
        // упавшая запись — то самое событие, ради которого журнал и ведут.
        // И именно как упавшая: «документов: 1» у отказа означало бы, что
        // документ записан, а его нет.
        // Что записать в журнал: причина отказа или итог выполненного вызова.
        // У операции записи он обязателен — без него в журнале стоит «была
        // запись», и восстановить по нему, что стало с базой, нельзя.
        var auditNote: String? = writing.map {
            "documents: \($0.documents.count.plainDigits)"
        }
        defer {
            record(
                tool: tool, key: key, clientName: client.name, collection: collection,
                arguments: arguments, note: auditNote,
                responseBytes: responseBytes, started: started
            )
        }

        do {
            switch tool.name {
            case MCPToolCatalogue.listCollections.name:
                return answered(try await listCollections(client: client, limits: limits).result)
            case MCPToolCatalogue.describeCollection.name:
                return answered(try await describe(collection: collection ?? "", client: client).result)
            case MCPToolCatalogue.search.name:
                switch Self.searchRequest(
                    collection ?? "", arguments, limits: limits,
                    smartSearch: client.permissions.smartSearch
                ) {
                case .failure(let error): return refused(error)
                case .success(let parsed):
                    // Куда ходил вызов — в журнал доступа. Списком
                    // коллекция приезжает мимо параметра «collection», и без
                    // этой строки успешный поиск по трём коллекциям попадал
                    // в журнал вовсе без единого их имени.
                    if parsed.request.isMultiCollection {
                        auditNote = "collections: \(parsed.request.collections.joined(separator: ", "))"
                    }
                    // Права проверяются по **каждой** коллекции списка.
                    // Решение выше видело только параметр «collection», а его
                    // здесь может не быть вовсе — имена агент назвал сам,
                    // и молча выбросить их из поиска нельзя: «нашлось три
                    // документа» вместо «в эту коллекцию нельзя» — это
                    // неверный ответ, а не ограничение.
                    let forbidden = parsed.request.collections.filter {
                        !client.permissions.allows(collection: $0)
                    }
                    guard forbidden.isEmpty else {
                        let outcome = MCPToolOutcome.failure("The key «\(client.name)» has no access to the collections: \(forbidden.joined(separator: ", ")). The available ones are in list_collections.").result
                        auditNote = "refused for collections: \(forbidden.joined(separator: ", "))"
                        return answered(outcome)
                    }
                    return answered(try await search(parsed, limits: limits).result)
                }
            case MCPToolCatalogue.getDocuments.name:
                switch Self.documentsRequest(collection ?? "", arguments, limits: limits) {
                case .failure(let error): return refused(error)
                case .success(let parsed):
                    return answered(try await documents(parsed, limits: limits).result)
                }
            case MCPToolCatalogue.getFile.name:
                switch Self.fileRequest(collection ?? "", arguments, limits: limits) {
                case .failure(let error): return refused(error)
                case .success(let parsed):
                    return answered(try await file(parsed, limits: limits).result)
                }
            case MCPToolCatalogue.collectMentions.name:
                switch Self.mentionsRequest(collection ?? "", arguments, limits: limits) {
                case .failure(let error): return refused(error)
                case .success(let parsed):
                    return answered(try await mentions(parsed, limits: limits).result)
                }
            case MCPToolCatalogue.addDocuments.name:
                guard let writing else {
                    return refused(.invalidParams("No documents passed: the «documents» parameter is required."))
                }
                return answered(try await add(writing).result)
            case MCPToolCatalogue.deleteDocuments.name:
                switch Self.deleteRequest(collection ?? "", arguments) {
                case .failure(let error): return refused(error)
                case .success(let parsed):
                    let (outcome, done) = try await delete(parsed)
                    auditNote = done
                    return answered(outcome.result)
                }
            default:
                return refused(JSONRPCError(
                    code: JSONRPCError.internalError,
                    message: "The tool «\(name)» is declared but not implemented"
                ))
            }
        } catch let failure as MCPToolFailure {
            // Причина уже написана для модели — оборачивать её в «инструмент не
            // отработал» значит отодвинуть от неё то, что она должна прочитать
            // первым.
            auditNote = failure.reason
            return answered(MCPToolOutcome.failure(failure.reason).result)
        } catch {
            // Сбой базы — тоже ошибка выполнения: модель прочитает причину и
            // сможет объяснить её человеку, а протокольная ошибка для неё
            // непрозрачна.
            //
            // Но чужой текст уходит модели только если он на её языке.
            // Ошибки приложения — привязка модели, LM Studio, Foundation —
            // писались человеку у экрана и написаны по-русски; подставленные
            // в английскую обвязку, они дают тот самый смешанный ответ,
            // который сторожат проверки поверхности. Причина при этом не
            // теряется: она остаётся в журнале доступа.
            auditNote = error.localizedDescription
            return answered(MCPToolOutcome.failure(
                Self.englishFailure(tool: name, error: error)
            ).result)
        }
    }

    /// Отказ инструмента по-английски.
    ///
    /// Порядок такой. Ошибка, умеющая говорить с моделью (`MCPReadableError`),
    /// сама называет причину по-английски — это лучший ответ: агент узнаёт,
    /// что LM Studio не запущена или база недоступна, и может сказать это
    /// человеку. Остальные проходят по-английски как есть; русский текст
    /// не проходит вовсе — он писался человеку у экрана, и в английской
    /// обвязке даёт смешанный ответ. Причина при этом не теряется:
    /// подлинный текст уходит в журнал доступа.
    static func englishFailure(tool: String, error: Error) -> String {
        // Отмена — не отказ. Без отдельной ветки она приезжала агенту как
        // «сломалось внутри приложения, спроси хозяина», и агент отправлял
        // человека чинить то, что не ломалось.
        if error is CancellationError {
            return "The call to «\(tool)» was cancelled before it finished."
        }
        let opaque = "The tool «\(tool)» failed inside the application. The reason is in the application log; ask the person who runs it."
        // Правило причины: подставленные значения — в «ёлочках», всё вне их
        // обязано быть английским. Проверяется именно проза: «ёлочки» с их
        // содержимым выбрасываются перед просмотром.
        //
        // Иначе выходит выбор из двух бед. Пропускать всё — и русская фраза
        // из небрежной реализации приезжает в английский ответ. Глушить по
        // первой же кириллице — и причина гибнет от **данных**: имя коллекции
        // «заметки» превращало «collection not found» в «спроси хозяина».
        // Первое агент чинит сам одной попыткой, второе не чинит никак.
        if let readable = error as? MCPReadableError {
            let reason = readable.mcpReason
            guard !reason.isEmpty, Self.prose(of: reason).rangeOfCharacter(from: Self.cyrillic) == nil else {
                return opaque
            }
            return "The tool «\(tool)» failed: \(reason)"
        }
        // Незнакомая ошибка — отговорка почти всегда. `localizedDescription`
        // у Foundation переводится на язык системы, так что на русской машине
        // сюда доходит русский текст и отсеивается. Ветка «английское проходит
        // как есть» живёт для чужих ошибок, которые пишут по-английски сами.
        // Правило про «ёлочки» одно на обе ветки: чужая английская фраза,
        // назвавшая коллекцию по-русски, — такие же данные в кавычках.
        let description = error.localizedDescription
        guard Self.prose(of: description).rangeOfCharacter(from: Self.cyrillic) == nil else { return opaque }
        return "The tool «\(tool)» failed: \(description)"
    }

    /// Причина без подставленных значений — то, что писал человек.
    ///
    /// Всё в «ёлочках» выбрасывается: там имена коллекций, моделей и полей,
    /// и они русские по праву — данные у нас русские. Судить о языке
    /// причины надо по прозе вокруг них.
    static func prose(of reason: String) -> String {
        reason.replacingOccurrences(
            of: "«[^»]*»", with: " ", options: .regularExpression
        )
    }

    /// Множество собирается один раз: отказ — не горячий путь, но и городить
    /// его на каждую ошибку незачем. Открыто для сторожа: пусть проверка
    /// кириллицы и код, который её вычёркивает, считают буквы по одному списку.
    static let cyrillic = CharacterSet(
        charactersIn: "абвгдеёжзийклмнопрстуфхцчшщъыьэюяАБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ"
    )

    private func listCollections(
        client: ExternalClient, limits: MCPOutputLimits
    ) async throws -> MCPToolOutcome {
        let collections = try await backend.collections(allowed: client.permissions.collections)
        // Потолки этого ключа называются прямо здесь, а не только тогда, когда
        // в них упёрлись. Агент выбирает `n_results` в первом же вызове,
        // и до этой правки узнать потолок ему было неоткуда: описание говорило
        // «обычно 10», и агент брал десять при потолке в сто.
        //
        // Потолки приходят готовыми от вызывающего: он их уже посчитал для
        // разбора параметров, и второй расчёт здесь однажды разъедется с
        // первым.
        let limitsLine = """
        Limits of this key: up to \(limits.ceiling) results in one search, \
        up to \(limits.collections) collections in one search, \
        \(limits.documentCharacters) characters per document, \
        \(limits.responseCharacters) per answer. \
        The default of 5 is a look, not a count — choose the number the question needs.
        """
        let structured = JSONValue.object([
            "collections": .array(collections.map(\.json)),
            "limits": .object([
                "maxResultsPerSearch": .int(limits.ceiling),
                "maxCollectionsPerSearch": .int(limits.collections),
                "maxCharactersPerDocument": .int(limits.documentCharacters),
                "maxCharactersPerAnswer": .int(limits.responseCharacters),
            ]),
        ])
        guard !collections.isEmpty else {
            // Не ошибка: ключ может быть заведён без единой коллекции. Но
            // молчаливый пустой список модель истолкует как «база пуста».
            return MCPToolOutcome(
                text: "This key has no collection open to it. Access is configured in ChromaDB Manager, on the «Clients» screen.",
                structured: structured
            )
        }
        let lines = collections.map { collection -> String in
            var parts = ["«\(collection.name)»"]
            if let count = collection.documentCount { parts.append("documents: \(count)") }
            if let model = collection.model { parts.append("model: \(model)") }
            if let metric = collection.metric { parts.append("metric: \(metric)") }
            return parts.joined(separator: ", ")
        }
        return MCPToolOutcome(
            text: (["Collections available:"] + lines + ["", limitsLine]).joined(separator: "\n"),
            structured: structured
        )
    }

    private func describe(collection: String, client: ExternalClient) async throws -> MCPToolOutcome {
        let description = try await backend.describe(collection: collection)
        var lines = ["Collection «\(description.summary.name)»"]
        if let count = description.summary.documentCount { lines.append("documents: \(count)") }
        if let model = description.summary.model { lines.append("model: \(model)") }
        if description.fields.isEmpty {
            lines.append("No metadata fields found — there is nothing to filter on.")
        } else {
            lines.append(description.hasSchema
                ? "Metadata fields (from the collection schema):"
                : "Metadata fields (no schema; listed from what the documents carry):")
            lines += description.fields.map { field in
                var line = "  \(field.key) — \(field.type)"
                if field.isRequired { line += ", required" }
                if !field.examples.isEmpty {
                    line += "; for example: " + field.examples.prefix(3).joined(separator: ", ")
                }
                return line
            }
        }
        return MCPToolOutcome(text: lines.joined(separator: "\n"), structured: description.json)
    }

    // MARK: - Поиск и выборка

    /// Разобранный запрос вместе с тем, что придётся сказать агенту про
    /// урезанную выдачу.
    private struct ParsedSearch {
        let request: MCPSearchRequest
        let limitNote: String?
        /// Проекция метаданных. Забота выдачи, а не базы: в запрос
        /// к ChromaDB она не уходит — предупреждения о плоской таблице и
        /// отпечаток файла читаются из полных метаданных.
        let fields: [String]?
    }

    private struct ParsedDocuments {
        let request: MCPDocumentsRequest
        let limitNote: String?
        let fields: [String]?
    }

    /// Разобранный «собери по теме».
    private struct ParsedMentions {
        let collection: String
        let contains: String
        let filter: DocumentFilter
        /// Сколько **файлов** показать за раз: результат этого инструмента —
        /// файл, а не кусок.
        let files: Int
        let offset: Int
        let perFile: Int
        let fields: [String]?
        let limitNote: String?
    }

    private struct ParsedFile {
        /// Путь, которым назвали файл. Пуст, когда файл спросили отпечатком —
        /// тогда путь узнаётся из найденных документов и возвращается агенту.
        let path: String
        let fingerprint: String?
        let request: MCPDocumentsRequest
        let limitNote: String?
        let fields: [String]?
    }

    /// Имена параметров, которыми агент попытался бы передать вектор.
    private static func vectorParameter(in arguments: JSONValue?) -> String? {
        guard let object = arguments?.objectValue else { return nil }
        let forbidden = ["embedding", "embeddings", "vector", "query_embedding", "query_embeddings"]
        return forbidden.first { object[$0] != nil }
    }

    /// Фильтр по метаданным и по тексту из параметров вызова.
    ///
    /// `where` уезжает в базу как есть, сырым JSON: это тот самый синтаксис,
    /// который модель знает по документации ChromaDB, и переписывать его в свою
    /// форму значило бы терять всё, чего эта форма ещё не умеет.
    private static func filter(_ arguments: JSONValue?) -> Result<DocumentFilter?, JSONRPCError> {
        var filter = DocumentFilter()
        var used = false

        // Условий по метаданным может быть два — своё у агента и наше по типу
        // файла. Складываются они через `$and`, а не затирают друг
        // друга: «таблицы за 2024 год» — это оба условия сразу.
        var whereClauses: [String] = []

        if let raw = arguments?["filter"], raw != .null {
            guard let object = raw.objectValue else {
                return .failure(.invalidParams("The «filter» parameter must be an object: {\"field\": {\"$eq\": value}}."))
            }
            if !object.isEmpty {
                guard let text = raw.jsonString else {
                    return .failure(.invalidParams("The «filter» parameter could not be read as JSON."))
                }
                whereClauses.append(text)
            }
        }

        if let raw = arguments?["file_types"], raw != .null {
            guard let list = raw.arrayValue else {
                return .failure(.invalidParams("The «file_types» parameter must be a list of strings: [\"excel\", \"word\"]."))
            }
            let names = list.compactMap(\.stringValue)
            guard names.count == list.count else {
                return .failure(.invalidParams("The «file_types» parameter must be a list of strings: [\"excel\", \"word\"]."))
            }
            switch DocumentKind.extensions(for: names) {
            case .unknown(let message):
                return .failure(.invalidParams(message))
            case .extensions(let extensions):
                if let clause = DocumentKind.whereClause(extensions: extensions) {
                    whereClauses.append(clause)
                }
            }
        }

        if whereClauses.count == 1 {
            filter.rawWhereJSON = whereClauses[0]
            used = true
        } else if whereClauses.count > 1 {
            filter.rawWhereJSON = "{\"$and\": [\(whereClauses.joined(separator: ", "))]}"
            used = true
        }

        if let contains = arguments?["contains"], contains != .null {
            guard let text = contains.stringValue else {
                return .failure(.invalidParams("The «contains» parameter must be a string."))
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                // `$contains` у ChromaDB различает регистр, а агент об этом не
                // думает и думать не должен: он ищет слово, а не написание.
                // Поэтому спрашиваются варианты написания через `$or` — тот же
                // приём, которым чинился текстовый поиск на экране.
                let variants = TextRelevance.caseVariants(of: [trimmed])
                filter.textConditions = variants.map { DocumentTextCondition(op: .contains, text: $0) }
                filter.textLogic = .or
                used = true
            }
        }

        return .success(used ? filter : nil)
    }

    /// Какие поля метаданных вернуть.
    ///
    /// Пустой список — это не «не возвращать ничего», а «не сказано»: тем же
    /// правилом живёт `contains`, и агенту, приславшему пустой массив,
    /// логичнее получить обычный ответ, чем документы без единого поля.
    static func metadataFields(_ arguments: JSONValue?) -> Result<[String]?, JSONRPCError> {
        guard let raw = arguments?["fields"], raw != .null else { return .success(nil) }
        guard let array = raw.arrayValue else {
            return .failure(.invalidParams("The «fields» parameter must be a list of field names."))
        }
        var names: [String] = []
        for value in array {
            guard let name = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else {
                return .failure(.invalidParams("«fields» must hold non-empty metadata field names."))
            }
            // Повтор поля — не ошибка, но и не повод показывать его дважды.
            if !names.contains(name) { names.append(name) }
        }
        return .success(names.isEmpty ? nil : names)
    }

    /// Та же сборка фильтра, доступная тестам: складывание условий по «и»
    /// проверяется на разборе, а не на живом сервере.
    static func filterForTesting(_ arguments: JSONValue?) -> Result<DocumentFilter?, JSONRPCError> {
        filter(arguments)
    }

    /// Целое из параметров — или отказ, называющий параметр.
    private static func integer(
        _ arguments: JSONValue?, _ name: String
    ) -> Result<Int?, JSONRPCError> {
        guard let value = arguments?[name], value != .null else { return .success(nil) }
        guard let number = value.intValue else {
            return .failure(.invalidParams("The «\(name)» parameter must be an integer."))
        }
        return .success(number)
    }

    /// Две пометки об урезании в одну строку — или ни одной.
    static func joined(_ parts: String?...) -> String? {
        let text = parts.compactMap { $0 }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    /// Коллекции запроса: одна из «collection» или несколько из «collections»
    ///.
    ///
    /// Оба сразу — отказ: угадывать, какое из двух противоречащих указаний
    /// человек имел в виду, приложение не станет.
    static func searchCollections(
        _ collection: String, _ arguments: JSONValue?
    ) -> Result<[String], JSONRPCError> {
        let raw = arguments?["collections"]
        guard let raw, raw != .null else {
            guard !collection.isEmpty else {
                return .failure(.invalidParams("No collection given: pass «collection» or a list in «collections»."))
            }
            return .success([collection])
        }
        guard let array = raw.arrayValue else {
            return .failure(.invalidParams("The «collections» parameter must be a list of collection names."))
        }
        guard collection.isEmpty else {
            return .failure(.invalidParams("Both «collection» and «collections» were passed — keep one of them."))
        }
        var names: [String] = []
        for value in array {
            guard let name = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return .failure(.invalidParams("«collections» must hold non-empty collection names."))
            }
            // Повтор — это не ошибка, а лишний поиск: одна и та же коллекция
            // дважды выдаст одни и те же документы и займёт место потолка.
            if !names.contains(name) { names.append(name) }
        }
        guard !names.isEmpty else {
            return .failure(.invalidParams("The «collections» list is empty: name at least one collection."))
        }
        return .success(names)
    }

    private static func searchRequest(
        _ collection: String, _ arguments: JSONValue?, limits: MCPOutputLimits,
        smartSearch: Bool?
    ) -> Result<ParsedSearch, JSONRPCError> {
        guard let query = arguments?["query"]?.stringValue,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.invalidParams("No query text: the «query» parameter is required and cannot be empty."))
        }

        let names: [String]
        switch searchCollections(collection, arguments) {
        case .failure(let error): return .failure(error)
        case .success(let value): names = value
        }
        let collections = limits.resolvedCollections(names)

        let requested: Int?
        switch integer(arguments, "n_results") {
        case .failure(let error): return .failure(error)
        case .success(let value): requested = value
        }
        let resolved = limits.resolved(requested: requested)

        let fields: [String]?
        switch metadataFields(arguments) {
        case .failure(let error): return .failure(error)
        case .success(let value): fields = value
        }

        switch filter(arguments) {
        case .failure(let error):
            return .failure(error)
        case .success(let filter):
            return .success(ParsedSearch(
                request: MCPSearchRequest(
                    collections: collections.names, query: query,
                    nResults: resolved.count, filter: filter,
                    smartSearch: smartSearch
                ),
                limitNote: Self.joined(collections.note, resolved.note),
                fields: fields
            ))
        }
    }

    private static func documentsRequest(
        _ collection: String, _ arguments: JSONValue?, limits: MCPOutputLimits
    ) -> Result<ParsedDocuments, JSONRPCError> {
        var ids: [String] = []
        if let raw = arguments?["ids"], raw != .null {
            guard let array = raw.arrayValue else {
                return .failure(.invalidParams("The «ids» parameter must be a list of strings."))
            }
            ids = array.compactMap(\.stringValue)
            guard ids.count == array.count else {
                return .failure(.invalidParams("The «ids» parameter must hold only strings — document identifiers."))
            }
        }

        let requested: Int?
        switch integer(arguments, "limit") {
        case .failure(let error): return .failure(error)
        case .success(let value): requested = value
        }
        // Спрошенные по именам документы потолком не режутся сверх того, что
        // спрошено: агент назвал ровно то, что ему нужно.
        let resolved = limits.resolved(requested: ids.isEmpty ? requested : min(ids.count, limits.ceiling))
        var note = resolved.note
        if !ids.isEmpty, ids.count > limits.ceiling {
            note = "Documents asked for: \(ids.count.plainDigits), returned \(limits.ceiling.plainDigits) — the ceiling set by the key rights. The rest come with the next call."
        }

        let offset: Int
        switch integer(arguments, "offset") {
        case .failure(let error): return .failure(error)
        case .success(let value): offset = max(0, value ?? 0)
        }

        let fields: [String]?
        switch metadataFields(arguments) {
        case .failure(let error): return .failure(error)
        case .success(let value): fields = value
        }

        switch filter(arguments) {
        case .failure(let error):
            return .failure(error)
        case .success(let filter):
            return .success(ParsedDocuments(
                request: MCPDocumentsRequest(
                    collection: collection,
                    ids: Array(ids.prefix(limits.ceiling)),
                    filter: filter,
                    limit: resolved.count,
                    offset: ids.isEmpty ? offset : 0
                ),
                limitNote: note,
                fields: fields
            ))
        }
    }

    /// Сколько совпадений приложение готово собрать за один вызов.
    ///
    /// Двадцать тысяч — столько же, сколько у `get_file`, и по той же
    /// причине: охват требует **всех** совпадений, а не первых попавшихся.
    /// Замер: обход коллекции в 5765 кусков стоит около полутора секунд
    /// независимо от того, сколько кусков подошло, — цена в самом обходе.
    static let mentionsScanLimit = 20_000

    /// Больше трёх образцов с файла не отдаётся: задача — сравнить
    /// формулировки между документами, а не вычитать один документ.
    static let mentionsMaximumPerFile = 3

    private static func mentionsRequest(
        _ collection: String, _ arguments: JSONValue?, limits: MCPOutputLimits
    ) -> Result<ParsedMentions, JSONRPCError> {
        // Тип и отсутствие — разные беды, и путать их в сообщении нельзя:
        // «не сказано, что искать» в ответ на число сбивает с толку сильнее,
        // чем молчание.
        let missingWord = JSONRPCError.invalidParams(
            "Nothing to look for: the «contains» parameter is required. Give the word as a stem without the ending — «приемк»."
        )
        guard let raw = arguments?["contains"], raw != .null else { return .failure(missingWord) }
        guard let text = raw.stringValue else {
            return .failure(.invalidParams("The «contains» parameter must be a string."))
        }
        let contains = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contains.isEmpty else { return .failure(missingWord) }

        let requested: Int?
        switch integer(arguments, "limit") {
        case .failure(let error): return .failure(error)
        case .success(let value): requested = value
        }
        let resolved = limits.resolved(requested: requested)

        let offset: Int
        switch integer(arguments, "offset") {
        case .failure(let error): return .failure(error)
        case .success(let value): offset = max(0, value ?? 0)
        }

        // Урезание называется вслух (правило 3 приложения 5): иначе агент
        // попросил девять образцов, получил три и решил, что больше в файле
        // ничего нет.
        var perFile = 1
        var perFileNote: String?
        switch integer(arguments, "per_file") {
        case .failure(let error): return .failure(error)
        case .success(let value):
            let asked = max(1, value ?? 1)
            perFile = min(mentionsMaximumPerFile, asked)
            if asked > perFile {
                perFileNote = "Samples per file asked for: \(asked.plainDigits), returned \(perFile.plainDigits) — the limit of this tool. For every match in one file use get_file or get_documents with contains."
            }
        }

        let fields: [String]?
        switch metadataFields(arguments) {
        case .failure(let error): return .failure(error)
        case .success(let value): fields = value
        }

        // Условие собирается тем же кодом, что и у остальных инструментов:
        // вторая сборка «того же самого» — это второй набор ошибок.
        switch filter(arguments) {
        case .failure(let error): return .failure(error)
        case .success(let base):
            // Условие по тексту уже собрано общим кодом: «contains» здесь
            // обязателен, поэтому фильтр не может оказаться пустым.
            let filter = base ?? DocumentFilter()
            return .success(ParsedMentions(
                collection: collection, contains: contains, filter: filter,
                files: resolved.count, offset: offset, perFile: perFile,
                fields: fields, limitNote: Self.joined(resolved.note, perFileNote)
            ))
        }
    }

    /// Разбор `get_file`.
    ///
    /// Фильтр строится здесь, а не отдаётся на откуп агенту: «файл целиком»
    /// означает ровно одно условие — `source_file` равно названному пути, —
    /// и позволить дописать к нему что-то ещё значит вернуть половину файла
    /// под видом целого.
    private static func fileRequest(
        _ collection: String, _ arguments: JSONValue?, limits: MCPOutputLimits
    ) -> Result<ParsedFile, JSONRPCError> {
        func argument(_ name: String) -> String? {
            let value = arguments?[name]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty ?? true) ? nil : value
        }
        // Отпечаток предпочтительнее пути, поэтому спрашивается первым.
        let fingerprint = argument("file_id")
        let path = argument("file")
        guard fingerprint != nil || path != nil else {
            return .failure(.invalidParams("Name the file: «file_id» — the fingerprint from the metadata of a document you found, or «file» — the source_file value, the path relative to the source folder."))
        }

        let requested: Int?
        switch integer(arguments, "limit") {
        case .failure(let error): return .failure(error)
        case .success(let value): requested = value
        }
        let resolved = limits.resolved(requested: requested)

        let offset: Int
        switch integer(arguments, "offset") {
        case .failure(let error): return .failure(error)
        case .success(let value): offset = max(0, value ?? 0)
        }

        let fields: [String]?
        switch metadataFields(arguments) {
        case .failure(let error): return .failure(error)
        case .success(let value): fields = value
        }

        return .success(ParsedFile(
            path: path ?? "",
            fingerprint: fingerprint,
            request: MCPDocumentsRequest(
                collection: collection, ids: [],
                filter: fingerprint.map { fingerprintFilter($0) } ?? fileFilter(path ?? ""),
                limit: resolved.count, offset: offset, orderedByChunkIndex: true
            ),
            limitNote: resolved.note,
            fields: fields
        ))
    }

    /// Условие «этот и только этот файл».
    static func fileFilter(_ path: String) -> DocumentFilter {
        var filter = DocumentFilter()
        filter.conditions = [MetadataCondition(field: "source_file", op: .equals, value: path)]
        return filter
    }

    /// То же, но по отпечатку файла.
    static func fingerprintFilter(_ fingerprint: String) -> DocumentFilter {
        var filter = DocumentFilter()
        filter.conditions = [MetadataCondition(field: "file_id", op: .equals, value: fingerprint)]
        return filter
    }

    /// Метаданные из параметров вызова.
    ///
    /// Плоские: ChromaDB вложенных объектов и списков не принимает вовсе, и
    /// сказать об этом на разборе куда полезнее, чем дать базе ответить
    /// четырёхсотым по неизвестной модели причине.
    private static func metadata(
        _ value: JSONValue?, documentNumber: Int
    ) -> Result<ChromaMetadata?, JSONRPCError> {
        guard let value, value != .null else { return .success(nil) }
        guard let object = value.objectValue else {
            return .failure(.invalidParams("Document \(documentNumber.plainDigits): «metadata» must be an object."))
        }
        var result: ChromaMetadata = [:]
        for (key, item) in object {
            switch item {
            case .string(let text): result[key] = .string(text)
            case .int(let number): result[key] = .int(number)
            case .double(let number): result[key] = .double(number)
            case .bool(let flag): result[key] = .bool(flag)
            case .null: continue
            case .array, .object:
                return .failure(.invalidParams(
                    "Document \(documentNumber.plainDigits), field «\(key)»: ChromaDB metadata is flat — nested objects and lists are not accepted. Fold the value into a string or spread it over separate fields."
                ))
            }
        }
        return .success(result.isEmpty ? nil : result)
    }

    private static func addRequest(
        _ collection: String, _ arguments: JSONValue?
    ) -> Result<MCPAddRequest, JSONRPCError> {
        guard let raw = arguments?["documents"], raw != .null else {
            return .failure(.invalidParams("No documents passed: the «documents» parameter is required."))
        }
        guard let array = raw.arrayValue else {
            return .failure(.invalidParams("The «documents» parameter must be a list of objects."))
        }
        guard !array.isEmpty else {
            return .failure(.invalidParams("The «documents» list is empty — there is nothing to write."))
        }

        var documents: [MCPIncomingDocument] = []
        for (index, item) in array.enumerated() {
            let number = index + 1
            guard item.objectValue != nil else {
                return .failure(.invalidParams("Document \(number.plainDigits) must be an object with a «text» field."))
            }
            guard let text = item["text"]?.stringValue,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(.invalidParams("Document \(number.plainDigits): the «text» field is required and cannot be empty."))
            }
            let id = item["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            switch metadata(item["metadata"], documentNumber: number) {
            case .failure(let error): return .failure(error)
            case .success(let metadata):
                documents.append(MCPIncomingDocument(
                    id: (id?.isEmpty ?? true) ? nil : id, text: text, metadata: metadata
                ))
            }
        }

        // Повтор внутри одного вызова база примет молча, оставив первый
        // документ: агент решит, что записаны оба.
        let named = documents.compactMap(\.id)
        if Set(named).count != named.count {
            return .failure(.invalidParams("Identifiers repeat within one call — the database would keep only the first document."))
        }

        return .success(MCPAddRequest(collection: collection, documents: documents))
    }

    private func add(_ request: MCPAddRequest) async throws -> MCPToolOutcome {
        let answer = try await backend.add(request)
        var structured: [String: JSONValue] = [
            "collection": .string(request.collection),
            "ids": .array(answer.ids.map(JSONValue.string)),
        ]
        if let model = answer.model { structured["model"] = .string(model) }
        if let note = answer.note { structured["notes"] = .array([.string(note)]) }

        var lines = ["Written to «\(request.collection)»: \(EnglishCount.grouped(answer.ids.count, "document", "documents"))."]
        if let model = answer.model {
            lines.append("Vectors computed with the model \(model).")
        }
        lines.append("Identifiers: \(answer.ids.joined(separator: ", "))")
        if let note = answer.note { lines.append(note) }
        return MCPToolOutcome(text: lines.joined(separator: "\n"), structured: .object(structured))
    }

    private static func deleteRequest(
        _ collection: String, _ arguments: JSONValue?
    ) -> Result<MCPDeleteRequest, JSONRPCError> {
        guard let raw = arguments?["ids"], raw != .null else {
            return .failure(.invalidParams("No identifiers passed: the «ids» parameter is required. There is no delete by filter — first find the documents with get_documents."))
        }
        guard let array = raw.arrayValue else {
            return .failure(.invalidParams("The «ids» parameter must be a list of strings."))
        }
        let ids = array.compactMap(\.stringValue)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard ids.count == array.count else {
            return .failure(.invalidParams("The «ids» parameter must hold only non-empty strings — document identifiers."))
        }
        guard !ids.isEmpty else {
            return .failure(.invalidParams("The «ids» list is empty — there is nothing to delete."))
        }
        // Фильтр отвергается вслух: агент, чей фильтр молча выбросили, решил
        // бы, что удалилось ровно то, что он описал.
        if arguments?["filter"] != nil || arguments?["contains"] != nil
            || arguments?["file_types"] != nil {
            return .failure(.invalidParams("Delete by filter is not provided: list the identifiers in «ids». They can be found with get_documents using that same filter."))
        }
        return .success(MCPDeleteRequest(collection: collection, ids: ids))
    }

    /// Возвращает ответ агенту и строку для журнала: что именно удалено.
    ///
    /// Итог операции удаления в журнале обязателен. «Была попытка удаления»
    /// без результата не отвечает на единственный вопрос, который к журналу
    /// приходят с ним задавать, — что стало с базой.
    private func delete(
        _ request: MCPDeleteRequest
    ) async throws -> (outcome: MCPToolOutcome, auditNote: String) {
        let answer = try await backend.delete(request)
        var structured: [String: JSONValue] = [
            "collection": .string(request.collection),
            "deleted": .array(answer.deleted.map(JSONValue.string)),
            "keptInTrash": .bool(answer.keptInTrash),
        ]
        if !answer.missing.isEmpty {
            structured["missing"] = .array(answer.missing.map(JSONValue.string))
        }

        var lines: [String] = []
        if answer.deleted.isEmpty {
            lines.append("Nothing was deleted from «\(request.collection)»: none of the given identifiers was found.")
        } else {
            lines.append("Deleted from «\(request.collection)»: \(EnglishCount.grouped(answer.deleted.count, "document", "documents")).")
            lines.append("Identifiers: \(answer.deleted.joined(separator: ", "))")
        }
        if !answer.missing.isEmpty {
            // Перечислением, а не числом: «удалено 2 из 5» оставляет агента
            // гадать, какие три, и он повторит вызов целиком.
            lines.append("Not found and therefore not deleted: \(answer.missing.joined(separator: ", "))")
        }
        if !answer.deleted.isEmpty {
            lines.append(answer.keptInTrash
                ? "Copies are kept in the ChromaDB Manager trash — the owner of the base can restore them."
                : "The trash is off in ChromaDB Manager: the deletion is final and nothing can bring the documents back.")
        }

        var note = answer.deleted.isEmpty
            ? "nothing deleted"
            : "deleted: \(answer.deleted.joined(separator: ", "))"
        if !answer.deleted.isEmpty, !answer.keptInTrash {
            note += " (trash off — no copies)"
        }
        return (
            MCPToolOutcome(text: lines.joined(separator: "\n"), structured: .object(structured)),
            note
        )
    }

    private func search(_ parsed: ParsedSearch, limits: MCPOutputLimits) async throws -> MCPToolOutcome {
        let answer = try await backend.search(parsed.request)
        let rendered = MCPDocumentRendering.render(
            answer.documents, limits: limits, metric: answer.metric, fields: parsed.fields
        )

        var structured: [String: JSONValue] = [
            "query": .string(parsed.request.query),
            "documents": .array(rendered.documents),
        ]
        // Поиск шёл по нескольким — сказать, по каким именно: агент
        // обязан знать, где искали, а не только что нашлось.
        //
        // И **вместо** «collection», а не рядом с ним: одно имя на выдачу
        // из трёх коллекций — это неверный ответ, по которому агент пойдёт
        // дочитывать документ не туда. У каждого результата коллекция своя,
        // она стоит в самом результате. Схема поля и не требует.
        if parsed.request.isMultiCollection {
            structured["collections"] = .array(parsed.request.collections.map(JSONValue.string))
        } else {
            structured["collection"] = .string(parsed.request.collection)
        }
        if let metric = answer.metric { structured["metric"] = .string(metric) }
        if let model = answer.model { structured["model"] = .string(model) }
        if rendered.isTruncated { structured["truncated"] = .bool(true) }

        var notes = rendered.notes
        if let limitNote = parsed.limitNote { notes.insert(limitNote, at: 0) }
        if let note = answer.note { notes.append(note) }
        if !notes.isEmpty { structured["notes"] = .array(notes.map(JSONValue.string)) }

        guard !answer.documents.isEmpty else {
            // Пустая выдача — не ошибка, но и не молчание: чаще всего виноват
            // фильтр, и агент должен знать, куда смотреть.
            var lines = [
                parsed.request.isMultiCollection
                    ? "Nothing was found for «\(parsed.request.query)» in the collections: \(parsed.request.collections.joined(separator: ", "))."
                    : "Nothing was found for «\(parsed.request.query)» in the collection «\(parsed.request.collection)».",
            ]
            if parsed.request.filter != nil {
                lines.append("The query carried a filter — check the field names and value types with describe_collection, and try again without it.")
            }
            lines += notes
            return MCPToolOutcome(text: lines.joined(separator: "\n"), structured: .object(structured))
        }

        var header = parsed.request.isMultiCollection
            ? "Found in collections \(parsed.request.collections.joined(separator: ", ")): \(EnglishCount.grouped(rendered.shown, "document", "documents"))"
            : "Found in «\(parsed.request.collection)»: \(EnglishCount.grouped(rendered.shown, "document", "documents"))"
        if let model = answer.model { header += ", model \(model)" }
        let text = ([header] + rendered.lines + notes).joined(separator: "\n")
        return MCPToolOutcome(text: text, structured: .object(structured))
    }

    private func documents(_ parsed: ParsedDocuments, limits: MCPOutputLimits) async throws -> MCPToolOutcome {
        let answer = try await backend.documents(parsed.request)
        let rendered = MCPDocumentRendering.render(
            answer.documents, limits: limits, fields: parsed.fields
        )

        var structured: [String: JSONValue] = [
            "collection": .string(parsed.request.collection),
            "documents": .array(rendered.documents),
            "hasMore": .bool(answer.hasMore || rendered.isTruncated),
        ]

        var notes = rendered.notes
        if let limitNote = parsed.limitNote { notes.insert(limitNote, at: 0) }
        if answer.hasMore, parsed.request.ids.isEmpty {
            notes.append("There are more documents beyond this page: repeat the call with offset \((parsed.request.offset + rendered.shown).plainDigits).")
        }
        if !notes.isEmpty { structured["notes"] = .array(notes.map(JSONValue.string)) }

        guard !answer.documents.isEmpty else {
            var lines = ["The collection «\(parsed.request.collection)» has no documents for this request."]
            if !parsed.request.ids.isEmpty {
                lines.append("None of the given identifiers was found — check how they are spelled.")
            }
            lines += notes
            return MCPToolOutcome(text: lines.joined(separator: "\n"), structured: .object(structured))
        }

        let header = "From the collection «\(parsed.request.collection)»: \(EnglishCount.grouped(rendered.shown, "document", "documents"))"
        let text = ([header] + rendered.lines + notes).joined(separator: "\n")
        return MCPToolOutcome(text: text, structured: .object(structured))
    }

    /// Один файл в ответе «собери по теме».
    ///
    /// Числа совпадений отдельным полем нет: это `samples.count`, и счётчик,
    /// который живёт рядом со списком, рано или поздно с ним разойдётся.
    private struct MentionedFile {
        let path: String
        let fileID: String?
        let samples: [MCPDocumentPayload]

        var hits: Int { samples.count }
    }

    /// Ключ группировки — путь файла.
    ///
    /// Куски без пути собираются в одну кучу, а не растворяются поодиночке:
    /// «файл не назван — 12 совпадений» это ответ, а дюжина безымянных строк
    /// в списке файлов — нет.
    private static func filePathKey(of document: MCPDocumentPayload) -> String {
        if case .string(let path)? = document.metadata?["source_file"], !path.isEmpty { return path }
        return "(no file named)"
    }

    /// Файл перечня в том виде, в каком он уедет в `structuredContent`.
    ///
    /// Собирается один раз и в одном месте: и для оплаты бюджетом, и для самого
    /// ответа. Две сборки разошлись бы, и бюджет считал бы не то, что уходит.
    private static func mentionedFileMirror(_ file: MentionedFile) -> JSONValue {
        var object: [String: JSONValue] = [
            "file": .string(file.path),
            "hits": .int(file.hits),
        ]
        if let fileID = file.fileID, !fileID.isEmpty { object["fileId"] = .string(fileID) }
        return .object(object)
    }

    /// «Собери по теме».
    ///
    /// Один обход коллекции вместо двадцати: замер показал, что обход по
    /// текстовому условию стоит около секунды **независимо** от того, сколько
    /// кусков подошло, и агент, листавший то же самое страницами по сто,
    /// платил эту секунду за каждую страницу.
    private func mentions(_ parsed: ParsedMentions, limits: MCPOutputLimits) async throws -> MCPToolOutcome {
        let answer = try await backend.documents(MCPDocumentsRequest(
            collection: parsed.collection, ids: [], filter: parsed.filter,
            limit: Self.mentionsScanLimit, offset: 0
        ))

        // Сначала частые файлы: «где этого больше всего» — обычный первый
        // вопрос. Порядок при равном числе совпадений закреплён путём, иначе
        // страницы поедут друг относительно друга.
        let grouped: [String: [MCPDocumentPayload]] = Dictionary(
            grouping: answer.documents, by: Self.filePathKey
        )
        let mentioned: [MentionedFile] = grouped.map { path, documents in
            MentionedFile(
                path: path,
                fileID: Self.storedFingerprint(of: documents),
                samples: documents
            )
        }
        let files: [MentionedFile] = mentioned.sorted { left, right in
            left.hits == right.hits ? left.path < right.path : left.hits > right.hits
        }

        var notes: [String] = []
        if let limitNote = parsed.limitNote { notes.append(limitNote) }
        // Предел сбора определяется по ответу базы, а не по одному лишь счёту:
        // «ровно двадцать тысяч» и «двадцать тысяч и ещё сколько-то» иначе
        // неотличимы.
        if answer.hasMore || answer.documents.count >= Self.mentionsScanLimit {
            notes.append("There are more matches than the application collects at once (\(Self.mentionsScanLimit.plainDigits)): the coverage is counted over what was collected. Narrow it with a filter or take a rarer word.")
        }

        var structured: [String: JSONValue] = [
            "collection": .string(parsed.collection),
            "contains": .string(parsed.contains),
            "totalMatches": .int(answer.documents.count),
            "totalFiles": .int(files.count),
        ]

        func answered(_ lines: [String]) -> MCPToolOutcome {
            if !notes.isEmpty { structured["notes"] = .array(notes.map(JSONValue.string)) }
            return MCPToolOutcome(
                text: (lines + notes).joined(separator: "\n"), structured: .object(structured)
            )
        }

        guard !files.isEmpty else {
            structured["files"] = .array([])
            structured["documents"] = .array([])
            structured["hasMore"] = .bool(false)
            return answered([
                "The word «\(parsed.contains)» is in no document of the collection «\(parsed.collection)».",
                "The comparison is literal: try the stem without the ending, or another spelling. Synonyms are the job of search, not of this tool.",
            ])
        }

        let page = Array(files.dropFirst(parsed.offset).prefix(parsed.files))
        guard !page.isEmpty else {
            structured["files"] = .array([])
            structured["documents"] = .array([])
            structured["hasMore"] = .bool(false)
            return answered(["Files holding «\(parsed.contains)»: \(files.count.plainDigits), and offset \(parsed.offset.plainDigits) is already past the end of the list."])
        }

        // Перечень файлов и образцы делят один бюджет. Раньше перечень в него
        // не входил вовсе: сотня длинных путей — это двадцать пять тысяч
        // знаков, и ответ выходил за «Символов в ответе» молча.
        let listingBudget = max(1, limits.responseCharacters / 2)
        var listing: [String] = []
        var listingFiles: [JSONValue] = []
        var listingSize = 0
        var shown: [MentionedFile] = []
        for (index, file) in page.enumerated() {
            let line = "\((parsed.offset + index + 1).plainDigits). \(file.path) — \(EnglishCount.grouped(file.hits, "match", "matches"))"
            // Перечень уезжает дважды — строкой и зеркалом в `structuredContent`,
            // — и платить обязан за оба. Зеркало здесь не оплачивалось вовсе:
            // на двадцати файлах это незаметно, на семидесяти живой ответ вышел
            // на 30 174 символа при обещанных 24 000.
            let mirror = Self.mentionedFileMirror(file)
            let cost = line.count + 1 + mirror.deliveredSize
            // Первый файл показывается всегда, как и первый документ в выдаче:
            // ответ без единого файла хуже ответа с одним.
            if index > 0, listingSize + cost > listingBudget { break }
            listing.append(line)
            listingFiles.append(mirror)
            listingSize += cost
            shown.append(file)
        }
        if shown.count < page.count {
            // «Из скольких» — это сколько **подошло**, а не сколько попросили:
            // при `limit: 100` и семидесяти подошедших ответ говорил «45 из 70
            // запрошенных», и агент читал это как «мой предел урезали до 70».
            notes.append("The list was trimmed by answer size: \(shown.count.plainDigits) of the \(page.count.plainDigits) matching files are shown.")
        }

        let samples = shown.flatMap { file in
            MCPFileChunks.ordered(file.samples).prefix(parsed.perFile)
        }
        let rendered = MCPDocumentRendering.render(
            samples, limits: limits, fields: parsed.fields,
            budget: max(1, limits.responseCharacters - listingSize)
        )
        notes += rendered.notes

        let hasMore = parsed.offset + shown.count < files.count
        if hasMore {
            notes.append("Files \((parsed.offset + 1).plainDigits) to \((parsed.offset + shown.count).plainDigits) of \(files.count.plainDigits) are shown — continue with offset \((parsed.offset + shown.count).plainDigits).")
        }

        // Ровно те зеркала, что уже оплачены выше: собирать их второй раз
        // значило бы разойтись с бюджетом при первой же правке.
        structured["files"] = .array(listingFiles)
        structured["documents"] = .array(rendered.documents)
        structured["hasMore"] = .bool(hasMore)

        let header = "«\(parsed.contains)»: \(EnglishCount.grouped(answer.documents.count, "match", "matches")) in \(EnglishCount.grouped(files.count, "file", "files")), \(shown.count.plainDigits) shown"
        return answered([header] + listing + [""] + rendered.lines)
    }

    /// `get_file` — чанки одного файла по порядку.
    private func file(_ parsed: ParsedFile, limits: MCPOutputLimits) async throws -> MCPToolOutcome {
        let found = try await fileChunks(parsed)
        let answer = found.answer
        // Файл, спрошенный отпечатком, называется в ответе путём: агент
        // покажет человеку документ, а не шестнадцать знаков.
        let path = found.path.isEmpty ? Self.storedPath(of: answer.documents) : found.path
        let fingerprint = parsed.fingerprint ?? Self.storedFingerprint(of: answer.documents)
        let rendered = MCPDocumentRendering.render(
            answer.documents, limits: limits, fields: parsed.fields
        )
        // Показано меньше, чем отдала база (сработал потолок объёма ответа), —
        // значит следующая страница начинается там, где оборвался показ,
        // а не там, где кончилась выборка. Иначе агент потеряет чанки
        // в середине файла и не заметит этого.
        let next = parsed.request.offset + rendered.shown
        let more = answer.hasMore || rendered.isTruncated

        var structured: [String: JSONValue] = [
            "collection": .string(parsed.request.collection),
            // Путь, под которым файл лежит в базе, а не тот, которым его
            // спросили: они различаются формой записи, и следующая страница
            // должна запрашиваться тем, что сработало.
            "file": .string(path),
            "documents": .array(rendered.documents),
            "hasMore": .bool(more),
            "offset": .int(parsed.request.offset),
        ]
        // Отпечаток отдаётся и тогда, когда спрашивали путём: следующая
        // страница обойдётся без пути вовсе.
        if let fingerprint { structured["fileId"] = .string(fingerprint) }
        if let total = answer.total { structured["total"] = .int(total) }
        if more { structured["nextOffset"] = .int(next) }

        var notes = rendered.notes
        if let limitNote = parsed.limitNote { notes.insert(limitNote, at: 0) }
        if answer.orderUnavailable {
            notes.append("The file holds more than \(MCPFileChunks.maximumOrdered.plainDigits) chunks — the application does not return that many in an arbitrary order; assemble them by the chunk_index field.")
        }
        if more {
            notes.append("The file was not read whole: continue with offset \(next.plainDigits).")
        }
        if !notes.isEmpty { structured["notes"] = .array(notes.map(JSONValue.string)) }

        guard !answer.documents.isEmpty else {
            guard parsed.fingerprint == nil else {
                // Отпечаток испортить нечем, поэтому промах по нему значит
                // одно из двух: коллекция не та или файла в ней нет.
                // Отдельная беда — коллекции прежних сборок, где поля file_id
                // ещё нет; о ней говорится прямо, иначе агент будет повторять
                // тот же вызов.
                let lines = [
                    "The collection «\(parsed.request.collection)» has no chunks with file_id «\(parsed.fingerprint ?? "")».",
                    "If the collection was filled by earlier builds it has no file_id field yet — call get_file with the «file» parameter, taking the path from the source_file field of a document you found.",
                ] + notes
                return MCPToolOutcome(text: lines.joined(separator: "\n"), structured: .object(structured))
            }
            var lines = ["The collection «\(parsed.request.collection)» has no documents of the file «\(parsed.path)»."]
            // Что делать дальше, а не только чем ошибся: файл с этим именем
            // почти всегда в коллекции есть — агент потерял верхние папки
            // пути. Живой случай: спросили «000001/Документ/…», а лежит
            // «Ведомство Б/ЦОД/000001/Документ/…», и агент бросил читать.
            let similar = await similarFiles(to: parsed.path, in: parsed.request.collection)
            if similar.isEmpty {
                lines.append("Take the path from the source_file field of a document you found, whole — not the file name and not an absolute path.")
            } else {
                lines.append("A file with that name is in the collection — its whole path differs. Call get_file with one of these:")
                lines += similar.map { "• \($0)" }
                structured["similarFiles"] = .array(similar.map(JSONValue.string))
            }
            lines += notes
            return MCPToolOutcome(text: lines.joined(separator: "\n"), structured: .object(structured))
        }

        var header = "File «\(path)»: \(EnglishCount.grouped(rendered.shown, "chunk", "chunks")) starting at \(parsed.request.offset.plainDigits)"
        if let total = answer.total { header += ", \(total.plainDigits) in total" }
        let text = ([header] + rendered.lines + notes).joined(separator: "\n")
        return MCPToolOutcome(text: text, structured: .object(structured))
    }

    /// Чанки файла — в любой форме записи пути.
    ///
    /// Один и тот же путь Unicode позволяет записать по-разному, и файловая
    /// система выбирает не ту форму, в которой путь перепечатает агент.
    /// Для базы это разные строки, поэтому спрашиваем по очереди, пока файл
    /// не найдётся. Обычно хватает первой попытки: лишние запросы уходят
    /// только там, где файл иначе не нашёлся бы вовсе.
    private func fileChunks(_ parsed: ParsedFile) async throws -> (answer: MCPDocumentsAnswer, path: String) {
        let first = try await backend.documents(parsed.request)
        // По отпечатку перебирать нечего: он один и тот же в любой записи.
        guard first.documents.isEmpty, parsed.fingerprint == nil else { return (first, parsed.path) }

        for variant in FilePathKey.variants(parsed.path).dropFirst() {
            let retry = MCPDocumentsRequest(
                collection: parsed.request.collection,
                ids: [],
                filter: Self.fileFilter(variant),
                limit: parsed.request.limit,
                offset: parsed.request.offset,
                orderedByChunkIndex: parsed.request.orderedByChunkIndex
            )
            let answer = try await backend.documents(retry)
            if !answer.documents.isEmpty { return (answer, variant) }
        }
        return (first, parsed.path)
    }

    /// Пути файлов с тем же именем — подсказка на промах.
    ///
    /// По `file_name`, а не перебором коллекции: имя файла лежит в метаданных
    /// отдельным полем, и один запрос по нему стоит дешевле обхода базы.
    /// Ошибки здесь молчат намеренно: подсказка не обязана быть, а ответ
    /// «нет документов» должен дойти в любом случае.
    private func similarFiles(to path: String, in collection: String, limit: Int = 3) async -> [String] {
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty else { return [] }

        for variant in FilePathKey.variants(name) {
            var filter = DocumentFilter()
            filter.conditions = [MetadataCondition(field: "file_name", op: .equals, value: variant)]
            let request = MCPDocumentsRequest(
                collection: collection, ids: [], filter: filter,
                limit: Self.similarFilesScan, offset: 0
            )
            guard let answer = try? await backend.documents(request) else { continue }

            var paths: [String] = []
            for document in answer.documents {
                guard case .string(let file)? = document.metadata?["source_file"] else { continue }
                guard !paths.contains(where: { FilePathKey.matches($0, file) }) else { continue }
                paths.append(file)
                if paths.count == limit { return paths }
            }
            if !paths.isEmpty { return paths }
        }
        return []
    }

    /// Путь файла, как он записан у его чанков.
    private static func storedPath(of documents: [MCPDocumentPayload]) -> String {
        for document in documents {
            if case .string(let path)? = document.metadata?["source_file"], !path.isEmpty { return path }
        }
        return ""
    }

    /// Отпечаток файла, как он записан у его чанков. `nil` у коллекций
    /// прежних сборок: поля там ещё нет, и выдумывать его нельзя — агент
    /// позвал бы с ним и получил пустоту.
    private static func storedFingerprint(of documents: [MCPDocumentPayload]) -> String? {
        for document in documents {
            if case .string(let value)? = document.metadata?["file_id"], !value.isEmpty { return value }
        }
        return nil
    }

    /// Сколько чанков просматривается ради подсказки.
    ///
    /// Чанки одного файла идут подряд, поэтому три разных пути в выдаче по
    /// одному имени — это уже три разных файла, а не три куска одного.
    private static let similarFilesScan = 60
}
