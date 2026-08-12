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

    public init(
        summary: MCPCollectionSummary,
        fields: [MCPFieldDescription],
        hasSchema: Bool,
        allowsExtraFields: Bool
    ) {
        self.summary = summary
        self.fields = fields
        self.hasSchema = hasSchema
        self.allowsExtraFields = allowsExtraFields
    }

    public var json: JSONValue {
        .object([
            "collection": summary.json,
            "hasSchema": .bool(hasSchema),
            "allowsExtraFields": .bool(allowsExtraFields),
            "fields": .array(fields.map(\.json)),
        ])
    }
}

/// Поиск, как его просит агент.
///
/// Текст, а не вектор — в этом весь смысл этапа: эмбеддинг считает приложение
/// моделью, привязанной к коллекции, и агент физически не может обратиться
/// к базе вектором от чужой модели.
public struct MCPSearchRequest: Sendable {
    public let collection: String
    public let query: String
    public let nResults: Int
    public let filter: DocumentFilter?
    /// Умный поиск для этого ключа: `nil` — как настроено у коллекции.
    /// Решает владелец базы в правах ключа, а не агент: иначе настройка,
    /// которую человек выключил, включалась бы обратно чужим запросом.
    public let smartSearch: Bool?

    public init(
        collection: String, query: String, nResults: Int, filter: DocumentFilter?,
        smartSearch: Bool? = nil
    ) {
        self.collection = collection
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

    public init(collection: String, ids: [String], filter: DocumentFilter?, limit: Int, offset: Int) {
        self.collection = collection
        self.ids = ids
        self.filter = filter
        self.limit = limit
        self.offset = offset
    }
}

public struct MCPDocumentsAnswer: Sendable {
    public let documents: [MCPDocumentPayload]
    /// Есть ли что-то за этой страницей. Устанавливается по запросу на один
    /// документ больше потолка: иначе «ровно limit документов» и «дальше есть
    /// ещё» неотличимы, и агент останавливается на середине коллекции.
    public let hasMore: Bool

    public init(documents: [MCPDocumentPayload], hasMore: Bool) {
        self.documents = documents
        self.hasMore = hasMore
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
        title: "Список коллекций",
        description: """
        Возвращает коллекции ChromaDB, к которым открыт доступ этому ключу. \
        Применяй первым, когда не знаешь, где искать: имена коллекций нужны \
        всем остальным инструментам. Для каждой коллекции отдаются имя, число \
        документов, модель эмбеддинга и метрика расстояния. Коллекции вне \
        списка доступа не показываются вовсе — их отсутствие не значит, что \
        их нет в базе. Создавать и удалять коллекции через MCP нельзя.
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
        title: "Описание коллекции",
        description: """
        Рассказывает, как устроена одна коллекция: какие поля метаданных в ней \
        есть, какого они типа, какие обязательны и какие значения в них \
        встречаются. Применяй перед тем, как задавать фильтр в поиске: без \
        этого фильтр строится наугад и чаще всего возвращает пустую выдачу. \
        Если у коллекции нет схемы, поля всё равно перечислены — по тому, что \
        реально записано в документах.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "collection": .object([
                    "type": .string("string"),
                    "description": .string("Имя коллекции из list_collections."),
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
        Фильтр по метаданным в синтаксисе ChromaDB: {"поле": {"$eq": значение}}. \
        Поддерживаются $eq, $ne, $gt, $gte, $lt, $lte, $in, $nin, а также $and и $or \
        со списком условий. Имена полей и их типы бери из describe_collection: \
        сравнение с числом 2024 и со строкой «2024» — разные условия, и второе \
        вернёт пустую выдачу.
        """),
    ])

    private static let containsProperty = JSONValue.object([
        "type": .string("string"),
        "description": .string("""
        Подстрока, которая обязана встретиться в тексте документа. \
        Регистр учитывать не нужно: проверяются обычные варианты написания \
        (как передано, строчными, С Заглавной, а для коротких слов и ПРОПИСНЫМИ), \
        так что «astra» найдёт «Astra». Написание вроде «AsTrA» так не найдётся — \
        база сравнивает подстроки буквально.
        """),
    ])

    public static let search = MCPToolDefinition(
        name: "search",
        title: "Поиск по смыслу",
        description: """
        Ищет документы по смыслу в одной коллекции. Принимай как основной способ \
        найти нужное: запрос пишется обычной фразой или вопросом, вектор считает \
        приложение моделью, привязанной к коллекции, — передавать эмбеддинг не нужно \
        и нельзя. Результаты идут от ближайшего к дальнему; расстояние возвращается \
        вместе с метрикой коллекции, меньше расстояние — ближе по смыслу. \
        К результату может прилагаться раздел-родитель, помеченный как контекст: \
        он не занимает место среди запрошенных результатов. \
        Длинные документы обрезаются с явной пометкой — полный текст берётся через \
        get_documents по тому же id. Искать сразу по нескольким коллекциям нельзя: \
        вызывай по одной. Коллекции вне списка доступа не ищутся.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "collection": .object([
                    "type": .string("string"),
                    "description": .string("Имя коллекции из list_collections."),
                ]),
                "query": .object([
                    "type": .string("string"),
                    "description": .string("""
                    Текст запроса: фраза или вопрос на естественном языке. \
                    Отдельные ключевые слова работают хуже — поиск смысловой.
                    """),
                ]),
                "n_results": .object([
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "description": .string("""
                    Сколько результатов вернуть. По умолчанию 5; потолок задан правами \
                    ключа (обычно 10). Запрос сверх потолка не отвергается — выдача \
                    урезается, и об этом сказано в ответе.
                    """),
                ]),
                "filter": filterProperty,
                "contains": containsProperty,
            ]),
            "required": .array([.string("collection"), .string("query")]),
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

    public static let getDocuments = MCPToolDefinition(
        name: "get_documents",
        title: "Получить документы",
        description: """
        Отдаёт документы целиком — по списку идентификаторов или по фильтру, \
        без поиска по смыслу. Применяй, когда id уже известны: например, чтобы \
        дочитать документ, текст которого search обрезал. Годится и для \
        постраничного просмотра коллекции — тогда фильтр не нужен, а страницы \
        листаются параметром offset. Если ищешь «что-то похожее на», это не тот \
        инструмент: расстояний здесь нет, порядок произвольный, бери search. \
        Векторы не возвращаются никогда.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "collection": .object([
                    "type": .string("string"),
                    "description": .string("Имя коллекции из list_collections."),
                ]),
                "ids": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("""
                    Идентификаторы документов. Когда список задан, фильтр и offset \
                    не применяются: спрошено конкретное, оно и отдаётся.
                    """),
                ]),
                "filter": filterProperty,
                "contains": containsProperty,
                "limit": .object([
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "description": .string("""
                    Сколько документов вернуть. По умолчанию 5, потолок тот же, \
                    что у поиска.
                    """),
                ]),
                "offset": .object([
                    "type": .string("integer"),
                    "minimum": .int(0),
                    "description": .string("Сколько документов пропустить — для листания страницами."),
                ]),
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

    public static let addDocuments = MCPToolDefinition(
        name: "add_documents",
        title: "Добавить документы",
        description: """
        Записывает документы в коллекцию. Присылай текст — вектор считает \
        приложение моделью, привязанной к коллекции. Разбиение текста на части \
        **не выполняется**: что прислано одним документом, то и станет одним \
        документом с одним вектором, поэтому длинный текст дели на осмысленные \
        куски сам. Текст длиннее контекста модели будет отвергнут с указанием, \
        какой именно документ не прошёл. Идентификатор можно не задавать — \
        приложение придумает его само; заданный, но уже занятый, отвергается \
        целиком: перезаписи не будет, существующий документ этот инструмент \
        не трогает. Метаданные — плоский объект: строки, числа, булевы; \
        вложенных объектов и списков база не принимает. Если у коллекции есть \
        схема, метаданные проверяются по ней. Каждому записанному документу \
        приложение само проставляет поле origin со значением «mcp» — по нему \
        видно, что документ пришёл от агента.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "collection": .object([
                    "type": .string("string"),
                    "description": .string("Имя коллекции из list_collections."),
                ]),
                "documents": .object([
                    "type": .string("array"),
                    "minItems": .int(1),
                    "description": .string("Документы, каждый — объект с полями text, id (необязательно) и metadata (необязательно)."),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "text": .object([
                                "type": .string("string"),
                                "description": .string("Текст документа. Он же и будет проиндексирован."),
                            ]),
                            "id": .object([
                                "type": .string("string"),
                                "description": .string("Идентификатор. Не задан — приложение придумает свой."),
                            ]),
                            "metadata": .object([
                                "type": .string("object"),
                                "description": .string("Плоский объект: строки, числа, булевы. Поля бери из describe_collection."),
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
        title: "Удалить документы",
        description: """
        Удаляет документы по явному списку идентификаторов. Удаления по фильтру \
        здесь нет намеренно: одно неточное условие сносит половину коллекции, \
        а отменить это нечем — если нужно удалить группу, сначала найди её \
        через get_documents с тем же фильтром, посмотри, что нашлось, и передай \
        сюда идентификаторы. Требует отдельного права на удаление, помимо права \
        записи: ключ, которому разрешена запись, удалять по умолчанию не может. \
        Идентификаторы, которых в коллекции нет, не считаются ошибкой — они \
        перечисляются в ответе отдельно. Коллекции этот инструмент не удаляет \
        и не может: через MCP их нельзя ни создать, ни удалить.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "collection": .object([
                    "type": .string("string"),
                    "description": .string("Имя коллекции из list_collections."),
                ]),
                "ids": .object([
                    "type": .string("array"),
                    "minItems": .int(1),
                    "items": .object(["type": .string("string")]),
                    "description": .string("Идентификаторы документов, которые нужно удалить."),
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

    /// Все инструменты сервера в постоянном порядке.
    ///
    /// Порядок именно постоянный, а не «какой получится»: спецификация просит
    /// детерминированный список, потому что на нём клиент строит кэш, а модель
    /// — свой контекст.
    public static let all: [MCPToolDefinition] = [
        listCollections, describeCollection, search, getDocuments, addDocuments, deleteDocuments,
    ]

    /// Инструменты, которым коллекция обязательна. Список, а не флаг у
    /// определения: он же и отвечает на вопрос «по чему проверять whitelist».
    public static let collectionRequired: Set<String> = [
        describeCollection.name, search.name, getDocuments.name, addDocuments.name,
        deleteDocuments.name,
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

    public init(
        backend: any MCPToolBackend,
        access: AccessController,
        isReadOnlyServer: @escaping @Sendable () -> Bool = { false },
        audit: (@Sendable (AuditEntry) -> Void)? = nil
    ) {
        self.backend = backend
        self.access = access
        self.isReadOnlyServer = isReadOnlyServer
        self.audit = audit
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
                + String(localized: "… [текст параметров обрезан в журнале]")
        }
        audit(AuditEntry(
            client: clientName ?? key.map { "\(ClientKey.prefix(of: $0))…" } ?? String(localized: "без ключа"),
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
                message: "Неизвестный инструмент: \(name)"
            ))
        }

        // Коллекция нужна до проверки прав: без неё whitelist проверить не по
        // чему, а после — уже поздно.
        // Пустая строка — это тоже «не указана»: проверка на `nil` её
        // пропускала, и вызов уходил дальше без имени коллекции.
        let collection = arguments?["collection"]?.stringValue
        if MCPToolCatalogue.collectionRequired.contains(tool.name),
           collection?.isEmpty != false {
            return .failure(.invalidParams("Не указана коллекция: параметр «collection» обязателен."))
        }

        // Вектор не принимается ни одним инструментом (DoD этапа 7). Схема его
        // и так не описывает, но молчаливо выброшенный параметр агент примет
        // за применённый: он обязан узнать, что запрос ушёл не таким, как он
        // его составил.
        if let rejected = Self.vectorParameter(in: arguments) {
            return .success(MCPToolOutcome.failure(String(
                localized: "Параметр «\(rejected)» не поддерживается: векторы через MCP не передаются. Пиши запрос текстом в «query» — эмбеддинг посчитает ChromaDB Manager моделью, привязанной к коллекции."
            )).result)
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
            let outcome = MCPToolOutcome.failure(decision.refusal ?? "Отказано.").result
            record(
                tool: tool, key: key, clientName: decision.clientName, collection: collection,
                arguments: arguments, note: decision.refusal,
                responseBytes: outcome.jsonString?.utf8.count ?? 0, started: started
            )
            return .success(outcome)
        }

        let limits = MCPOutputLimits.forClient(client.permissions)
        // Вызов записывается в журнал независимо от того, чем он кончится:
        // упавшая запись — то самое событие, ради которого журнал и ведут.
        // И именно как упавшая: «документов: 1» у отказа означало бы, что
        // документ записан, а его нет.
        // Что записать в журнал: причина отказа или итог выполненного вызова.
        // У операции записи он обязателен — без него в журнале стоит «была
        // запись», и восстановить по нему, что стало с базой, нельзя.
        var auditNote: String? = writing.map {
            String(localized: "документов: \($0.documents.count.plainDigits)")
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
                return answered(try await listCollections(client: client).result)
            case MCPToolCatalogue.describeCollection.name:
                return answered(try await describe(collection: collection ?? "", client: client).result)
            case MCPToolCatalogue.search.name:
                switch Self.searchRequest(
                    collection ?? "", arguments, limits: limits,
                    smartSearch: client.permissions.smartSearch
                ) {
                case .failure(let error): return refused(error)
                case .success(let parsed):
                    return answered(try await search(parsed, limits: limits).result)
                }
            case MCPToolCatalogue.getDocuments.name:
                switch Self.documentsRequest(collection ?? "", arguments, limits: limits) {
                case .failure(let error): return refused(error)
                case .success(let parsed):
                    return answered(try await documents(parsed, limits: limits).result)
                }
            case MCPToolCatalogue.addDocuments.name:
                guard let writing else {
                    return refused(.invalidParams("Не переданы документы: параметр «documents» обязателен."))
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
                    message: "Инструмент «\(name)» объявлен, но не реализован"
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
            auditNote = error.localizedDescription
            return answered(MCPToolOutcome.failure(
                "Инструмент «\(name)» не отработал: \(error.localizedDescription)"
            ).result)
        }
    }

    private func listCollections(client: ExternalClient) async throws -> MCPToolOutcome {
        let collections = try await backend.collections(allowed: client.permissions.collections)
        let structured = JSONValue.object(["collections": .array(collections.map(\.json))])
        guard !collections.isEmpty else {
            // Не ошибка: ключ может быть заведён без единой коллекции. Но
            // молчаливый пустой список модель истолкует как «база пуста».
            return MCPToolOutcome(
                text: "Ключу не открыта ни одна коллекция. Доступ настраивается в ChromaDB Manager, на экране «Клиенты».",
                structured: structured
            )
        }
        let lines = collections.map { collection -> String in
            var parts = ["«\(collection.name)»"]
            if let count = collection.documentCount { parts.append("документов: \(count)") }
            if let model = collection.model { parts.append("модель: \(model)") }
            if let metric = collection.metric { parts.append("метрика: \(metric)") }
            return parts.joined(separator: ", ")
        }
        return MCPToolOutcome(
            text: (["Доступные коллекции:"] + lines).joined(separator: "\n"),
            structured: structured
        )
    }

    private func describe(collection: String, client: ExternalClient) async throws -> MCPToolOutcome {
        let description = try await backend.describe(collection: collection)
        var lines = ["Коллекция «\(description.summary.name)»"]
        if let count = description.summary.documentCount { lines.append("документов: \(count)") }
        if let model = description.summary.model { lines.append("модель: \(model)") }
        if description.fields.isEmpty {
            lines.append("Полей метаданных не найдено — фильтровать не по чему.")
        } else {
            lines.append(description.hasSchema
                ? "Поля метаданных (по схеме коллекции):"
                : "Поля метаданных (схемы нет, перечислено то, что реально записано):")
            lines += description.fields.map { field in
                var line = "  \(field.key) — \(field.type)"
                if field.isRequired { line += ", обязательное" }
                if !field.examples.isEmpty {
                    line += "; например: " + field.examples.prefix(3).joined(separator: ", ")
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
    }

    private struct ParsedDocuments {
        let request: MCPDocumentsRequest
        let limitNote: String?
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

        if let raw = arguments?["filter"], raw != .null {
            guard let object = raw.objectValue else {
                return .failure(.invalidParams("Параметр «filter» должен быть объектом: {\"поле\": {\"$eq\": значение}}."))
            }
            if !object.isEmpty {
                guard let text = raw.jsonString else {
                    return .failure(.invalidParams("Параметр «filter» не удалось прочитать как JSON."))
                }
                filter.rawWhereJSON = text
                used = true
            }
        }

        if let contains = arguments?["contains"], contains != .null {
            guard let text = contains.stringValue else {
                return .failure(.invalidParams("Параметр «contains» должен быть строкой."))
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

    /// Целое из параметров — или отказ, называющий параметр.
    private static func integer(
        _ arguments: JSONValue?, _ name: String
    ) -> Result<Int?, JSONRPCError> {
        guard let value = arguments?[name], value != .null else { return .success(nil) }
        guard let number = value.intValue else {
            return .failure(.invalidParams("Параметр «\(name)» должен быть целым числом."))
        }
        return .success(number)
    }

    private static func searchRequest(
        _ collection: String, _ arguments: JSONValue?, limits: MCPOutputLimits,
        smartSearch: Bool?
    ) -> Result<ParsedSearch, JSONRPCError> {
        guard let query = arguments?["query"]?.stringValue,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.invalidParams("Не указан текст запроса: параметр «query» обязателен и не может быть пустым."))
        }

        let requested: Int?
        switch integer(arguments, "n_results") {
        case .failure(let error): return .failure(error)
        case .success(let value): requested = value
        }
        let resolved = limits.resolved(requested: requested)

        switch filter(arguments) {
        case .failure(let error):
            return .failure(error)
        case .success(let filter):
            return .success(ParsedSearch(
                request: MCPSearchRequest(
                    collection: collection, query: query,
                    nResults: resolved.count, filter: filter,
                    smartSearch: smartSearch
                ),
                limitNote: resolved.note
            ))
        }
    }

    private static func documentsRequest(
        _ collection: String, _ arguments: JSONValue?, limits: MCPOutputLimits
    ) -> Result<ParsedDocuments, JSONRPCError> {
        var ids: [String] = []
        if let raw = arguments?["ids"], raw != .null {
            guard let array = raw.arrayValue else {
                return .failure(.invalidParams("Параметр «ids» должен быть списком строк."))
            }
            ids = array.compactMap(\.stringValue)
            guard ids.count == array.count else {
                return .failure(.invalidParams("Параметр «ids» должен содержать только строки — идентификаторы документов."))
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
            note = String(
                localized: "Запрошено документов: \(ids.count.plainDigits), отдано \(limits.ceiling.plainDigits) — это потолок, заданный правами ключа. Остальные — следующим вызовом."
            )
        }

        let offset: Int
        switch integer(arguments, "offset") {
        case .failure(let error): return .failure(error)
        case .success(let value): offset = max(0, value ?? 0)
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
                limitNote: note
            ))
        }
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
            return .failure(.invalidParams("Документ \(documentNumber.plainDigits): «metadata» должен быть объектом."))
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
                    "Документ \(documentNumber.plainDigits), поле «\(key)»: метаданные ChromaDB — плоские, вложенные объекты и списки не принимаются. Сверни значение в строку или разложи по отдельным полям."
                ))
            }
        }
        return .success(result.isEmpty ? nil : result)
    }

    private static func addRequest(
        _ collection: String, _ arguments: JSONValue?
    ) -> Result<MCPAddRequest, JSONRPCError> {
        guard let raw = arguments?["documents"], raw != .null else {
            return .failure(.invalidParams("Не переданы документы: параметр «documents» обязателен."))
        }
        guard let array = raw.arrayValue else {
            return .failure(.invalidParams("Параметр «documents» должен быть списком объектов."))
        }
        guard !array.isEmpty else {
            return .failure(.invalidParams("Список «documents» пуст — записывать нечего."))
        }

        var documents: [MCPIncomingDocument] = []
        for (index, item) in array.enumerated() {
            let number = index + 1
            guard item.objectValue != nil else {
                return .failure(.invalidParams("Документ \(number.plainDigits) должен быть объектом с полем «text»."))
            }
            guard let text = item["text"]?.stringValue,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(.invalidParams("Документ \(number.plainDigits): поле «text» обязательно и не может быть пустым."))
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
            return .failure(.invalidParams("В одном вызове повторяются идентификаторы — база оставила бы только первый документ."))
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

        var lines = [String(
            localized: "Записано в «\(request.collection)»: \(RussianCount.grouped(answer.ids.count, "документ", "документа", "документов"))."
        )]
        if let model = answer.model {
            lines.append(String(localized: "Векторы посчитаны моделью \(model)."))
        }
        lines.append(String(localized: "Идентификаторы: \(answer.ids.joined(separator: ", "))"))
        if let note = answer.note { lines.append(note) }
        return MCPToolOutcome(text: lines.joined(separator: "\n"), structured: .object(structured))
    }

    private static func deleteRequest(
        _ collection: String, _ arguments: JSONValue?
    ) -> Result<MCPDeleteRequest, JSONRPCError> {
        guard let raw = arguments?["ids"], raw != .null else {
            return .failure(.invalidParams("Не переданы идентификаторы: параметр «ids» обязателен. Удаления по фильтру нет — сначала найди документы через get_documents."))
        }
        guard let array = raw.arrayValue else {
            return .failure(.invalidParams("Параметр «ids» должен быть списком строк."))
        }
        let ids = array.compactMap(\.stringValue)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard ids.count == array.count else {
            return .failure(.invalidParams("Параметр «ids» должен содержать только непустые строки — идентификаторы документов."))
        }
        guard !ids.isEmpty else {
            return .failure(.invalidParams("Список «ids» пуст — удалять нечего."))
        }
        // Фильтр отвергается вслух: агент, чей фильтр молча выбросили, решил
        // бы, что удалилось ровно то, что он описал.
        if arguments?["filter"] != nil || arguments?["contains"] != nil {
            return .failure(.invalidParams("Удаление по фильтру не предоставляется: перечисли идентификаторы в «ids». Найти их можно через get_documents с тем же фильтром."))
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
            lines.append(String(localized: "Из «\(request.collection)» не удалено ничего: ни один из указанных идентификаторов не найден."))
        } else {
            lines.append(String(
                localized: "Удалено из «\(request.collection)»: \(RussianCount.grouped(answer.deleted.count, "документ", "документа", "документов"))."
            ))
            lines.append(String(localized: "Идентификаторы: \(answer.deleted.joined(separator: ", "))"))
        }
        if !answer.missing.isEmpty {
            // Перечислением, а не числом: «удалено 2 из 5» оставляет агента
            // гадать, какие три, и он повторит вызов целиком.
            lines.append(String(localized: "Не найдены и потому не удалены: \(answer.missing.joined(separator: ", "))"))
        }
        if !answer.deleted.isEmpty {
            lines.append(answer.keptInTrash
                ? String(localized: "Копии сохранены в корзине ChromaDB Manager — владелец базы может их вернуть.")
                : String(localized: "Корзина в ChromaDB Manager выключена: удаление окончательное, вернуть документы нечем."))
        }

        var note = answer.deleted.isEmpty
            ? String(localized: "не удалено ничего")
            : String(localized: "удалено: \(answer.deleted.joined(separator: ", "))")
        if !answer.deleted.isEmpty, !answer.keptInTrash {
            note += String(localized: " (корзина выключена — без копий)")
        }
        return (
            MCPToolOutcome(text: lines.joined(separator: "\n"), structured: .object(structured)),
            note
        )
    }

    private func search(_ parsed: ParsedSearch, limits: MCPOutputLimits) async throws -> MCPToolOutcome {
        let answer = try await backend.search(parsed.request)
        let rendered = MCPDocumentRendering.render(
            answer.documents, limits: limits, metric: answer.metric
        )

        var structured: [String: JSONValue] = [
            "collection": .string(parsed.request.collection),
            "query": .string(parsed.request.query),
            "documents": .array(rendered.documents),
        ]
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
            var lines = [String(localized: "По запросу «\(parsed.request.query)» в коллекции «\(parsed.request.collection)» ничего не найдено.")]
            if parsed.request.filter != nil {
                lines.append(String(localized: "Запрос шёл с фильтром — проверь поля и типы значений через describe_collection и попробуй без фильтра."))
            }
            lines += notes
            return MCPToolOutcome(text: lines.joined(separator: "\n"), structured: .object(structured))
        }

        var header = String(
            localized: "Найдено в «\(parsed.request.collection)»: \(RussianCount.grouped(rendered.shown, "документ", "документа", "документов"))"
        )
        if let model = answer.model { header += String(localized: ", модель \(model)") }
        let text = ([header] + rendered.lines + notes).joined(separator: "\n")
        return MCPToolOutcome(text: text, structured: .object(structured))
    }

    private func documents(_ parsed: ParsedDocuments, limits: MCPOutputLimits) async throws -> MCPToolOutcome {
        let answer = try await backend.documents(parsed.request)
        let rendered = MCPDocumentRendering.render(answer.documents, limits: limits)

        var structured: [String: JSONValue] = [
            "collection": .string(parsed.request.collection),
            "documents": .array(rendered.documents),
            "hasMore": .bool(answer.hasMore || rendered.isTruncated),
        ]

        var notes = rendered.notes
        if let limitNote = parsed.limitNote { notes.insert(limitNote, at: 0) }
        if answer.hasMore, parsed.request.ids.isEmpty {
            notes.append(String(
                localized: "За этой страницей есть ещё документы: повтори вызов с offset \((parsed.request.offset + rendered.shown).plainDigits)."
            ))
        }
        if !notes.isEmpty { structured["notes"] = .array(notes.map(JSONValue.string)) }

        guard !answer.documents.isEmpty else {
            var lines = [String(localized: "В коллекции «\(parsed.request.collection)» по этому запросу документов нет.")]
            if !parsed.request.ids.isEmpty {
                lines.append(String(localized: "Ни один из указанных идентификаторов не найден — проверь их написание."))
            }
            lines += notes
            return MCPToolOutcome(text: lines.joined(separator: "\n"), structured: .object(structured))
        }

        let header = String(
            localized: "Из коллекции «\(parsed.request.collection)»: \(RussianCount.grouped(rendered.shown, "документ", "документа", "документов"))"
        )
        let text = ([header] + rendered.lines + notes).joined(separator: "\n")
        return MCPToolOutcome(text: text, structured: .object(structured))
    }
}
