import Foundation

public enum ChunkStrategy: String, Codable, CaseIterable, Identifiable, Sendable {
    case fixed
    case recursive
    case documentBased
    case hierarchical
    case semantic
    case adaptive
    case llmBased
    // Late chunking is absent by design: it needs token-level embeddings, which
    // the OpenAI-compatible API of LM Studio does not expose.

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fixed: return "Fixed-size"
        case .recursive: return "Recursive"
        case .documentBased: return "Document-based"
        case .hierarchical: return "Hierarchical"
        case .semantic: return "Semantic"
        case .adaptive: return "Adaptive"
        case .llmBased: return "LLM-based"
        }
    }

    public var summary: String {
        switch self {
        case .fixed:
            return "Разбиение по фиксированному размеру с перекрытием. Предсказуемо и быстро; границы могут рвать предложения."
        case .recursive:
            return "Пытается резать по естественным границам — абзацы → строки → предложения → слова, — пока чанк не уложится в лимит."
        case .documentBased:
            return "Резать по структуре документа: оглавление, если экстрактор его нашёл (PDF, EPUB, Word), иначе заголовки Markdown, теги HTML, границы функций и классов в коде."
        case .hierarchical:
            return "Крупные родительские чанки плюс мелкие дочерние. Живут в одной коллекции, связаны полем parent_chunk_id и различаются chunk_level. Если у документа есть оглавление, родителями становятся его разделы."
        case .semantic:
            return "Эмбеддинг каждого предложения, разрыв там, где смысл резко меняется. Границы получаются осмысленными, но каждое предложение стоит отдельного вызова модели."
        case .adaptive:
            return "Размер подстраивается под плотность текста по эвристикам: длина предложений, доля пунктуации и чисел."
        case .llmBased:
            return "Границы чанков определяет чат-модель LM Studio. Самая медленная и самая дорогая стратегия."
        }
    }

    public var recommendation: String {
        switch self {
        case .fixed: return "Когда использовать: однородный текст, логи, transcript'ы без выраженной структуры."
        case .recursive: return "Когда использовать: обычные документы, Markdown, статьи. Разумный выбор по умолчанию."
        case .documentBased: return "Когда использовать: документация с заголовками, PDF и книги с оглавлением, HTML-страницы, исходный код."
        case .hierarchical: return "Когда использовать: длинные документы, где нужен и точный фрагмент, и его контекст."
        case .semantic: return "Когда использовать: разнородные тексты без структуры, где важна точность границ и не жаль времени."
        case .adaptive: return "Когда использовать: смесь плотных таблиц и разреженной прозы в одной папке."
        case .llmBased: return "Когда использовать: небольшие важные наборы, где качество границ важнее скорости."
        }
    }

    /// Needs a chat model in LM Studio, not just an embedding one.
    public var requiresChatModel: Bool { self == .llmBased }

    /// Produces parent and child chunks instead of a flat list.
    public var producesLevels: Bool { self == .hierarchical }

    /// Warning shown in the UI **before** a run, not after it.
    public var costWarning: String? {
        switch self {
        case .semantic:
            return String(localized: "Стратегия делает отдельный вызов эмбеддинга на каждое предложение — на большом источнике это ощутимо дольше остальных.")
        case .llmBased:
            return String(localized: "Каждый фрагмент текста проходит через чат-модель: это заметно медленнее и дороже по времени, чем любая другая стратегия. Проверьте её на одном файле, прежде чем запускать на всей папке.")
        default:
            return nil
        }
    }
}

/// What Document-based treats the file as.
public enum DocumentSourceFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case markdown
    case html
    case code

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return String(localized: "автоопределение по расширению")
        case .markdown: return "Markdown"
        case .html: return "HTML"
        case .code: return String(localized: "код")
        }
    }

    /// Resolves `auto` by file extension; unknown extensions read as Markdown,
    /// which degrades to "split on headings if there are any" and is harmless.
    public static func resolved(_ format: DocumentSourceFormat, fileExtension: String?) -> DocumentSourceFormat {
        guard format == .auto else { return format }
        switch (fileExtension ?? "").lowercased() {
        case "html", "htm", "xhtml": return .html
        case "swift", "py", "js", "ts", "tsx", "jsx", "java", "kt", "go", "rs", "c", "h", "cpp", "hpp", "m", "mm", "rb", "php", "cs", "sh":
            return .code
        default: return .markdown
        }
    }
}

public enum CodeSplitTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case functions
    case classes
    case both

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .functions: return String(localized: "функции")
        case .classes: return String(localized: "классы и типы")
        case .both: return String(localized: "и функции, и классы")
        }
    }
}

/// What to do with a structural section that came out too big.
public enum OversizedSectionFallback: String, Codable, CaseIterable, Identifiable, Sendable {
    case keep
    case fixed
    case recursive

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .keep: return String(localized: "не делить")
        case .fixed: return "Fixed-size"
        case .recursive: return "Recursive"
        }
    }
}

public enum SemanticThresholdMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case percentile
    case absolute

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .percentile: return String(localized: "перцентиль расстояний")
        case .absolute: return String(localized: "абсолютное расстояние")
        }
    }
}

public enum LLMGranularity: String, Codable, CaseIterable, Identifiable, Sendable {
    case atomic
    case topical
    case logical

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .atomic: return String(localized: "атомарные утверждения")
        case .topical: return String(localized: "тематические разделы")
        case .logical: return String(localized: "логические блоки")
        }
    }

    /// Default prompt per mode. Editable in the UI — this is only the starting point.
    ///
    /// Модель получает текст пронумерованными предложениями и отвечает
    /// **номерами** границ: куски вырезаются из исходника, и
    /// переписать, сократить или выдумать текст модели нечем. Шаблон со
    /// старой подстановкой `{{TEXT}}`, просящий фрагменты текстом, тоже
    /// работает — его фрагменты сверяются с исходником.
    public var defaultPrompt: String {
        let task: String
        switch self {
        case .atomic:
            task = "Раздели текст на атомарные утверждения: каждый фрагмент — одна законченная мысль, понятная без соседних."
        case .topical:
            task = "Раздели текст на тематические разделы: смена темы — граница фрагмента."
        case .logical:
            task = "Раздели текст на логические блоки: вступление, аргументы, выводы, примеры, определения."
        }
        return """
        Ниже текст, разбитый на пронумерованные предложения.
        \(task)
        Назови номера предложений, с которых начинается каждый фрагмент, кроме первого. Сам текст не переписывай.
        Ответь только JSON без пояснений: {"starts": [номер, номер]}. Если весь текст — один фрагмент, ответь {"starts": []}.

        Текст:
        {{NUMBERED_TEXT}}
        """
    }
}

public enum MalformedOutputPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Retry up to `llmMaxRetries`, then give up with an error.
    case retryThenFail
    /// Retry, then fall back to Recursive and mark those chunks.
    case fallbackToRecursive

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .retryThenFail: return String(localized: "повторить и сообщить об ошибке")
        case .fallbackToRecursive: return String(localized: "откатиться на Recursive с пометкой")
        }
    }
}

public enum SizeUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case tokens
    case characters

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .tokens: return "токены (приблизительно)"
        case .characters: return "символы"
        }
    }
}

/// Parameters of the chunking step, stored per data source.
///
/// One flat struct for every strategy: only the fields of the chosen strategy
/// are shown in the UI and only they take part in `signature`, so switching
/// strategies back and forth does not lose what was typed for the other one.
public struct ChunkingConfiguration: Codable, Hashable, Sendable {
    public var strategy: ChunkStrategy
    public var chunkSize: Int
    public var sizeUnit: SizeUnit
    /// Overlap as a percentage of `chunkSize` (spec default: 15%).
    public var overlapPercent: Double
    /// Ordered separators for the recursive strategy.
    public var separators: [String]

    /// Дописывать ли перед текстом чанка строку «Документ → Раздел →
    /// Подраздел» **перед вычислением вектора**.
    ///
    /// Почти бесплатно и заметно помогает: чанк «превышение допустимого
    /// значения приводит к отказу» сам по себе бесполезен — в базе на десять
    /// тысяч документов он не находится ничем, потому что в нём нет ни одного
    /// слова о том, о чём он.
    ///
    /// **В вектор, но не в текст документа.** Иначе человек и агент читали бы
    /// служебную строку в каждом результате, а `content_hash` считался бы
    /// от строки, которой в файле нет.
    ///
    /// Выключено по умолчанию: включение меняет содержимое коллекции,
    /// то есть требует переиндексации, и решать это должен человек.
    public var contextPrefix: Bool

    /// Дописывать ли перед текстом чанка одно-два предложения, **написанные
    /// чат-моделью**: о чём документ и где в нём этот фрагмент.
    ///
    /// То же, что `contextPrefix`, но дороже и умнее. Структурная строка берёт
    /// заголовки — она бесплатна и молчит там, где заголовков нет; здесь
    /// модель читает сам фрагмент и говорит, о чём он.
    ///
    /// **Цена — один вызов чат-модели на чанк.** На коллекции в десять тысяч
    /// чанков это часы работы локальной модели, поэтому опция выключена по
    /// умолчанию, а экран обязан показать оценку до запуска: сколько вызовов
    /// и сколько это займёт.
    ///
    /// В вектор, но не в текст документа — по тому же правилу.
    public var contextEnrichment: Bool
    /// Модель для обогащения. Пусто — берётся `chatModel` источника.
    public var enrichmentModel: String?

    /// До какой длины в знаках может дорасти чанк при этих настройках
    ///. `nil` — предела нет вовсе.
    ///
    /// Нужно, чтобы форма могла сказать «этот размер больше того, что модель
    /// читает», **до** прогона, а не после него. Считается по той настройке,
    /// которая ограничивает размер у выбранной стратегии, — у каждой она своя,
    /// и общего «максимума чанка» в конфигурации нет.
    public var largestChunkCharacters: Int? {
        switch strategy {
        case .fixed, .recursive:
            return chunkSizeInCharacters
        case .documentBased:
            // «Не делить» — размер секции ничем не ограничен: сколько нашлось
            // между заголовками, столько и уйдёт в модель.
            return oversizedFallback == .keep ? nil : maxSectionSizeInCharacters
        case .hierarchical:
            // Родитель крупнее ребёнка по построению — по нему и считаем.
            return max(parentSizeInCharacters, childSizeInCharacters)
        case .semantic, .adaptive:
            return maxSizeInCharacters
        case .llmBased:
            // Границы расставляет чат-модель, и предел ей не задан ничем:
            // сколько она вернёт одним фрагментом, столько и будет.
            return nil
        }
    }

    /// Какой моделью пойдёт обогащение — одним ответом для экрана и прогона.
    ///
    /// Пустая строка здесь равна `nil`: поле обещает откат к `chatModel`,
    /// и «выбрана пустая модель» — это не выбор. Считается в одном месте,
    /// потому что экран, называющий одну модель, и прогон, зовущий другую,
    /// расходятся молча.
    public var resolvedEnrichmentModel: String? {
        [enrichmentModel, chatModel]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// Модель предложений Semantic, если она задана. Пустая строка
    /// равна «не задана» тем же правилом, что у обогащения: иначе очищенное
    /// поле не откатывалось к модели источника, и каждый файл падал с «нет
    /// эмбеддинг-модели».
    public var resolvedSentenceModel: String? {
        sentenceEmbeddingModel.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    // Document-based
    public var sourceFormat: DocumentSourceFormat
    /// Markdown heading level to split on: 2 means `##`.
    public var splitHeaderLevel: Int
    public var splitTags: [String]
    public var codeSplitBy: CodeSplitTarget
    /// A structural section bigger than this is handed to `oversizedFallback`.
    public var maxSectionSize: Int
    public var oversizedFallback: OversizedSectionFallback

    // Hierarchical
    public var levels: Int
    public var parentChunkSize: Int
    public var childChunkSize: Int
    public var parentOverlapPercent: Double
    public var childOverlapPercent: Double

    // Semantic
    public var thresholdMode: SemanticThresholdMode
    /// Percentile (0–100) or absolute cosine distance, depending on the mode.
    public var thresholdValue: Double
    /// Sentences on each side included when measuring the change of meaning.
    public var sentenceBuffer: Int
    /// Shared by Semantic and Adaptive: both clamp the result to this range.
    public var minChunkSize: Int
    public var maxChunkSize: Int
    /// Model used for sentence vectors; `nil` means the source's own model.
    public var sentenceEmbeddingModel: String?

    // Adaptive
    public var baseChunkSize: Int
    /// 0…1: how strongly text density moves the chunk size.
    public var sensitivity: Double

    // LLM-based
    public var chatModel: String?
    public var granularity: LLMGranularity
    public var promptTemplate: String
    /// Part G: the whole generation block, not just temperature. Shared type,
    /// because G0 forbids one global panel and demands one reusable component.
    public var generation: ChatGenerationSettings
    /// use a JSON schema when the model supports one. Kept as a switch so a
    /// model with partial support can be forced onto the fallback parser.
    public var useStructuredOutput: Bool

    /// Kept as an accessor so existing forms and call sites read the same way;
    /// the value itself lives in `generation`.
    public var temperature: Double {
        get { generation.temperature }
        set { generation.temperature = newValue }
    }
    public var llmMaxRetries: Int
    public var onMalformedOutput: MalformedOutputPolicy
    /// Hard cap per call, so one stuck answer cannot hang a whole sync.
    public var llmTimeout: TimeInterval

    public init(
        strategy: ChunkStrategy = .recursive,
        chunkSize: Int = 512,
        sizeUnit: SizeUnit = .tokens,
        overlapPercent: Double = ChunkingConfiguration.defaultOverlapPercent,
        separators: [String] = ChunkingConfiguration.defaultSeparators,
        contextPrefix: Bool = false,
        contextEnrichment: Bool = false,
        enrichmentModel: String? = nil,
        sourceFormat: DocumentSourceFormat = .auto,
        splitHeaderLevel: Int = 2,
        splitTags: [String] = ["section", "article"],
        codeSplitBy: CodeSplitTarget = .both,
        maxSectionSize: Int = 2048,
        oversizedFallback: OversizedSectionFallback = .recursive,
        levels: Int = 2,
        parentChunkSize: Int = 2048,
        childChunkSize: Int = 512,
        parentOverlapPercent: Double = 10,
        childOverlapPercent: Double = 15,
        thresholdMode: SemanticThresholdMode = .percentile,
        thresholdValue: Double = 95,
        sentenceBuffer: Int = 1,
        minChunkSize: Int = 128,
        maxChunkSize: Int = 2048,
        sentenceEmbeddingModel: String? = nil,
        baseChunkSize: Int = 512,
        sensitivity: Double = 0.5,
        chatModel: String? = nil,
        granularity: LLMGranularity = .topical,
        promptTemplate: String = "",
        // deterministic by default — the boundaries of a chunk are not a
        // place for creativity, and a re-run has to give the same collection.
        generation: ChatGenerationSettings = ChatGenerationSettings(),
        useStructuredOutput: Bool = true,
        llmMaxRetries: Int = 2,
        onMalformedOutput: MalformedOutputPolicy = .fallbackToRecursive,
        llmTimeout: TimeInterval = 120
    ) {
        self.strategy = strategy
        self.chunkSize = chunkSize
        self.sizeUnit = sizeUnit
        self.overlapPercent = overlapPercent
        self.separators = separators
        self.contextPrefix = contextPrefix
        self.contextEnrichment = contextEnrichment
        self.enrichmentModel = enrichmentModel
        self.sourceFormat = sourceFormat
        self.splitHeaderLevel = splitHeaderLevel
        self.splitTags = splitTags
        self.codeSplitBy = codeSplitBy
        self.maxSectionSize = maxSectionSize
        self.oversizedFallback = oversizedFallback
        self.levels = levels
        self.parentChunkSize = parentChunkSize
        self.childChunkSize = childChunkSize
        self.parentOverlapPercent = parentOverlapPercent
        self.childOverlapPercent = childOverlapPercent
        self.thresholdMode = thresholdMode
        self.thresholdValue = thresholdValue
        self.sentenceBuffer = sentenceBuffer
        self.minChunkSize = minChunkSize
        self.maxChunkSize = maxChunkSize
        self.sentenceEmbeddingModel = sentenceEmbeddingModel
        self.baseChunkSize = baseChunkSize
        self.sensitivity = sensitivity
        self.chatModel = chatModel
        self.granularity = granularity
        self.promptTemplate = promptTemplate
        self.generation = generation
        self.useStructuredOutput = useStructuredOutput
        self.llmMaxRetries = llmMaxRetries
        self.onMalformedOutput = onMalformedOutput
        self.llmTimeout = llmTimeout
    }

    /// Tolerant decoding: a source configured by an earlier build has none of the
    /// 2D keys, and losing its chunk size to a default would silently re-chunk
    /// the whole folder on the next sync.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ChunkingConfiguration()
        func value<T: Decodable>(_ key: CodingKeys, _ default: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? `default`
        }
        strategy = value(.strategy, fallback.strategy)
        chunkSize = value(.chunkSize, fallback.chunkSize)
        sizeUnit = value(.sizeUnit, fallback.sizeUnit)
        overlapPercent = value(.overlapPercent, fallback.overlapPercent)
        separators = value(.separators, fallback.separators)
        contextPrefix = value(.contextPrefix, fallback.contextPrefix)
        contextEnrichment = value(.contextEnrichment, fallback.contextEnrichment)
        enrichmentModel = value(.enrichmentModel, fallback.enrichmentModel)
        sourceFormat = value(.sourceFormat, fallback.sourceFormat)
        splitHeaderLevel = value(.splitHeaderLevel, fallback.splitHeaderLevel)
        splitTags = value(.splitTags, fallback.splitTags)
        codeSplitBy = value(.codeSplitBy, fallback.codeSplitBy)
        maxSectionSize = value(.maxSectionSize, fallback.maxSectionSize)
        oversizedFallback = value(.oversizedFallback, fallback.oversizedFallback)
        levels = value(.levels, fallback.levels)
        parentChunkSize = value(.parentChunkSize, fallback.parentChunkSize)
        childChunkSize = value(.childChunkSize, fallback.childChunkSize)
        parentOverlapPercent = value(.parentOverlapPercent, fallback.parentOverlapPercent)
        childOverlapPercent = value(.childOverlapPercent, fallback.childOverlapPercent)
        thresholdMode = value(.thresholdMode, fallback.thresholdMode)
        thresholdValue = value(.thresholdValue, fallback.thresholdValue)
        sentenceBuffer = value(.sentenceBuffer, fallback.sentenceBuffer)
        minChunkSize = value(.minChunkSize, fallback.minChunkSize)
        maxChunkSize = value(.maxChunkSize, fallback.maxChunkSize)
        sentenceEmbeddingModel = try? container.decodeIfPresent(String.self, forKey: .sentenceEmbeddingModel)
        baseChunkSize = value(.baseChunkSize, fallback.baseChunkSize)
        sensitivity = value(.sensitivity, fallback.sensitivity)
        chatModel = try? container.decodeIfPresent(String.self, forKey: .chatModel)
        granularity = value(.granularity, fallback.granularity)
        promptTemplate = value(.promptTemplate, fallback.promptTemplate)
        // A configuration written before part G has a flat `temperature` and no
        // generation block; its value is carried across rather than lost, so an
        // existing source keeps chunking the way it did.
        if let stored = ((try? container.decodeIfPresent(ChatGenerationSettings.self, forKey: .generation)) ?? nil) {
            generation = stored
        } else {
            var carried = fallback.generation
            let legacy = try? decoder.container(keyedBy: LegacyChunkingKeys.self)
            if let value = ((try? legacy?.decodeIfPresent(Double.self, forKey: .temperature)) ?? nil) {
                carried.temperature = value
            }
            generation = carried
        }
        useStructuredOutput = value(.useStructuredOutput, fallback.useStructuredOutput)
        llmMaxRetries = value(.llmMaxRetries, fallback.llmMaxRetries)
        onMalformedOutput = value(.onMalformedOutput, fallback.onMalformedOutput)
        llmTimeout = value(.llmTimeout, fallback.llmTimeout)
    }

    /// Prompt actually sent: the edited template, or the default for the mode.
    public var effectivePrompt: String {
        let trimmed = promptTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? granularity.defaultPrompt : promptTemplate
    }

    /// Chunk size expressed in characters — the unit chunkers actually work in.
    public var chunkSizeInCharacters: Int {
        switch sizeUnit {
        case .characters: return max(32, chunkSize)
        case .tokens: return max(32, TokenEstimator.characters(forTokens: chunkSize))
        }
    }

    public var overlapInCharacters: Int {
        let value = Double(chunkSizeInCharacters) * max(0, min(overlapPercent, 90)) / 100.0
        return Int(value.rounded())
    }

    /// Stable description of everything that affects the resulting chunks.
    ///
    /// Stored in the manifest: when it changes, a file has to be re-chunked even
    /// though its bytes are untouched, and that is not visible any other way.
    public var signature: String {
        let unit = sizeUnit == .tokens ? "t" : "c"
        var parts = [strategy.rawValue]
        // Размер в токенах переводится в знаки этим числом: его смена
        // сдвигает границы всех кусков, и подпись обязана это видеть.
        if sizeUnit == .tokens { parts.append("cpt\(TokenEstimator.charactersPerToken)") }
        // контекстный префикс меняет то, что уходит в модель, при любой
        // стратегии — значит это часть рецепта коллекции, а не настройка
        // показа.
        if contextPrefix { parts.append("ctx") }
        // Обогащение стоит вызова модели на чанк — оно обязано быть видно
        // в строке настроек источника, а не только в форме.
        // Модель, пишущая контекст, — часть рецепта: её строка
        // уходит в вектор, и смена модели без новой подписи смешала бы
        // в коллекции векторы двух моделей.
        if contextEnrichment {
            parts.append(resolvedEnrichmentModel.map { "ctx+llm:\($0)" } ?? "ctx+llm")
        }

        switch strategy {
        case .fixed:
            parts += ["\(chunkSize)\(unit)", "ov\(Int(overlapPercent.rounded()))"]
        case .recursive:
            parts += ["\(chunkSize)\(unit)", "ov\(Int(overlapPercent.rounded()))"]
            // Separators are part of the recipe only for the recursive strategy.
            parts.append("sep:" + separators.joined(separator: "|"))
        case .documentBased:
            parts += [
                "fmt:\(sourceFormat.rawValue)",
                "h\(splitHeaderLevel)",
                "tags:" + splitTags.joined(separator: ","),
                "code:\(codeSplitBy.rawValue)",
                "max\(maxSectionSize)\(unit)",
                "over:\(oversizedFallback.rawValue)",
            ]
            if oversizedFallback == .recursive {
                parts.append("sep:" + separators.joined(separator: "|"))
            }
        case .hierarchical:
            parts += [
                "lv\(levels)",
                "p\(parentChunkSize)\(unit)", "pov\(Int(parentOverlapPercent.rounded()))",
                "c\(childChunkSize)\(unit)", "cov\(Int(childOverlapPercent.rounded()))",
            ]
        case .semantic:
            parts += [
                "th:\(thresholdMode.rawValue)\(thresholdSignature)",
                "buf\(sentenceBuffer)",
                "min\(minChunkSize)\(unit)", "max\(maxChunkSize)\(unit)",
                "sm:\(resolvedSentenceModel ?? "source")",
            ]
        case .adaptive:
            parts += [
                "base\(baseChunkSize)\(unit)",
                "min\(minChunkSize)\(unit)", "max\(maxChunkSize)\(unit)",
                "sens\(String(format: "%.2f", sensitivity))",
                "ov\(Int(overlapPercent.rounded()))",
            ]
        case .llmBased:
            parts += [
                "model:\(chatModel ?? "-")",
                "gran:\(granularity.rawValue)",
                // every generation parameter shapes the boundaries, so the
                // whole block is part of the recipe — not temperature alone.
                "gen:\(generation.signature)",
                "so:\(useStructuredOutput ? 1 : 0)",
                "max\(maxChunkSize)\(unit)",
                // The prompt shapes the chunks, so an edited prompt is a new recipe.
                "prompt:\(Self.shortHash(effectivePrompt))",
            ]
        }
        // Разделители и перекрытие, которыми режут и эти стратегии, — через
        // запасную или вложенную рекурсивную нарезку. Их правка в форме
        // меняет чанки, а подпись о ней не знала: неизменённые файлы не
        // перенарезались, и коллекция молча становилась смешанной.
        //
        // Дописываются **только отличные от умолчания**: иначе подпись
        // сменилась бы у каждого такого источника разом, и обновление
        // приложения перенарезало бы всё, где ничего не меняли.
        let customSeparators = separators != Self.defaultSeparators
        let customOverlap = overlapPercent.rounded() != Self.defaultOverlapPercent.rounded()
        switch strategy {
        case .hierarchical, .adaptive:
            if customSeparators { parts.append("sep:" + separators.joined(separator: "|")) }
        case .llmBased:
            if customSeparators { parts.append("sep:" + separators.joined(separator: "|")) }
            if customOverlap { parts.append("ov\(Int(overlapPercent.rounded()))") }
        case .documentBased:
            if customOverlap { parts.append("ov\(Int(overlapPercent.rounded()))") }
        case .fixed, .recursive, .semantic:
            break
        }
        return parts.joined(separator: "/")
    }

    public static let defaultSeparators = ["\n\n", "\n", ". ", " "]
    public static let defaultOverlapPercent: Double = 15

    /// Порог семантической нарезки в подписи.
    ///
    /// Перцентиль и отклонения — целые числа, и их запись осталась прежней.
    /// Абсолютное расстояние лежит между нулём и единицей: округлённое
    /// до целого, оно давало «0» и для 0.20, и для 0.40 — смена порога
    /// подпись не меняла.
    var thresholdSignature: String {
        thresholdMode == .absolute
            ? String(format: "%.3f", thresholdValue)
            : "\(Int(thresholdValue.rounded()))"
    }

    /// Short digest for parts of the signature that would otherwise be long.
    static func shortHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in Data(text.utf8) {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    /// Human-readable parameters for the source card.
    public var summaryText: String {
        let unit = sizeUnit == .tokens ? String(localized: "≈токенов") : String(localized: "символов")
        switch strategy {
        case .fixed, .recursive:
            return "\(strategy.title) · \(chunkSize) \(unit) · перекрытие \(Int(overlapPercent.rounded()))%"
        case .documentBased:
            return "\(strategy.title) · \(sourceFormat.title) · секции до \(maxSectionSize) \(unit) · крупные: \(oversizedFallback.title)"
        case .hierarchical:
            return "\(strategy.title) · родитель \(parentChunkSize) / ребёнок \(childChunkSize) \(unit)"
        case .semantic:
            // Порог — как в подписи: абсолютное расстояние до целого
            // округлялось в 0 или 1, и смена порога на карточке не была видна.
            let threshold = thresholdMode == .absolute ? String(format: "%.2f", thresholdValue) : thresholdSignature
            return "\(strategy.title) · \(thresholdMode.title) \(threshold) · \(minChunkSize)–\(maxChunkSize) \(unit)"
        case .adaptive:
            return "\(strategy.title) · база \(baseChunkSize) \(unit) · \(minChunkSize)–\(maxChunkSize) · чувствительность \(String(format: "%.1f", sensitivity))"
        case .llmBased:
            return "\(strategy.title) · \(chatModel ?? "модель не выбрана") · \(granularity.title)"
        }
    }

    /// Размер куска в знаках, в который обязан уложиться кусок таблицы
    /// вместе с дописанной шапкой, или `nil`, если кусок делить
    /// нельзя.
    ///
    /// - Структурная стратегия с запасным путём «оставить как есть» — раздел
    ///   длиннее предела человек велел оставить целым.
    /// - Родитель иерархической нарезки — контекст своих детей: разделённый,
    ///   он оставлял детей второй половины с чужим `parent_chunk_id` и без
    ///   места в документе. Предел модели за ним всё равно следит
    ///   (`OversizeChunks`).
    public func characterLimit(of chunk: TextChunk) -> Int? {
        switch strategy {
        case .fixed, .recursive: return chunkSizeInCharacters
        case .documentBased: return oversizedFallback == .keep ? nil : maxSectionSizeInCharacters
        case .hierarchical: return chunk.level > 0 ? nil : childSizeInCharacters
        case .adaptive, .semantic, .llmBased: return maxSizeInCharacters
        }
    }

    /// Sizes in characters, which is the unit chunkers actually work in.
    public var parentSizeInCharacters: Int { converted(parentChunkSize) }
    public var childSizeInCharacters: Int { converted(childChunkSize) }
    public var minSizeInCharacters: Int { converted(minChunkSize) }
    public var maxSizeInCharacters: Int { converted(maxChunkSize) }
    public var baseSizeInCharacters: Int { converted(baseChunkSize) }
    public var maxSectionSizeInCharacters: Int { converted(maxSectionSize) }

    private func converted(_ value: Int) -> Int {
        switch sizeUnit {
        case .characters: return max(32, value)
        case .tokens: return max(32, TokenEstimator.characters(forTokens: value))
        }
    }

    public func overlapInCharacters(percent: Double, of size: Int) -> Int {
        Int((Double(size) * max(0, min(percent, 90)) / 100.0).rounded())
    }

    /// A rough count for one file's worth of text, used only for the sync
    /// preview's "≈X чанков". Real chunking depends on where natural
    /// boundaries fall — and for `semantic`/`adaptive`/`llmBased`, on the
    /// model — so this is a size-based approximation, never presented as exact.
    public func estimatedChunkCount(forCharacters characters: Int) -> Int {
        guard characters > 0 else { return 0 }
        func count(step size: Int) -> Int {
            let effective = max(1, size)
            return max(1, Int((Double(characters) / Double(effective)).rounded(.up)))
        }
        switch strategy {
        case .fixed, .recursive:
            return count(step: max(1, chunkSizeInCharacters - overlapInCharacters))
        case .documentBased:
            return count(step: maxSectionSizeInCharacters)
        case .hierarchical:
            // Parents and children both land in the collection as chunks.
            return count(step: parentSizeInCharacters) + count(step: childSizeInCharacters)
        case .semantic, .adaptive:
            return count(step: (minSizeInCharacters + maxSizeInCharacters) / 2)
        case .llmBased:
            return count(step: maxSizeInCharacters)
        }
    }

    /// Problems that must be fixed before a sync can start.
    public var problem: String? {
        if strategy.requiresChatModel, (chatModel ?? "").isEmpty {
            return String(localized: "Для LLM-based нужно выбрать чат-модель.")
        }
        if strategy == .hierarchical, childChunkSize >= parentChunkSize {
            return String(localized: "Дочерний чанк должен быть меньше родительского.")
        }
        if (strategy == .semantic || strategy == .adaptive), minChunkSize >= maxChunkSize {
            return String(localized: "Минимальный размер чанка должен быть меньше максимального.")
        }
        if strategy == .documentBased, sourceFormat == .html, splitTags.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return String(localized: "Укажите хотя бы один тег для разбиения HTML.")
        }
        return nil
    }
}

public struct TextChunk: Hashable {
    public let index: Int
    public let text: String
    /// 0 for a plain or child chunk, 1 for a hierarchical parent.
    public var level: Int
    /// Index of the parent chunk of the same file, for hierarchical chunking.
    public var parentIndex: Int?
    /// Set when the chunk did not come from the chosen strategy — currently only
    /// "the chat model answered with nonsense, this is the Recursive fallback".
    public var note: String?
    /// Сколько знаков в начале куска — дописанная шапка таблицы: её
    /// в этом месте файла нет. По этой мере `get_file` убирает шапку на швах,
    /// где читатель её только что видел. Ноль — ничего не дописано.
    ///
    /// Не в инициализаторе: кусок с другим текстом обязан начинаться с нуля,
    /// и каждое пересоздание куска так и делает — мера переживает только
    /// перенумерацию (`renumbered`).
    public var repeatedHeaderLength = 0

    public init(index: Int, text: String, level: Int = 0, parentIndex: Int? = nil, note: String? = nil) {
        self.index = index
        self.text = text
        self.level = level
        self.parentIndex = parentIndex
        self.note = note
    }

    public var estimatedTokens: Int { TokenEstimator.estimatedTokens(text) }

    /// Тот же кусок под другим номером — с мерой дописанной шапки.
    public func renumbered(_ index: Int, parentIndex: Int?) -> TextChunk {
        var copy = TextChunk(index: index, text: text, level: level, parentIndex: parentIndex, note: note)
        copy.repeatedHeaderLength = repeatedHeaderLength
        return copy
    }
}

public protocol Chunking {
    func chunks(from text: String) -> [TextChunk]
}

/// LM Studio does not expose the model's tokenizer over the OpenAI-compatible
/// API, so token counts in the UI are an estimate and labelled as such.
public enum TokenEstimator {
    /// Знаков русского текста на токен — у токенизатора Qwen3.
    ///
    /// Было 3.5, и «512 токенов» в форме превращались в 1792 знака ≈ 669
    /// настоящих токенов — на 31 % больше заказанного. Замер токенизатором
    /// Qwen3 на корпусе пользователя (82 документа): 2.78 знака на токен по
    /// всему тексту, 2.29 — медиана по файлам (таблицы и цифры дробятся
    /// мельче), 2.02–2.95 между десятым и девяностым процентилем; на русской
    /// Википедии — 2.68. Взято 2.6: «512 токенов» — 1331 знак, около 510
    /// настоящих токенов на прозе и до 660 на таблицах.
    ///
    /// Константа переводит **настройку** в знаки, поэтому её правка сдвигает
    /// границы кусков у всех источников в токенах. Чтобы коллекция не
    /// набралась смесью старой и новой нарезки, она входит в подпись нарезки
    /// (`ChunkingConfiguration.signature`): такие источники перенарезаются
    /// целиком. Точно знает размер только единица «знаки» — у эндпойнта
    /// эмбеддингов LM Studio `usage.prompt_tokens` равен нулю.
    ///
    /// Там, где ошибка опасна, а не косметична, берётся
    /// `pessimisticCharactersPerToken`.
    public static let charactersPerToken = 2.6

    /// Для бюджета промпта — когда ошибка в одну сторону безобидна, а в
    /// другую означает отказ модели.
    ///
    /// Измерено на настоящих документах пользователя (юридический текст на
    /// русском, `usage.prompt_tokens` от `qwen/qwen3-4b`): 2.09, 2.21, 2.52,
    /// 2.87, 2.97 — в среднем **2.50** там, где приложение считало 3.50.
    /// Недооценка на 40 %, и десятипроцентного запаса не хватило: промпт
    /// в «6800 токенов» по оценке оказался 9500 настоящих.
    ///
    /// Это значение — не догадка получше, а нижняя граница наблюдённого.
    /// Как только от модели придёт хоть один `usage.prompt_tokens`, вместо
    /// него берётся измеренное (`ChatProvider.charactersPerToken`).
    public static let pessimisticCharactersPerToken = 2.0

    public static func estimatedTokens(_ text: String) -> Int {
        estimatedTokens(text, charactersPerToken: charactersPerToken)
    }

    public static func estimatedTokens(_ text: String, charactersPerToken ratio: Double) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, Int((Double(text.count) / max(0.5, ratio)).rounded()))
    }

    public static func characters(forTokens tokens: Int) -> Int {
        max(1, Int((Double(tokens) * charactersPerToken).rounded()))
    }
}

public struct FixedSizeChunker: Chunking {
    public let size: Int
    public let overlap: Int

    public init(size: Int, overlap: Int) {
        self.size = max(1, size)
        self.overlap = max(0, min(overlap, max(0, size - 1)))
    }

    public func chunks(from text: String) -> [TextChunk] {
        let characters = Array(text)
        guard !characters.isEmpty else { return [] }
        guard characters.count > size else { return [TextChunk(index: 0, text: text)] }

        var result: [TextChunk] = []
        let step = max(1, size - overlap)
        var start = 0
        while start < characters.count {
            let end = min(start + size, characters.count)
            let piece = String(characters[start..<end])
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                result.append(TextChunk(index: result.count, text: trimmed))
            }
            if end == characters.count { break }
            start += step
        }
        return result
    }
}

/// Splits on the first separator that yields pieces small enough, then packs
/// neighbouring pieces back together up to `size`, adding a tail overlap.
///
/// **Три правила, которых раньше не было.**
///
/// * Части хранят свои разделители, и куски склеиваются из них дословно.
///   Раньше пустые части после разреза выбрасывались вместе с разделителем:
///   блок, кончавшийся `\n\n`, терял его, и последняя строка таблицы
///   приклеивалась к шапке следующей — `| 357,28 || N п/п |`. На корпусе
///   при 512 токенах — 269 таких склеек в 18 файлах.
/// * Перекрытие — целыми частями, а если последняя часть длиннее перекрытия,
///   то с начала предложения, в крайнем случае с начала слова. Раньше это
///   были последние N знаков, и треть кусков начиналась с середины слова или
///   строки таблицы, а раздел куска по его началу оказывался предыдущим.
/// * Строка таблицы не режется внутри и в перекрытие не идёт: шапку
/// каждому куску таблицы дописывает конвейер, а обрывок строки
///   — это значения без своей позиции. Строку длиннее куска делит по
/// ячейкам `TableChunks`.
public struct RecursiveChunker: Chunking {
    public let size: Int
    public let overlap: Int
    public let separators: [String]
    /// Строка таблицы и шапка с разделителем не режутся, даже если длиннее
    /// куска. Выключается там, где размер — жёсткий предел, а не ориентир:
    /// у окон LLM-нарезки, посчитанных по контексту модели и таймауту.
    public let keepsTableRowsWhole: Bool

    public init(size: Int, overlap: Int, separators: [String], keepsTableRowsWhole: Bool = true) {
        self.size = max(1, size)
        self.overlap = max(0, min(overlap, max(0, size - 1)))
        self.separators = separators.isEmpty ? ["\n\n", "\n", ". ", " "] : separators
        self.keepsTableRowsWhole = keepsTableRowsWhole
    }

    /// Часть, которую нельзя резать дальше, хоть она и длиннее куска.
    private func isIndivisible(_ text: String) -> Bool {
        keepsTableRowsWhole && (Self.isTableRow(text) || Self.isTableHeader(text))
    }

    public func chunks(from text: String) -> [TextChunk] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let pieces = split(trimmed, separatorIndex: 0)
        let merged = merge(pieces)
        return merged.enumerated().map { TextChunk(index: $0.offset, text: $0.element) }
    }

    private func split(_ text: String, separatorIndex: Int) -> [String] {
        if text.count <= size || isIndivisible(text) { return [text] }
        guard separatorIndex < separators.count else {
            // No separators left: hard-cut what is still too long.
            return Self.cut(text, every: size)
        }

        // Разделитель `| --- |` — с шапкой над ним: шапка, оставшаяся
        // в конце одного куска, и разделитель в начале другого не дают
        // таблицы ни там, ни там.
        var parts: [String] = []
        for part in Self.pieces(of: text, separator: separators[separatorIndex]) {
            if let last = parts.last, Self.isTableRow(last),
               TableText.isSeparator(part.trimmingCharacters(in: .whitespacesAndNewlines)) {
                parts[parts.count - 1] = last + part
            } else {
                parts.append(part)
            }
        }
        if parts.count <= 1 {
            return split(text, separatorIndex: separatorIndex + 1)
        }

        var result: [String] = []
        for part in parts {
            if part.count <= size || isIndivisible(part) {
                result.append(part)
            } else {
                result += split(part, separatorIndex: separatorIndex + 1)
            }
        }
        return result
    }

    /// Части текста **с разделителем на конце** каждой: склеенные подряд,
    /// они дают исходный текст знак в знак. Часть из одних пробелов
    /// и разделителей — хвост предыдущей, а не своя.
    static func pieces(of text: String, separator: String) -> [String] {
        guard !separator.isEmpty else { return [text] }
        var raw: [String] = []
        var rest = text[...]
        while let found = rest.range(of: separator) {
            raw.append(String(rest[..<found.upperBound]))
            rest = rest[found.upperBound...]
        }
        if !rest.isEmpty { raw.append(String(rest)) }

        var result: [String] = []
        for piece in raw {
            if !result.isEmpty, piece.allSatisfy({ $0.isWhitespace || $0.isNewline }) || piece == separator {
                result[result.count - 1] += piece
            } else {
                result.append(piece)
            }
        }
        return result
    }

    private func merge(_ pieces: [String]) -> [String] {
        var result: [String] = []
        var current = ""
        /// Длина `current` в знаках: `count` у строки — проход по ней,
        /// и на каждой части он делал склейку квадратичной.
        var currentCount = 0
        var parts: [String] = []
        /// Первая часть куска — перекрытие, повтор конца предыдущего.
        var startsWithOverlap = false

        func emit() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed) }
        }

        for piece in pieces {
            let pieceCount = piece.count
            if current.isEmpty {
                current = piece
                currentCount = pieceCount
                parts = [piece]
                startsWithOverlap = false
            } else if currentCount + pieceCount <= size {
                current += piece
                currentCount += pieceCount
                parts.append(piece)
            } else {
                // Шапка таблицы в конце куска — без единой строки под ней —
                // уходит в следующий, к своим строкам.
                // С ней — подпись прямо над ней («Таблица 16 – …»): одна
                // в конце куска она оставалась обрывком без таблицы.
                // Шапка, с которой кусок начался, тоже переносится: одна она
                // выходила отдельным куском без единой строки.
                var carried = ""
                if let last = parts.last, Self.isTableHeader(last) {
                    parts.removeLast()
                    carried = last
                    if let caption = parts.last, Self.isCaption(caption, limit: size) {
                        parts.removeLast()
                        carried = caption + carried
                    }
                    current = parts.joined()
                }
                // Кусок из одного перекрытия — дубль конца предыдущего:
                // он не пишется.
                let onlyOverlap = !carried.isEmpty && startsWithOverlap && parts.count == 1
                if !onlyOverlap { emit() }
                if !carried.isEmpty {
                    current = carried + piece
                    currentCount = current.count
                    parts = [carried, piece]
                    startsWithOverlap = false
                    continue
                }
                // Перекрытие, с которым кусок вылез бы за размер, не берётся:
                // размер — граница, перекрытие — пожелание.
                let tail = overlapTail(of: parts)
                let tailCount = tail.count
                let fits = !tail.isEmpty && tailCount + pieceCount <= size
                current = fits ? tail + piece : piece
                currentCount = fits ? tailCount + pieceCount : pieceCount
                parts = fits ? [tail, piece] : [piece]
                startsWithOverlap = fits
            }
        }
        emit()
        return result
    }

    /// Конец куска, с которого начнётся следующий: целые части, а если
    /// последняя часть длиннее перекрытия — её конец с начала предложения
    /// или слова. Всегда дословный конец куска.
    private func overlapTail(of parts: [String]) -> String {
        guard overlap > 0, let last = parts.last else { return "" }
        var tail = ""
        for part in parts.reversed() {
            guard tail.count + part.count <= overlap else { break }
            tail = part + tail
        }
        // Внутри таблицы перекрытия нет: обрывок строки — значения без
        // позиции, а шапку куску и так дописывают. Проверяется часть,
        // из которой взят хвост: конец длинной строки таблицы с `|`
        // не начинается и строкой таблицы сам не выглядит.
        let source = tail.isEmpty ? last : tail
        if source.split(separator: "\n").contains(where: { Self.isTableRow(String($0)) }) { return "" }
        if tail.isEmpty { tail = Self.alignedSuffix(of: last, maximum: overlap) }
        return tail
    }

    /// Самый длинный конец `text` не длиннее `maximum`, начинающийся
    /// с предложения, а если такого нет — со слова.
    static func alignedSuffix(of text: String, maximum: Int) -> String {
        let length = text.count
        guard maximum > 0, length > 0 else { return "" }
        if length <= maximum { return text }
        let earliest = text.index(text.endIndex, offsetBy: -maximum)
        if let sentence = SentenceSplitter.ranges(in: text).first(where: { $0.lowerBound >= earliest }) {
            return String(text[sentence.lowerBound...])
        }
        var index = earliest
        while index < text.endIndex {
            if index > text.startIndex, text[text.index(before: index)].isWhitespace, !text[index].isWhitespace {
                return String(text[index...])
            }
            index = text.index(after: index)
        }
        return ""
    }

    /// Одна строка таблицы Markdown — `| … |`, без переводов строки внутри.
    static func isTableRow(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 2 && trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && !trimmed.contains("\n")
    }

    /// Подпись таблицы: короткая строка прозы — не больше четверти куска.
    static func isCaption(_ text: String, limit: Int) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= limit / 4 && !trimmed.contains("\n") && !trimmed.hasPrefix("|")
    }

    /// Шапка таблицы — строка и разделитель `| --- |` под ней.
    static func isTableHeader(_ text: String) -> Bool {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        return lines.count == 2 && isTableRow(lines[0]) && TableText.isSeparator(lines[1])
    }

    /// Нарезка по знакам — когда разделителей больше нет.
    static func cut(_ text: String, every size: Int) -> [String] {
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[start..<end]))
            start = end
        }
        return result
    }
}

public enum ChunkerFactory {
    /// Builds the synchronous chunkers. Semantic and LLM-based need a model and
    /// go through `ChunkingPipeline` instead; asking for them here falls back to
    /// Recursive, which is the closest thing that can run without one.
    public static func make(
        _ configuration: ChunkingConfiguration,
        fileExtension: String? = nil,
        structure: [DocumentNode] = []
    ) -> Chunking {
        switch configuration.strategy {
        case .fixed:
            return FixedSizeChunker(
                size: configuration.chunkSizeInCharacters,
                overlap: configuration.overlapInCharacters
            )
        case .recursive, .semantic, .llmBased:
            return RecursiveChunker(
                size: configuration.chunkSizeInCharacters,
                overlap: configuration.overlapInCharacters,
                separators: configuration.separators
            )
        case .documentBased:
            return DocumentBasedChunker(configuration: configuration, fileExtension: fileExtension, structure: structure)
        case .hierarchical:
            return HierarchicalChunker(configuration: configuration, structure: structure)
        case .adaptive:
            return AdaptiveChunker(configuration: configuration)
        }
    }
}
