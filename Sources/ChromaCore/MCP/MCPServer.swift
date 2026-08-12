import Foundation

/// Разбор и маршрутизация сообщений MCP на стороне приложения (этап 7).
///
/// Живёт в ядре, а не в приложении: сюда приходит запрос агента, и решение
/// «можно или нельзя» должно приниматься там же, где его можно закрыть тестом.
///
/// Ревизия одна — `2026-07-28`. Рукопожатия `initialize` в ней нет: версия
/// и возможности клиента едут в `_meta` каждого запроса.
public struct MCPServer: Sendable {
    /// Что сервер умеет. Пусто, пока инструменты не заведены: объявленная,
    /// но не обслуживаемая возможность — это не заготовка на будущее,
    /// а обещание, по которому клиент построит запрос и получит отказ.
    public var capabilities: JSONValue

    /// Подсказка модели, как пользоваться этим сервером.
    public var instructions: String?

    public var serverVersion: String

    /// Инструменты. `nil` — сервер без них: тогда возможность `tools`
    /// не объявляется вовсе, потому что объявленная и не обслуживаемая
    /// возможность — это обещание, по которому клиент построит запрос.
    public var tools: MCPToolService?

    public init(
        capabilities: JSONValue = .object([:]),
        instructions: String? = nil,
        serverVersion: String,
        tools: MCPToolService? = nil
    ) {
        self.capabilities = capabilities
        self.instructions = instructions
        self.serverVersion = serverVersion
        self.tools = tools
    }

    /// Объявляемые возможности: к заданным добавляется `tools`, когда
    /// инструменты есть.
    ///
    /// `listChanged: false` — честно: уведомлений об изменении списка мы не
    /// шлём, и обещать их значило бы заставить клиента ждать того, чего
    /// не будет.
    private var declaredCapabilities: JSONValue {
        guard tools != nil else { return capabilities }
        var object: [String: JSONValue] = [:]
        if case .object(let existing) = capabilities { object = existing }
        object["tools"] = .object(["listChanged": .bool(false)])
        return .object(object)
    }

    /// Обрабатывает одно сообщение и возвращает ответ.
    ///
    /// `nil` — когда отвечать нечем и не нужно: у уведомления нет
    /// идентификатора, и ответ на него запрещён протоколом.
    public func respond(to message: Data, key: String? = nil) async -> JSONRPCOutgoing? {
        guard let incoming = try? JSONDecoder().decode(JSONRPCIncoming.self, from: message) else {
            return .unidentifiedFailure(JSONRPCError(
                code: JSONRPCError.parseError,
                message: "Сообщение не разобрано как JSON-RPC"
            ))
        }
        return await respond(to: incoming, key: key)
    }

    public func respond(to incoming: JSONRPCIncoming, key: String? = nil) async -> JSONRPCOutgoing? {
        // Рукопожатие старой эпохи. Опознаётся по самому методу:
        // в этих запросах `_meta` нет вовсе.
        if incoming.method == MCPProtocol.initializeMethod {
            guard let id = incoming.id else { return nil }
            return .result(id: id, initializeResult(
                requested: incoming.params?["protocolVersion"]?.stringValue
            ))
        }
        // Клиент сообщает, что рукопожатие завершено. Ответ на уведомление
        // протокол запрещает — молчим.
        if incoming.method == MCPProtocol.initializedNotification { return nil }

        guard let id = incoming.id else {
            // Уведомления транспортного уровня — единственное, что сейчас
            // приходит без идентификатора. Отмена придёт в дело вместе
            // с долгими инструментами; молчание на неё протокол разрешает.
            return nil
        }

        // Проверка живости есть в обеих эпохах и отвечается пустым результатом.
        if incoming.method == MCPProtocol.pingMethod { return .result(id: id, .object([:])) }

        // Версия проверяется у каждого запроса — но только если она есть.
        // В новой ревизии она обязана ехать в `_meta` каждого запроса; в
        // старой её там нет вовсе, и её отсутствие — это и есть признак того,
        // что клиент уже представился через `initialize`. Отвергать такие
        // запросы значило бы отвергать всю старую эпоху после того, как мы
        // ответили ей рукопожатием.
        if let version = incoming.protocolVersion, version != MCPProtocol.version {
            return .failure(id: id, .unsupportedVersion(
                requested: version,
                supported: MCPProtocol.supportedVersions
            ))
        }

        switch incoming.method {
        case MCPProtocol.discoverMethod:
            return .result(id: id, discoverResult())

        case MCPProtocol.listToolsMethod:
            guard let tools else { return .failure(id: id, .methodNotFound(incoming.method)) }
            return .result(id: id, await tools.list(key: key))

        case MCPProtocol.callToolMethod:
            guard let tools else { return .failure(id: id, .methodNotFound(incoming.method)) }
            guard let name = incoming.params?["name"]?.stringValue, !name.isEmpty else {
                return .failure(id: id, .invalidParams("Не указано имя инструмента."))
            }
            switch await tools.call(name: name, arguments: incoming.params?["arguments"], key: key) {
            case .success(let result): return .result(id: id, result)
            case .failure(let error): return .failure(id: id, error)
            }

        default:
            return .failure(id: id, .methodNotFound(incoming.method))
        }
    }

    /// Ответ на `initialize` старой эпохи.
    ///
    /// Форма — та, которую эта эпоха и требует: версия, возможности и сведения
    /// о сервере лежат наверху, а не в `_meta`. Подсказка модели идёт тем же
    /// полем `instructions`, что и в новой ревизии.
    private func initializeResult(requested: String?) -> JSONValue {
        var result: [String: JSONValue] = [
            "protocolVersion": .string(MCPProtocol.negotiatedLegacyVersion(requested: requested)),
            "capabilities": declaredCapabilities,
            "serverInfo": .object([
                "name": .string(MCPProtocol.serverName),
                "version": .string(serverVersion),
            ]),
        ]
        if let instructions { result["instructions"] = .string(instructions) }
        return .object(result)
    }

    /// Ответ на `server/discover` — сервер обязан его обслуживать.
    ///
    /// Форма сверена со спецификацией 7 августа 2026 года: `resultType`,
    /// список версий и возможности лежат наверху, а сведения о сервере —
    /// в `_meta` под зарезервированным ключом, не рядом с ними.
    private func discoverResult() -> JSONValue {
        var result: [String: JSONValue] = [
            "resultType": .string("complete"),
            "supportedVersions": .array(MCPProtocol.supportedVersions.map(JSONValue.string)),
            "capabilities": declaredCapabilities,
            "_meta": .object([
                "io.modelcontextprotocol/serverInfo": .object([
                    "name": .string(MCPProtocol.serverName),
                    "version": .string(serverVersion),
                ]),
            ]),
        ]
        if let instructions { result["instructions"] = .string(instructions) }
        return .object(result)
    }
}
