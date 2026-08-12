import Foundation

/// Сочетание клавиш для вызова быстрого поиска.
///
/// Хранится кодом клавиши, а не символом: символ зависит от раскладки, а
/// `RegisterEventHotKey` работает с физической клавишей. Иначе клавиша,
/// назначенная в русской раскладке, в английской ловилась бы другая.
public struct HotKeyCombination: Codable, Equatable, Sendable {
    /// Виртуальный код клавиши (`kVK_ANSI_K` и его соседи).
    public var keyCode: UInt32
    public var command: Bool
    public var option: Bool
    public var control: Bool
    public var shift: Bool

    public init(
        keyCode: UInt32, command: Bool = true, option: Bool = true,
        control: Bool = true, shift: Bool = false
    ) {
        self.keyCode = keyCode
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
    }

    /// ⌃⌥⌘K — сочетание, за которым в системе ничего не закреплено.
    ///
    /// Три модификатора не случайность: на двух почти всё занято, и
    /// приложение, отобравшее у человека ⌘⇧K, — плохой сосед.
    public static let `default` = HotKeyCombination(keyCode: 40)

    /// Годится ли сочетание в глобальные.
    ///
    /// Без модификаторов клавиша перехватывалась бы у **всех** приложений:
    /// человек нажал бы «K» в чужом текстовом поле и получил бы наш поиск.
    public var isUsable: Bool {
        command || option || control
    }

    /// Как это выглядит в меню: ⌃⌥⌘K.
    public var display: String {
        var symbols = ""
        if control { symbols += "⌃" }
        if option { symbols += "⌥" }
        if shift { symbols += "⇧" }
        if command { symbols += "⌘" }
        return symbols + (Self.keyNames[keyCode] ?? "клавиша \(keyCode)")
    }

    /// Имена тех клавиш, которые вообще можно выбрать.
    ///
    /// Список закрытый: свободно назначаемое сочетание — это отдельный
    /// редактор с проверкой занятости, а его ТЗ не требует.
    public static let keyNames: [UInt32: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O",
        35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V",
        13: "W", 7: "X", 16: "Y", 6: "Z", 49: "Пробел",
    ]

    /// Клавиши в порядке, в котором их показывать человеку.
    public static var selectableKeys: [(code: UInt32, name: String)] {
        keyNames.map { (code: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Настройки строки меню и быстрого поиска.
///
/// Отдельной структурой, а не россыпью полей в конфигурации: это один
/// связный кусок поведения, и переносится он между машинами целиком.
public struct MenuBarPreferences: Codable, Equatable, Sendable {
    /// Показывать ли значок в строке меню. ТЗ требует, чтобы **оба**
    /// варианта поведения были доступны.
    public var showsIcon: Bool
    /// Оставаться ли в строке меню после закрытия окна, убрав значок из Dock.
    ///
    /// Выключено по умолчанию: «жизнь в строке меню» навязывать нельзя —
    /// приложение, которое не закрывается по красной кнопке, воспринимается
    /// как сломанное.
    public var keepsRunningWithoutWindow: Bool
    /// Глобальная горячая клавиша. Выключена по умолчанию: сочетание
    /// отбирается у всей системы, и делать это без спроса нельзя.
    public var globalHotKeyEnabled: Bool
    public var hotKey: HotKeyCombination
    /// Коллекция, по которой ищет быстрый поиск. `nil` — не выбрана,
    /// и поиск честно просит её выбрать, а не ищет наугад.
    public var quickSearchCollection: String?
    public var quickSearchResultCount: Int

    public init(
        showsIcon: Bool = true,
        keepsRunningWithoutWindow: Bool = false,
        globalHotKeyEnabled: Bool = false,
        hotKey: HotKeyCombination = .default,
        quickSearchCollection: String? = nil,
        quickSearchResultCount: Int = 5
    ) {
        self.showsIcon = showsIcon
        self.keepsRunningWithoutWindow = keepsRunningWithoutWindow
        self.globalHotKeyEnabled = globalHotKeyEnabled
        self.hotKey = hotKey
        self.quickSearchCollection = quickSearchCollection
        self.quickSearchResultCount = max(1, min(20, quickSearchResultCount))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showsIcon = try container.decodeIfPresent(Bool.self, forKey: .showsIcon) ?? true
        keepsRunningWithoutWindow = try container.decodeIfPresent(
            Bool.self, forKey: .keepsRunningWithoutWindow
        ) ?? false
        globalHotKeyEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .globalHotKeyEnabled
        ) ?? false
        hotKey = ((try? container.decodeIfPresent(HotKeyCombination.self, forKey: .hotKey)) ?? nil)
            ?? .default
        quickSearchCollection = try container.decodeIfPresent(
            String.self, forKey: .quickSearchCollection
        )
        let count = try container.decodeIfPresent(Int.self, forKey: .quickSearchResultCount) ?? 5
        quickSearchResultCount = max(1, min(20, count))
    }
}

/// Что показывает значок в строке меню.
///
/// Считается отдельно от вида: «идёт ли индексация» и «сколько ждёт» —
/// это правила, а не отрисовка, и проверять их надо тестом.
public struct MenuBarSummary: Equatable, Sendable {
    /// Что делается прямо сейчас, — `nil`, если ничего.
    public let running: String?
    public let queuedCount: Int
    public let paused: Bool
    /// Сводка последней синхронизации — ровно та, что показана на её экране.
    public let lastSync: String?

    public init(running: String?, queuedCount: Int, paused: Bool, lastSync: String?) {
        self.running = running
        self.queuedCount = queuedCount
        self.paused = paused
        self.lastSync = lastSync
    }

    public init(tasks: [QueuedTaskInfo], paused: Bool, lastSync: String?) {
        // Одновременно выполняться может несколько задач разных групп;
        // в строке меню называется первая — остальные попадают в счётчик.
        let active = tasks.filter { $0.state == .running }
        self.running = active.first?.title
        self.queuedCount = tasks.count - min(active.count, 1)
        self.paused = paused
        self.lastSync = lastSync
    }

    public var isBusy: Bool { running != nil }

    /// Значок: занятое приложение отличается от свободного одним взглядом.
    public var symbol: String {
        if paused { return "pause.circle" }
        return isBusy ? "arrow.triangle.2.circlepath" : "tray.full"
    }

    /// Первая строка меню — самое главное о состоянии.
    public var headline: String {
        if let running {
            return String(localized: "Идёт: \(running)")
        }
        if paused {
            return String(localized: "Автоматическая синхронизация на паузе")
        }
        return String(localized: "Задач нет")
    }

    /// Вторая строка — только когда есть что сказать.
    ///
    /// «Ожидают: 0» не пишется: ноль в очереди — это не новость, а шум.
    public var queueLine: String? {
        guard queuedCount > 0 else { return nil }
        return String(localized: "Ожидают: \(RussianCount.grouped(queuedCount, "задача", "задачи", "задач"))")
    }

    /// Пауза называется и тогда, когда что-то выполняется: остановлена
    /// автоматика, а запущенное руками доработает до конца, и путать эти
    /// два состояния нельзя.
    public var pausedLine: String? {
        guard paused, running != nil else { return nil }
        return String(localized: "Автоматическая синхронизация на паузе")
    }
}
