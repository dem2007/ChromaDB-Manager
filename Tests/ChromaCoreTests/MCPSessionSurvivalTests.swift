import XCTest
@testable import ChromaCore

/// Живучесть сессий MCP.
///
/// Проверяется на настоящем сокете, а не на выдумке: слушатель, подключение
/// и переданные байты — то же, чем пользуется мост агента.
final class MCPSessionSurvivalTests: XCTestCase {
    private var path: String!
    private let queue = DispatchQueue(label: "test.mcp.session")

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "cdbm-mcp-\(UUID().uuidString).sock"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Вторая копия приложения не отбирает адрес у первой.
    ///
    /// До правки второй слушатель молча удалял чужой файл сокета и вставал
    /// на его место: мосты, поднятые раньше, оставались у первой копии,
    /// а новые уходили ко второй — и «кто ответит на вызов» зависело от того,
    /// когда его подняли.
    func testASecondListenerRefusesInsteadOfStealingTheSocket() throws {
        let first = MCPListener(path: path)
        first.onConnection = { _ in }
        try first.start()
        defer { first.stop() }

        let second = MCPListener(path: path)
        XCTAssertThrowsError(try second.start()) { error in
            XCTAssertEqual(error as? MCPListener.ListenError, .alreadyRunning)
        }
        // И первый по-прежнему на месте: адрес не тронут.
        let channel = try MCPConnector.connect(path: path, queue: queue)
        channel.close()
    }

    /// Файл сокета от упавшего процесса не мешает: он мёртв, и его убирают.
    ///
    /// Сокет создаётся руками и тут же закрывается — ровно то, что остаётся
    /// на диске после падения приложения: файл есть, отвечать некому.
    func testAStaleSocketFileIsReplaced() throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { source in
                strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, 104)
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0, "не удалось создать файл сокета для пробы")
        close(descriptor)

        var status = stat()
        XCTAssertEqual(lstat(path, &status), 0)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFSOCK, "проба обязана оставить именно сокет")

        let listener = MCPListener(path: path)
        listener.onConnection = { _ in }
        XCTAssertNoThrow(try listener.start(), "мёртвый сокет не должен мешать запуску")
        listener.stop()
    }

    /// Отправка в закрытый канал не проходит молча: об этом сообщают.
    ///
    /// Ради этого мост и умеет отвечать за приложение: сообщение, ушедшее
    /// в щель между «приложение закрылось» и «о закрытии сообщили», раньше
    /// пропадало, и агент ждал своего таймаута вместо внятного отказа.
    func testSendingIntoAClosedChannelReportsFailure() throws {
        let listener = MCPListener(path: path)
        listener.onConnection = { _ in }
        try listener.start()

        let channel = try MCPConnector.connect(path: path, queue: queue)
        // Приложение закрылось: слушателя больше нет, канал обрывается.
        listener.stop()
        channel.close()

        let failed = expectation(description: "об ошибке отправки сообщено")
        channel.send(Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)) { _ in
            failed.fulfill()
        }
        wait(for: [failed], timeout: 5)
    }
}
