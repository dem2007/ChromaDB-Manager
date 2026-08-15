import Foundation

/// Привязка MCP к HTTP — «Streamable HTTP» ревизии `2026-07-28`.
///
/// Прочитана по спецификации 13 августа 2026, а не вспомнена: в этой ревизии
/// из транспорта **убраны** сессии (`Mcp-Session-Id`), отдельный GET-поток
/// и возобновление по `Last-Event-ID`. Зато появились заголовки, которые
/// сервер **обязан сверять с телом**, — иначе посредник маршрутизирует
/// по заголовку, а сервер выполняет по телу, и это дыра, а не расхождение.
///
/// Чего здесь нет намеренно: **SSE**. Спецификация разрешает отвечать
/// на запрос либо одним объектом JSON, либо потоком событий, и требует
/// от клиента понимать оба. Наши инструменты отвечают целиком и сразу —
/// промежуточных уведомлений о ходе работы у них нет, — так что поток
/// не дал бы ничего, кроме второго пути в коде.
///
/// Разбор HTTP и запись ответа живут в прокси; здесь — только правила.
public struct MCPHTTPTransport: Sendable {
    /// Путь единственной конечной точки. Одна на весь транспорт — так требует
    /// спецификация.
    public static let endpointPath = "/mcp"

    // Заголовки ревизии. Имена сравниваются без учёта регистра.
    public static let protocolVersionHeader = "mcp-protocol-version"
    public static let methodHeader = "mcp-method"
    public static let nameHeader = "mcp-name"
    // `Mcp-Param-{Name}` здесь намеренно нет. Эти заголовки зеркалят
    // параметры инструмента, помеченные `x-mcp-header`; ни один наш
    // инструмент такой пометки не несёт, поэтому «узнаваемых» параметров
    // у сервера нет, и спецификация прямо велит незнакомые пропускать.
    // Константа без применения только обещала бы проверку, которой нет.

    /// Код ошибки «заголовки не совпали с телом» из той же ревизии.
    public static let headerMismatch = -32020

    /// Что вернуть клиенту.
    public struct Response: Sendable, Equatable {
        public var status: Int
        public var headers: [(name: String, value: String)]
        public var body: Data

        public init(status: Int, headers: [(name: String, value: String)] = [], body: Data = Data()) {
            self.status = status
            self.headers = headers
            self.body = body
        }

        public static func == (lhs: Response, rhs: Response) -> Bool {
            lhs.status == rhs.status && lhs.body == rhs.body
                && lhs.headers.map { [$0.name, $0.value] } == rhs.headers.map { [$0.name, $0.value] }
        }
    }

    private let server: MCPServer
    /// Разрешён ли этот `Origin`. Спрашивается, а не хранится списком:
    /// список origin'ов у приложения уже есть — он живёт в правах клиентов
    ///, — и заводить рядом второй значит однажды их разойтись.
    private let isOriginAllowed: @Sendable (String) async -> Bool

    public init(server: MCPServer, isOriginAllowed: @escaping @Sendable (String) async -> Bool) {
        self.server = server
        self.isOriginAllowed = isOriginAllowed
    }

    /// Список — для тестов и для случая, когда origin'ы известны заранее.
    public init(server: MCPServer, allowedOrigins: [String] = []) {
        self.init(server: server, isOriginAllowed: { origin in
            allowedOrigins.contains { $0.caseInsensitiveCompare(origin) == .orderedSame }
        })
    }

    public static func isEndpoint(path: String) -> Bool {
        // Строка запроса к конечной точке отношения не имеет: параметров
        // у неё нет, а `?` в пути встречается у клиентов, добавляющих своё.
        let withoutQuery = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        return withoutQuery == endpointPath || withoutQuery == endpointPath + "/"
    }

    /// Обрабатывает один HTTP-запрос к конечной точке MCP.
    public func handle(
        method: String,
        headers: [(name: String, value: String)],
        body: Data,
        key: String? = nil
    ) async -> Response {
        func header(_ name: String) -> String? {
            headers.first { $0.name.lowercased() == name }?.value
        }

        // 1. Origin. Проверяется первым и до всего остального: защита
        //    от перепривязки DNS не должна зависеть от того, разобралось ли
        //    тело. Отсутствующий `Origin` — это не браузер, и он допустим.
        if let origin = header("origin"), await !isAllowed(origin: origin) {
            return Self.error(
                status: 403,
                JSONRPCError(code: JSONRPCError.invalidRequest, message: "Origin не разрешён: \(origin)")
            )
        }

        // 2. Методы, которых у этой ревизии больше нет. Прежние клиенты
        //    открывали GET-поток и удаляли сессию через DELETE; спецификация
        //    прямо велит отвечать им 405, а не притворяться, что мы их поняли.
        let verb = method.uppercased()
        guard verb == "POST" else {
            return Response(
                status: 405,
                headers: [("Allow", "POST"), ("Content-Type", "application/json; charset=utf-8")],
                body: Self.encode(JSONRPCOutgoing.unidentifiedFailure(JSONRPCError(
                    code: JSONRPCError.invalidRequest,
                    message: "Конечная точка MCP принимает только POST"
                )))
            )
        }

        // 3. Тело.
        guard let incoming = try? JSONDecoder().decode(JSONRPCIncoming.self, from: body) else {
            return Self.error(
                status: 400,
                JSONRPCError(code: JSONRPCError.parseError, message: "Тело не разобрано как JSON-RPC")
            )
        }

        // 4. Заголовки против тела. Порядок важен: сначала совпадение версии
        //    с телом, потом поддерживаем ли мы её. Иначе клиент, приславший
        //    несовпадающую пару, получил бы список версий и решил, что дело
        //    в версии.
        if let mismatch = Self.validate(headers: headers, against: incoming) {
            return Self.error(status: 400, mismatch, id: incoming.id)
        }

        // 5. Версия протокола. У старой эпохи (`initialize`) заголовка нет
        //    вовсе — такие запросы сюда доходить не должны, но если дойдут,
        // их разберёт сам сервер: он двухэпоховый.
        if let requested = header(Self.protocolVersionHeader),
           !MCPProtocol.supportedVersions.contains(requested) {
            return Self.error(
                status: 400,
                JSONRPCError.unsupportedVersion(requested: requested, supported: MCPProtocol.supportedVersions),
                id: incoming.id
            )
        }

        // 6. Уведомление: ответа нет, и тело у ответа тоже пустое.
        guard incoming.id != nil else {
            _ = await server.respond(to: incoming, key: key)
            return Response(status: 202)
        }

        guard let outgoing = await server.respond(to: incoming, key: key) else {
            // Запрос с идентификатором обязан получить ответ; молчание здесь
            // означало бы, что клиент ждёт вечно.
            return Self.error(
                status: 500,
                JSONRPCError(code: JSONRPCError.internalError, message: "Сервер не сформировал ответ"),
                id: incoming.id
            )
        }

        // 7. Неизвестный метод отвечается кодом 404 — так эта ревизия
        //    отличает «мы не умеем такой метод» от «здесь вообще нет MCP».
        let status = Self.isMethodNotFound(outgoing) ? 404 : 200
        return Response(
            status: status,
            headers: [("Content-Type", "application/json; charset=utf-8")],
            body: Self.encode(outgoing)
        )
    }

    // MARK: - Правила

    private func isAllowed(origin: String) async -> Bool {
        let value = origin.trimmingCharacters(in: .whitespaces)
        // `null` присылает страница из локального файла или песочницы —
        // ровно тот случай, от которого проверка и защищает.
        guard value != "null" else { return false }
        return await isOriginAllowed(value)
    }

    /// Сверяет зеркальные заголовки с телом. `nil` — расхождений нет.
    ///
    /// Проверяется и обратное направление: заголовок, которого нет, когда
    /// значение в теле есть, — тоже расхождение. Спецификация называет такого
    /// клиента несоответствующим, и молча его обслуживать значит принимать
    /// запросы, которые посредник не увидел.
    static func validate(headers: [(name: String, value: String)], against incoming: JSONRPCIncoming) -> JSONRPCError? {
        func header(_ name: String) -> String? {
            headers.first { $0.name.lowercased() == name }?.value
        }

        // Старая эпоха заголовков не знает: `initialize` и его спутники
        // приходят без них, и требовать их значило бы отказать клиенту,
        // которого мы решили обслуживать.
        let isLegacy = incoming.method == MCPProtocol.initializeMethod
            || incoming.method == MCPProtocol.initializedNotification
        if isLegacy && header(protocolVersionHeader) == nil { return nil }

        guard let version = header(protocolVersionHeader) else {
            return JSONRPCError(code: headerMismatch, message: "Нет обязательного заголовка MCP-Protocol-Version")
        }
        if let inBody = incoming.params?[MCPProtocol.metaKey]?[MCPProtocol.metaProtocolVersion]?.stringValue,
           inBody != version {
            return JSONRPCError(
                code: headerMismatch,
                message: "MCP-Protocol-Version «\(version)» не совпадает с версией в теле «\(inBody)»"
            )
        }

        guard let method = header(methodHeader) else {
            return JSONRPCError(code: headerMismatch, message: "Нет обязательного заголовка Mcp-Method")
        }
        guard method == incoming.method else {
            return JSONRPCError(
                code: headerMismatch,
                message: "Mcp-Method «\(method)» не совпадает с методом в теле «\(incoming.method)»"
            )
        }

        // `Mcp-Name` обязателен там, где у запроса есть имя: вызов
        // инструмента, чтение ресурса, получение подсказки.
        if let expected = namedValue(in: incoming) {
            guard let raw = header(nameHeader) else {
                return JSONRPCError(code: headerMismatch, message: "Нет обязательного заголовка Mcp-Name")
            }
            guard let decoded = decodeHeaderValue(raw) else {
                return JSONRPCError(code: headerMismatch, message: "Mcp-Name закодирован неверно")
            }
            guard decoded == expected else {
                return JSONRPCError(
                    code: headerMismatch,
                    message: "Mcp-Name «\(decoded)» не совпадает со значением в теле «\(expected)»"
                )
            }
        }
        return nil
    }

    /// Что должно быть в `Mcp-Name` для этого запроса, если должно.
    static func namedValue(in incoming: JSONRPCIncoming) -> String? {
        switch incoming.method {
        case MCPProtocol.callToolMethod:
            return incoming.params?["name"]?.stringValue
        case "resources/read":
            return incoming.params?["uri"]?.stringValue
        case "prompts/get":
            return incoming.params?["name"]?.stringValue
        default:
            return nil
        }
    }

    /// Значение заголовка, возможно закодированное сентинелом `=?base64?…?=`.
    ///
    /// Кодировка нужна не для красоты: имя коллекции по-русски в заголовок
    /// в открытом виде не помещается — HTTP разрешает там только видимый ASCII.
    static func decodeHeaderValue(_ raw: String) -> String? {
        let prefix = "=?base64?"
        let suffix = "?="
        guard raw.hasPrefix(prefix), raw.hasSuffix(suffix), raw.count > prefix.count + suffix.count else {
            return raw
        }
        let encoded = String(raw.dropFirst(prefix.count).dropLast(suffix.count))
        guard let data = Data(base64Encoded: encoded), let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    static func isMethodNotFound(_ outgoing: JSONRPCOutgoing) -> Bool {
        guard case .failure(_, let error) = outgoing else { return false }
        return error.code == JSONRPCError.methodNotFound
    }

    // MARK: - Ответы

    static func error(status: Int, _ error: JSONRPCError, id: JSONRPCID? = nil) -> Response {
        let outgoing: JSONRPCOutgoing = id.map { .failure(id: $0, error) } ?? .unidentifiedFailure(error)
        return Response(
            status: status,
            headers: [("Content-Type", "application/json; charset=utf-8")],
            body: encode(outgoing)
        )
    }

    /// Кодирование у исходящего сообщения своё: `result` и `error`
    /// взаимоисключающи, и синтезированный `Encodable` этого бы не удержал.
    static func encode(_ outgoing: JSONRPCOutgoing) -> Data {
        (try? outgoing.encoded()) ?? Data()
    }
}
