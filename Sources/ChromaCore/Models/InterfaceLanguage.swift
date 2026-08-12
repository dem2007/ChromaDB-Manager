import Foundation

/// Язык интерфейса.
///
/// По умолчанию — системный: приложение не решает за человека, на каком языке
/// ему работать, если система уже ответила на этот вопрос. Явный выбор нужен
/// тем, у кого система на одном языке, а работа на другом, — обычный случай
/// для русскоязычного пользователя macOS на английской системе.
public enum InterfaceLanguage: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Как в системных настройках.
    case system
    case russian = "ru"
    case english = "en"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return String(localized: "Как в системе")
        // Названия языков **не переводятся**: человек, попавший в незнакомый
        // интерфейс, ищет своё название языка, а не его перевод.
        case .russian: return "Русский"
        case .english: return "English"
        }
    }

    /// Коды для `AppleLanguages`. Пусто — снять переопределение и вернуться
    /// к системному порядку языков.
    public var appleLanguages: [String]? {
        switch self {
        case .system: return nil
        case .russian: return ["ru"]
        case .english: return ["en"]
        }
    }
}

/// Хранит выбор языка там, где его читает сама система.
///
/// Язык бандла выбирается **при запуске**, до того как выполнится хоть одна
/// строка приложения: список `AppleLanguages` читает загрузчик ресурсов.
/// Поэтому выбор пишется в `UserDefaults` — то самое место, откуда система
/// его и возьмёт, — и вступает в силу со следующего запуска. Обещать
/// мгновенное переключение было бы обманом: половина экрана осталась бы на
/// прежнем языке, потому что тексты уже прочитаны.
public struct InterfaceLanguageStore {
    /// Ключ системы: отсюда язык берёт загрузчик ресурсов.
    public static let systemKey = "AppleLanguages"
    /// Свой ключ: **что выбрал человек**.
    ///
    /// Два ключа, а не один, и это не дублирование. `AppleLanguages` виден
    /// приложению и тогда, когда оно туда ничего не писало: значение
    /// наследуется от системы — на русской машине это `["ru-RU"]`. По нему
    /// нельзя отличить «человек выбрал русский» от «так стоит в системе»,
    /// а на машине с `["en"]` системная настройка читалась бы как явный
    /// выбор английского. Поймано тестом сразу же.
    public static let choiceKey = "io.github.chromadbmanager.interfaceLanguage"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Что записано в системный ключ **этим приложением**.
    public var override: [String]? {
        guard current != .system else { return nil }
        return defaults.array(forKey: Self.systemKey) as? [String]
    }

    public var current: InterfaceLanguage {
        guard let raw = defaults.string(forKey: Self.choiceKey) else { return .system }
        return InterfaceLanguage(rawValue: raw) ?? .system
    }

    /// Применяет выбор. Возвращает `true`, если что-то изменилось — то есть
    /// если есть смысл предлагать перезапуск.
    @discardableResult
    public func apply(_ language: InterfaceLanguage) -> Bool {
        guard language != current else { return false }
        if let codes = language.appleLanguages {
            defaults.set(language.rawValue, forKey: Self.choiceKey)
            defaults.set(codes, forKey: Self.systemKey)
        } else {
            // Снять своё переопределение и вернуться к системному порядку —
            // не записать в него нынешний язык системы: иначе выбор застыл бы
            // на том, что было в день нажатия.
            defaults.removeObject(forKey: Self.choiceKey)
            defaults.removeObject(forKey: Self.systemKey)
        }
        return true
    }

    /// Язык, на котором приложение говорит **сейчас**.
    ///
    /// Не то же, что выбор: при «как в системе» это то, что выбрал загрузчик
    /// ресурсов из системного порядка языков и того, что есть в бандле.
    public static func running(bundle: Bundle = .main) -> String? {
        bundle.preferredLocalizations.first
    }
}
