import Foundation

/// Измеренное «символов на токен» по моделям, общее на всё приложение.
///
/// **Почему отдельный объект, а не поле клиента.** `LMStudioClient` создаётся
/// заново на каждую операцию — на каждый поиск, на каждую синхронизацию.
/// Измерение, положенное внутрь клиента, не переживало бы и одного запроса,
/// и калибровка, ради которой всё затевалось, не наступала бы никогда.
/// Живёт там же, где кэш эмбеддингов, и внедряется так же.
///
/// Хранится в памяти: соотношение — свойство пары «модель + характер текста»,
/// а не пользовательская настройка, и после перезапуска честнее измерить
/// заново, чем доверять записи неизвестной давности.
public actor TokenRatioStore {
    private var ratios: [String: Double] = [:]

    public init() {}

    /// Запоминает соотношение из настоящего ответа модели.
    ///
    /// Берётся **минимум** из наблюдённых, а не среднее: бюджет промпта
    /// ошибается опасно только в одну сторону, и закладываться надо на худший
    /// из встреченных текстов, а не на типичный.
    public func record(characters: Int, tokens: Int?, model: String) {
        guard let tokens, tokens > 0, characters > 0 else { return }
        let ratio = Double(characters) / Double(tokens)
        ratios[model] = min(ratios[model] ?? .greatestFiniteMagnitude, ratio)
    }

    /// `nil` — от этой модели ещё не приходило ответа с `usage`.
    public func ratio(of model: String) -> Double? { ratios[model] }

    /// Соотношение для бюджета: измеренное, а пока его нет — пессимистичное.
    public func budgetRatio(of model: String) -> Double {
        ratios[model] ?? TokenEstimator.pessimisticCharactersPerToken
    }
}
