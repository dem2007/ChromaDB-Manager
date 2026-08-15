import Foundation

/// Том, на котором лежит источник.
///
/// Нужен ради одного сценария, который кончается потерей данных. Источник
/// лежит на внешнем диске или сетевой шаре; диск отключили. Если точка
/// монтирования при этом осталась пустой папкой — а так бывает и с autofs,
/// и с сетевыми шарами, и с каталогом, который кто-то создал руками, —
/// сканирование честно видит ноль файлов и докладывает: «исчезло восемь тысяч
/// файлов, требуют решения». Дальше достаточно одного подтверждения.
///
/// Поэтому у источника запоминается **том**, а не только путь: `/Volumes/Backup`
/// сегодня и завтра — это запросто разные диски.
public struct SourceVolume: Codable, Hashable, Sendable {
    /// UUID тома. `nil` у сетевых шар и образов, которые его не сообщают, —
    /// тогда сверка идёт по имени и точке монтирования.
    public var uuid: String?
    public var name: String?
    /// Точка монтирования — корень тома, а не путь источника.
    public var mountPoint: String?
    public var isRemovable: Bool
    /// Не локальный: сетевая шара. Отдельно от «съёмного» — отключаются они
    /// по-разному, а выглядят одинаково.
    public var isNetwork: Bool

    public init(
        uuid: String? = nil,
        name: String? = nil,
        mountPoint: String? = nil,
        isRemovable: Bool = false,
        isNetwork: Bool = false
    ) {
        self.uuid = uuid
        self.name = name
        self.mountPoint = mountPoint
        self.isRemovable = isRemovable
        self.isNetwork = isNetwork
    }

    /// Том, на котором лежит этот путь. `nil` — пути нет вовсе.
    public static func of(_ url: URL) -> SourceVolume? {
        let keys: Set<URLResourceKey> = [
            .volumeUUIDStringKey, .volumeNameKey, .volumeURLKey,
            .volumeIsRemovableKey, .volumeIsLocalKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        // Ни одного значения — путь недоступен: у несуществующего пути
        // ресурсных значений тома нет вовсе (проверено вживую).
        guard values.volumeUUIDString != nil || values.volumeName != nil || values.volume != nil else {
            return nil
        }
        return SourceVolume(
            uuid: values.volumeUUIDString,
            name: values.volumeName,
            mountPoint: values.volume?.path,
            isRemovable: values.volumeIsRemovable ?? false,
            isNetwork: !(values.volumeIsLocal ?? true)
        )
    }

    /// Тот же это том или другой.
    ///
    /// **UUID главнее всего**: имя тома человек меняет, точка монтирования
    /// зависит от порядка подключения. Если UUID есть у обоих и они разные —
    /// это другой диск, и говорить тут не о чем.
    ///
    /// Если UUID нет (сетевая шара), сверяются имя и точка монтирования.
    /// Когда сверять нечем вовсе, ответ «тот же»: отказать источнику на
    /// внутреннем диске из-за того, что система не сообщила о нём ничего, —
    /// хуже, чем не проверить. От массовой пропажи защищает отдельное правило.
    public func isSame(as other: SourceVolume) -> Bool {
        if let mine = uuid, let theirs = other.uuid { return mine == theirs }
        if uuid != nil || other.uuid != nil {
            // UUID появился или пропал — это смена тома, а не совпадение.
            return false
        }
        let names = name == other.name
        let points = mountPoint == other.mountPoint
        if name == nil && mountPoint == nil { return true }
        return names && points
    }

    /// Как называть том человеку.
    public var title: String {
        name ?? mountPoint ?? String(localized: "неизвестный том")
    }

    /// Состояние тома источника перед прогоном.
    public enum Availability: Sendable, Equatable {
        /// Том на месте и тот самый.
        case ready(SourceVolume?)
        /// Пути нет: диск отключён или папку унесли.
        case missing
        /// Путь есть, но том другой — `/Volumes/Backup` сегодня и вчера бывают
        /// разными дисками.
        case changed(expected: SourceVolume, found: SourceVolume?)
    }

    /// Проверяет том до сканирования.
    ///
    /// - Parameter expected: том, запомненный у источника. `nil` — источник
    ///   заведён прежней сборкой или ещё ни разу не синхронизировался: тогда
    ///   проверять не с чем, и текущий том просто запоминается.
    public static func check(
        path: String,
        expected: SourceVolume?,
        fileManager: FileManager = .default
    ) -> Availability {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .missing
        }
        let current = SourceVolume.of(URL(fileURLWithPath: path))
        guard let expected else { return .ready(current) }
        guard let current, current.isSame(as: expected) else {
            return .changed(expected: expected, found: current)
        }
        return .ready(current)
    }
}
