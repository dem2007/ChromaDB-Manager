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

    /// Сколько отказов подряд — и модель считается молчащей до конца
    /// прогона.
    public static let silenceLimit = 3

    private let model: String
    private let complete: Completion
    private let log: LogHandler
    private let silence = Silence()

    public init(model: String, log: @escaping LogHandler = noopLogHandler, complete: @escaping Completion) {
        self.model = model
        self.complete = complete
        self.log = log
    }

    /// Отказы подряд — на весь прогон: обогатитель один на прогон, и файлов
    /// в нём сотни.
    private final class Silence: @unchecked Sendable {
        private let lock = NSLock()
        private var streak = 0
        private(set) var gaveUp = false

        var isOver: Bool { lock.withLock { gaveUp } }

        func answered() { lock.withLock { streak = 0 } }

        /// `true` — именно этот отказ исчерпал терпение.
        func failed() -> Bool {
            lock.withLock {
                streak += 1
                guard !gaveUp, streak >= ContextEnricher.silenceLimit else { return false }
                gaveUp = true
                return true
            }
        }
    }

    /// Промпт: документ, где находится фрагмент, и сам фрагмент.
    ///
    /// Просит **не пересказывать**: пересказанный фрагмент в векторе — это тот
    /// же фрагмент другими словами, а нужен контекст, которого в нём нет.
    ///
    /// **Документ — в запросе**. Раньше модель видела только название
    /// файла, путь раздела и сам фрагмент: сказать, «о чём документ», ей было
    /// не из чего, и ответ сводился к пересказу фрагмента. У Anthropic модель
    /// видит документ целиком; локальной модели целого ТЗ не прочесть, и она
    /// получает его начало и оглавление (`documentContext`). Общая для всех
    /// кусков файла часть стоит в запросе первой, фрагмент — последним:
    /// одинаковое начало запросов движок модели может не пересчитывать.
    public static func prompt(
        documentTitle: String?, headingPath: String?, text: String, documentContext: String? = nil
    ) -> String {
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
        if let documentContext, !documentContext.isEmpty {
            lines.append(documentContext)
            lines.append("")
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
        headingPaths: [Int: String] = [:], documentContext: String? = nil
    ) async throws -> [String] {
        guard chunks.count == texts.count else { return texts }
        var result = texts
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            // Модель не ответила несколько раз подряд — дальше без контекста
            //. Иначе каждый из тысяч чанков ждал полный срок, и прогон
            // папки шёл часами, не обогатив ничего, — тот же случай, что
            // у LLM-нарезки.
            guard !silence.isOver else { break }
            let prompt = Self.prompt(
                documentTitle: documentTitle,
                headingPath: headingPaths[chunk.index],
                text: chunk.text,
                documentContext: documentContext
            )
            do {
                let answer = try await complete(prompt, model)
                silence.answered()
                guard let context = Self.cleaned(answer) else { continue }
                result[index] = context + "\n\n" + texts[index]
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log(.warning, "Чанкинг",
                    "Контекст для чанка \(chunk.index) не получен: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
                if silence.failed() {
                    log(.warning, "Чанкинг",
                        "Модель \(model) не ответила \(Self.silenceLimit) раза подряд — обогащение контекстом до конца прогона выключено, фрагменты уходят в эмбеддинг как есть")
                }
            }
        }
        return result
    }

    /// Ответ модели, приведённый к строке контекста: без пустых строк,
    /// без обрамляющих кавычек, не длиннее предела.
    /// Сколько знаков начала документа идёт в запрос.
    public static let openingLength = 1_200
    /// Сколько знаков оглавления идёт в запрос.
    public static let outlineLength = 1_500

    /// Документ для запроса: его начало (название, преамбула, предмет) и
    /// оглавление — заголовки двух верхних уровней. `nil`, если сказать нечего.
    public static func documentContext(of document: ExtractedDocument) -> String? {
        var parts: [String] = []
        let text = document.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            var opening = String(text.prefix(openingLength))
            if text.count > openingLength {
                // До конца последней целой строки, а не посреди слова.
                if let cut = opening.lastIndex(where: \.isNewline), opening.distance(from: opening.startIndex, to: cut) > openingLength / 2 {
                    opening = String(opening[..<cut])
                }
                opening += " …"
            }
            parts.append("Начало документа:\n" + opening)
        }
        let top = document.structure.map(\.level).min() ?? 1
        var outline: [String] = []
        var length = 0
        for node in document.structure where node.level <= top + 1 {
            let line = String(repeating: "  ", count: node.level - top) + node.title
            guard length + line.count <= outlineLength else { break }
            outline.append(line)
            length += line.count + 1
        }
        if outline.count > 1 { parts.append("Оглавление документа:\n" + outline.joined(separator: "\n")) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

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
