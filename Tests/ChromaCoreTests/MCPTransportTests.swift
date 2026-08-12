import XCTest
@testable import ChromaCore

/// Этап 7 — несущий слой MCP: кадрирование, сообщения, маршрутизация.
final class MCPTransportTests: XCTestCase {

    private func json(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    // MARK: - Кадрирование

    func testMessageSplitAcrossReadsIsAssembledBack() throws {
        // Чтение из потока режет данные как попало — сообщение, пришедшее
        // двумя кусками, обязано собраться.
        var framer = LineFramer()
        XCTAssertTrue(try framer.consume(Data(#"{"a":"#.utf8)).isEmpty)
        let messages = try framer.consume(Data("1}\n".utf8))
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(try json(messages[0]), .object(["a": .int(1)]))
    }

    func testSeveralMessagesInOneReadAreAllReturned() throws {
        var framer = LineFramer()
        let messages = try framer.consume(Data("{\"a\":1}\n{\"a\":2}\n{\"a\":3}\n".utf8))
        XCTAssertEqual(messages.count, 3)
    }

    func testBlankLinesAreSkippedRatherThanFailing() throws {
        // Лишний перевод строки ничего не нарушает, а ошибка разбора
        // на пустоте выглядела бы загадкой.
        var framer = LineFramer()
        XCTAssertEqual(try framer.consume(Data("\n\n{\"a\":1}\n".utf8)).count, 1)
    }

    func testTailWithoutNewlineIsNotLostOnClose() throws {
        var framer = LineFramer()
        XCTAssertTrue(try framer.consume(Data(#"{"a":1}"#.utf8)).isEmpty)
        XCTAssertEqual(try json(XCTUnwrap(framer.flush())), .object(["a": .int(1)]))
        XCTAssertNil(framer.flush())
    }

    func testUnterminatedStreamIsRefusedInsteadOfEatingMemory() throws {
        // Отправитель, забывший перевод строки, не должен заставить нас
        // копить его поток до конца памяти.
        var framer = LineFramer()
        let chunk = Data(repeating: UInt8(ascii: "x"), count: 1024 * 1024)
        XCTAssertThrowsError(try {
            for _ in 0...17 { _ = try framer.consume(chunk) }
        }())
    }

    func testEncodedMessageNeverContainsARawNewline() throws {
        // Требование спецификации «в сообщении нет переводов строк»
        // выполняется само: JSONEncoder экранирует их внутри строк.
        // Проверяем это, а не верим на слово.
        let message = JSONRPCOutgoing.result(
            id: .int(1), .object(["text": .string("первая\nвторая\nтретья")])
        )
        let encoded = try message.encoded()
        XCTAssertFalse(encoded.contains(UInt8(ascii: "\n")))

        var framer = LineFramer()
        let framed = try framer.consume(LineFraming.frame(encoded))
        XCTAssertEqual(framed.count, 1, "многострочный текст должен остаться одним сообщением")
        XCTAssertEqual(
            try json(framed[0])["result"]?["text"]?.stringValue,
            "первая\nвторая\nтретья"
        )
    }

    // MARK: - Значения и сообщения

    func testWholeNumbersSurviveTheRoundTripAsIntegers() throws {
        // 10, вернувшееся как 10.0, — другой JSON: агент, сверяющий ответ
        // со схемой "type": "integer", получил бы отказ.
        let value = try json(Data(#"{"n_results":10,"score":0.5}"#.utf8))
        XCTAssertEqual(value["n_results"], .int(10))
        XCTAssertEqual(value["score"], .double(0.5))
        let encoded = try JSONEncoder().encode(value)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\"n_results\":10"))
    }

    func testRequestIdentifierKeepsItsKind() throws {
        // Строковый «7», приведённый к числу, вернулся бы клиенту как чужой
        // с виду ответ.
        let incoming = try JSONDecoder().decode(
            JSONRPCIncoming.self, from: Data(#"{"jsonrpc":"2.0","id":"7","method":"x"}"#.utf8)
        )
        XCTAssertEqual(incoming.id, .string("7"))
        let encoded = try JSONRPCOutgoing.result(id: XCTUnwrap(incoming.id), .null).encoded()
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\"id\":\"7\""))
    }

    func testErrorResponseCarriesNoResultField() throws {
        let encoded = try JSONRPCOutgoing.failure(
            id: .int(1), JSONRPCError(code: -1, message: "нет")
        ).encoded()
        let value = try json(encoded)
        XCTAssertNil(value["result"], "result рядом с error нарушает JSON-RPC")
        XCTAssertEqual(value["error"]?["code"], .int(-1))
    }

    func testUnparseableMessageIsAnsweredWithNullIdentifier() async throws {
        let server = MCPServer(serverVersion: "1.0")
        let answered = await server.respond(to: Data("не json".utf8))
        let response = try XCTUnwrap(answered)
        let value = try json(try response.encoded())
        XCTAssertEqual(value["id"], .null, "молчание оставило бы клиента ждать вечно")
        XCTAssertEqual(value["error"]?["code"], .int(JSONRPCError.parseError))
    }

    // MARK: - Маршрутизация

    private func request(
        _ method: String, id: JSONRPCID? = .int(1), version: String? = MCPProtocol.version
    ) -> JSONRPCIncoming {
        var meta: [String: JSONValue] = [:]
        if let version { meta[MCPProtocol.metaProtocolVersion] = .string(version) }
        return JSONRPCIncoming(id: id, method: method, params: .object(["_meta": .object(meta)]))
    }

    func testDiscoverReportsVersionsAndIdentityWhereTheSpecPutsThem() async throws {
        let server = MCPServer(serverVersion: "1.2.3")
        let answered = await server.respond(to: request(MCPProtocol.discoverMethod))
        let response = try XCTUnwrap(answered)
        let result = try XCTUnwrap(try json(try response.encoded())["result"])

        XCTAssertEqual(result["resultType"], .string("complete"))
        // Названы все обслуживаемые ревизии, новая первой: с 9 августа
        // 2026 года приложение отвечает и старой эпохе.
        XCTAssertEqual(
            result["supportedVersions"],
            .array(MCPProtocol.supportedVersions.map(JSONValue.string))
        )
        // Сведения о сервере лежат в _meta, а не рядом с возможностями.
        let info = result["_meta"]?["io.modelcontextprotocol/serverInfo"]
        XCTAssertEqual(info?["name"]?.stringValue, MCPProtocol.serverName)
        XCTAssertEqual(info?["version"]?.stringValue, "1.2.3")
    }

    func testNoCapabilityIsDeclaredWhileNoneIsServed() async throws {
        // Объявленная, но не обслуживаемая возможность — обещание, по которому
        // клиент построит запрос и получит отказ.
        let server = MCPServer(serverVersion: "1.0")
        let answered = await server.respond(to: request(MCPProtocol.discoverMethod))
        let response = try XCTUnwrap(answered)
        let result = try XCTUnwrap(try json(try response.encoded())["result"])
        XCTAssertEqual(result["capabilities"], .object([:]))
    }

    /// старое рукопожатие обслуживается, а не отвергается.
    func testTheLegacyHandshakeIsAnswered() async throws {
        let server = MCPServer(serverVersion: "1.0")
        let legacy = JSONRPCIncoming(id: .int(1), method: "initialize", params: nil)
        let answered = await server.respond(to: legacy)
        let response = try XCTUnwrap(answered)
        let body = try json(try response.encoded())
        XCTAssertNil(body["error"], "клиент старой эпохи обязан получить рукопожатие, а не отказ")
        let result = try XCTUnwrap(body["result"])
        XCTAssertEqual(result["protocolVersion"], .string(MCPProtocol.legacyVersions[0]))
        XCTAssertEqual(result["serverInfo"]?["name"], .string(MCPProtocol.serverName))
        XCTAssertEqual(result["serverInfo"]?["version"], .string("1.0"))
    }

    /// Просьбу, которую узнаём, возвращаем ею же: клиент вправе говорить на
    /// той ревизии, которую просил.
    func testTheRequestedLegacyVersionComesBack() async throws {
        let server = MCPServer(serverVersion: "1.0")
        let asked = JSONRPCIncoming(
            id: .int(1), method: "initialize",
            params: .object(["protocolVersion": .string("2024-11-05")])
        )
        let answered = await server.respond(to: asked)
        let response = try XCTUnwrap(answered)
        let result = try XCTUnwrap(try json(try response.encoded())["result"])
        XCTAssertEqual(result["protocolVersion"], .string("2024-11-05"))
    }

    /// А запрос без версии после рукопожатия обязан работать: в старой эпохе
    /// её в запросах нет вовсе, и требовать её значило бы отвергнуть всю
    /// эпоху сразу после того, как мы ей ответили.
    func testARequestWithoutAVersionIsServedAfterTheHandshake() async throws {
        let server = MCPServer(serverVersion: "1.0")
        let answered = await server.respond(
            to: JSONRPCIncoming(id: .int(2), method: MCPProtocol.discoverMethod, params: nil)
        )
        let response = try XCTUnwrap(answered)
        let body = try json(try response.encoded())
        XCTAssertNil(body["error"], "запрос старой эпохи не должен получать отказ по версии")
        XCTAssertNotNil(body["result"])
    }

    /// Уведомление о завершении рукопожатия ответа не требует и не допускает.
    func testTheInitializedNotificationIsSilent() async throws {
        let server = MCPServer(serverVersion: "1.0")
        let answered = await server.respond(
            to: JSONRPCIncoming(id: nil, method: MCPProtocol.initializedNotification, params: nil)
        )
        XCTAssertNil(answered)
    }

    func testPingIsAnsweredEmpty() async throws {
        let server = MCPServer(serverVersion: "1.0")
        let answered = await server.respond(
            to: JSONRPCIncoming(id: .int(3), method: MCPProtocol.pingMethod, params: nil)
        )
        let response = try XCTUnwrap(answered)
        XCTAssertEqual(try json(try response.encoded())["result"], .object([:]))
    }

    func testUnsupportedVersionIsRefusedWithTheListToRetryWith() async throws {
        let server = MCPServer(serverVersion: "1.0")
        let answered = await server.respond(to: request(MCPProtocol.discoverMethod, version: "1900-01-01"))
        let response = try XCTUnwrap(answered)
        let error = try XCTUnwrap(try json(try response.encoded())["error"])
        XCTAssertEqual(error["code"], .int(-32022))
        XCTAssertEqual(error["data"]?["requested"], .string("1900-01-01"))
        XCTAssertEqual(
            error["data"]?["supported"],
            .array(MCPProtocol.supportedVersions.map(JSONValue.string))
        )
    }

    /// Прежде запрос без версии считался ошибкой: «не угадываем, а отвергаем».
    /// С это перевёрнуто, и перевёрнуто сознательно — в старой эпохе
    /// версии в запросах нет вовсе, она называется один раз в рукопожатии.
    /// Отвергать такие запросы значило бы ответить клиенту рукопожатием и тут
    /// же отказать ему во всём остальном.
    func testARequestWithoutAVersionIsTreatedAsTheOlderEpoch() async throws {
        let server = MCPServer(serverVersion: "1.0")
        let answered = await server.respond(to: request(MCPProtocol.discoverMethod, version: nil))
        let response = try XCTUnwrap(answered)
        let body = try json(try response.encoded())
        XCTAssertNil(body["error"])
        XCTAssertNotNil(body["result"])
    }

    /// А вот **названная** и незнакомая версия по-прежнему отвергается: это
    /// не старый клиент, а клиент из будущего или из ниоткуда, и угадывать
    /// за него нельзя.
    func testANamedUnknownVersionIsStillRefused() async throws {
        let server = MCPServer(serverVersion: "1.0")
        let answered = await server.respond(to: request(MCPProtocol.discoverMethod, version: "1900-01-01"))
        let response = try XCTUnwrap(answered)
        XCTAssertNotNil(try json(try response.encoded())["error"])
    }

    func testNotificationIsNeverAnswered() async {
        // У уведомления нет идентификатора, и отвечать на него запрещено.
        let server = MCPServer(serverVersion: "1.0")
        let answered = await server.respond(to: request(MCPProtocol.cancelledNotification, id: nil))
        XCTAssertNil(answered)
    }

    func testUnknownMethodIsAProtocolError() async throws {
        let server = MCPServer(serverVersion: "1.0")
        let answered = await server.respond(to: request("tools/nonesuch"))
        let response = try XCTUnwrap(answered)
        let error = try XCTUnwrap(try json(try response.encoded())["error"])
        XCTAssertEqual(error["code"], .int(JSONRPCError.methodNotFound))
    }
}
