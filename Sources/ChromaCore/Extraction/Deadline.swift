import Foundation

/// Продолжение, которое возобновляется ровно один раз.
///
/// Нужно там, где ответ может прийти двумя путями: Vision зовёт обработчик
/// запроса с ошибкой **и** бросает ту же ошибку из `perform`, а гонка работы
/// с таймаутом кончается тем, кто успел первым. Второе возобновление
/// `CheckedContinuation` — это ловушка, роняющая приложение; здесь оно
/// просто не случается.
final class OnceContinuation<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    /// `true` — возобновил именно этот вызов.
    @discardableResult
    func resume(with result: Result<T, Error>) -> Bool {
        let taken: CheckedContinuation<T, Error>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        guard let taken else { return false }
        taken.resume(with: result)
        return true
    }
}

/// Ожидание, ограниченное по времени, — именно **ожидание**, а не работа.
enum Deadline {
    /// Первое из двух: результат работы или истёкший срок.
    ///
    /// Не `withThrowingTaskGroup`: группа при выходе дожидается **всех**
    /// своих задач, и работа, застрявшая в синхронном вызове (разбор на
    /// главном потоке, `VNImageRequestHandler.perform`), держала бы
    /// вызывающего столько же, сколько без всякого срока. Здесь работа
    /// идёт отдельной задачей: по истечении срока её просят отмениться,
    /// а ответ вызывающему приходит сразу. Досчитает она — результат
    /// никто не прочтёт.
    static func race<T: Sendable>(
        seconds: TimeInterval,
        timeoutError: @escaping @Sendable () -> Error,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard seconds.isFinite, seconds > 0 else { return try await work() }
        let nanoseconds = UInt64(min(seconds, 365 * 86_400) * 1_000_000_000)
        let tasks = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                let once = OnceContinuation(continuation)
                let worker = Task {
                    let result: Result<T, Error>
                    do { result = .success(try await work()) } catch { result = .failure(error) }
                    if once.resume(with: result) { tasks.cancelAll() }
                }
                let timer = Task {
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    guard !Task.isCancelled else { return }
                    if once.resume(with: .failure(timeoutError())) { tasks.cancelAll() }
                }
                tasks.set(worker: worker, timer: timer, once: { once.resume(with: .failure(CancellationError())) })
            }
        } onCancel: {
            tasks.cancelFromOutside()
        }
    }

    /// Задачи гонки — чтобы снять их, кто бы ни кончил первым.
    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var worker: Task<Void, Never>?
        private var timer: Task<Void, Never>?
        private var cancelWaiter: (() -> Void)?
        private var cancelledEarly = false

        func set(worker: Task<Void, Never>, timer: Task<Void, Never>, once: @escaping () -> Void) {
            let early: Bool = lock.withLock {
                self.worker = worker
                self.timer = timer
                self.cancelWaiter = once
                return cancelledEarly
            }
            if early { cancelFromOutside() }
        }

        func cancelAll() {
            let (worker, timer) = lock.withLock { (self.worker, self.timer) }
            worker?.cancel()
            timer?.cancel()
        }

        /// Отменили того, кто ждёт: ждать больше некому.
        func cancelFromOutside() {
            let waiter: (() -> Void)? = lock.withLock {
                cancelledEarly = true
                return cancelWaiter
            }
            waiter?()
            cancelAll()
        }
    }
}
