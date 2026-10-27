import Foundation

/// Сервер моделей, с которым работает приложение.
///
/// LM Studio выпускается только для Apple Silicon. На Маке с Intel её место
/// занимает Ollama: тот же локальный сервер с API в духе OpenAI, но список
/// моделей, их тип и контекст она отдаёт своими запросами (`/api/tags`,
/// `/api/show`, `/api/ps`), а векторы — `/api/embed`. Всё остальное
/// приложение делает одинаково для обоих: чат и переранжирование идут через
/// `/v1/chat/completions` и `/v1/completions`, которые Ollama понимает.
public enum LLMProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case lmStudio
    case ollama

    public var id: String { rawValue }

    /// Название — как его пишет сам сервер.
    public var title: String {
        switch self {
        case .lmStudio: return "LM Studio"
        case .ollama: return "Ollama"
        }
    }

    /// Адрес, на котором сервер слушает сразу после установки.
    public var defaultBaseURL: String {
        switch self {
        case .lmStudio: return "http://localhost:1234"
        // Ollama слушает 127.0.0.1:11434, пока `OLLAMA_HOST` не сказал иначе.
        case .ollama: return "http://localhost:11434"
        }
    }

    /// Что сделать, если сервер не отвечает.
    var unreachableHint: String {
        switch self {
        case .lmStudio: return "Запустите LM Studio и включите Local Server в разделе Developer."
        case .ollama: return "Запустите Ollama — приложение Ollama или `ollama serve` в терминале."
        }
    }

    var unreachableHintForAgents: String {
        switch self {
        case .lmStudio: return "It must be running with Local Server enabled."
        case .ollama: return "It must be running (the Ollama app or `ollama serve`)."
        }
    }

    /// Имя модели в кэшах приложения: векторы, размерность, контекст,
    /// доля символов на токен. Одно имя у двух серверов — две модели, и
    /// кэшированное у одного другому не годится. У LM Studio ключ — само
    /// имя, как было до Ollama: накопленный кэш не теряется.
    public func cacheName(of model: String) -> String {
        self == .lmStudio ? model : "\(rawValue):\(model)"
    }

    /// С каким сервером приложение начинает на этом Маке: на Intel —
    /// с Ollama, потому что LM Studio там не работает.
    public static var platformDefault: LLMProvider {
        #if arch(x86_64)
        return .ollama
        #else
        return .lmStudio
        #endif
    }
}
