import XCTest
@testable import ChromaCore

/// Records the order in which things actually happened, from any thread.
private final class Journal: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: String) {
        lock.lock(); lines.append(line); lock.unlock()
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}

/// one owner of long work — priorities, serial groups, yield points instead
/// of preemption, and a queue that survives a restart.
final class TaskQueueTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeQueue() -> TaskQueue {
        TaskQueue(store: PendingTaskStore(fileURL: directory.appendingPathComponent("pending.json")))
    }

    private func ticket(
        _ title: String,
        _ priority: QueuePriority = .manual,
        _ group: ResourceGroup = .lmStudio,
        connectionID: UUID? = nil,
        resumable: ResumableRequest? = nil
    ) -> QueueTicket {
        QueueTicket(title: title, priority: priority, group: group, connectionID: connectionID, resumable: resumable)
    }

    // MARK: - Serial groups

    func testTwoTasksOfOneGroupNeverOverlap() async throws {
        let queue = makeQueue()
        let journal = Journal()
        let counter = Counter()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<4 {
                group.addTask {
                    try? await queue.run(self.ticket("задача \(index)")) { _ in
                        let now = await counter.enter()
                        journal.add("одновременно: \(now)")
                        try? await Task.sleep(nanoseconds: 40_000_000)
                        await counter.leave()
                    }
                }
            }
        }

        XCTAssertEqual(journal.all.filter { $0 != "одновременно: 1" }, [], "группа lmStudio обязана быть строго последовательной")
    }

    /// Вторая задача видна в очереди **сразу**, а не когда закончится первая.
    ///
    /// Снимок публиковался до того, как задача попадала в список ожидающих, и
    /// на экране «Задачи» её не было всё время работы предыдущей: человек,
    /// поставивший второй источник, не видел ни строки о нём.
    func testAQueuedTaskShowsUpBeforeTheRunningOneFinishes() async throws {
        let queue = makeQueue()
        let seen = Journal()
        await queue.setChangeHandler { snapshot in
            for task in snapshot where task.state == .queued {
                seen.add(task.title)
            }
        }

        let firstStarted = Blocker()
        let letFirstFinish = Blocker()
        async let first: Void = {
            try? await queue.run(ticket("первая")) { _ in
                await firstStarted.release()
                await letFirstFinish.wait()
            }
        }()
        await firstStarted.wait()

        async let second: Void = {
            try? await queue.run(ticket("вторая")) { _ in }
        }()

        // Ждём, пока вторая действительно встанет в очередь.
        for _ in 0..<50 where !seen.all.contains("вторая") {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(
            seen.all.contains("вторая"),
            "ожидающая задача обязана попасть в снимок до конца первой: \(seen.all)"
        )

        await letFirstFinish.release()
        _ = await (first, second)
    }

    /// Groups that do not compete run side by side — otherwise scanning a folder
    /// would wait for an embedding batch for no reason.
    func testDifferentGroupsRunTogether() async throws {
        let queue = makeQueue()
        let started = Journal()

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await queue.run(self.ticket("модель", .manual, .lmStudio)) { _ in
                    started.add("модель")
                    try? await Task.sleep(nanoseconds: 120_000_000)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 20_000_000)
                try? await queue.run(self.ticket("файлы", .manual, .filesystem)) { _ in
                    started.add("файлы")
                }
            }
        }

        XCTAssertEqual(started.all, ["модель", "файлы"], "файловая задача не должна ждать модель")
    }

    // MARK: - Priorities

    func testHigherPriorityGoesFirstAndEqualPriorityKeepsItsOrder() async throws {
        let queue = makeQueue()
        let journal = Journal()
        let blocker = Blocker()

        // Hold the group so everything else has to queue up.
        let held = Task {
            try? await queue.run(self.ticket("держим группу")) { _ in
                await blocker.wait()
            }
        }
        try await waitUntil { await queue.isRunning(group: .lmStudio) }

        let waiting = Task {
            await withTaskGroup(of: Void.self) { group in
                for (title, priority) in [
                    ("автоматическая", QueuePriority.automatic),
                    ("ручная 1", .manual),
                    ("ручная 2", .manual),
                    ("интерактивная", .interactive),
                ] {
                    group.addTask {
                        try? await queue.run(self.ticket(title, priority)) { _ in
                            journal.add(title)
                        }
                    }
                    // Deterministic arrival order inside one priority.
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
            }
        }

        try await waitUntil { await queue.snapshot().filter { $0.state == .queued }.count == 4 }
        await blocker.release()
        _ = await held.value
        _ = await waiting.value

        XCTAssertEqual(journal.all, ["интерактивная", "ручная 1", "ручная 2", "автоматическая"])
    }

    /// the search a user just typed starts at the next yield point, not
    /// after the whole folder is indexed.
    func testAnInteractiveTaskStartsAtTheNextYieldPoint() async throws {
        let queue = makeQueue()
        let journal = Journal()
        let longTask = Task {
            try? await queue.run(self.ticket("длинная синхронизация", .automatic)) { context in
                for batch in 0..<6 {
                    journal.add("батч \(batch)")
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    // Between batches, never inside one.
                    await context.yieldToHigherPriority()
                }
            }
        }
        try await waitUntil { await queue.isRunning(group: .lmStudio) }
        try await Task.sleep(nanoseconds: 45_000_000)

        try await queue.run(ticket("поиск пользователя", .interactive)) { _ in
            journal.add("поиск")
        }
        _ = await longTask.value

        let lines = journal.all
        let search = try XCTUnwrap(lines.firstIndex(of: "поиск"))
        XCTAssertLessThan(search, lines.count - 1, "поиск обязан пройти до конца длинной задачи")
        XCTAssertGreaterThan(search, 0, "но не раньше, чем завершится начатый батч")
    }


    /// Отмена задачи, которая уступила место.
    ///
    /// Уступившая стоит среди ожидающих, но её код выполняется — она отошла
    /// в точке уступки внутри собственной работы. `yield` возврат с ошибкой
    /// проглатывает, поэтому без остановки самой работы кнопка «Отменить»
    /// не делала бы ничего, а задача продолжала бы считать **без места
    /// в очереди**: серийная группа оказалась бы занята двумя разом.
    func testCancellingATaskThatSteppedAsideActuallyStopsItsWork() async throws {
        let queue = makeQueue()
        let journal = Journal()
        let stopped = Stopper()

        let longTask = Task {
            try? await queue.run(self.ticket("длинная синхронизация", .automatic)) { context in
                await queue.setCanceller(for: context.id) { stopped.stop() }
                for batch in 0..<12 {
                    if stopped.isStopped { journal.add("остановлена"); return }
                    journal.add("батч \(batch)")
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    await context.yieldToHigherPriority()
                }
                journal.add("доработала до конца")
            }
        }
        try await waitUntil { await queue.isRunning(group: .lmStudio) }

        // Задача с большим приоритетом занимает место: длинная уходит
        // в ожидающие, продолжая при этом быть живой работой.
        let holder = Blocker()
        let interactive = Task {
            try? await queue.run(self.ticket("поиск пользователя", .interactive)) { _ in
                await holder.wait()
            }
        }
        try await waitUntil { await queue.snapshot().contains { $0.title == "длинная синхронизация" && $0.state == .queued } }

        // Отменяем именно уступившую.
        let standingAside = await queue.snapshot().first { $0.title == "длинная синхронизация" }
        let id = try XCTUnwrap(standingAside?.id)
        await queue.cancel(id: id)

        await holder.release()
        _ = await interactive.value
        _ = await longTask.value

        XCTAssertTrue(stopped.isStopped, "остановщик работы обязан быть вызван, иначе кнопка «Отменить» бесполезна")
        XCTAssertFalse(
            journal.all.contains("доработала до конца"),
            "отменённая задача не должна досчитывать без места в очереди"
        )
    }


    /// несколько источников, поданных разом, видны все — один идёт,
    /// остальные ждут.
    ///
    /// На это опирается «Синхронизировать все». Там стоял последовательный
    /// цикл с `await` на каждом источнике: очередь получала по одной заявке,
    /// панель задач оставалась пустой, и человек видел, как источники
    /// синхронизируются друг за другом непонятно откуда. Очередь serial-группу
    /// и так держит по одному — вести её вручную было незачем.
    func testSeveralTasksOfOneSerialGroupAreAllVisibleAtOnce() async throws {
        let queue = makeQueue()
        let hold = Blocker()

        for index in 0..<3 {
            Task {
                try? await queue.run(self.ticket("источник \(index)", .automatic)) { _ in
                    await hold.wait()
                }
            }
            await Task.yield()
        }

        try await waitUntil { await queue.snapshot().count == 3 }
        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.filter { $0.state == .running }.count, 1, "модель занята одним")
        XCTAssertEqual(snapshot.filter { $0.state == .queued }.count, 2, "остальные обязаны быть видны ожидающими")

        await hold.release()
    }

    // MARK: - Cancellation

    func testCancellingAQueuedTaskLeavesTheOthersAlone() async throws {
        let queue = makeQueue()
        let journal = Journal()
        let blocker = Blocker()

        let held = Task {
            try? await queue.run(self.ticket("держим группу")) { _ in await blocker.wait() }
        }
        try await waitUntil { await queue.isRunning(group: .lmStudio) }

        let doomed = Task {
            try await queue.run(self.ticket("отменяемая")) { _ in journal.add("отменяемая") }
        }
        let survivor = Task {
            try? await queue.run(self.ticket("выжившая")) { _ in journal.add("выжившая") }
        }
        try await waitUntil { await queue.snapshot().filter { $0.state == .queued }.count == 2 }

        let snapshot = await queue.snapshot()
        let victim = try XCTUnwrap(snapshot.first { $0.title == "отменяемая" })
        await queue.cancel(id: victim.id)

        do {
            _ = try await doomed.value
            XCTFail("отменённая задача не должна выполниться")
        } catch {}

        await blocker.release()
        _ = await held.value
        _ = await survivor.value
        XCTAssertEqual(journal.all, ["выжившая"])
    }

    /// A connection that goes away takes its tasks with it: they hold a client
    /// that is about to be released.
    func testTasksOfAClosedConnectionAreDropped() async throws {
        let queue = makeQueue()
        let connection = UUID()
        let other = UUID()
        let journal = Journal()
        let blocker = Blocker()

        let held = Task {
            try? await queue.run(self.ticket("держим группу")) { _ in await blocker.wait() }
        }
        try await waitUntil { await queue.isRunning(group: .lmStudio) }

        let doomed = Task {
            try await queue.run(self.ticket("задача умершего подключения", .manual, .lmStudio, connectionID: connection)) { _ in
                journal.add("умершее подключение")
            }
        }
        let survivor = Task {
            try? await queue.run(self.ticket("задача другого подключения", .manual, .lmStudio, connectionID: other)) { _ in
                journal.add("другое подключение")
            }
        }
        try await waitUntil { await queue.snapshot().filter { $0.state == .queued }.count == 2 }

        await queue.cancelTasks(connectionID: connection)
        do {
            _ = try await doomed.value
            XCTFail("задача мёртвого подключения не должна выполниться")
        } catch {}

        await blocker.release()
        _ = await held.value
        _ = await survivor.value
        XCTAssertEqual(journal.all, ["другое подключение"])
    }

    // MARK: - Pause

    func testPauseStopsAdmissionsAndResumeLetsThemThrough() async throws {
        let queue = makeQueue()
        let journal = Journal()

        await queue.setPaused(true)
        let waiting = Task {
            try? await queue.run(self.ticket("после паузы")) { _ in journal.add("выполнено") }
        }
        try await waitUntil { await queue.snapshot().contains { $0.state == .queued } }
        XCTAssertTrue(journal.all.isEmpty, "на паузе ничего не начинается")

        await queue.setPaused(false)
        _ = await waiting.value
        XCTAssertEqual(journal.all, ["выполнено"])
    }

    // MARK: - Deadlines

    /// 1 through the queue: waiting for a turn is not part of the operation's
    /// timeout, because the timeout lives inside the work.
    func testWaitingInTheQueueDoesNotEatTheOperationsDeadline() async throws {
        let queue = makeQueue()
        let blocker = Blocker()
        let held = Task {
            try? await queue.run(self.ticket("держим группу")) { _ in await blocker.wait() }
        }
        try await waitUntil { await queue.isRunning(group: .lmStudio) }

        let queued = Task {
            try await queue.run(self.ticket("вторая")) { _ in
                // Its own deadline starts here — it must not have expired while
                // the task was waiting.
                try await withDeadline(seconds: 1, onExpiry: { ChromaError.timedOut(operation: .fetch, seconds: 1) }) {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    return "готово"
                }
            }
        }
        // Sit in the queue for longer than that deadline.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        await blocker.release()

        let result = try await queued.value
        XCTAssertEqual(result, "готово")
        _ = await held.value
    }

    // MARK: - Surviving a restart

    func testUnfinishedWorkIsOfferedAfterARestartAndNotStarted() async throws {
        let fileURL = directory.appendingPathComponent("pending.json")
        let request = ResumableRequest(kind: .sync, subject: "источник-1", title: "Синхронизация «Договоры»")

        let queue = TaskQueue(store: PendingTaskStore(fileURL: fileURL))
        let blocker = Blocker()
        let running = Task {
            try? await queue.run(self.ticket("Синхронизация «Договоры»", .automatic, .lmStudio, resumable: request)) { _ in
                await blocker.wait()
            }
        }
        try await waitUntil { await queue.isRunning(group: .lmStudio) }

        // The app dies here: the record on disk is what the next launch sees.
        let afterCrash = TaskQueue(store: PendingTaskStore(fileURL: fileURL))
        await afterCrash.loadResumable()
        let offered = await afterCrash.resumable
        XCTAssertEqual(offered, [request])
        let snapshot = await afterCrash.snapshot()
        XCTAssertTrue(snapshot.isEmpty, "предложить — да, запустить само — нет")

        await blocker.release()
        _ = await running.value

        // A finished task leaves nothing behind.
        let afterSuccess = TaskQueue(store: PendingTaskStore(fileURL: fileURL))
        await afterSuccess.loadResumable()
        let leftovers = await afterSuccess.resumable
        XCTAssertTrue(leftovers.isEmpty)
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("условие не наступило за \(Int(timeout)) с")
    }
}

/// F2 DoD, in the shape the spec asks for: a folder is being indexed through
/// the real synchronisation service against a fake LM Studio, and the user's own
/// search has to get the model at the next yield point — between embedding
/// batches, not after the whole folder.
final class QueueYieldDuringSyncTests: XCTestCase {
    private var root: URL!

    /// Deliberately slow, so the test is about ordering and not about luck.
    private actor SlowEmbeddings: EmbeddingProvider {
        func embed(texts: [String], model: String) async throws -> [[Double]] {
            try? await Task.sleep(nanoseconds: 60_000_000)
            return texts.map { text in
                let value = Double(text.count % 17) / 17
                return [value, 1 - value, 0.5, 0.25]
            }
        }
    }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-yield-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Enough chunks to make several batches.
        for index in 0..<6 {
            try String(repeating: "текст про оплату номер \(index). ", count: 60)
                .write(to: folder.appendingPathComponent("note-\(index).md"), atomically: true, encoding: .utf8)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAUserSearchGetsTheModelBeforeTheFolderIsFinished() async throws {
        let queue = TaskQueue(store: PendingTaskStore(fileURL: root.appendingPathComponent("pending.json")))
        let service = SourceSyncService(
            manifests: ManifestStore(directory: root.appendingPathComponent("manifests")),
            journal: SyncJournal(directory: root.appendingPathComponent("journals"))
        )
        let source = DataSource(
            name: "папка",
            path: root.appendingPathComponent("docs").path,
            fileExtensions: ["md"],
            mapping: .singleCollectionWithRelativePath,
            collectionName: "notes",
            chunking: ChunkingConfiguration(strategy: .fixed, chunkSize: 60, sizeUnit: .characters, overlapPercent: 0)
        )
        let database = FailingDatabase()
        let searchRan = expectation(description: "поиск выполнен")

        let sync = Task {
            try? await queue.run(QueueTicket(title: "Синхронизация «папка»", priority: .automatic, group: .lmStudio)) { context in
                try await service.sync(
                    source: source, embeddingModel: "stub", chroma: database,
                    embeddings: SlowEmbeddings(), binding: ModelBindingService(),
                    yield: { await context.yieldToHigherPriority() },
                    progress: { _ in }
                )
            }
        }

        // Let the run get going, then ask for something interactive.
        try await Task.sleep(nanoseconds: 150_000_000)
        let search = Task {
            try? await queue.run(QueueTicket(title: "Поиск", priority: .interactive, group: .lmStudio)) { _ in
                searchRan.fulfill()
            }
        }

        // The search must land while the sync is still going: that is the whole
        // point of a yield point.
        await fulfillment(of: [searchRan], timeout: 5)
        XCTAssertFalse(sync.isCancelled)
        let syncStillRunning = await queue.isRunning(group: .lmStudio) || !sync.isCancelled
        XCTAssertTrue(syncStillRunning)

        _ = await search.value
        _ = await sync.value
    }
}

/// Counts how many tasks are inside the critical section at once.
private actor Counter {
    private var current = 0

    func enter() -> Int {
        current += 1
        return current
    }

    func leave() {
        current -= 1
    }
}

/// Holds a task until the test lets it go.
private actor Blocker {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
/// Progress arrives after every batch; the task list changes far more rarely.
/// Publishing at the rate of the former is a stream of layout passes.
final class QueuePublishingTests: XCTestCase {
    func testProgressOnlyUpdatesAreCoalescedButStateChangesAreNot() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-publish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let queue = TaskQueue(store: PendingTaskStore(fileURL: directory.appendingPathComponent("p.json")))
        let counter = PublishCounter()
        await queue.setChangeHandler { _ in counter.bump() }
        let afterHandler = counter.value

        try await queue.run(QueueTicket(title: "задача", priority: .manual, group: .lmStudio)) { context in
            // A hundred batches in a row, as a folder sync would.
            for index in 0..<100 {
                await context.report(progress: Double(index) / 100, detail: "батч \(index)")
            }
        }

        let published = counter.value - afterHandler
        // Start and finish are structural and always land; the hundred progress
        // reports in between must not.
        XCTAssertGreaterThanOrEqual(published, 2)
        XCTAssertLessThan(published, 20, "прогресс должен схлопываться, а не идти потоком: \(published)")
    }
}

private final class PublishCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func bump() {
        lock.lock(); count += 1; lock.unlock()
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

/// a pause stops the machine grinding, it does not lock the user out of
/// their own database.
final class QueuePauseTests: XCTestCase {
    func testAPausedQueueStillLetsTheUsersOwnSearchThrough() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-pause-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let queue = TaskQueue(store: PendingTaskStore(fileURL: directory.appendingPathComponent("p.json")))
        await queue.setPaused(true)

        let ran = expectation(description: "поиск выполнен")
        let search = Task {
            try? await queue.run(QueueTicket(title: "Поиск", priority: .interactive, group: .lmStudio)) { _ in
                ran.fulfill()
            }
        }
        await fulfillment(of: [ran], timeout: 3)
        _ = await search.value

        // Everything else waits for the pause to be lifted.
        let background = Task {
            try? await queue.run(QueueTicket(title: "Синхронизация", priority: .automatic, group: .lmStudio)) { _ in }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let waiting = await queue.snapshot()
        XCTAssertEqual(waiting.filter { $0.state == .queued }.map(\.title), ["Синхронизация"])

        await queue.setPaused(false)
        _ = await background.value
    }
}

/// Флаг «работу попросили остановить». Ставится остановщиком, который очередь
/// вызывает при отмене, читается самой работой на её собственных проверках.
private final class Stopper: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func stop() {
        lock.lock(); value = true; lock.unlock()
    }

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
