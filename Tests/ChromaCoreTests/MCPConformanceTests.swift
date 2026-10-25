import XCTest
@testable import ChromaCore

/// Сверка с ревизией `2026-07-28` и совместимость со старыми ревизиями —
/// сообщениями в том виде, в каком их шлют клиенты каждой эпохи.
///
/// Источник требований — сама спецификация: «Overview» (сообщения, `_meta`,
/// коды ошибок), «Versioning and Compatibility», «Discovery», «Tools»,
/// «Caching», «Streamable HTTP», «Cancellation».
final class MCPConformanceTests: XCTestCase {
    private func server() -> MCPServer {
        MCPServer(
            instructions: "x", serverVersion: "9.9",
            tools: MCPToolService(backend: NoBackend(), access: AccessController())
        )
    }

    private let modernMeta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#

    private func answer(_ text: String, from server: MCPServer? = nil) async throws -> JSONValue? {
        guard let outgoing = await (server ?? self.server()).respond(to: Data(text.utf8)) else { return nil }
        return try JSONDecoder().decode(JSONValue.self, from: outgoing.encoded())
    }

    private func http(
        _ text: String, headers: [String: String], server: MCPServer? = nil
    ) async throws -> (status: Int, body: JSONValue?) {
        let transport = MCPHTTPTransport(server: server ?? self.server())
        let response = await transport.handle(
            method: "POST", headers: headers.map { (name: $0.key, value: $0.value) }, body: Data(text.utf8)
        )
        let body = response.body.isEmpty ? nil : try JSONDecoder().decode(JSONValue.self, from: response.body)
        return (response.status, body)
    }

    private func serverInfo(_ result: JSONValue?) -> JSONValue? {
        result?["_meta"]?["io.modelcontextprotocol/serverInfo"]
    }

    // MARK: - Новая ревизия

    /// `server/discover`: версии, возможности, сведения о сервере в `_meta`,
    /// обязательные подсказки кэша.
    func testDiscoverMatchesTheRevision() async throws {
        let result = try await answer(#"{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{\#(modernMeta)}}"#)?["result"]
        XCTAssertEqual(result?["resultType"], .string("complete"))
        let versions = result?["supportedVersions"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertEqual(versions.first, "2026-07-28")
        XCTAssertTrue(versions.contains("2025-11-25"), "последняя ревизия с рукопожатием")
        XCTAssertEqual(result?["capabilities"]?["tools"]?["listChanged"], .bool(false))
        XCTAssertEqual(serverInfo(result)?["name"], .string(MCPProtocol.serverName))
        XCTAssertGreaterThanOrEqual(result?["ttlMs"]?.intValue ?? -1, 0)
        XCTAssertEqual(result?["cacheScope"], .string("public"))
    }

    /// `tools/list`: `resultType`, подсказки кэша (список зависит от ключа —
    /// `private`), сведения о сервере.
    func testToolsListCarriesCacheHints() async throws {
        let result = try await answer(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{\#(modernMeta)}}"#)?["result"]
        XCTAssertEqual(result?["resultType"], .string("complete"))
        XCTAssertFalse(result?["tools"]?.arrayValue?.isEmpty ?? true)
        XCTAssertGreaterThanOrEqual(result?["ttlMs"]?.intValue ?? -1, 0)
        XCTAssertEqual(result?["cacheScope"], .string("private"))
        XCTAssertNotNil(serverInfo(result))
        for tool in result?["tools"]?.arrayValue ?? [] {
            XCTAssertEqual(tool["inputSchema"]?["type"], .string("object"), "\(tool["name"] ?? .null)")
        }
    }

    /// Обязательное поле `_meta` пропущено — `-32602`, по HTTP 400.
    func testAMissingClientCapabilitiesIsMalformed() async throws {
        let text = #"{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#
        let direct = try await answer(text)
        XCTAssertEqual(direct?["error"]?["code"], .int(-32602))
        let over = try await http(text, headers: ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/list"])
        XCTAssertEqual(over.status, 400)
        XCTAssertEqual(over.body?["error"]?["code"], .int(-32602))
        XCTAssertEqual(over.body?["id"], .int(3))
    }

    /// Неизвестная версия — `UnsupportedProtocolVersionError` (`-32022`)
    /// со списком поддерживаемых; по HTTP 400.
    func testAnUnknownVersionIsRefusedWithTheSupportedList() async throws {
        let text = #"{"jsonrpc":"2.0","id":4,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"1900-01-01","io.modelcontextprotocol/clientCapabilities":{}}}}"#
        let error = try await answer(text)?["error"]
        XCTAssertEqual(error?["code"], .int(-32022))
        XCTAssertEqual(error?["data"]?["requested"], .string("1900-01-01"))
        XCTAssertEqual(error?["data"]?["supported"]?.arrayValue?.first, .string("2026-07-28"))
        let over = try await http(text, headers: ["MCP-Protocol-Version": "1900-01-01", "Mcp-Method": "tools/list"])
        XCTAssertEqual(over.status, 400)
        XCTAssertEqual(over.body?["error"]?["code"], .int(-32022))
    }

    /// Неизвестный инструмент — `-32602`, и по HTTP не 404: 404 с `-32601`
    /// значит «метода нет у сервера».
    func testAnUnknownToolIsInvalidParamsNotMethodNotFound() async throws {
        let text = #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"nope",\#(modernMeta)}}"#
        let direct = try await answer(text)
        XCTAssertEqual(direct?["error"]?["code"], .int(-32602))
        let over = try await http(text, headers: [
            "MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/call", "Mcp-Name": "nope",
        ])
        XCTAssertNotEqual(over.status, 404)
        XCTAssertEqual(over.body?["error"]?["code"], .int(-32602))
    }

    /// Неизвестный метод — `-32601`, по HTTP 404 с телом ошибки.
    func testAnUnknownMethodIsNotFound() async throws {
        let text = #"{"jsonrpc":"2.0","id":6,"method":"prompts/list","params":{\#(modernMeta)}}"#
        let over = try await http(text, headers: ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "prompts/list"])
        XCTAssertEqual(over.status, 404)
        XCTAssertEqual(over.body?["error"]?["code"], .int(-32601))
    }

    /// `ping` удалён в `2026-07-28`: запрос новой ревизии получает «метода
    /// нет», старой — пустой результат.
    func testPingBelongsToTheOldRevisionsOnly() async throws {
        let modern = try await answer(#"{"jsonrpc":"2.0","id":7,"method":"ping","params":{\#(modernMeta)}}"#)
        XCTAssertEqual(modern?["error"]?["code"], .int(-32601))
        let legacy = try await answer(#"{"jsonrpc":"2.0","id":8,"method":"ping"}"#)
        XCTAssertEqual(legacy?["result"], .object([:]))
    }

    /// Ошибка без прочитанного идентификатора — без поля `id`; пакет —
    /// `-32600`, не ошибка разбора.
    func testUnreadableMessagesAnswerWithoutIdentifier() async throws {
        let garbage = try await answer("не json")
        XCTAssertNil(garbage?["id"])
        XCTAssertEqual(garbage?["error"]?["code"], .int(-32700))
        let batch = try await answer(#"[{"jsonrpc":"2.0","id":1,"method":"tools/list"}]"#)
        XCTAssertNil(batch?["id"])
        XCTAssertEqual(batch?["error"]?["code"], .int(-32600))
        let over = try await http(#"[{"jsonrpc":"2.0","id":1,"method":"tools/list"}]"#, headers: [:])
        XCTAssertEqual(over.status, 400)
        XCTAssertEqual(over.body?["error"]?["code"], .int(-32600))
        XCTAssertNil(over.body?["id"])
    }

    /// Заголовок новой ревизии без версии в теле — испорченный запрос.
    func testAModernHeaderNeedsTheVersionInTheBody() async throws {
        let over = try await http(
            #"{"jsonrpc":"2.0","id":9,"method":"tools/list"}"#,
            headers: ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/list"]
        )
        XCTAssertEqual(over.status, 400)
        XCTAssertEqual(over.body?["error"]?["code"], .int(-32602))
    }

    /// Неверные аргументы — ошибка выполнения (`isError`); не объект
    /// в «arguments» — нарушение формы `tools/call`, ошибка протокола.
    func testArgumentErrorsAreToolErrorsAndShapeErrorsAreProtocolErrors() async throws {
        let bad = try await answer(#"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"describe_collection","arguments":{},\#(modernMeta)}}"#)
        XCTAssertNil(bad?["error"])
        XCTAssertEqual(bad?["result"]?["isError"], .bool(true))
        XCTAssertEqual(bad?["result"]?["resultType"], .string("complete"))
        let shape = try await answer(#"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"describe_collection","arguments":"x",\#(modernMeta)}}"#)
        XCTAssertEqual(shape?["error"]?["code"], .int(-32602))
    }

    /// Уведомление по HTTP — 202 без тела.
    func testANotificationIsAcceptedWithoutBody() async throws {
        let over = try await http(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#, headers: [:])
        XCTAssertEqual(over.status, 202)
        XCTAssertNil(over.body)
    }

    // MARK: - Старые ревизии

    /// Рукопожатие каждой старой ревизии отвечается ею же; незнакомая —
    /// самой новой из старых.
    func testEveryLegacyRevisionIsNegotiated() async throws {
        for version in ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"] {
            let result = try await answer(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(version)","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}"#)?["result"]
            XCTAssertEqual(result?["protocolVersion"], .string(version))
            XCTAssertEqual(result?["serverInfo"]?["name"], .string(MCPProtocol.serverName), version)
            XCTAssertNotNil(result?["capabilities"]?["tools"], version)
        }
        let newer = try await answer(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2099-01-01","capabilities":{}}}"#)
        XCTAssertEqual(newer?["result"]?["protocolVersion"], .string("2025-11-25"))
        // Уведомление о завершённом рукопожатии ответа не получает.
        let initialized = try await answer(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(initialized)
    }

    /// После рукопожатия запросы без `_meta` обслуживаются, в том числе по
    /// HTTP с заголовком старой ревизии и без зеркальных заголовков.
    func testLegacyRequestsAreServed() async throws {
        let plain = try await answer(#"{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}"#)
        XCTAssertFalse(plain?["result"]?["tools"]?.arrayValue?.isEmpty ?? true)
        for version in ["2025-11-25", "2025-06-18"] {
            let over = try await http(#"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#, headers: ["MCP-Protocol-Version": version])
            XCTAssertEqual(over.status, 200, version)
            XCTAssertNotNil(over.body?["result"]?["tools"], version)
        }
        // Клиенты до 2025-06-18 заголовка версии не шлют вовсе.
        let headerless = try await http(#"{"jsonrpc":"2.0","id":5,"method":"tools/list"}"#, headers: [:])
        XCTAssertEqual(headerless.status, 200)
    }

    /// Неверные аргументы — по правилам ревизии клиента: до `2025-11-25`
    /// это ошибка протокола (`-32602`), с неё — результат с `isError`.
    /// Ревизию сервер узнаёт из `_meta`, из заголовка, из рукопожатия на
    /// соединении; без всего этого предполагает `2025-03-26`.
    func testArgumentErrorsFollowTheClientRevision() async throws {
        let call = #"{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"describe_collection","arguments":{}}}"#
        let server = self.server()
        func reply(negotiated: String?) async throws -> JSONValue? {
            let outgoing = await server.respond(to: Data(call.utf8), negotiatedVersion: negotiated)
            return try outgoing.map { try JSONDecoder().decode(JSONValue.self, from: $0.encoded()) }
        }
        for version in ["2025-06-18", "2025-03-26", "2024-11-05"] {
            let answer = try await reply(negotiated: version)
            XCTAssertEqual(answer?["error"]?["code"], .int(-32602), version)
            XCTAssertNil(answer?["result"], version)
        }
        let current = try await reply(negotiated: "2025-11-25")
        XCTAssertEqual(current?["result"]?["isError"], .bool(true))
        let unnamed = try await reply(negotiated: nil)
        XCTAssertEqual(unnamed?["error"]?["code"], .int(-32602))

        // Версия в `_meta` важнее известной транспорту.
        let named = #"{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"describe_collection","arguments":{},"_meta":{"io.modelcontextprotocol/protocolVersion":"2025-11-25"}}}"#
        let viaMeta = await server.respond(to: Data(named.utf8), negotiatedVersion: "2025-06-18")
        let decoded = try viaMeta.map { try JSONDecoder().decode(JSONValue.self, from: $0.encoded()) }
        XCTAssertEqual(decoded?["result"]?["isError"], .bool(true))

        // По HTTP ревизию называет заголовок.
        for (version, isError) in [("2025-06-18", false), ("2025-11-25", true)] {
            let over = try await http(call, headers: ["MCP-Protocol-Version": version], server: server)
            XCTAssertEqual(over.status, 200, version)
            if isError {
                XCTAssertEqual(over.body?["result"]?["isError"], .bool(true), version)
            } else {
                XCTAssertEqual(over.body?["error"]?["code"], .int(-32602), version)
            }
        }
        let headerless = try await http(call, headers: [:], server: server)
        XCTAssertEqual(headerless.body?["error"]?["code"], .int(-32602))
    }

    /// Старая версия, названная в `_meta`, обслуживается: сервер сам числит
    /// её поддерживаемой и не отсылает клиента по кругу.
    func testALegacyVersionNamedInMetaIsServed() async throws {
        let text = #"{"jsonrpc":"2.0","id":6,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2025-06-18"}}}"#
        let reply = try await answer(text)
        XCTAssertNil(reply?["error"])
        XCTAssertNotNil(reply?["result"]?["tools"])
    }
}

private struct NoBackend: MCPToolBackend {
    func collections(allowed: [String]) async throws -> [MCPCollectionSummary] { [] }
    func describe(collection: String) async throws -> MCPCollectionDescription { throw MCPToolFailure("no") }
    func search(_ request: MCPSearchRequest) async throws -> MCPSearchAnswer { throw MCPToolFailure("no") }
    func documents(_ request: MCPDocumentsRequest) async throws -> MCPDocumentsAnswer { throw MCPToolFailure("no") }
    func add(_ request: MCPAddRequest) async throws -> MCPAddAnswer { throw MCPToolFailure("no") }
    func delete(_ request: MCPDeleteRequest) async throws -> MCPDeleteAnswer { throw MCPToolFailure("no") }
}
