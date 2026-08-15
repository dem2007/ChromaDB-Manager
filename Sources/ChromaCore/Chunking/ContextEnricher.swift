import Foundation

/// Контекстное обогащение чат-моделью.
///
/// Модель читает фрагмент и пишет одно-два предложения о том, о чём документ
/// и где в нём этот фрагмент; строка приписывается к тексту **перед
/// вычислением вектора** — по тому же правилу, что и структурная строка
/// «Документ → Раздел»: в вектор, но не в документ. Человек и агент
/// читают чанк как он есть, и `content_hash` остаётся хэшем файла.
///
/// **Стоит вызова чат-модели на каждый чанк.** Это не оптимизируется: смысл
/// приёма в том, что модель видит именно этот фрагмент. Поэтому опция
/// выключена по умолчанию, а экран обязан показать оценку до запуска —
/// `ContextEnricher.estimate`.
public struct ContextEnricher: Sendable {
    /// Сколько предложений просить. Больше двух — это уже пересказ, который
    /// начинает конкурировать с самим фрагментом за место в векторе.
    public static let sentenceLimit = 2
    /// Ответ длиннее этого обрезается: модель, ушедшая в пересказ, не должна
    /// утопить текст чанка в собственных словах.
    public static let maximumLength = 400
    /// Свой срок ответа: чанков тысячи, и ждать по три минуты каждый нельзя.
    public static let timeout: TimeInterval = 60

    public typealias Completion = @Sendable (_ prompt: String, _ model: String) async throws -> String

    private let model: String
    private let complete: Completion
    private let log: LogHandler

    public init(model: String, log: @escaping LogHandler = noopLogHandler, complete: @escaping Completion) {
        self.model = model
        self.complete = complete
        self.log = log
    }

    /// Промпт: документ, где находится фрагмент, и сам фрагмент.
    ///
    /// Просит **не пересказывать**: пересказанный фрагмент в векторе — это тот
    /// же фрагмент другими словами, а нужен контекст, которого в нём нет.
    public static func prompt(documentTitle: String?, headingPath: String?, text: String) -> String {
        var lines = [
            "Ты помогаешь искать по базе документов.",
            "Напиши не больше \(sentenceLimit) предложений о том, о чём документ и какое место в нём занимает фрагмент ниже.",
            "Не пересказывай сам фрагмент и не добавляй ничего, чего в нём и в его расположении нет.",
            "Ответь только этими предложениями, без вступлений.",
            "",
        ]
        if let documentTitle, !documentTitle.isEmpty {
            lines.append("Документ: \(documentTitle)")
        }
        if let headingPath, !headingPath.isEmpty {
            lines.append("Раздел: \(headingPath)")
        }
        lines.append("")
        lines.append("Фрагмент:")
        lines.append(text)
        return lines.joined(separator: "\n")
    }

    /// Тексты для эмбеддинга с приписанным контекстом.
    ///
    /// Чанк, для которого модель не ответила, идёт дальше **как был**: потеря
    /// контекста у одного фрагмента — мелочь, а сорванная из-за неё
    /// синхронизация папки — нет.
    ///
    /// - Parameter headingPaths: путь заголовков по номеру чанка. Половина
    ///   вопроса, ради которого приём и делается, — «какое место в документе
    ///   занимает фрагмент», и без раздела модель отвечает на неё догадкой.
    public func enriched(
        chunks: [TextChunk], texts: [String], documentTitle: String?,
        headingPaths: [Int: String] = [:]
    ) async throws -> [String] {
        guard chunks.count == texts.count else { return texts }
        var result = texts
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let prompt = Self.prompt(
                documentTitle: documentTitle,
                headingPath: headingPaths[chunk.index],
                text: chunk.text
            )
            do {
                let answer = try await complete(prompt, model)
                guard let context = Self.cleaned(answer) else { continue }
                result[index] = context + "\n\n" + texts[index]
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log(.warning, "Чанкинг",
                    "Контекст для чанка \(chunk.index) не получен: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            }
        }
        return result
    }

    /// Ответ модели, приведённый к строке контекста: без пустых строк,
    /// без обрамляющих кавычек, не длиннее предела.
    static func cleaned(_ answer: String) -> String? {
        // Кавычки снимаются с **каждой** строки, а не с готовой склейки: модель
        // нередко берёт в кавычки каждое предложение, и тогда у собранной
        // строки обрамляющей кавычки нет, а внутри они остаются.
        let quotes = CharacterSet(charactersIn: " \"«»")
        let flat = answer
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: quotes) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: quotes)
        guard !flat.isEmpty else { return nil }
        guard flat.count > maximumLength else { return flat }
        return String(flat.prefix(maximumLength)) + "…"
    }

    /// Во что обойдётся обогащение: вызовов столько же, сколько чанков.
    ///
    /// Секунда на вызов — не выдумка, а измеренная скорость чат-модели, если
    /// она есть; без измерения время не называется вовсе (правило 4
    /// приложения 5: угаданных чисел не показываем).
    public static func estimate(
        chunks: Int, secondsPerCall: Double?, basis: TableRunEstimate.Basis = .unknown
    ) -> TableRunEstimate {
        TableRunEstimate(
            embeddings: chunks,
            metadataWrites: 0,
            seconds: secondsPerCall.map { $0 * Double(chunks) },
            basis: secondsPerCall == nil ? .unknown : basis
        )
    }
}
