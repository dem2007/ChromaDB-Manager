import Foundation

/// Идентификатор запроса JSON-RPC: число или строка.
///
/// Своим типом, а не `Int`: спецификация допускает оба, и ответ обязан вернуть
/// идентификатор **того же вида**, каким он пришёл. Приведя строковый «7»
/// к числу, мы вернули бы клиенту чужой с виду ответ.
public enum JSONRPCID: Codable, Hashable, Sendable {
    case int(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

/// Ошибка JSON-RPC.
public struct JSONRPCError: Codable, Hashable, Sendable, Error {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    // Коды самого JSON-RPC 2.0.
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
    /// Код MCP из ревизии 2026-07-28: запрошена версия протокола,
    /// которую сервер не поддерживает.
    public static let unsupportedProtocolVersion = -32022

    public static func methodNotFound(_ method: String) -> JSONRPCError {
        JSONRPCError(code: methodNotFound, message: "Неизвестный метод: \(method)")
    }

    public static func invalidParams(_ reason: String) -> JSONRPCError {
        JSONRPCError(code: invalidParams, message: reason)
    }

    /// Отказ по версии протокола.
    ///
    /// Список поддерживаемых версий обязателен: по нему клиент выбирает, чем
    /// повторить запрос. Без него отказ — тупик.
    public static func unsupportedVersion(requested: String?, supported: [String]) -> JSONRPCError {
        JSONRPCError(
            code: unsupportedProtocolVersion,
            message: "Unsupported protocol version",
            data: .object([
                "supported": .array(supported.map(JSONValue.string)),
                "requested": requested.map(JSONValue.string) ?? .null,
            ])
        )
    }
}

/// Входящее сообщение: запрос или уведомление.
///
/// Сервер по спецификации не получает ответов — клиент их не шлёт вовсе, —
/// поэтому третьего случая здесь нет.
public struct JSONRPCIncoming: Codable, Sendable {
    public var jsonrpc: String
    /// Отсутствует у уведомления. Именно этим уведомление и отличается:
    /// на него нельзя отвечать.
    public var id: JSONRPCID?
    public var method: String
    public var params: JSONValue?

    public init(jsonrpc: String = "2.0", id: JSONRPCID?, method: String, params: JSONValue? = nil) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
    }

    public var isNotification: Bool { id == nil }

    /// Метаданные запроса ревизии 2026-07-28: версия протокола, возможности и
    /// личность клиента едут в `_meta` **каждого** запроса, отдельной фазы
    /// согласования больше нет.
    public var meta: JSONValue? { params?[MCPProtocol.metaKey] }

    public var protocolVersion: String? {
        meta?[MCPProtocol.metaProtocolVersion]?.stringValue
    }
}

/// Исходящее сообщение: ответ или уведомление.
///
/// Кодируется вручную, потому что `result` и `error` взаимоисключающи, а поле
/// `result: null` в ответе с ошибкой — уже нарушение JSON-RPC.
public enum JSONRPCOutgoing: Sendable {
    case result(id: JSONRPCID, JSONValue)
    case failure(id: JSONRPCID, JSONRPCError)
    /// Ошибка, когда идентификатор запроса неизвестен: строка не разобралась
    /// вовсе. JSON-RPC предписывает в этом случае `"id": null` — молчание
    /// оставило бы клиента ждать ответа, которого не будет.
    case unidentifiedFailure(JSONRPCError)
    case notification(method: String, params: JSONValue?)

    public func encoded() throws -> Data {
        var object: [String: JSONValue] = ["jsonrpc": .string("2.0")]
        let encoder = JSONEncoder()
        switch self {
        case .result(let id, let value):
            object["id"] = try id.asJSON()
            object["result"] = value
        case .failure(let id, let error):
            object["id"] = try id.asJSON()
            object["error"] = Self.payload(for: error)
        case .unidentifiedFailure(let error):
            object["id"] = .null
            object["error"] = Self.payload(for: error)
        case .notification(let method, let params):
            object["method"] = .string(method)
            if let params { object["params"] = params }
        }
        return try encoder.encode(JSONValue.object(object))
    }

    private static func payload(for error: JSONRPCError) -> JSONValue {
        var payload: [String: JSONValue] = [
            "code": .int(error.code),
            "message": .string(error.message),
        ]
        if let data = error.data { payload["data"] = data }
        return .object(payload)
    }
}

private extension JSONRPCID {
    func asJSON() throws -> JSONValue {
        switch self {
        case .int(let value): return .int(value)
        case .string(let value): return .string(value)
        }
    }
}
