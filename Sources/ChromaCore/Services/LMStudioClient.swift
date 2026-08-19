import Foundation

public enum LMStudioModelKind: String, Codable, CaseIterable {
    case embedding
    case chat
    /// Специализированный переранжировщик — **только вручную**.
    ///
    /// Автоматически этот тип не ставится никогда, и не по недосмотру:
    /// LM Studio отдаёт переранжировщики обычным `llm` (проверено на
    /// `qwen3-reranker-0.6b` и `jina-reranker-v3.5-mlx`), а пробный запрос
    /// отличить их не может — они отвечают на `/v1/chat/completions` как все
    /// прочие. Единственный, кто знает, что модель обучена ранжировать
    /// пары, — человек, который её скачал.
    case reranking
    case unknown

    public var title: String {
        switch self {
        case .embedding: return "Эмбеддинги"
        case .chat: return "Чат / LLM"
        case .reranking: return "Реранкинг"
        case .unknown: return "Не определён"
        }
    }
}

public struct LMStudioModel: Identifiable, Hashable {
    public let id: String
    public var kind: LMStudioModelKind
    public let rawType: String?
    public let contextLength: Int?
    /// Контекст, с которым модель **загружена сейчас**, — в отличие от
    /// `contextLength`, который берёт потолок.
    ///
    /// Разница не косметическая. Для эмбеддингов потолок достижим: рантайм
    /// наращивает контекст, это измерено. Для порождающих вызовов —
    /// нет: движок MLX отвечает `exceed_context_size_error` с `n_ctx`, равным
    /// именно загруженному значению, а llama.cpp на `/v1/completions`
    /// отказывается, на `/v1/chat/completions` же молча обрезает. Поэтому
    /// бюджет промпта считается отсюда, а не от потолка.
    public let loadedContextLength: Int?
    /// True when `kind` came from a manual override or a probe, not the API.
    public var kindIsInferred: Bool

    /// Что показать в таблице моделей.
    ///
    /// Пока показывали один потолок, экран говорил «131 072 токена», а журнал
    /// чанкинга — «контекст модели 8192», и это читалось как ошибка
    /// приложения. Оба числа настоящие и означают разное: потолок — что модель
    /// умеет, загруженное — с чем её подняли в LM Studio. Порождающие вызовы
    /// упираются во второе, поэтому названы оба.
    /// Числа — через `plainDigits`: «128 000 токенов» с разрядным пробелом
    /// нельзя ни вписать в поле контекста LM Studio, ни подставить в команду
    /// `lms load -c`, а именно это человек и пойдёт делать.
    ///
    /// «Загружена» говорится всегда, когда модель загружена, — а не только
    /// когда её контекст меньше потолка. Пока это зависело от **разницы чисел**,
    /// модель, поднятая ровно на потолке, выглядела в точности как
    /// незагруженная: обе строки «128000 токенов».
    public var contextLine: String? {
        guard let contextLength else {
            return loadedContextLength.map { String(localized: "загружена, \($0.plainDigits) токенов") }
        }
        guard let loadedContextLength else {
            return String(localized: "\(contextLength.plainDigits) токенов")
        }
        guard loadedContextLength != contextLength else {
            return String(localized: "загружена, \(contextLength.plainDigits) токенов")
        }
        return String(localized: "загружена с \(loadedContextLength.plainDigits) из \(contextLength.plainDigits) токенов")
    }

    public init(
        id: String,
        kind: LMStudioModelKind,
        rawType: String? = nil,
        contextLength: Int? = nil,
        loadedContextLength: Int? = nil,
        kindIsInferred: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.rawType = rawType
        self.contextLength = contextLength
        self.loadedContextLength = loadedContextLength
        self.kindIsInferred = kindIsInferred
    }
}

public enum LMStudioError: LocalizedError {
    case badURL(String)
    case unreachable(String)
    case api(status: Int, message: String)
    case emptyResponse
    case modelNotEmbedding(String)
    case timedOut(what: String, seconds: TimeInterval)
    /// the answer stopped because it ran out of tokens, so whatever arrived
    /// is a fragment. Never a valid result — a cut-off JSON is broken JSON, and
    /// with a reasoning model the content can even be empty while the whole
    /// budget went to reasoning (confirmed live).
    case truncatedByTokenLimit(model: String)
    /// Векторов пришло не столько, сколько отправлено текстов.
    ///
    /// Отдельным случаем, а не `emptyResponse`: короткий ответ опаснее пустого.
    /// Пустой заметен сразу, а короткий выравнивается по первым позициям
    /// и выглядит как удачный — пока не выяснится, что хвост документов
    /// в базу не попал.
    case embeddingCountMismatch(sent: Int, received: Int)

    /// LM Studio ответила от другой модели, чем просили.
    ///
    /// Замерено на живой LM Studio 0.3.x: `/v1/embeddings` **не загружает**
    /// модель по имени из запроса. Если названной модели среди загруженных
    /// нет, ответ приходит от той, что загружена, — и в поле `model` стоит
    /// её имя, а не запрошенное. На заведомо несуществующее имя тоже: ошибки
    /// не будет. Просили `bge-m3-mlx` — получили
    /// `text-embedding-qwen3-embedding-0.6b`, и узнать об этом можно было
    /// только по этому полю.
    case modelSubstituted(requested: String, returned: String)

    public var errorDescription: String? {
        switch self {
        case .badURL(let value):
            return "Некорректный адрес LM Studio: \(value)"
        case .unreachable(let reason):
            return "LM Studio недоступна: \(reason). Запустите LM Studio и включите Local Server в разделе Developer."
        case .api(let status, let message):
            return "LM Studio вернула ошибку \(status): \(message)"
        case .emptyResponse:
            return "LM Studio вернула пустой ответ."
        case .modelNotEmbedding(let model):
            return "Модель «\(model)» не вернула вектор — вероятно, это чат-модель, а не эмбеддинговая."
        case .timedOut(let what, let seconds):
            return "LM Studio не ответила за \(Int(seconds)) с (\(what))."
        case .truncatedByTokenLimit(let model):
            return "Ответ модели «\(model)» оборван по лимиту токенов (finish_reason: length) — это неполный результат, а не короткий."
        case .embeddingCountMismatch(let sent, let received):
            return "LM Studio вернула \(received) векторов на \(sent) текстов. Сопоставить их с текстами нельзя, поэтому операция остановлена: молча записанная часть означала бы пропавшие документы."
        case .modelSubstituted(let requested, let returned):
            return "Запрошена модель «\(requested)», а ответила «\(returned)». Операция остановлена: векторы двух моделей несопоставимы, и записанные молча они превратили бы коллекцию в смесь, которую уже не разделить. Загрузите нужную модель в LM Studio или выберите ту, что уже загружена."
        }
    }

    /// Ответ оборван пределом длины — то есть модель **отвечала**.
    ///
    /// Свойством, а не `if case` по месту: вызывающей стороне важно одно —
    /// отличить живую модель от молчащей, и от того, как здесь устроено
    /// перечисление, это отличие зависеть не должно.
    public var isTruncatedByTokenLimit: Bool {
        if case .truncatedByTokenLimit = self { return true }
        return false
    }
}

/// Talks to the LM Studio local server over its OpenAI-compatible API.
///
/// The app never downloads, loads or deletes models — that stays in LM Studio.
public actor LMStudioClient {
    public let baseURL: URL
    private let session: URLSession
    private let log: LogHandler

    private let timeouts: TimeoutSettings
    /// consulted before the network, transparent to every caller.
    private let cache: EmbeddingCache?
    /// измеренное «символов на токен». Общее на приложение, потому что
    /// клиент создаётся заново на каждую операцию.
    private let ratios: TokenRatioStore?

    public init(
        baseURLString: String,
        log: @escaping LogHandler = noopLogHandler,
        timeouts: TimeoutSettings = TimeoutSettings(),
        cache: EmbeddingCache? = nil,
        ratios: TokenRatioStore? = nil
    ) throws {
        let normalized = baseURLString.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: normalized), url.scheme != nil, url.host != nil else {
            throw LMStudioError.badURL(baseURLString)
        }
        self.baseURL = url
        self.log = log
        self.timeouts = timeouts
        self.cache = cache
        self.ratios = ratios
        let configuration = URLSessionConfiguration.ephemeral
        // Every call names its own deadline; the session must not cut short an
        // embedding batch that legitimately takes minutes on a CPU.
        configuration.timeoutIntervalForRequest = TimeoutSettings.allowedRange.upperBound
        configuration.timeoutIntervalForResource = TimeoutSettings.allowedRange.upperBound
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Models

    struct ModelsResponse: Decodable {
        struct Model: Decodable {
            let id: String
            let type: String?
            let max_context_length: Int?
            let loaded_context_length: Int?
        }
        let data: [Model]
    }

    /// Разбор ответа списка моделей — отдельно от сетевого вызова, чтобы
    /// «какой тип приходит из API» проверялось тестом, а не догадкой.
    static func decodeModelsForTesting(_ data: Data) throws -> [LMStudioModel] {
        try JSONDecoder().decode(ModelsResponse.self, from: data).data.map(describe)
    }

    /// Lists what LM Studio currently exposes.
    ///
    /// The native endpoint is asked first: it is the only one that reports the
    /// model's type and its context length. The OpenAI-compatible list has
    /// neither — every model comes back as «тип неизвестен, контекст неизвестен»,
    /// which then costs a probe per model and still gets the type wrong, because
    /// LM Studio answers an embedding call for chat models too.
    ///
    /// An LM Studio too old for `/api/v0` falls back to `/v1/models`, and the
    /// probe path stays for exactly that case.
    public func models() async throws -> [LMStudioModel] {
        if let native = try? await get("/api/v0/models"),
           let payload = try? JSONDecoder().decode(ModelsResponse.self, from: native),
           !payload.data.isEmpty {
            return payload.data.map(Self.describe)
        }

        let data = try await get("/v1/models")
        guard let payload = try? JSONDecoder().decode(ModelsResponse.self, from: data) else {
            throw LMStudioError.emptyResponse
        }
        return payload.data.map(Self.describe)
    }

    static func describe(_ model: ModelsResponse.Model) -> LMStudioModel {
        let kind: LMStudioModelKind
        switch model.type?.lowercased() {
        case .some(let value) where value.contains("embed"):
            kind = .embedding
        case .some(let value) where value == "llm" || value.contains("chat") || value == "vlm":
            kind = .chat
        default:
            kind = .unknown
        }
        return LMStudioModel(
            id: model.id,
            kind: kind,
            rawType: model.type,
            // `max_context_length` is the ceiling the runtime will grow to;
            // `loaded_context_length` is what it started with.
            contextLength: model.max_context_length ?? model.loaded_context_length,
            // Без запасного варианта: у незагруженной модели загруженного
            // контекста ещё не существует, и подставить сюда потолок значило бы
            // считать бюджет по числу в разы большему настоящего — ровно тот
            // дефект, против которого это поле и заведено.
            loadedContextLength: model.loaded_context_length,
            kindIsInferred: false
        )
    }

    /// Fallback when the API does not report a type: try a tiny embedding call.
    public func detectKind(of modelID: String) async -> LMStudioModelKind {
        do {
            let vectors = try await embed(texts: ["ping"], model: modelID)
            return vectors.first?.isEmpty == false ? .embedding : .chat
        } catch {
            return .chat
        }
    }

    public func checkConnection() async throws -> Int {
        let models = try await models()
        log(.success, "LM Studio", "Соединение установлено, моделей доступно: \(models.count)")
        return models.count
    }

    // MARK: - Embeddings

    private struct EmbeddingsResponse: Decodable {
        struct Item: Decodable {
            let embedding: [Double]
            let index: Int?
        }
        let data: [Item]
        let model: String?
    }

    /// Only what is not already known goes to the model.
    ///
    /// The order of the answer follows the order of `texts`, cached or not —
    /// callers zip it with their own arrays and would silently mismatch chunks
    /// to vectors otherwise.
    public func embed(texts: [String], model: String) async throws -> [[Double]] {
        guard !texts.isEmpty else { return [] }
        guard let cache else { return try await embedWithoutCache(texts, model: model) }

        var known: [Int: [Double]] = [:]
        var missingIndexes: [Int] = []
        for (index, text) in texts.enumerated() {
            if let vector = await cache.vector(model: model, text: text) {
                known[index] = vector
            } else {
                missingIndexes.append(index)
            }
        }
        guard !missingIndexes.isEmpty else {
            return texts.indices.map { known[$0] ?? [] }
        }

        let computed = try await embedWithoutCache(missingIndexes.map { texts[$0] }, model: model)
        guard computed.count == missingIndexes.count else { throw LMStudioError.emptyResponse }

        // The dimension cannot be part of the key — at lookup time the vector
        // does not exist yet. This is where it gets checked: a model swapped
        // under the same name makes every cached vector of that name an answer
        // from a different model, not a stale one.
        if let fresh = computed.first?.count, known.values.contains(where: { $0.count != fresh }) {
            log(.warning, "Кэш", "Размерность модели \(model) изменилась — кэш этой модели сброшен, батч считается заново")
            await cache.removeAll(model: model)
            let recomputed = try await embedWithoutCache(texts, model: model)
            for (index, vector) in recomputed.enumerated() {
                await cache.store(model: model, text: texts[index], vector: vector)
            }
            return recomputed
        }

        for (offset, index) in missingIndexes.enumerated() {
            known[index] = computed[offset]
            await cache.store(model: model, text: texts[index], vector: computed[offset])
        }
        return texts.indices.map { known[$0] ?? [] }
    }

    /// Straight to the model, past the cache. Indexing must never use this
    /// — it exists so a benchmark measures the model rather than the cache.
    public func embedIgnoringCache(texts: [String], model: String) async throws -> [[Double]] {
        guard !texts.isEmpty else { return [] }
        return try await embedWithoutCache(texts, model: model)
    }

    private func embedWithoutCache(_ texts: [String], model: String) async throws -> [[Double]] {
        let body: [String: Any] = ["model": model, "input": texts]
        let data = try await send(
            path: "/v1/embeddings",
            method: "POST",
            body: try JSONSerialization.data(withJSONObject: body),
            timeout: timeouts.embedding,
            what: String(localized: "эмбеддинг батча из \(texts.count) текстов")
        )
        return try Self.orderedEmbeddings(from: data, sent: texts.count, model: model)
    }

    /// Раскладывает ответ на эмбеддинги в порядке отправленных текстов.
    ///
    /// Отдельно и статически — как `decodeModelsForTesting`: выравнивание
    /// вектора с текстом это самое дорогое место всей подсистемы, и проверять
    /// его надо на фиксированных ответах, а не через живой сервер.
    static func orderedEmbeddings(from data: Data, sent: Int, model: String) throws -> [[Double]] {
        guard let payload = try? JSONDecoder().decode(EmbeddingsResponse.self, from: data),
              !payload.data.isEmpty
        else {
            throw LMStudioError.modelNotEmbedding(model)
        }

        // Порядок восстанавливается по `index`, а при его отсутствии остаётся
        // тем, в котором пришёл. Сортировка по константе полагалась бы на
        // устойчивость `sorted`, которой Swift не гарантирует: в пакете без
        // `index` векторы могли бы разъехаться по чужим текстам — самая
        // дорогая из возможных здесь ошибок, и притом бесшумная.
        let items = payload.data.contains(where: { $0.index == nil })
            ? payload.data
            : payload.data.sorted { ($0.index ?? 0) < ($1.index ?? 0) }

        // Сверка количества — здесь, а не у вызывающих сторон. Четыре из пяти
        // её делали, пятая (импорт коллекции) не делала, и `zip` там молча
        // отбрасывал хвост документов. Проверка в одном месте действует на все
        // пути сразу, включая тот, где кэш выключен настройкой: раньше при
        // выключенном кэше сверка пропадала вовсе, хотя настройка про
        // скорость, а не про целостность.
        guard items.count == sent else {
            throw LMStudioError.embeddingCountMismatch(sent: sent, received: items.count)
        }

        // Кто на самом деле ответил. Проверка здесь, вместе со сверкой
        // количества: оба вопроса — «то ли мы получили, что просили», и оба
        // должны действовать на все пути сразу, включая выключенный кэш.
        if let returned = payload.model, substituted(requested: model, returned: returned) {
            throw LMStudioError.modelSubstituted(requested: model, returned: returned)
        }
        return items.map(\.embedding)
    }

    /// Ответила ли LM Studio от **другой** модели, чем просили.
    ///
    /// Сравнение нестрогое, и это осознанно. Живые замеры показали три вида
    /// расхождений, ни одно из которых не является подменой:
    ///
    /// * регистр — на `TEXT-EMBEDDING-QWEN3-EMBEDDING-4B` приходит
    ///   `text-embedding-qwen3-embedding-4b`;
    /// * издатель в начале — `google/gemma-4-e2b` против `gemma-4-e2b`;
    /// * квантование в конце — `qwen3.8-27b-mlx@4bit` против `qwen3.8-27b-mlx`;
    /// * сокращённое имя — на `qwen3-embedding-4b` приходит полное
    ///   `text-embedding-qwen3-embedding-4b`, то есть имя **разрешено**,
    ///   а не подменено.
    ///
    /// Поэтому совпадением считается не только равенство, но и вхождение
    /// одного имени в другое. Плата за мягкость — модель, чьё имя является
    /// началом имени другой (`qwen3-4b` и `qwen3-4b-thinking`), подмены
    /// не покажет. Для эмбеддинговых моделей такой пары в живом списке нет,
    /// а ложная остановка индексации стоила бы дороже: она ломает работу
    /// там, где всё в порядке.
    static func substituted(requested: String, returned: String) -> Bool {
        let asked = canonicalModelID(requested)
        let answered = canonicalModelID(returned)
        guard !asked.isEmpty, !answered.isEmpty else { return false }
        guard asked != answered else { return false }
        return !asked.contains(answered) && !answered.contains(asked)
    }

    /// Имя модели без издателя и квантования, в нижнем регистре.
    static func canonicalModelID(_ id: String) -> String {
        let withoutPublisher = id.split(separator: "/").last.map(String.init) ?? id
        let withoutQuantisation = withoutPublisher.split(separator: "@").first.map(String.init) ?? withoutPublisher
        return withoutQuantisation.trimmingCharacters(in: .whitespaces).lowercased()
    }

    public func embed(text: String, model: String) async throws -> [Double] {
        guard let vector = try await embed(texts: [text], model: model).first else {
            throw LMStudioError.emptyResponse
        }
        return vector
    }

    // MARK: - Chat

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
                /// Канал рассуждения у «думающих» моделей.
                ///
                /// Обычно здесь размышления, а ответ — в `content`. Но при
                /// Structured Output у qwen3.5 всё наоборот: `content` пуст,
                /// а ответ по схеме лежит **здесь**. Измерено вживую
                ///: тот же промпт без схемы даёт `content: "Привет"`
                /// и рассуждения в этом поле, со схемой — `content: ""`
                /// и `{"word": "Привет"}` в нём.
                let reasoning_content: String?
            }
            let message: Message?
            /// the one field that says whether the answer is complete.
            let finish_reason: String?
        }
        struct Usage: Decodable {
            let prompt_tokens: Int?
            /// Длина ответа — вторая половина замера скорости.
            let completion_tokens: Int?
        }
        let choices: [Choice]
        /// Единственное место во всём API, где сообщается **настоящее** число
        /// токенов промпта. Токенизатора LM Studio не отдаёт (проверено:
        /// `/v1/tokenize` и родственники — «Unexpected endpoint»), поэтому
        /// откалибровать оценку можно только отсюда.
        let usage: Usage?
    }

    /// How many answers ended by running out of tokens this session.
    ///
    /// G3 asks for this to be visible: an occasional truncation is a long
    /// document, a systematic one is a wrong `max_tokens`, and the difference
    /// is only legible as a count.
    public private(set) var truncatedAnswerCount = 0

    // MARK: - Скорость письма

    /// Токенов в секунду, по модели. Худшее из наблюдённого, а не среднее:
    /// из этого числа считается, сколько модель успеет написать за отпущенное
    /// ей время, и ошибаться здесь можно только в сторону меньшего окна.
    private var generationSpeeds: [String: Double] = [:]

    /// Сколько токенов просит калибровка.
    static let speedSampleTokens = 200

    /// Короче этого ответ в замер не идёт: в нём время съедает не письмо,
    /// а чтение промпта и накладные расходы, и скорость выходит заниженной.
    ///
    /// Заведомо меньше, чем просит калибровка, и это не перестраховка:
    /// LM Studio на `max_tokens: 200` возвращает 199 (проверено вживую), и
    /// порог, равный запросу, отбрасывал бы собственный замер — ровно это
    /// и происходило, пока живой тест не показал.
    static let minimumSpeedSample = 100

    /// Промпт калибровки: попросить ничего не значащего текста побольше —
    /// ответ выбрасывается, важно только время.
    ///
    /// С наполнителем, а не короткой строкой, и это существенно. Скорость
    /// падает по мере наполнения контекста: на этой машине измерено 118 ток/с
    /// при промпте в 19 токенов, 105 при 27, 86 при 811, 81 при 2187 и 72 при
    /// 10 616. Замер на пустом контексте давал 105 и обещал вдвое большее
    /// окно, чем модель успевала переписать, — прогон снова упирался в таймаут
    /// (поймано живым прогоном). Наполнитель примерно на 2000 токенов
    /// ставит замер в те же условия, в которых пойдёт работа.
    static let speedCalibrationPrompt: String = {
        let sentence = "Текст для замера скорости: обычное предложение на русском языке. "
        return "Перечисли числа от 1 до 500 через запятую. Текст ниже читать не нужно.\n\n"
            + String(repeating: sentence, count: 62)
    }()

    private func recordSpeed(model: String, tokens: Int?, seconds: TimeInterval) {
        guard let tokens, tokens >= Self.minimumSpeedSample, seconds > 0 else { return }
        let speed = Double(tokens) / seconds
        generationSpeeds[model] = min(generationSpeeds[model] ?? .greatestFiniteMagnitude, speed)
    }

    /// Сколько токенов в секунду пишет эта модель здесь и сейчас.
    ///
    /// Сначала — то, что уже намерено на настоящих вызовах: они длиннее
    /// калибровочного и потому честнее. Если мерить ещё не на чем, делается
    /// один короткий вызов: две секунды перед прогоном на много часов.
    /// Ответ выбрасывается, важно только время.
    public func generationSpeed(of model: String) async -> Double? {
        if let known = generationSpeeds[model] { return known }
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": Self.speedCalibrationPrompt]],
            "max_tokens": Self.speedSampleTokens,
            "temperature": 0,
            "stream": false,
        ]
        let started = Date()
        do {
            let data = try await send(
                path: "/v1/chat/completions",
                method: "POST",
                body: try JSONSerialization.data(withJSONObject: body),
                timeout: timeouts.chat,
                what: String(localized: "замер скорости модели \(model)")
            )
            let payload = try JSONDecoder().decode(ChatResponse.self, from: data)
            recordSpeed(
                model: model,
                tokens: payload.usage?.completion_tokens,
                seconds: Date().timeIntervalSince(started)
            )
        } catch {
            // Замер — не обязанность модели: не вышло, значит время в расчёт
            // окна не берётся, как и было до.
            log(.debug, "LM Studio", "Скорость модели «\(model)» замерить не удалось: \(error.localizedDescription)")
        }
        return generationSpeeds[model]
    }

    /// One-shot completion, used by LLM-based chunking.
    ///
    /// `timeout` is per call and shorter than the session's own: a model that
    /// stops answering must not be able to hang a whole folder's sync.
    ///
    /// Passing a `schema` constrains the answer to it — with LM Studio the
    /// model then physically cannot emit a token that breaks the structure,
    /// which removes the whole class of defects `on_malformed_output` exists to
    /// paper over. The fallback stays for models and versions without support.
    public func complete(
        prompt: String,
        model: String,
        settings: ChatGenerationSettings = ChatGenerationSettings(),
        schema: ChatJSONSchema? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "stream": false,
        ]
        body.merge(settings.requestFields()) { _, new in new }
        if let schema {
            body["response_format"] = schema.requestValue()
        }

        let started = Date()
        let data = try await send(
            path: "/v1/chat/completions",
            method: "POST",
            body: try JSONSerialization.data(withJSONObject: body),
            timeout: timeout ?? timeouts.chat,
            what: String(localized: "ответ чат-модели \(model)")
        )
        guard let payload = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let choice = payload.choices.first else {
            throw LMStudioError.emptyResponse
        }
        await ratios?.record(
            characters: prompt.count, tokens: payload.usage?.prompt_tokens, model: model
        )
        // Замер до разбора ответа: оборванный по лимиту ответ — самый длинный
        // из возможных, и для скорости он годится ровно так же.
        recordSpeed(
            model: model,
            tokens: payload.usage?.completion_tokens,
            seconds: Date().timeIntervalSince(started)
        )

        // Checked before the content is even looked at, and regardless of
        // whether a schema was used: a schema guarantees a well-formed answer
        // only if the model is allowed to finish it.
        if choice.finish_reason == "length" {
            truncatedAnswerCount += 1
            log(.warning, "Чанкинг", "Ответ модели «\(model)» оборван по лимиту токенов — обрабатывается как некорректный (всего за сеанс: \(truncatedAnswerCount.plainDigits))")
            throw LMStudioError.truncatedByTokenLimit(model: model)
        }

        guard let answer = Self.answerText(
            content: choice.message?.content, reasoning: choice.message?.reasoning_content
        ) else {
            throw LMStudioError.emptyResponse
        }
        if answer == choice.message?.reasoning_content {
            reasoningFallbackCount += 1
            if reasoningFallbackCount == 1 {
                log(
                    .info, "LM Studio",
                    "Модель «\(model)» отвечает в канале рассуждения, поле content пустое — "
                    + "ответ берётся оттуда. Так ведут себя «думающие» модели при заданной схеме ответа."
                )
            }
        }
        return answer
    }


    /// Сколько раз за сеанс ответ пришлось взять из канала рассуждения.
    /// Считается, чтобы разовая особенность одной модели не выглядела нормой.
    public private(set) var reasoningFallbackCount = 0

    /// Какой текст считается ответом на такое сообщение — правило отдельно
    /// от сети, чтобы его можно было проверить тестом на настоящих ответах
    /// LM Studio, не поднимая сервер.
    static func answerText(content: String?, reasoning: String?) -> String? {
        if let content, !content.isEmpty { return content }
        if let reasoning, !reasoning.isEmpty { return reasoning }
        return nil
    }

    /// Сырое дополнение через `/v1/completions` — без шаблона чата.
    ///
    /// Нужно ровно для одного: специализированные переранжировщики ждут
    /// собственную разметку промпта, а шаблон чата, который LM Studio
    /// подставляет на `/v1/chat/completions`, её ломает — модель отвечает
    /// «No document is provided» вместо «yes»/«no». Здесь текст уходит как есть.
    public func rawCompletion(
        prompt: String,
        model: String,
        maxTokens: Int = 4,
        timeout: TimeInterval? = nil
    ) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "max_tokens": maxTokens,
            "temperature": 0,
            "stream": false,
        ]
        let data = try await send(
            path: "/v1/completions",
            method: "POST",
            body: try JSONSerialization.data(withJSONObject: body),
            timeout: timeout ?? timeouts.chat,
            what: String(localized: "ответ модели \(model)")
        )
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = payload["choices"] as? [[String: Any]],
              let text = choices.first?["text"] as? String
        else { throw LMStudioError.emptyResponse }
        return text
    }

    /// Загруженный контекст по моделям. Спрашивается один раз: значение
    /// меняется при перезагрузке модели, а список — не бесплатный вызов.
    private var loadedContextCache: [String: Int?] = [:]

    /// Потолок контекста модели — предел входа для эмбеддингов.
    public func contextLength(of model: String) async -> Int? {
        if let cached = contextCeilingCache[model] { return cached }
        let value = (try? await models())?.first { $0.id == model }?.contextLength
        contextCeilingCache[model] = value
        return value
    }

    private var contextCeilingCache: [String: Int?] = [:]

    // MARK: - Калибровка оценки токенов

    /// `ChatProvider`: сколько символов приходится на токен у этой модели,
    /// по измерениям. `nil` — ещё ни одного ответа с `usage` не приходило
    /// или хранилище не подключено.
    public func charactersPerToken(of model: String) async -> Double? {
        await ratios?.ratio(of: model)
    }

    /// `ChatProvider`: контекст, с которым модель загружена сейчас.
    ///
    /// У незагруженной модели этого числа не существует, и LM Studio отдаёт
    /// `null`. Ответить «не знаю» значило бы отключить бюджет ровно на первом
    /// вызове — том самом, который модель и загрузит. Поэтому она сначала
    /// загружается крошечным запросом (LM Studio делает это и так, по первому
    /// обращению — здесь лишь сдвинуто на шаг раньше), и только после этого
    /// число спрашивается по-настоящему.
    /// Потолок контекста модели по её карточке в LM Studio.
    public func maximumContextLength(of model: String) async -> Int? {
        (try? await models())?.first { $0.id == model }?.contextLength
    }

    public func loadedContextLength(of model: String) async -> Int? {
        if let cached = loadedContextCache[model] { return cached }
        var value = await reportedLoadedContextLength(of: model)
        if value == nil {
            // Прогрев: незагруженная **чат**-модель о своём контексте молчит,
            // и один короткий вызов заставляет LM Studio её поднять. Для
            // переранжировщика это осмысленно — он всё равно сейчас нужен.
            _ = try? await rawCompletion(prompt: " ", model: model, maxTokens: 1)
            value = await reportedLoadedContextLength(of: model)
        }
        loadedContextCache[model] = value
        return value
    }

    /// То же, но **без прогрева**: только то, что рантайм уже говорит.
    ///
    /// Для эмбеддинг-модели будить нечем: порождающий вызов ей не подходит —
    /// она ответит ошибкой, а LM Studio по дороге поднимет её по JIT и
    /// выгрузит занятую. Признак свежести измеренного предела такой цены
    /// не стоит: не знаем — отвечаем `nil`.
    public func reportedLoadedContextLength(of model: String) async -> Int? {
        (try? await models())?.first { $0.id == model }?.loadedContextLength
    }

    /// whether this model actually honours a JSON schema, asked once and
    /// remembered, so the form can say which mode it is in before a run starts.
    private var structuredOutputSupport: [String: Bool] = [:]

    public func supportsStructuredOutput(model: String) async -> Bool {
        if let known = structuredOutputSupport[model] { return known }
        let probe = ChatJSONSchema(
            name: "probe",
            schema: ["type": "object", "properties": ["ok": ["type": "boolean"]], "required": ["ok"]]
        )
        do {
            let answer = try await complete(
                prompt: "Answer with {\"ok\": true}",
                model: model,
                settings: ChatGenerationSettings(temperature: 0, seed: nil, maxTokens: 2000),
                schema: probe,
                timeout: timeouts.chat
            )
            let supported = (try? JSONSerialization.jsonObject(with: Data(answer.utf8))) != nil
            structuredOutputSupport[model] = supported
            return supported
        } catch {
            // A refusal is an answer: this model does not do schemas. A timeout
            // is not, so it is not remembered as a «no».
            if case LMStudioError.api = error {
                structuredOutputSupport[model] = false
                return false
            }
            return false
        }
    }

    // MARK: - Transport

    private func get(_ path: String) async throws -> Data {
        try await send(path: path, method: "GET", body: nil)
    }

    private func post(_ path: String, body: [String: Any]) async throws -> Data {
        try await send(path: path, method: "POST", body: try JSONSerialization.data(withJSONObject: body))
    }

    private func send(
        path: String,
        method: String,
        body: Data?,
        timeout: TimeInterval? = nil,
        what: String = "запрос"
    ) async throws -> Data {
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw LMStudioError.badURL(baseURL.absoluteString + path)
        }
        let deadline = timeout ?? timeouts.metadata
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = deadline
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let data: Data
        let response: URLResponse
        do {
            let session = self.session
            let prepared = request
            (data, response) = try await withDeadline(
                seconds: deadline,
                onExpiry: { LMStudioError.timedOut(what: what, seconds: deadline) },
                work: { try await session.data(for: prepared) }
            )
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                // A cancellation that lands inside the request comes back as a
                // URLError, and «LM Studio недоступна: отменено» is a lie the
                // user then has to debug. Callers tell «отменено» from «сломалось»
                // by the error type, so it has to be thrown as such.
                throw CancellationError()
            case .cannotConnectToHost, .cannotFindHost:
                throw LMStudioError.unreachable("не удалось подключиться к \(baseURL.absoluteString)")
            case .timedOut:
                throw LMStudioError.unreachable("истекло время ожидания ответа")
            default:
                throw LMStudioError.unreachable(error.localizedDescription)
            }
        }

        guard let http = response as? HTTPURLResponse else { throw LMStudioError.emptyResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8)?.prefix(300).description ?? "нет тела ответа"
            throw LMStudioError.api(status: http.statusCode, message: message)
        }
        return data
    }
}
