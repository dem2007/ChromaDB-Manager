import Foundation

/// Splits text into sentences. Used by Semantic chunking and by the test bench.
public enum SentenceSplitter {
    public static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""

        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" || character == "\n" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count > 1 {
                    result.append(trimmed)
                    current = ""
                }
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }
}

public enum VectorMath {
    /// 1 for identical direction, 0 for orthogonal.
    public static func cosineSimilarity(_ first: [Double], _ second: [Double]) -> Double {
        guard first.count == second.count, !first.isEmpty else { return 0 }
        var dot = 0.0
        var firstNorm = 0.0
        var secondNorm = 0.0
        for index in first.indices {
            dot += first[index] * second[index]
            firstNorm += first[index] * first[index]
            secondNorm += second[index] * second[index]
        }
        guard firstNorm > 0, secondNorm > 0 else { return 0 }
        return dot / (firstNorm.squareRoot() * secondNorm.squareRoot())
    }

    public static func cosineDistance(_ first: [Double], _ second: [Double]) -> Double {
        1 - cosineSimilarity(first, second)
    }

    /// Percentile by nearest rank — no interpolation, so the value is always one
    /// of the observed distances.
    public static func percentile(_ values: [Double], _ percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let fraction = max(0, min(percentile, 100)) / 100
        let index = Int((fraction * Double(sorted.count - 1)).rounded())
        return sorted[index]
    }
}

/// Chunking that needs a model, so it cannot be a plain `Chunking`.
public protocol AsyncChunking {
    func chunks(from text: String) async throws -> [TextChunk]
}

public enum SemanticChunkingError: LocalizedError {
    case noEmbeddingModel
    /// Предложение не помещается в модель — границы считать не по чему.
    case sentenceLongerThanContext(estimatedTokens: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .noEmbeddingModel:
            return String(localized: "Semantic-чанкинг требует эмбеддинг-модель: он считает вектор каждого предложения.")
        case .sentenceLongerThanContext(let tokens, let limit):
            return String(localized: "В тексте есть «предложение» длиннее контекста модели: ≈\(tokens) токенов при лимите \(limit). Модель обработала бы только его начало, и границы чанков считались бы не по тому тексту.")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .noEmbeddingModel:
            return nil
        case .sentenceLongerThanContext:
            return String(localized: "Обычно это текст без знаков препинания — сплошная строка или минифицированный файл. Выберите стратегию Recursive или модель с большим контекстом.")
        }
    }
}

/// Embeds every sentence and cuts where the meaning changes most.
public struct SemanticChunker: AsyncChunking {
    public let configuration: ChunkingConfiguration
    private let embeddings: EmbeddingProvider
    private let model: String
    private let batchSize: Int

    public init(configuration: ChunkingConfiguration, embeddings: EmbeddingProvider, model: String, batchSize: Int = 32) {
        self.configuration = configuration
        self.embeddings = embeddings
        self.model = model
        self.batchSize = batchSize
    }

    public func chunks(from text: String) async throws -> [TextChunk] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let sentences = SentenceSplitter.sentences(in: trimmed)
        // One or two sentences have no boundary worth measuring.
        guard sentences.count > 2 else {
            return [TextChunk(index: 0, text: trimmed)]
        }

        // Предложение длиннее контекста модель обрежет молча, и вектор будет
        // описывать его начало. Здесь это не теряет текст — чанки нарезаются
        // из исходника, — но границы считаются по расстояниям между такими
        // векторами, то есть стратегия работает не по тому, что видит человек.
        // Текст без знаков препинания (сплошная строка, минифицированный файл)
        // даёт ровно такие «предложения».
        let contextLength = await embeddings.contextLength(of: model)
        if let oversized = sentences.first(where: {
            ContextBudget.check($0, contextLength: contextLength).blocksSending
        }) {
            throw SemanticChunkingError.sentenceLongerThanContext(
                estimatedTokens: TokenEstimator.estimatedTokens(oversized),
                limit: contextLength ?? 0
            )
        }

        var vectors: [[Double]] = []
        for start in stride(from: 0, to: sentences.count, by: batchSize) {
            try Task.checkCancellation()
            let slice = Array(sentences[start..<min(start + batchSize, sentences.count)])
            vectors += try await embeddings.embed(texts: slice, model: model)
        }
        guard vectors.count == sentences.count else {
            throw LMStudioError.emptyResponse
        }

        // Distance between the windows on both sides of each gap. A buffer wider
        // than one sentence smooths over a single odd sentence in a coherent run.
        let buffer = max(1, configuration.sentenceBuffer)
        var distances: [Double] = []
        for gap in 0..<(sentences.count - 1) {
            let left = averaged(vectors, from: max(0, gap - buffer + 1), through: gap)
            let right = averaged(vectors, from: gap + 1, through: min(sentences.count - 1, gap + buffer))
            distances.append(VectorMath.cosineDistance(left, right))
        }

        let threshold: Double
        switch configuration.thresholdMode {
        case .percentile:
            threshold = VectorMath.percentile(distances, configuration.thresholdValue)
        case .absolute:
            threshold = configuration.thresholdValue
        }

        let minimum = configuration.minSizeInCharacters
        let maximum = max(minimum + 1, configuration.maxSizeInCharacters)
        var result: [TextChunk] = []
        var current = ""

        for (index, sentence) in sentences.enumerated() {
            let candidate = current.isEmpty ? sentence : current + " " + sentence
            // A chunk that would exceed the ceiling breaks here regardless of
            // where the meaning changes: the size limit is the hard one.
            if candidate.count > maximum, !current.isEmpty {
                result.append(TextChunk(index: result.count, text: current))
                current = sentence
                continue
            }
            current = candidate

            let isBreakpoint = index < distances.count && distances[index] >= threshold && threshold > 0
            if isBreakpoint, current.count >= minimum {
                result.append(TextChunk(index: result.count, text: current))
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(TextChunk(index: result.count, text: current))
        }
        return result
    }

    private func averaged(_ vectors: [[Double]], from start: Int, through end: Int) -> [Double] {
        let slice = vectors[start...end]
        guard let width = slice.first?.count, width > 0 else { return [] }
        var sum = [Double](repeating: 0, count: width)
        for vector in slice where vector.count == width {
            for index in 0..<width { sum[index] += vector[index] }
        }
        let count = Double(slice.count)
        return sum.map { $0 / count }
    }
}

// MARK: - LLM-based

public enum LLMChunkingError: LocalizedError {
    case noChatModel
    case malformedOutput(attempts: Int)
    /// Модель не ответила вовсе: таймаут, обрыв, отказ LM Studio.
    ///
    /// Отдельно от `malformedOutput`, и это не педантизм. «Ответила не по
    /// формату» — про **разбор ответа**, и настройка `on_malformed_output`
    /// отвечает именно на этот вопрос. Молчание модели — не ответ не по
    /// формату, а недоступная модель, и откатываться на Recursive по
    /// настройке, которая про другое, значит наполнять коллекцию «LLM»
    /// границами Recursive часами подряд.
    case noAnswer(model: String, attempts: Int, reason: String)
    /// Контекста, с которым загружена модель, не хватает даже на минимальное
    /// окно.
    case contextTooSmall(tokens: Int)
    /// За отпущенное время модель не успевает переписать даже минимальное
    /// окно.
    ///
    /// Отдельно от `contextTooSmall`: контекст лечится перезагрузкой модели,
    /// а это — таймаутом или моделью полегче, и путать их значит советовать
    /// человеку не то. Лучше сказать сразу, чем оборвать первый же вызов
    /// по таймауту и повторить это на каждом окне каждого файла.
    case tooSlowForTimeout(model: String, tokensPerSecond: Double, timeout: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .noChatModel:
            return String(localized: "LLM-based чанкинг требует выбранной чат-модели LM Studio.")
        case .malformedOutput(let attempts):
            return String(localized: "Чат-модель \(attempts) раз(а) ответила не по формату — разобрать границы чанков не удалось.")
        case .noAnswer(let model, let attempts, let reason):
            return String(localized: "Чат-модель \(model) не ответила ни разу за \(attempts) попыт(ку/ки/ок): \(reason). Прогон остановлен.")
        case .contextTooSmall(let tokens):
            return String(localized: "Модель загружена с контекстом \(tokens) токенов — в него не помещается даже минимальный кусок текста вместе с ответом.")
        case .tooSlowForTimeout(let model, let speed, let timeout):
            return String(localized: "Модель \(model) пишет \(Int(speed.rounded())) токенов в секунду: за отпущенные ей \(Int(timeout)) с она не успевает переписать даже минимальный кусок текста.")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .malformedOutput:
            return String(localized: "Попробуйте другую модель, упростите шаблон запроса или переключите поведение на «откатиться на Recursive».")
        case .noAnswer:
            return String(localized: "Проверьте, что модель загружена в LM Studio и успевает отвечать: увеличьте таймаут в настройках источника или возьмите модель полегче. Прогон остановлен даже при выбранном «откатиться на Recursive»: эта настройка про ответ не по формату, а молчащая модель — это недоступная модель, и откат по ней наполнил бы коллекцию границами Recursive под видом LLM-нарезки.")
        case .noChatModel:
            return nil
        case .contextTooSmall:
            return String(localized: "Перезагрузите модель в LM Studio с бо́льшим контекстом, укоротите шаблон запроса или выберите другую стратегию нарезки.")
        case .tooSlowForTimeout:
            return String(localized: "Увеличьте таймаут в настройках источника или возьмите модель полегче. Перезагрузка модели с бо́льшим контекстом здесь не поможет: места ей хватает, не хватает времени.")
        }
    }
}

/// Asks a chat model where the boundaries are (optional strategy).
///
/// The model is never trusted: the answer must parse as a list of strings, every
/// piece is clipped to `max_chunk_size`, and a malformed answer either fails or
/// falls back to Recursive with a mark — depending on the source's setting.
public struct LLMChunker: AsyncChunking {
    public let configuration: ChunkingConfiguration
    private let chat: ChatProvider
    private let log: LogHandler

    public init(configuration: ChunkingConfiguration, chat: ChatProvider, log: @escaping LogHandler = noopLogHandler) {
        self.configuration = configuration
        self.chat = chat
        self.log = log
    }

    public func chunks(from text: String) async throws -> [TextChunk] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let model = configuration.chatModel, !model.isEmpty else {
            throw LLMChunkingError.noChatModel
        }

        // The whole file rarely fits a context window, so it is pre-split into
        // windows the model can actually read, and each window is asked about
        // separately. Boundaries between windows follow paragraph breaks.
        //
        // «Which the model can actually read» до сих пор было фигурой речи:
        // размер окна считался только от размера чанка. При настройках по
        // умолчанию (2048 токенов на чанк) окно выходило 28 672 символа —
        // около 8192 токенов **одного промпта**, то есть весь контекст обычной
        // загруженной модели, и это ещё без ответа, который по объёму равен
        // входу.
        let wanted = Self.wantedWindow(for: configuration)
        var windowSize = wanted
        if let context = await chat.loadedContextLength(of: model) {
            let allowed = Self.windowLimit(contextTokens: context, prompt: configuration.effectivePrompt)
            guard allowed >= Self.minimumWindow else {
                throw LLMChunkingError.contextTooSmall(tokens: context)
            }
            if allowed < wanted {
                // Названо «загружена с», а не «контекст модели»: 8192 — это
                // не свойство модели, а настройка её загрузки в LM Studio,
                // и человек, видящий в таблице потолок в 131 072, иначе
                // читает эту строку как ошибку приложения.
                log(
                    .warning, "Чанкинг",
                    "Окно уменьшено с \(wanted) до \(allowed) символов: модель \(model) "
                    + "загружена с контекстом \(context) токенов. Размер контекста задаётся "
                    + "при загрузке модели в LM Studio, приложение его не меняет."
                )
            }
            windowSize = min(windowSize, allowed)
        }

        // Второй предел — время. Считается от измеренной скорости, а
        // не от предположения о ней: сколько эта модель пишет на этой машине,
        // видно из её же ответов.
        let speed = await chat.generationSpeed(of: model)
        if let speed {
            let byTime = Self.windowLimitByTime(timeout: configuration.llmTimeout, tokensPerSecond: speed)
            guard byTime >= Self.minimumWindow else {
                throw LLMChunkingError.tooSlowForTimeout(
                    model: model, tokensPerSecond: speed, timeout: configuration.llmTimeout
                )
            }
            if byTime < windowSize {
                log(
                    .warning, "Чанкинг",
                    "Окно уменьшено с \(windowSize) до \(byTime) символов: модель \(model) пишет "
                    + "\(Int(speed.rounded())) ток/с, и за отпущенные ей \(Int(configuration.llmTimeout)) с "
                    + "больше переписать не успеет. Увеличьте таймаут в настройках источника, "
                    + "если нужны окна побольше."
                )
            }
            windowSize = min(windowSize, byTime)
        }
        let windows = RecursiveChunker(
            size: windowSize,
            overlap: 0,
            separators: configuration.separators
        ).chunks(from: trimmed).map(\.text)

        // Потолок ответа по времени: модель должна упереться в предел длины
        // раньше, чем в секундомер. Обрыв по длине — это разобранный случай
        // (ответ не по формату, дальше решает настройка источника), а обрыв
        // по таймауту — три потерянные попытки и остановленный прогон.
        let answerCeiling = speed.map {
            Self.answerBudget(timeout: configuration.llmTimeout, tokensPerSecond: $0)
        }

        var result: [TextChunk] = []
        for window in windows {
            try Task.checkCancellation()
            let pieces = try await pieces(of: window, model: model, answerCeiling: answerCeiling)
            for piece in pieces {
                result.append(TextChunk(index: result.count, text: piece.text, note: piece.note))
            }
        }
        return result
    }

    private struct Piece {
        let text: String
        let note: String?
    }

    // MARK: - Окно против контекста модели

    /// Меньше этого окно бессмысленно: модель должна видеть несколько абзацев,
    /// чтобы было где искать границу.
    public static let minimumWindow = 1_000

    /// Во сколько раз ответ длиннее окна.
    ///
    /// Эта задача устроена иначе, чем переранжирование: модель не оценивает
    /// текст, а **переписывает его целиком**, разложив по фрагментам. Значит
    /// в контексте должно поместиться и то, что послали, и почти столько же
    /// обратно, плюс кавычки, запятые и экранирование JSON — отсюда 1.3,
    /// а не 1.0.
    public static let answerToWindowRatio = 1.3

    /// Десятая часть — на погрешность `TokenEstimator`: это правило большого
    /// пальца, а не токенизатор модели.
    public static let safetyFraction = 0.10

    /// Какую долю таймаута отдавать под письмо.
    ///
    /// Не десятая часть про запас, как выше, а вполне конкретная величина,
    /// снятая с живого прогона. При доле 0.9 вызовы, упиравшиеся в предел
    /// длины, занимали 116–117 секунд из отпущенных 120 — и два из них
    /// таймаут всё-таки обогнал. Причины две, и обе системные: скорость
    /// измеряется на калибровочном промпте в тысячу с небольшим токенов, а
    /// работа идёт на четырёх-шести тысячах, где модель заметно медленнее;
    /// плюс чтение промпта, которое в замер письма не входит.
    ///
    /// Смысл этого числа — сделать так, чтобы модель упиралась **в предел
    /// длины, а не в секундомер**: обрыв по длине разбирает настройка
    /// источника, обрыв по таймауту теряет попытку целиком.
    public static let timeBudgetFraction = 0.70

    /// Окно, которое хотелось бы под заданный размер чанка.
    ///
    /// Отдельной функцией, потому что это же число считает предполётная
    /// проверка: разойдись они — проверка разрешала бы прогон, который потом
    /// жалуется на маленькое окно, или наоборот.
    public static func wantedWindow(for configuration: ChunkingConfiguration) -> Int {
        max(configuration.maxSizeInCharacters * 4, 2000)
    }

    /// Предел длины ответа для окна такого размера.
    ///
    /// Без него запрос уходил вовсе без `max_tokens`, и модель могла писать,
    /// пока не кончится контекст. Так и вышло: на окно в 2237 токенов пришло
    /// 9102 токена ответа — вчетверо больше входа, и это при задании
    /// «объединение фрагментов должно давать исходный текст». Модель не
    /// отвечала, а повторялась по кругу; остановить её было нечем, кроме
    /// таймаута, а после перезагрузки на контекст 128 000 такой круг успел
    /// уронить движок LM Studio по памяти.
    ///
    /// Предел заведомо просторнее честного ответа: он ловит зацикливание,
    /// а не подрезает работу. Оборванный ответ не разберётся как JSON и
    /// пойдёт по ветке «ответ не по формату» — той самой, для которой она
    /// и заведена.
    public static func answerLimit(
        forWindow window: String,
        charactersPerToken ratio: Double = TokenEstimator.pessimisticCharactersPerToken
    ) -> Int {
        let windowTokens = TokenEstimator.estimatedTokens(window, charactersPerToken: ratio)
        return max(minimumAnswerLimit, Int((Double(windowTokens) * answerToWindowRatio).rounded(.up)))
    }

    /// Ниже этого предел ответа не опускается: у совсем короткого окна
    /// накладные расходы формата съедают весь запас, и обрезанным оказался
    /// бы честный ответ.
    public static let minimumAnswerLimit = 512

    /// Сколько токенов модель успевает написать за отпущенное время.
    ///
    /// Из этого числа получается потолок `max_tokens`, и смысл у него ровно
    /// один: сделать таймаут недостижимым. Пока предел ответа считался только
    /// от размера окна, он оказывался просторнее, чем позволяли сто двадцать
    /// секунд, — и прогон по-прежнему упирался в секундомер, а не в предел.
    public static func answerBudget(timeout: TimeInterval, tokensPerSecond: Double) -> Int {
        guard timeout > 0, tokensPerSecond > 0 else { return .max }
        return max(minimumAnswerLimit, Int(timeout * tokensPerSecond * timeBudgetFraction))
    }

    /// Сколько символов окна модель успевает переписать за отведённое время.
    ///
    /// Контекст говорит «поместится», время говорит «успеет», и это разные
    /// ответы. Окно в 28 672 символа помещалось в контекст 128 000 с запасом
    /// в четыре раза и требовало при этом около 11 000 токенов ответа — при
    /// измеренных на этой машине 72 ток/с почти три минуты против отпущенных
    /// ста двадцати секунд. Пока окно считалось только от контекста, кнопка
    /// «загрузить с максимальным контекстом» учетверяла окно и тем гарантировала
    /// обрыв: чем больше контекст, тем вернее прогон не доходил до конца.
    public static func windowLimitByTime(
        timeout: TimeInterval,
        tokensPerSecond: Double,
        charactersPerToken ratio: Double = TokenEstimator.pessimisticCharactersPerToken
    ) -> Int {
        guard timeout > 0, tokensPerSecond > 0 else { return .max }
        // Из того же бюджета, что и предел ответа: окно, на которое модель
        // ответит длиннее, чем разрешено, — это окно, которое всегда будет
        // обрываться.
        let windowTokens = Double(answerBudget(timeout: timeout, tokensPerSecond: tokensPerSecond))
            / answerToWindowRatio
        return max(1, Int(windowTokens * ratio))
    }

    /// Сколько символов окна влезает в модель с таким контекстом.
    public static func windowLimit(
        contextTokens: Int, prompt: String,
        charactersPerToken ratio: Double = TokenEstimator.pessimisticCharactersPerToken
    ) -> Int {
        // Шаблон без текста — то, что уходит в каждом вызове сверх окна.
        let overhead = TokenEstimator.estimatedTokens(
            prompt.replacingOccurrences(of: "{{TEXT}}", with: ""), charactersPerToken: ratio
        )
        let margin = Int((Double(contextTokens) * safetyFraction).rounded(.up))
        let available = contextTokens - overhead - margin
        guard available > 0 else { return 0 }
        let windowTokens = Double(available) / (1.0 + answerToWindowRatio)
        return max(1, Int(windowTokens * ratio))
    }

    /// Отметка на чанках, границы которых определила не модель, а Recursive.
    ///
    /// Публичная и одна на всех: по ней прогон узнаёт, что нарезка подменилась,
    /// и называет файл в сводке. Сравнение идёт с этой самой строкой, поэтому
    /// «почти такой же» текст в другом месте ничего не сломает.
    public static let recursiveFallbackNote = String(
        localized: "границы определены Recursive: чат-модель ответила не по формату"
    )

    private func pieces(of window: String, model: String, answerCeiling: Int? = nil) async throws -> [Piece] {
        let prompt = configuration.effectivePrompt.replacingOccurrences(of: "{{TEXT}}", with: window)
        var attempts = 0
        /// Ответила ли модель хоть раз — пусть даже так, что разобрать не вышло.
        var everAnswered = false
        /// Чем кончилась последняя неудача вызова, если модель молчала.
        var silence: String?

        // G3 прямо это и предписывает: предел ответа задаёт приложение, от
        // задачи и длины входа. До не задавал никто, и поле оставалось
        // пустым — «не задан» в настройках источника.
        var settings = configuration.generation
        if settings.maxTokens == nil {
            settings.maxTokens = min(Self.answerLimit(forWindow: window), answerCeiling ?? .max)
        }

        while attempts <= max(0, configuration.llmMaxRetries) {
            attempts += 1
            try Task.checkCancellation()
            do {
                let answer = try await chat.complete(
                    prompt: prompt,
                    model: model,
                    settings: settings,
                    // with a schema the model cannot emit a token that
                    // breaks the structure, which is the whole class of defect
                    // `on_malformed_output` exists to survive. That fallback
                    // stays, for models and versions without support.
                    schema: configuration.useStructuredOutput ? .chunks : nil,
                    timeout: configuration.llmTimeout
                )
                if let parsed = Self.parse(answer), !parsed.isEmpty {
                    return clipped(parsed).map { Piece(text: $0, note: nil) }
                }
                // Ответ пришёл — разобрать не вышло. Вот это и есть «не по
                // формату», и вот на это отвечает `on_malformed_output`.
                everAnswered = true
                log(.warning, "Чанкинг", "Ответ чат-модели не разобран как список фрагментов (попытка \(attempts))")
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as LMStudioError where error.isTruncatedByTokenLimit {
                // Ответ упёрся в предел длины — модель писала и не остановилась
                //. Это живая модель, а не молчащая, и разбирать этот
                // случай должна настройка про формат: оборванный JSON и есть
                // ответ не по формату.
                everAnswered = true
                log(
                    .warning, "Чанкинг",
                    "Ответ чат-модели оборван по пределу длины (попытка \(attempts)): модель "
                    + "пишет больше, чем есть в исходном тексте, — похоже на повтор по кругу."
                )
            } catch {
                silence = error.localizedDescription
                log(.warning, "Чанкинг", "Вызов чат-модели не удался (попытка \(attempts)): \(error.localizedDescription)")
            }
        }

        // Модель не ответила ни разу — это не «ответ не по формату», а
        // недоступная модель, и решает это не настройка про формат.
        //
        // Без этой ветки прогон шёл дальше: три попытки по две минуты на
        // каждое окно каждого файла, четырнадцать часов подряд, — и всё это
        // время коллекция «LLM» наполнялась границами Recursive с отметкой,
        // объясняющей их несуществующим нарушением формата.
        // Ровно «не ответила **ни разу**»: модель, которая ответила хоть как-то,
        // а потом замолчала, — живая, и её случай разбирает настройка ниже.
        if let silence, !everAnswered {
            throw LLMChunkingError.noAnswer(model: model, attempts: attempts, reason: silence)
        }

        switch configuration.onMalformedOutput {
        case .retryThenFail:
            throw LLMChunkingError.malformedOutput(attempts: attempts)
        case .fallbackToRecursive:
            let note = Self.recursiveFallbackNote
            log(.warning, "Чанкинг", "Откат на Recursive для фрагмента текста: \(note)")
            let size = configuration.maxSizeInCharacters
            return RecursiveChunker(
                size: size,
                overlap: configuration.overlapInCharacters(percent: configuration.overlapPercent, of: size),
                separators: configuration.separators
            )
            .chunks(from: window)
            .map { Piece(text: $0.text, note: note) }
        }
    }

    /// Chat models wrap JSON in prose and fences, so the array is extracted
    /// rather than assumed to be the whole answer.
    ///
    /// Two shapes are accepted on purpose: `{"chunks": [...]}`, which is what
    /// the schema of G2 produces, and a bare `[...]`, which is what a model
    /// without schema support tends to answer. Both are real, so both parse.
    static func parse(_ answer: String) -> [String]? {
        if let structured = parseStructured(answer) { return structured }
        return parseArray(answer)
    }

    /// The schema shape, parsed as itself rather than by hunting for brackets.
    private static func parseStructured(_ answer: String) -> [String]? {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end else {
            return nil
        }
        let slice = String(trimmed[start...end])
        guard let data = slice.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["chunks"] as? [Any] else {
            return nil
        }
        let strings = list.compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return strings.isEmpty ? nil : strings
    }

    private static func parseArray(_ answer: String) -> [String]? {
        // The longest fenced part, **among those that actually contain an
        // array**: picking the longest part outright loses the answer whenever
        // the model's prose is wordier than its JSON, which is common. This is
        // the path a model without schema support takes, so it has to be robust.
        let parts = answer
            .replacingOccurrences(of: "```json", with: "```")
            .components(separatedBy: "```")
        let cleaned = parts.filter { $0.contains("[") }.max(by: { $0.count < $1.count })
            ?? parts.max(by: { $0.count < $1.count })
            ?? answer

        guard let start = cleaned.firstIndex(of: "["), let end = cleaned.lastIndex(of: "]"), start < end else {
            return nil
        }
        let slice = String(cleaned[start...end])
        guard let data = slice.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return nil
        }
        let strings = list.compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return strings.isEmpty ? nil : strings
    }

    private func clipped(_ pieces: [String]) -> [String] {
        let maximum = configuration.maxSizeInCharacters
        var result: [String] = []
        for piece in pieces {
            if piece.count <= maximum {
                result.append(piece)
            } else {
                // The model ignored the size: cut it down ourselves instead of
                // sending an oversized chunk to the embedding model.
                result += RecursiveChunker(
                    size: maximum,
                    overlap: 0,
                    separators: configuration.separators
                ).chunks(from: piece).map(\.text)
            }
        }
        return result
    }
}

// MARK: - Pipeline

/// One entry point for every strategy, sync or not.
///
/// `SourceSyncService` and the test bench both go through this, so a strategy
/// cannot behave differently in a preview and in a real run.
public struct ChunkingPipeline {
    public let configuration: ChunkingConfiguration
    private let embeddings: EmbeddingProvider?
    private let chat: ChatProvider?
    private let embeddingModel: String?
    private let log: LogHandler

    public init(
        configuration: ChunkingConfiguration,
        embeddings: EmbeddingProvider? = nil,
        chat: ChatProvider? = nil,
        embeddingModel: String? = nil,
        log: @escaping LogHandler = noopLogHandler
    ) {
        self.configuration = configuration
        self.embeddings = embeddings
        self.chat = chat
        self.embeddingModel = embeddingModel
        self.log = log
    }

    /// `structure` is what the extractor found in the file; the two
    /// structural strategies cut on it, the rest ignore it.
    public func chunks(
        from text: String,
        fileExtension: String? = nil,
        structure: [DocumentNode] = []
    ) async throws -> [TextChunk] {
        switch configuration.strategy {
        case .fixed, .recursive, .documentBased, .hierarchical, .adaptive:
            return ChunkerFactory.make(configuration, fileExtension: fileExtension, structure: structure).chunks(from: text)

        case .semantic:
            guard let embeddings, let model = configuration.sentenceEmbeddingModel ?? embeddingModel, !model.isEmpty else {
                throw SemanticChunkingError.noEmbeddingModel
            }
            return try await SemanticChunker(
                configuration: configuration,
                embeddings: embeddings,
                model: model
            ).chunks(from: text)

        case .llmBased:
            guard let chat else { throw LLMChunkingError.noChatModel }
            return try await LLMChunker(configuration: configuration, chat: chat, log: log).chunks(from: text)
        }
    }
}
