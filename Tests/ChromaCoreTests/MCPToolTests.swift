import XCTest
@testable import ChromaCore

/// §D2.3, D2.5, D2.7 — инструменты и матрица «право × инструмент».
final class MCPToolTests: XCTestCase {
    // MARK: - Стенд

    private struct Backend: MCPToolBackend {
        var collections: [MCPCollectionSummary] = [
            MCPCollectionSummary(name: "заметки", documentCount: 12, model: "bge-m3", metric: "cosine", dimension: 1024),
            MCPCollectionSummary(name: "договоры", documentCount: 300, model: "bge-m3", metric: "cosine", dimension: 1024),
        ]
        var failure: Error?

        func collections(allowed: [String]) async throws -> [MCPCollectionSummary] {
            if let failure { throw failure }
            return collections.filter { allowed.contains($0.name) }
        }

        func describe(collection: String) async throws -> MCPCollectionDescription {
            if let failure { throw failure }
            guard let summary = collections.first(where: { $0.name == collection }) else {
                throw NSError(domain: "тест", code: 1, userInfo: [NSLocalizedDescriptionKey: "нет такой коллекции"])
            }
            return MCPCollectionDescription(
                summary: summary,
                fields: [
                    MCPFieldDescription(
                        key: "year", type: "int", isRequired: true, note: "год документа",
                        examples: ["2024", "2025"]
                    ),
                ],
                hasSchema: true,
                allowsExtraFields: false
            )
        }

        /// Документы, которые «найдёт» поиск. По умолчанию три коротких.
        var hits: [MCPDocumentPayload] = (1...3).map { number in
            MCPDocumentPayload(
                id: "d\(number)",
                text: "текст документа \(number)",
                metadata: ["year": .int(2024)],
                distance: Double(number) / 10
            )
        }
        /// Что инструменты получили последним вызовом — по этому и проверяется,
        /// что потолок применился до обращения к базе, а не после.
        final class Received: @unchecked Sendable {
            var search: MCPSearchRequest?
            var documents: MCPDocumentsRequest?
            var add: MCPAddRequest?
            var delete: MCPDeleteRequest?
        }
        let received = Received()

        func search(_ request: MCPSearchRequest) async throws -> MCPSearchAnswer {
            if let failure { throw failure }
            received.search = request
            return MCPSearchAnswer(
                documents: Array(hits.prefix(request.nResults)),
                metric: "cosine",
                model: "bge-m3"
            )
        }

        func documents(_ request: MCPDocumentsRequest) async throws -> MCPDocumentsAnswer {
            if let failure { throw failure }
            received.documents = request
            guard request.ids.isEmpty else {
                return MCPDocumentsAnswer(
                    documents: hits.filter { request.ids.contains($0.id) }.map(Self.withoutDistance),
                    hasMore: false
                )
            }
            let page = hits.dropFirst(request.offset)
            return MCPDocumentsAnswer(
                documents: page.prefix(request.limit).map(Self.withoutDistance),
                hasMore: page.count > request.limit
            )
        }

        func add(_ request: MCPAddRequest) async throws -> MCPAddAnswer {
            if let failure { throw failure }
            received.add = request
            return MCPAddAnswer(
                ids: request.documents.enumerated().map { $1.id ?? "новый-\($0 + 1)" },
                model: "bge-m3"
            )
        }

        func delete(_ request: MCPDeleteRequest) async throws -> MCPDeleteAnswer {
            if let failure { throw failure }
            received.delete = request
            let known = Set(hits.map(\.id))
            return MCPDeleteAnswer(
                deleted: request.ids.filter(known.contains),
                missing: request.ids.filter { !known.contains($0) },
                keptInTrash: true
            )
        }

        /// Расстояния в выборке без поиска нет и быть не может — стенд обязан
        /// врать не больше, чем настоящий бэкенд.
        private static func withoutDistance(_ payload: MCPDocumentPayload) -> MCPDocumentPayload {
            MCPDocumentPayload(id: payload.id, text: payload.text, metadata: payload.metadata)
        }
    }

    private let key = "секретный-ключ"

    private func client(
        name: String = "агент",
        collections: [String] = ["заметки"],
        write: Bool = false,
        enabled: Bool = true,
        perMinute: Int = 60,
        maxResults: Int? = nil
    ) -> ExternalClient {
        ExternalClient(
            name: name,
            keyHash: ClientKey.hash(key),
            keyPrefix: String(key.prefix(4)),
            isEnabled: enabled,
            permissions: ClientPermissions(
                collections: collections,
                allowsWrite: write,
                requestsPerMinute: perMinute,
                burst: perMinute,
                maxSearchResults: maxResults
            )
        )
    }

    /// Обязательные параметры каждого инструмента — тем, кто вызывает их все
    /// подряд.
    private static func arguments(for tool: MCPToolDefinition) -> JSONValue {
        var object: [String: JSONValue] = ["collection": .string("заметки")]
        if tool.name == MCPToolCatalogue.search.name { object["query"] = .string("договор аренды") }
        if tool.name == MCPToolCatalogue.addDocuments.name {
            object["documents"] = .array([.object(["text": .string("текст документа")])])
        }
        if tool.name == MCPToolCatalogue.deleteDocuments.name {
            object["ids"] = .array([.string("d1")])
        }
        if tool.name == MCPToolCatalogue.getFile.name {
            object["file"] = .string("папка/файл.md")
        }
        if tool.name == MCPToolCatalogue.collectMentions.name {
            object["contains"] = .string("приемк")
        }
        return .object(object)
    }

    /// Клиент с правом записи — им проверяются инструменты записи.
    private func writer(maxPerDay: Int? = nil, maxBytes: Int? = nil, delete: Bool = true) -> ExternalClient {
        ExternalClient(
            name: "агент",
            keyHash: ClientKey.hash(key),
            keyPrefix: String(key.prefix(4)),
            permissions: ClientPermissions(
                collections: ["заметки"],
                allowsWrite: true,
                maxDocumentsPerDay: maxPerDay,
                maxDocumentBytes: maxBytes,
                requestsPerMinute: 60,
                burst: 60,
                allowsDelete: delete
            )
        )
    }

    private func service(
        clients: [ExternalClient], backend: Backend = Backend(), readOnly: Bool = false
    ) async -> MCPToolService {
        let access = AccessController()
        await access.setClients(clients)
        return MCPToolService(backend: backend, access: access, isReadOnlyServer: { readOnly })
    }

    // MARK: - Список инструментов

    func testTheToolListHasTheShapeTheSpecificationFixes() async {
        let service = await service(clients: [client()])
        let listed = await service.list(key: key)

        XCTAssertEqual(listed["resultType"], .string("complete"))
        guard case .array(let tools)? = listed["tools"] else { return XCTFail("нет списка инструментов") }
        XCTAssertFalse(tools.isEmpty)
        for tool in tools {
            XCTAssertNotNil(tool["name"]?.stringValue)
            XCTAssertNotNil(tool["description"]?.stringValue)
            // Схема параметров обязана быть схемой-объектом, а не `null`:
            // клиент, получивший `null`, отбрасывает инструмент целиком.
            XCTAssertEqual(tool["inputSchema"]?["type"], .string("object"))
            // И обязана нести `properties` — пусть даже пустые. По JSON Schema
            // объект без них законен, но клиент перекладывает схему в вызов
            // функции у своего поставщика модели, и часть таких слоёв на
            // отсутствующем ключе спотыкается. Инструмент без параметров —
            // ровно тот, которым агент начинает разговор.
            guard case .object? = tool["inputSchema"]?["properties"] else {
                return XCTFail("\(tool["name"]?.stringValue ?? "?"): в схеме параметров нет properties")
            }
        }
    }

    /// Описание пишется для модели: без него она не знает, когда инструмент
    /// применять. Пустое описание — функциональный дефект этапа, а не мелочь.
    func testEveryToolExplainsItselfToAModel() {
        for tool in MCPToolCatalogue.all {
            XCTAssertGreaterThan(tool.description.count, 120, "\(tool.name): описание слишком короткое")
            XCTAssertFalse(tool.title.isEmpty, tool.name)
            // Имя по правилам спецификации: латиница, цифры, `_`, `-`, `.`.
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
            XCTAssertTrue(tool.name.unicodeScalars.allSatisfy(allowed.contains), tool.name)
        }
    }

    /// Список сокращается под права ключа — спецификация это прямо разрешает,
    /// а инструмент, который заведомо ответит отказом, только тратит вызов.
    func testAReadOnlyKeyIsNotOfferedWriteTools() async {
        let readerService = await service(clients: [client(write: false)])
        let listed = await readerService.list(key: key)
        guard case .array(let tools)? = listed["tools"] else { return XCTFail("нет списка") }
        let names = tools.compactMap { $0["name"]?.stringValue }
        XCTAssertTrue(names.contains("list_collections"))
        for name in names {
            let permission = MCPToolCatalogue.all.first { $0.name == name }?.permission
            XCTAssertEqual(permission, .read, "ключу только на чтение предложен \(name)")
        }
    }

    /// Незарегистрированный ключ получает не аварию, а список инструментов
    /// чтения: `tools/list` — первое, что делает клиент, и отказ на нём
    /// человек прочитает как «сервер сломан».
    func testAnUnknownKeyStillGetsAListRatherThanAFailure() async {
        let service = await service(clients: [client()])
        let listed = await service.list(key: "чужой")
        guard case .array(let tools)? = listed["tools"] else { return XCTFail("нет списка") }
        XCTAssertFalse(tools.isEmpty)
    }

    // MARK: - Вызов

    private func call(
        _ service: MCPToolService, _ name: String, _ arguments: JSONValue? = nil, key: String?
    ) async -> Result<JSONValue, JSONRPCError> {
        await service.call(name: name, arguments: arguments, key: key)
    }

    func testListCollectionsReturnsOnlyWhatTheKeyMaySee() async throws {
        let service = await service(clients: [client(collections: ["заметки"])])
        let result = try await call(service, "list_collections", key: key).get()

        XCTAssertEqual(result["isError"], .bool(false))
        guard case .array(let listed)? = result["structuredContent"]?["collections"] else {
            return XCTFail("нет структурированной выдачи")
        }
        XCTAssertEqual(listed.compactMap { $0["name"]?.stringValue }, ["заметки"])
        // Текстовый блок есть всегда — его читает клиент, не умеющий
        // структурированной выдачи.
        XCTAssertTrue(result["content"]?[0]?["text"]?.stringValue?.contains("заметки") ?? false)
        XCTAssertFalse(result["content"]?[0]?["text"]?.stringValue?.contains("договоры") ?? true)
    }

    /// Объявив `outputSchema`, сервер **обязан** возвращать `structuredContent`.
    func testToolsThatDeclareAnOutputSchemaReturnStructuredContent() async throws {
        // Ключ с записью: инструменты записи иначе ответят отказом, и проверять
        // было бы нечего.
        let service = await service(clients: [writer()])
        for tool in MCPToolCatalogue.all where tool.outputSchema != nil {
            let result = try await call(service, tool.name, Self.arguments(for: tool), key: key).get()
            XCTAssertNotNil(result["structuredContent"], tool.name)
        }
    }

    /// Отказ по правам — ошибка **выполнения** инструмента, а не протокола:
    /// модель читает причину и объясняет её человеку.
    func testARefusalIsAToolErrorWithAReadableReason() async throws {
        let service = await service(clients: [client(collections: ["заметки"])])
        let result = try await call(
            service, "describe_collection", .object(["collection": .string("договоры")]), key: key
        ).get()

        XCTAssertEqual(result["isError"], .bool(true))
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        // Коллекция вне whitelist называется несуществующей: сказать «доступ
        // закрыт» значило бы сообщить агенту, что она есть.
        XCTAssertTrue(text.contains("не найдена"), text)
    }

    func testAnUnknownKeyIsRefusedWithAnExplanationOfWhereToGetOne() async throws {
        let service = await service(clients: [client()])
        let result = try await call(service, "list_collections", key: "чужой").get()
        XCTAssertEqual(result["isError"], .bool(true))
        XCTAssertTrue(result["content"]?[0]?["text"]?.stringValue?.contains("не зарегистрирован") ?? false)
    }

    func testAMissingKeyNamesTheSettingThatCarriesIt() async throws {
        let service = await service(clients: [client()])
        let result = try await call(service, "list_collections", key: nil).get()
        XCTAssertEqual(result["isError"], .bool(true))
        XCTAssertTrue(result["content"]?[0]?["text"]?.stringValue?.contains("CHROMADB_MCP_KEY") ?? false)
    }

    func testADisabledClientIsRefusedByName() async throws {
        let service = await service(clients: [client(name: "старый агент", enabled: false)])
        let result = try await call(service, "list_collections", key: key).get()
        XCTAssertEqual(result["isError"], .bool(true))
        XCTAssertTrue(result["content"]?[0]?["text"]?.stringValue?.contains("старый агент") ?? false)
    }

    /// Неизвестный инструмент — ошибка протокола: модель её не исправит,
    /// и спецификация требует именно её.
    func testAnUnknownToolIsAProtocolError() async {
        let service = await service(clients: [client()])
        switch await call(service, "drop_everything", key: key) {
        case .success: XCTFail("неизвестный инструмент обязан быть ошибкой протокола")
        case .failure(let error): XCTAssertEqual(error.code, JSONRPCError.methodNotFound)
        }
    }

    func testAMissingRequiredArgumentIsAProtocolErrorToo() async {
        let service = await service(clients: [client()])
        switch await call(service, "describe_collection", .object([:]), key: key) {
        case .success: XCTFail("без обязательного параметра вызов невозможен")
        case .failure(let error): XCTAssertEqual(error.code, JSONRPCError.invalidParams)
        }
    }

    /// Сбой базы — тоже ошибка выполнения: она объяснима, и агент передаст
    /// причину человеку вместо «инструмент недоступен».
    func testABackendFailureComesBackAsAReadableToolError() async throws {
        var backend = Backend()
        backend.failure = NSError(
            domain: "тест", code: 7, userInfo: [NSLocalizedDescriptionKey: "база не отвечает"]
        )
        let service = await service(clients: [client()], backend: backend)
        let result = try await call(service, "list_collections", key: key).get()
        XCTAssertEqual(result["isError"], .bool(true))
        XCTAssertTrue(result["content"]?[0]?["text"]?.stringValue?.contains("база не отвечает") ?? false)
    }

    func testAKeyWithNoCollectionsIsToldWhereAccessIsGranted() async throws {
        let service = await service(clients: [client(collections: [])])
        let result = try await call(service, "list_collections", key: key).get()
        // Не ошибка: ключ заведён, просто пуст. Но молчаливый пустой список
        // модель истолкует как «база пуста».
        XCTAssertEqual(result["isError"], .bool(false))
        XCTAssertTrue(result["content"]?[0]?["text"]?.stringValue?.contains("Клиенты") ?? false)
    }

    /// Частота ограничивается тем же ведром, что и у прокси.
    func testTheRateLimitAppliesToToolCallsAsWell() async throws {
        let service = await service(clients: [client(perMinute: 1)])
        _ = try await call(service, "list_collections", key: key).get()
        let second = try await call(service, "list_collections", key: key).get()
        XCTAssertEqual(second["isError"], .bool(true))
        XCTAssertTrue(second["content"]?[0]?["text"]?.stringValue?.contains("Слишком много запросов") ?? false)
    }

    // MARK: - Поиск

    func testSearchTakesTextAndReturnsDistanceWithItsMetric() async throws {
        let backend = Backend()
        let service = await service(clients: [client()], backend: backend)
        let result = try await call(
            service, "search",
            .object(["collection": .string("заметки"), "query": .string("договор аренды")]),
            key: key
        ).get()

        XCTAssertEqual(result["isError"], .bool(false))
        XCTAssertEqual(backend.received.search?.query, "договор аренды")
        guard case .array(let documents)? = result["structuredContent"]?["documents"] else {
            return XCTFail("нет документов")
        }
        XCTAssertEqual(documents.first?["id"]?.stringValue, "d1")
        XCTAssertEqual(documents.first?["metric"], .string("cosine"))
        XCTAssertNotNil(documents.first?["distance"]?.doubleValue)
        // Число остаётся числом: агент строит по выдаче фильтр.
        XCTAssertEqual(documents.first?["metadata"]?["year"], .int(2024))
    }

    /// Вектор не принимается ни одним инструментом (DoD этапа 7). И не молча:
    /// выброшенный параметр агент принял бы за применённый.
    func testAnEmbeddingIsRefusedByNameRatherThanIgnored() async throws {
        let service = await service(clients: [client()])
        for parameter in ["embedding", "query_embeddings", "vector"] {
            let result = try await call(
                service, "search",
                .object([
                    "collection": .string("заметки"),
                    "query": .string("что угодно"),
                    parameter: .array([.double(0.1), .double(0.2)]),
                ]),
                key: key
            ).get()
            XCTAssertEqual(result["isError"], .bool(true), parameter)
            let text = result["content"]?[0]?["text"]?.stringValue ?? ""
            XCTAssertTrue(text.contains(parameter), text)
            XCTAssertTrue(text.contains("текстом"), text)
        }
    }

    func testAnEmptyQueryIsAProtocolErrorNamingTheParameter() async {
        let service = await service(clients: [client()])
        let result = await call(
            service, "search",
            .object(["collection": .string("заметки"), "query": .string("   ")]), key: key
        )
        guard case .failure(let error) = result else { return XCTFail("пустой запрос принят") }
        XCTAssertEqual(error.code, JSONRPCError.invalidParams)
        XCTAssertTrue(error.message.contains("query"))
    }

    /// Фильтр уезжает в базу тем самым синтаксисом, который модель знает
    /// по документации ChromaDB.
    func testTheFilterReachesTheDatabaseAsChromaWhereClause() async throws {
        let backend = Backend()
        let service = await service(clients: [client()], backend: backend)
        _ = try await call(
            service, "search",
            .object([
                "collection": .string("заметки"),
                "query": .string("аренда"),
                "filter": .object(["year": .object(["$eq": .int(2024)])]),
                "contains": .string("аренда"),
            ]),
            key: key
        ).get()

        let filter = try XCTUnwrap(backend.received.search?.filter)
        XCTAssertEqual(filter.rawWhereJSON, #"{"year":{"$eq":2024}}"#)
        XCTAssertEqual(filter.textConditions.first?.text, "аренда")
    }

    /// `contains` не должен требовать от агента угадывать написание: `$contains`
    /// у ChromaDB различает регистр, а агент ищет слово, а не написание.
    func testContainsAsksForTheUsualSpellingsRatherThanOne() async throws {
        let backend = Backend()
        let service = await service(clients: [client()], backend: backend)
        _ = try await call(
            service, "search",
            .object([
                "collection": .string("заметки"),
                "query": .string("операционная система"),
                "contains": .string("astra linux"),
            ]),
            key: key
        ).get()

        let filter = try XCTUnwrap(backend.received.search?.filter)
        let asked = filter.textConditions.map(\.text)
        XCTAssertTrue(asked.contains("astra linux"))
        XCTAssertTrue(asked.contains("Astra Linux"), "не спрошено написание с заглавных: \(asked)")
        // Через `$or`: документ, где написано «Astra Linux», обязан найтись
        // по запросу «astra linux», а не отсеяться пересечением вариантов.
        XCTAssertEqual(filter.textLogic, .or)
    }

    func testAFilterOfTheWrongShapeIsRefusedBeforeTheDatabaseIsTouched() async {
        let backend = Backend()
        let service = await service(clients: [client()], backend: backend)
        let result = await call(
            service, "search",
            .object([
                "collection": .string("заметки"),
                "query": .string("аренда"),
                "filter": .string("year = 2024"),
            ]),
            key: key
        )
        guard case .failure(let error) = result else { return XCTFail("строка принята как фильтр") }
        XCTAssertEqual(error.code, JSONRPCError.invalidParams)
        XCTAssertNil(backend.received.search)
    }

    /// Пустая выдача — не молчание: чаще всего виноват фильтр, и агент должен
    /// знать, куда смотреть.
    func testAnEmptyResultSaysWhereToLookNext() async throws {
        var backend = Backend()
        backend.hits = []
        let service = await service(clients: [client()], backend: backend)
        let result = try await call(
            service, "search",
            .object([
                "collection": .string("заметки"),
                "query": .string("аренда"),
                "filter": .object(["year": .object(["$eq": .int(1999)])]),
            ]),
            key: key
        ).get()

        XCTAssertEqual(result["isError"], .bool(false))
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("ничего не найдено"), text)
        XCTAssertTrue(text.contains("describe_collection"), text)
    }

    /// Умный поиск решается в правах ключа, а не запросом агента: настройка,
    /// которую человек выключил, не должна включаться обратно чужим вызовом.
    func testSmartSearchIsDecidedByTheKeyAndNotByTheAgent() async throws {
        for decision: Bool? in [nil, true, false] {
            let backend = Backend()
            var permissions = ClientPermissions(collections: ["заметки"], requestsPerMinute: 60, burst: 60)
            permissions.smartSearch = decision
            let owner = ExternalClient(
                name: "агент", keyHash: ClientKey.hash(key), keyPrefix: String(key.prefix(4)),
                permissions: permissions
            )
            let access = AccessController()
            await access.setClients([owner])
            let service = MCPToolService(backend: backend, access: access)

            _ = try await service.call(
                name: "search",
                arguments: .object([
                    "collection": .string("заметки"),
                    "query": .string("аренда"),
                    // Агент пытается решить это сам — параметра нет и в схеме.
                    "smart_search": .bool(true),
                ]),
                key: key
            ).get()
            XCTAssertEqual(backend.received.search?.smartSearch, decision)
        }
    }

    // MARK: - Потолки выдачи

    func testARequestAboveTheCeilingIsCutAndSaysSo() async throws {
        let backend = Backend()
        let service = await service(clients: [client(maxResults: 2)], backend: backend)
        let result = try await call(
            service, "search",
            .object([
                "collection": .string("заметки"),
                "query": .string("аренда"),
                "n_results": .int(50),
            ]),
            key: key
        ).get()

        // Потолок применён **до** обращения к базе, а не к её ответу.
        XCTAssertEqual(backend.received.search?.nResults, 2)
        guard case .array(let documents)? = result["structuredContent"]?["documents"] else {
            return XCTFail("нет документов")
        }
        XCTAssertEqual(documents.count, 2)
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("потолок"), text)
    }

    func testADocumentLongerThanTheLimitIsCutWithAMarkerAndItsID() async throws {
        var backend = Backend()
        backend.hits = [MCPDocumentPayload(
            id: "длинный",
            text: String(repeating: "я", count: MCPOutputLimits.defaultDocumentCharacters + 500),
            metadata: nil,
            distance: 0.1
        )]
        let service = await service(clients: [client()], backend: backend)
        let result = try await call(
            service, "search",
            .object(["collection": .string("заметки"), "query": .string("аренда")]), key: key
        ).get()

        guard case .array(let documents)? = result["structuredContent"]?["documents"] else {
            return XCTFail("нет документов")
        }
        XCTAssertEqual(documents.first?["truncated"], .bool(true))
        XCTAssertEqual(
            documents.first?["text"]?.stringValue?.count, MCPOutputLimits.defaultDocumentCharacters
        )
        XCTAssertEqual(
            documents.first?["textCharacters"], .int(MCPOutputLimits.defaultDocumentCharacters + 500)
        )
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("текст обрезан"), "нет пометки об обрезке")
        // Без идентификатора пометка бесполезна: дочитать нечем.
        XCTAssertTrue(text.contains("длинный"), text)
        XCTAssertTrue(text.contains("get_documents"), text)
    }

    /// Сумма средних документов переполняет контекст не хуже одного огромного.
    func testTheListIsCutWhenTheWholeAnswerGrowsTooLarge() async throws {
        var backend = Backend()
        backend.hits = (1...10).map { number in
            MCPDocumentPayload(
                id: "d\(number)",
                text: String(repeating: "т", count: 3500),
                metadata: nil,
                distance: Double(number) / 100
            )
        }
        let service = await service(clients: [client(maxResults: 10)], backend: backend)
        let result = try await call(
            service, "search",
            .object([
                "collection": .string("заметки"),
                "query": .string("аренда"),
                "n_results": .int(10),
            ]),
            key: key
        ).get()

        guard case .array(let documents)? = result["structuredContent"]?["documents"] else {
            return XCTFail("нет документов")
        }
        XCTAssertLessThan(documents.count, 10)
        XCTAssertGreaterThan(documents.count, 0)
        XCTAssertEqual(result["structuredContent"]?["truncated"], .bool(true))
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("усечён"), text)
    }

    /// Метаданные занимают бюджет наравне с текстом. У документа из настоящей
    /// коллекции их набирается на полтора килобайта — бюджет, который их не
    /// считает, ограничивает ответ только на бумаге.
    func testMetadataCountsAgainstTheAnswerBudgetToo() {
        let heavy: ChromaMetadata = [
            "warnings": .string(String(repeating: "п", count: 6000)),
        ]
        let payloads = (1...6).map { number in
            MCPDocumentPayload(
                id: "d\(number)", text: "короткий текст", metadata: heavy, distance: 0.1
            )
        }
        let rendered = MCPDocumentRendering.render(payloads, limits: MCPOutputLimits())
        XCTAssertLessThan(rendered.shown, 6)
        XCTAssertTrue(rendered.notes.contains { $0.contains("усечён") })
    }

    /// Один документ длиннее всего бюджета всё равно отдаётся: ответ без
    /// единого результата хуже, чем ответ с одним.
    func testASingleOversizedDocumentStillComesBack() {
        let payload = MCPDocumentPayload(
            id: "один", text: String(repeating: "щ", count: 100_000), metadata: nil, distance: 0.1
        )
        let rendered = MCPDocumentRendering.render([payload], limits: MCPOutputLimits())
        XCTAssertEqual(rendered.shown, 1)
        XCTAssertEqual(
            rendered.documents.first?["text"]?.stringValue?.count,
            MCPOutputLimits.defaultDocumentCharacters
        )
    }

    // MARK: - Собери по теме

    /// Куски раскладываются по файлам, частые файлы идут первыми, и с каждого
    /// показывается один образец, а не все совпадения.
    func testMentionsGroupChunksByFileAndShowOneSampleEach() async throws {
        var backend = Backend()
        backend.hits = Self.mentions([("а.docx", 3), ("б.docx", 1), ("в.docx", 5)])
        let service = await service(clients: [client()], backend: backend)
        let result = try await call(
            service, "collect_mentions",
            .object(["collection": .string("заметки"), "contains": .string("приемк")]),
            key: key
        ).get()

        guard case .array(let files)? = result["structuredContent"]?["files"] else {
            return XCTFail("файлов нет вовсе")
        }
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files.first?["file"], .string("в.docx"))
        XCTAssertEqual(files.first?["hits"], .int(5))
        XCTAssertEqual(result["structuredContent"]?["totalMatches"], .int(9))
        XCTAssertEqual(result["structuredContent"]?["totalFiles"], .int(3))
        // По образцу с файла, а не по совпадению с куска.
        guard case .array(let documents)? = result["structuredContent"]?["documents"] else {
            return XCTFail("образцов нет вовсе")
        }
        XCTAssertEqual(documents.count, 3)
    }

    /// Обход коллекции один, а не по одному на страницу: инструмент просит
    /// у базы всё сразу и листает уже разложенное по файлам.
    func testMentionsScanTheCollectionOnceAndPageOverFiles() async throws {
        var backend = Backend()
        backend.hits = Self.mentions([("а.docx", 1), ("б.docx", 1), ("в.docx", 1)])
        let service = await service(clients: [client()], backend: backend)
        let result = try await call(
            service, "collect_mentions",
            .object([
                "collection": .string("заметки"), "contains": .string("приемк"),
                "limit": .int(2), "offset": .int(0),
            ]),
            key: key
        ).get()

        XCTAssertEqual(backend.received.documents?.limit, MCPToolService.mentionsScanLimit)
        XCTAssertEqual(backend.received.documents?.offset, 0)
        guard case .array(let files)? = result["structuredContent"]?["files"] else {
            return XCTFail("файлов нет вовсе")
        }
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(result["structuredContent"]?["hasMore"], .bool(true))
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("offset 2"), text)
    }

    /// Вторая страница продолжает первую, а не начинает её заново.
    func testMentionsPagingDoesNotRepeatFiles() async throws {
        var backend = Backend()
        backend.hits = Self.mentions([("а.docx", 3), ("б.docx", 2), ("в.docx", 1)])
        let service = await service(clients: [client()], backend: backend)
        func page(_ offset: Int) async throws -> [String] {
            let result = try await call(
                service, "collect_mentions",
                .object([
                    "collection": .string("заметки"), "contains": .string("приемк"),
                    "limit": .int(2), "offset": .int(offset),
                ]),
                key: key
            ).get()
            guard case .array(let files)? = result["structuredContent"]?["files"] else { return [] }
            return files.compactMap { $0["file"]?.stringValue }
        }
        let first = try await page(0)
        let second = try await page(2)
        XCTAssertEqual(first, ["а.docx", "б.docx"])
        XCTAssertEqual(second, ["в.docx"])
        XCTAssertTrue(Set(first).isDisjoint(with: Set(second)))
    }

    /// Больше трёх образцов с файла не отдаётся, сколько ни проси.
    func testMentionsNeverShowMoreThanThreeSamplesPerFile() async throws {
        var backend = Backend()
        backend.hits = Self.mentions([("а.docx", 10)])
        let service = await service(clients: [client()], backend: backend)
        let result = try await call(
            service, "collect_mentions",
            .object([
                "collection": .string("заметки"), "contains": .string("приемк"),
                "per_file": .int(9),
            ]),
            key: key
        ).get()
        guard case .array(let documents)? = result["structuredContent"]?["documents"] else {
            return XCTFail("образцов нет вовсе")
        }
        XCTAssertEqual(documents.count, MCPToolService.mentionsMaximumPerFile)
    }

    /// Пустой ответ говорит, почему пусто: сравнение буквальное, а синонимы —
    /// это другой инструмент.
    func testMentionsSayWhyNothingMatched() async throws {
        var backend = Backend()
        backend.hits = []
        let service = await service(clients: [client()], backend: backend)
        let result = try await call(
            service, "collect_mentions",
            .object(["collection": .string("заметки"), "contains": .string("экранная форма")]),
            key: key
        ).get()
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("буквальное"), text)
        XCTAssertTrue(text.contains("search"), text)
        XCTAssertEqual(result["structuredContent"]?["totalFiles"], .int(0))
    }

    func testMentionsWithoutAWordAreRefusedBeforeTheDatabaseIsTouched() async {
        let backend = Backend()
        let service = await service(clients: [client()], backend: backend)
        let result = await call(
            service, "collect_mentions", .object(["collection": .string("заметки")]), key: key
        )
        guard case .failure(let error) = result else { return XCTFail("вызов без слова принят") }
        XCTAssertEqual(error.code, JSONRPCError.invalidParams)
        XCTAssertNil(backend.received.documents)
    }

    /// Просьбу об образцах урезали — об этом сказано вслух, иначе агент решит,
    /// что больше в файле ничего нет (правило 3 приложения 5).
    func testMentionsSayWhenPerFileWasCutDown() async throws {
        var backend = Backend()
        backend.hits = Self.mentions([("а.docx", 9)])
        let service = await service(clients: [client()], backend: backend)
        let result = try await call(
            service, "collect_mentions",
            .object([
                "collection": .string("заметки"), "contains": .string("приемк"),
                "per_file": .int(9),
            ]),
            key: key
        ).get()
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("Запрошено образцов с файла: 9"), text)
    }

    /// Перечень файлов занимает место в ответе наравне с текстами: сотня
    /// длинных путей не должна выносить ответ за отведённый объём.
    func testMentionsListingStaysInsideTheAnswerBudget() async throws {
        var backend = Backend()
        // Длинные **пути**, а не идентификаторы: в живой базе путь занимает
        // полторы-две сотни знаков, и сотня таких путей — это перечень
        // размером с весь ответ.
        let longPath = String(repeating: "п", count: 400)
        backend.hits = (1...100).map { number in
            MCPDocumentPayload(
                id: "d\(number)",
                text: "приемка работ",
                metadata: ["source_file": .string("\(longPath)-\(number).docx")]
            )
        }
        let service = await service(
            clients: [client(maxResults: 100)], backend: backend
        )
        let result = try await call(
            service, "collect_mentions",
            .object([
                "collection": .string("заметки"), "contains": .string("приемк"),
                "limit": .int(100),
            ]),
            key: key
        ).get()
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        // Первая строка — заголовок ответа, перечень идёт следом до пустой.
        let listing = text.split(separator: "\n", omittingEmptySubsequences: false)
            .dropFirst()
            .prefix { !$0.isEmpty }
            .joined(separator: "\n")
        // Перечню отведена половина ответа: иначе сотня путей вытеснит из него
        // сами образцы, ради которых вызов и делался.
        XCTAssertLessThanOrEqual(listing.count, MCPOutputLimits.defaultResponseCharacters / 2)
        // Допуск — на заголовки документов (id и подсказка про get_file):
        // их render в бюджет не считает, и это его давнее правило, общее для
        // всех инструментов. Без правки перечня ответ выходил за 35 000.
        XCTAssertLessThanOrEqual(text.count, MCPOutputLimits.defaultResponseCharacters + 2000)
        XCTAssertTrue(text.contains("Перечень урезан"), String(text.prefix(400)))
    }

    /// Проекция полей доходит и до образцов «собери по теме».
    func testMentionsHonourRequestedFields() async throws {
        var backend = Backend()
        backend.hits = Self.mentions([("а.docx", 1)])
        let service = await service(clients: [client()], backend: backend)
        let result = try await call(
            service, "collect_mentions",
            .object([
                "collection": .string("заметки"), "contains": .string("приемк"),
                "fields": .array([.string("source_file")]),
            ]),
            key: key
        ).get()
        guard case .array(let documents)? = result["structuredContent"]?["documents"],
              case .object(let metadata)? = documents.first?["metadata"]
        else { return XCTFail("образца с метаданными нет") }
        XCTAssertEqual(Set(metadata.keys), ["source_file"])
    }

    /// Число «contains» — это ошибка типа, а не «не сказано, что искать».
    func testMentionsRefuseANonStringWord() async {
        let backend = Backend()
        let service = await service(clients: [client()], backend: backend)
        let result = await call(
            service, "collect_mentions",
            .object(["collection": .string("заметки"), "contains": .int(5)]),
            key: key
        )
        guard case .failure(let error) = result else { return XCTFail("число принято как слово") }
        XCTAssertTrue(error.message.contains("строкой"), error.message)
        XCTAssertNil(backend.received.documents)
    }

    /// Куски нескольких файлов: по `count` штук с каждого, в порядке чанков.
    private static func mentions(_ files: [(String, Int)]) -> [MCPDocumentPayload] {
        var payloads: [MCPDocumentPayload] = []
        for (path, count) in files {
            for index in 0..<count {
                payloads.append(MCPDocumentPayload(
                    id: "\(path)-\(index)",
                    text: "приемка работ, кусок \(index)",
                    metadata: [
                        "source_file": .string(path),
                        "file_id": .string(String(path.prefix(1))),
                        "chunk_index": .int(index),
                    ]
                ))
            }
        }
        return payloads
    }

    // MARK: - Проекция метаданных

    /// Строка таблицы тащит в ответ все свои колонки. Агент, назвавший нужные,
    /// получает их — и только их.
    func testOnlyTheRequestedFieldsComeBack() {
        let row: ChromaMetadata = [
            "товар": .string("сервер"),
            "цена_руб": .int(120_000),
            "совокупные_трудозатраты_чел_мес": .double(3.5),
            "руководитель_проекта_по_иб": .string("Иванов"),
        ]
        let rendered = MCPDocumentRendering.render(
            [MCPDocumentPayload(id: "r1", text: "строка", metadata: row, distance: 0.1)],
            limits: MCPOutputLimits(),
            fields: ["товар", "цена_руб"]
        )
        guard case .object(let metadata)? = rendered.documents.first?["metadata"] else {
            return XCTFail("метаданных нет вовсе")
        }
        XCTAssertEqual(Set(metadata.keys), ["товар", "цена_руб"])
        // Не только в структурированном ответе: модель читает строку.
        XCTAssertFalse(rendered.lines.joined().contains("руководитель_проекта_по_иб"))
    }

    /// Ради чего это сделано: те же строки, тот же бюджет — но помещается
    /// их больше, потому что место занимали колонки, а не текст.
    func testProjectionLetsMoreRowsFitTheSameBudget() {
        var row: ChromaMetadata = ["цена_руб": .int(120_000)]
        for number in 1...40 { row["колонка_\(number)"] = .string(String(repeating: "з", count: 40)) }
        let payloads = (1...40).map { number in
            MCPDocumentPayload(
                id: "r\(number)", text: "строка таблицы", metadata: row, distance: 0.1
            )
        }
        let whole = MCPDocumentRendering.render(payloads, limits: MCPOutputLimits())
        let projected = MCPDocumentRendering.render(
            payloads, limits: MCPOutputLimits(), fields: ["цена_руб"]
        )
        XCTAssertGreaterThan(projected.shown, whole.shown)
    }

    /// Проекция — забота выдачи, а не базы: предупреждение о плоской таблице
    /// и отпечаток файла читаются из полных метаданных и переживают отбор.
    func testProjectionKeepsWarningsAndTheFileFingerprint() {
        let metadata: ChromaMetadata = [
            "цена_руб": .int(500),
            "file_id": .string("7b0d604937a1c2e4"),
            "tables_flat": .bool(true),
        ]
        let rendered = MCPDocumentRendering.render(
            [MCPDocumentPayload(id: "r1", text: "строка", metadata: metadata, distance: 0.1)],
            limits: MCPOutputLimits(),
            fields: ["цена_руб"]
        )
        XCTAssertEqual(rendered.documents.first?["fileId"], .string("7b0d604937a1c2e4"))
        XCTAssertTrue(rendered.notes.contains { $0.contains("плоским текстом") })
        guard case .object(let visible)? = rendered.documents.first?["metadata"] else {
            return XCTFail("метаданных нет вовсе")
        }
        XCTAssertEqual(Set(visible.keys), ["цена_руб"])
    }

    /// Опечатка в имени колонки иначе выглядит как «в базе про это пусто» —
    /// то есть как ответ, а не как промах.
    func testAFieldNobodyHasIsNamedOutLoud() {
        let rendered = MCPDocumentRendering.render(
            [MCPDocumentPayload(id: "r1", text: "строка", metadata: ["цена_руб": .int(1)], distance: 0.1)],
            limits: MCPOutputLimits(),
            fields: ["цена_руб", "стоимость_руб"]
        )
        XCTAssertTrue(
            rendered.notes.contains { $0.contains("стоимость_руб") && !$0.contains("цена_руб") },
            rendered.notes.joined(separator: " | ")
        )
    }

    /// Не задано — прежнее поведение: возвращаются все поля.
    func testWithoutFieldsEverythingIsStillReturned() {
        let metadata: ChromaMetadata = ["а": .int(1), "б": .int(2)]
        for fields in [nil, []] as [[String]?] {
            let rendered = MCPDocumentRendering.render(
                [MCPDocumentPayload(id: "r1", text: "т", metadata: metadata, distance: 0.1)],
                limits: MCPOutputLimits(), fields: fields
            )
            guard case .object(let visible)? = rendered.documents.first?["metadata"] else {
                return XCTFail("метаданных нет вовсе")
            }
            XCTAssertEqual(Set(visible.keys), ["а", "б"])
        }
    }

    /// Ничего не нашлось — виноват запрос, а не имена полей. Пометка о полях
    /// в пустой выдаче уводит агента переименовывать то, что названо верно.
    func testAnEmptyResultDoesNotBlameTheRequestedFields() async throws {
        var backend = Backend()
        backend.hits = []
        let service = await service(clients: [client()], backend: backend)
        let result = try await call(
            service, "search",
            .object([
                "collection": .string("заметки"),
                "query": .string("аренда"),
                "fields": .array([.string("цена_руб")]),
            ]),
            key: key
        ).get()
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("ничего не найдено"), text)
        XCTAssertFalse(text.contains("Запрошенных полей нет"), text)
    }

    func testFieldsOfTheWrongShapeAreRefusedBeforeTheDatabaseIsTouched() async {
        let backend = Backend()
        let service = await service(clients: [client()], backend: backend)
        for wrong in [JSONValue.string("цена"), .array([.string("")])] {
            let result = await call(
                service, "search",
                .object([
                    "collection": .string("заметки"),
                    "query": .string("аренда"),
                    "fields": wrong,
                ]),
                key: key
            )
            guard case .failure(let error) = result else {
                return XCTFail("принято как список полей: \(wrong)")
            }
            XCTAssertEqual(error.code, JSONRPCError.invalidParams)
        }
        XCTAssertNil(backend.received.search)
    }

    /// Повтор поля — не ошибка, но и не повод показывать его дважды.
    func testRepeatedFieldNamesAreCollapsed() throws {
        let parsed = try MCPToolService.metadataFields(
            .object(["fields": .array([.string("цена"), .string("цена"), .string(" цена ")])])
        ).get()
        XCTAssertEqual(parsed, ["цена"])
    }

    /// Векторы не возвращаются никогда — в выдаче для них нет даже места.
    func testNoAnswerEverCarriesAVector() async throws {
        let service = await service(clients: [writer()])
        for tool in MCPToolCatalogue.all {
            let result = try await call(service, tool.name, Self.arguments(for: tool), key: key).get()
            let json = try JSONEncoder().encode(result)
            let text = String(data: json, encoding: .utf8) ?? ""
            for forbidden in ["embedding", "\"vector\""] {
                XCTAssertFalse(text.contains(forbidden), "\(tool.name): в ответе \(forbidden)")
            }
        }
    }

    // MARK: - Выборка документов

    func testGetDocumentsByIDIgnoresPagingAndReturnsWhatWasAsked() async throws {
        let backend = Backend()
        let service = await service(clients: [client()], backend: backend)
        let result = try await call(
            service, "get_documents",
            .object([
                "collection": .string("заметки"),
                "ids": .array([.string("d2"), .string("d3")]),
                "offset": .int(100),
            ]),
            key: key
        ).get()

        XCTAssertEqual(backend.received.documents?.ids, ["d2", "d3"])
        // Спрошено по именам — листать нечего.
        XCTAssertEqual(backend.received.documents?.offset, 0)
        guard case .array(let documents)? = result["structuredContent"]?["documents"] else {
            return XCTFail("нет документов")
        }
        XCTAssertEqual(documents.compactMap { $0["id"]?.stringValue }, ["d2", "d3"])
        // Расстояния здесь нет и быть не может: поиска не было.
        XCTAssertNil(documents.first?["distance"])
    }

    func testGetDocumentsSaysHowToAskForTheNextPage() async throws {
        var backend = Backend()
        backend.hits = (1...5).map {
            MCPDocumentPayload(id: "d\($0)", text: "текст \($0)", metadata: nil)
        }
        let service = await service(clients: [client()], backend: backend)
        let result = try await call(
            service, "get_documents",
            .object(["collection": .string("заметки"), "limit": .int(2), "offset": .int(2)]),
            key: key
        ).get()

        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("offset 4"), text)
        XCTAssertEqual(result["structuredContent"]?["hasMore"], .bool(true))
    }

    func testAnIDListOfTheWrongTypeIsAProtocolError() async {
        let service = await service(clients: [client()])
        let result = await call(
            service, "get_documents",
            .object(["collection": .string("заметки"), "ids": .array([.int(7)])]), key: key
        )
        guard case .failure(let error) = result else { return XCTFail("числовой id принят") }
        XCTAssertEqual(error.code, JSONRPCError.invalidParams)
    }

    /// Коллекция вне whitelist недоступна и поиску, не только каталогу.
    func testSearchIsRefusedOutsideTheWhitelist() async throws {
        let backend = Backend()
        let service = await service(clients: [client(collections: ["заметки"])], backend: backend)
        let result = try await call(
            service, "search",
            .object(["collection": .string("договоры"), "query": .string("аренда")]), key: key
        ).get()

        XCTAssertEqual(result["isError"], .bool(true))
        XCTAssertNil(backend.received.search)
        XCTAssertTrue(
            result["content"]?[0]?["text"]?.stringValue?.contains("не найдена") ?? false,
            "чужая коллекция не должна опознаваться как существующая"
        )
    }

    /// Пустое имя коллекции не должно проходить мимо проверки прав.
    ///
    /// Обязательность параметра проверялась как «не nil», а проверка whitelist
    /// стояла под `!collection.isEmpty` — строка `""` минула обе, и вызов
    /// уходил на бэкенд без решения по доступу.
    func testAnEmptyCollectionNameIsRefusedRatherThanSlippingPastTheWhitelist() async throws {
        let backend = Backend()
        let service = await service(clients: [client(collections: ["заметки"])], backend: backend)
        let result = await call(
            service, "search",
            .object(["collection": .string(""), "query": .string("аренда")]), key: key
        )
        guard case .failure(let error) = result else {
            return XCTFail("пустое имя коллекции принято как имя")
        }
        XCTAssertEqual(error.code, JSONRPCError.invalidParams)
        XCTAssertNil(backend.received.search, "до бэкенда такой вызов доходить не должен")
    }

    /// То же для инструмента, который читает документы: пустое имя не даёт
    /// обойти whitelist ни одним путём.
    func testAnEmptyCollectionNameIsRefusedForDocumentsToo() async throws {
        let backend = Backend()
        let service = await service(clients: [client(collections: ["заметки"])], backend: backend)
        let result = await call(
            service, "get_documents",
            .object(["collection": .string(""), "ids": .array([.string("d1")])]), key: key
        )
        guard case .failure(let error) = result else {
            return XCTFail("пустое имя коллекции принято как имя")
        }
        XCTAssertEqual(error.code, JSONRPCError.invalidParams)
        XCTAssertNil(backend.received.documents, "до бэкенда такой вызов доходить не должен")
    }

    // MARK: - Запись

    func testAddDocumentsPassesTextAndMetadataThrough() async throws {
        let backend = Backend()
        let service = await service(clients: [writer()], backend: backend)
        let result = try await call(
            service, "add_documents",
            .object([
                "collection": .string("заметки"),
                "documents": .array([
                    .object([
                        "text": .string("Договор аренды подписан."),
                        "id": .string("свой-id"),
                        "metadata": .object(["year": .int(2024), "важное": .bool(true)]),
                    ]),
                    .object(["text": .string("Второй документ")]),
                ]),
            ]),
            key: key
        ).get()

        XCTAssertEqual(result["isError"], .bool(false))
        let sent = try XCTUnwrap(backend.received.add)
        XCTAssertEqual(sent.documents.count, 2)
        XCTAssertEqual(sent.documents.first?.id, "свой-id")
        XCTAssertEqual(sent.documents.first?.metadata?["year"], .int(2024))
        // Идентификаторы возвращаются все — в том числе придуманные
        // приложением, иначе агент не сможет сослаться на записанное.
        guard case .array(let ids)? = result["structuredContent"]?["ids"] else {
            return XCTFail("нет идентификаторов")
        }
        XCTAssertEqual(ids.count, 2)
    }

    /// Матрица «право × инструмент»: ключу только на чтение запись запрещена,
    /// и до базы вызов не доходит.
    func testAReadOnlyKeyIsRefusedTheWriteToolWithAReason() async throws {
        let backend = Backend()
        let service = await service(clients: [client(write: false)], backend: backend)
        let result = try await call(
            service, "add_documents", Self.arguments(for: MCPToolCatalogue.addDocuments), key: key
        ).get()

        XCTAssertEqual(result["isError"], .bool(true))
        XCTAssertTrue(result["content"]?[0]?["text"]?.stringValue?.contains("только чтение") ?? false)
        XCTAssertNil(backend.received.add, "отказанная запись не должна доходить до базы")
    }

    /// Переключатель «весь сервер только на чтение» сильнее прав ключа.
    func testTheReadOnlyServerRefusesEvenAKeyAllowedToWrite() async throws {
        let backend = Backend()
        let service = await service(clients: [writer()], backend: backend, readOnly: true)
        let result = try await call(
            service, "add_documents", Self.arguments(for: MCPToolCatalogue.addDocuments), key: key
        ).get()

        XCTAssertEqual(result["isError"], .bool(true))
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        // Причина названа именно серверная: ключ-то писать вправе, и без этого
        // владелец пойдёт править права, которые ни при чём.
        XCTAssertTrue(text.contains("режим только чтения"), text)
        XCTAssertNil(backend.received.add)
    }

    func testTheDailyDocumentQuotaAppliesToTheAgentToo() async throws {
        let backend = Backend()
        let service = await service(clients: [writer(maxPerDay: 2)], backend: backend)
        let three = JSONValue.object([
            "collection": .string("заметки"),
            "documents": .array((1...3).map { .object(["text": .string("документ \($0)")]) }),
        ])
        let result = try await call(service, "add_documents", three, key: key).get()

        XCTAssertEqual(result["isError"], .bool(true))
        XCTAssertTrue(result["content"]?[0]?["text"]?.stringValue?.contains("лимит") ?? false)
        XCTAssertNil(backend.received.add, "лимит обязан сработать до записи, а не после")
    }

    func testADocumentAboveTheSizeLimitIsRefusedBeforeAnythingIsWritten() async throws {
        let backend = Backend()
        let service = await service(clients: [writer(maxBytes: 100)], backend: backend)
        let result = try await call(
            service, "add_documents",
            .object([
                "collection": .string("заметки"),
                "documents": .array([.object(["text": .string(String(repeating: "я", count: 500))])]),
            ]),
            key: key
        ).get()

        XCTAssertEqual(result["isError"], .bool(true))
        XCTAssertNil(backend.received.add)
    }

    /// Вложенные метаданные ChromaDB не принимает вовсе. Сказать об этом на
    /// разборе полезнее, чем дать базе ответить четырёхсотым.
    func testNestedMetadataIsRefusedWithTheFieldNamed() async {
        let service = await service(clients: [writer()])
        let result = await call(
            service, "add_documents",
            .object([
                "collection": .string("заметки"),
                "documents": .array([.object([
                    "text": .string("текст"),
                    "metadata": .object(["автор": .object(["имя": .string("Иван")])]),
                ])]),
            ]),
            key: key
        )
        guard case .failure(let error) = result else { return XCTFail("вложенные метаданные приняты") }
        XCTAssertEqual(error.code, JSONRPCError.invalidParams)
        XCTAssertTrue(error.message.contains("автор"), error.message)
    }

    func testRepeatedIdentifiersInOneCallAreRefused() async {
        let service = await service(clients: [writer()])
        let result = await call(
            service, "add_documents",
            .object([
                "collection": .string("заметки"),
                "documents": .array([
                    .object(["text": .string("раз"), "id": .string("один")]),
                    .object(["text": .string("два"), "id": .string("один")]),
                ]),
            ]),
            key: key
        )
        guard case .failure(let error) = result else { return XCTFail("повтор принят") }
        XCTAssertEqual(error.code, JSONRPCError.invalidParams)
    }

    func testAnEmptyDocumentTextIsRefusedByNumber() async {
        let service = await service(clients: [writer()])
        let result = await call(
            service, "add_documents",
            .object([
                "collection": .string("заметки"),
                "documents": .array([
                    .object(["text": .string("нормальный")]),
                    .object(["text": .string("   ")]),
                ]),
            ]),
            key: key
        )
        guard case .failure(let error) = result else { return XCTFail("пустой текст принят") }
        XCTAssertTrue(error.message.contains("2"), error.message)
    }

    // MARK: - Удаление

    func testDeleteRemovesWhatWasNamedAndSaysWhatWasNotFound() async throws {
        let backend = Backend()
        let service = await service(clients: [writer()], backend: backend)
        let result = try await call(
            service, "delete_documents",
            .object([
                "collection": .string("заметки"),
                "ids": .array([.string("d1"), .string("которого-нет")]),
            ]),
            key: key
        ).get()

        XCTAssertEqual(result["isError"], .bool(false))
        XCTAssertEqual(backend.received.delete?.ids, ["d1", "которого-нет"])
        XCTAssertEqual(result["structuredContent"]?["deleted"], .array([.string("d1")]))
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        // Перечислением, а не числом: «удалено 1 из 2» оставляет агента
        // гадать, какой второй.
        XCTAssertTrue(text.contains("которого-нет"), text)
        XCTAssertTrue(text.contains("корзине"), text)
    }

    /// Удаление — отдельное право поверх записи (DoD этапа 7).
    func testAWriterWithoutTheDeleteRightIsRefused() async throws {
        let backend = Backend()
        let service = await service(clients: [writer(delete: false)], backend: backend)
        let result = try await call(
            service, "delete_documents", Self.arguments(for: MCPToolCatalogue.deleteDocuments), key: key
        ).get()

        XCTAssertEqual(result["isError"], .bool(true))
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("отдельное право"), text)
        XCTAssertNil(backend.received.delete, "отказанное удаление не должно доходить до базы")
    }

    func testAKeyWithoutTheDeleteRightIsNotOfferedTheTool() async {
        let service = await service(clients: [writer(delete: false)])
        let listed = await service.list(key: key)
        guard case .array(let tools)? = listed["tools"] else { return XCTFail("нет списка") }
        let names = tools.compactMap { $0["name"]?.stringValue }
        XCTAssertTrue(names.contains("add_documents"))
        XCTAssertFalse(names.contains("delete_documents"))
    }

    /// Удаления по фильтру нет намеренно — и переданный фильтр отвергается
    /// вслух: молча выброшенный, он заставил бы агента думать, что удалилось
    /// ровно то, что он описал.
    func testDeletingByFilterIsRefusedRatherThanIgnored() async {
        let backend = Backend()
        let service = await service(clients: [writer()], backend: backend)
        let result = await call(
            service, "delete_documents",
            .object([
                "collection": .string("заметки"),
                "ids": .array([.string("d1")]),
                "filter": .object(["year": .object(["$eq": .int(2024)])]),
            ]),
            key: key
        )
        guard case .failure(let error) = result else { return XCTFail("фильтр принят") }
        XCTAssertEqual(error.code, JSONRPCError.invalidParams)
        XCTAssertNil(backend.received.delete)
    }

    func testDeletingWithoutIdentifiersIsRefused() async {
        let service = await service(clients: [writer()])
        for arguments in [
            JSONValue.object(["collection": .string("заметки")]),
            .object(["collection": .string("заметки"), "ids": .array([])]),
        ] {
            let result = await call(service, "delete_documents", arguments, key: key)
            guard case .failure(let error) = result else { return XCTFail("пустой список принят") }
            XCTAssertEqual(error.code, JSONRPCError.invalidParams)
        }
    }

    /// Переключатель «весь сервер только на чтение» сильнее и права удаления.
    func testTheReadOnlyServerRefusesDeletionToo() async throws {
        let backend = Backend()
        let service = await service(clients: [writer()], backend: backend, readOnly: true)
        let result = try await call(
            service, "delete_documents", Self.arguments(for: MCPToolCatalogue.deleteDocuments), key: key
        ).get()
        XCTAssertEqual(result["isError"], .bool(true))
        XCTAssertNil(backend.received.delete)
    }

    // MARK: - Журнал доступа

    func testEveryToolCallReachesTheAuditLog() async throws {
        let recorded = Recorder()
        let access = AccessController()
        await access.setClients([writer()])
        let service = MCPToolService(
            backend: Backend(), access: access, audit: { recorded.append($0) }
        )

        _ = try await service.call(
            name: "add_documents",
            arguments: .object([
                "collection": .string("заметки"),
                "documents": .array([.object(["text": .string("Договор аренды")])]),
            ]),
            key: key
        ).get()

        let entry = try XCTUnwrap(recorded.entries.first)
        XCTAssertEqual(entry.transport, .mcp)
        XCTAssertEqual(entry.access, .write)
        XCTAssertEqual(entry.operation, "add_documents")
        XCTAssertEqual(entry.collection, "заметки")
        XCTAssertEqual(entry.client, "агент")
        // Полный текст параметров — это и есть то, что записали в базу.
        XCTAssertTrue(entry.parameters?.contains("Договор аренды") ?? false)
        XCTAssertTrue(entry.title.contains("add_documents"), entry.title)
    }

    /// Отказ пишется в журнал наравне с выполненным вызовом: попытка записи,
    /// которую не пропустили, — то самое событие, ради которого журнал ведут.
    func testARefusedWriteIsAuditedToo() async throws {
        let recorded = Recorder()
        let access = AccessController()
        await access.setClients([client(write: false)])
        let service = MCPToolService(
            backend: Backend(), access: access, audit: { recorded.append($0) }
        )

        _ = try await service.call(
            name: "add_documents",
            arguments: Self.arguments(for: MCPToolCatalogue.addDocuments),
            key: key
        ).get()

        let entry = try XCTUnwrap(recorded.entries.first)
        XCTAssertEqual(entry.transport, .mcp)
        XCTAssertTrue(entry.note?.contains("только чтение") ?? false, entry.note ?? "нет причины")
        // Отказ подписан именем клиента, а не префиксом ключа: иначе владелец
        // сверяет его со списком глазами.
        XCTAssertEqual(entry.client, "агент")
    }

    /// Итог удаления в журнале обязателен: «была попытка удаления» без
    /// результата не отвечает на единственный вопрос, ради которого в журнал
    /// заглядывают, — что стало с базой.
    func testTheAuditSaysWhatWasActuallyDeleted() async throws {
        let recorded = Recorder()
        let access = AccessController()
        await access.setClients([writer()])
        let service = MCPToolService(
            backend: Backend(), access: access, audit: { recorded.append($0) }
        )

        _ = try await service.call(
            name: "delete_documents",
            arguments: .object([
                "collection": .string("заметки"),
                "ids": .array([.string("d1"), .string("которого-нет")]),
            ]),
            key: key
        ).get()

        let entry = try XCTUnwrap(recorded.entries.first)
        XCTAssertEqual(entry.access, .write)
        XCTAssertTrue(entry.note?.contains("удалено: d1") ?? false, entry.note ?? "нет итога")
    }

    /// Запись, которая не состоялась, обязана и в журнале выглядеть
    /// несостоявшейся: «документов: 1» у отказа значит, что документ есть.
    func testAFailedWriteIsNotLoggedAsIfItHadHappened() async throws {
        let recorded = Recorder()
        let access = AccessController()
        await access.setClients([writer()])
        var backend = Backend()
        backend.failure = MCPToolFailure("Эти идентификаторы уже заняты: письмо-1.")
        let service = MCPToolService(
            backend: backend, access: access, audit: { recorded.append($0) }
        )

        _ = try await service.call(
            name: "add_documents",
            arguments: Self.arguments(for: MCPToolCatalogue.addDocuments),
            key: key
        ).get()

        let entry = try XCTUnwrap(recorded.entries.first)
        XCTAssertTrue(entry.note?.contains("уже заняты") ?? false, entry.note ?? "нет причины")
        XCTAssertFalse(entry.note?.contains("документов:") ?? false, entry.note ?? "")
    }

    /// Объём ответа в журнале — настоящий, а не ноль.
    ///
    /// Записывался ноль: журнал пишется через `defer`, а возвращаемое значение
    /// оттуда не видно, и никто этого не замечал, потому что столбец «Объём»
    /// показывает сумму запроса и ответа — у чтения запрос крошечный, и разница
    /// между «ответ на сто килобайт» и «ответа не было» на экране не читалась.
    func testTheAuditRecordsHowLargeTheAnswerWas() async throws {
        let recorded = Recorder()
        let access = AccessController()
        await access.setClients([client()])
        let service = MCPToolService(
            backend: Backend(), access: access, audit: { recorded.append($0) }
        )

        let answer = try await service.call(name: "list_collections", arguments: nil, key: key).get()

        let entry = try XCTUnwrap(recorded.entries.first)
        XCTAssertGreaterThan(entry.responseBytes, 0, "объём ответа в журнале не может быть нулевым")
        XCTAssertEqual(
            entry.responseBytes, answer.jsonString?.utf8.count,
            "записан объём именно того, что ушло клиенту"
        )
    }

    /// И у отказа тоже: ответ был, место занял.
    func testAnAuditedRefusalAlsoCarriesItsSize() async throws {
        let recorded = Recorder()
        let access = AccessController()
        await access.setClients([client(write: false)])
        let service = MCPToolService(
            backend: Backend(), access: access, audit: { recorded.append($0) }
        )

        _ = try await service.call(
            name: "add_documents",
            arguments: Self.arguments(for: MCPToolCatalogue.addDocuments),
            key: key
        ).get()

        let entry = try XCTUnwrap(recorded.entries.first)
        XCTAssertGreaterThan(entry.responseBytes, 0, "у отказа ответ тоже есть")
    }

    /// Мегабайтный документ не должен вытеснить из журнала всю историю —
    /// но и потеряться молча тоже.
    func testHugeParametersAreCutInTheLogWithAMark() async throws {
        let recorded = Recorder()
        let access = AccessController()
        await access.setClients([writer()])
        let service = MCPToolService(
            backend: Backend(), access: access, audit: { recorded.append($0) }
        )

        _ = try await service.call(
            name: "add_documents",
            arguments: .object([
                "collection": .string("заметки"),
                "documents": .array([.object([
                    "text": .string(String(repeating: "я", count: 60_000)),
                ])]),
            ]),
            key: key
        ).get()

        let parameters = try XCTUnwrap(recorded.entries.first?.parameters)
        XCTAssertLessThan(parameters.count, 60_000)
        XCTAssertTrue(parameters.contains("обрезан"), "обрезка не помечена")
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [AuditEntry] = []
        var entries: [AuditEntry] { lock.withLock { storage } }
        func append(_ entry: AuditEntry) { lock.withLock { storage.append(entry) } }
    }

    // MARK: - Сервер целиком

    private func request(_ method: String, id: Int = 1, params: [String: JSONValue] = [:]) throws -> Data {
        var object = params
        object["_meta"] = .object([MCPProtocol.metaProtocolVersion: .string(MCPProtocol.version)])
        return try JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string(method),
            "params": .object(object),
        ]))
    }

    func testTheServerAnswersListAndCallAndDeclaresTheToolsCapability() async throws {
        let server = MCPServer(serverVersion: "тест", tools: await service(clients: [client()]))

        let discoveredResponse = await server.respond(to: try request(MCPProtocol.discoverMethod))
        let discovered = try XCTUnwrap(discoveredResponse)
        let discoverJSON = try JSONDecoder().decode(JSONValue.self, from: try discovered.encoded())
        XCTAssertEqual(discoverJSON["result"]?["capabilities"]?["tools"]?["listChanged"], .bool(false))

        let listedResponse = await server.respond(to: try request(MCPProtocol.listToolsMethod), key: key)
        let listed = try XCTUnwrap(listedResponse)
        let listJSON = try JSONDecoder().decode(JSONValue.self, from: try listed.encoded())
        XCTAssertNotNil(listJSON["result"]?["tools"])

        let calledResponse = await server.respond(
            to: try request(MCPProtocol.callToolMethod, id: 2, params: [
                "name": .string("list_collections"),
                "arguments": .object([:]),
            ]),
            key: key
        )
        let called = try XCTUnwrap(calledResponse)
        let callJSON = try JSONDecoder().decode(JSONValue.self, from: try called.encoded())
        XCTAssertEqual(callJSON["result"]?["isError"], .bool(false))
        XCTAssertEqual(callJSON["id"], .int(2))
    }

    /// Сервер без инструментов не объявляет возможность `tools` и отвечает на
    /// `tools/list` «метода нет»: объявленная и не обслуживаемая возможность —
    /// это обещание, по которому клиент построит запрос и получит отказ.
    func testAServerWithoutToolsDoesNotPromiseThem() async throws {
        let server = MCPServer(serverVersion: "тест")
        let discoveredResponse = await server.respond(to: try request(MCPProtocol.discoverMethod))
        let discovered = try XCTUnwrap(discoveredResponse)
        let json = try JSONDecoder().decode(JSONValue.self, from: try discovered.encoded())
        XCTAssertNil(json["result"]?["capabilities"]?["tools"])

        let listedResponse = await server.respond(to: try request(MCPProtocol.listToolsMethod))
        let listed = try XCTUnwrap(listedResponse)
        let listJSON = try JSONDecoder().decode(JSONValue.self, from: try listed.encoded())
        XCTAssertEqual(listJSON["error"]?["code"], .int(JSONRPCError.methodNotFound))
    }
}

/// §D2.5 — сокет как поверхность доступа.
final class MCPSocketPermissionTests: XCTestCase {
    /// Подключиться к сокету Unix может тот, у кого есть право записи на файл.
    /// С обычным umask это «все в системе», а на другом конце — доступ к базе
    /// документов, ограниченный только ключом.
    func testTheSocketIsReadableByItsOwnerAlone() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path
        try XCTSkipIf(path.utf8.count >= 104, "путь не помещается в sockaddr_un")

        let listener = MCPListener(path: path)
        try listener.start()
        defer { listener.stop() }

        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o600, "к сокету не должен подключаться кто угодно")
    }
}

/// §D2.6 — готовая конфигурация для агентского приложения.
final class MCPConnectionConfigTests: XCTestCase {
    /// Форма сверена с документацией MCP: клиенты читают `mcpServers` с
    /// `command` и `env`. Ошибка здесь не ловится ни сборкой, ни тестом
    /// протокола — только чужим приложением, которое молча не увидит сервер.
    func testTheConfigurationHasTheShapeAgentsRead() throws {
        let text = MCPConnectionConfig.json(helperPath: "/Applications/App.app/Contents/MacOS/chromadb-mcp", key: "cdbm_секрет")
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])
        let server = try XCTUnwrap(servers[MCPConnectionConfig.serverName] as? [String: Any])
        XCTAssertEqual(server["command"] as? String, "/Applications/App.app/Contents/MacOS/chromadb-mcp")
        let environment = try XCTUnwrap(server["env"] as? [String: String])
        XCTAssertEqual(environment["CHROMADB_MCP_KEY"], "cdbm_секрет")
    }

    /// Путь к бандлу содержит пробел — без экранирования команда развалится
    /// на две.
    func testTheCommandLineQuotesThePath() {
        let line = MCPConnectionConfig.commandLine(
            helperPath: "/Applications/ChromaDB Manager.app/Contents/MacOS/chromadb-mcp", key: "k"
        )
        XCTAssertTrue(line.contains("\"/Applications/ChromaDB Manager.app/Contents/MacOS/chromadb-mcp\""), line)
    }

    /// Ключа нет — вместо него заметная заглушка, а не пустая строка: пустую
    /// агент примет за ключ и получит отказ, не поняв, что его забыли.
    func testAMissingKeyBecomesAVisiblePlaceholder() throws {
        let text = MCPConnectionConfig.json(helperPath: "/tmp/mcp", key: nil)
        XCTAssertTrue(text.contains(MCPConnectionConfig.keyPlaceholder), text)
    }

    func testTheCheckReportsTheFirstBrokenStep() {
        let check = MCPConnectionCheck(steps: [
            .init(title: "Вспомогательный файл", outcome: .ok, detail: "/tmp/mcp"),
            .init(title: "Связь с приложением", outcome: .failed, detail: "ответа нет"),
            .init(title: "Инструменты", outcome: .ok, detail: "search"),
        ])
        XCTAssertFalse(check.isOK)
        XCTAssertEqual(check.firstProblem?.title, "Связь с приложением")
        XCTAssertTrue(check.summary.contains("ответа нет"))
    }

    /// Связь есть, а подключаться не к чему — это не зелёный итог: он отпустил
    /// бы человека довольным и неподключённым.
    func testAWorkingTransportWithoutAccessIsNotReportedAsReady() {
        let check = MCPConnectionCheck(steps: [
            .init(title: "Связь с приложением", outcome: .ok, detail: "отвечает"),
            .init(title: "Права ключа", outcome: .warning, detail: "ни одной коллекции не открыто"),
        ])
        XCTAssertFalse(check.isOK)
        XCTAssertNil(check.firstProblem)
        XCTAssertTrue(check.summary.contains("ещё не готово"), check.summary)
    }
}

/// §D2.7 — матрица «право × инструмент» целиком, по образцу тестов прокси.
///
/// Отдельным тестом, а не набором частных случаев: права проверяются в двух
/// местах (список инструментов и сам вызов), и разойтись они могут молча —
/// инструмент, которого нет в списке, но который отрабатывает по прямому
/// вызову, это открытая дверь без вывески.
final class MCPPermissionMatrixTests: XCTestCase {
    private let key = "ключ-матрицы"

    private struct Backend: MCPToolBackend {
        final class Touched: @unchecked Sendable {
            var names: Set<String> = []
        }
        let touched = Touched()

        func collections(allowed: [String]) async throws -> [MCPCollectionSummary] {
            touched.names.insert("list_collections")
            return [MCPCollectionSummary(name: "заметки", documentCount: 1, model: nil, metric: nil, dimension: nil)]
        }
        func describe(collection: String) async throws -> MCPCollectionDescription {
            touched.names.insert("describe_collection")
            return MCPCollectionDescription(
                summary: MCPCollectionSummary(name: collection, documentCount: 1, model: nil, metric: nil, dimension: nil),
                fields: [], hasSchema: false, allowsExtraFields: true
            )
        }
        func search(_ request: MCPSearchRequest) async throws -> MCPSearchAnswer {
            touched.names.insert("search")
            return MCPSearchAnswer(documents: [], metric: nil, model: nil)
        }
        func documents(_ request: MCPDocumentsRequest) async throws -> MCPDocumentsAnswer {
            // `get_file` ходит в базу тем же путём, что и `get_documents`,
            // и различает их только просьба об упорядоченной выдаче.
            touched.names.insert(request.orderedByChunkIndex ? "get_file" : "get_documents")
            return MCPDocumentsAnswer(documents: [], hasMore: false)
        }
        func add(_ request: MCPAddRequest) async throws -> MCPAddAnswer {
            touched.names.insert("add_documents")
            return MCPAddAnswer(ids: ["новый"], model: nil)
        }
        func delete(_ request: MCPDeleteRequest) async throws -> MCPDeleteAnswer {
            touched.names.insert("delete_documents")
            return MCPDeleteAnswer(deleted: request.ids, missing: [], keptInTrash: true)
        }
    }

    private struct Role {
        let title: String
        let write: Bool
        let delete: Bool
        let readOnlyServer: Bool
        /// Что этой роли разрешено.
        let allowed: Set<String>
    }

    private static let readTools: Set<String> = [
        "list_collections", "describe_collection", "search", "get_documents", "get_file",
        "collect_mentions",
    ]

    /// Какими вызовами базы оборачиваются разрешённые инструменты.
    ///
    /// Своего метода у `collect_mentions` нет намеренно: он обходит коллекцию
    /// тем же `get_documents`, только один раз вместо страницы за страницей.
    private static func backendCalls(for tools: Set<String>) -> Set<String> {
        var names = tools
        if names.remove("collect_mentions") != nil { names.insert("get_documents") }
        return names
    }

    private func arguments(_ name: String) -> JSONValue {
        var object: [String: JSONValue] = ["collection": .string("заметки")]
        if name == "search" { object["query"] = .string("запрос") }
        if name == "add_documents" { object["documents"] = .array([.object(["text": .string("текст")])]) }
        if name == "delete_documents" { object["ids"] = .array([.string("d1")]) }
        if name == "get_file" { object["file"] = .string("папка/файл.md") }
        if name == "collect_mentions" { object["contains"] = .string("приемк") }
        return .object(object)
    }

    func testEveryRoleGetsExactlyTheToolsItMay() async throws {
        let roles = [
            Role(title: "только чтение", write: false, delete: false, readOnlyServer: false,
                 allowed: Self.readTools),
            Role(title: "чтение и запись", write: true, delete: false, readOnlyServer: false,
                 allowed: Self.readTools.union(["add_documents"])),
            Role(title: "запись и удаление", write: true, delete: true, readOnlyServer: false,
                 allowed: Self.readTools.union(["add_documents", "delete_documents"])),
            // Сервер в режиме только чтения сильнее любых прав ключа.
            Role(title: "полные права при сервере только на чтение", write: true, delete: true,
                 readOnlyServer: true, allowed: Self.readTools),
        ]

        for role in roles {
            let backend = Backend()
            let client = ExternalClient(
                name: role.title,
                keyHash: ClientKey.hash(key),
                keyPrefix: String(key.prefix(4)),
                permissions: ClientPermissions(
                    collections: ["заметки"],
                    allowsWrite: role.write,
                    requestsPerMinute: 600,
                    burst: 600,
                    allowsDelete: role.delete
                )
            )
            let access = AccessController()
            await access.setClients([client])
            let service = MCPToolService(
                backend: backend, access: access, isReadOnlyServer: { role.readOnlyServer }
            )

            // 1. Список предлагает ровно разрешённое.
            let listed = await service.list(key: key)
            guard case .array(let tools)? = listed["tools"] else {
                return XCTFail("\(role.title): нет списка инструментов")
            }
            XCTAssertEqual(
                Set(tools.compactMap { $0["name"]?.stringValue }), role.allowed,
                "\(role.title): список инструментов разошёлся с правами"
            )

            // 2. Прямой вызов подчиняется тем же правам — и до базы отказ
            //    не доходит.
            for tool in MCPToolCatalogue.all {
                let result = try await service.call(
                    name: tool.name, arguments: arguments(tool.name), key: key
                ).get()
                let isError = result["isError"]?.boolValue ?? false
                XCTAssertEqual(
                    !isError, role.allowed.contains(tool.name),
                    "\(role.title) × \(tool.name): права разошлись со списком"
                )
            }
            XCTAssertEqual(
                backend.touched.names, Self.backendCalls(for: role.allowed),
                "\(role.title): до базы дошло не то, что разрешено"
            )
        }
    }

    /// Ключ, которого нет в реестре, не получает ничего — ни чтения, ни записи.
    func testAnUnregisteredKeyReachesNothing() async throws {
        let backend = Backend()
        let access = AccessController()
        await access.setClients([])
        let service = MCPToolService(backend: backend, access: access)

        for tool in MCPToolCatalogue.all {
            let result = try await service.call(
                name: tool.name, arguments: arguments(tool.name), key: "чужой"
            ).get()
            XCTAssertEqual(result["isError"], .bool(true), tool.name)
        }
        XCTAssertTrue(backend.touched.names.isEmpty, "до базы дошёл вызов незарегистрированного ключа")
    }
}

/// §D2.7 — разбор и формирование сообщений на зафиксированных фикстурах.
///
/// Фикстуры записаны текстом, а не собраны кодом: тест, строящий запрос теми же
/// средствами, что и сервер, проверяет согласованность кода с собой, а не
/// с протоколом. Эти строки — то, что реально приходит от клиента.
final class MCPFixtureTests: XCTestCase {
    private func respond(_ text: String) async throws -> JSONValue {
        let server = MCPServer(instructions: "тест", serverVersion: "1.0")
        let response = await server.respond(to: Data(text.utf8))
        let outgoing = try XCTUnwrap(response)
        return try JSONDecoder().decode(JSONValue.self, from: try outgoing.encoded())
    }

    func testDiscoverFixture() async throws {
        let answer = try await respond("""
        {"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"проверка","version":"1"}}}}
        """)
        XCTAssertEqual(answer["jsonrpc"], .string("2.0"))
        XCTAssertEqual(answer["id"], .int(1))
        XCTAssertEqual(answer["result"]?["resultType"], .string("complete"))
        XCTAssertEqual(
            answer["result"]?["supportedVersions"], .array(MCPProtocol.supportedVersions.map(JSONValue.string))
        )
        // Сведения о сервере живут в `_meta`, а не рядом с возможностями.
        XCTAssertNotNil(answer["result"]?["_meta"]?["io.modelcontextprotocol/serverInfo"])
    }

    func testWrongVersionFixture() async throws {
        let answer = try await respond("""
        {"jsonrpc":"2.0","id":"строковый-id","method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2024-11-05"}}}
        """)
        // Идентификатор возвращается той же породы, какой пришёл.
        XCTAssertEqual(answer["id"], .string("строковый-id"))
        XCTAssertEqual(answer["error"]?["code"], .int(-32022))
        XCTAssertEqual(
            answer["error"]?["data"]?["supported"], .array(MCPProtocol.supportedVersions.map(JSONValue.string))
        )
    }

    /// настоящее рукопожатие настоящего клиента старой эпохи.
    func testLegacyInitializeFixture() async throws {
        let answer = try await respond("""
        {"jsonrpc":"2.0","id":7,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"старый","version":"0.1"}}}
        """)
        XCTAssertNil(answer["error"], "старая эпоха обслуживается с 9 августа 2026 года")
        XCTAssertEqual(answer["result"]?["protocolVersion"], .string("2024-11-05"))
        XCTAssertNotNil(answer["result"]?["capabilities"])
        XCTAssertEqual(answer["result"]?["serverInfo"]?["name"], .string(MCPProtocol.serverName))
    }

    /// И следом — то, ради чего рукопожатие и делалось: запрос без `_meta`
    /// обязан дойти до маршрутизации, а не быть отвергнутым по версии.
    ///
    /// Инструментов у этой фикстуры нет вовсе, поэтому ответ — «нет такого
    /// метода» (−32601). Важно, что это именно он, а не отказ по версии
    /// (−32022): первый значит «дошло и разобрано», второй значил бы, что
    /// старую эпоху по-прежнему не пускают на порог.
    func testLegacyRequestWithoutMetaReachesRouting() async throws {
        let answer = try await respond("""
        {"jsonrpc":"2.0","id":8,"method":"tools/list","params":{}}
        """)
        XCTAssertEqual(answer["error"]?["code"], .int(-32601))
    }

    func testUnparseableFixture() async throws {
        let answer = try await respond("{это не json")
        XCTAssertEqual(answer["id"], .null)
        XCTAssertEqual(answer["error"]?["code"], .int(-32700))
    }
}
