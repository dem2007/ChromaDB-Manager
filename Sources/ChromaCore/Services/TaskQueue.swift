import Foundation

/// Who gets the model first. Lower raw value wins; inside one priority
/// the order is the order of arrival.
public enum QueuePriority: Int, Comparable, Codable, Sendable, CaseIterable {
    /// The user is waiting in front of the screen: search, preview, test bench.
    case interactive = 0
    /// An outside agent through MCP (stage 7).
    case agent = 1
    /// Something the user started and walked away from: manual sync, import,
    /// export, re-embedding.
    case manual = 2
    /// Started by a timer, by app launch or by a file change.
    case automatic = 3
    /// Nobody is waiting for it: the health inspector.
    case background = 4

    public static func < (lhs: QueuePriority, rhs: QueuePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var title: String {
        switch self {
        case .interactive: return String(localized: "действие пользователя")
        case .agent: return String(localized: "запрос агента")
        case .manual: return String(localized: "ручная операция")
        case .automatic: return String(localized: "автоматическая операция")
        case .background: return String(localized: "фоновая проверка")
        }
    }
}

/// What a task competes for. Tasks in a serial group run one at a time; tasks
/// in different groups run side by side.
public enum ResourceGroup: String, Codable, Sendable, CaseIterable {
    /// The local model. The scarcest thing here, and strictly serial.
    case lmStudio
    /// Scanning folders, reading manifests, extracting text without OCR.
    case filesystem
    /// Reads and writes to ChromaDB that do not touch the model.
    case database
    /// Операции, которые останавливают локальный сервер.
    ///
    /// Бэкап копирует папку базы, а для этого сервер приходится погасить —
    /// значит на это время в базе не может работать никто. Такая задача
    /// ждёт, пока очередь опустеет, и держит её, пока не кончится.
    /// Живой случай: два «Переизвлечь и переэмбедить» подряд — бэкап второго
    /// гасил сервер и снимал задачу первого, из шести источников доживал один.
    case exclusive

    public var isSerial: Bool { self == .lmStudio || self == .exclusive }

    /// Задача этой группы не терпит рядом никого.
    public var needsEmptyQueue: Bool { self == .exclusive }

    public var title: String {
        switch self {
        case .lmStudio: return String(localized: "локальная модель")
        case .filesystem: return String(localized: "файлы")
        case .database: return String(localized: "база")
        case .exclusive: return String(localized: "вся база целиком")
        }
    }
}

/// Everything the queue needs to know about a task before it runs.
public struct QueueTicket: Sendable {
    public let title: String
    public let priority: QueuePriority
    public let group: ResourceGroup
    /// Which connection the work belongs to, so it can be dropped when that
    /// connection goes away.
    public let connectionID: UUID?
    /// What to offer resuming after a restart. Absent for work that makes no
    /// sense to resume (a search nobody is waiting for any more).
    public let resumable: ResumableRequest?

    public init(
        title: String,
        priority: QueuePriority,
        group: ResourceGroup,
        connectionID: UUID? = nil,
        resumable: ResumableRequest? = nil
    ) {
        self.title = title
        self.priority = priority
        self.group = group
        self.connectionID = connectionID
        self.resumable = resumable
    }

    /// Тот же тикет, но у другого подключения.
    ///
    /// Нужен на плановой остановке сервера: ожидающая задача переживает её,
    /// но подключение после подъёма — уже другое.
    func rebound(to connectionID: UUID?) -> QueueTicket {
        QueueTicket(
            title: title, priority: priority, group: group,
            connectionID: connectionID, resumable: resumable
        )
    }
}

/// A request, not a progress point: what to start again, not where it stopped.
///
/// Half-finished indexing is already recovered by the synchronisation journal
///; a second recovery mechanism in the queue would only disagree with it.
public struct ResumableRequest: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case sync
        case importDocuments
        case reembedding
    }

    public let kind: Kind
    /// Source id, collection name — whatever the kind needs to be started again.
    public let subject: String
    public let title: String

    public init(kind: Kind, subject: String, title: String) {
        self.kind = kind
        self.subject = subject
        self.title = title
    }
}

public struct QueuedTaskInfo: Identifiable, Sendable, Equatable {
    public enum State: String, Sendable {
        case queued
        case running
    }

    public let id: UUID
    public let title: String
    public let priority: QueuePriority
    public let group: ResourceGroup
    public var connectionID: UUID?
    public let submittedAt: Date
    public var startedAt: Date?
    public var state: State
    /// 0…1 where the task can say; `nil` where it cannot.
    public var progress: Double?
    public var detail: String?

    public var waitedSeconds: TimeInterval {
        (startedAt ?? Date()).timeIntervalSince(submittedAt)
    }
}

/// Handed to the running task so it can report progress and offer to step aside.
public struct QueueContext: Sendable {
    public let id: UUID
    private let queue: TaskQueue

    init(id: UUID, queue: TaskQueue) {
        self.id = id
        self.queue = queue
    }

    public func report(progress: Double?, detail: String? = nil) async {
        await queue.report(id: id, progress: progress, detail: detail)
    }

    /// A yield point. Call it **between batches**, never inside one: the model
    /// cannot be interrupted mid-batch, and a partially written batch is exactly
    /// what A6 exists to prevent.
    ///
    /// Returns immediately when nobody more important is waiting.
    public func yieldToHigherPriority() async {
        await queue.yield(id: id)
    }
}

public enum QueueError: LocalizedError {
    case cancelled(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled(let title):
            return String(localized: "Задача «\(title)» отменена.")
        }
    }
}

/// The one owner of long work.
///
/// A single instance is right here, and it does not contradict A10: the ban on
/// singletons covers everything that depends on a *connection*, and the queue
/// does not — its tasks do, which is why it can drop the tasks of a connection
/// that went away.
///
/// The queue decides **when** a task may proceed; the caller keeps executing it.
/// That way cancellation, progress and per-operation deadlines stay where they
/// already work, and the deadline of A8.1 starts when the work starts — waiting
/// in the queue is not part of it.
public actor TaskQueue {
    private struct Waiter {
        let id: UUID
        var ticket: QueueTicket
        let submittedAt: Date
        /// Resumed when the task is admitted, or thrown into when it is cancelled.
        let continuation: CheckedContinuation<Void, Error>
        /// A task that stepped aside comes back ahead of newcomers of its own
        /// priority: it has already been waiting once.
        let isReturning: Bool
    }

    private var waiters: [Waiter] = []
    private var running: [UUID: QueuedTaskInfo] = [:]
    private var queuedInfo: [UUID: QueuedTaskInfo] = [:]
    private var cancellers: [UUID: @Sendable () -> Void] = [:]
    /// Ожидающие, отвязанные от подключения на время плановой остановки
    /// сервера. Им вернут подключение, когда сервер поднимется.
    private var detached: Set<UUID> = []
    private var isPaused = false

    private let log: LogHandler
    private let store: PendingTaskStore
    /// Requests left over from a previous run, offered but never started by
    /// themselves (8.4: «молча база не меняется»).
    private(set) public var resumable: [ResumableRequest] = []

    private var onChange: (@Sendable ([QueuedTaskInfo]) -> Void)?
    /// Progress arrives after every batch; the list of tasks changes far more
    /// rarely. Redrawing the interface at the rate of the former is a stream of
    /// layout passes nobody asked for, so progress-only changes are coalesced.
    private var lastPublishedAt = Date.distantPast
    private var lastPublishedShape: [UUID: QueuedTaskInfo.State] = [:]
    static let progressPublishInterval: TimeInterval = 0.25

    public init(
        store: PendingTaskStore = PendingTaskStore(),
        log: @escaping LogHandler = noopLogHandler
    ) {
        self.store = store
        self.log = log
    }

    /// Called once at startup: what the previous run did not finish.
    public func loadResumable() {
        resumable = store.load()
        if !resumable.isEmpty {
            log(.warning, "Задачи", "С прошлого запуска остались незавершённые задачи: \(resumable.map(\.title).joined(separator: ", ")) — запускать их автоматически приложение не будет")
        }
    }

    public func forgetResumable(_ request: ResumableRequest) {
        resumable.removeAll { $0 == request }
        store.save(resumable + pendingRequests())
    }

    public func clearResumable() {
        resumable = []
        store.save(pendingRequests())
    }

    public func setChangeHandler(_ handler: @escaping @Sendable ([QueuedTaskInfo]) -> Void) {
        onChange = handler
        publish()
    }

    // MARK: - Running work

    /// Waits for a turn, then runs `operation`.
    ///
    /// Cancelling the caller's task removes it from the queue if it has not
    /// started, and cancels the work if it has.
    public func run<T: Sendable>(
        _ ticket: QueueTicket,
        operation: @Sendable (QueueContext) async throws -> T
    ) async throws -> T {
        let id = UUID()
        try await acquire(id: id, ticket: ticket)
        defer { release(id: id) }
        return try await operation(QueueContext(id: id, queue: self))
    }

    /// Registers how to stop the work of the currently running task. Used by the
    /// panel's cancel button and when a connection goes away.
    public func setCanceller(for id: UUID, _ canceller: @escaping @Sendable () -> Void) {
        cancellers[id] = canceller
    }

    public func cancel(id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            queuedInfo.removeValue(forKey: id)
            detached.remove(id)
            waiter.continuation.resume(throwing: QueueError.cancelled(waiter.ticket.title))
            // Уступившая место задача стоит среди ожидающих, но её код
            // **выполняется** — она отошла в точке уступки внутри собственной
            // работы. `yield` возврат с ошибкой проглатывает, поэтому без
            // остановки работы кнопка «Отменить» не делала бы ничего видимого,
            // а задача продолжала бы считать уже без места в очереди — то есть
            // серийная группа (LM Studio) оказалась бы занята двумя разом,
            // ровно тем, что она и должна исключать.
            if waiter.isReturning {
                cancellers[id]?()
                log(.info, "Задачи", "Задача «\(waiter.ticket.title)» отменяется — она стояла в очереди, уступив место")
            } else {
                log(.info, "Задачи", "Задача «\(waiter.ticket.title)» снята из очереди")
            }
            publish()
            return
        }
        if let info = running[id] {
            cancellers[id]?()
            log(.info, "Задачи", "Задача «\(info.title)» отменяется")
        }
    }

    /// Сервер гасят и поднимут снова — бэкап, сжатие, восстановление копии
    ///. Отменяется только то, что **работает**: у него на руках
    /// клиент, который сейчас исчезнет.
    ///
    /// Ожидающие остаются в очереди. Клиента у них ещё нет — они берут его,
    /// когда доходит очередь, — и снимать их незачем: через несколько секунд
    /// та же база вернётся на место. Живой случай, ради которого это и
    /// сделано: четыре «Переизвлечь и переэмбедить» подряд, и копия каждого
    /// следующего снимала из очереди работу предыдущих. В очереди оставались
    /// одни копии, а переэмбединга не случалось вовсе.
    public func pauseTasks(connectionID: UUID) -> Int {
        let doomed = running.keys.filter { running[$0]?.connectionID == connectionID }
        for id in doomed {
            cancellers[id]?()
            log(.info, "Задачи", "Задача «\(running[id]?.title ?? "")» отменяется — сервер останавливается")
        }
        var kept = 0
        for index in waiters.indices where waiters[index].ticket.connectionID == connectionID {
            let id = waiters[index].id
            waiters[index].ticket = waiters[index].ticket.rebound(to: nil)
            queuedInfo[id]?.connectionID = nil
            detached.insert(id)
            kept += 1
        }
        if kept > 0 {
            log(.info, "Задачи", "Ждут возвращения сервера: \(kept.plainDigits)")
        }
        return kept
    }

    /// Сервер поднялся — ожидавшие получают новое подключение.
    public func resumeTasks(connectionID: UUID) {
        guard !detached.isEmpty else { return }
        for index in waiters.indices where detached.contains(waiters[index].id) {
            waiters[index].ticket = waiters[index].ticket.rebound(to: connectionID)
            queuedInfo[waiters[index].id]?.connectionID = connectionID
        }
        detached.removeAll()
    }

    /// Сервер не вернулся: ждать больше нечего, и молчать об этом нельзя.
    public func dropDetachedTasks() {
        guard !detached.isEmpty else { return }
        log(.warning, "Задачи", "Сервер не поднялся — снимаются задачи, ждавшие его: \(detached.count.plainDigits)")
        for id in detached { cancel(id: id) }
        detached.removeAll()
    }

    /// Everything belonging to a connection that is closing: the client
    /// these tasks hold is about to be released.
    public func cancelTasks(connectionID: UUID) {
        let doomed = (waiters.map(\.id) + Array(running.keys)).filter { id in
            (queuedInfo[id] ?? running[id])?.connectionID == connectionID
        }
        guard !doomed.isEmpty else { return }
        log(.warning, "Задачи", "Подключение закрывается — снимаются задачи: \(doomed.count.plainDigits)")
        for id in doomed { cancel(id: id) }
    }

    // MARK: - Pause

    public func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        log(.info, "Задачи", paused ? "Очередь задач на паузе — новые задачи не начинаются" : "Очередь задач продолжена")
        if !paused { promote() }
        publish()
    }

    public var paused: Bool { isPaused }

    // MARK: - State

    public func snapshot() -> [QueuedTaskInfo] {
        let active = running.values.sorted { ($0.startedAt ?? $0.submittedAt) < ($1.startedAt ?? $1.submittedAt) }
        let waiting = waiters.compactMap { queuedInfo[$0.id] }
        return active + waiting
    }

    public func isRunning(group: ResourceGroup) -> Bool {
        running.values.contains { $0.group == group }
    }

    // MARK: - Admission

    private func acquire(id: UUID, ticket: QueueTicket) async throws {
        remember(id: id, request: ticket.resumable)
        if canStart(ticket.group, priority: ticket.priority) {
            start(id: id, ticket: ticket, submittedAt: Date())
            return
        }

        let submittedAt = Date()
        queuedInfo[id] = QueuedTaskInfo(
            id: id, title: ticket.title, priority: ticket.priority, group: ticket.group,
            connectionID: ticket.connectionID, submittedAt: submittedAt,
            startedAt: nil, state: .queued, progress: nil, detail: nil
        )
        // Снимок публикуется **после** того, как задача встала в очередь
        // ожидающих, а не до. `snapshot` собирает ожидающих обходом
        // `waiters`, а в них задача попадает строкой ниже: опубликованный
        // раньше снимок её не содержал, и на экране «Задачи» она появлялась
        // только со следующим событием очереди — то есть когда предыдущая
        // работа заканчивалась. Пока шла первая синхронизация, вторая
        // выглядела потерянной.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(Waiter(
                    id: id, ticket: ticket, submittedAt: submittedAt,
                    continuation: continuation, isReturning: false
                ))
                publish()
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    private func enqueue(_ waiter: Waiter) {
        // Priority first, arrival second — and a task that stepped aside counts
        // as having arrived when it first did, not when it stepped back in.
        let insertion = waiters.firstIndex { existing in
            if existing.ticket.priority != waiter.ticket.priority {
                return existing.ticket.priority > waiter.ticket.priority
            }
            return existing.submittedAt > waiter.submittedAt
        }
        waiters.insert(waiter, at: insertion ?? waiters.endIndex)
    }

    /// Pause stops the machine grinding; it does not lock the user out of their
    /// own database. An interactive task — the search they just typed — still
    /// goes through, because a pause on background work that also freezes the
    /// search looks like a broken app.
    private func canStart(_ group: ResourceGroup, priority: QueuePriority) -> Bool {
        guard !isPaused || priority == .interactive else { return false }
        // Задача, гасящая сервер, начинается только на пустой очереди —
        // и, пока идёт, не пускает никого.
        if group.needsEmptyQueue { return running.isEmpty }
        if running.values.contains(where: { $0.group.needsEmptyQueue }) { return false }
        guard group.isSerial else { return true }
        return !isRunning(group: group)
    }

    private func start(id: UUID, ticket: QueueTicket, submittedAt: Date) {
        queuedInfo.removeValue(forKey: id)
        detached.remove(id)
        running[id] = QueuedTaskInfo(
            id: id, title: ticket.title, priority: ticket.priority, group: ticket.group,
            connectionID: ticket.connectionID, submittedAt: submittedAt,
            startedAt: Date(), state: .running, progress: nil, detail: nil
        )
        publish()
    }

    private func release(id: UUID) {
        running.removeValue(forKey: id)
        cancellers.removeValue(forKey: id)
        pendingByID.removeValue(forKey: id)
        store.save(resumable + pendingRequests())
        promote()
        publish()
    }

    /// Admits as many waiters as the free groups allow, in queue order.
    private func promote() {
        var index = 0
        while index < waiters.count {
            let waiter = waiters[index]
            guard canStart(waiter.ticket.group, priority: waiter.ticket.priority) else {
                index += 1
                continue
            }
            waiters.remove(at: index)
            start(id: waiter.id, ticket: waiter.ticket, submittedAt: waiter.submittedAt)
            waiter.continuation.resume()
        }
    }

    // MARK: - Yield points

    /// The running task offers its slot to anyone more important waiting for the
    /// same group. No preemption: this only happens where the task says it is
    /// safe.
    func yield(id: UUID) async {
        guard let info = running[id] else { return }
        guard let contender = waiters.first(where: { $0.ticket.group == info.group }),
              contender.ticket.priority < info.priority else { return }

        log(.debug, "Задачи", "«\(info.title)» уступает очередь задаче «\(contender.ticket.title)»")
        let ticket = QueueTicket(
            title: info.title, priority: info.priority, group: info.group,
            connectionID: info.connectionID, resumable: pendingByID[id]
        )
        // Put the slot down and get back in line ahead of newcomers of the same
        // priority — it has already waited once.
        running.removeValue(forKey: id)
        queuedInfo[id] = QueuedTaskInfo(
            id: id, title: info.title, priority: info.priority, group: info.group,
            connectionID: info.connectionID, submittedAt: info.submittedAt,
            startedAt: nil, state: .queued, progress: info.progress, detail: info.detail
        )
        promote()
        publish()

        // Cancellation while standing aside is not swallowed: the caller's task
        // is cancelled too, and it will notice at its own next checkpoint.
        try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            enqueue(Waiter(
                id: id, ticket: ticket, submittedAt: info.submittedAt,
                continuation: continuation, isReturning: true
            ))
        }
    }

    // MARK: - Progress

    func report(id: UUID, progress: Double?, detail: String?) {
        if var info = running[id] {
            info.progress = progress
            info.detail = detail
            running[id] = info
        } else if var info = queuedInfo[id] {
            info.progress = progress
            info.detail = detail
            queuedInfo[id] = info
        }
        publish()
    }

    private func publish() {
        guard let onChange else { return }
        let snapshot = snapshot()
        let shape = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0.state) })
        let structureChanged = shape != lastPublishedShape
        guard structureChanged || Date().timeIntervalSince(lastPublishedAt) >= Self.progressPublishInterval else {
            return
        }
        lastPublishedShape = shape
        lastPublishedAt = Date()
        onChange(snapshot)
    }

    // MARK: - Surviving a restart

    private var pendingByID: [UUID: ResumableRequest] = [:]

    private func remember(id: UUID, request: ResumableRequest?) {
        guard let request else { return }
        pendingByID[id] = request
        store.save(resumable + pendingRequests())
    }

    private func pendingRequests() -> [ResumableRequest] {
        Array(Set(pendingByID.values))
    }
}

/// Requests that outlived the app, stored next to everything else it writes.
public struct PendingTaskStore: Sendable {
    private let fileURL: URL

    public init(fileURL: URL = AppPaths.supportDirectory.appendingPathComponent("pending-tasks.json")) {
        self.fileURL = fileURL
    }

    public func load() -> [ResumableRequest] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([ResumableRequest].self, from: data)) ?? []
    }

    public func save(_ requests: [ResumableRequest]) {
        let unique = Array(Set(requests))
        guard !unique.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? JSONEncoder().encode(unique) else { return }
        _ = try? AppPaths.ensureDirectory(fileURL.deletingLastPathComponent())
        try? data.write(to: fileURL, options: .atomic)
    }
}
