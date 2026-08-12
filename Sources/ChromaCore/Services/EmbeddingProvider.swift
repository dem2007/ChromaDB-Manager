import Foundation

/// Whatever computes vectors for the sync pipeline.
///
/// In the app this is always LM Studio. The protocol exists so a sync can be
/// tested end-to-end against a real ChromaDB server without requiring LM Studio
/// to be running — the part being tested is the manifest logic, not the model.
public protocol EmbeddingProvider: Sendable {
    func embed(texts: [String], model: String) async throws -> [[Double]]

    /// Предел длины входа для этой модели, в токенах. `nil` — неизвестен.
    ///
    /// Здесь берётся **потолок** (`max_context_length`), а не загруженный
    /// контекст, — в отличие от `ChatProvider.loadedContextLength`.
    /// Разница измерена: на эмбеддингах рантайм контекст наращивает, текст
    /// в 30 000 символов проходит через модель, загруженную с 2048;
    /// на порождающих вызовах не наращивает и отвечает 400.
    func contextLength(of model: String) async -> Int?
}

public extension EmbeddingProvider {
    func contextLength(of model: String) async -> Int? { nil }
}

/// Whatever answers a chat prompt — used only by LLM-based chunking.
///
/// Carries the whole generation block rather than just `temperature` (part G):
/// seed, token limit and the extended parameters all shape the answer, and a
/// provider that silently dropped them would produce different chunks from the
/// ones the settings describe.
public protocol ChatProvider: Sendable {
    func complete(
        prompt: String,
        model: String,
        settings: ChatGenerationSettings,
        schema: ChatJSONSchema?,
        timeout: TimeInterval?
    ) async throws -> String

    /// Контекст, с которым модель загружена сейчас, — чтобы вызывающая сторона
    /// могла уложить в него промпт, а не узнать о нём из ошибки 400.
    /// `nil` — неизвестно; тогда бюджет не считается и ничего не режется.
    func loadedContextLength(of model: String) async -> Int?

    /// Измеренное «символов на токен» для этой модели. `nil` — ещё
    /// не измерялось; тогда берётся пессимистичная оценка.
    func charactersPerToken(of model: String) async -> Double?

    /// Потолок контекста модели — не то, с чем она загружена.
    ///
    /// Разница и есть весь смысл: модель с потолком 131 072 сплошь и рядом
    /// загружена с 8192, и это чинится перезагрузкой модели, а не настройками
    /// приложения. `nil` — неизвестно.
    func maximumContextLength(of model: String) async -> Int?

    /// Сколько токенов в секунду эта модель пишет **на этой машине**.
    ///
    /// Контекст отвечает на вопрос «поместится ли», а это — на вопрос
    /// «успеет ли». Вопросы разные: окно на 28 672 символа помещалось в
    /// контекст 128 000 с большим запасом и при этом требовало от модели
    /// около 11 000 токенов ответа — почти три минуты при измеренных
    /// 72 ток/с, вдвое больше отпущенных ей ста двадцати секунд.
    /// `nil` — не измерялось; тогда время в расчёт не берётся.
    func generationSpeed(of model: String) async -> Double?
}

public extension ChatProvider {
    /// Реализация по умолчанию — «не знаю». Двойники в тестах и провайдеры,
    /// которым нечего сказать, остаются валидными.
    func loadedContextLength(of model: String) async -> Int? { nil }
    func charactersPerToken(of model: String) async -> Double? { nil }
    func maximumContextLength(of model: String) async -> Int? { nil }
    func generationSpeed(of model: String) async -> Double? { nil }
}

extension LMStudioClient: EmbeddingProvider {}
extension LMStudioClient: ChatProvider {}
extension LMStudioClient: UncachedEmbeddingProvider {}
