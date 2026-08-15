import XCTest
@testable import ChromaCore

/// Привязка MCP к HTTP, ревизия `2026-07-28`.
///
/// Тесты написаны по букве спецификации, а не по тому, как «обычно делают»:
/// в этой ревизии из транспорта убраны сессии и GET-поток, а зеркальные
/// заголовки сервер обязан сверять с телом. Каждое правило здесь — отдельная
/// проверка, потому что нарушение любого из них выглядит как работающий
/// сервер ровно до первого настоящего клиента.
final class MCPHTTPTests: XCTestCase {
    private func transport(origins: [String] = []) -> MCPHTTPTransport {
        MCPHTTPTransport(server: MCPServer(serverVersion: "тест"), allowedOrigins: origins)
    }

    private func body(
        id: Int? = 1,
        method: String,
        params: [String: JSONValue]? = nil,
        version: String? = MCPProtocol.version
    ) -> Data {
        var payload: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let id { payload["id"] = .int(id) }
        var parameters = params ?? [:]
        if let version {
            parameters[MCPProtocol.metaKey] = .object([
                MCPProtocol.metaProtocolVersion: .string(version),
            ])
        }
        if !parameters.isEmpty { payload["params"] = .object(parameters) }
        return try! JSONEncoder().encode(JSONValue.object(payload))
    }

    private func headers(
        version: String? = MCPProtocol.version,
        method: String? = nil,
        name: String? = nil,
        origin: String? = nil
    ) -> [(name: String, value: String)] {
        var result: [(name: String, value: String)] = [("Content-Type", "application/json")]
        if let version { result.append(("MCP-Protocol-Version", version)) }
        if let method { result.append(("Mcp-Method", method)) }
        if let name { result.append(("Mcp-Name", name)) }
        if let origin { result.append(("Origin", origin)) }
        return result
    }

    private func errorCode(in response: MCPHTTPTransport.Response) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return nil }
        return error["code"] as? Int
    }

    // MARK: - Конечная точка

    func testOnlyTheOneEndpointPathIsRecognised() {
        XCTAssertTrue(MCPHTTPTransport.isEndpoint(path: "/mcp"))
        XCTAssertTrue(MCPHTTPTransport.isEndpoint(path: "/mcp/"))
        XCTAssertTrue(MCPHTTPTransport.isEndpoint(path: "/mcp?client=x"))
        XCTAssertFalse(MCPHTTPTransport.isEndpoint(path: "/mcp/tools"))
        XCTAssertFalse(MCPHTTPTransport.isEndpoint(path: "/api/v2/heartbeat"))
        // Путь базы данных не должен случайно уехать в MCP: это разные миры.
        XCTAssertFalse(MCPHTTPTransport.isEndpoint(path: "/"))
    }

    // MARK: - Методы, которых больше нет

    func testGetAndDeleteAreRefusedWith405() async {
        // Прежние клиенты открывали GET-поток и удаляли сессию через DELETE.
        // Спецификация велит отвечать им 405, а не притворяться понимающими.
        for verb in ["GET", "DELETE", "PUT", "HEAD"] {
            let response = await transport().handle(method: verb, headers: headers(), body: Data())
            XCTAssertEqual(response.status, 405, "\(verb) обязан получить 405")
            XCTAssertTrue(
                response.headers.contains { $0.name == "Allow" && $0.value == "POST" },
                "отказ должен называть допустимый метод"
            )
        }
    }

    // MARK: - Origin

    func testAnUnknownOriginIsForbidden() async {
        let response = await transport(origins: ["https://good.example"]).handle(
            method: "POST",
            headers: headers(method: "tools/list", origin: "https://evil.example"),
            body: body(method: "tools/list")
        )
        XCTAssertEqual(response.status, 403, "иначе страница из браузера достучится до базы через перепривязку DNS")
    }

    func testAKnownOriginPasses() async {
        let response = await transport(origins: ["https://good.example"]).handle(
            method: "POST",
            headers: headers(method: "tools/list", origin: "https://good.example"),
            body: body(method: "tools/list")
        )
        XCTAssertNotEqual(response.status, 403)
    }

    func testNullOriginIsNeverAllowed() async {
        // `null` присылает страница из файла или песочницы — ровно тот случай,
        // от которого проверка и защищает.
        let response = await transport(origins: ["null"]).handle(
            method: "POST",
            headers: headers(method: "tools/list", origin: "null"),
            body: body(method: "tools/list")
        )
        XCTAssertEqual(response.status, 403)
    }

    func testARequestWithoutOriginIsNotABrowserAndPasses() async {
        let response = await transport().handle(
            method: "POST",
            headers: headers(method: "tools/list"),
            body: body(method: "tools/list")
        )
        XCTAssertNotEqual(response.status, 403, "у агента, запущенного из терминала, Origin нет вовсе")
    }

    // MARK: - Заголовки против тела

    func testAMissingProtocolVersionHeaderIsAMismatch() async {
        let response = await transport().handle(
            method: "POST",
            headers: headers(version: nil, method: "tools/list"),
            body: body(method: "tools/list")
        )
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(errorCode(in: response), MCPHTTPTransport.headerMismatch)
    }

    func testAVersionHeaderThatDisagreesWithTheBodyIsRefused() async {
        // Посредник маршрутизирует по заголовку, сервер выполняет по телу.
        // Расхождение между ними — дыра, а не мелочь.
        let response = await transport().handle(
            method: "POST",
            headers: headers(version: "2025-06-18", method: "tools/list"),
            body: body(method: "tools/list", version: MCPProtocol.version)
        )
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(errorCode(in: response), MCPHTTPTransport.headerMismatch)
    }

    func testAMethodHeaderThatDisagreesWithTheBodyIsRefused() async {
        let response = await transport().handle(
            method: "POST",
            headers: headers(method: "tools/list"),
            body: body(method: "tools/call", params: ["name": .string("search")])
        )
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(errorCode(in: response), MCPHTTPTransport.headerMismatch)
    }

    func testToolCallsRequireTheNameHeaderAndItMustMatch() async {
        let missing = await transport().handle(
            method: "POST",
            headers: headers(method: "tools/call"),
            body: body(method: "tools/call", params: ["name": .string("search")])
        )
        XCTAssertEqual(errorCode(in: missing), MCPHTTPTransport.headerMismatch)

        let wrong = await transport().handle(
            method: "POST",
            headers: headers(method: "tools/call", name: "delete_everything"),
            body: body(method: "tools/call", params: ["name": .string("search")])
        )
        XCTAssertEqual(errorCode(in: wrong), MCPHTTPTransport.headerMismatch, "имя в заголовке решает, куда запрос пустят")
    }

    func testListingToolsNeedsNoNameHeader() async {
        let response = await transport().handle(
            method: "POST",
            headers: headers(method: "tools/list"),
            body: body(method: "tools/list")
        )
        XCTAssertNotEqual(errorCode(in: response), MCPHTTPTransport.headerMismatch)
    }

    func testANameThatIsNotASCIITravelsBase64() {
        // Русское имя коллекции в заголовок в открытом виде не помещается:
        // HTTP разрешает там только видимый ASCII.
        let encoded = "=?base64?" + Data("отчёты".utf8).base64EncodedString() + "?="
        XCTAssertEqual(MCPHTTPTransport.decodeHeaderValue(encoded), "отчёты")
        XCTAssertEqual(MCPHTTPTransport.decodeHeaderValue("plain"), "plain")
        XCTAssertNil(MCPHTTPTransport.decodeHeaderValue("=?base64?не-база-64?="))
    }

    func testAnEncodedNameHeaderIsComparedAfterDecoding() async {
        let encoded = "=?base64?" + Data("отчёты".utf8).base64EncodedString() + "?="
        let response = await transport().handle(
            method: "POST",
            headers: headers(method: "resources/read", name: encoded),
            body: body(method: "resources/read", params: ["uri": .string("отчёты")])
        )
        XCTAssertNotEqual(errorCode(in: response), MCPHTTPTransport.headerMismatch)
    }

    // MARK: - Версия протокола

    func testAnUnsupportedVersionGetsTheListOfSupportedOnes() async {
        let response = await transport().handle(
            method: "POST",
            headers: headers(version: "1999-01-01", method: "tools/list"),
            body: body(method: "tools/list", version: "1999-01-01")
        )
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(errorCode(in: response), JSONRPCError.unsupportedProtocolVersion)

        let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        let data = error?["data"] as? [String: Any]
        let supported = data?["supported"] as? [String]
        XCTAssertEqual(supported, MCPProtocol.supportedVersions, "без списка версий отказ — тупик")
    }

    // MARK: - Тело

    func testUnparseableBodyIsAParseError() async {
        let response = await transport().handle(
            method: "POST",
            headers: headers(method: "tools/list"),
            body: Data("не json".utf8)
        )
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(errorCode(in: response), JSONRPCError.parseError)
    }

    func testANotificationIsAcceptedWithoutABody() async {
        let response = await transport().handle(
            method: "POST",
            headers: headers(method: MCPProtocol.cancelledNotification),
            body: body(id: nil, method: MCPProtocol.cancelledNotification)
        )
        XCTAssertEqual(response.status, 202, "у уведомления нет идентификатора — отвечать нечем")
        XCTAssertTrue(response.body.isEmpty)
    }

    func testAnUnknownMethodIsFourOhFourNotFiveHundred() async {
        // Так эта ревизия отличает «мы не умеем такой метод» от «здесь вообще
        // нет MCP»: тело с кодом -32601 против пустого 404 у чужого сервера.
        let response = await transport().handle(
            method: "POST",
            headers: headers(method: "tools/dance"),
            body: body(method: "tools/dance")
        )
        XCTAssertEqual(response.status, 404)
        XCTAssertEqual(errorCode(in: response), JSONRPCError.methodNotFound)
    }

    func testAGoodRequestAnswersWithJSON() async {
        let response = await transport().handle(
            method: "POST",
            headers: headers(method: MCPProtocol.discoverMethod),
            body: body(method: MCPProtocol.discoverMethod)
        )
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(
            response.headers.contains { $0.name == "Content-Type" && $0.value.contains("application/json") },
            "ответ обязан называть свой тип: клиент разбирает по нему"
        )
        let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        XCTAssertNotNil(object?["result"])
        XCTAssertNil(object?["error"])
    }

    // MARK: - Старая эпоха

    func testTheLegacyHandshakeIsNotRefusedForMissingHeaders() async {
        // Клиент старой эпохи заголовков не знает вовсе. Требовать
        // их значило бы отказать тому, кого мы решили обслуживать.
        let response = await transport().handle(
            method: "POST",
            headers: [("Content-Type", "application/json")],
            body: body(method: MCPProtocol.initializeMethod, params: ["protocolVersion": .string("2025-06-18")], version: nil)
        )
        XCTAssertEqual(response.status, 200)
        let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        XCTAssertNotNil(object?["result"], "рукопожатие обязано отвечать результатом")
    }
}
