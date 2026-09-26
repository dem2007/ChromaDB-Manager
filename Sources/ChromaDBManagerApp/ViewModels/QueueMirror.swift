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

    /// Начала названий задач — **переведённые**, как и сами названия.
    ///
    /// Названия строятся через `String(localized:)`, а экраны искали их по
    /// русскому началу: в английском интерфейсе «Syncing “X”» не начинается
    /// с «Синхронизация», и строки прогресса синхронизации, импорта и
    /// пересчёта не находили своих задач вовсе. Начало берётся из того же
    /// шаблона: вместо имени подставляется метка, и всё после неё отрезается.
    enum TitlePrefix {
        static var sync: String { prefix { String(localized: "Синхронизация «\($0)»") } }
        static var `import`: String { prefix { String(localized: "Импорт в «\($0)»") } }
        static var recompute: String { prefix { String(localized: "Пересчёт коллекции «\($0)»") } }

        private static let marker = "\u{1}"
        private static func prefix(_ template: (String) -> String) -> String {
            let title = template(marker)
            return title.range(of: marker).map { String(title[..<$0.lowerBound]) } ?? title
        }
    }
}
