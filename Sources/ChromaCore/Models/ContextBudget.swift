import Foundation

/// Whether a text fits the model that will embed it.
///
/// This check exists because nothing else does it. Verified on LM Studio with
/// a loaded embedding model: 160 000 characters came back `200 OK` with
/// a perfectly ordinary vector, `usage.prompt_tokens` was `0`, and two texts
/// differing only in their tails produced **identical** vectors — the tail
/// never reached the model. A document indexed that way is searchable by its
/// first pages and invisible beyond them, with nothing anywhere to say so.
public enum ContextVerdict: Equatable, Sendable {
    case empty
    case fits(estimatedTokens: Int, limit: Int?)
    /// Close enough to the limit that the estimate itself might be wrong.
    case tight(estimatedTokens: Int, limit: Int)
    case tooLong(estimatedTokens: Int, limit: Int)
    /// The model did not report a context length; only a rough warning is
    /// possible, and blocking on a guess would do more harm than letting it through.
    case unknownLimit(estimatedTokens: Int, characters: Int)

    public var blocksSending: Bool {
        switch self {
        case .tooLong, .empty: return true
        case .fits, .tight, .unknownLimit: return false
        }
    }

    /// `nil` when there is nothing worth saying.
    public var message: String? {
        switch self {
        case .empty:
            return String(localized: "Текст пустой — эмбеддинг такого документа не имеет смысла.")
        case .fits:
            return nil
        case .tight(let tokens, let limit):
            return String(localized: "Текст близок к пределу модели: ≈\(tokens.plainDigits) токенов при лимите \(limit.plainDigits). Оценка приблизительная, поэтому запас лучше оставить.")
        case .tooLong(let tokens, let limit):
            return String(localized: "Текст длиннее контекста модели (≈\(tokens.plainDigits) токенов при лимите \(limit.plainDigits)). Сократите текст или выберите модель с большим контекстом — иначе модель молча обработает только начало.")
        case .unknownLimit(let tokens, let characters):
            return String(localized: "Длина контекста модели неизвестна, а текст большой: \(characters.plainDigits) символов, ≈\(tokens.plainDigits) токенов. Если модель короткая, конец текста в вектор не попадёт.")
        }
    }
}

public enum ContextBudget {
    /// Below this share of the context everything is fine; above it the
    /// estimate is too close to the limit to be trusted.
    public static let warningShare = 0.8
    /// Used when the model says nothing about its context: a text this long is
    /// worth a warning under any model, and still not worth blocking.
    public static let unknownLimitWarningCharacters = 8000

    public static func check(_ text: String, contextLength: Int?) -> ContextVerdict {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        // Пессимистичная оценка, а не обычная. Здесь ошибка в одну
        // сторону безобидна — лишнее предупреждение, — а в другую означает
        // молча обрезанный моделью текст. Замер на живом корпусе: 2.68 знака
        // на токен для русского против 3.5, которые приложение считает
        // «средними». По 3.5 текст в 21 400 знаков выглядит как 6114 токенов
        // и укладывается в лимит 8192; на деле там 7990, то есть впритык.
        let tokens = TokenEstimator.estimatedTokens(
            text, charactersPerToken: TokenEstimator.pessimisticCharactersPerToken
        )

        guard let limit = contextLength, limit > 0 else {
            return text.count > unknownLimitWarningCharacters
                ? .unknownLimit(estimatedTokens: tokens, characters: text.count)
                : .fits(estimatedTokens: tokens, limit: nil)
        }
        if tokens > limit {
            return .tooLong(estimatedTokens: tokens, limit: limit)
        }
        if Double(tokens) > Double(limit) * warningShare {
            return .tight(estimatedTokens: tokens, limit: limit)
        }
        return .fits(estimatedTokens: tokens, limit: limit)
    }
}

public enum ContextError: LocalizedError, Equatable {
    case tooLong(estimatedTokens: Int, limit: Int, model: String)
    case emptyText

    public var errorDescription: String? {
        switch self {
        case .tooLong(let tokens, let limit, let model):
            return String(localized: "Текст длиннее контекста модели «\(model)»: ≈\(tokens.plainDigits) токенов при лимите \(limit.plainDigits).")
        case .emptyText:
            return String(localized: "Пустой текст не отправляется на эмбеддинг.")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .tooLong:
            return String(localized: "Сократите текст, включите чанкинг для источника или выберите модель с большим контекстом.")
        case .emptyText:
            return nil
        }
    }
}
