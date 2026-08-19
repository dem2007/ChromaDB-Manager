import XCTest
@testable import ChromaCore

/// Плановая остановка сервера не должна убивать очередь.
///
/// Живой случай: человек нажал «Переизвлечь и переэмбедить» у четырёх
/// источников. Каждое нажатие начинается с копии базы, копия гасит локальный
/// сервер, а гашение снимало **все** задачи подключения — включая те, что
/// ещё стояли в очереди и никакого клиента не держали. В очереди оставались
/// одни «Резервная копия базы», а переизвлечения не случалось вовсе.
///
/// Разница, которую эти тесты закрепляют: работающая задача уходит вместе
/// с сервером (клиент у неё на руках), а ожидающая — остаётся и получает
/// новое подключение, когда сервер вернётся.
final class ServerRestartQueueTests: XCTestCase {
    private func ticket(
        _ title: String,
        _ group: ResourceGroup = .lmStudio,
        connectionID: UUID? = nil
    ) -> QueueTicket {
        QueueTicket(title: title, priority: .manual, group: group, connectionID: connectionID)
    }

    /// Главный тест пункта: копия базы больше не съедает работу, ради которой
    /// её и снимали.
    func testWaitingWorkSurvivesAPlannedStop() async throws {
        let queue = TaskQueue()
        let connection = UUID()
        let backupStarted = expectation(description: "копия началась")
        let letBackupFinish = expectation(description: "копии дали кончиться")
        let syncDone = expectation(description: "синхронизация выполнилась")

        // Копия базы — та самая задача «вся база целиком», что гасит сервер.
        let backup = Task {
            try await queue.run(ticket("Резервная копия базы", .exclusive)) { _ in
                backupStarted.fulfill()
                await self.fulfillment(of: [letBackupFinish], timeout: 5)
                return true
            }
        }
        await fulfillment(of: [backupStarted], timeout: 5)

        // Синхронизация встала в очередь за ней — клиента у неё ещё нет.
        let sync = Task {
            try await queue.run(ticket("Синхронизация «дом»", connectionID: connection)) { _ in
                syncDone.fulfill()
                return true
            }
        }
        try await Task.sleep(nanoseconds: 150_000_000)

        // Сервер гаснет — и ожидающая задача остаётся в очереди.
        let kept = await queue.pauseTasks(connectionID: connection)
        XCTAssertEqual(kept, 1, "ожидающая задача обязана пережить остановку сервера")
        let waiting = await queue.snapshot().first { $0.title.hasPrefix("Синхронизация") }
        XCTAssertNotNil(waiting, "задача не должна пропасть из очереди")
        XCTAssertNil(waiting?.connectionID, "на время остановки она ничьё подключение не держит")

        // Сервер поднялся — подключение новое.
        let restored = UUID()
        await queue.resumeTasks(connectionID: restored)
        let rebound = await queue.snapshot().first { $0.title.hasPrefix("Синхронизация") }
        XCTAssertEqual(rebound?.connectionID, restored, "после подъёма задача принадлежит новому подключению")

        letBackupFinish.fulfill()
        _ = try await backup.value
        await fulfillment(of: [syncDone], timeout: 5)
        _ = try await sync.value
    }

    /// А работающая задача уходит вместе с сервером: клиент у неё уже на руках,
    /// и через секунду он превратится в порт, которого нет.
    func testRunningWorkGoesDownWithTheServer() async throws {
        let queue = TaskQueue()
        let connection = UUID()
        let started = expectation(description: "работа началась")
        let cancelled = expectation(description: "работу остановили")
        let letFinish = expectation(description: "работе дали выйти")

        let work = Task {
            try await queue.run(ticket("Синхронизация «дом»", .database, connectionID: connection)) { context in
                await queue.setCanceller(for: context.id) { cancelled.fulfill() }
                started.fulfill()
                await self.fulfillment(of: [letFinish], timeout: 5)
                return true
            }
        }
        await fulfillment(of: [started], timeout: 5)

        let kept = await queue.pauseTasks(connectionID: connection)
        XCTAssertEqual(kept, 0, "останавливать нечего: ожидающих нет")
        await fulfillment(of: [cancelled], timeout: 5)

        letFinish.fulfill()
        _ = try await work.value
    }

    /// Настоящее отключение — другое дело: там база будет другая или её
    /// не будет вовсе, и ожидающие задачи снимаются, как и раньше.
    func testLeavingStillClearsTheQueue() async throws {
        let queue = TaskQueue()
        let connection = UUID()
        let blockerStarted = expectation(description: "занявшая очередь задача началась")
        let letBlockerFinish = expectation(description: "ей дали кончиться")

        let blocker = Task {
            try await queue.run(ticket("Занятие очереди", .exclusive)) { _ in
                blockerStarted.fulfill()
                await self.fulfillment(of: [letBlockerFinish], timeout: 5)
                return true
            }
        }
        await fulfillment(of: [blockerStarted], timeout: 5)

        let sync = Task {
            try await queue.run(ticket("Синхронизация «дом»", connectionID: connection)) { _ in true }
        }
        try await Task.sleep(nanoseconds: 150_000_000)

        await queue.cancelTasks(connectionID: connection)
        do {
            _ = try await sync.value
            XCTFail("задача ушедшего подключения обязана сняться")
        } catch let error as QueueError {
            guard case .cancelled(let title) = error else { return XCTFail("другая ошибка: \(error)") }
            XCTAssertTrue(title.hasPrefix("Синхронизация"))
        }

        letBlockerFinish.fulfill()
        _ = try await blocker.value
    }

    /// Сервер не поднялся — ждать больше нечего, и задача узнаёт об этом
    /// ошибкой, а не вечным ожиданием.
    func testWaitingWorkIsDroppedWhenTheServerNeverComesBack() async throws {
        let queue = TaskQueue()
        let connection = UUID()
        let blockerStarted = expectation(description: "копия началась")
        let letBlockerFinish = expectation(description: "копии дали кончиться")

        let blocker = Task {
            try await queue.run(ticket("Резервная копия базы", .exclusive)) { _ in
                blockerStarted.fulfill()
                await self.fulfillment(of: [letBlockerFinish], timeout: 5)
                return true
            }
        }
        await fulfillment(of: [blockerStarted], timeout: 5)

        let sync = Task {
            try await queue.run(ticket("Синхронизация «дом»", connectionID: connection)) { _ in true }
        }
        try await Task.sleep(nanoseconds: 150_000_000)

        _ = await queue.pauseTasks(connectionID: connection)
        await queue.dropDetachedTasks()
        do {
            _ = try await sync.value
            XCTFail("без сервера задача не может ни идти, ни ждать")
        } catch let error as QueueError {
            guard case .cancelled = error else { return XCTFail("другая ошибка: \(error)") }
        }

        letBlockerFinish.fulfill()
        _ = try await blocker.value
    }
}
