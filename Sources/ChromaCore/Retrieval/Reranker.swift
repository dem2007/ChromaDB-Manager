import Foundation

/// Reordering the final list with a chat model.
///
/// The expensive stage: one chat call per query, seconds or tens of seconds
/// added to a search that until now took milliseconds. Off by default, and the
/// interface says the price before it is turned on.
///
/// **A dedicated rerank endpoint was checked for and is not there.** LM Studio
/// 0.3.x answers `POST /v1/rerank` with «Unexpected endpoint or method», even
/// though its library carries cross-encoders (`qwen3-reranker-0.6b`,
/// `jina-reranker-v3.5-mlx`) — they are reported as ordinary `llm`. So the chat
/// path the section describes as the fallback is currently the only path
///. When the endpoint appears, this is the type to change.
public enum Reranker {
    /// At most this many candidates are sent. Twenty is what the section fixes,
    /// and the reason is the prompt: a longer list is both slower and worse,
    /// because the model stops attending to the tail.
    public static let maximumCandidates = 20

    /// What the model must answer with. Without a schema the stage is not
    /// workable — G2 makes it compulsory, and it is what removes the whole
    /// class of «модель ответила прозой» failures.
    public static let schema = ChatJSONSchema(
        name: "ranking",
        schema: [
            "type": "object",
            "properties": [
                "ranking": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "index": ["type": "integer"],
                            "score": ["type": "number"],
                        ],
                        "required": ["index", "score"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "required": ["ranking"],
            "additionalProperties": false,
        ]
    )

    /// The default prompt. Editable in the profile, because what «релевантно»
    /// means depends on the corpus — but it ships with a version that works.
    public static let defaultPrompt = """
    Ты оцениваешь, насколько каждый фрагмент отвечает на запрос.

    Запрос: {query}

    Фрагменты:
    {documents}

    Для каждого фрагмента верни его номер и оценку от 0 до 1: 1 — прямо отвечает \
    на запрос, 0 — не относится к делу. Оцени все фрагменты, не пропуская ни \
    одного, и не придумывай номеров, которых нет в списке.
    """

    /// What the user is told before switching this on (rule 4 of Приложение 5:
    /// a long operation warns beforehand, not afterwards).
    public static let costWarning = String(localized: """
    Переранжирование — это один вызов чат-модели на каждый запрос. Поиск, который \
    сейчас занимает миллисекунды, станет занимать секунды или десятки секунд. \
    Включайте, когда качество выдачи важнее скорости.
    """)

    public static func prompt(
        template: String, query: String, documents: [String]
    ) -> String {
        let listed = documents.enumerated()
            .map { "\($0.offset + 1). \($0.element.replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: "\n\n")
        let base = template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultPrompt
            : template
        return base
            .replacingOccurrences(of: "{query}", with: query)
            .replacingOccurrences(of: "{documents}", with: listed)
    }

    // MARK: - Бюджет промпта

    /// Меньше этого фрагмент отдавать модели бессмысленно: по трём строкам
    /// судить не о чем, и лучше спросить про меньшее число кандидатов целиком,
    /// чем про все по огрызку.
    public static let minimumTokensPerDocument = 60

    /// Место под ответ. Схема просит номер и оценку на каждого кандидата;
    /// двадцать пять токенов на позицию — с запасом, плюс скобки списка.
    public static func answerReserve(for count: Int) -> Int { 40 + 25 * count }

    /// Оценка в токенах приблизительная (`TokenEstimator` — правило большого
    /// пальца, а не токенизатор модели: LM Studio его по API не отдаёт).
    /// Десятая часть контекста остаётся на ошибку этой оценки.
    public static let safetyFraction = 0.10

    public struct FittedPrompt: Sendable, Equatable {
        /// Фрагменты в том же порядке, возможно укороченные и, возможно,
        /// не все.
        public let documents: [String]
        public let truncatedCount: Int
        public let droppedCount: Int
        /// Соотношение, по которому считался бюджет, и откуда оно взято.
        /// Без этого «укорочено 18» не объясняет, почему именно столько —
        /// а панель E0.4 существует ровно чтобы объяснять.
        public var charactersPerToken: Double = TokenEstimator.pessimisticCharactersPerToken
        public var ratioWasMeasured = false

        public var isUnchanged: Bool { truncatedCount == 0 && droppedCount == 0 }

        /// Строка для панели «как получен этот результат»: молчать о том, что
        /// модель судила не по всему тексту, нельзя — это ровно то тихое
        /// усечение, против которого написан A7.1.
        public var note: String? {
            let counts: String
            switch (truncatedCount, droppedCount) {
            case (0, 0): return nil
            case (let t, 0): counts = String(localized: "укорочено \(t)")
            case (0, let d): counts = String(localized: "отброшено \(d)")
            case (let t, let d): counts = String(localized: "укорочено \(t), отброшено \(d)")
            }
            // Через `String(format:)`, а не интерполяцией: интерполяция
            // `Double` в локализованную строку печатает шесть знаков после
            // запятой — «2,770000 симв/токен».
            let rounded = String(format: "%.2f", charactersPerToken)
            let source = ratioWasMeasured
                ? String(localized: "измерено")
                : String(localized: "оценка по умолчанию")
            return String(localized: "не влезало в контекст: \(counts), \(rounded) симв/токен — \(source)")
        }
    }

    /// Укладывает фрагменты в контекст модели.
    ///
    /// **Зачем.** Двадцать кандидатов уходили в один промпт без всякой оценки
    /// размера. На модели, загруженной с контекстом 8192, это 14 000 токенов,
    /// и оба движка отвечают на такой промпт `400` — MLX своим
    /// `exceed_context_size_error`, llama.cpp своим «provide a shorter input»
    /// (; первая редакция утверждала, что llama.cpp обрезает молча, —
    /// это было неверно и там же исправлено). Стадия просто не выполнялась.
    ///
    /// **Как делится место.** Поровну, но без потерь: тот, кому его доля не
    /// нужна целиком, отдаёт остаток другим (заполнение водой). Короткие
    /// фрагменты поэтому уходят как есть, а режутся только длинные.
    ///
    /// **Когда доли перестаёт хватать**, число кандидатов уменьшается: судить
    /// по огрызку в три строки — не переранжирование.
    ///
    /// `contextTokens == nil` — LM Studio не сказала, сколько контекста;
    /// тогда ничего не выдумываем и не трогаем.
    public static func fit(
        documents: [String], query: String, template: String, contextTokens: Int?,
        charactersPerToken ratio: Double = TokenEstimator.pessimisticCharactersPerToken,
        ratioWasMeasured measured: Bool = false
    ) -> FittedPrompt {
        guard let contextTokens, contextTokens > 0, !documents.isEmpty else {
            return FittedPrompt(documents: documents, truncatedCount: 0, droppedCount: 0)
        }
        let tokens = { (text: String) in
            TokenEstimator.estimatedTokens(text, charactersPerToken: ratio)
        }
        let overhead = tokens(prompt(template: template, query: query, documents: []))
        let margin = Int((Double(contextTokens) * safetyFraction).rounded(.up))
        var count = documents.count
        var available = 0
        while count > 0 {
            available = contextTokens - overhead - margin - answerReserve(for: count)
            if available >= count * minimumTokensPerDocument { break }
            count -= 1
        }
        guard count > 1 else {
            return FittedPrompt(documents: [], truncatedCount: 0, droppedCount: documents.count)
        }
        let describe = { (fitted: [String], truncated: Int, dropped: Int) -> FittedPrompt in
            var value = FittedPrompt(documents: fitted, truncatedCount: truncated, droppedCount: dropped)
            value.charactersPerToken = ratio
            value.ratioWasMeasured = measured
            return value
        }
        let kept = Array(documents.prefix(count))
        let needs = kept.map(tokens)
        let shares = share(available, among: needs)

        var truncated = 0
        // Сравнивается доля с запросом, а не длина с пересчитанным пределом:
        // перевод «символы → токены → символы» не круглый (3.5 символа на
        // токен), и фрагмент, влезающий целиком, терял бы на округлении
        // последнюю букву при каждом поиске.
        let fitted = zip(zip(kept, needs), shares).map { pair, share -> String in
            let (document, need) = pair
            guard share < need else { return document }
            truncated += 1
            return String(document.prefix(max(1, Int(Double(share) * ratio))))
        }
        return describe(fitted, truncated, documents.count - count)
    }

    /// Заполнение водой: у кого запрос меньше равной доли — получает свой
    /// запрос целиком, освободившееся делится между остальными.
    static func share(_ total: Int, among needs: [Int]) -> [Int] {
        var shares = [Int](repeating: 0, count: needs.count)
        var open = Array(needs.indices)
        var remaining = total
        while !open.isEmpty {
            let fair = remaining / open.count
            let modest = open.filter { needs[$0] <= fair }
            if modest.isEmpty {
                for index in open { shares[index] = fair }
                break
            }
            for index in modest {
                shares[index] = needs[index]
                remaining -= needs[index]
            }
            open.removeAll { modest.contains($0) }
        }
        return shares
    }

    /// One position of the model's answer.
    public struct Verdict: Hashable, Sendable {
        /// 1-based, as the prompt numbered them.
        public let index: Int
        public let score: Double
    }

    /// Reads the model's answer.
    ///
    /// Positions the model invented, repeated or left out are dropped here
    /// rather than in the caller: a schema guarantees the *shape* of the answer,
    /// not that the numbers in it are the ones we asked about.
    public static func verdicts(from answer: String, count: Int) throws -> [Verdict] {
        guard let data = answer.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["ranking"] as? [[String: Any]] else {
            throw RerankError.unreadableAnswer(String(answer.prefix(200)))
        }
        var seen: Set<Int> = []
        var result: [Verdict] = []
        for row in rows {
            guard let index = (row["index"] as? Int) ?? (row["index"] as? Double).map(Int.init),
                  index >= 1, index <= count, !seen.contains(index) else { continue }
            let score = (row["score"] as? Double) ?? (row["score"] as? Int).map(Double.init) ?? 0
            seen.insert(index)
            result.append(Verdict(index: index, score: score))
        }
        guard !result.isEmpty else { throw RerankError.nothingUsable }
        return result
    }

    /// The new order: what the model scored, best first, then everything it did
    /// not mention in its original order.
    ///
    /// Never dropping the unmentioned is deliberate. A model that answers about
    /// three of twenty candidates has not said the other seventeen are
    /// irrelevant — it has said nothing about them, and throwing them away would
    /// turn a lazy answer into a lost result.
    public static func reordered<T>(_ items: [T], by verdicts: [Verdict]) -> [T] {
        let sorted = verdicts.sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            return left.index < right.index
        }
        var used: Set<Int> = []
        var result: [T] = []
        for verdict in sorted {
            let position = verdict.index - 1
            guard position >= 0, position < items.count else { continue }
            used.insert(position)
            result.append(items[position])
        }
        for (position, item) in items.enumerated() where !used.contains(position) {
            result.append(item)
        }
        return result
    }
}

public enum RerankError: LocalizedError, Equatable {
    case unreadableAnswer(String)
    case nothingUsable
    case noModelChosen
    case noPlainCompleter
    /// Контекста, с которым модель загружена, не хватает даже на пару
    /// кандидатов.
    case contextTooSmall(tokens: Int)

    public var errorDescription: String? {
        switch self {
        case .unreadableAnswer(let answer):
            return String(localized: "Модель переранжирования ответила не по схеме: \(answer)")
        case .nothingUsable:
            // Самая частая причина — выбрана модель-переранжировщик (jina-reranker,
            // qwen3-reranker и подобные). LM Studio показывает их как обычные
            // llm, но они обучены отвечать оценкой пары «запрос — документ», а не
            // структурированным JSON, и на схему конвейера отвечают мимо.
            return String(localized: "Модель переранжирования не назвала ни одного из предложенных фрагментов — похоже, она не понимает схему ответа. Специализированные переранжировщики (jina-reranker, qwen3-reranker) сюда не годятся: конвейеру нужна обычная чат-модель, умеющая Structured Output.")
        case .noModelChosen:
            return String(localized: "Для переранжирования не выбрана модель.")
        case .noPlainCompleter:
            return String(localized: "Режим переранжировщика требует прямого вызова модели, а этому конвейеру он не передан.")
        case .contextTooSmall(let tokens):
            return String(localized: "Модель загружена с контекстом \(tokens) токенов — этого не хватает даже на пару фрагментов. Перезагрузите её в LM Studio с большим контекстом или выберите другую модель.")
        }
    }
}

/// Как именно переранжируется выдача.
public enum RerankMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Один вызов чат-модели со схемой: она видит все фрагменты сразу и
    /// расставляет оценки. Дёшево по числу вызовов и требует Structured Output.
    case chatSchema
    /// Специализированный переранжировщик: по вызову на фрагмент, ответ —
    /// «yes» или «no». Так устроены cross-encoder'ы вроде `qwen3-reranker`.
    case crossEncoder

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .chatSchema: return String(localized: "чат-модель по схеме (один вызов)")
        case .crossEncoder: return String(localized: "переранжировщик да/нет (вызов на фрагмент)")
        }
    }

    public var explanation: String {
        switch self {
        case .chatSchema:
            return String(localized: "Модель получает все фрагменты разом и возвращает оценки по схеме. Нужна обычная чат-модель, умеющая Structured Output.")
        case .crossEncoder:
            return String(localized: "Для каждого фрагмента отдельный вопрос «подходит ли он под запрос» и ответ да/нет. Так работают специализированные переранжировщики (qwen3-reranker и подобные), которые LM Studio отдаёт как обычные модели. Вызовов столько же, сколько фрагментов, — дороже по времени.")
        }
    }
}

/// Переранжирование специализированной моделью.
///
/// **Почему отдельный путь, а не тот же чат.** LM Studio отдаёт переранжировщики
/// как обычные `llm`, но обучены они другому: на паре «запрос — документ»
/// отвечать одним словом. Схему ответа они не понимают вовсе — попытка
/// применить к ним путь `.chatSchema` заканчивается «модель не назвала ни одного
/// фрагмента». Проверено на живой LM Studio: `qwen3-reranker-0.6b` по этому
/// промпту отвечает верно на всех проверенных парах, а через
/// `/v1/chat/completions` — «No document is provided», потому что шаблон чата
/// модели ломает разметку промпта. Поэтому запрос идёт в `/v1/completions`
/// сырым текстом, с разметкой, которую ждёт сама модель.
public enum CrossEncoderReranker {
    /// Инструкция по умолчанию — та же формулировка, что в карточке Qwen3-Reranker.
    public static let defaultInstruction =
        "Given a web search query, retrieve relevant passages that answer the query"

    /// Цена этого режима — не «один вызов на запрос», а вызов на каждый
    /// кандидат. Говорится до включения, а не после (правило 4 Приложения 5).
    public static let costWarning = String(localized: """
    Переранжировщик спрашивается отдельно про каждый фрагмент: до \
    \(Reranker.maximumCandidates) вызовов модели на один запрос, один за другим. \
    Это дороже по времени, чем режим чат-схемы, но иначе такая модель отвечать \
    не умеет.
    """)

    /// Инструкция, приведённая к рабочему виду: пустая строка означает
    /// «стандартная», а переносы строк ломают разметку `<Instruct>:` —
    /// она однострочная.
    public static func instruction(from text: String) -> String {
        let flattened = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.isEmpty ? defaultInstruction : flattened
    }

    /// Сколько текста фрагмента уходит в промпт.
    ///
    /// Предел существует не ради контекста модели — у `qwen3-reranker-0.6b` его
    /// 40960 токенов, и один фрагмент туда влезает с любым запасом, — а ради
    /// времени: вызовов столько же, сколько кандидатов, и каждый лишний
    /// килобайт умножается на двадцать. Значение подобрано по собственным
    /// умолчаниям приложения: чанк в 512 токенов — это 1792 символа, чанк
    /// в 1024 токена — 3584 (`TokenEstimator.charactersPerToken` = 3.5).
    /// Обрезка на 1200 разрезала бы обычный чанк на треть, поэтому предел
    /// поднят так, чтобы оба размера уходили целиком; режется только то, что
    /// чанком не является — например, документ, положенный в базу одним куском.
    public static let documentLimit = 4_000

    /// Сколько символов фрагмента влезает на самом деле: обычный предел или
    /// контекст модели, смотря что меньше. Один вызов — один фрагмент,
    /// поэтому делить место не с кем; вычитается только разметка и ответ.
    public static func documentLimit(
        contextTokens: Int?,
        charactersPerToken ratio: Double = TokenEstimator.pessimisticCharactersPerToken
    ) -> Int {
        guard let contextTokens, contextTokens > 0 else { return documentLimit }
        let overhead = TokenEstimator.estimatedTokens(
            prompt(query: "", document: ""), charactersPerToken: ratio
        )
        let margin = Int((Double(contextTokens) * Reranker.safetyFraction).rounded(.up))
        let available = contextTokens - overhead - margin - answerTokens
        guard available > 0 else { return 0 }
        return min(documentLimit, max(1, Int(Double(available) * ratio)))
    }

    /// Ответ — одно слово; четырёх токенов хватает и на «yes», и на «No, I».
    public static let answerTokens = 4

    public static func prompt(
        query: String, document: String,
        instruction: String = defaultInstruction,
        contextTokens: Int? = nil,
        charactersPerToken: Double = TokenEstimator.pessimisticCharactersPerToken
    ) -> String {
        let limit = documentLimit(contextTokens: contextTokens, charactersPerToken: charactersPerToken)
        let text = document.count > limit
            ? String(document.prefix(limit))
            : document
        return """
        <|im_start|>system
        Judge whether the Document meets the requirements based on the Query and the Instruct provided. \
        Note that the answer can only be "yes" or "no".<|im_end|>
        <|im_start|>user
        <Instruct>: \(instruction)
        <Query>: \(query)
        <Document>: \(text)<|im_end|>
        <|im_start|>assistant
        <think>

        </think>


        """
    }

    /// Ответ модели как решение. `nil` — ответ не понят: это не «нет», и
    /// считать его отказом значило бы молча выбросить фрагмент.
    public static func verdict(_ answer: String) -> Bool? {
        let trimmed = answer
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let first = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).first
        else { return nil }
        switch first {
        case "yes", "да", "true", "1": return true
        case "no", "нет", "false", "0": return false
        default: return nil
        }
    }

    /// Порядок после переранжирования: подошедшие впереди, и **внутри групп
    /// прежний порядок сохраняется**.
    ///
    /// Ответ «да/нет» не даёт градаций, и выдумывать их нельзя. Значит, всё, что
    /// эта стадия вправе сделать, — поднять подошедшие над остальными, не трогая
    /// то, что уже нашли предыдущие стадии.
    public static func reordered<T>(_ items: [T], verdicts: [Bool?]) -> [T] {
        let paired = zip(items, verdicts + Array(repeating: nil, count: max(0, items.count - verdicts.count)))
        let accepted = paired.filter { $0.1 == true }.map(\.0)
        let rest = paired.filter { $0.1 != true }.map(\.0)
        return accepted + rest
    }
}
