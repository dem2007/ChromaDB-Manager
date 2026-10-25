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
    ///
    /// `negotiatedVersion` — версия, известная транспорту помимо тела:
    /// заголовок `MCP-Protocol-Version` или рукопожатие на этом соединении.
    public func respond(to message: Data, key: String? = nil, negotiatedVersion: String? = nil) async -> JSONRPCOutgoing? {
        guard let incoming = try? JSONDecoder().decode(JSONRPCIncoming.self, from: message) else {
            return .unidentifiedFailure(Self.unreadable(message))
        }
        return await respond(to: incoming, key: key, negotiatedVersion: negotiatedVersion)
    }

    /// Что ответить на сообщение, которое не стало запросом.
    ///
    /// Не JSON вовсе — ошибка разбора (`-32700`). JSON, но не запрос — массив
    /// (пакеты MCP не допускает) или объект без метода — неверный запрос
    /// (`-32600`): разобрать его удалось, принять — нет.
    public static func unreadable(_ message: Data) -> JSONRPCError {
        guard (try? JSONSerialization.jsonObject(with: message, options: [.fragmentsAllowed])) != nil else {
            return JSONRPCError(code: JSONRPCError.parseError, message: "The message could not be parsed as JSON")
        }
        return .invalidRequest(
            "The message is JSON but not a single JSON-RPC request or notification; batches are not supported"
        )
    }

    /// Проверка запроса до маршрутизации — то, что спецификация требует
    /// отклонять, не глядя на метод (`2026-07-28`, «Versioning», «_meta»).
    ///
    /// Сервер двух эпох (dual-era) решает по самому запросу:
    /// - версия новой ревизии в `_meta` — запрос новой ревизии, и обязательные
    ///   поля `_meta` у него обязательны: без `clientCapabilities` это
    ///   испорченный запрос (`-32602`);
    /// - версия старой ревизии в `_meta` — обслуживается как старый запрос.
    ///   Эти версии мы сами называем поддерживаемыми в `server/discover`
    ///   и в ошибке версии; отказать ими значило бы отправить клиента по
    ///   кругу: «не поддерживается — поддерживаются вот эти, включая её»;
    /// - версии в `_meta` нет — запрос старой эпохи, после `initialize`;
    /// - неизвестная версия — `UnsupportedProtocolVersionError`.
    ///
    /// Открыто для HTTP: там на эти отказы отвечают статусом 400.
    public static func preflight(_ incoming: JSONRPCIncoming) -> JSONRPCError? {
        if incoming.method == MCPProtocol.initializeMethod
            || incoming.method == MCPProtocol.initializedNotification { return nil }
        guard let raw = incoming.meta?[MCPProtocol.metaProtocolVersion] else { return nil }
        guard let version = raw.stringValue else {
            return .invalidParams("The _meta field «\(MCPProtocol.metaProtocolVersion)» must be a string")
        }
        if MCPProtocol.legacyVersions.contains(version) { return nil }
        guard version == MCPProtocol.version else {
            return .unsupportedVersion(requested: version, supported: MCPProtocol.supportedVersions)
        }
        guard incoming.meta?[MCPProtocol.metaClientCapabilities]?.objectValue != nil else {
            return .invalidParams(
                "Missing required _meta field «\(MCPProtocol.metaClientCapabilities)»: every \(MCPProtocol.version) request carries the client capabilities"
            )
        }
        return nil
    }

    /// Запрос новой ревизии — по версии в `_meta`.
    static func isModern(_ incoming: JSONRPCIncoming) -> Bool {
        incoming.protocolVersion == MCPProtocol.version
    }

    /// Версия, по правилам которой отвечать на запрос: названная в `_meta`,
    /// иначе известная транспорту, иначе предполагаемая старой эпохой.
    static func effectiveVersion(_ incoming: JSONRPCIncoming, negotiated: String?) -> String {
        incoming.protocolVersion ?? negotiated ?? MCPProtocol.assumedLegacyVersion
    }

    public func respond(
        to incoming: JSONRPCIncoming, key: String? = nil, negotiatedVersion: String? = nil
    ) async -> JSONRPCOutgoing? {
        // Рукопожатие старой эпохи. Опознаётся по самому методу:
        // в этих запросах `_meta` нет вовсе.
        if incoming.method == MCPProtocol.initializeMethod {
            guard let id = incoming.id else { return nil }
            return .result(id: id, withServerInfo(initializeResult(
                requested: incoming.params?["protocolVersion"]?.stringValue
            )))
        }

        guard let id = incoming.id else {
            // Уведомление: ответ на него протокол запрещает. Отмену разбирает
            // транспорт — он и держит задачи запросов.
            return nil
        }

        if let rejection = Self.preflight(incoming) {
            return .failure(id: id, rejection)
        }

        // Проверка живости есть только у старых ревизий: `2026-07-28` её
        // удалила. Запрос новой ревизии получает «метод не найден».
        if incoming.method == MCPProtocol.pingMethod {
            guard !Self.isModern(incoming) else { return .failure(id: id, .methodNotFound(incoming.method)) }
            return .result(id: id, .object([:]))
        }

        switch incoming.method {
        case MCPProtocol.discoverMethod:
            return .result(id: id, withServerInfo(discoverResult()))

        case MCPProtocol.listToolsMethod:
            guard let tools else { return .failure(id: id, .methodNotFound(incoming.method)) }
            return .result(id: id, withServerInfo(await tools.list(key: key)))

        case MCPProtocol.callToolMethod:
            guard let tools else { return .failure(id: id, .methodNotFound(incoming.method)) }
            guard let name = incoming.params?["name"]?.stringValue, !name.isEmpty else {
                return .failure(id: id, .invalidParams("No tool name given."))
            }
            // Форма самого `tools/call`: аргументы, если есть, — объект.
            // Это ошибка протокола, а не инструмента: до инструмента такой
            // вызов не доходит.
            let arguments = incoming.params?["arguments"]
            if let arguments, arguments != .null, arguments.objectValue == nil {
                return .failure(id: id, .invalidParams("«arguments» must be an object."))
            }
            let version = Self.effectiveVersion(incoming, negotiated: negotiatedVersion)
            switch await tools.call(name: name, arguments: arguments, key: key, version: version) {
            case .success(let result): return .result(id: id, withServerInfo(result))
            case .failure(let error): return .failure(id: id, error)
            }

        default:
            return .failure(id: id, .methodNotFound(incoming.method))
        }
    }

    /// Результат со сведениями о сервере в `_meta` — их сервер **SHOULD**
    /// класть в каждый ответ, а не только в `server/discover`.
    private func withServerInfo(_ result: JSONValue) -> JSONValue {
        guard var object = result.objectValue else { return result }
        var meta = object[MCPProtocol.metaKey]?.objectValue ?? [:]
        meta[MCPProtocol.metaServerInfo] = .object([
            "name": .string(MCPProtocol.serverName),
            "version": .string(serverVersion),
        ])
        object[MCPProtocol.metaKey] = .object(meta)
        return .object(object)
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
                MCPProtocol.metaServerInfo: .object([
                    "name": .string(MCPProtocol.serverName),
                    "version": .string(serverVersion),
                ]),
            ]),
            // Подсказки кэша обязательны (`CacheableResult`): сведения
            // о сервере одни для всех и меняются только с новой версией.
            "ttlMs": .int(MCPProtocol.discoverCacheTTL),
            "cacheScope": .string("public"),
        ]
        if let instructions { result["instructions"] = .string(instructions) }
        return .object(result)
    }
}
