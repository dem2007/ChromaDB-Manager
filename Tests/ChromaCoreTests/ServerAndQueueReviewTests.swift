import XCTest
@testable import ChromaCore

/// Разбор ревью очереди задач и запуска сервера: кто вправе начаться, пока
/// задача отошла в сторону, и свободен ли порт сразу после остановки.
final class ServerAndQueueReviewTests: XCTestCase {
    /// Задача, уступившая место, — посреди своей работы и с подключением на
    /// руках. Бэкап, гасящий сервер, не вправе начаться в этот промежуток:
    /// очередь в этот миг выглядит пустой, но работа в базе не кончилась.
    func testABackupDoesNotStartWhileATaskStandsAside() async throws {
        let queue = TaskQueue()
        let connection = UUID()
        let reembedStarted = expectation(description: "пересчёт начался")
        let agentStarted = expectation(description: "агент вошёл")
        let releaseAgent = expectation(description: "агенту дали кончиться")
        let releaseReembed = expectation(description: "пересчёту дали кончиться")

        let reembed = Task {
            try await queue.run(QueueTicket(
                title: "Пересчёт", priority: .manual, group: .lmStudio, connectionID: connection
            )) { context in
                reembedStarted.fulfill()
                await self.fulfillment(of: [releaseReembed], timeout: 5)
                await context.yieldToHigherPriority()
                return true
            }
        }
        await fulfillment(of: [reembedStarted], timeout: 5)

        let backupStarted = expectation(description: "бэкап начался посреди пересчёта")
        backupStarted.isInverted = true
        let backup = Task {
            try await queue.run(QueueTicket(
                title: "Резервная копия", priority: .interactive, group: .exclusive
            )) { _ in
                backupStarted.fulfill()
                return true
            }
        }
        let agent = Task {
            try await queue.run(QueueTicket(
                title: "Агент", priority: .agent, group: .lmStudio, connectionID: connection
            )) { _ in
                agentStarted.fulfill()
                await self.fulfillment(of: [releaseAgent], timeout: 5)
                return true
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        releaseReembed.fulfill()
        await fulfillment(of: [agentStarted], timeout: 5)

        // Пересчёт стоит в стороне, агент работает. Бэкапа быть не должно.
        await fulfillment(of: [backupStarted], timeout: 0.3)

        releaseAgent.fulfill()
        _ = try await agent.value
        _ = try await reembed.value
        _ = try await backup.value
    }

    /// Сервер останавливают — задача, отошедшая в сторону, держит клиента
    /// этого сервера и отменяется так же, как работающая.
    func testPausingAServerCancelsATaskStandingAside() async throws {
        let queue = TaskQueue()
        let connection = UUID()
        let started = expectation(description: "пересчёт начался")
        let agentStarted = expectation(description: "агент вошёл")
        let releaseAgent = expectation(description: "агенту дали кончиться")
        let goAside = expectation(description: "пересчёт отходит")
        let cancelled = expectation(description: "пересчёт отменён")

        let reembed = Task {
            try await queue.run(QueueTicket(
                title: "Пересчёт", priority: .manual, group: .lmStudio, connectionID: connection
            )) { context in
                await queue.setCanceller(for: context.id) { cancelled.fulfill() }
                started.fulfill()
                await self.fulfillment(of: [goAside], timeout: 5)
                await context.yieldToHigherPriority()
                return true
            }
        }
        await fulfillment(of: [started], timeout: 5)
        let agent = Task {
            try await queue.run(QueueTicket(
                title: "Агент", priority: .agent, group: .lmStudio, connectionID: connection
            )) { _ in
                agentStarted.fulfill()
                await self.fulfillment(of: [releaseAgent], timeout: 5)
                return true
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        goAside.fulfill()
        await fulfillment(of: [agentStarted], timeout: 5)

        _ = await queue.pauseTasks(connectionID: connection)
        await fulfillment(of: [cancelled], timeout: 2)
        releaseAgent.fulfill()
        _ = try? await agent.value
        _ = try? await reembed.value
    }

    /// Порт, который сервер только что закрыл, занят лишь «хвостами»
    /// соединений (FIN_WAIT, TIME_WAIT): сам сервер на нём поднимется,
    /// и проверка не должна называть его занятым. Живой слушатель — занят.
    func testAPortWithOnlyClosingConnectionsIsAvailable() throws {
        let port = PortUtility.freePort()
        let listener = try LoopbackSocket.listen(port: port)
        let client = try LoopbackSocket.connect(port: port)
        let accepted = try listener.accept()

        XCTAssertFalse(PortUtility.isAvailable(host: "127.0.0.1", port: port), "живой слушатель — порт занят")

        // Сервер закрывает первым — как `chroma` на остановке.
        accepted.close()
        listener.close()
        defer { client.close() }
        usleep(200_000)
        XCTAssertTrue(PortUtility.isAvailable(host: "127.0.0.1", port: port),
                      "после остановки сервера порт держат лишь закрывающиеся соединения")
    }
}

/// Сокеты на POSIX — ровно столько, сколько нужно тесту порта.
private struct LoopbackSocket {
    let fd: Int32

    static func address(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    static func listen(port: Int) throws -> LoopbackSocket {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = address(port: port)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Foundation.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Foundation.listen(fd, 4) == 0 else { throw POSIXError(.EADDRINUSE) }
        return LoopbackSocket(fd: fd)
    }

    static func connect(port: Int) throws -> LoopbackSocket {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = address(port: port)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Foundation.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw POSIXError(.ECONNREFUSED) }
        return LoopbackSocket(fd: fd)
    }

    func accept() throws -> LoopbackSocket {
        let accepted = Foundation.accept(fd, nil, nil)
        guard accepted >= 0 else { throw POSIXError(.EBADF) }
        return LoopbackSocket(fd: accepted)
    }

    func close() { _ = Foundation.close(fd) }
}
