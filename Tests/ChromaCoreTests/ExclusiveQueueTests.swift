import XCTest
@testable import ChromaCore

/// Задача, гасящая сервер, работает в одиночку.
///
/// Из живого случая: человек нажал «Переизвлечь и переэмбедить» подряд
/// у нескольких источников. Каждое нажатие начинается с бэкапа, бэкап гасит
/// локальный сервер, а вместе с подключением снимаются все его задачи —
/// второе нажатие убивало первое, и из шести источников дожил один.
final class ExclusiveQueueTests: XCTestCase {
    func testTheExclusiveGroupIsSerialAndWantsAnEmptyQueue() {
        XCTAssertTrue(ResourceGroup.exclusive.isSerial)
        XCTAssertTrue(ResourceGroup.exclusive.needsEmptyQueue)
        // Остальным группам одиночество не нужно: иначе поиск встал бы
        // в очередь за синхронизацией.
        XCTAssertFalse(ResourceGroup.database.needsEmptyQueue)
        XCTAssertFalse(ResourceGroup.filesystem.needsEmptyQueue)
        XCTAssertFalse(ResourceGroup.lmStudio.needsEmptyQueue)
    }

    /// Бэкап ждёт, пока работа в базе кончится, а не обрывает её.
    func testABackupWaitsForRunningWork() async throws {
        let queue = TaskQueue()
        let started = expectation(description: "работа началась")
        let release = expectation(description: "работе дали кончиться")

        let work = Task {
            try await queue.run(QueueTicket(
                title: "Синхронизация", priority: .background, group: .database, connectionID: nil
            )) { _ in
                started.fulfill()
                await self.fulfillment(of: [release], timeout: 5)
                return true
            }
        }
        await fulfillment(of: [started], timeout: 5)

        let backup = Task {
            try await queue.run(QueueTicket(
                title: "Резервная копия базы", priority: .interactive, group: .exclusive, connectionID: nil
            )) { _ in true }
        }

        // Пока работа идёт, бэкап стоять обязан.
        try await Task.sleep(nanoseconds: 200_000_000)
        let running = await queue.isRunning(group: .exclusive)
        XCTAssertFalse(running, "бэкап не имеет права начаться поверх чужой работы")

        release.fulfill()
        _ = try await work.value
        _ = try await backup.value
    }

    /// И наоборот: пока копируется база, никто не стартует.
    func testNothingStartsWhileTheBackupRuns() async throws {
        let queue = TaskQueue()
        let started = expectation(description: "бэкап начался")
        let release = expectation(description: "бэкапу дали кончиться")

        let backup = Task {
            try await queue.run(QueueTicket(
                title: "Резервная копия базы", priority: .interactive, group: .exclusive, connectionID: nil
            )) { _ in
                started.fulfill()
                await self.fulfillment(of: [release], timeout: 5)
                return true
            }
        }
        await fulfillment(of: [started], timeout: 5)

        let other = Task {
            try await queue.run(QueueTicket(
                title: "Синхронизация", priority: .interactive, group: .database, connectionID: nil
            )) { _ in true }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let running = await queue.isRunning(group: .database)
        XCTAssertFalse(running, "во время копирования папки базы работать в ней нельзя")

        release.fulfill()
        _ = try await backup.value
        _ = try await other.value
    }
}
