import Foundation

/// Помещается ли LLM-нарезка в контекст, с которым загружена модель.
///
/// Считается **до** запуска. Раньше об этом узнавали изнутри прогона: либо
/// строкой в журнале «окно уменьшено с 28672 до 6284», которую никто не
/// читает, либо ошибкой на первом же файле. И то и другое — уже после того,
/// как человек нажал «Синхронизировать» и пошёл заниматься другим делом.
///
/// Контекст — не свойство модели, а настройка её загрузки в LM Studio. Модель
/// с потолком 131 072 бывает загружена с 8192, и это не ошибка приложения,
/// а то, что можно исправить одной перезагрузкой модели.
public struct LLMContextCheck: Sendable, Hashable {
    public let model: String
    /// С каким контекстом модель загружена сейчас. `nil` — LM Studio не сказала.
    public let loaded: Int?
    /// Потолок, до которого её можно загрузить. `nil` — неизвестен.
    public let maximum: Int?
    /// Сколько символов окна помещается при нынешней загрузке.
    public let allowed: Int
    /// Меньше этого нарезка не работает вовсе.
    public let minimum: Int
    /// Сколько хотелось бы под заданный размер чанка.
    public let wanted: Int
    /// Измеренная скорость письма, токенов в секунду. `nil` — не мерили.
    public let tokensPerSecond: Double?
    /// Сколько символов окна модель успевает переписать за таймаут.
    /// `nil` — скорость неизвестна, время в расчёт не берётся.
    public let allowedByTime: Int?

    public init(
        model: String, loaded: Int?, maximum: Int?,
        allowed: Int, minimum: Int, wanted: Int,
        tokensPerSecond: Double? = nil, allowedByTime: Int? = nil
    ) {
        self.model = model
        self.loaded = loaded
        self.maximum = maximum
        self.allowed = allowed
        self.minimum = minimum
        self.wanted = wanted
        self.tokensPerSecond = tokensPerSecond
        self.allowedByTime = allowedByTime
    }

    /// Предел по контексту, `Int.max` — если контекст неизвестен.
    ///
    /// «Неизвестно» — это не «ноль»: при `loaded == nil` в `allowed` лежит
    /// ноль, и брать его как предел значило бы запретить нарезку там, где
    /// про неё просто нечего сказать.
    private var byContext: Int { isUnknown ? .max : allowed }

    /// Окно, которое получится на самом деле: меньшее из двух пределов.
    /// `Int.max` — оба неизвестны, окно ничем не ограничено.
    public var effective: Int { min(byContext, allowedByTime ?? .max) }

    /// Время — более узкое место, чем контекст.
    ///
    /// Ровно тот случай, ради которого проверка и заведена: контекста
    /// после перезагрузки на 128 000 хватало с четырёхкратным запасом, а
    /// времени не хватало вдвое.
    public var timeIsTheLimit: Bool {
        guard let allowedByTime else { return false }
        return allowedByTime < byContext
    }

    /// Контекст неизвестен — судить не по чему, и мешать работать нельзя.
    public var isUnknown: Bool { loaded == nil }

    /// Нарезка вообще возможна.
    ///
    /// Оба предела разом: в контекст должно помещаться и за таймаут должно
    /// успеваться. Второе до не проверялось вовсе.
    public var fits: Bool {
        (isUnknown || allowed >= minimum) && (allowedByTime.map { $0 >= minimum } ?? true)
    }

    /// Работает, но окна меньше желаемых: границы модель ищет в кусках
    /// поменьше, чем просили. Не ошибка — повод сказать.
    public var isReduced: Bool { effective != .max && effective < wanted }

    /// Поможет ли перезагрузка: потолок выше того, с чем модель загружена.
    public var reloadingWouldHelp: Bool {
        guard let loaded, let maximum else { return false }
        return maximum > loaded
    }

    /// Строка для человека: с чем загружена, что из этого вышло.
    public var summary: String {
        // Про время — раньше, чем про контекст, и только когда оно и есть
        // помеха: иначе человек читает про контекст, идёт перезагружать
        // модель и делает себе хуже — окно вырастет, а времени не прибавится.
        if timeIsTheLimit, let allowedByTime, let speed = tokensPerSecond {
            let rate = Int(speed.rounded())
            if allowedByTime < minimum {
                return String(localized: "Модель \(model) пишет \(rate.plainDigits) токенов в секунду: за отпущенное ей время она не успеет переписать даже минимальный кусок текста (\(minimum.plainDigits) символов).")
            }
            return String(localized: "Модель \(model) пишет \(rate.plainDigits) токенов в секунду: за отпущенное ей время окно нарезки \(allowedByTime.plainDigits) символов вместо \(wanted.plainDigits). Здесь узкое место — время, а не контекст.")
        }
        guard let loaded else {
            return String(localized: "LM Studio не сказала, с каким контекстом загружена модель \(model).")
        }
        // Через `plainDigits`: «8 192» — не то число, которое можно вписать
        // в поле контекста LM Studio, а именно это человек и пойдёт делать.
        let ceiling = maximum.map { String(localized: " из \($0.plainDigits) возможных") } ?? ""
        if !fits {
            return String(localized: "Модель \(model) загружена с контекстом \(loaded.plainDigits) токенов\(ceiling). В него не помещается даже минимальный кусок текста вместе с ответом: на окно остаётся \(allowed.plainDigits) символов при необходимых \(minimum.plainDigits).")
        }
        return String(localized: "Модель \(model) загружена с контекстом \(loaded.plainDigits) токенов\(ceiling): окно нарезки \(allowed.plainDigits) символов вместо \(wanted.plainDigits).")
    }
}

public extension LLMChunker {
    /// Проверка контекста для этой настройки нарезки.
    ///
    /// Спрашивает модель, а не догадывается: `loadedContextLength` — то, с чем
    /// её загрузили в LM Studio, и меняется это без ведома приложения.
    static func contextCheck(
        configuration: ChunkingConfiguration,
        model: String,
        chat: ChatProvider
    ) async -> LLMContextCheck {
        let loaded = await chat.loadedContextLength(of: model)
        let maximum = await chat.maximumContextLength(of: model)
        let prompt = configuration.effectivePrompt
        let allowed = loaded.map { windowLimit(contextTokens: $0, prompt: prompt) } ?? 0
        // Скорость спрашивается здесь же: замер стоит пары секунд, а прогон,
        // который она отменит, — часов.
        let speed = await chat.generationSpeed(of: model)
        return LLMContextCheck(
            model: model,
            loaded: loaded,
            maximum: maximum,
            allowed: allowed,
            minimum: minimumWindow,
            wanted: wantedWindow(for: configuration),
            tokensPerSecond: speed,
            allowedByTime: speed.map {
                windowLimitByTime(timeout: configuration.llmTimeout, tokensPerSecond: $0)
            }
        )
    }
}
