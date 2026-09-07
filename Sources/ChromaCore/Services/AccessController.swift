import Foundation

/// What the proxy knows about a collection while deciding.
public struct CollectionSnapshot: Sendable, Hashable {
    public let id: String
    public let name: String
    /// Vector size, as ChromaDB reports it. `nil` for a collection that has
    /// never been written to — the first write will fix it forever.
    public let dimension: Int?

    public init(id: String, name: String, dimension: Int?) {
        self.id = id
        self.name = name
        self.dimension = dimension
    }
}

/// What the proxy should do with one request.
public enum AccessDecision: Sendable, Equatable {
    case allow(clientID: UUID?, clientName: String, filter: ResponseFilter)
    case reject(status: Int, message: String, clientName: String?, retryAfterSeconds: Int? = nil)

    public enum ResponseFilter: Sendable, Equatable {
        case none
        /// The list of collections is trimmed to the names this client may see:
        /// «ключ с whitelist из одной коллекции не видит остальные» is part of
        /// the spec's definition of done, and a full list would leak the rest.
        case collectionList(allowed: [String])
    }
}

/// Решение по вызову инструмента MCP.
public enum MCPAccessDecision: Sendable, Equatable {
    case allow(ExternalClient)
    /// Причина словами: она уедет агенту как ошибка выполнения инструмента,
    /// и человек прочитает именно её. Имя клиента — для журнала и экрана
    /// активности: отказ, подписанный префиксом ключа вместо имени, заставляет
    /// владельца сверять его глазами со списком.
    case reject(String, clientName: String? = nil)

    public var client: ExternalClient? {
        if case .allow(let client) = self { return client }
        return nil
    }

    public var refusal: String? {
        if case .reject(let reason, _) = self { return reason }
        return nil
    }

    /// Имя клиента, если ключ вообще опознан.
    public var clientName: String? {
        switch self {
        case .allow(let client): return client.name
        case .reject(_, let name): return name
        }
    }
}

/// A token bucket: a steady rate plus a burst allowance.
///
/// Rate alone is unusable — a client that legitimately fires ten requests at
/// once would be throttled — and burst alone does not bound anything over time.
struct TokenBucket {
    let capacity: Double
    let refillPerSecond: Double
    private var tokens: Double
    private var lastRefill: Date

    init(perMinute: Int, burst: Int, now: Date = Date()) {
        capacity = Double(max(1, burst))
        refillPerSecond = Double(max(1, perMinute)) / 60.0
        tokens = capacity
        lastRefill = now
    }

    /// Takes one token, or reports how long to wait for the next one.
    mutating func take(now: Date = Date()) -> (allowed: Bool, retryAfterSeconds: Int) {
        let elapsed = max(0, now.timeIntervalSince(lastRefill))
        tokens = min(capacity, tokens + elapsed * refillPerSecond)
        lastRefill = now
        if tokens >= 1 {
            tokens -= 1
            return (true, 0)
        }
        let wait = (1 - tokens) / refillPerSecond
        return (false, max(1, Int(wait.rounded(.up))))
    }
}

/// What a write request is actually carrying.
///
/// Built from traffic: the real client sends embeddings as **base64 of float32**
/// while our own Swift client sends JSON arrays, and the server accepts both
///. A dimension check that only understood arrays would wave through
/// every request from the official client.
public struct WritePayload: Sendable, Equatable {
    public var documentCount: Int
    public var largestDocumentBytes: Int
    public var dimensions: Set<Int>

    public static func parse(_ body: Data) -> WritePayload? {
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }

        var payload = WritePayload(documentCount: 0, largestDocumentBytes: 0, dimensions: [])
        if let ids = object["ids"] as? [Any] {
            payload.documentCount = ids.count
        }
        if let documents = object["documents"] as? [Any] {
            payload.documentCount = max(payload.documentCount, documents.count)
            for case let text as String in documents {
                payload.largestDocumentBytes = max(payload.largestDocumentBytes, text.utf8.count)
            }
        }
        if let embeddings = object["embeddings"] as? [Any] {
            for embedding in embeddings {
                if let vector = embedding as? [Any] {
                    payload.dimensions.insert(vector.count)
                } else if let encoded = embedding as? String,
                          let data = Data(base64Encoded: encoded) {
                    // float32 apiece — 16 bytes is a vector of four.
                    payload.dimensions.insert(data.count / 4)
                }
            }
        }
        return payload
    }
}

/// Decides whether a proxied request may go through.
///
/// Kept apart from the proxy on purpose: this is the part that has to be right,
/// and it is worth being able to test every rule without a socket in sight.
public actor AccessController {
    private var clients: [ExternalClient] = []
    private var byID: [String: CollectionSnapshot] = [:]
    private var byName: [String: CollectionSnapshot] = [:]
    /// Documents written today, per client. Reset when the day turns over.
    private var written: [UUID: Int] = [:]
    /// Per-client rate buckets, plus one for the proxy as a whole.
    private var buckets: [UUID: TokenBucket] = [:]
    private var writeBuckets: [UUID: TokenBucket] = [:]
    private var throttled: [UUID: Int] = [:]
    static let globalRequestsPerMinute = 600
    /// Запас всплеска прокси. Стоит рядом со скоростью, потому что в отказе
    /// называются оба числа, а число, зашитое прямо в вызов, в текст отказа
    /// не попадает — и человек читает лимит, которого не достигал.
    static let globalBurst = 100
    private var globalBucket = TokenBucket(
        perMinute: AccessController.globalRequestsPerMinute, burst: AccessController.globalBurst
    )

    /// Запас всплеска на запись — половина общего.
    ///
    /// Считается здесь, а не на месте, по той же причине: это число называется
    /// в отказе, и посчитанное дважды оно однажды разойдётся.
    static func writeBurst(for client: ExternalClient) -> Int {
        max(1, client.permissions.burst / 2)
    }
    private var usageDay: Date = Calendar.current.startOfDay(for: Date())
    private var catalogLoader: (@Sendable () async -> [CollectionSnapshot])?
    /// References already confirmed absent, with an expiry. Without this a
    /// client asking for a collection that does not exist would make the proxy
    /// re-read the whole catalogue on every request.
    private var confirmedMissing: [String: Date] = [:]

    public init() {}

    // MARK: - Configuration

    public func setClients(_ clients: [ExternalClient]) {
        self.clients = clients
    }

    /// Supplies the collection catalogue. The proxy needs names and vector
    /// sizes, and only the app has a ChromaDB client to ask.
    public func setCatalogLoader(_ loader: @escaping @Sendable () async -> [CollectionSnapshot]) {
        catalogLoader = loader
    }

    public func setCatalog(_ snapshots: [CollectionSnapshot]) {
        byID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        byName = Dictionary(snapshots.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for snapshot in snapshots {
            confirmedMissing[snapshot.id] = nil
            confirmedMissing[snapshot.name] = nil
        }
    }

    public func refreshCatalog() async {
        guard let catalogLoader else { return }
        setCatalog(await catalogLoader())
    }

    /// Remembers the size the first write fixed, so the next request is checked
    /// against it without another round trip.
    public func rememberDimension(_ dimension: Int, forCollectionID id: String) {
        guard let existing = byID[id], existing.dimension == nil else { return }
        let updated = CollectionSnapshot(id: existing.id, name: existing.name, dimension: dimension)
        byID[id] = updated
        byName[existing.name] = updated
    }

    public func snapshot(forCollectionID id: String) -> CollectionSnapshot? { byID[id] }

    public func usageToday(for clientID: UUID) -> Int {
        rolloverIfNeeded()
        return written[clientID] ?? 0
    }

    /// How many requests of this client the proxy has turned down for rate —
    /// shown on its card so a misbehaving agent is visible.
    public func throttledCount(for clientID: UUID) -> Int {
        throttled[clientID] ?? 0
    }

    /// Origins any enabled client allows. A preflight arrives without a key, so
    /// this is all the proxy can check it against.
    public func originIsAllowedByAnyClient(_ origin: String) -> Bool {
        clients.contains { $0.isEnabled && !$0.isRevoked && $0.permissions.allowsOrigin(origin) }
    }

    /// Клиент по ключу — **любой известный**, включая отключённого.
    ///
    /// Нужен там, где спрашивают имя: карточка соединения обязана назвать
    /// ключ, даже если им сейчас нельзя пользоваться. Для решения «пускать
    /// ли» это не тот метод — берите `activeClient(withKey:)`.
    public func client(withKey key: String?) -> ExternalClient? {
        guard let key, !key.isEmpty else { return nil }
        let hash = ClientKey.hash(key)
        return clients.first { !$0.isRevoked && $0.keyHash == hash }
    }

    /// Клиент, которым **можно** пользоваться прямо сейчас.
    ///
    /// Отдельным методом, а не проверкой на месте: пока каждый вызывающий
    /// дописывал `isEnabled` сам, одно место его забыло — и отключённый ключ
    /// проходил в MCP через прокси, получая имя сервера, версию и подсказки
    /// модели. Условие живёт там же, где поиск по ключу.
    public func activeClient(withKey key: String?) -> ExternalClient? {
        client(withKey: key).flatMap { $0.isEnabled ? $0 : nil }
    }

    // MARK: - Deciding

    public func decide(
        key: String?,
        route: ChromaRoute,
        body: Data
    ) async -> AccessDecision {
        rolloverIfNeeded()

        guard let key, !key.isEmpty else {
            return .reject(
                status: 401,
                message: String(localized: "Ключ доступа не передан. Ожидается заголовок X-Chroma-Token или Authorization: Bearer."),
                clientName: nil
            )
        }
        let hash = ClientKey.hash(key)
        // `!$0.isRevoked` is not belt-and-braces: a revoked client has an empty
        // hash, and an empty hash must never be matched by anything.
        guard let client = clients.first(where: { !$0.isRevoked && $0.keyHash == hash }) else {
            return .reject(status: 401, message: String(localized: "Ключ доступа не зарегистрирован."), clientName: nil)
        }
        guard client.isEnabled else {
            return .reject(status: 403, message: String(localized: "Клиент «\(client.name)» отключён."), clientName: client.name)
        }

        // Rate first, before anything expensive: a runaway loop should cost the
        // proxy one dictionary lookup, not a catalogue refresh.
        if let refusal = consumeRate(for: client, route: route) { return refusal }

        // Heartbeat, version, identity: no collection is involved, and the
        // client cannot even be created without them.
        if route.access == .service {
            return .allow(clientID: client.id, clientName: client.name, filter: .none)
        }

        // Listing is answered, but trimmed to what this client may see.
        if route.operation == "list_collections" {
            return .allow(
                clientID: client.id,
                clientName: client.name,
                filter: .collectionList(allowed: client.permissions.collections)
            )
        }

        // Reset wipes everything, whitelist or not.
        if route.operation == "reset" {
            return .reject(status: 403, message: String(localized: "Сброс базы через прокси запрещён."), clientName: client.name)
        }

        // `get_or_create_collection` — the idiomatic way to obtain a handle in
        // the official client — is sent as a **creation** even when the
        // collection already exists (found against the live client). Refusing
        // creation outright therefore breaks ordinary read-only use, so the
        // name in the body is checked against the whitelist instead.
        if route.operation == "create_collection" {
            guard let name = Self.collectionName(inCreateBody: body) else {
                return .reject(status: 400, message: String(localized: "В запросе нет имени коллекции."), clientName: client.name)
            }
            guard client.permissions.allows(collection: name) else {
                return .reject(status: 404, message: String(localized: "Коллекция не найдена: \(name)"), clientName: client.name)
            }
            // An existing whitelisted collection means this is a lookup. A
            // missing one means the client is really creating something, and
            // that needs write permission.
            if await resolve(name) == nil && !client.permissions.allowsWrite {
                return .reject(
                    status: 403,
                    message: String(localized: "Коллекции «\(name)» ещё нет, а создавать её клиенту «\(client.name)» не разрешено."),
                    clientName: client.name
                )
            }
            return .allow(clientID: client.id, clientName: client.name, filter: .none)
        }

        if route.access.changesData && !client.permissions.allowsWrite {
            return .reject(
                status: 403,
                message: String(localized: "Клиенту «\(client.name)» разрешено только чтение."),
                clientName: client.name
            )
        }

        // Удаление — отдельное право поверх записи, и по HTTP оно значит ровно
        // то же, что у инструментов MCP. Пока `Access` знал
        // только «запись», галка «Разрешить удаление документов» на прокси
        // не действовала вовсе: клиент с записью сносил коллекцию.
        if route.access == .delete && !client.permissions.allowsDelete {
            return .reject(
                status: 403,
                message: String(localized: "Клиенту «\(client.name)» разрешена запись, но не удаление — это отдельное право, и оно не выдано."),
                clientName: client.name
            )
        }

        // An endpoint we do not recognise: reads pass (a new read-only endpoint
        // in a future ChromaDB should not break anyone), writes do not.
        guard route.isKnown else {
            return route.access.changesData
                ? .reject(
                    status: 403,
                    message: String(localized: "Неизвестная операция записи отклонена: прокси не может проверить её права."),
                    clientName: client.name)
                : .allow(clientID: client.id, clientName: client.name, filter: .none)
        }

        guard let reference = route.collectionReference else {
            return .reject(status: 403, message: String(localized: "Не удалось определить коллекцию запроса."), clientName: client.name)
        }
        guard let collection = await resolve(reference) else {
            return .reject(
                status: 404,
                message: String(localized: "Коллекция не найдена: \(reference)"),
                clientName: client.name
            )
        }
        guard client.permissions.allows(collection: collection.name) else {
            // 404, not 403: a client with no access to a collection should not
            // learn that it exists.
            return .reject(
                status: 404,
                message: String(localized: "Коллекция не найдена: \(collection.name)"),
                clientName: client.name
            )
        }

        if route.access.changesData, let payload = WritePayload.parse(body) {
            if let problem = checkLimits(payload, client: client) {
                return .reject(status: 429, message: problem, clientName: client.name)
            }
            if let problem = checkDimension(payload, collection: collection, client: client) {
                return .reject(status: 400, message: problem, clientName: client.name)
            }
            written[client.id, default: 0] += payload.documentCount
        }

        return .allow(clientID: client.id, clientName: client.name, filter: .none)
    }

    /// Takes a token from the client's bucket, and from the write bucket too
    /// when the request writes. Also from the proxy-wide bucket, which bounds
    /// the sum of all keys.
    // MARK: - MCP

    /// Решение по вызову инструмента MCP.
    ///
    /// Второй транспорт поверх той же модели прав — новых понятий не заводится
    ///. Отличается только форма ответа: у MCP нет кодов HTTP, а есть
    /// текст причины, который агент обязан уметь показать человеку.
    ///
    /// Разница с `decide` не косметическая и в одном месте существенная:
    /// коллекция, к которой у ключа нет доступа, здесь называется несуществующей
    /// — ровно как в прокси, где на это отвечает 404. Сказать «доступ закрыт»
    /// значило бы сообщить агенту, что коллекция есть.
    /// - Parameter writing: объём записи, когда инструмент пишет. По нему
    ///   проверяются те же лимиты, что у прокси: размер документа и суточная
    ///   норма. Второй счётчик для MCP не заводится — это тот же ключ и та же
    ///   норма, каким бы транспортом он ни пришёл.
    public func decideTool(
        key: String?,
        permission: MCPToolPermission,
        collection: String?,
        isReadOnlyServer: Bool,
        writing: MCPWritePayload? = nil
    ) -> MCPAccessDecision {
        rolloverIfNeeded()

        guard let key, !key.isEmpty else {
            return .reject("No access key was sent. Set it in the agent's connection configuration — the CHROMADB_MCP_KEY variable.")
        }
        let hash = ClientKey.hash(key)
        guard let client = clients.first(where: { !$0.isRevoked && $0.keyHash == hash }) else {
            return .reject("This access key is not registered in ChromaDB Manager.")
        }
        guard client.isEnabled else {
            return .reject("The client «\(client.name)» is switched off in ChromaDB Manager.", clientName: client.name)
        }

        // Частота — до всего остального: разогнавшийся агент должен стоить
        // одного поиска в словаре, а не обращения к базе.
        var bucket = buckets[client.id]
            ?? TokenBucket(perMinute: client.permissions.requestsPerMinute, burst: client.permissions.burst)
        let general = bucket.take()
        buckets[client.id] = bucket
        guard general.allowed else {
            throttled[client.id, default: 0] += 1
            return .reject("Too many requests at once: the client «\(client.name)» may send \(client.permissions.burst.plainDigits) in a burst, and the burst refills at \(client.permissions.requestsPerMinute.plainDigits) per minute. Retry in \(general.retryAfterSeconds.plainDigits) s.", clientName: client.name)
        }

        if permission != .read {
            if isReadOnlyServer {
                return .reject("The MCP server is in read-only mode — writing is refused for every key, whatever its rights.", clientName: client.name)
            }
            guard client.permissions.allowsWrite else {
                return .reject("The client «\(client.name)» is allowed to read only.", clientName: client.name)
            }
            // Удаление — отдельное право поверх записи: снести коллекцию одним
            // неудачным вызовом слишком легко, чтобы это ехало вместе
            // с обычной записью.
            if permission == .delete, !client.permissions.allowsDelete {
                return .reject("The client «\(client.name)» may write but not delete — that is a right of its own, and it has not been granted.", clientName: client.name)
            }
            let writeBurst = Self.writeBurst(for: client)
            var writeBucket = writeBuckets[client.id]
                ?? TokenBucket(perMinute: client.permissions.writesPerMinute, burst: writeBurst)
            let write = writeBucket.take()
            writeBuckets[client.id] = writeBucket
            guard write.allowed else {
                throttled[client.id, default: 0] += 1
                return .reject("Too many write operations at once: the client «\(client.name)» may write \(writeBurst.plainDigits) in a burst, and the burst refills at \(client.permissions.writesPerMinute.plainDigits) per minute.", clientName: client.name)
            }
        }

        // `!collection.isEmpty` здесь стояло — и пустая строка проходила мимо
        // whitelist целиком: обязательность параметра проверяется как
        // «не nil», а пустая строка не nil. Сегодня такой вызов упирался
        // в отказ бэкенда, но решение по доступу принимается здесь, и
        // пропускать мимо себя хоть что-то этот сторож не имеет права:
        // изменись бэкенд — и щель стала бы дырой.
        if let collection {
            guard client.permissions.allows(collection: collection) else {
                return .reject("Collection not found: \(collection)", clientName: client.name)
            }
        }

        // Лимиты объёма — после прав и после whitelist: сообщать «суточная
        // норма исчерпана» тому, кому коллекция и так не открыта, значило бы
        // подтвердить, что она существует.
        if let writing {
            let payload = WritePayload(
                documentCount: writing.documentCount,
                largestDocumentBytes: writing.largestDocumentBytes,
                dimensions: []
            )
            if let problem = checkLimits(payload, client: client, forAgent: true) {
                return .reject(problem, clientName: client.name)
            }
            written[client.id, default: 0] += writing.documentCount
        }

        return .allow(client)
    }

    private func consumeRate(for client: ExternalClient, route: ChromaRoute) -> AccessDecision? {
        // Service calls (heartbeat, version) are what a client polls with; they
        // still count, or the limit would be trivial to walk around.
        var bucket = buckets[client.id]
            ?? TokenBucket(perMinute: client.permissions.requestsPerMinute, burst: client.permissions.burst)
        let general = bucket.take()
        buckets[client.id] = bucket
        guard general.allowed else {
            throttled[client.id, default: 0] += 1
            return .reject(
                status: 429,
                message: String(localized: "Слишком много запросов подряд: клиенту «\(client.name)» разрешено \(client.permissions.burst.plainDigits) за раз, дальше запас восполняется со скоростью \(client.permissions.requestsPerMinute.plainDigits) в минуту."),
                clientName: client.name,
                retryAfterSeconds: general.retryAfterSeconds
            )
        }

        if route.access.changesData {
            let writeBurst = Self.writeBurst(for: client)
            var writeBucket = writeBuckets[client.id]
                ?? TokenBucket(perMinute: client.permissions.writesPerMinute, burst: writeBurst)
            let write = writeBucket.take()
            writeBuckets[client.id] = writeBucket
            guard write.allowed else {
                throttled[client.id, default: 0] += 1
                return .reject(
                    status: 429,
                    message: String(localized: "Слишком много операций записи подряд: клиенту «\(client.name)» разрешено \(writeBurst.plainDigits) за раз, дальше запас восполняется со скоростью \(client.permissions.writesPerMinute.plainDigits) в минуту."),
                    clientName: client.name,
                    retryAfterSeconds: write.retryAfterSeconds
                )
            }
        }

        let global = globalBucket.take()
        guard global.allowed else {
            throttled[client.id, default: 0] += 1
            return .reject(
                status: 429,
                message: String(localized: "Прокси перегружен: всеми ключами вместе разрешено \(Self.globalBurst.plainDigits) запросов за раз, дальше запас восполняется со скоростью \(Self.globalRequestsPerMinute.plainDigits) в минуту."),
                clientName: client.name,
                retryAfterSeconds: global.retryAfterSeconds
            )
        }
        return nil
    }

    /// The name a creation request carries — the only place it appears, since
    /// the path has no collection segment yet.
    public static func collectionName(inCreateBody body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return object["name"] as? String
    }

    /// - Parameter forAgent: отвечаем ли модели по MCP. У прокси и у MCP разные
    /// читатели: HTTP-ответ читает человек, ответ MCP — модель, и по
    ///   ей отвечают по-английски. Умолчание — прокси, чтобы вызов из `decide`
    ///   остался прежним.
    private func checkLimits(_ payload: WritePayload, client: ExternalClient, forAgent: Bool = false) -> String? {
        if let maximum = client.permissions.maxDocumentBytes, payload.largestDocumentBytes > maximum {
            let actual = ByteCountFormatter.string(fromByteCount: Int64(payload.largestDocumentBytes), countStyle: .file)
            let allowed = ByteCountFormatter.string(fromByteCount: Int64(maximum), countStyle: .file)
            return forAgent
                ? "The document is larger than allowed: \(actual) against a limit of \(allowed)."
                : String(localized: "Документ больше разрешённого: \(actual) при пределе \(allowed).")
        }
        if let perDay = client.permissions.maxDocumentsPerDay {
            let already = written[client.id] ?? 0
            if already + payload.documentCount > perDay {
                return forAgent
                    ? "The daily limit is spent: \(already.plainDigits) of \(perDay.plainDigits) documents are already written today."
                    : String(localized: "Суточный лимит исчерпан: \(already.plainDigits) из \(perDay.plainDigits) документов уже записано сегодня.")
            }
        }
        return nil
    }

    /// The spec asks the proxy to enforce «the client uses the same model».
    /// The model cannot be checked — vectors carry no identity — so the vector
    /// size is checked instead, which is the strongest available approximation
    /// and is also what ChromaDB itself would refuse on.
    private func checkDimension(
        _ payload: WritePayload,
        collection: CollectionSnapshot,
        client: ExternalClient
    ) -> String? {
        guard !payload.dimensions.isEmpty else { return nil }
        if payload.dimensions.count > 1 {
            return String(localized: "В одном запросе векторы разной размерности: \(payload.dimensions.sorted().map(\.description).joined(separator: ", ")).")
        }
        let incoming = payload.dimensions.first!
        guard let stored = collection.dimension else {
            // Empty collection: this write sets the standard. The proxy records
            // it so the next request is checked, and the audit log says so.
            rememberDimension(incoming, forCollectionID: collection.id)
            return nil
        }
        guard incoming != stored else { return nil }
        return String(localized: "Коллекция «\(collection.name)» хранит векторы размерности \(stored.plainDigits), а клиент прислал \(incoming.plainDigits). Скорее всего, используется другая модель эмбеддингов.")
    }

    /// A path segment is either a UUID or a name, and a collection
    /// created a moment ago is not in the cache yet — a client that creates a
    /// collection and immediately writes to it must not be told that the
    /// collection does not exist.
    private func resolve(_ reference: String) async -> CollectionSnapshot? {
        if let hit = byID[reference] ?? byName[reference] { return hit }
        if let until = confirmedMissing[reference], until > Date() { return nil }

        await refreshCatalog()
        if let hit = byID[reference] ?? byName[reference] {
            confirmedMissing[reference] = nil
            return hit
        }
        confirmedMissing[reference] = Date().addingTimeInterval(2)
        return nil
    }

    private func rolloverIfNeeded() {
        let today = Calendar.current.startOfDay(for: Date())
        guard today != usageDay else { return }
        usageDay = today
        written.removeAll()
    }
}
