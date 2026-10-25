import Foundation
import Darwin

/// Вернуть системе освобождённую память после тяжёлой разовой работы.
///
/// Распределитель держит у себя страницы, освобождённые программой, и отдаёт
/// их системе, лишь когда той не хватает. После чтения корзины, поиска тем,
/// синхронизации приложение занимало по «Мониторингу системы» 200–450 МБ
/// при 150 МБ живого: остальное — уже свободные, но не отданные страницы.
/// Здесь они отдаются сразу.
///
/// С задержкой и одним вызовом на серию: временные массивы операции
/// освобождаются, когда вызывающий получил результат и отпустил их, а пять
/// задач подряд — это одна уборка, а не пять.
public enum MemoryRelief {
    private final class Debouncer: @unchecked Sendable {
        let queue = DispatchQueue(label: "io.github.chromadbmanager.memoryrelief", qos: .utility)
        let lock = NSLock()
        var generation = 0
    }

    private static let debouncer = Debouncer()

    public static func soon(after delay: TimeInterval = 2) {
        let state = debouncer
        let current = state.lock.withLock { () -> Int in
            state.generation += 1
            return state.generation
        }
        state.queue.asyncAfter(deadline: .now() + delay) {
            guard state.lock.withLock({ state.generation == current }) else { return }
            malloc_zone_pressure_relief(nil, 0)
        }
    }
}
