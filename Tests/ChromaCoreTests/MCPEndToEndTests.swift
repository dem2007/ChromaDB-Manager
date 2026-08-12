import XCTest
@testable import ChromaCore

/// Этап 7 — сквозной обмен: настоящий сокет, а в одном тесте и настоящий
/// вспомогательный исполняемый файл.
///
/// Эти тесты существуют потому, что модульные проверяют разбор сообщений,
/// а сломаться здесь может ровно то, чего они не видят: кадрирование поверх
/// потока, склейка кусков и поведение при отсутствии приложения.
final class MCPEndToEndTests: XCTestCase {

    /// Короткий путь: под адрес сокета Unix в `sockaddr_un` отведено 104 байта,
    /// и каталоги временных файлов macOS съедают заметную их часть.
    private func makeSocketPath() throws -> String {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("s.sock").path
        try XCTSkipIf(path.utf8.count >= 104, "путь временного сокета не помещается в sockaddr_un")
        return path
    }

    private func startServer(
        at path: String, server: MCPServer = MCPServer(serverVersion: "test"), key: String? = nil
    ) throws -> MCPListener {
        let listener = MCPListener(path: path)
        listener.onConnection = { channel in
            channel.onMessage = { message in
                // Инструменты обращаются к базе, значит ответ асинхронный —
                // как и в приложении.
                Task {
                    guard let response = await server.respond(to: message, key: key),
                          let encoded = try? response.encoded() else { return }
                    channel.send(encoded)
                }
            }
        }
        try listener.start()
        return listener
    }

    // MARK: - Сокет

    func testRequestTravelsOverTheSocketAndTheAnswerComesBack() throws {
        let path = try makeSocketPath()
        let listener = try startServer(at: path)
        defer { listener.stop() }

        let answered = expectation(description: "ответ получен")
        let received = UncheckedBox<Data?>(nil)

        let channel = try MCPConnector.connect(path: path, queue: .global())
        channel.onMessage = { data in
            received.value = data
            answered.fulfill()
        }
        channel.start()
        defer { channel.close() }

        channel.send(try JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .int(1),
            "method": .string(MCPProtocol.discoverMethod),
            "params": .object(["_meta": .object([
                MCPProtocol.metaProtocolVersion: .string(MCPProtocol.version),
            ])]),
        ])))

        wait(for: [answered], timeout: 5)
        let value = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(received.value))
        XCTAssertEqual(value["id"], .int(1))
        XCTAssertEqual(value["result"]?["supportedVersions"], .array(MCPProtocol.supportedVersions.map(JSONValue.string)))
    }

    func testMissingAppIsReportedRatherThanHanging() throws {
        // Самое частое состояние: приложение просто не запущено. Агент,
        // не получивший ответа, зависает, и человек видит таймаут вместо
        // причины.
        let path = try makeSocketPath()
        XCTAssertThrowsError(try MCPConnector.connect(path: path, queue: .global())) { error in
            XCTAssertEqual(error as? MCPConnector.ConnectError, .appNotRunning)
        }
    }

    /// Файл сокета переживает закрытие приложения — и «файл есть» тогда
    /// значит «отвечать некому». Проверка на существование файла пропускала
    /// этот случай, сообщение уходило в мёртвый канал, и агент ждал ответа
    /// бесконечно. Найдено живой сверкой с DoD этапа 7.
    func testASocketFileLeftBehindIsNotMistakenForARunningApp() throws {
        let path = try makeSocketPath()
        // Файл сокета, который никто не слушает: приложение вышло, не убрав
        // его за собой (а после падения — тем более не уберёт).
        try makeAbandonedSocketFile(at: path)
        var status = stat()
        XCTAssertEqual(lstat(path, &status), 0, "стенд не воспроизводит случай: файла нет")
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFSOCK, "по пути лежит не сокет")

        let started = Date()
        XCTAssertThrowsError(try MCPConnector.connect(path: path, queue: .global())) { error in
            XCTAssertEqual(error as? MCPConnector.ConnectError, .appNotRunning)
        }
        // И отказ обязан прийти быстро: агент ждёт ответа, а не выяснения.
        XCTAssertLessThan(Date().timeIntervalSince(started), MCPConnector.connectTimeout + 2)
    }

    /// Сокет, привязанный к пути и брошенный: файл остаётся, слушателя нет.
    private func makeAbandonedSocketFile(at path: String) throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        try XCTSkipIf(descriptor < 0, "не удалось создать сокет")
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { source in
                strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, 103)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, size) }
        }
        try XCTSkipIf(bound != 0, "не удалось привязать сокет")
        close(descriptor)
    }

    // MARK: - Вспомогательный исполняемый файл

    func testHelperBinaryCarriesARequestToTheAppAndBack() throws {
        let helper = try XCTUnwrap(helperBinaryURL(), "исполняемый файл не собран")
        let path = try makeSocketPath()
        let listener = try startServer(at: path)
        defer { listener.stop() }

        let process = Process()
        process.executableURL = helper
        process.environment = ["CHROMADB_MCP_SOCKET": path]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        let line = #"{"jsonrpc":"2.0","id":"probe","method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"# + "\n"
        input.fileHandleForWriting.write(Data(line.utf8))

        let answered = expectation(description: "ответ на стандартном выводе")
        let collected = UncheckedBox(Data())
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            collected.value.append(chunk)
            if collected.value.contains(UInt8(ascii: "\n")) { answered.fulfill() }
        }
        wait(for: [answered], timeout: 10)
        output.fileHandleForReading.readabilityHandler = nil

        // Закрытый стандартный ввод — единственный переносимый сигнал
        // завершения, и сервер обязан на него выйти.
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "выход по концу файла на stdin должен быть штатным")

        var framer = LineFramer()
        let messages = try framer.consume(collected.value)
        XCTAssertEqual(messages.count, 1, "в stdout не должно быть ничего, кроме сообщений протокола")
        let value = try JSONDecoder().decode(JSONValue.self, from: messages[0])
        XCTAssertEqual(value["id"], .string("probe"), "идентификатор обязан вернуться строкой")
        XCTAssertEqual(value["result"]?["supportedVersions"], .array(MCPProtocol.supportedVersions.map(JSONValue.string)))
    }

    func testHelperAnswersWhenTheAppIsNotRunning() throws {
        let helper = try XCTUnwrap(helperBinaryURL(), "исполняемый файл не собран")
        let path = try makeSocketPath()   // слушателя не поднимаем

        let process = Process()
        process.executableURL = helper
        process.environment = ["CHROMADB_MCP_SOCKET": path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()

        // Запрос и уведомление подряд: на первый ответ обязателен,
        // на второе — запрещён.
        let lines = #"{"jsonrpc":"2.0","id":5,"method":"tools/list","params":{}}"# + "\n"
            + #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}"# + "\n"
        input.fileHandleForWriting.write(Data(lines.utf8))
        input.fileHandleForWriting.closeFile()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var framer = LineFramer()
        let messages = try framer.consume(data)
        XCTAssertEqual(messages.count, 1, "на уведомление отвечать запрещено")
        let value = try JSONDecoder().decode(JSONValue.self, from: messages[0])
        XCTAssertEqual(value["id"], .int(5))
        let message = try XCTUnwrap(value["error"]?["message"]?.stringValue)
        XCTAssertTrue(message.contains("не запущено"), "причина должна быть названа: \(message)")
    }

    /// Собранный `chromadb-mcp` лежит рядом с бандлом тестов.
    private func helperBinaryURL() -> URL? {
        let directory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let candidate = directory.appendingPathComponent("chromadb-mcp")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }
}

/// Ящик для значения, которое заполняется в обработчике и читается в тесте.
private final class UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
