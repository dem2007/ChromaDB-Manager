import Foundation

public struct ChromaEndpoint: Hashable, Codable {
    public static let defaultTenant = "default_tenant"
    public static let defaultDatabase = "default_database"

    public var host: String
    public var port: Int
    public var useTLS: Bool
    public var tenant: String
    public var database: String
    /// Extra headers — the auth token is injected here, never logged.
    public var headers: [String: String]

    public init(
        host: String = "localhost",
        port: Int = 8000,
        useTLS: Bool = false,
        tenant: String = ChromaEndpoint.defaultTenant,
        database: String = ChromaEndpoint.defaultDatabase,
        headers: [String: String] = [:]
    ) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.tenant = tenant
        self.database = database
        self.headers = headers
    }

    public var baseURLString: String {
        "\(useTLS ? "https" : "http")://\(host):\(port)"
    }

    /// Everything lives under the v2 prefix; v1 was removed from ChromaDB.
    public static let apiPrefix = "/api/v2"

    public var collectionsPath: String {
        "\(Self.apiPrefix)/tenants/\(tenant)/databases/\(database)/collections"
    }
}

public enum ChromaError: LocalizedError {
    case notConfigured
    case unreachable(endpoint: String, reason: String)
    /// The server still speaks the removed v1 API.
    case serverTooOld(endpoint: String)
    case api(status: Int, code: String?, message: String)
    case decoding(String)
    case resetForbidden
    case unauthorized
    case dimensionMismatch(expected: Int, got: Int)
    case collectionNotFound(String)
    case tenantNotFound(String)
    case databaseNotFound(database: String, tenant: String)
    /// A request the client refuses to send at all.
    case invalidRequest(String)
    /// The connection was opened for reading only. Refused here, before a
    /// request exists: writes arrive from synchronisation, import and MCP, not
    /// just from buttons that could have been hidden.
    case readOnly(operation: String)
    case timedOut(operation: ChromaOperation, seconds: TimeInterval)
    /// Some of the sub-batches went in and one did not. There are no
    /// transactions in ChromaDB, so this state is real and has to be told, not
    /// smoothed over.
    case partialWrite(PartialWrite)

    public struct PartialWrite: Sendable, Hashable {
        public let written: Int
        public let total: Int
        /// 1-based, the way it is shown to the user.
        public let failedBatch: Int
        public let batchCount: Int
        public let reason: String

        public init(written: Int, total: Int, failedBatch: Int, batchCount: Int, reason: String) {
            self.written = written
            self.total = total
            self.failedBatch = failedBatch
            self.batchCount = batchCount
            self.reason = reason
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "Подключение к ChromaDB не настроено. Откройте раздел «Подключение».")
        case .unreachable(let endpoint, let reason):
            return String(localized: "ChromaDB недоступна по адресу \(endpoint): \(reason)")
        case .serverTooOld(let endpoint):
            return String(localized: "Сервер по адресу \(endpoint) отвечает по API v1, который удалён из ChromaDB. Требуется ChromaDB 1.0 или новее.")
        case .api(let status, let code, let message):
            return String(localized: "ChromaDB вернула ошибку \(status)\(code.map { " (\($0))" } ?? ""): \(message)")
        case .decoding(let details):
            return String(localized: "Не удалось разобрать ответ ChromaDB: \(details)")
        case .resetForbidden:
            return String(localized: "Сервер запрещает сброс базы: в его конфигурации allow_reset выключен.")
        case .unauthorized:
            return String(localized: "Сервер отклонил запрос: неверный или отсутствующий токен доступа.")
        case .dimensionMismatch(let expected, let got):
            return String(localized: "Размерность вектора не совпадает: коллекция ожидает \(expected), модель выдала \(got).")
        case .collectionNotFound(let name):
            return String(localized: "Коллекция «\(name)» не найдена.")
        case .tenantNotFound(let name):
            return String(localized: "Тенант «\(name)» не найден на этом сервере.")
        case .databaseNotFound(let database, let tenant):
            return String(localized: "База «\(database)» в тенанте «\(tenant)» не найдена.")
        case .invalidRequest(let details):
            return details
        case .readOnly(let operation):
            return String(localized: "Подключение открыто только для чтения: «\(operation)» не выполняется.")
        case .timedOut(let operation, let seconds):
            return String(localized: "\(operation.title): сервер не ответил за \(Int(seconds)) с.")
        case .partialWrite(let failure):
            return String(localized: "Записано \(failure.written) из \(failure.total); сбой на части \(failure.failedBatch) из \(failure.batchCount): \(failure.reason)")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .timedOut:
            return String(localized: "Увеличьте таймаут для этого класса операций в настройках или проверьте нагрузку на сервер.")
        case .partialWrite:
            return String(localized: "Повторите операцию: записи с теми же идентификаторами будут перезаписаны, а не продублированы.")
        case .serverTooOld:
            return String(localized: "Обновите ChromaDB на сервере до версии 1.0 или новее.")
        case .resetForbidden:
            return String(localized: "Включите allow_reset в профиле сервера и перезапустите его — приложение запишет это в конфигурацию.")
        case .unauthorized:
            return String(localized: "Проверьте токен в настройках профиля сервера.")
        case .readOnly:
            return String(localized: "Снимите режим «только чтение» в профиле подключения, если правки действительно нужны.")
        case .dimensionMismatch:
            return String(localized: "Выберите модель с той же размерностью или клонируйте коллекцию под новую модель (этап 2).")
        case .unreachable:
            return String(localized: "Проверьте, запущен ли сервер, и правильность host/port.")
        case .tenantNotFound, .databaseNotFound:
            return String(localized: "Проверьте написание в профиле подключения или создайте недостающее — приложение предложит это сделать.")
        default:
            return nil
        }
    }
}

public struct ChromaServerInfo {
    public let version: String
    public let isHealthy: Bool
}

/// HTTP client for the ChromaDB REST API v2.
///
/// This is the single data path of the app: neither database files nor CLI
/// output are ever parsed for data.
public actor ChromaClient {
    public let endpoint: ChromaEndpoint
    /// fixed at creation, like the address. A connection opened for reading
    /// cannot become writable — a new client is created instead (A10).
    public let isReadOnly: Bool
    private let transport: HTTPTransport
    private let timeouts: TimeoutSettings
    private let retries: RetryPolicy
    private let log: LogHandler
    /// name → UUID, resolved once per collection and reused.
    private var collectionIDs: [String: String] = [:]
    /// Identifiers this client has already replaced, old UUID → name.
    ///
    /// Screens hold on to the collection objects they were given, so an id can
    /// still arrive here long after the cache moved on. Without this the first
    /// call after a re-creation would be rescued and the second would not.
    /// Cleared whenever the list is re-read, which bounds it.
    private var retiredIDs: [String: String] = [:]
    /// Asked once per connection, like the server version.
    private var cachedLimits: WriteLimits?

    public init(
        endpoint: ChromaEndpoint,
        log: @escaping LogHandler = noopLogHandler,
        timeouts: TimeoutSettings = TimeoutSettings(),
        retries: RetryPolicy = .reads,
        transport: HTTPTransport = URLSessionTransport(),
        isReadOnly: Bool = false
    ) {
        self.endpoint = endpoint
        self.isReadOnly = isReadOnly
        self.log = log
        self.timeouts = timeouts
        self.retries = retries
        self.transport = transport
    }

    /// every write passes through here before anything is built or sent.
    private func refuseIfReadOnly(_ operation: String) throws {
        guard isReadOnly else { return }
        log(.warning, "ChromaDB", "Подключение только для чтения: «\(operation)» отклонена до отправки запроса")
        throw ChromaError.readOnly(operation: operation)
    }

    // MARK: - Connection

    private struct HealthcheckResponse: Decodable {
        let is_executor_ready: Bool?
        let is_log_client_ready: Bool?
    }

    /// `GET /api/v2/healthcheck` + `GET /api/v2/version` + the write limits.
    @discardableResult
    public func connect() async throws -> ChromaServerInfo {
        let health = try await request(
            HealthcheckResponse.self,
            method: "GET",
            path: "\(ChromaEndpoint.apiPrefix)/healthcheck",
            operation: .liveness
        )
        let raw = (try? await rawString(path: "\(ChromaEndpoint.apiPrefix)/version")) ?? ""
        let version = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
        let healthy = (health.is_executor_ready ?? true) && (health.is_log_client_ready ?? true)
        log(.success, "ChromaDB", "Подключение к \(endpoint.baseURLString) — версия \(version.isEmpty ? "неизвестна" : version)")
        _ = await writeLimits()
        return ChromaServerInfo(version: version, isHealthy: healthy)
    }

    public func healthcheck() async throws {
        _ = try await requestRaw(method: "GET", path: "\(ChromaEndpoint.apiPrefix)/healthcheck", operation: .liveness)
    }

    // MARK: - Write limits

    private struct PreflightResponse: Decodable {
        let max_batch_size: Int?
    }

    /// How many records the server takes in one request.
    ///
    /// Verified on 1.4.4: `GET /api/v2/pre-flight-checks` answers
    /// `{"max_batch_size": 5461, ...}`. A server that does not answer, or
    /// answers something unreadable, gets the conservative fallback and says so
    /// — silently assuming a large limit only moves the failure to write time
    ///.
    public func writeLimits() async -> WriteLimits {
        if let cachedLimits { return cachedLimits }
        var limits = WriteLimits()
        do {
            let payload = try await request(
                PreflightResponse.self,
                method: "GET",
                path: "\(ChromaEndpoint.apiPrefix)/pre-flight-checks",
                operation: .liveness
            )
            if let value = payload.max_batch_size, value > 0 {
                limits = WriteLimits(maxRecords: value, isReportedByServer: true)
                log(.info, "ChromaDB", "Лимит записей в одном запросе: \(value)")
            } else {
                log(.warning, "ChromaDB", "Сервер не сообщил лимит батча — используется безопасное значение \(WriteLimits.fallbackRecords)")
            }
        } catch {
            log(.warning, "ChromaDB", "Лимит батча не определён (\(error.localizedDescription)) — используется безопасное значение \(WriteLimits.fallbackRecords)")
        }
        cachedLimits = limits
        return limits
    }

    // MARK: - Tenants and databases

    private struct DatabaseRecord: Decodable {
        let id: String
        let name: String
        let tenant: String?
    }

    /// Databases of the current tenant.
    ///
    /// Tenants themselves cannot be listed — `GET /api/v2/tenants` answers
    /// `405` — so the tenant stays a text field while the database gets
    /// a picker.
    public func listDatabases(tenant: String? = nil) async throws -> [String] {
        let owner = tenant ?? endpoint.tenant
        let records = try await request(
            [DatabaseRecord].self,
            method: "GET",
            path: "\(ChromaEndpoint.apiPrefix)/tenants/\(owner)/databases",
            operation: .metadata
        )
        return records.map(\.name).sorted()
    }

    /// Whether the tenant and database in the endpoint actually exist.
    ///
    /// Worth asking explicitly: listing collections of a database that is not
    /// there answers `200 []`, so a typo looks exactly like an empty database
    ///.
    public func verifyTenantAndDatabase() async throws {
        do {
            _ = try await requestRaw(
                method: "GET",
                path: "\(ChromaEndpoint.apiPrefix)/tenants/\(endpoint.tenant)",
                operation: .metadata
            )
        } catch ChromaError.api(let status, _, _) where status == 404 {
            throw ChromaError.tenantNotFound(endpoint.tenant)
        }

        do {
            _ = try await requestRaw(
                method: "GET",
                path: "\(ChromaEndpoint.apiPrefix)/tenants/\(endpoint.tenant)/databases/\(endpoint.database)",
                operation: .metadata
            )
        } catch ChromaError.api(let status, _, _) where status == 404 {
            throw ChromaError.databaseNotFound(database: endpoint.database, tenant: endpoint.tenant)
        }
    }

    /// `POST /tenants`. Creating one is a real decision — data in a new tenant
    /// is invisible from the old one — so the UI asks first.
    public func createTenant(name: String) async throws {
        try refuseIfReadOnly("создание тенанта")
        _ = try await requestRaw(
            method: "POST",
            path: "\(ChromaEndpoint.apiPrefix)/tenants",
            body: ["name": name],
            operation: .management
        )
        log(.warning, "ChromaDB", "Создан тенант «\(name)»")
    }

    public func createDatabase(name: String, tenant: String? = nil) async throws {
        try refuseIfReadOnly("создание базы")
        let owner = tenant ?? endpoint.tenant
        _ = try await requestRaw(
            method: "POST",
            path: "\(ChromaEndpoint.apiPrefix)/tenants/\(owner)/databases",
            body: ["name": name],
            operation: .management
        )
        log(.success, "ChromaDB", "Создана база «\(name)» в тенанте «\(owner)»")
    }

    // MARK: - Collections

    public func listCollections(withCounts: Bool = true) async throws -> [ChromaCollection] {
        var collections = try await request([ChromaCollection].self, method: "GET", path: endpoint.collectionsPath, operation: .metadata)
        // Rebuilt rather than merged: a name that is no longer on the server
        // must not survive in the cache, and this is the one call the refresh
        // button makes (rule 3).
        collectionIDs.removeAll(keepingCapacity: true)
        retiredIDs.removeAll(keepingCapacity: true)
        for index in collections.indices {
            collectionIDs[collections[index].name] = collections[index].id
            if withCounts {
                collections[index].documentCount = try? await count(collectionID: collections[index].id)
            }
        }
        return collections
    }

    public func collection(named name: String) async throws -> ChromaCollection {
        guard let match = try await listCollections(withCounts: false).first(where: { $0.name == name }) else {
            throw ChromaError.collectionNotFound(name)
        }
        return match
    }

    /// Data operations address collections by UUID; names are resolved once.
    public func resolveID(of name: String) async throws -> String {
        if let cached = collectionIDs[name] { return cached }
        let resolved = try await collection(named: name).id
        collectionIDs[name] = resolved
        return resolved
    }

    public func count(collectionID: String) async throws -> Int {
        try await retryingStaleID(collectionID) { id in
            let data = try await requestRaw(method: "GET", path: "\(endpoint.collectionsPath)/\(id)/count", operation: .metadata)
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let value = Int(text) else {
                throw ChromaError.decoding("ожидалось число в ответе /count, получено: \(text)")
            }
            return value
        }
    }

    @discardableResult
    /// Creates a collection, always saying which metric it wants.
    ///
    /// The server's own default is `l2`, and almost every embedding model in
    /// LM Studio is trained for cosine — a collection that quietly takes the
    /// default just ranks worse, with nothing to notice and no way back except
    /// re-creating it. So the metric is never left to the server, and
    /// what the server actually stored is read back from the response rather
    /// than assumed from the request not failing.
    public func createCollection(
        name: String,
        metadata: ChromaMetadata? = nil,
        configuration: CollectionConfiguration? = nil,
        getOrCreate: Bool = false
    ) async throws -> ChromaCollection {
        try refuseIfReadOnly("создание коллекции")
        var body: [String: Any] = ["name": name, "get_or_create": getOrCreate]
        var metadata = metadata ?? [:]
        if let configuration {
            body["configuration"] = configuration.requestBody()
            // Both spellings at once — see `CollectionConfiguration.requestBody`.
            metadata.merge(configuration.legacyMetadata) { current, _ in current }
            metadata[CollectionBindingKeys.space] = .string(configuration.metric.rawValue)
        }
        if !metadata.isEmpty {
            body["metadata"] = try encodeToJSONObject(metadata)
        }
        let collection = try await request(
            ChromaCollection.self,
            method: "POST",
            path: endpoint.collectionsPath,
            body: body,
            operation: .management
        )
        collectionIDs[collection.name] = collection.id

        if let requested = configuration?.metric, let actual = collection.space, actual != requested {
            // The setting did not take. Saying so is the whole point: pretending
            // otherwise leaves the user with a collection that ranks by a metric
            // they did not choose and cannot change.
            log(.warning, "ChromaDB", "Коллекция «\(name)»: запрошена метрика \(requested.rawValue), сервер записал \(actual.rawValue)")
        } else {
            log(.success, "ChromaDB", "Коллекция «\(name)» создана (id \(collection.id), метрика \(collection.space?.rawValue ?? "по умолчанию сервера"))")
        }
        return collection
    }

    /// `PUT /collections/{id}` — replaces the whole metadata dictionary,
    /// so callers must pass the merged result, not a delta.
    public func updateCollection(
        id: String,
        newName: String? = nil,
        metadata: ChromaMetadata? = nil
    ) async throws {
        try refuseIfReadOnly("изменение коллекции")
        var body: [String: Any] = [:]
        if let newName { body["new_name"] = newName }
        if let metadata { body["new_metadata"] = try encodeToJSONObject(metadata) }
        guard !body.isEmpty else { return }
        _ = try await requestRaw(method: "PUT", path: "\(endpoint.collectionsPath)/\(id)", body: body, operation: .management)
        log(.info, "ChromaDB", "Метаданные коллекции обновлены (id \(id))")
    }

    public func deleteCollection(name: String) async throws {
        try refuseIfReadOnly("удаление коллекции")
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        _ = try await requestRaw(method: "DELETE", path: "\(endpoint.collectionsPath)/\(encoded)", operation: .management)
        collectionIDs.removeValue(forKey: name)
        log(.warning, "ChromaDB", "Коллекция «\(name)» удалена")
    }

    // MARK: - Documents

    public func getDocuments(
        collectionID: String,
        limit: Int = 100,
        offset: Int = 0,
        filter: DocumentFilter? = nil,
        includeEmbeddings: Bool = false,
        /// Тексты документов. Выключается там, где нужен только перечень:
        /// упорядочивание чанков файла читает метаданные всех чанков
        /// сразу, и тянуть при этом сами тексты — это мегабайты ради одного
        /// поля `chunk_index`.
        includeDocuments: Bool = true,
        ids: [String]? = nil,
        caller: String = #fileID,
        callerLine: Int = #line
    ) async throws -> [DocumentRecord] {
        var include = includeDocuments ? ["documents", "metadatas"] : ["metadatas"]
        if includeEmbeddings {
            include.append("embeddings")
            // not a refusal — export asks for exactly this, legitimately —
            // but a page of vectors is almost always someone loading them into a
            // list screen, and that has to be visible without a packet capture.
            if limit > 1 || ids?.isEmpty != false {
                log(.warning, "ChromaDB",
                    "Запрошены векторы страницей: limit \(limit.plainDigits), явных id \(ids?.count.plainDigits ?? "нет") — \(caller):\(callerLine.plainDigits)")
            }
        }
        var body: [String: Any] = ["limit": limit, "offset": offset, "include": include]
        // Fetching by id is how an in-place rewrite walks a collection: paging by
        // offset would shift under its own writes.
        if let ids, !ids.isEmpty { body["ids"] = ids }
        if let filter {
            if let clause = try filter.whereClause() { body["where"] = clause }
            if let clause = filter.whereDocumentClause() { body["where_document"] = clause }
        }
        let payload = try await retryingStaleID(collectionID) { id in
            try await request(
                GetResponse.self,
                method: "POST",
                path: "\(endpoint.collectionsPath)/\(id)/get",
                body: body,
                operation: .fetch
            )
        }
        return payload.records
    }

    /// Vectors for specific documents. Fetched on demand: pulling embeddings
    /// for a whole page would move megabytes for a preview of a few numbers.
    public func embeddings(collectionID: String, ids: [String]) async throws -> [String: [Double]] {
        guard !ids.isEmpty else { return [:] }
        let payload = try await retryingStaleID(collectionID) { id in
            try await request(
                GetResponse.self,
                method: "POST",
                path: "\(endpoint.collectionsPath)/\(id)/get",
                body: ["ids": ids, "include": ["embeddings"]],
                operation: .fetch
            )
        }
        var result: [String: [Double]] = [:]
        for (index, id) in payload.ids.enumerated() {
            guard let vectors = payload.embeddings, index < vectors.count, let vector = vectors[index] else { continue }
            result[id] = vector
        }
        return result
    }

    /// Partial update of existing documents.
    ///
    /// Note: changing `document` without sending a new `embedding` leaves the
    /// old vector in place (verified on 1.4.4), so callers that edit text must
    /// always recompute it.
    public func updateDocuments(collectionID: String, updates: [DocumentUpdate]) async throws {
        try refuseIfReadOnly("правка документов")
        guard !updates.isEmpty else { return }
        var body: [String: Any] = ["ids": updates.map(\.id)]
        if updates.contains(where: { $0.document != nil }) {
            body["documents"] = updates.map { $0.document as Any? ?? NSNull() }
        }
        if updates.contains(where: { $0.embedding != nil }) {
            body["embeddings"] = updates.map { $0.embedding as Any? ?? NSNull() }
        }
        if updates.contains(where: { $0.metadata != nil }) {
            body["metadatas"] = try updates.map { update -> Any in
                guard let metadata = update.metadata else { return NSNull() }
                var object = try encodeToJSONObject(metadata)
                // Явный `null` — единственное, чем у ChromaDB удаляется ключ
                // метаданных: `update` их **сливает**, и ключ, которого нет
                // в запросе, остаётся прежним.
                for key in update.removedMetadataKeys where object[key] == nil {
                    object[key] = NSNull()
                }
                return object
            }
        }
        try await retryingStaleID(collectionID) { id in
            _ = try await requestRaw(
                method: "POST",
                path: "\(endpoint.collectionsPath)/\(id)/update",
                body: body,
                operation: .write
            )
        }
        log(.info, "ChromaDB", "Обновлено документов: \(updates.count)")
    }

    /// Dimension of vectors already stored in a collection, read from one
    /// record. Used when adopting collections created outside this app.
    public func storedDimension(collectionID: String) async throws -> Int? {
        let payload = try await retryingStaleID(collectionID) { id in
            try await request(
                GetResponse.self,
                method: "POST",
                path: "\(endpoint.collectionsPath)/\(id)/get",
                body: ["limit": 1, "include": ["embeddings"]],
                operation: .fetch
            )
        }
        return payload.embeddings?.compactMap { $0 }.first?.count
    }

    /// Nearest documents, optionally narrowed by the same filter the browser
    /// uses.
    ///
    /// `where` and `where_document` are independent parameters and go together
    /// with the vector — that combination is the whole point of «найди похожее,
    /// но только там, где встречается слово X» (verified in.
    public func query(
        collectionID: String,
        embedding: [Double],
        nResults: Int = 5,
        filter: DocumentFilter? = nil,
        includeEmbeddings: Bool = false
    ) async throws -> [QueryHit] {
        // Vectors only when something is going to do arithmetic on them. The
        // pool MMR asks for is bounded, which is what makes this a legitimate
        // case rather than a page of embeddings loaded into a list.
        var include = ["documents", "metadatas", "distances"]
        if includeEmbeddings { include.append("embeddings") }
        var body: [String: Any] = [
            "query_embeddings": [embedding],
            "n_results": nResults,
            "include": include,
        ]
        if let filter {
            if let clause = try filter.whereClause() { body["where"] = clause }
            if let clause = filter.whereDocumentClause() { body["where_document"] = clause }
        }
        let payload = try await retryingStaleID(collectionID) { id in
            try await request(
                QueryResponse.self,
                method: "POST",
                path: "\(endpoint.collectionsPath)/\(id)/query",
                body: body,
                operation: .query
            )
        }
        return payload.hits
    }

    /// Which of these ids are already in the collection.
    ///
    /// Needed because `add` does **not** report a conflict: on 1.4.4 it answers
    /// 201 and silently keeps the existing document, so «добавить» would look
    /// like it worked while changing nothing. The only way to know is to
    /// ask first.
    public func existingIDs(collectionID: String, ids: [String]) async throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let limits = await writeLimits()
        var found: Set<String> = []
        var index = 0
        while index < ids.count {
            try Task.checkCancellation()
            let slice = Array(ids[index..<min(index + limits.maxRecords, ids.count)])
            let payload = try await retryingStaleID(collectionID) { id in
                try await request(
                    GetResponse.self,
                    method: "POST",
                    path: "\(endpoint.collectionsPath)/\(id)/get",
                    body: ["ids": slice, "include": []],
                    operation: .fetch
                )
            }
            found.formUnion(payload.ids)
            index += limits.maxRecords
        }
        return found
    }

    public func add(collectionID: String, records: [EmbeddedRecord]) async throws {
        try await write(collectionID: collectionID, records: records, operation: "add")
    }

    public func upsert(collectionID: String, records: [EmbeddedRecord]) async throws {
        try await write(collectionID: collectionID, records: records, operation: "upsert")
    }

    /// Sends the records in as few requests as the server allows.
    ///
    /// Splitting lives here rather than in each caller so that every write path
    /// — manual add, import, source sync, re-embedding — gets it without having
    /// to remember. Cancellation is honoured between sub-batches and
    /// never inside one: a request already on the wire is going to be applied
    /// whatever the app does with it, so pretending otherwise would only lose
    /// track of what was written.
    private func write(collectionID: String, records: [EmbeddedRecord], operation: String) async throws {
        try refuseIfReadOnly("запись документов")
        guard !records.isEmpty else { return }
        let limits = await writeLimits()
        let batches = try BatchSplitter.split(records, limits: limits)

        // A collection that disappeared mid-write is re-resolved and the whole
        // write starts again: the re-created collection is empty, so repeating
        // the earlier sub-batches is what makes it complete rather than
        // duplicated.
        try await retryingStaleID(collectionID) { resolvedID in
            var written = 0
            for (index, batch) in batches.enumerated() {
                do {
                    try Task.checkCancellation()
                    let body: [String: Any] = [
                        "ids": batch.map(\.id),
                        "embeddings": batch.map(\.embedding),
                        "documents": batch.map(\.document),
                        "metadatas": try batch.map { try encodeToJSONObject($0.metadata) },
                    ]
                    _ = try await requestRaw(
                        method: "POST",
                        path: "\(endpoint.collectionsPath)/\(resolvedID)/\(operation)",
                        body: body,
                        operation: .write
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch ChromaError.collectionNotFound(let subject) {
                    // Not a partial write: nothing survives in a collection that is
                    // gone. Let the caller above re-resolve and start over.
                    throw ChromaError.collectionNotFound(subject)
                } catch {
                    // Nothing written yet means nothing partial happened; the
                    // caller gets the real error instead of a wrapper around it.
                    guard written > 0 else { throw error }
                    let failure = ChromaError.PartialWrite(
                        written: written,
                        total: records.count,
                        failedBatch: index + 1,
                        batchCount: batches.count,
                        reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    )
                    log(.error, "ChromaDB", "Частичная запись: \(written) из \(records.count), сбой на части \(index + 1) из \(batches.count)")
                    throw ChromaError.partialWrite(failure)
                }
                written += batch.count
                if batches.count > 1 {
                    log(.info, "ChromaDB", "Запись частями: \(index + 1)/\(batches.count), записей \(written) из \(records.count)")
                }
            }
        }
    }

    public func deleteDocuments(collectionID: String, ids: [String]) async throws {
        try refuseIfReadOnly("удаление документов")
        guard !ids.isEmpty else { return }
        let limits = await writeLimits()
        try await retryingStaleID(collectionID) { resolvedID in
            var index = 0
            while index < ids.count {
                try Task.checkCancellation()
                let slice = Array(ids[index..<min(index + limits.maxRecords, ids.count)])
                _ = try await requestRaw(
                    method: "POST",
                    path: "\(endpoint.collectionsPath)/\(resolvedID)/delete",
                    body: ["ids": slice],
                    operation: .write
                )
                index += limits.maxRecords
            }
        }
    }

    /// Deletes everything matching a filter and returns how many rows went.
    ///
    /// Used by source sync to replace a changed file's chunks: their count can
    /// differ from last time, so deleting by remembered ids would leave the tail
    /// behind. Verified on 1.4.4: the response is `{"deleted": N}` and N is the
    /// real number of rows for a `where` delete (for a delete by ids the server
    /// simply echoes the number of ids, so that number is not used).
    ///
    /// An empty filter is refused here rather than by the server — a where-clause
    /// that accidentally matches everything must not be able to wipe a collection.
    @discardableResult
    public func deleteDocuments(collectionID: String, filter: DocumentFilter) async throws -> Int {
        try refuseIfReadOnly("удаление документов по фильтру")
        guard let clause = try filter.whereClause() else {
            throw ChromaError.invalidRequest(String(localized: "Удаление по фильтру без условий запрещено — так можно случайно стереть всю коллекцию."))
        }
        var body: [String: Any] = ["where": clause]
        if let documentClause = filter.whereDocumentClause() { body["where_document"] = documentClause }

        let data = try await retryingStaleID(collectionID) { id in
            try await requestRaw(
                method: "POST",
                path: "\(endpoint.collectionsPath)/\(id)/delete",
                body: body,
                operation: .write
            )
        }
        struct DeleteResponse: Decodable { let deleted: Int? }
        let deleted = (try? JSONDecoder().decode(DeleteResponse.self, from: data))?.deleted ?? 0
        if deleted > 0 {
            log(.info, "ChromaDB", "Удалено документов по фильтру: \(deleted)")
        }
        return deleted
    }

    // MARK: - Reset

    /// Wipes the database. Requires `allow_reset: true` in the server config —
    /// otherwise the server answers 403 and the app explains how to enable it
    /// instead of deleting collections one by one behind the user's back.
    public func reset() async throws {
        try refuseIfReadOnly("сброс базы")
        do {
            _ = try await requestRaw(method: "POST", path: "\(ChromaEndpoint.apiPrefix)/reset", operation: .management)
            log(.warning, "ChromaDB", "Выполнен полный сброс базы")
        } catch ChromaError.api(let status, _, let message) {
            if status == 403 || message.lowercased().contains("reset is disabled") {
                throw ChromaError.resetForbidden
            }
            throw ChromaError.api(status: status, code: nil, message: message)
        }
    }

    // MARK: - Response shapes

    struct GetResponse: Decodable {
        let ids: [String]
        let documents: [String?]?
        let metadatas: [ChromaMetadata?]?
        let embeddings: [[Double]?]?

        var records: [DocumentRecord] {
            ids.enumerated().map { index, id in
                DocumentRecord(
                    id: id,
                    document: documents.flatMap { index < $0.count ? $0[index] : nil },
                    metadata: metadatas.flatMap { index < $0.count ? $0[index] : nil },
                    embeddingDimension: embeddings.flatMap { index < $0.count ? $0[index]?.count : nil }
                )
            }
        }
    }

    private struct QueryResponse: Decodable {
        let ids: [[String]]
        let documents: [[String?]]?
        let metadatas: [[ChromaMetadata?]]?
        let distances: [[Double]]?
        let embeddings: [[[Double]?]]?

        var hits: [QueryHit] {
            guard let first = ids.first else { return [] }
            return first.enumerated().map { index, id in
                QueryHit(
                    id: id,
                    document: documents?.first.flatMap { index < $0.count ? $0[index] : nil },
                    metadata: metadatas?.first.flatMap { index < $0.count ? $0[index] : nil },
                    distance: distances?.first.flatMap { index < $0.count ? $0[index] : nil },
                    embedding: embeddings?.first.flatMap { index < $0.count ? $0[index] : nil }
                )
            }
        }
    }

    private struct APIErrorBody: Decodable {
        let error: String?
        let message: String?
        let detail: String?
    }

    // MARK: - Transport

    private func rawString(path: String) async throws -> String {
        let data = try await requestRaw(method: "GET", path: path, operation: .liveness)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func request<T: Decodable>(
        _ type: T.Type,
        method: String,
        path: String,
        body: [String: Any]? = nil,
        operation: ChromaOperation
    ) async throws -> T {
        let data = try await requestRaw(method: method, path: path, body: body, operation: operation)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let preview = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            throw ChromaError.decoding("\(error.localizedDescription)\nОтвет: \(preview)")
        }
    }

    @discardableResult
    private func requestRaw(
        method: String,
        path: String,
        body: [String: Any]? = nil,
        operation: ChromaOperation
    ) async throws -> Data {
        guard let url = URL(string: endpoint.baseURLString + path) else {
            throw ChromaError.unreachable(endpoint: endpoint.baseURLString, reason: "некорректный URL: \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in endpoint.headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        request.timeoutInterval = timeouts[operation]

        let attempts = operation.isRetriedAutomatically ? retries.maxAttempts : 1
        var attempt = 1
        while true {
            do {
                let deadline = timeouts[operation]
                let (data, http) = try await withDeadline(
                    seconds: deadline,
                    onExpiry: { ChromaError.timedOut(operation: operation, seconds: deadline) },
                    work: { [transport, request] in try await transport.send(request) }
                )
                if (200..<300).contains(http.statusCode) { return data }

                if attempt < attempts, let delay = retryDelay(
                    afterStatus: http.statusCode,
                    retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                    attempt: attempt
                ) {
                    try await pause(delay: delay, operation: operation, attempt: attempt, reason: "HTTP \(http.statusCode)")
                    attempt += 1
                    continue
                }
                throw Self.mapError(status: http.statusCode, data: data, endpoint: endpoint.baseURLString)
            } catch let error as URLError {
                // Cancellation is not unreachability: it arrives here as a
                // URLError, and everything above tells one from the other by the
                // error type.
                if error.code == .cancelled { throw CancellationError() }
                if attempt < attempts, isWorthRetrying(error) {
                    try await pause(
                        delay: retries.delay(beforeAttempt: attempt + 1),
                        operation: operation,
                        attempt: attempt,
                        reason: friendlyReason(for: error)
                    )
                    attempt += 1
                    continue
                }
                throw ChromaError.unreachable(endpoint: endpoint.baseURLString, reason: friendlyReason(for: error))
            } catch let error as ChromaError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ChromaError.unreachable(endpoint: endpoint.baseURLString, reason: error.localizedDescription)
            }
        }
    }

    /// Which HTTP failures are the environment's fault rather than the
    /// request's. 4xx means the request itself is wrong and repeating it will
    /// produce the same answer — the one exception is 429, where the server is
    /// asking for exactly that.
    private func retryDelay(afterStatus status: Int, retryAfter: String?, attempt: Int) -> TimeInterval? {
        if status == 429 {
            if let retryAfter, let seconds = TimeInterval(retryAfter.trimmingCharacters(in: .whitespaces)) {
                return min(max(seconds, 0), TimeoutSettings.allowedRange.upperBound)
            }
            return retries.delay(beforeAttempt: attempt + 1)
        }
        guard [502, 503, 504].contains(status) else { return nil }
        return retries.delay(beforeAttempt: attempt + 1)
    }

    /// A timeout is deliberately not in this list: the deadline for this class
    /// has already expired, and waiting the same amount again is the opposite
    /// of what it was set for.
    private func isWorthRetrying(_ error: URLError) -> Bool {
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
             .notConnectedToInternet, .dnsLookupFailed, .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    private func pause(delay: TimeInterval, operation: ChromaOperation, attempt: Int, reason: String) async throws {
        log(.warning, "ChromaDB", "\(operation.title): попытка \(attempt) не удалась (\(reason)), повтор через \(String(format: "%.1f", delay)) с")
        try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
    }

    /// Turns an HTTP failure into a typed error. Kept `static` so tests can
    /// feed it recorded server responses without touching the network.
    public static func mapError(status: Int, data: Data, endpoint: String) -> ChromaError {
        let parsed = try? JSONDecoder().decode(APIErrorBody.self, from: data)
        let message = parsed?.message ?? parsed?.detail
            ?? String(data: data, encoding: .utf8)?.prefix(400).description
            ?? "нет тела ответа"

        // ChromaDB 1.x answers 410 for every /api/v1 path.
        if status == 410 || message.contains("v1 API is deprecated") {
            return .serverTooOld(endpoint: endpoint)
        }
        if status == 401 || status == 403, message.lowercased().contains("auth") || status == 401 {
            return .unauthorized
        }
        if status == 403, message.lowercased().contains("reset") {
            return .resetForbidden
        }
        // A 404 alone means nothing: an unknown endpoint answers 404 with an
        // empty body, and treating that as a missing collection would send the
        // app re-resolving names forever. The server names the case in the
        // body, and only that is trusted.
        if status == 404, parsed?.error == "NotFoundError", message.contains("Collection") {
            let subject = message.firstMatch(between: "[", and: "]") ?? message
            return .collectionNotFound(subject)
        }
        // "Collection expecting embedding with dimension of 4, got 2"
        if let range = message.range(of: #"dimension of (\d+), got (\d+)"#, options: .regularExpression) {
            let numbers = message[range].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if numbers.count == 2 {
                return .dimensionMismatch(expected: numbers[0], got: numbers[1])
            }
        }
        return .api(status: status, code: parsed?.error, message: message)
    }

    private func friendlyReason(for error: URLError) -> String {
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost:
            return "не удалось установить соединение (сервер не запущен?)"
        case .timedOut:
            return "истекло время ожидания"
        case .networkConnectionLost:
            return "соединение разорвано"
        default:
            return error.localizedDescription
        }
    }

    /// Runs an operation against a collection id, and survives that id having
    /// become stale.
    ///
    /// A collection can be deleted and re-created under the same name from
    /// another client, a script or a second window; the UUID changes and the
    /// cached one starts failing in a way that looks like the app broke for no
    /// reason. So a «collection not found» is answered by dropping the cached
    /// id, resolving the name **once** and repeating the call. Once, and the
    /// counter lives in this call rather than in the actor, so no sequence of
    /// failures can turn into a loop.
    private func retryingStaleID<T>(
        _ collectionID: String,
        _ body: (String) async throws -> T
    ) async throws -> T {
        do {
            return try await body(collectionID)
        } catch ChromaError.collectionNotFound(let subject) {
            // Only ids this client resolved by name can be re-resolved; an id
            // handed in from elsewhere has no name to look up.
            guard let name = collectionIDs.first(where: { $0.value == collectionID })?.key
                ?? retiredIDs[collectionID] else {
                throw ChromaError.collectionNotFound(subject)
            }
            collectionIDs.removeValue(forKey: name)
            let fresh = try await collection(named: name).id
            collectionIDs[name] = fresh
            guard fresh != collectionID else { throw ChromaError.collectionNotFound(name) }
            retiredIDs[collectionID] = name
            log(.warning, "ChromaDB", "Коллекция «\(name)» была пересоздана — идентификатор обновлён")
            return try await body(fresh)
        }
    }

    private func encodeToJSONObject(_ metadata: ChromaMetadata) throws -> [String: Any] {
        let data = try JSONEncoder().encode(metadata)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChromaError.decoding("не удалось сериализовать метаданные")
        }
        return object
    }
}

extension String {
    /// The first `[…]` group — how the server names the collection it could
    /// not find.
    func firstMatch(between opening: Character, and closing: Character) -> String? {
        guard let start = firstIndex(of: opening) else { return nil }
        let afterStart = index(after: start)
        guard let end = self[afterStart...].firstIndex(of: closing), afterStart < end else { return nil }
        return String(self[afterStart..<end])
    }
}
