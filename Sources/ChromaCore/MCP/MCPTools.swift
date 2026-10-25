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
    /// Тексты не нужны — нужны только метаданные.
    ///
    /// Оглавление строится по `heading_path` и `chunk_index`, а сами тексты
    /// в нём не участвуют вовсе. Без этого карта файла на тысячу кусков
    /// тянула из базы весь его текст — мегабайты ради того, чтобы их
    /// выбросить, и ровно та цена, от которой оглавление и спасает.
    public let needsText: Bool

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
        orderedByChunkIndex: Bool = false,
        needsText: Bool = true
    ) {
        self.collection = collection
        self.ids = ids
        self.filter = filter
        self.limit = limit
        self.offset = offset
        self.orderedByChunkIndex = orderedByChunkIndex
        self.needsText = needsText
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

/// Где документ лежит на диске — и сколько он весит там.
///
/// Агент работает на той же машине, что и приложение: путь к файлу — это
/// самый дешёвый способ отдать ему документ целиком. Ноль вызовов на чтение,
/// ноль знаков в контексте, и текст берётся из первоисточника, а не
/// собирается обратно из кусков.
public struct MCPFileOnDisk: Sendable, Hashable {
    public let path: String
    public let bytes: Int?

    public init(path: String, bytes: Int?) {
        self.path = path
        self.bytes = bytes
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

    /// Где лежит исходный файл этого куска, если он есть и доступен.
    ///
    /// `nil` — документ пришёл не из файла (записан агентом, взят из веба)
    /// или файла на месте больше нет. Подложки, которым это неизвестно,
    /// молчат: умолчание ниже.
    func fileOnDisk(metadata: ChromaMetadata?) async -> MCPFileOnDisk?
}

public extension MCPToolBackend {
    func fileOnDisk(metadata: ChromaMetadata?) async -> MCPFileOnDisk? { nil }
}

/// Реестр инструментов этапа 7.
public enum MCPToolCatalogue {
    /// Предел глубины карты — и в схеме, и при разборе.
    ///
    /// Глубже некуда: у самого вложенного заголовка живого ТЗ пять уровней,
    /// и сотня — с запасом на любой мыслимый документ. Число нужно не ради
    /// обозримости (её держит умолчание), а ради того, чтобы сложение
    /// с глубиной раздела не переполнилось: `Int.max` вместе с «heading»
    /// роняет приложение целиком.
    public static let outlineMaximumDepth = 100

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
        list of conditions. There is no substring operator here — «$regex» is \
        refused and «$contains» matches nothing at all on metadata; use the \
        «contains» parameter, which searches the text of documents. Take field \
        names and their types from describe_collection: comparing against the \
        number 2024 and against the string «2024» are different conditions, and \
        the second returns nothing.
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
        .xlsm, .ods, .numbers, .csv, .tsv; pdf; presentation — .pptx, .key; \
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
        literally. This is the way to find codes, numbers, article and contract \
        numbers and abbreviations: search by meaning alone often misses them.
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
        **Search inside one file** by filtering on it: `{"file_id": {"$eq": "…"}}` \
        with the fingerprint from any of its chunks. On a document of a thousand \
        chunks this is the way to find what a question is about — reading it \
        whole is not possible. \
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
                    work worse — the search is by meaning. A code, a number or an abbreviation \
                    («001», «1-100/24», «S3») the meaning barely carries: put it into \
                    «contains» as well, and keep the query a phrase.
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
        Returns one file: as continuous text, as a map of its sections, or as \
        its chunks **in order** — the order the file was cut into. \
        **To get a whole document**, ask with «as»: "text" and page it with the \
        «offset» the answer gives you; every answer also carries «sourcePath», \
        the document's place on this machine's disk — if you can read files \
        there, that is the whole document in one step and costs nothing. \
        To work with a large document without reading it whole, ask for \
        «outline» first and then the section you need by «heading». \
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
                    "description": .string("How many chunks to return at once. Unset, a page of text fills the answer budget and a page of chunks holds 5; the ceiling belongs to the key. Ignored with «outline», where chunks are not counted at all."),
                ]),
                "offset": .object([
                    "type": .string("integer"),
                    "minimum": .int(0),
                    "description": .string("Which chunk to continue from — the number given by the previous answer. With «heading» it counts inside that section, so a section too big for one answer is read on. Ignored with «outline»; with «as»: \"text\" it works and counts chunks."),
                ]),
                "as": .object([
                    "type": .string("string"),
                    "enum": .array([.string("chunks"), .string("text")]),
                    "description": .string("""
                    «text» returns the document as continuous text instead of \
                    a list of chunks: no ids, no metadata, no mirror in \
                    structuredContent — the text travels once. Measured on \
                    answers of the same size: 9 280 characters of the document \
                    as chunks against 20 880 as text. The document is described \
                    once, on the first page («document» in the structured \
                    answer: size, language, sections, extraction warnings); \
                    after that the answer is text alone, carrying only \
                    «[chunk N]» marks — and «[chunk N · section]» where the \
                    section changes — so you always know where you are and \
                    what to quote. Strip the marks before quoting. This is the \
                    way to **read a whole file**: page it with «offset», which \
                    the answer gives you, or take «sourcePath» from the answer \
                    and open the original file directly if you can reach this \
                    machine's disk. Overlapping chunks are joined without the \
                    repeats. **This is the default** — ask for «chunks» when \
                    you need the ids to fetch with get_documents, or the \
                    metadata of each chunk; passing «fields» selects chunks on \
                    its own, since text has no metadata to project.
                    """),
                ]),
                "outline": .object([
                    "type": .string("boolean"),
                    "description": .string("""
                    Return the structure of the file instead of its text: its \
                    sections, the chunks each one spans and roughly how many \
                    tokens it weighs. **Ask for this first on any file you have \
                    not read.** A specification of a thousand chunks will not \
                    fit in one answer nor in your context — reading it by \
                    offset takes hundreds of calls — but its outline fits in \
                    one, and from it you choose the section you actually need.
                    """),
                ]),
                "outline_depth": .object([
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "maximum": .int(outlineMaximumDepth),
                    "description": .string("""
                    How deep the outline goes. Default 1 — the top level only, \
                    which is what a map is for: a specification of a thousand \
                    chunks has hundreds of sub-headings, and listing them all \
                    gives a wall, not a map. Go deeper inside one section by \
                    passing «heading» together with «outline».
                    """),
                ]),
                "heading": .object([
                    "type": .string("string"),
                    "description": .string("""
                    Read one section instead of a page: the value of \
                    «heading_path» from the outline. Subsections come with it: \
                    a heading brings everything whose path starts with it, so \
                    asking for a chapter gives the chapter and its parts. \
                    Whitespace is matched loosely — a name copied from the \
                    outline works even where it holds a line break or a \
                    non-breaking space — and a miss answers with the nearest \
                    section names, so you need not ask for the map again. A \
                    section is a unit you can reason about and name to a person; \
                    «chunks 200 to 203» is neither.
                    """),
                ]),
                "fields": fieldsProperty,
            ]),
            // Обязательна только коллекция: файл называют либо отпечатком,
            // либо путём, и требовать оба значит требовать невозможного.
            "required": .array([.string("collection")]),
            "additionalProperties": .bool(false),
        ]),
        // Схема описывает **все три** вида ответа: страницу по порядку,
        // карту файла и раздел. Обязательна одна коллекция: карта отдаёт
        // «sections» и не отдаёт «documents», и клиент, сверяющий выдачу со
        // схемой, выбрасывал её целиком.
        outputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "collection": .object(["type": .string("string")]),
                "file": .object(["type": .string("string")]),
                "fileId": .object(["type": .string("string")]),
                "notes": .object(["type": .string("array")]),
                // Чтение по порядку.
                "documents": .object(["type": .string("array")]),
                "total": .object(["type": .string("integer")]),
                "offset": .object(["type": .string("integer")]),
                "nextOffset": .object(["type": .string("integer")]),
                "hasMore": .object(["type": .string("boolean")]),
                "fitsInOneAnswer": .object(["type": .string("boolean")]),
                "callsToFinish": .object(["type": .string("integer")]),
                "similarFiles": .object(["type": .string("array")]),
                // Карта файла.
                "outline": .object(["type": .string("boolean")]),
                "sections": .object(["type": .string("array")]),
                "totalSections": .object(["type": .string("integer")]),
                "totalChunks": .object(["type": .string("integer")]),
                "estimatedTokens": .object(["type": .string("integer")]),
                // Чтение по разделу.
                "heading": .object(["type": .string("string")]),
                "chunksInSection": .object(["type": .string("integer")]),
                "estimatedTokensInSection": .object(["type": .string("integer")]),
                "sectionFitsInOneAnswer": .object(["type": .string("boolean")]),
                // Документ текстом и файл на диске.
                "as": .object(["type": .string("string")]),
                "characters": .object(["type": .string("integer")]),
                "chunksShown": .object(["type": .string("integer")]),
                "sourcePath": .object(["type": .string("string")]),
                "sourceBytes": .object(["type": .string("integer")]),
                "document": .object(["type": .string("object")]),
                "callsToFinishSection": .object(["type": .string("integer")]),
                "nearestSections": .object(["type": .string("array")]),
                // Метаданные, одинаковые у всех кусков ответа: один раз
                // здесь вместо повтора на каждом.
                "sharedMetadata": .object(["type": .string("object")]),
                // Цена чтения целиком, посчитанная картой.
                "charactersEstimate": .object(["type": .string("integer")]),
                "callsToReadWhole": .object(["type": .string("integer")]),
            ]),
            "required": .array([.string("collection")]),
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

/// Что известно о том, откуда пришёл вызов инструмента.
///
/// Сервер инструментов один на оба транспорта, и знать, кто на том
/// конце, он не может — знает прокси, принимающий HTTP. Поэтому значение
/// ставит он, на время одного вызова.
public enum MCPCallContext {
    /// Можно ли называть пути на этом Маке. Агенту по сети — нельзя:
    /// абсолютный путь говорит об имени учётной записи и раскладке папок,
    /// а открыть файл там, где он сидит, агент всё равно не может.
    @TaskLocal public static var revealsLocalPaths = true
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
        // Объём запроса считается **до** обрезки: иначе столбец «Объём»
        // показывает двадцать килобайт на запись мегабайтного документа —
        // то есть врёт ровно там, где этот столбец и нужен.
        let requestBytes = text.utf8.count
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
            requestBytes: requestBytes,
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
        // Список спрашивается **не** через `decideTool`: тот тратит токен
        // частоты и на исчерпанном ведре отвечает отказом без клиента.
        // Разогнавшийся агент получал тогда список без инструментов записи —
        // и держал его весь сеанс, потому что сервер объявляет
        // «listChanged: false». Права ключа от частоты вызовов не зависят
        //.
        let client = await access.activeClient(withKey: key)
        let tools = client.map {
            MCPToolCatalogue.available(for: $0.permissions, readOnlyServer: readOnly)
        } ?? MCPToolCatalogue.all.filter { $0.permission == .read }

        return .object([
            "resultType": .string("complete"),
            "tools": .array(tools.map(\.listing)),
            // Подсказки кэша обязательны (`CacheableResult`). Список зависит
            // от ключа — значит `private`: делить его между ключами нельзя.
            "ttlMs": .int(MCPProtocol.toolsListCacheTTL),
            "cacheScope": .string("private"),
        ])
    }

    /// Ответ на `tools/call`.
    ///
    /// `Result` с ошибкой JSON-RPC — только для того, чего модель исправить не
    /// может: неизвестного инструмента и неразобранных параметров. Всё
    /// остальное — отказ по правам, отсутствующая коллекция, сбой базы —
    /// возвращается как `isError: true` с причиной словами.
    ///
    /// Граница двух видов ошибок — по спецификации (`2026-07-28`, «Tools»,
    /// «Error Handling»). Ошибка протокола — неизвестный инструмент и вызов,
    /// не отвечающий форме `tools/call`; код `-32602`, а не `-32601`: по HTTP
    /// «метод не найден» отвечается 404, и клиент решил бы, что сервер не
    /// умеет `tools/call` вовсе. Неверные **аргументы** — не протокол, а
    /// ошибка выполнения: `isError: true` с причиной, по которой модель
    /// исправит вызов сама.
    ///
    /// Так — с ревизии `2025-11-25`. Клиенту более старой ревизии (`version`)
    /// неверные аргументы отвечаются ошибкой протокола, как требовала его
    /// спецификация.
    public func call(
        name: String, arguments: JSONValue?, key: String?, version: String = MCPProtocol.version
    ) async -> Result<JSONValue, JSONRPCError> {
        guard MCPToolCatalogue.all.contains(where: { $0.name == name }) else {
            return .failure(.invalidParams("Unknown tool: \(name)"))
        }
        switch await perform(name: name, arguments: arguments, key: key) {
        case .failure(let error) where error.code == JSONRPCError.invalidParams
            && MCPProtocol.reportsArgumentErrorsAsToolResults(version):
            return .success(MCPToolOutcome.failure(error.message).result)
        case let other:
            return other
        }
    }

    private func perform(name: String, arguments: JSONValue?, key: String?) async -> Result<JSONValue, JSONRPCError> {
        let started = Date()
        guard let tool = MCPToolCatalogue.all.first(where: { $0.name == name }) else {
            return .failure(.invalidParams("Unknown tool: \(name)"))
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
                    // Один такой обход на ключ за раз: каждый перебирает до
                    // двадцати тысяч кусков, и всплеск вызовов разом занимал
                    // базу, которой пользуется и само приложение.
                    guard await access.beginHeavyCall(for: client.id) else {
                        auditNote = "refused: another collect_mentions of this key is running"
                        return answered(MCPToolOutcome.failure(
                            "Another collect_mentions call of this key is still running — wait for its answer, then call again."
                        ).result)
                    }
                    do {
                        let outcome = try await mentions(parsed, limits: limits)
                        await access.endHeavyCall(for: client.id)
                        return answered(outcome.result)
                    } catch {
                        await access.endHeavyCall(for: client.id)
                        throw error
                    }
                }
            case MCPToolCatalogue.addDocuments.name:
                guard let writing else {
                    return refused(.invalidParams("No documents passed: the «documents» parameter is required."))
                }
                do {
                    return answered(try await add(writing).result)
                } catch {
                    // Запись не состоялась — дневной предел ей не причитается
                    //. Списан он был при решении, до обращения к базе.
                    //
                    // Возвращается только **незаписанное**: большая запись идёт
                    // частями, и часть, успевшая лечь до сбоя, в базе есть.
                    // Вернуть за неё предел значило бы дать ключу писать сверх
                    // дневной нормы повторами одной и той же большой записи.
                    var written = 0
                    if case ChromaError.partialWrite(let failure) = error { written = failure.written }
                    // Отмена: что успело лечь, неизвестно — запрос мог уйти
                    // по сети и примениться. Норма не возвращается: вернуть её
                    // значило бы дать ключу писать сверх дневного предела
                    // отменами и повторами. Отменил вызов сам агент.
                    if error is CancellationError { written = writing.payload.documentCount }
                    await access.refundWrite(writing.payload.documentCount - written, forKey: key)
                    throw error
                }
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
        /// Идентификаторы, не поместившиеся в потолок ключа.
        ///
        /// Они отрезаются при разборе, и об этом говорит пометка — а вот
        /// `hasMore` в структуре оставался ложью: текст обещал продолжение,
        /// зеркало говорило «всё». Клиент, читающий структуру, уходил
        /// с половиной выборки, считая её целой.
        var droppedIdentifiers = 0
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
        /// Спросили не текст, а устройство файла: разделы и их размеры.
        let wantsOutline: Bool
        /// Спросили **документ текстом**, а не список кусков.
        let wantsWholeText: Bool
        /// Просил ли агент «limit» явно. Нужно, чтобы сказать вслух, что
        /// в режиме сплошного текста он не действует: молча выбросить
        /// переданный параметр хуже, чем урезать его (правило 3
        /// приложения 5).
        let askedLimit: Int?
        /// Читать не с начала, а раздел — тот, чей `heading_path` назван.
        let heading: String?
        /// Смещение **внутри раздела**, когда он не поместился целиком.
        let sectionOffset: Int
        /// Сколько кусков раздела показать за раз.
        ///
        /// Отдельно от `request.limit`: у запроса к базе он подменён на весь
        /// файл — границы раздела иначе не найти, — и просьба агента там
        /// не сохраняется. Хранить её надо здесь, иначе «limit» с «heading»
        /// перестаёт работать, как обещано в схеме.
        let sectionLimit: Int
        /// До какого уровня сворачивать оглавление. Не меньше единицы:
        /// несвёрнутая карта на живом ТЗ давала 596 «разделов» и переставала
        /// быть картой, поэтому такого случая нет вовсе.
        let outlineDepth: Int
    }

    /// Имена параметров, которыми агент попытался бы передать вектор.
    private static func vectorParameter(in arguments: JSONValue?) -> String? {
        guard let object = arguments?.objectValue else { return nil }
        let forbidden = ["embedding", "embeddings", "vector", "query_embedding", "query_embeddings"]
        return forbidden.first { object[$0] != nil }
    }

    /// Операторы, которые ChromaDB понимает в фильтре по метаданным.
    ///
    /// Список снят с живой базы (chroma 1.4.4), а не с документации: каждый
    /// проверен запросом, и в нём нет ни одного, про который «должно
    /// работать».
    private static let metadataOperators: Set<String> = [
        "$eq", "$ne", "$gt", "$gte", "$lt", "$lte", "$in", "$nin", "$and", "$or",
    ]

    /// Операторы поиска подстроки. ChromaDB принимает их **в фильтре по
    /// метаданным тоже** — и не находит по ним ничего.
    ///
    /// Замерено на живой базе: у 1699 документов `doc_type` начинается с
    /// «ГК ПР10», а `{"doc_type": {"$contains": "ПР10"}}` возвращает ноль,
    /// без ошибки. Отказ здесь — не строгость ради строгости: молчаливый
    /// пустой ответ агент читает как «в базе этого нет» и уходит искать
    /// в другое место, тогда как ошибку он читает и исправляет.
    private static let textOnlyOperators: Set<String> = ["$contains", "$not_contains"]

    /// Первый оператор фильтра, который база не поймёт, — вместе с тем, что
    /// делать вместо него.
    ///
    /// Проверяется до отправки, потому что своим ответом база объясняет
    /// ровно ничего: на `$regex` она отвечает «Invalid where clause», не
    /// называя ни поля, ни оператора. В журнале это видно трижды подряд —
    /// агент повторил один и тот же неисправимый вызов.
    private static func unsupportedOperator(in value: JSONValue) -> String? {
        if let object = value.objectValue {
            for (key, nested) in object.sorted(by: { $0.key < $1.key }) {
                if key.hasPrefix("$") {
                    if textOnlyOperators.contains(key) {
                        return "The «\(key)» operator works on the text of documents, not on metadata: "
                            + "ChromaDB accepts it in a metadata filter and then matches nothing at all. "
                            + "To search the text use the «contains» parameter; to match a metadata field "
                            + "use «$eq» with a value taken from describe_collection."
                    }
                    guard metadataOperators.contains(key) else {
                        return "The «\(key)» operator is not supported in «filter». "
                            + "Supported: \(metadataOperators.sorted().joined(separator: ", ")). "
                            + "For a substring use the «contains» parameter — it searches the text of "
                            + "documents; for a section use get_file with «heading»."
                    }
                }
                if let problem = unsupportedOperator(in: nested) { return problem }
            }
            return nil
        }
        if let array = value.arrayValue {
            for nested in array {
                if let problem = unsupportedOperator(in: nested) { return problem }
            }
        }
        return nil
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
                if let problem = unsupportedOperator(in: raw) {
                    return .failure(.invalidParams(problem))
                }
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
                fields: fields,
                droppedIdentifiers: max(0, ids.count - limits.ceiling)
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

        let outline = arguments?["outline"]?.boolValue ?? false
        // «as»: «chunks» — как было, «text» — сплошной текст документа.
        // Незнакомое значение — отказ, а не молчаливое «как было»: агент,
        // написавший «full», должен узнать об этом сразу, а не по тому, что
        // ответ выглядит не так.
        let shape = argument("as")?.lowercased()
        if let shape, shape != "text", shape != "chunks" {
            return .failure(.invalidParams("The «as» parameter takes «text» — the document as continuous text, the default — or «chunks», its chunks with ids and metadata."))
        }
        // Умолчание — **сплошной текст**, а не куски.
        //
        // Замер по журналу: 183 вызова `get_file` живыми агентами, из них
        // текстом — ноль. Режим описан в скилле пять раз, в схеме — с
        // замером «4 640 против 20 880», и всё равно не выбирается: агент
        // решает по заметкам в ответе, а не по описанию параметра. Совет как
        // средство здесь исчерпан, остаётся умолчание.
        //
        // Куски остаются там, где их спросили: явным «as»: "chunks" — и там,
        // где передан «fields». Проекция полей относится к метаданным куска,
        // а у сплошного текста метаданных нет вовсе: молча переключить такой
        // вызов в режим, где его параметр не значит ничего, хуже, чем
        // оставить как было. Тех и других в замере 8 из 183.
        let wholeText: Bool
        if let shape {
            wholeText = shape == "text"
        } else {
            wholeText = !outline && fields == nil
        }
        let heading = argument("heading")
        // Умолчание — верхний уровень: карта нужна обозримой, а подробности
        // берутся тем же вызовом с «heading».
        let depth: Int
        switch integer(arguments, "outline_depth") {
        case .failure(let error): return .failure(error)
        // Предел сверху — не придирчивость, а защита от падения: глубина
        // складывается с глубиной раздела, и `Int.max` вместе с «heading»
        // роняет **всё приложение** переполнением — мосты, прокси и окно
        // заодно. Ключа на чтение для этого достаточно.
        case .success(let value): depth = min(max(1, value ?? 1), MCPToolCatalogue.outlineMaximumDepth)
        }
        return .success(ParsedFile(
            path: path ?? "",
            fingerprint: fingerprint,
            request: MCPDocumentsRequest(
                collection: collection, ids: [],
                filter: fingerprint.map { fingerprintFilter($0) } ?? fileFilter(path ?? ""),
                // Оглавление строится по всему файлу сразу: половину разделов
                // показать хуже, чем не показать вовсе.
                // Раздел, как и оглавление, отбирается из всего файла: его
                // границы неизвестны заранее, а брать страницу и надеяться,
                // что раздел в неё попал, — то же гадание, от которого уходим.
                limit: (outline || wholeText || heading != nil) ? MCPFileChunks.maximumOrdered : resolved.count,
                offset: (outline || wholeText || heading != nil) ? 0 : offset,
                orderedByChunkIndex: true,
                // Ни карте, ни поиску границ раздела текст не нужен: обе
                // работают по заголовкам и номерам, а окно у них — весь файл.
                // Тексты раздела добираются отдельно, по идентификаторам
                // страницы.
                needsText: !(outline || wholeText || heading != nil)
            ),
            // У раздела «limit» работает, значит и про его урезание
            // потолком ключа нужно сказать. Молчит только оглавление: там
            // число кусков ни на что не влияет.
            // Ни карта, ни сплошной текст «limit» не читают: у первой куски
            // не считаются вовсе, у второго счёт идёт знаками бюджета.
            // Ни карта «limit» не читает — у неё куски не считаются вовсе.
            // Сплошной текст читает: с он стал умолчанием, и параметр,
            // переданный в режим, который человек не выбирал, обязан
            // работать, а не пропадать в пометке «проигнорировано».
            limitNote: outline ? nil : resolved.note,
            fields: fields,
            wantsOutline: outline,
            wantsWholeText: wholeText,
            askedLimit: requested,
            heading: heading,
            sectionOffset: offset,
            sectionLimit: resolved.count,
            outlineDepth: depth
        ))
    }

    /// Условие «этот и только этот файл».
    static func fileFilter(_ path: String) -> DocumentFilter {
        var filter = DocumentFilter()
        filter.conditions = [MetadataCondition(field: "source_file", op: .equals, value: path, valueIsText: true)]
        return filter
    }

    /// То же, но по отпечатку файла.
    static func fingerprintFilter(_ fingerprint: String) -> DocumentFilter {
        var filter = DocumentFilter()
        filter.conditions = [MetadataCondition(field: "file_id", op: .equals, value: fingerprint, valueIsText: true)]
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
            // Служебные поля ставит приложение: по ним документ числится
            // куском файла, закреплённым или записанным тем-то. Принятые
            // со слов агента, они выдавали бы его текст за часть чужого
            // файла в get_file или подмешивали бы его в каждую выдачу.
            if Self.isReservedMetadataKey(key) {
                return .failure(.invalidParams(
                    "Document \(documentNumber.plainDigits), field «\(key)»: this field is set by ChromaDB Manager itself — it ties a document to a file or a mark. Use another field name."
                ))
            }
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

    /// Поля, которые агент не пишет: адрес куска в файле, происхождение,
    /// пометки человека и всё служебное с приставкой `_cdbm_`.
    static func isReservedMetadataKey(_ key: String) -> Bool {
        key.hasPrefix("_cdbm_")
            || SourceSyncService.autoMetadataKeys.contains(key)
            || reservedMetadataKeys.contains(key)
    }

    static let reservedMetadataKeys: Set<String> = [
        "parent_chunk_id", "chunk_level", "chunk_count", "file_name", "sheet_name", "sheet_index", "row_number",
    ]

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
        // Шапка и пометки платят из того же бюджета, что и документы,
        // как у get_file и collect_mentions: прибавленные после рендера, они
        // выводили ответ за потолок ключа ровно на свою длину. Шапка — по
        // числу всех найденных: показанных не больше, значит и запас не меньше.
        let reserve = MCPDocumentRendering.overhead(
            header: Self.searchHeader(parsed.request, shown: answer.documents.count, model: answer.model),
            notes: (parsed.limitNote.map { [$0] } ?? []) + (answer.note.map { [$0] } ?? [])
        )
        let rendered = MCPDocumentRendering.render(
            answer.documents, limits: limits, metric: answer.metric, fields: parsed.fields,
            reserve: reserve,
            vocabulary: .searchResults
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

        let header = Self.searchHeader(parsed.request, shown: rendered.shown, model: answer.model)
        let text = ([header] + rendered.lines + notes).joined(separator: "\n")
        return MCPToolOutcome(text: text, structured: .object(structured))
    }

    /// Шапка выдачи поиска — одна на бюджет и на ответ.
    private static func searchHeader(_ request: MCPSearchRequest, shown: Int, model: String?) -> String {
        var header = request.isMultiCollection
            ? "Found in collections \(request.collections.joined(separator: ", ")): \(EnglishCount.grouped(shown, "document", "documents"))"
            : "Found in «\(request.collection)»: \(EnglishCount.grouped(shown, "document", "documents"))"
        if let model { header += ", model \(model)" }
        return header
    }

    private func documents(_ parsed: ParsedDocuments, limits: MCPOutputLimits) async throws -> MCPToolOutcome {
        let answer = try await backend.documents(parsed.request)
        // Шапка и пометки — из того же бюджета, см. `search`.
        let continueNote = answer.hasMore && parsed.request.ids.isEmpty
            ? Self.documentsContinueNote(next: parsed.request.offset + answer.documents.count)
            : nil
        let reserve = MCPDocumentRendering.overhead(
            header: Self.documentsHeader(parsed.request, shown: answer.documents.count),
            notes: (parsed.limitNote.map { [$0] } ?? []) + (continueNote.map { [$0] } ?? [])
        )
        let rendered = MCPDocumentRendering.render(
            answer.documents, limits: limits, fields: parsed.fields,
            reserve: reserve,
            // Выборку по идентификаторам «limit» не режет: советовать его
            // уменьшить значит советовать бездействие.
            vocabulary: parsed.request.ids.isEmpty ? .documents : .identifiedDocuments
        )

        var structured: [String: JSONValue] = [
            "collection": .string(parsed.request.collection),
            "documents": .array(rendered.documents),
            // Отрезанные по потолку идентификаторы — тоже «есть ещё»:
            // текст об этом говорит пометкой, и зеркало не вправе
            // утверждать обратное.
            "hasMore": .bool(answer.hasMore || rendered.isTruncated || parsed.droppedIdentifiers > 0),
        ]

        var notes = rendered.notes
        if let limitNote = parsed.limitNote { notes.insert(limitNote, at: 0) }
        if answer.hasMore, parsed.request.ids.isEmpty {
            notes.append(Self.documentsContinueNote(next: parsed.request.offset + rendered.shown))
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

        let header = Self.documentsHeader(parsed.request, shown: rendered.shown)
        let text = ([header] + rendered.lines + notes).joined(separator: "\n")
        return MCPToolOutcome(text: text, structured: .object(structured))
    }

    private static func documentsHeader(_ request: MCPDocumentsRequest, shown: Int) -> String {
        "From the collection «\(request.collection)»: \(EnglishCount.grouped(shown, "document", "documents"))"
    }

    private static func documentsContinueNote(next: Int) -> String {
        "There are more documents beyond this page: repeat the call with offset \(next.plainDigits)."
    }

    /// Те же документы — с текстами, в том же порядке. Подложка, отдавшая
    /// тексты сразу, второго обращения не получает.
    private func withTexts(_ documents: [MCPDocumentPayload], collection: String) async throws -> [MCPDocumentPayload] {
        let missing = documents.filter { $0.text == nil }.map(\.id)
        guard !missing.isEmpty else { return documents }
        let fetched = try await backend.documents(MCPDocumentsRequest(
            collection: collection, ids: missing, filter: nil, limit: missing.count, offset: 0
        ))
        let byID = Dictionary(fetched.documents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return documents.map { byID[$0.id] ?? $0 }
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
        // Без текстов: группировке по файлам хватает метаданных, а показаны
        // будут один-три образца с файла. Тексты двадцати тысяч совпадений,
        // взятые ради этого, — мегабайты на выброс; за текстами образцов
        // ходим ниже, отдельно и только за ними.
        let answer = try await backend.documents(MCPDocumentsRequest(
            collection: parsed.collection, ids: [], filter: parsed.filter,
            limit: Self.mentionsScanLimit, offset: 0, needsText: false
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

        let chosen = shown.flatMap { file in
            MCPFileChunks.ordered(file.samples).prefix(parsed.perFile)
        }
        let samples = try await withTexts(chosen, collection: parsed.collection)

        // Заголовок и пометки уезжают вместе с образцами и платят из того же
        // бюджета. У этой ветки оплаты не было вовсе: перечень
        // вычитался, а заголовок, пометки и их зеркало держались на плоском
        // запасе обвязки — и на длинных образцах ответ выходил за потолок
        // ключа молча. Считается до рендера: после — уже не бюджет,
        // а отчёт о перерасходе.
        let hasMore = parsed.offset + shown.count < files.count
        let continueNote = hasMore
            ? "Files \((parsed.offset + 1).plainDigits) to \((parsed.offset + shown.count).plainDigits) of \(files.count.plainDigits) are shown — continue with offset \((parsed.offset + shown.count).plainDigits)."
            : nil
        let header = "«\(parsed.contains)»: \(EnglishCount.grouped(answer.documents.count, "match", "matches")) in \(EnglishCount.grouped(files.count, "file", "files")), \(shown.count.plainDigits) shown"
        let overhead = MCPDocumentRendering.overhead(
            header: header, notes: notes + (continueNote.map { [$0] } ?? [])
        )

        let rendered = MCPDocumentRendering.render(
            samples, limits: limits, fields: parsed.fields,
            budget: max(1, limits.responseCharacters - listingSize),
            reserve: overhead,
            vocabulary: .mentionSamples
        )
        notes += rendered.notes
        if let continueNote { notes.append(continueNote) }

        // Ровно те зеркала, что уже оплачены выше: собирать их второй раз
        // значило бы разойтись с бюджетом при первой же правке.
        structured["files"] = .array(listingFiles)
        structured["documents"] = .array(rendered.documents)
        structured["hasMore"] = .bool(hasMore)

        return answered([header] + listing + [""] + rendered.lines)
    }

    /// Во сколько вызовов уложится чтение файла целиком — и стоит ли браться.
    ///
    /// Порог не из головы: десять вызовов агент делает, тридцать — уже нет,
    /// а триста не сделает никто. Живой случай: ТЗ на 1281 кусок, в ответ
    /// помещается четыре — агент прочитал двадцать три куска из тысячи с
    /// лишним и написал по ним «критический разбор», не заметив, что видел
    /// один процент.
    static let wholeFileCallBudget = 10

    /// Потолок числа кусков за одну ходку в режиме сплошного текста.
    static let wholeTextBatch = 64

    /// Первая ходка — короткая, пока о длине кусков ничего не известно.
    ///
    /// Порция в тридцать два куска при живой длине в 1150 знаков и бюджете
    /// в 21 000 давала восемнадцать кусков в ответ и четырнадцать —
    /// в мусор: сорок четыре процента лишнего чтения на каждой странице.
    /// После первой ходки длина известна точно, и порция считается под
    /// остаток бюджета.
    static let wholeTextBatchFirst = 12
    /// Сколько таких ходок на один ответ.
    ///
    /// Ограничение от зацикливания, а не от объёма: набор идёт, пока есть
    /// бюджет. Четырёх ходок хватало на куски обычной длины, но у коллекции,
    /// нарезанной по сотне знаков, они дают 12 800 знаков при бюджете в
    /// 23 000 — ответ наполовину пуст, и агент платит вдвое больше вызовов
    /// ровно там, где режим и придуман их сокращать.
    static let wholeTextRoundLimit = 64

    /// Запас под пометки ответа — **по замеру**, а не круглым числом
    /// (правило 4 приложения 5).
    ///
    /// Семь пометок могут встретиться в одном ответе; их постоянные части
    /// с подставленными самыми длинными числами дают 872 знака плюс семь
    /// переводов строки. Путь на диске в них не входит — он считается
    /// отдельно, потому что длины у него нет.
    ///
    /// Число это **устаревает**: прошлый замер был на шести пометках, и
    /// следующий же коммит добавил седьмую и удлинил другую, не пересчитав
    /// запас. Поэтому его держит проверка
    /// `testEveryNoteAtOnceStaysInsideTheCeiling`: она собирает ответ, где
    /// срабатывают все пометки сразу, и падает, как только они перестают
    /// помещаться.
    static let wholeTextNotesReserve = 900

    /// Запас под заголовок ответа и зеркало пути.
    ///
    /// Путь уезжает трижды — строкой заголовка, полем `file` и пометкой про
    /// диск, — а оплачивался один раз. У `collect_mentions` пути по четыреста
    /// знаков проверяются тестом, то есть случай живой.
    static let wholeTextHeaderReserve = 120
    /// Меньше этого ответ текстом не имеет смысла.
    static let minimumWholeTextAnswer = 2_000

    /// Как называется всё, что лежит до первого заголовка файла.
    ///
    /// Одна метка на оглавление и на отбор: если карта называет раздел, его
    /// обязано быть можно спросить. Иначе выходит место на карте, куда сама
    /// карта не ведёт.
    static let beforeFirstHeading = "(before the first heading)"

    /// Имя раздела в том виде, в каком его можно набрать обратно.
    ///
    /// Ключ раздела — строка, которую агент перепечатывает с карты руками.
    /// В `heading_path` живого ТЗ нашлись **неразрывный пробел** и **перевод
    /// строки**: на экране они неотличимы от обычного пробела. Агент набрал
    /// обычный, сравнение шло знак в знак — и он получил «в файле нет такого
    /// раздела» про раздел, который карта назвала строкой выше. Цена той
    /// невидимой закорючки: 352 куска и 101 067 токенов — пятая часть
    /// документа, — не прочитанные и без объяснения почему.
    ///
    /// Поэтому пробельное приводится к одному виду и на карте, и в отборе:
    /// печатается ровно то, что потом сработает. Ключ, который нельзя
    /// набрать, — не ключ.
    static func typeableHeading(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Каким разделом считается каждый кусок — одним правилом.
    ///
    /// Правило одно на карту и на отбор нарочно. Кусок без заголовка —
    /// таблица, врезка, продолжение абзаца — принадлежит разделу, внутри
    /// которого лежит; карта так и считала, а отбор по «heading» считал иначе
    /// и такие куски терял. Раздел, который карта называет, обязан выдаваться
    /// целиком: иначе на карте есть место, куда сама карта не ведёт.
    static func effectiveHeadings(of documents: [MCPDocumentPayload]) -> [String] {
        var carried: String?
        return documents.map { payload in
            if case .string(let value)? = payload.metadata?["heading_path"] {
                let name = Self.typeableHeading(value)
                if !name.isEmpty {
                    carried = name
                    return name
                }
            }
            return carried ?? Self.beforeFirstHeading
        }
    }

    /// Слова имени раздела для счёта совпадений.
    ///
    /// Один разбор на спрошенное имя и на кандидатов: две копии разошлись бы
    /// при первой же правке, и счёт тихо перестал бы совпадать.
    static func headingWords(_ value: String) -> Set<String> {
        Set(
            value.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        )
    }

    /// Пометка о том, что передали и что не сработало.
    ///
    /// Одна на все ветки: молча выбросить переданный параметр хуже, чем
    /// урезать его (правило 3 приложения 5), и правило это одинаково верно
    /// для каждого вида ответа. Первый раз пометка была написана только
    /// для сплошного текста, и карта осталась без неё.
    static func ignoredNote(_ names: [String], mode: String, because reason: String) -> String? {
        guard !names.isEmpty else { return nil }
        let list = names.joined(separator: " and ")
        let verb = names.count == 1 ? "does" : "do"
        return "\(list) \(verb) not apply to \(mode) — \(reason)"
    }

    /// Ответ на промах по имени раздела — один на все три ветки `get_file`.
    ///
    /// Третья копия этого места родилась уже без последней строки — той,
    /// что говорит, **что делать дальше**, — и промах снова упирался в
    /// тупик, ради ухода от которого блок и писался.
    static func sectionNotFound(
        file: String, heading: String, among headings: [String]
    ) -> (lines: [String], nearest: [String]) {
        let nearest = nearestSections(to: heading, among: headings)
        var lines = ["The file «\(file)» has no section «\(heading)»."]
        guard !nearest.isEmpty else {
            lines.append("Call get_file with «outline»: true and no «heading» to see the sections it does have.")
            return (lines, [])
        }
        lines.append("Its sections closest to that name are:")
        lines += nearest.map { "• \($0)" }
        lines.append("Ask for one of these by «heading», or call get_file with «outline»: true and no «heading» for the whole map.")
        return (lines, nearest)
    }

    /// Разделы файла, похожие на спрошенный, — подсказка на промах.
    ///
    /// «В файле нет такого раздела. Позови outline» — совет в пустоту: имя
    /// агент оттуда и взял. Промах по имени лечится тем же, чем промах по
    /// пути, — показать то, что есть, и не заставлять ходить второй раз.
    ///
    /// Кандидаты берутся **на той глубине, на какой спросили**. Иначе агент,
    /// опечатавшийся в имени подраздела на шесть кусков, получал в ответ
    /// главу на триста пятьдесят — и уходил читать её девяноста вызовами.
    static func nearestSections(to heading: String, among headings: [String], limit: Int = 5) -> [String] {
        // Глубина спрошенного имени: спросили главу — предлагаем главы,
        // спросили подраздел — подразделы.
        let depth = max(1, typeableHeading(heading).components(separatedBy: " > ").count)
        var names: [String] = []
        let trimmed = headings.map { name -> String in
            let parts = name.components(separatedBy: " > ")
            return parts.count > depth ? parts.prefix(depth).joined(separator: " > ") : name
        }
        for name in trimmed where names.last != name {
            if !names.contains(name) { names.append(name) }
        }
        // Ничего похожего — лучше промолчать, чем назвать «ближайшими»
        // первые пять разделов файла: у настоящего ТЗ это титульный лист
        // и содержание, то есть самое бесполезное из всего документа.
        let asked = headingWords(typeableHeading(heading)).filter { $0.count > 2 }
        guard !asked.isEmpty else { return [] }
        // Счёт по общим словам: опечатка в одном слове не должна прятать
        // раздел, совпавший остальными пятью.
        //
        // При равном счёте порядок закрепляется местом в файле: `sorted`
        // в Swift не устойчива, и восемь одинаково подошедших «Требований
        // к оказанию услуг…» возвращались бы каждый раз в своём порядке —
        // агент не смог бы понять, есть нужный раздел в списке или нет.
        // Та же оговорка, что у перечня файлов в collect_mentions.
        struct Candidate { let order: Int; let name: String; let score: Int }
        var matched: [Candidate] = []
        for (order, name) in names.enumerated() {
            let score = asked.intersection(headingWords(name)).count
            if score > 0 { matched.append(Candidate(order: order, name: name, score: score)) }
        }
        guard !matched.isEmpty else { return [] }
        matched.sort { $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score }
        return matched.prefix(limit).map(\.name)
    }

    /// Раздел оглавления в том виде, в каком он уедет в `structuredContent`.
    static func outlineSectionMirror(
        heading: String, first: Int, last: Int, tokens: Int
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "heading": .string(heading),
            "firstChunk": .int(first),
            "lastChunk": .int(last),
        ]
        if tokens > 0 { object["estimatedTokens"] = .int(tokens) }
        return .object(object)
    }

    /// Что сказать, когда файла в коллекции не нашлось.
    ///
    /// Одно объяснение на все три ветки `get_file`. Карту велено спрашивать
    /// первой — значит и промахиваются по пути чаще всего на ней, — а
    /// отвечала она одной строкой без единой подсказки, тогда как чтение по
    /// порядку предлагало похожие пути. Чтение по разделу отвечало хуже
    /// обоих: «в файле нет такого раздела», причём имя файла в этой пометке
    /// пустое, потому что взять его неоткуда.
    private func fileNotFound(_ parsed: ParsedFile) async -> (lines: [String], similar: [String]) {
        // Отпечаток испортить нечем, поэтому промах по нему значит одно из
        // двух: коллекция не та или файла в ней нет. Отдельная беда —
        // коллекции прежних сборок, где поля file_id ещё нет; о ней говорится
        // прямо, иначе агент будет повторять тот же вызов.
        guard parsed.fingerprint == nil else {
            return ([
                "The collection «\(parsed.request.collection)» has no chunks with file_id «\(parsed.fingerprint ?? "")».",
                "If the collection was filled by earlier builds it has no file_id field yet — call get_file with the «file» parameter, taking the path from the source_file field of a document you found.",
            ], [])
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
        }
        return (lines, similar)
    }

    /// Устройство файла: разделы, их границы и вес.
    ///
    /// Отвечает на вопрос, который у «прочитай документ целиком» стоит первым,
    /// а задаётся последним: из чего этот документ состоит. Метаданные без
    /// текста — оглавление документа на тысячу кусков само помещается в один
    /// ответ, а чтение такого документа подряд не помещается никуда.
    private func fileOutline(_ parsed: ParsedFile, limits: MCPOutputLimits) async throws -> MCPToolOutcome {
        let found = try await fileChunks(parsed)
        let documents = found.answer.documents
        let path = found.path.isEmpty ? Self.storedPath(of: documents) : found.path
        let fingerprint = parsed.fingerprint ?? Self.storedFingerprint(of: documents)

        var structured: [String: JSONValue] = [
            "collection": .string(parsed.request.collection),
            "file": .string(path),
            "outline": .bool(true),
        ]
        if let fingerprint { structured["fileId"] = .string(fingerprint) }

        guard !documents.isEmpty else {
            structured["sections"] = .array([])
            if path.isEmpty { structured["file"] = .string(parsed.path) }
            let missing = await fileNotFound(parsed)
            if !missing.similar.isEmpty {
                structured["similarFiles"] = .array(missing.similar.map(JSONValue.string))
            }
            return MCPToolOutcome(
                text: missing.lines.joined(separator: "\n"), structured: .object(structured)
            )
        }

        // Карта одного раздела, когда назван «heading»: схема это обещает —
        // «go deeper inside one section by passing heading together with
        // outline», — и это единственный выход, когда карта целого файла
        // не поместилась. Правило принадлежности то же самое.
        let all = Self.effectiveHeadings(of: documents)
        // Номер куска считается по **всему файлу**, а не по обрезку. Без
        // «chunk_index» запасной отсчёт по месту в массиве дал бы у раздела,
        // начинающегося с двухсотого куска, «firstChunk: 0», и продолжение
        // по этому числу увело бы агента в начало файла.
        let positions = documents.enumerated().map { index, payload -> Int in
            if case .int(let value)? = payload.metadata?[MCPFileChunks.orderKey] { return value }
            return index
        }
        var inScope = Array(documents.indices)
        if let requested = parsed.heading, !requested.isEmpty {
            // То же приведение имени, что и у отбора: карта раздела не должна
            // спотыкаться о неразрывный пробел, которого агенту не видно.
            let scope = Self.typeableHeading(requested)
            inScope = inScope.filter { all[$0] == scope || all[$0].hasPrefix(scope + " > ") }
            structured["heading"] = .string(scope)
            guard !inScope.isEmpty else {
                structured["sections"] = .array([])
                // Размер файла известен, раз файл найден.
                structured["totalChunks"] = .int(documents.count)
                let missing = Self.sectionNotFound(file: path, heading: scope, among: all)
                if !missing.nearest.isEmpty {
                    structured["nearestSections"] = .array(missing.nearest.map(JSONValue.string))
                }
                return MCPToolOutcome(
                    text: missing.lines.joined(separator: "\n"), structured: .object(structured)
                )
            }
        }
        // Глубина отсчитывается **от запрошенного раздела**, а не от корня:
        // иначе карта раздела «Требования» при умолчании 1 сворачивалась в
        // одну строку — сам этот раздел, — и указанный схемой выход из
        // урезанной карты не давал ни одной подробности ( обещал его,
        // но мерил глубину не оттуда).
        let scopeDepth = parsed.heading.flatMap {
            $0.isEmpty ? nil : Self.typeableHeading($0).components(separatedBy: " > ").count
        } ?? 0

        // Разделы идут подряд: соседние куски одного раздела — это он и есть.
        // Складывать по имени нельзя — один заголовок встречается в документе
        // не раз, и «Общие положения» из начала и из приложения слиплись бы.
        struct Section { var heading: String; var first: Int; var last: Int; var tokens: Int }
        var sections: [Section] = []
        // Кусок без заголовка принадлежит тому разделу, внутри которого лежит:
        // правило общее с отбором по «heading».
        for index in inScope {
            // Принадлежность посчитана один раз по всему файлу: считать её
            // заново по обрезку значит зависеть от того, попал ли в обрезок
            // носитель заголовка.
            var heading = all[index]
            // Свёртка до запрошенной глубины. Без неё карта перестаёт быть
            // картой: на живом ТЗ вышло 596 «разделов», больше половины по
            // одному куску, и в ответ поместилась восьмая часть. Верхний
            // уровень даёт десятки строк — по ним и выбирают, куда идти,
            // а подробности берут тем же вызовом с «heading».
            let parts = heading.components(separatedBy: " > ")
            let allowed = scopeDepth + parsed.outlineDepth
            if parts.count > allowed {
                heading = parts.prefix(allowed).joined(separator: " > ")
            }
            let position = positions[index]
            var tokens = 0
            if case .int(let value)? = documents[index].metadata?["chunk_estimated_tokens"] { tokens = value }
            if var last = sections.last, last.heading == heading {
                last.last = position
                last.tokens += tokens
                sections[sections.count - 1] = last
            } else {
                sections.append(Section(heading: heading, first: position, last: position, tokens: tokens))
            }
        }

        let totalTokens = sections.reduce(0) { $0 + $1.tokens }
        // Вес целого — по всему файлу, а не по разделу: пара с `totalChunks`,
        // и по ней тоже решают, читается ли документ целиком. Сложенный по
        // одному разделу, он выдавал бы ТЗ на 600 токенов вместо 500 625 —
        // ровно та подмена, что чинилась у счёта кусков.
        let fileTokens = documents.reduce(0) { sum, payload in
            if case .int(let value)? = payload.metadata?["chunk_estimated_tokens"] { return sum + value }
            return sum
        }
        var header = parsed.heading.map { "Outline of «\(path)», section «\($0)»: " } ?? "Outline of «\(path)»: "
        header += EnglishCount.grouped(inScope.count, "chunk", "chunks")
        if totalTokens > 0 { header += ", about \(totalTokens.plainDigits) tokens" }
        header += ", \(EnglishCount.grouped(sections.count, "section", "sections"))."

        var lines: [String] = []
        var mirrors: [JSONValue] = []
        var shown = 0
        var size = 0
        // Пометки собираются **до** цикла, потому что из этого же бюджета
        // и платят.
        //
        // Комментарий ниже обещал «за вычетом конверта, заголовка и пометок»
        // с самого начала, а вычитались только первые два: пометки уезжали
        // сверх — и текстом, и зеркалом. Пока их было две, запас конверта
        // это скрывал; третья (цена чтения целиком) вынесла ответ
        // за объявленный потолок — 24 290 против 24 000 на замере.
        let (headNotes, tailNotes, trimReserve) = await outlineNotes(
            parsed: parsed, path: path, fingerprint: fingerprint,
            sectionCount: sections.count,
            onlySectionHeading: sections.count == 1 ? sections[0].heading : nil,
            documents: documents, fileTokens: fileTokens, limits: limits,
            orderUnavailable: found.answer.orderUnavailable, structured: &structured
        )
        // Бюджет — весь ответ за вычетом конверта, заголовка и пометок.
        // Половина, как у collect_mentions, здесь не за что: там вторую
        // половину съедают тексты образцов, а у карты второго плательщика
        // нет — и урезанная зря карта стоит агенту лишнего вызова.
        let notesCost = MCPDocumentRendering.overhead(header: "", notes: headNotes + tailNotes) + trimReserve
        let budget = max(
            1,
            limits.responseCharacters - MCPDocumentRendering.envelopeReserve - header.count - notesCost
        )
        for (index, section) in sections.enumerated() {
            let range = section.first == section.last
                ? "chunk \(section.first.plainDigits)"
                : "chunks \(section.first.plainDigits)–\(section.last.plainDigits)"
            var line = "\((index + 1).plainDigits). \(section.heading) — \(range)"
            if section.tokens > 0 { line += ", ~\(section.tokens.plainDigits) tokens" }
            // Зеркало раздела уезжает наравне со строкой и платит из того же
            // бюджета. Без этого ответ вышел на 27 923 символа при
            // обещанных 24 000 — та же дыра, что чинили у перечня файлов.
            let mirror = Self.outlineSectionMirror(
                heading: section.heading, first: section.first, last: section.last, tokens: section.tokens
            )
            let cost = line.count + 1 + mirror.deliveredSize
            if index > 0, size + cost > budget { break }
            lines.append(line)
            mirrors.append(mirror)
            size += cost
            shown += 1
        }

        // Пометки уже собраны — остаётся вставить ту, что зависит от цикла.
        var notes = headNotes
        if shown < sections.count {
            notes.append("The outline was trimmed by answer size: \(shown.plainDigits) of the \(sections.count.plainDigits) sections are shown. Ask for one section of it — «outline» together with «heading» — and the rest fits.")
        }
        notes += tailNotes

        // Ровно те зеркала, что оплачены выше: вторая сборка разошлась бы
        // с бюджетом при первой же правке.
        structured["sections"] = .array(mirrors)
        structured["totalSections"] = .int(sections.count)
        // «Всего кусков» — у файла, даже когда спрошен один раздел: по этому
        // полю решают, читается ли документ целиком, и раздел на сорок кусков
        // под этим именем выдавал бы ТЗ на 1281 кусок за небольшой файл.
        structured["totalChunks"] = .int(documents.count)
        if parsed.heading != nil { structured["chunksInSection"] = .int(inScope.count) }
        if fileTokens > 0 { structured["estimatedTokens"] = .int(fileTokens) }
        // Вес спрошенного раздела — своим полем, как и его размер: в строке
        // заголовка стоит именно он, и читающему структуру нужно то же число.
        if parsed.heading != nil, totalTokens > 0 {
            structured["estimatedTokensInSection"] = .int(totalTokens)
        }
        structured["notes"] = .array(notes.map(JSONValue.string))

        return MCPToolOutcome(
            text: ([header] + lines + notes).joined(separator: "\n"), structured: .object(structured)
        )
    }

    /// Сколько знаков конца `left` повторяются началом `right`.
    ///
    /// Нарезка по умолчанию перекрывает куски на 15 %. Склеенные встык, они
    /// дадут документ с повтором на каждом шве — а для разбора требований
    /// это не косметика: повторённый пункт читается как отдельный.
    ///
    /// Перекрытие ищется **по данным**, а не по настройке: настройка могла
    /// меняться между прогонами, а куски в базе — те, что есть. Берётся зачин
    /// `right`, ищется в хвосте `left`, и найденное место проверяется целиком:
    /// совпасть обязан **весь** остаток `left`, а не только зачин.
    ///
    /// Зонд короче настоящего перекрытия — иначе его не найти вовсе, — но не
    /// настолько, чтобы срезать случайное совпадение. Тридцать два знака:
    /// перекрытие при умолчании нарезки составляет около ста восьмидесяти,
    /// а случайно совпасть хвостом и зачином на тридцать два знака подряд
    /// два соседних куска документа практически не могут. Ошибка здесь
    /// дороже повтора: лишний срез **удаляет текст документа**.
    static let overlapProbe = 32

    /// Больше половины куска перекрытием не считается.
    ///
    /// Не осторожность ради осторожности: два **одинаковых** соседних куска —
    /// шапка таблицы, повторённая в каждой строке, бланк, боилерплейт — дают
    /// «перекрытие» во весь кусок, и срез удалил бы его целиком. Первый же
    /// замер на такой подложке это и показал: двести кусков схлопнулись в
    /// один. Повтор в тексте агент увидит и переживёт, пропажу — нет,
    /// поэтому предел выбран в пользу повтора.
    static let overlapShare = 0.5

    static func overlapLength(_ left: String, _ right: String, cap: Int = 4000) -> Int {
        guard left.count >= overlapProbe, right.count >= overlapProbe else { return 0 }
        let ceiling = Int(Double(min(left.count, right.count)) * overlapShare)
        guard ceiling >= overlapProbe else { return 0 }
        let tail = left.count > cap ? String(left.suffix(cap)) : left
        let head = String(right.prefix(overlapProbe))
        // Перекрытие длиннее потолка не берётся всё равно — значит и искать
        // его начало раньше последних `ceiling` знаков незачем. На повторяющемся
        // тексте (шапка таблицы в каждой строке) пробник находится в хвосте
        // десятки раз, и каждая находка — сравнение на тысячи знаков.
        var from = tail.index(tail.endIndex, offsetBy: -min(ceiling, tail.count))
        while let found = tail.range(of: head, range: from..<tail.endIndex) {
            let candidate = tail[found.lowerBound...]
            if candidate.count <= ceiling, right.hasPrefix(candidate) { return candidate.count }
            from = tail.index(after: found.lowerBound)
        }
        return 0
    }

    /// «Лист1, row 12» — у строки таблицы; `nil` у всего остального.
    static func rowAddress(of payload: MCPDocumentPayload) -> String? {
        guard case .int(let row)? = payload.metadata?["row_number"] else { return nil }
        if case .string(let sheet)? = payload.metadata?["sheet_name"], !sheet.isEmpty {
            return "\(sheet), row \(row.plainDigits)"
        }
        return "row \(row.plainDigits)"
    }

    /// Поля строк таблицы, которые стоит показать при тексте: не служебные
    /// и **не одинаковые у всех строк** — одинаковое (год папки, клиент)
    /// — свойство файла, а не строки, и в каждой строке было бы шумом.
    /// У файла из одной строки сравнивать не с чем — показывается всё.
    ///
    /// Одинаковые не пропадают: они уходят в `shared` и называются один раз
    /// пометкой — цена, совпавшая у всех строк, тоже данные.
    static func rowColumnFields(_ payloads: [MCPDocumentPayload]) -> (varying: Set<String>, shared: ChromaMetadata) {
        let rows = payloads.compactMap { payload -> ChromaMetadata? in
            guard payload.metadata?["row_number"] != nil else { return nil }
            return payload.metadata
        }
        guard !rows.isEmpty else { return ([], [:]) }
        let keys = Set(rows.flatMap(\.keys)).filter {
            !MetadataSchema.isTechnicalKey($0) && $0 != CollectionBindingKeys.legacySpace
        }
        guard rows.count > 1 else { return (keys, [:]) }
        var varying: Set<String> = []
        var shared: ChromaMetadata = [:]
        for key in keys {
            let first = rows[0][key]
            if rows.contains(where: { $0[key] != first }) { varying.insert(key) } else if let first { shared[key] = first }
        }
        return (varying, shared)
    }

    /// «Цена: 12; Остаток: 5» — значения колонок строки из метаданных.
    static func rowValues(of payload: MCPDocumentPayload, fields: Set<String>) -> String? {
        guard let metadata = payload.metadata, !fields.isEmpty else { return nil }
        let pairs = fields.sorted().compactMap { key -> String? in
            guard let value = metadata[key], value != .null else { return nil }
            return "\(key): \(value.displayString)"
        }
        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }

    /// Сколько знаков в начале куска — повторённая шапка таблицы.
    ///
    /// Мера пишется при нарезке; здесь она проверяется по тексту: срезается
    /// только то, что и правда строки таблицы, заканчивающиеся переводом
    /// строки. Мера, не сошедшаяся с текстом, — `nil`: лишний срез удалил
    /// бы текст документа, повтор шапки — только место.
    static func repeatedHeader(of payload: MCPDocumentPayload, text: String) -> Int? {
        guard case .int(let length)? = payload.metadata?[TableChunkHeaders.lengthKey],
              length > 1, length < text.count else { return nil }
        let prefix = text.prefix(length)
        guard prefix.hasSuffix("\n") else { return nil }
        let lines = prefix.dropLast().components(separatedBy: "\n")
        guard lines.allSatisfy(TableText.isRow) else { return nil }
        return length
    }

    /// Куски — в сплошной текст документа, без повторов на швах.
    static func joinedText(_ parts: [String]) -> (text: String, trimmed: Int) {
        let joined = joinedText(parts.map { (mark: nil, text: $0) })
        return (joined.text, joined.trimmed)
    }

    /// То же, но с метками последовательности перед кусками.
    ///
    /// Шов ищется по **исходным** кускам, а не по собранному тексту: метка,
    /// попавшая между ними, разорвала бы совпадение, и перекрытие перестало
    /// бы находиться.
    ///
    /// `after` — текст куска, стоящего перед первым: шов **между страницами**
    /// иначе не срезается вовсе. Внутри страницы повторы убирались, между
    /// страницами оставались, а пометка обещала агенту, что текст читается
    /// как документ: на семидесяти страницах это шестьдесят девять швов и
    /// около двенадцати тысяч повторённых знаков.
    static func joinedText(
        _ parts: [(mark: String?, text: String)], after: String = ""
    ) -> (text: String, trimmed: Int, atPageStart: Int) {
        var text = ""
        var previous = after
        var trimmed = 0
        // Шов **на границе страницы** считается отдельно: пометка о нём
        // иначе не может отличить сделанную работу от несделанной и
        // обещает её на коллекции без перекрытия вовсе.
        var atPageStart = 0
        for part in parts where !part.text.isEmpty {
            var body = part.text
            var overlap = 0
            if !previous.isEmpty {
                overlap = overlapLength(previous, body)
                trimmed += overlap
                if text.isEmpty { atPageStart = overlap }
                if overlap > 0 { body = String(body.dropFirst(overlap)) }
            }
            previous = part.text
            guard !text.isEmpty else {
                text = part.mark.map { $0 + "\n" } ?? ""
                text += body
                continue
            }
            if let mark = part.mark {
                text += "\n" + mark + "\n" + body
            } else {
                // Без перекрытия куски — соседние куски документа, и
                // разделитель между ними свой: перевод строки. С перекрытием
                // он уже внутри.
                text += overlap > 0 ? body : "\n" + body
            }
        }
        return (text, trimmed, atPageStart)
    }

    /// Сколько знаков пометок извлечения показывается в строке описания.
    static let warningsInLine = 160

    /// Приговор странице — одной сборкой на оба места, как и у раздела.
    static func pageVerdict(
        total: Int, shown: Int, left: Int, calls: Int, onDiskPath: String?
    ) -> [String] {
        // Ни слова о токенах: по пяти прочитанным кускам их не сосчитать —
        // на титульных страницах они мелкие, и оценка разошлась с точной на
        // треть (342 027 против 500 625). Число чанков и вызовов известно
        // точно, его и называем, а вес отдаёт оглавление.
        var verdict = [
            "This file does not fit in one answer as chunks: \(total.plainDigits) chunks, \(shown.plainDigits) here and \(left.plainDigits) still unread"
                + ". Finishing it this way would take about \(calls.plainDigits) more calls.",
        ]
        // Приговор называет **выходы**, а не отговаривает. Задача «получить
        // документ целиком» законна, и приложение обязано дать способ,
        // а не объяснять, почему не стоит.
        if let onDiskPath {
            verdict.append("The whole document is on this machine at \(onDiskPath) — open it there, in one step.")
            verdict.append("Through this channel: get_file with «as»: \"text\" carries more than twice as much of the document per call; «outline»: true gives the structure if you only need a part.")
        } else {
            verdict.append("Ask for it with «as»: \"text\" — the same file as continuous text, more than twice as much of the document per call. Or take its structure first with «outline»: true and read only the section you need.")
        }
        return verdict
    }

    static func pageHeader(path: String, shown: Int, from: Int, total: Int?) -> String {
        var header = "File «\(path)»: \(EnglishCount.grouped(shown, "chunk", "chunks")) starting at \(from.plainDigits)"
        if let total { header += ", \(total.plainDigits) in total" }
        return header
    }

    /// Пометки о непредсказуемом порядке — по одной сборке на оба места,
    /// где они нужны: в оплате наперёд и в самом ответе.
    static var unorderedPageNote: String {
        "The file holds more than \(MCPFileChunks.maximumOrdered.plainDigits) chunks — the application does not return that many in an arbitrary order; assemble them by the chunk_index field."
    }
    static var unorderedSectionNote: String {
        "The file holds more than \(MCPFileChunks.maximumOrdered.plainDigits) chunks — they came back in an arbitrary order, so this section may be incomplete."
    }

    static func pageContinueNote(next: Int) -> String {
        "The file was not read whole: continue with offset \(next.plainDigits)."
    }

    /// Приговор разделу — одной сборкой на оба места: на оплату наперёд
    /// и на сам ответ.
    static func sectionVerdict(
        section: Int, shown: Int, left: Int, calls: Int, hasSubsections: Bool
    ) -> [String] {
        var verdict = [
            "This section does not fit in one answer: \(section.plainDigits) chunks, \(shown.plainDigits) here and \(left.plainDigits) still unread. Finishing it would take about \(calls.plainDigits) more calls.",
            // Первым — самый дешёвый маршрут, а не самый привычный.
            // Куски эту страницу везут вместе с метаданными и зеркалом;
            // тот же раздел сплошным текстом идёт вчетверо плотнее, и до
            // этой правки о нём не говорила ни одна заметка — при том что
            // на него же переключается умолчание инструмента.
            "The same section as text costs fewer calls: get_file with this «heading» and «as»: \"text\" — that is what this tool returns unless «chunks» is asked for.",
        ]
        // Совет обязан быть исполним: у раздела без подразделов карта
        // вернёт его же одной строкой, и звать её оттуда некуда — тот же
        // дефект, что и. Тогда остаётся «offset» и поиск
        // с фильтром по файлу.
        verdict.append(hasSubsections
            ? "Or take its structure first — call get_file with «outline»: true and this same «heading» — then read the part you need, or find it with search and a filter on this file."
            : "Or read it on with «offset», or find what you need with search and a filter on this file.")
        return verdict
    }

    static func sectionHeader(path: String, heading: String, shown: Int, section: Int, from: Int) -> String {
        "File «\(path)», section «\(heading)»: \(EnglishCount.grouped(shown, "chunk", "chunks")) of \(section.plainDigits), starting at \(from.plainDigits)"
    }

    static func sectionContinueNote(section: Int, shown: Int, from: Int, next: Int) -> String {
        "The section holds \(EnglishCount.grouped(section, "chunk", "chunks")) and did not fit whole: \(shown.plainDigits) shown from \(from.plainDigits). Continue in this same section with offset \(next.plainDigits)."
    }

    /// Пометки карты — и запас под ту единственную, что зависит от того,
    /// сколько разделов поместилось.
    ///
    /// Собираются до цикла, чтобы их можно было оплатить из бюджета: пометка,
    /// приписанная после подсчёта, уезжает сверх обещанного потолка.
    /// Заодно кладёт в структурированный ответ поля, которые сопровождают эти
    /// же пометки, — путь на диске и цену чтения целиком: одно без другого
    /// разошлось бы при первой же правке.
    private func outlineNotes(
        parsed: ParsedFile,
        path: String,
        fingerprint: String?,
        sectionCount: Int,
        // Единственный заголовок файла — когда он единственный: по нему
        // видно, что заголовков в файле нет вовсе. Тип разделов живёт внутри
        // самой карты, и тащить его сюда значило бы вынести наружу подробность
        // ради одной проверки.
        onlySectionHeading: String?,
        documents: [MCPDocumentPayload],
        fileTokens: Int,
        limits: MCPOutputLimits,
        orderUnavailable: Bool,
        structured: inout [String: JSONValue]
    ) async -> (head: [String], tail: [String], trimReserve: Int) {
        var head: [String] = []
        if orderUnavailable {
            head.append("The file holds more than \(MCPFileChunks.maximumOrdered.plainDigits) chunks — they came back in an arbitrary order, so the boundaries below are not to be trusted.")
        }
        // Запас под пометку об урезании: её текст известен заранее с точностью
        // до числа показанных разделов, и берётся верхняя оценка — столько же
        // цифр, сколько в общем счёте.
        let trimNote = "The outline was trimmed by answer size: \(sectionCount.plainDigits) of the \(sectionCount.plainDigits) sections are shown. Ask for one section of it — «outline» together with «heading» — and the rest fits."
        let trimReserve = MCPDocumentRendering.overhead(header: "", notes: [trimNote])

        var tail: [String] = []
        // Переданное и не сработавшее называется вслух — и на карте тоже.
        // «outline» побеждает «as» молча, и агент, написавший оба, получал
        // не тот вид ответа без единого слова о причине.
        var ignored: [String] = []
        if parsed.wantsWholeText { ignored.append("«as»: \"text\"") }
        if parsed.askedLimit != nil { ignored.append("«limit»") }
        if parsed.fields != nil { ignored.append("«fields»") }
        if let note = Self.ignoredNote(
            ignored, mode: "«outline»: true",
            because: "the outline is metadata about the file, not its text. Ask again without «outline» for the text form."
        ) {
            tail.append(note)
        }
        // Заголовков в файле нет вовсе — и карта обязана это сказать, а не
        // выдавать один придуманный раздел на весь документ за устройство.
        // Поле heading_path пишется не всякому источнику, а карту велено
        // спрашивать первой.
        if parsed.heading == nil, onlySectionHeading == Self.beforeFirstHeading {
            tail.append("This file carries no headings at all — what is shown is the whole of it, not a chapter. Read it in pages with «offset», or find what you need with search and a filter on this file.")
        }
        // Отпечаток подставляется только настоящий: у коллекций прежних
        // сборок поля file_id нет, и совет с пустым значением — это фильтр,
        // который не найдёт ничего.
        if let fingerprint {
            tail.append("Read a section with get_file and the «heading» parameter, or find what you need with search and a filter on this file: {\"file_id\": {\"$eq\": \"\(fingerprint)\"}}.")
        } else {
            tail.append("Read a section with get_file and the «heading» parameter, or find what you need with search and a filter on this file: {\"source_file\": {\"$eq\": \"\(path)\"}} — this collection carries no file_id field.")
        }
        // Путь на диске — и здесь. Карту велено спрашивать **первой**, и
        // именно из неё агент должен узнать, что весь документ лежит рядом
        // файлом: без этого он тратит второй вызов ровно на то, ради чего
        // поле и заведено.
        let onDisk = await localFile(metadata: documents.first?.metadata)
        if let onDisk {
            structured["sourcePath"] = .string(onDisk.path)
            if let bytes = onDisk.bytes { structured["sourceBytes"] = .int(bytes) }
            tail.append("The whole document is on this machine at \(onDisk.path) — if you can read files there, that is all of it in one step.")
        }
        // Цена маршрута — в карте, где маршрут и выбирают.
        //
        // Разбор живого сеанса: агент взял карту, увидел 37 разделов и пошёл
        // читать их по одному — стратегия разумная, но он не знал, что этот
        // маршрут отдаёт четыре куска за вызов, а соседний пятнадцать. Ни
        // одна заметка цены не называла, и выбор был вслепую. Число считается
        // той же формулой, по которой потом наполняется страница, — иначе
        // карта звала бы в маршрут по цене, которой у него нет.
        if let price = Self.callsToReadWhole(
            estimatedTokens: fileTokens, limits: limits, path: path, onDiskPath: onDisk?.path
        ) {
            structured["charactersEstimate"] = .int(price.characters)
            structured["callsToReadWhole"] = .int(price.calls)
            tail.append("Reading it whole: about \(price.characters.plainDigits) characters, which is \(price.calls.plainDigits) calls at this key's answer size **at best** — a page stops at the last chunk that fits whole, so expect up to a fifth more. get_file returns text by default; page it with «offset». One section is one call when it fits; the chunk counts above say which do.")
        }
        return (head, tail, trimReserve)
    }

    /// Во что обходится общий блок: зеркало плюс объясняющая его пометка.
    static func sharedMetadataCost(
        _ projection: (fields: [String]?, shared: ChromaMetadata, note: String?)
    ) -> Int {
        guard !projection.shared.isEmpty else { return 0 }
        return JSONValue.object(projection.shared.mapValues(\.json)).deliveredSize
            + (projection.note?.count ?? 0)
    }

    /// Проекция, которая не повторяет общий блок, — и то, что о ней сказать.
    ///
    /// Возвращает то, что показывать у каждого куска, что вынести один раз
    /// и чем это объяснить. Спрошенную агентом проекцию не трогает: он назвал
    /// поля сам, и подменять его выбор — та же молчаливая подмена, от которой
    /// уходим.
    static func withoutRepeatedMetadata(
        _ payloads: [MCPDocumentPayload], asked: [String]?
    ) -> (fields: [String]?, shared: ChromaMetadata, note: String?) {
        guard asked == nil else { return (asked, [:], nil) }
        let shared = sharedMetadata(of: payloads)
        guard !shared.isEmpty else { return (nil, [:], nil) }
        let all = Set(payloads.compactMap(\.metadata).flatMap(\.keys))
        let varying = all.subtracting(shared.keys).sorted()
        // Ничего не меняется от куска к куску — прятать нечего: пустой
        // список полей рендер читает как «показать все», и вынос обернулся
        // бы удвоением вместо экономии.
        guard !varying.isEmpty else { return (nil, [:], nil) }
        // Сэкономленное считается, а не объявляется: столько знаков этот
        // ответ вёз бы повтором. Считается по полученным кускам, а пометка
        // пишется до рендера, который может часть из них не показать, —
        // поэтому «до»: верхняя граница правдива, точное число было бы нет.
        let saved = MCPDocumentRendering.metadataLine(shared).count * (payloads.count - 1)
        let note = """
        Metadata identical on every chunk here is in «sharedMetadata» once \
        instead of on each: \(shared.count.plainDigits) fields, up to \
        \(saved.plainDigits) characters that went to text instead. Name the \
        fields you want per chunk with «fields».
        """
        return (varying, shared, note)
    }

    /// Всё, что уезжает **вместе** со сплошным текстом и потому вычитается
    /// из его бюджета: конверт, заголовок, пометки, путь.
    ///
    /// Считается в одном месте на двоих: по этой же формуле карта
    /// обещает «около N вызовов», и обещание должно совпадать с тем, что
    /// человек потом получит. Разойдись они — карта звала бы в маршрут по
    /// цене, которой у него нет.
    static func wholeTextOverhead(path: String, onDiskPath: String?) -> Int {
        MCPDocumentRendering.envelopeReserve
            + (onDiskPath?.count ?? 0)
            // Путь уезжает трижды: строкой заголовка, полем `file` и пометкой
            // про диск.
            + path.count * 2
            + wholeTextHeaderReserve
            + wholeTextNotesReserve
    }

    /// Во сколько страниц сплошного текста укладывается документ.
    ///
    /// Знаки — из оценки токенов, той же, что карта показывает по разделам;
    /// отсюда «около» (`TokenEstimator.charactersPerToken`).
    ///
    /// А вот **число вызовов** — оценка снизу, и сказано об этом вслух
    ///. Она делит знаки на бюджет страницы, то есть считает укладку
    /// идеальной; на деле страница обрывается на последнем куске, который
    /// влез целиком, и остаток пропадает.
    ///
    /// Насколько — замерено на трёх живых файлах, а не на одном:
    /// большое ТЗ, 1281 кусок — обещан 81 вызов, вышло 96 (+19 %);
    /// ТЗ поменьше в PDF, 1004 куска — 59 против 62 (+5 %);
    /// положение на 338 кусков — 21 против 23 (+10 %). Отсюда
    /// «до пятой части», а не «на пятую часть»: у файла с крупными кусками
    /// на границе страницы пропадает больше.
    static func callsToReadWhole(
        estimatedTokens: Int, limits: MCPOutputLimits, path: String, onDiskPath: String?
    ) -> (characters: Int, calls: Int)? {
        guard estimatedTokens > 0 else { return nil }
        let characters = TokenEstimator.characters(forTokens: estimatedTokens)
        let page = max(
            minimumWholeTextAnswer,
            limits.responseCharacters - wholeTextOverhead(path: path, onDiskPath: onDiskPath)
        )
        return (characters, max(1, (characters + page - 1) / page))
    }

    /// Метаданные, одинаковые у всех показанных кусков.
    ///
    /// Замерено на ТЗ в 1281 кусок: метаданных 1 158 знаков на кусок, из них
    /// 802 (69 %) байт в байт одинаковы у **всех** — двадцать пять полей:
    /// имя файла, размер, хеш содержимого, пометки извлечения, тип документа.
    /// Ответ на четыре куска нёс их четырежды, при том что файл назван в его
    /// же шапке. На четыре куска это 3 208 знаков из 20 669 — место текста,
    /// отданное под повтор.
    ///
    /// Считается по показанному, и говорится ровно так же — «одинаковое
    /// у кусков в этом ответе». Обещать «одинаковое у всего файла» можно
    /// только там, где весь файл в руках; у страницы его нет, и разница
    /// не словесная: `page_number`, совпавший на одной странице, свойством
    /// файла от этого не становится.
    static func sharedMetadata(of payloads: [MCPDocumentPayload]) -> ChromaMetadata {
        // На одном куске повторять нечего: вынести его метаданные в общий
        // блок значило бы отнять их у единственного куска, ничего не сэкономив.
        guard payloads.count > 1, let first = payloads.first?.metadata else { return [:] }
        var shared = first
        for payload in payloads.dropFirst() {
            guard let metadata = payload.metadata else { return [:] }
            shared = shared.filter { metadata[$0.key] == $0.value }
            if shared.isEmpty { break }
        }
        return shared
    }

    /// Сколько в файле разделов — тем же счётом, что и у карты.
    ///
    /// Считалось по полным путям заголовков, и на живом ТЗ описание файла
    /// говорило «571 section» там, где карта того же файла в том же сеансе
    /// говорила «37 sections». Слово одно, числа разные, и агенту неоткуда
    /// узнать, какое из них про что. Разошлись они потому, что карта режет
    /// заголовок до верхнего уровня, а описание брало его целиком — вместе
    /// со всеми подразделами.
    ///
    /// Пока сплошной текст просили явным «as», описание видели немногие;
    /// с оно уезжает на первой странице каждого чтения, и расхождение
    /// стало видно сразу.
    static func topLevelSectionCount(of headings: [String]) -> Int {
        var count = 0
        var previous: String?
        for heading in headings {
            let top = heading.components(separatedBy: " > ").first ?? heading
            if top != previous {
                count += 1
                previous = top
            }
        }
        return count
    }

    /// Описание документа — то, что агент обязан получить **один раз**.
    ///
    /// Метаданные лежат у каждого куска, и на странице из сорока кусков они
    /// уезжали бы сорок раз: 1 223 знака на кусок против 1 180 знаков самого
    /// текста (замер). Здесь они собраны один раз и отдаются с первой
    /// страницей — дальше в ответе только текст с метками.
    ///
    /// Ничего не выдумывается: поля берутся из метаданных, каких нет — тех
    /// нет и в описании.
    static func documentDescription(
        of documents: [MCPDocumentPayload], sections: Int, onDisk: MCPFileOnDisk?
    ) -> (fields: [String: JSONValue], line: String) {
        // Числа, у которых уже есть имя в ответе, здесь не повторяются:
        // «всего кусков» уезжает полем `totalChunks` на каждой странице, и
        // второе имя для того же значения заставляло бы клиента гадать,
        // одно ли это (тот же довод, что и у пути на диске).
        var fields: [String: JSONValue] = [:]
        var parts = [EnglishCount.grouped(documents.count, "chunk", "chunks")]
        if sections > 0 {
            fields["sections"] = .int(sections)
            parts.append(EnglishCount.grouped(sections, "section", "sections"))
        }
        // Поля ищутся по всем кускам, а не у первого: язык определяется не
        // всегда, а титульная страница коротка — на ней его может не быть,
        // тогда как у соседнего куска он есть. Тем же правилом, что у
        // `storedPath` и `storedFingerprint` строкой выше.
        func string(_ key: String) -> String? {
            for payload in documents {
                if case .string(let value)? = payload.metadata?[key], !value.isEmpty { return value }
            }
            return nil
        }
        func integer(_ key: String) -> Int? {
            for payload in documents {
                if case .int(let value)? = payload.metadata?[key] { return value }
            }
            return nil
        }
        var tokens = 0
        for payload in documents {
            if case .int(let value)? = payload.metadata?["chunk_estimated_tokens"] { tokens += value }
        }
        if tokens > 0 {
            fields["estimatedTokens"] = .int(tokens)
            parts.append("about \(tokens.plainDigits) tokens")
        }
        if let pages = integer("page_count") {
            fields["pages"] = .int(pages)
            parts.append(EnglishCount.grouped(pages, "page", "pages"))
        }
        if let bytes = integer("file_size") ?? onDisk?.bytes {
            fields["bytes"] = .int(bytes)
            parts.append("\(bytes.plainDigits) bytes")
        }
        if let modified = string("file_mtime") {
            fields["modified"] = .string(modified)
            parts.append("modified \(modified)")
        }
        if let language = string("document_language") ?? string("language") {
            fields["language"] = .string(language)
            parts.append("language \(language)")
        }
        if let sourceID = string("source_id") { fields["sourceId"] = .string(sourceID) }
        // Пометки извлечения — часть описания, а не мелочь: «таблица пришла
        // плоским текстом» меняет то, что по этому документу можно считать.
        if let warnings = string("extraction_warnings") {
            fields["warnings"] = .string(warnings)
            // У пометок извлечения длины нет: это строка из метаданных, и
            // целиком она уедет полем. В строке описания — начало, иначе
            // одна такая пометка вынесла бы ответ за потолок.
            let shown = warnings.count > warningsInLine
                ? String(warnings.prefix(warningsInLine)) + "…"
                : warnings
            parts.append("extraction warnings: \(shown)")
        }
        // Путь на диске здесь не повторяется: он уезжает полем `sourcePath`
        // на **каждой** странице, а описание — только на первой. Два имени
        // для одного значения заставляли бы клиента гадать, одно ли это.
        return (fields, parts.joined(separator: ", "))
    }

    /// Тексты для готовой страницы — вторым запросом, по идентификаторам.
    ///
    /// Порядок восстанавливается по списку id: выдача `get` по
    /// идентификаторам его не обещает, как и всякая другая.
    static func textsRestored(
        for page: [MCPDocumentPayload],
        request: MCPDocumentsRequest,
        backend: any MCPToolBackend
    ) async throws -> [MCPDocumentPayload] {
        // Решает флаг запроса, а не осмотр кусков: подложка вправе отдать
        // текст и там, где его не просили, и гадать по содержимому значит
        // получать разное поведение от разных баз.
        guard !page.isEmpty, !request.needsText else { return page }
        let ids = page.map(\.id)
        let answer = try await backend.documents(MCPDocumentsRequest(
            collection: request.collection, ids: ids, filter: nil,
            limit: ids.count, offset: 0
        ))
        let byID = Dictionary(answer.documents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Кусок, за которым сходили и не нашли, отдаётся как был: пустой
        // текст лучше пропавшего результата.
        return page.map { byID[$0.id] ?? $0 }
    }

    /// Документ **текстом**, а не списком кусков.
    ///
    /// Замер на живом ответе чтения по разделу: 19 942 знака ответа несли
    /// 4 590 знаков документа — 23 %. Остальное — текст, уехавший **дважды**
    /// (строкой модели и зеркалом в `structuredContent`), и метаданные,
    /// которых агент не просил: 1 223 знака на кусок против 1 180 знаков
    /// самого текста. Отсюда и цена «прочитать целиком»: ТЗ на 1281 кусок —
    /// около трёхсот вызовов.
    ///
    /// Здесь текст уезжает **один раз** и без обвязки: ни идентификаторов,
    /// ни метаданных, ни зеркала. Замер на ответах одного размера: 4 640
    /// знаков документа кусками против 20 880 текстом — и это уже не «сотни
    /// вызовов», а десятки.
    ///
    /// Куски склеиваются с проверкой шва: нарезка по умолчанию перекрывает
    /// их на 15 %, и склейка встык дала бы документ с повторами.
    private func fileWholeText(_ parsed: ParsedFile, limits: MCPOutputLimits) async throws -> MCPToolOutcome {
        let found = try await fileChunks(parsed)
        let documents = found.answer.documents
        let path = found.path.isEmpty ? Self.storedPath(of: documents) : found.path
        var structured: [String: JSONValue] = [
            "collection": .string(parsed.request.collection),
            "file": .string(path),
            "as": .string("text"),
        ]
        if let fingerprint = parsed.fingerprint ?? Self.storedFingerprint(of: documents) {
            structured["fileId"] = .string(fingerprint)
        }
        guard !documents.isEmpty else {
            if path.isEmpty { structured["file"] = .string(parsed.path) }
            let missing = await fileNotFound(parsed)
            if !missing.similar.isEmpty {
                structured["similarFiles"] = .array(missing.similar.map(JSONValue.string))
            }
            return MCPToolOutcome(
                text: missing.lines.joined(separator: "\n"), structured: .object(structured)
            )
        }
        structured["totalChunks"] = .int(documents.count)

        // Отбор в раздел — тем же правилом, что везде. Заголовки нужны и
        // дальше: по ним ставятся метки разделов внутри текста.
        let all = Self.effectiveHeadings(of: documents)
        // Номер куска — **по файлу**, а не по обрезку: пометка обещает
        // агенту, что в метках стоит нумерация документа, и у коллекций без
        // `chunk_index` запасной отсчёт обязан считать то же самое. Та же
        // подмена, что чинилась у карты в.
        var numbering: [String: Int] = [:]
        for (index, payload) in documents.enumerated() {
            if case .int(let value)? = payload.metadata?[MCPFileChunks.orderKey] {
                numbering[payload.id] = value
            } else {
                numbering[payload.id] = index
            }
        }
        let scope: [(payload: MCPDocumentPayload, heading: String)]
        if let heading = parsed.heading, !heading.isEmpty {
            let asked = Self.typeableHeading(heading)
            scope = zip(documents, all)
                .filter { $0.1 == asked || $0.1.hasPrefix(asked + " > ") }
                .map { (payload: $0.0, heading: $0.1) }
            structured["heading"] = .string(asked)
            guard !scope.isEmpty else {
                let missing = Self.sectionNotFound(file: path, heading: asked, among: all)
                if !missing.nearest.isEmpty {
                    structured["nearestSections"] = .array(missing.nearest.map(JSONValue.string))
                }
                return MCPToolOutcome(
                    text: missing.lines.joined(separator: "\n"), structured: .object(structured)
                )
            }
            structured["chunksInSection"] = .int(scope.count)
        } else {
            scope = zip(documents, all).map { (payload: $0.0, heading: $0.1) }
        }

        let from = max(0, min(parsed.sectionOffset, scope.count))

        // Где документ лежит целиком. Считается до всех выходов: тот, кто
        // промахнулся смещением, — первый, кому путь и нужен, а ответ
        // «за концом» его не нёс.
        let onDisk = await localFile(metadata: documents.first?.metadata)
        if let onDisk {
            structured["sourcePath"] = .string(onDisk.path)
            if let bytes = onDisk.bytes { structured["sourceBytes"] = .int(bytes) }
        }

        // Смещение за концом — это смещение, а не конец документа. «hasMore:
        // false» без объяснения агент читает как «дочитал», и это та же беда,
        // что чинилась у чтения кусками и у раздела; третья
        // ветка ту фразу не получила.
        guard from < scope.count else {
            structured["offset"] = .int(from)
            structured["chunksShown"] = .int(0)
            structured["characters"] = .int(0)
            structured["hasMore"] = .bool(false)
            let what = parsed.heading.map { "The section «\(Self.typeableHeading($0))» of «\(path)»" }
                ?? "The file «\(path)»"
            return MCPToolOutcome(
                text: "\(what) holds \(EnglishCount.grouped(scope.count, "chunk", "chunks")), and offset \(from.plainDigits) is already past its end.",
                structured: .object(structured)
            )
        }

        // Описание файла — **один раз**, с первой страницей. На семидесяти
        // страницах повторённое описание съело бы больше целого ответа,
        // а нового не сказало бы ничего.
        //
        // Считается до набора текста, потому что платит из того же бюджета:
        // у пометок извлечения длины нет вовсе, и одна такая строка вынесла
        // бы ответ за объявленный потолок молча.
        var describing: String?
        // Зеркало описания уезжает наравне со строкой и платит из того же
        // бюджета: у `extraction_warnings` длины нет, и одно такое
        // поле вынесло ответ за потолок на 857 знаков в первом же замере.
        var describingCost = 0
        if from == 0 {
            // Описывается **файл**, а не спрошенный раздел: под словом
            // «Document» раздел на сорок кусков выдавал бы ТЗ на 1281 за
            // небольшой файл — та же подмена, что чинилась у `totalChunks`
            // и у `estimatedTokens`.
            let description = Self.documentDescription(
                of: documents, sections: Self.topLevelSectionCount(of: all), onDisk: onDisk
            )
            let mirror = JSONValue.object(description.fields)
            structured["document"] = mirror
            describing = "Document: \(description.line)."
            describingCost = mirror.deliveredSize + (describing?.count ?? 0)
        }

        // Бюджет — весь ответ за вычетом конверта, описания и запаса под
        // пометки: текста в зеркале нет, платить дважды не за что, но за
        // всё, что **уезжает вместе с текстом**, платить обязано.
        // Путь уезжает трижды: строкой заголовка, полем `file` и пометкой
        // про диск. Считать его один раз значило обещать потолок и выдавать
        // больше — на путях по четыреста знаков это восемьсот сверх.
        /// Колонки строк таблицы, ушедшие в метаданные: текстом
        /// ответа они иначе не видны вовсе, а «для арифметики берите файл
        /// целиком» без цен и количеств — обещание впустую.
        let rowFields = Self.rowColumnFields(scope.map(\.payload))
        // Пометки о таблицах — по всему читаемому, а не по странице: их длина
        // известна заранее и платит из бюджета, как описание. У общих колонок
        // строк длины нет вовсе — сколько колонок, столько и строка, — и в
        // запас под пометки она не помещается.
        //
        // Плоская таблица и книга не целиком — те же предупреждения, что
        // у любой другой выдачи: текст по умолчанию их терял, и арифметика
        // по такой странице ничем не останавливалась.
        var tableNotes = MCPDocumentRendering.tableIntegrityNotes(scope.map(\.payload))
        if !rowFields.shared.isEmpty {
            let line = rowFields.shared.keys.sorted()
                .map { "\($0): \(rowFields.shared[$0]?.displayString ?? "")" }
                .joined(separator: "; ")
            tableNotes.append("Every table row here also carries: \(line).")
        }
        let overhead = Self.wholeTextOverhead(path: path, onDiskPath: onDisk?.path)
            + describingCost
            // Строкой ответа и зеркалом в `notes` — дважды, как и описание.
            + tableNotes.reduce(0) { $0 + $1.count + 1 }
            + JSONValue.array(tableNotes.map(JSONValue.string)).deliveredSize
        // Пол бюджета выше потолка ключа — это превышение обещанного, и
        // молчать о нём нельзя: человек ставил число под контекст своей
        // модели. Правило 3 приложения 5 в обратную сторону.
        let room = limits.responseCharacters - overhead
        let budget = max(Self.minimumWholeTextAnswer, room)
        let ceilingRaised = budget > room
        // Хвост предыдущей страницы: без него шов между страницами не
        // срезается вовсе, а пометка обещает, что текст читается как документ.
        // Едет вместе с первой порцией, а не отдельной ходкой: на семидесяти
        // страницах отдельная ходка — это шестьдесят девять лишних запросов
        // к базе ради одного куска.
        var precedingText = ""
        var pieces: [(mark: String?, text: String)] = []
        var size = 0
        var cursor = from
        var rounds = 0
        // Метка ставится у каждого куска: агент, читающий сплошной текст,
        // иначе не знает, где он в документе, и не может ни продолжить с
        // нужного места, ни назвать источник цитаты. Имя раздела в метке —
        // только там, где раздел сменился: в каждой строке оно было бы
        // не меткой, а шумом.
        var lastHeading: String?
        /// Сколько повторённых шапок таблиц убрано на швах.
        var headersDropped = 0
        // Потолок по числу кусков — тот, что попросили.
        //
        // Пока текст выбирали явным «as», молчаливое «limit здесь не
        // действует» было честным: человек знал, куда идёт. С умолчанием он
        // этого не знает, и параметр, переданный в режим, который он не
        // выбирал, обязан значить то же, что значил бы в другом. Потолок
        // ключа уже применён: `sectionLimit` — это `resolved.count`.
        let chunkCap = parsed.askedLimit == nil ? Int.max : max(1, parsed.sectionLimit)
        // Сколько кусков влезет, заранее неизвестно: длины лежат в текстах,
        // а тексты и есть то, за чем идём. Поэтому — порциями, пока не полно.
        while cursor < scope.count, size < budget, pieces.count < chunkCap,
              rounds < Self.wholeTextRoundLimit {
            // Порция берётся под остаток бюджета, а не круглым числом:
            // средняя длина куска после первой ходки известна точно.
            let wanted: Int
            if pieces.isEmpty {
                wanted = Self.wholeTextBatchFirst
            } else {
                let average = max(1, size / pieces.count)
                wanted = max(1, min(Self.wholeTextBatch, (budget - size) / average + 2))
            }
            // Первая ходка прихватывает и предшествующий кусок — тот, по
            // которому ищется шов границы. В ответе он не участвует.
            let seed = (rounds == 0 && from > 0) ? [scope[from - 1].payload] : []
            let slice = Array(scope[cursor..<min(scope.count, cursor + wanted)])
            var filled = try await Self.textsRestored(
                for: seed + slice.map(\.payload), request: parsed.request, backend: backend
            )
            if !seed.isEmpty {
                precedingText = filled.first?.text ?? ""
                filled = Array(filled.dropFirst())
            }
            var stopped = false
            for (offsetInSlice, payload) in filled.enumerated() {
                // Первый кусок отдаётся всегда, даже если он один больше
                // бюджета: ответ без текста хуже урезанного.
                //
                // Шапка таблицы, повторённая в начале куска, — только
                // у первого куска ответа: дальше читатель её только
                // что видел, и на таблицах она съедала до трети ответа.
                var text = payload.text ?? ""
                if !pieces.isEmpty, let header = Self.repeatedHeader(of: payload, text: text) {
                    text.removeFirst(header)
                    headersDropped += 1
                }
                let number = numbering[payload.id] ?? cursor
                let heading = offsetInSlice < slice.count ? slice[offsetInSlice].heading : ""
                var mark = heading != lastHeading && !heading.isEmpty
                    ? "[chunk \(number.plainDigits) · \(heading)]"
                    : "[chunk \(number.plainDigits)]"
                if let row = Self.rowAddress(of: payload) {
                    mark = "[chunk \(number.plainDigits) · \(row)]"
                    if let values = Self.rowValues(of: payload, fields: rowFields.varying) { text += "\n" + values }
                }
                // Столько кусков, сколько попросили, — раньше бюджета.
                if pieces.count >= chunkCap {
                    stopped = true
                    break
                }
                // Метка уезжает наравне с текстом и платит из того же
                // бюджета: у заголовка длиной в девяносто знаков сорок таких
                // меток — это лишние три тысячи знаков сверх обещанного
                // потолка — та же дыра, что у зеркал.
                if !pieces.isEmpty, size + text.count + mark.count + 2 > budget {
                    stopped = true
                    break
                }
                lastHeading = heading
                pieces.append((mark: mark, text: text))
                size += text.count + mark.count + 2
                cursor += 1
            }
            rounds += 1
            if stopped { break }
        }

        var joined = Self.joinedText(pieces, after: precedingText)
        let hasMore = cursor < scope.count
        // Конец назван концом: агент, дочитавший семидесятую страницу из
        // семидесяти, не должен выяснять это вычитанием.
        if !hasMore, !joined.text.isEmpty {
            joined.text += parsed.heading.map { "\n[end of section «\(Self.typeableHeading($0))»]" }
                ?? "\n[end of document]"
        }
        structured["offset"] = .int(from)
        structured["chunksShown"] = .int(cursor - from)
        structured["characters"] = .int(joined.text.count)
        structured["hasMore"] = .bool(hasMore)
        if hasMore { structured["nextOffset"] = .int(cursor) }

        var notes: [String] = []
        if found.answer.orderUnavailable {
            notes.append("The file holds more than \(MCPFileChunks.maximumOrdered.plainDigits) chunks — they came back in an arbitrary order, so this text is not the document's order.")
        }
        notes += tableNotes
        if headersDropped > 0 {
            notes.append("The table header repeated at the top of \(EnglishCount.grouped(headersDropped, "chunk", "chunks")) was dropped — it is the one shown above them.")
        }
        if joined.trimmed > 0 {
            notes.append("The chunks of this collection overlap: \(joined.trimmed.plainDigits) repeated characters were trimmed at the seams, so the text reads as the document does.")
        }
        // Пометка говорит о сделанном, а не о возможном: на коллекции без
        // перекрытия срезать на границе нечего, и обещать работу там нельзя.
        if joined.atPageStart > 0 {
            notes.append("Of those, \(joined.atPageStart.plainDigits) were at the seam with the previous page — paste the pages together as they are.")
        }
        if hasMore {
            // Сколько ещё ходок — по тому, сколько унесла эта.
            // Считать нечего, если страница не унесла ни куска: там свой
            // разговор, и деление было бы на ноль.
            let onThisPage = cursor - from
            let left = onThisPage > 0
                ? " About \(max(1, (scope.count - cursor + onThisPage - 1) / onThisPage).plainDigits) more pages at this rate."
                : ""
            notes.append("Chunks \(from.plainDigits) to \((cursor - 1).plainDigits) of \(scope.count.plainDigits) are here — continue with «offset»: \(cursor.plainDigits).\(left)")
        }
        if parsed.heading != nil {
            notes.append("«offset» counts chunks inside this section; the numbers in the [chunk N] marks are the document's own, so the two do not match here.")
        }
        if ceilingRaised {
            notes.append("This answer is longer than the key's ceiling of \(limits.responseCharacters.plainDigits) characters: what surrounds the text — the file description, the notes, the path — already fills it, and an answer with no text at all would be useless. Ask for a key with a larger ceiling, or read the file at «sourcePath».")
        }
        // Переданное и не сработавшее называется вслух: молча выбросить
        // параметр хуже, чем урезать его (правило 3 приложения 5).
        var ignored: [String] = []
        if parsed.fields != nil { ignored.append("«fields»") }
        if let note = Self.ignoredNote(
            ignored, mode: "«as»: \"text\"",
            because: "the text carries no metadata to project. Ask for «as»: \"chunks\" if you need the fields."
        ) {
            notes.append(note)
        }
        // Сделанное называется вслух ровно так же, как несделанное: страница
        // на пять кусков вместо пятнадцати выглядит как упёршаяся в бюджет,
        // и без этой строки агент решил бы, что дальше читать нечем.
        // «Сколько просили» — это просьба агента, а не то, что от неё
        // осталось после потолка ключа. При потолке 10 и просьбе 200 ответ
        // уверял, будто агент просил десять, и звал просить больше — то
        // есть звал в тупик, потому что больше ключу не дадут.
        if parsed.askedLimit == chunkCap, cursor - from >= chunkCap, hasMore {
            notes.append("The page stopped at the \(chunkCap.plainDigits) chunks you asked for, not at the answer budget — ask for more with «limit» to fill the answer.")
        }
        // Урезанную потолком просьбу называет та же пометка, что и в двух
        // других ветках чтения: без неё агент не знает, что его «limit»
        // не сработал, — а это первое, что он должен узнать.
        if let limitNote = parsed.limitNote { notes.append(limitNote) }
        // Совет читать файл на диске — только пока листать ещё есть что:
        // тому, кто дочитал до конца, он предлагает переделать сделанное.
        if hasMore, let onDisk {
            // Читающему раздел файл на диске даёт больше, чем он просил, —
            // и сказать об этом надо, иначе совет выглядит равноценной
            // заменой, а он не она.
            notes.append(parsed.heading == nil
                ? "The rest of this document is on this machine at \(onDisk.path) — read it there in one step instead of paging it through this channel."
                : "The whole document — not just this section — is on this machine at \(onDisk.path); reading it there is one step instead of paging this section through the channel.")
        }
        if !notes.isEmpty { structured["notes"] = .array(notes.map(JSONValue.string)) }

        // Границы включительные: «0–6 of 6» читается как семь кусков из
        // шести, и первая же сверка с метками «[chunk 5]» выглядит расхождением.
        var header = "File «\(path)» as text: \(joined.text.count.plainDigits) characters"
        header += cursor > from
            ? ", chunks \(from.plainDigits)–\((cursor - 1).plainDigits) of \(scope.count.plainDigits)."
            : ", nothing to show at offset \(from.plainDigits) of \(scope.count.plainDigits)."
        // Текст уезжает **один раз** — только строкой. Зеркало его не несёт
        // нарочно: ради этого режим и сделан.
        let preamble = [header] + (describing.map { [$0] } ?? []) + notes
        return MCPToolOutcome(
            text: (preamble + ["", joined.text]).joined(separator: "\n"),
            structured: .object(structured)
        )
    }

    /// Раздел файла целиком, а не страница неизвестно чего.
    ///
    /// Смещения — мерка машинная: агент, читающий «куски 200–203», не знает,
    /// что именно прочитал и кончилась ли мысль. Раздел — единица, о которой
    /// можно рассуждать и которую можно назвать человеку.
    private func fileSection(
        _ parsed: ParsedFile, heading: String, limits: MCPOutputLimits
    ) async throws -> MCPToolOutcome {
        let found = try await fileChunks(parsed)
        let path = found.path.isEmpty ? Self.storedPath(of: found.answer.documents) : found.path
        // Совпадение по началу пути: «Общие положения» берёт и свои
        // подразделы, а полный путь — только их.
        // Тем же правилом, что и карта: кусок без заголовка идёт
        // в раздел, внутри которого лежит, а не в «до первого заголовка».
        // Иначе карта обещает раздел из шести кусков, а отбор отдаёт пять.
        let headings = Self.effectiveHeadings(of: found.answer.documents)
        // Спрошенное имя приводится к тому же виду, что и имена на карте:
        // неразрывный пробел и перевод строки внутри заголовка агенту с
        // экрана не видны, и перепечатанное имя не совпадало знак в знак
        // с разделом, который карта только что назвала.
        let asked = Self.typeableHeading(heading)
        let picked = zip(found.answer.documents, headings)
            .filter { $0.1 == asked || $0.1.hasPrefix(asked + " > ") }
        let wanted = picked.map(\.0)
        // Есть ли внутри что делить: у раздела, где все куски под одним
        // заголовком, карта вернёт его же одной строкой, и звать её оттуда
        // некуда.
        let hasSubsections = picked.contains { $0.1 != asked }
        var structured: [String: JSONValue] = [
            "collection": .string(parsed.request.collection),
            "file": .string(path),
            "heading": .string(asked),
        ]
        // Отпечаток — как у чтения по порядку и у карты: раздел читается
        // страницами, и продолжение не должно зависеть от того, сумел ли
        // агент правильно перепечатать путь.
        if let fingerprint = parsed.fingerprint ?? Self.storedFingerprint(of: found.answer.documents) {
            structured["fileId"] = .string(fingerprint)
        }
        // Файла нет вовсе — и сказать надо это. «В файле нет такого раздела»
        // уводит агента искать имя раздела, когда испорчен путь, а имя файла
        // в этой пометке ещё и пустое: взять его неоткуда.
        guard !found.answer.documents.isEmpty else {
            structured["documents"] = .array([])
            if path.isEmpty { structured["file"] = .string(parsed.path) }
            let missing = await fileNotFound(parsed)
            if !missing.similar.isEmpty {
                structured["similarFiles"] = .array(missing.similar.map(JSONValue.string))
            }
            return MCPToolOutcome(
                text: missing.lines.joined(separator: "\n"), structured: .object(structured)
            )
        }
        // Размер файла известен, как только файл найден, — значит стоит во
        // всех ветках: клиент не должен гадать, значит ли отсутствие поля
        // «не посчитали».
        if let total = found.answer.total { structured["totalChunks"] = .int(total) }
        // Где документ лежит целиком — до всех выходов, включая «смещение
        // за концом»: тот, кто промахнулся, первым и нуждается в этом пути.
        // Но не раньше, чем файл найден: искать путь для несуществующего
        // файла — ход на главный поток впустую.
        if let onDisk = await localFile(metadata: found.answer.documents.first?.metadata) {
            structured["sourcePath"] = .string(onDisk.path)
            if let bytes = onDisk.bytes { structured["sourceBytes"] = .int(bytes) }
        }
        guard !wanted.isEmpty else {
            structured["documents"] = .array([])
            // Совет «позови outline» здесь был советом в пустоту: имя агент
            // оттуда и взял. Показываем ближайшие имена — как похожие пути
            // на промах по файлу.
            let missing = Self.sectionNotFound(file: path, heading: asked, among: headings)
            if !missing.nearest.isEmpty {
                structured["nearestSections"] = .array(missing.nearest.map(JSONValue.string))
            }
            return MCPToolOutcome(
                text: missing.lines.joined(separator: "\n"), structured: .object(structured)
            )
        }
        // Смещение считается **внутри раздела**, а не в файле: раздел на
        // тридцать семь кусков в ответ не влезает, и без этого дочитать его
        // было нечем — ответ советовал «возьмите остальное», а параметра для
        // этого не было ни одного, и повторный вызов отдавал те же куски.
        let within = parsed.sectionOffset
        // Окно — то же, что у чтения по порядку: схема обещает, что «limit»
        // с «heading» работает, и обещание должно исполняться.
        let page = within >= wanted.count
            ? []
            : Array(wanted.dropFirst(within).prefix(parsed.sectionLimit))
        guard !page.isEmpty else {
            structured["documents"] = .array([])
            structured["chunksInSection"] = .int(wanted.count)
            structured["offset"] = .int(within)
            structured["hasMore"] = .bool(false)
            structured["sectionFitsInOneAnswer"] = .bool(false)
            return MCPToolOutcome(
                text: "The section «\(asked)» of «\(path)» holds \(EnglishCount.grouped(wanted.count, "chunk", "chunks")), and offset \(within.plainDigits) is already past its end.",
                structured: .object(structured)
            )
        }
        // Тексты — только у страницы. Обход ради границ раздела шёл
        // без них: тянуть текст всего файла ради пяти кусков — та же цена,
        // от которой спасает оглавление.
        let withText = try await Self.textsRestored(
            for: page, request: parsed.request, backend: backend
        )
        // Общие метаданные — один раз на ответ, а не на каждый кусок.
        // Блок уезжает вместе с текстом, значит и платит из того же бюджета:
        // вынести повтор и не заплатить за вынесенное — это не экономия,
        // а та же дыра, что у зеркал.
        let projection = Self.withoutRepeatedMetadata(withText, asked: parsed.fields)
        // Приговор, заголовок и пометки уезжают вместе с кусками и платят из
        // того же бюджета. Числа в них взяты по верхней оценке: они
        // могут стать только короче, а строки — те же самые, собранные теми
        // же строителями, что и в самом ответе.
        let overhead = MCPDocumentRendering.overhead(
            header: (Self.sectionVerdict(
                section: wanted.count, shown: page.count,
                left: wanted.count, calls: wanted.count, hasSubsections: true
            ) + [Self.sectionHeader(
                path: path, heading: asked, shown: page.count,
                section: wanted.count, from: within
            )]).joined(separator: "\n"),
            notes: [Self.sectionContinueNote(
                section: wanted.count, shown: page.count, from: within, next: wanted.count
            )]
                + (projection.note.map { [$0] } ?? [])
                + (parsed.limitNote.map { [$0] } ?? [])
                // Пометка о непредсказуемом порядке — тоже обвязка, и условие
                // её известно до рендера. Без неё файл длиннее
                // предела упорядочивания вёз ~300 знаков мимо бюджета.
                + (found.answer.orderUnavailable ? [Self.unorderedSectionNote] : [])
        )
        let rendered = MCPDocumentRendering.render(
            withText, limits: limits, fields: projection.fields,
            budget: max(1, limits.responseCharacters - Self.sharedMetadataCost(projection)),
            reserve: overhead,
            vocabulary: .chunks
        )
        if !projection.shared.isEmpty {
            structured["sharedMetadata"] = .object(projection.shared.mapValues(\.json))
        }
        var notes = rendered.notes
        if let note = projection.note { notes.append(note) }
        if found.answer.orderUnavailable { notes.append(Self.unorderedSectionNote) }
        if let limitNote = parsed.limitNote { notes.insert(limitNote, at: 0) }
        let readSoFar = within + rendered.shown
        if readSoFar < wanted.count {
            notes.append(Self.sectionContinueNote(
                section: wanted.count, shown: rendered.shown, from: within, next: readSoFar
            ))
            structured["nextOffset"] = .int(readSoFar)
            structured["hasMore"] = .bool(true)
        } else {
            structured["hasMore"] = .bool(false)
        }
        structured["documents"] = .array(rendered.documents)
        structured["chunksInSection"] = .int(wanted.count)
        structured["offset"] = .int(within)

        // Приговор и разделу, а не только файлу целиком.
        //
        // Живой случай: раздел «Общие положения» — 47 кусков, в ответ влезло
        // четыре, и пометка «did not fit whole» лежала внизу среди прочих.
        // Агент прочитал восемь кусков из сорока семи и пошёл дальше; так
        // двенадцать разделов подряд — 48 кусков из 1281, и по ним разбор
        // требований. У чтения по порядку на этот случай приговор первой
        // строкой стоит с; до раздела его не довели.
        var verdict: [String] = []
        // Считается **оставшееся**, а не весь раздел. Иначе на последней
        // странице из сорока семи ответ открывался бы словами «читать целиком
        // — шестнадцать вызовов» тому, кто дочитал сорок четыре, и стоял бы
        // этот приговор первой строкой — громче, чем «hasMore: false» в том
        // же ответе.
        let leftToRead = max(0, wanted.count - readSoFar)
        let callsToFinish = rendered.shown > 0
            ? (leftToRead + rendered.shown - 1) / rendered.shown
            : 0
        structured["sectionFitsInOneAnswer"] = .bool(rendered.shown >= wanted.count)
        if callsToFinish > 0 { structured["callsToFinishSection"] = .int(callsToFinish) }
        if callsToFinish >= Self.wholeFileCallBudget {
            verdict += Self.sectionVerdict(
                section: wanted.count, shown: rendered.shown, left: leftToRead,
                calls: callsToFinish, hasSubsections: hasSubsections
            )
        }
        if !notes.isEmpty { structured["notes"] = .array(notes.map(JSONValue.string)) }
        let header = Self.sectionHeader(
            path: path, heading: asked, shown: rendered.shown,
            section: wanted.count, from: within
        )
        return MCPToolOutcome(
            text: (verdict + [header] + rendered.lines + notes).joined(separator: "\n"),
            structured: .object(structured)
        )
    }

    /// `get_file` — чанки одного файла по порядку.
    private func file(_ parsed: ParsedFile, limits: MCPOutputLimits) async throws -> MCPToolOutcome {
        if parsed.wantsOutline { return try await fileOutline(parsed, limits: limits) }
        if parsed.wantsWholeText { return try await fileWholeText(parsed, limits: limits) }
        if let heading = parsed.heading {
            return try await fileSection(parsed, heading: heading, limits: limits)
        }
        let found = try await fileChunks(parsed)
        let answer = found.answer
        // Файл, спрошенный отпечатком, называется в ответе путём: агент
        // покажет человеку документ, а не шестнадцать знаков.
        let path = found.path.isEmpty ? Self.storedPath(of: answer.documents) : found.path
        let fingerprint = parsed.fingerprint ?? Self.storedFingerprint(of: answer.documents)
        // То же, что и у раздела: повтор одного и того же блока метаданных
        // на каждом куске — место, отнятое у текста.
        let projection = Self.withoutRepeatedMetadata(answer.documents, asked: parsed.fields)
        // Путь на диске нужен **до** рендера: он уезжает в приговоре, и
        // приговор платит из того же бюджета, что и куски. На живом
        // пути в сто знаков он уходит туда дважды.
        let onDisk = await localFile(metadata: answer.documents.first?.metadata)
        // Обвязка ответа — приговор, заголовок и пометки — по верхней оценке
        // чисел: короче они стать могут, длиннее нет.
        let pageOverhead = MCPDocumentRendering.overhead(
            header: (Self.pageVerdict(
                total: answer.total ?? answer.documents.count,
                shown: answer.documents.count,
                left: answer.total ?? answer.documents.count,
                calls: answer.total ?? answer.documents.count,
                onDiskPath: onDisk?.path
            ) + [Self.pageHeader(
                path: path, shown: answer.documents.count,
                from: parsed.request.offset, total: answer.total
            )]).joined(separator: "\n"),
            notes: [Self.pageContinueNote(next: answer.total ?? answer.documents.count)]
                + (projection.note.map { [$0] } ?? [])
                + (parsed.limitNote.map { [$0] } ?? [])
                + (answer.orderUnavailable ? [Self.unorderedPageNote] : [])
        )
        let rendered = MCPDocumentRendering.render(
            answer.documents, limits: limits, fields: projection.fields,
            budget: max(1, limits.responseCharacters - Self.sharedMetadataCost(projection)),
            reserve: pageOverhead,
            vocabulary: .chunks
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

        if !projection.shared.isEmpty {
            structured["sharedMetadata"] = .object(projection.shared.mapValues(\.json))
        }
        var notes = rendered.notes
        if let note = projection.note { notes.append(note) }
        if let limitNote = parsed.limitNote { notes.insert(limitNote, at: 0) }
        if answer.orderUnavailable { notes.append(Self.unorderedPageNote) }
        if more {
            notes.append(Self.pageContinueNote(next: next))
        }
        if !notes.isEmpty { structured["notes"] = .array(notes.map(JSONValue.string)) }

        // «4 chunks starting at 0, 1281 in total» — это правда, поданная как
        // справка, и агент читает её как успех. Живой случай: прочитал
        // двадцать три куска из 1281 и написал по ним разбор требований, не
        // заметив, что видел один процент. Сказать «столько не поместится»
        // обязано приложение: полагаться на то, что агент сам поделит одно
        // число на другое, значит полагаться на случай.
        if let onDisk {
            structured["sourcePath"] = .string(onDisk.path)
            if let bytes = onDisk.bytes { structured["sourceBytes"] = .int(bytes) }
        }

        var verdict: [String] = []
        // Поле ставится всегда, когда о полном размере известно: клиент,
        // читающий структурированный ответ, не должен гадать, значит ли
        // отсутствие поля «влезает» или «не посчитали».
        //
        // И значит оно ровно то, что обещает именем: **весь файл в этом
        // ответе**, а не «читать недорого». Прежде в ветке «вызовов меньше
        // десяти» стояло `true` — то есть файл на двадцать кусков, показанный
        // по четыре, отвечал клиенту «влезает целиком», приговор при этом
        // молчал, и число вызовов не ставилось вовсе. Порог решает, надо
        // ли говорить вслух, а не известна ли цена.
        // Пропавшему файлу поле не ставится вовсе: `0 >= 0` — правда, но
        // «весь файл в этом ответе» о файле, которого в коллекции нет, —
        // не правда ни в каком смысле. Смещение за концом — другое дело:
        // там `total` известен и больше нуля, и ответ честно говорит «нет».
        if let total = answer.total, total > 0 {
            let whole = rendered.shown >= total
            structured["fitsInOneAnswer"] = .bool(whole)
            // Считается **оставшееся**, а не весь файл. закрыл это у
            // раздела и не перенёс сюда: на последней странице из 1281 куска
            // ответ открывался словами «читать так — двести пятьдесят семь
            // вызовов» тому, кто дочитал 1276, и советовал начать заново.
            let readSoFar = parsed.request.offset + rendered.shown
            let leftToRead = max(0, total - readSoFar)
            let callsToFinish = rendered.shown > 0
                ? (leftToRead + rendered.shown - 1) / rendered.shown
                : 0
            if callsToFinish > 0 { structured["callsToFinish"] = .int(callsToFinish) }
            if !whole, rendered.shown > 0 {
                if callsToFinish >= Self.wholeFileCallBudget {
                    // Ни слова о токенах: по пяти прочитанным кускам их не
                    // сосчитать — на титульных страницах они мелкие, и оценка
                    // разошлась с точной на треть (342 027 против 500 625).
                    // Число чанков и вызовов известно точно, его и называем,
                    // а вес отдаёт оглавление, где сложены все куски.
                    verdict += Self.pageVerdict(
                        total: total, shown: rendered.shown, left: leftToRead,
                        calls: callsToFinish, onDiskPath: onDisk?.path
                    )
                }
            }
        }

        guard !answer.documents.isEmpty else {
            // Файл есть, а страница пуста — значит смещение ушло за конец.
            // Сказать тут «файла нет» неверно вдвойне: в том же ответе стоит
            // total, а совет сменить отпечаток на путь уводит агента чинить
            // несуществующую беду. Чтение по разделу это говорит правильно
            // с, чтение по порядку молчало.
            if let total = answer.total, total > 0, parsed.request.offset >= total {
                let named = path.isEmpty ? (fingerprint ?? parsed.path) : path
                let lines = [
                    "The file «\(named)» holds \(EnglishCount.grouped(total, "chunk", "chunks")), and offset \(parsed.request.offset.plainDigits) is already past its end.",
                ] + notes
                return MCPToolOutcome(text: lines.joined(separator: "\n"), structured: .object(structured))
            }
            let missing = await fileNotFound(parsed)
            if !missing.similar.isEmpty {
                structured["similarFiles"] = .array(missing.similar.map(JSONValue.string))
            }
            return MCPToolOutcome(
                text: (missing.lines + notes).joined(separator: "\n"), structured: .object(structured)
            )
        }

        let header = Self.pageHeader(
            path: path, shown: rendered.shown, from: parsed.request.offset, total: answer.total
        )

        // Приговор идёт первой строкой, а не пометкой внизу.
        let text = (verdict + [header] + rendered.lines + notes).joined(separator: "\n")
        return MCPToolOutcome(text: text, structured: .object(structured))
    }

    /// Файл на диске — только тому, кому его путь можно назвать.
    private func localFile(metadata: ChromaMetadata?) async -> MCPFileOnDisk? {
        guard MCPCallContext.revealsLocalPaths else { return nil }
        return await backend.fileOnDisk(metadata: metadata)
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
                orderedByChunkIndex: parsed.request.orderedByChunkIndex,
                needsText: parsed.request.needsText
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
            filter.conditions = [MetadataCondition(field: "file_name", op: .equals, value: variant, valueIsText: true)]
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
