import Foundation

/// Сколько знаков модель читает — измеренное и запомненное.
///
/// Отдельным файлом, а не в замерах скорости: скорость меряют, когда
/// хотят узнать «успеет ли», а это отвечает на «поместится ли», и меряется
/// оно само, без просьбы. Общее у них одно — оба числа принадлежат модели
/// на этой машине и переживают перезапуск.
///
/// Переживать обязательно: проба стоит семи-восьми вызовов, и заново платить
/// за неё при каждом запуске приложения незачем. Забывается она вместе
/// с остальным, что знает `ModelBindingService`, — то есть при перезагрузке
/// модели, когда числа и правда могли поменяться.
public struct MeasuredInputLimit: Codable, Sendable, Hashable {
    public let model: String
    /// Знаков, а не токенов: токены приложение не знает наверняка,
    /// а знаки знает.
    public let characters: Int
    public let measuredAt: Date
    /// Контекст, с которым модель была загружена в момент замера.
    ///
    /// Признак свежести: перезагрузили модель с другим контекстом — число
    /// устарело и меряется заново. `nil` — рантайм не сказал; тогда сравнение
    /// `nil == nil` считает запись годной, и это честно: другого признака нет.
    public let loadedContext: Int?

    public init(model: String, characters: Int, measuredAt: Date = Date(), loadedContext: Int? = nil) {
        self.model = model
        self.characters = characters
        self.measuredAt = measuredAt
        self.loadedContext = loadedContext
    }
}

public actor EmbeddingLimitStore {
    private let file: GuardedJSONFile<[MeasuredInputLimit]>
    private var limits: [MeasuredInputLimit]

    public init(fileURL: URL = AppPaths.embeddingLimitsFile, log: @escaping LogHandler = noopLogHandler) {
        self.file = GuardedJSONFile(url: fileURL, category: "Модели", log: log)
        self.limits = file.value(or: [])
    }

    public func limit(for model: String) -> MeasuredInputLimit? {
        limits.first { $0.model == model }
    }

    public func all() -> [MeasuredInputLimit] { limits }

    public func remember(_ limit: MeasuredInputLimit) {
        limits.removeAll { $0.model == limit.model }
        limits.append(limit)
        file.write(limits)
    }

    /// Забыть измеренное — после перезагрузки модели с другим контекстом.
    public func forget(model: String) {
        limits.removeAll { $0.model == model }
        file.write(limits)
    }

    public func persistenceProblem() -> String? { file.problem }
}
