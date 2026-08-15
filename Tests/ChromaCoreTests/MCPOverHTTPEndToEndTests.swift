import XCTest
import Network
@testable import ChromaCore

/// MCP по сети, через тот же слушатель, что и прокси (HTTP-режим).
///
/// Правила транспорта проверены отдельно и без сокетов. Здесь другое: доходит
/// ли запрос агента до инструментов **по настоящему TCP**, тем же путём, каким
/// придёт настоящий клиент, — включая разбор HTTP, маршрутизацию по пути
/// и запись в журнал доступа.
final class MCPOverHTTPEndToEndTests: XCTestCase {
    private var core: ProxyCore?
    private var upstream: StubUpstream?
    private var directory: URL?

    override func tearDown() {
        core?.stop()
        upstream?.stop()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        core = nil
        upstream = nil
        directory = nil
        super.tearDown()
    }

    /// Поднимает прокси с включённым HTTP-режимом MCP и отдаёт его порт.
    @MainActor
    private func startProxy() async throws -> (port: Int, audit: AuditLog) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcp-http-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory

        let upstream = try StubUpstream(body: "{\"ok\":true}")
        self.upstream = upstream

        let audit = AuditLog(fileURL: directory.appendingPathComponent("audit.jsonl"))
        let access = AccessController()
        // Конечная точка MCP требует зарегистрированный ключ — как и всё
        // остальное на этом порту.
        await access.setClients([
            ExternalClient(
                name: "агент",
                keyHash: ClientKey.hash(Self.key),
                keyPrefix: ClientKey.prefix(of: Self.key),
                permissions: ClientPermissions(collections: [], allowsWrite: false)
            ),
        ])
        let core = ProxyCore(audit: audit, access: access)
        // Сервер без инструментов: проверяется дорога до него, а не они сами —
        // у инструментов свои тесты.
        let transport = MCPHTTPTransport(server: MCPServer(serverVersion: "тест"), allowedOrigins: [])
        core.mcp = { method, headers, body, key in
            await transport.handle(method: method, headers: headers, body: body, key: key)
        }
        self.core = core

        let port = PortUtility.freePort()
        try core.start(
            upstreamHost: "127.0.0.1",
            upstreamPort: upstream.port,
            listenPort: port,
            bindHost: "127.0.0.1"
        )
        try await Task.sleep(nanoseconds: 300_000_000)
        return (port, audit)
    }

    private func post(
        port: Int,
        path: String = MCPHTTPTransport.endpointPath,
        headers: [String] = [],
        body: String,
        method: String = "POST"
    ) -> (status: Int, body: String) {
        var arguments = ["-s", "-o", "/dev/stderr", "-w", "%{http_code}", "-X", method]
        for header in headers { arguments += ["-H", header] }
        arguments += ["--data-binary", body, "http://127.0.0.1:\(port)\(path)"]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try? process.run()
        let code = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let payload = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return (Int(code.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1, payload)
    }

    private func request(id: Int, method: String) -> String {
        """
        {"jsonrpc":"2.0","id":\(id),"method":"\(method)","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"\(MCPProtocol.version)"}}}
        """
    }

    /// Ключ зарегистрированного клиента.
    private static let key = "mcp-http-test-key"

    private var goodHeaders: [String] {
        [
            "Content-Type: application/json",
            "Accept: application/json, text/event-stream",
            "MCP-Protocol-Version: \(MCPProtocol.version)",
            "X-Chroma-Token: \(Self.key)",
        ]
    }

    @MainActor
    func testAnAgentReachesTheServerOverTheProxyPort() async throws {
        let (port, audit) = try await startProxy()

        let response = post(
            port: port,
            headers: goodHeaders + ["Mcp-Method: \(MCPProtocol.discoverMethod)"],
            body: request(id: 1, method: MCPProtocol.discoverMethod)
        )
        XCTAssertEqual(response.status, 200, response.body)
        XCTAssertTrue(response.body.contains("result"), response.body)
        XCTAssertTrue(
            response.body.contains(MCPProtocol.serverName),
            "ответ должен прийти от нашего сервера, а не от ChromaDB: \(response.body)"
        )

        // Запрос агента обязан попасть в журнал доступа: вопрос «что делали
        // с базой чужими руками» один для прокси и для MCP.
        //
        // Запись догоняет: `curl` уже получил ответ, а журнал пополняется
        // на главном акторе следующим тактом. Ждём событие, а не «немного»:
        // фиксированная пауза либо тормозит тест, либо однажды не хватает.
        var entries: [AuditEntry] = []
        for _ in 0..<50 {
            entries = audit.entries.filter { $0.operation.hasPrefix("mcp_") }
            if !entries.isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(entries.isEmpty, "обращение по MCP не записано в журнал")
        XCTAssertEqual(entries.first?.responseStatus, 200)
        XCTAssertEqual(entries.first?.client, "агент", "журнал обязан отвечать на вопрос «кто», а не показывать адрес")
    }

    /// Без ключа конечная точка не отвечает ничем содержательным.
    ///
    /// Раньше `server/discover`, `ping` и `initialize` отвечали кому угодно
    /// из сети: они доходят до ответа раньше, чем слой инструментов
    /// спрашивает про права. Имя сервера, его версия и подсказка модели
    /// о том, как пользоваться базой, — не то, что отдают неизвестному.
    @MainActor
    func testWithoutAKeyTheEndpointTellsNothing() async throws {
        let (port, _) = try await startProxy()

        let headers = goodHeaders.filter { !$0.hasPrefix("X-Chroma-Token") }
            + ["Mcp-Method: \(MCPProtocol.discoverMethod)"]
        let response = post(port: port, headers: headers, body: request(id: 9, method: MCPProtocol.discoverMethod))

        XCTAssertEqual(response.status, 401, response.body)
        XCTAssertFalse(response.body.contains(MCPProtocol.serverName), "имя сервера не должно уезжать без ключа")
        XCTAssertFalse(response.body.contains("supportedVersions"), "и список возможностей тоже")
    }

    /// Чужой ключ — то же самое, что никакого.
    @MainActor
    func testAnUnknownKeyIsRefusedToo() async throws {
        let (port, _) = try await startProxy()
        let headers = goodHeaders.filter { !$0.hasPrefix("X-Chroma-Token") }
            + ["X-Chroma-Token: не-тот-ключ", "Mcp-Method: \(MCPProtocol.discoverMethod)"]
        let response = post(port: port, headers: headers, body: request(id: 10, method: MCPProtocol.discoverMethod))
        XCTAssertEqual(response.status, 401, response.body)
    }

    @MainActor
    func testTheEndpointDoesNotLeakIntoTheDatabaseAndBackwards() async throws {
        let (port, _) = try await startProxy()

        // Путь MCP не уходит на ChromaDB: заглушка ответила бы `{"ok":true}`.
        let mcp = post(
            port: port,
            headers: goodHeaders + ["Mcp-Method: \(MCPProtocol.discoverMethod)"],
            body: request(id: 2, method: MCPProtocol.discoverMethod)
        )
        XCTAssertFalse(mcp.body.contains("\"ok\""), "запрос MCP ушёл на базу: \(mcp.body)")

        // И наоборот: путь базы не попадает в MCP, а получает обычный отказ
        // прокси по правам — ключа в запросе нет.
        let database = post(
            port: port,
            path: "/api/v2/heartbeat",
            headers: ["Content-Type: application/json"],
            body: ""
        )
        XCTAssertEqual(database.status, 401, "запрос к базе обязан проходить обычную проверку ключа")
    }

    @MainActor
    func testTheOldEraGetStreamIsRefusedOverTheWire() async throws {
        let (port, _) = try await startProxy()
        let response = post(port: port, headers: goodHeaders, body: "", method: "GET")
        XCTAssertEqual(response.status, 405, "GET-потока в этой ревизии нет: \(response.body)")
    }

    @MainActor
    func testHeaderMismatchIsRefusedOverTheWire() async throws {
        let (port, _) = try await startProxy()
        let response = post(
            port: port,
            headers: goodHeaders + ["Mcp-Method: tools/list"],
            body: request(id: 3, method: MCPProtocol.discoverMethod)
        )
        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(
            response.body.contains("\(MCPHTTPTransport.headerMismatch)"),
            "отказ должен нести код -32020: \(response.body)"
        )
    }

    @MainActor
    func testWithoutTheSettingTheEndpointIsNotServed() async throws {
        let (port, _) = try await startProxy()
        // Выключение режима — это снятие обработчика; путь сразу перестаёт
        // быть особенным и уходит на базу, где ключа нет.
        core?.mcp = nil

        let response = post(
            port: port,
            headers: goodHeaders + ["Mcp-Method: \(MCPProtocol.discoverMethod)"],
            body: request(id: 4, method: MCPProtocol.discoverMethod)
        )
        // Ответ приходит от прокси, а не от MCP: путь стал обычным и упёрся
        // в права ключа. Важно не число, а то, что сервер MCP не отозвался.
        XCTAssertGreaterThanOrEqual(response.status, 400, response.body)
        XCTAssertFalse(
            response.body.contains(MCPProtocol.serverName),
            "выключенный HTTP-режим не должен отвечать по MCP: \(response.body)"
        )
    }
}
