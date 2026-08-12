import Foundation
import ChromaCore

/// Состояние очереди для экрана — **отдельным наблюдаемым объектом**, а не полем
/// `AppEnvironment`.
///
/// Разница не в опрятности, а в числе перерисовок. SwiftUI извещает подписчиков
/// об объекте целиком: любое `@Published`-изменение `AppEnvironment` заставляет
/// перестроить тело **каждого** экрана, у которого он объявлен через
/// `@EnvironmentObject`, — а объявлен он у всех двадцати. Очередь же во время
/// работы сообщает о прогрессе четыре раза в секунду (`TaskQueue`
/// коалесцирует их в 0,25 с). Значит любая длительная операция перестраивала
/// весь открытый экран четырежды в секунду — включая «Коллекции» и «Источники»,
/// самые тяжёлые в приложении.
///
/// Это ровно тот дефект, который уже был найден и починен для времени работы
/// сервера: поле, меняющееся по таймеру, читалось из большого тела и
/// оплачивало его перестроение. Там лечение было тем же — вынести наблюдение
/// туда, где оно нужно, и оставить перерисовку одной надписи.
///
/// Держится в `AppEnvironment` обычным `let`: он его создаёт и наполняет, но
/// не публикует. Подписываются на зеркало только те, кому очередь и правда
/// нужна: экран «Задачи», меню-бар и три строки прогресса.
@MainActor
final class QueueMirror: ObservableObject {
    @Published private(set) var tasks: [QueuedTaskInfo] = []
    /// Прерванные операции, которые можно продолжить.
    @Published private(set) var resumableRequests: [ResumableRequest] = []

    func update(tasks: [QueuedTaskInfo]) {
        self.tasks = tasks
    }

    func update(resumable: [ResumableRequest]) {
        resumableRequests = resumable
    }

    // MARK: - Что спрашивают экраны

    /// Задача, чьё название начинается с этих слов. Так экран находит «свою»
    /// строку прогресса, не зная про очередь ничего больше.
    func task(titledWith prefix: String) -> QueuedTaskInfo? {
        tasks.first { $0.title.hasPrefix(prefix) }
    }

    func tasks(titledWith prefix: String) -> [QueuedTaskInfo] {
        tasks.filter { $0.title.hasPrefix(prefix) }
    }
}
