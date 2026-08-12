import Foundation

/// The texts a benchmark runs on.
///
/// Fixed in code rather than read from a folder: the whole point of the numbers
/// is that they are comparable between models and between runs, and a corpus
/// the user can edit is not. Three lengths, because throughput depends on them
/// — a model that is fast on titles can be slow on paragraphs.
public enum BenchmarkCorpus {
    /// Roughly a heading or a search query.
    public static let short = [
        "Векторная база данных",
        "Индексация документов",
        "Поиск по смыслу, а не по словам",
        "Размерность эмбеддинга",
        "Косинусное расстояние",
        "Локальная модель",
        "Чанкинг по абзацам",
        "Метаданные коллекции",
    ]

    /// Roughly a sentence or two — the size of a small chunk.
    public static let medium = [
        "Векторный поиск находит документы по смыслу запроса, а не по совпадению слов: близость измеряется расстоянием между векторами.",
        "Размерность вектора задаётся моделью и не может быть изменена после создания коллекции — векторы разных размерностей несравнимы.",
        "Инкрементальная синхронизация пересчитывает только изменившиеся файлы: содержимое сверяется по хэшу, а не по дате изменения.",
        "Чанкинг разрезает документ на фрагменты; от их границ зависит и качество поиска, и стоимость индексации.",
        "Кэш эмбеддингов хранит уже посчитанные векторы по паре «модель + текст» и не влияет на результат — только на время.",
        "Метрика расстояния выбирается один раз при создании коллекции: косинусная для нормализованных векторов, евклидова для остальных.",
    ]

    /// Roughly a full chunk of prose — where per-text time is dominated by the
    /// text itself rather than by the round trip.
    public static let long = [
        String(repeating: "Приложение считает векторы на своей стороне и передаёт их в базу уже готовыми: это позволяет менять модель, не трогая сервер, и точно знать, чем посчитан каждый вектор в коллекции. ", count: 6),
        String(repeating: "Размер батча влияет на пропускную способность нелинейно: слишком маленький тратит время на накладные расходы запроса, слишком большой упирается в память и начинает замедляться. ", count: 6),
        String(repeating: "Первый вызов к модели почти всегда дороже последующих, потому что веса подгружаются в память. Эту величину нужно измерять отдельно, иначе она размажется по среднему и исказит все оценки времени. ", count: 6),
        String(repeating: "Оценка времени, построенная на выдуманных числах, хуже отсутствия оценки: пользователь верит ей и планирует по ней работу, а расхождение обнаруживается через час прогона. ", count: 6),
    ]

    /// Every text of the corpus, in a fixed order.
    public static var allTexts: [String] { short + medium + long }

    /// Batch sizes the benchmark tries. Powers of two up to a size that is large
    /// enough to show the curve flattening, but not so large that a slow model
    /// makes the run unbearable.
    public static let batchSizes = [1, 4, 8, 16]

    public static var totalCalls: Int {
        // One warm-up call plus one call per batch of every batch size.
        1 + batchSizes.reduce(0) { $0 + Int(ceil(Double(allTexts.count) / Double($1))) }
    }
}

/// One measured batch size.
public struct BenchmarkBatchResult: Codable, Hashable, Identifiable, Sendable {
    public let batchSize: Int
    public let texts: Int
    public let seconds: Double

    public var id: Int { batchSize }
    public var textsPerSecond: Double { seconds > 0 ? Double(texts) / seconds : 0 }
    public var secondsPerText: Double { texts > 0 ? seconds / Double(texts) : 0 }

    public init(batchSize: Int, texts: Int, seconds: Double) {
        self.batchSize = batchSize
        self.texts = texts
        self.seconds = seconds
    }
}

/// What one measurement of one model produced.
public struct ModelBenchmark: Codable, Hashable, Identifiable, Sendable {
    public let model: String
    public let measuredAt: Date
    public let dimension: Int
    /// The very first call, measured on its own and excluded from everything
    /// else: the model is usually being loaded into memory during it, and that
    /// cost is real but happens once — averaging it in would inflate every
    /// estimate that follows.
    public let firstCallSeconds: Double
    public let batches: [BenchmarkBatchResult]

    public var id: String { model }

    /// The batch size that produced the highest throughput.
    public var optimalBatchSize: Int? {
        batches.max { $0.textsPerSecond < $1.textsPerSecond }?.batchSize
    }

    /// Texts per second at the best batch size — the headline number.
    public var textsPerSecond: Double {
        batches.map(\.textsPerSecond).max() ?? 0
    }

    /// Seconds per text at the best batch size, comparable with
    /// `MetricsSnapshot.ModelMetric.averageSeconds`.
    public var secondsPerText: Double {
        textsPerSecond > 0 ? 1 / textsPerSecond : 0
    }

    public init(
        model: String,
        measuredAt: Date,
        dimension: Int,
        firstCallSeconds: Double,
        batches: [BenchmarkBatchResult]
    ) {
        self.model = model
        self.measuredAt = measuredAt
        self.dimension = dimension
        self.firstCallSeconds = firstCallSeconds
        self.batches = batches
    }
}

/// A benchmark measures the model, so it must not be served by the cache.
///
/// `EmbeddingProvider.embed` answers from the cache where it can — which is
/// exactly right for indexing and exactly wrong here: on a second run it would
/// report a model that is infinitely fast.
public protocol UncachedEmbeddingProvider: Sendable {
    func embedIgnoringCache(texts: [String], model: String) async throws -> [[Double]]
}

/// Runs the fixed corpus through a model and times it.
public struct ModelBenchmarkService: Sendable {
    private let provider: UncachedEmbeddingProvider
    private let log: LogHandler
    private let now: @Sendable () -> Date

    public init(
        provider: UncachedEmbeddingProvider,
        log: @escaping LogHandler = noopLogHandler,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.log = log
        self.now = now
    }

    /// How long the run is likely to take, for the warning shown **before** it
    /// starts (rule 4, Приложение 5).
    ///
    /// Returns `nil` when nothing has ever been measured for this model: a
    /// warning with an invented number is worse than a warning without one.
    /// A previous benchmark of the same model is the honest basis; so is the
    /// average from real runs, which is why both are accepted.
    public static func estimatedSeconds(
        model: String,
        benchmarks: [ModelBenchmark],
        metrics: MetricsSnapshot
    ) -> Double? {
        let calls = Double(BenchmarkCorpus.totalCalls)
        let texts = Double(BenchmarkCorpus.allTexts.count * BenchmarkCorpus.batchSizes.count + 1)

        if let previous = benchmarks.first(where: { $0.model == model }), previous.secondsPerText > 0 {
            // The load cost is paid again only if the model has been evicted
            // since; counting it is the pessimistic side of the estimate, which
            // is the right side for a warning.
            return previous.firstCallSeconds + previous.secondsPerText * texts
        }
        if let metric = metrics.models.first(where: { $0.model == model }), metric.averageSeconds > 0 {
            // Real runs know nothing about loading the model, so a single call's
            // worth of slack is added rather than pretending it is free.
            return metric.averageSeconds * (texts + calls)
        }
        return nil
    }

    /// Measures one model. `progress` is called with 0…1 after each call so the
    /// queue panel can show movement — a run that looks frozen gets killed.
    public func run(
        model: String,
        progress: @Sendable (Double, String) async -> Void = { _, _ in }
    ) async throws -> ModelBenchmark {
        let texts = BenchmarkCorpus.allTexts
        guard !texts.isEmpty else { throw LMStudioError.emptyResponse }

        var completedCalls = 0
        let totalCalls = Double(BenchmarkCorpus.totalCalls)
        func advance(_ detail: String) async {
            completedCalls += 1
            await progress(min(1, Double(completedCalls) / totalCalls), detail)
        }

        // The first call, on its own. Everything after it talks to a model that
        // is already in memory.
        let started = now()
        let firstVectors = try await provider.embedIgnoringCache(texts: [texts[0]], model: model)
        let firstCallSeconds = now().timeIntervalSince(started)
        guard let dimension = firstVectors.first?.count, dimension > 0 else {
            throw LMStudioError.modelNotEmbedding(model)
        }
        await advance(String(localized: "первый вызов: \(String(format: "%.2f", firstCallSeconds)) с"))

        var batches: [BenchmarkBatchResult] = []
        for size in BenchmarkCorpus.batchSizes {
            try Task.checkCancellation()
            var seconds: Double = 0
            var counted = 0
            for chunk in stride(from: 0, to: texts.count, by: size) {
                try Task.checkCancellation()
                let slice = Array(texts[chunk..<min(chunk + size, texts.count)])
                let batchStarted = now()
                let vectors = try await provider.embedIgnoringCache(texts: slice, model: model)
                seconds += now().timeIntervalSince(batchStarted)
                guard vectors.count == slice.count else { throw LMStudioError.emptyResponse }
                // A model swapped under the same name mid-run would make the
                // whole measurement meaningless rather than merely wrong.
                if let other = vectors.first(where: { $0.count != dimension }) {
                    log(.error, "Бенчмарк", "Модель «\(model)» вернула вектор размерности \(other.count) вместо \(dimension) — измерение прервано")
                    throw LMStudioError.modelNotEmbedding(model)
                }
                counted += slice.count
                await advance(String(localized: "батч по \(size): \(counted) из \(texts.count)"))
            }
            batches.append(BenchmarkBatchResult(batchSize: size, texts: counted, seconds: seconds))
        }

        let result = ModelBenchmark(
            model: model,
            measuredAt: now(),
            dimension: dimension,
            firstCallSeconds: firstCallSeconds,
            batches: batches
        )
        log(
            .info,
            "Бенчмарк",
            "Модель «\(model)»: \(String(format: "%.1f", result.textsPerSecond)) текстов/с при батче \(result.optimalBatchSize ?? 0), размерность \(dimension), первый вызов \(String(format: "%.2f", firstCallSeconds)) с"
        )
        return result
    }
}

/// Measured models, kept next to everything else the app writes.
public actor BenchmarkStore {
    private let file: GuardedJSONFile<[ModelBenchmark]>
    private let log: LogHandler
    private var benchmarks: [ModelBenchmark]

    public init(fileURL: URL = AppPaths.benchmarksFile, log: @escaping LogHandler = noopLogHandler) {
        self.file = GuardedJSONFile(url: fileURL, category: "Эмбеддинги", log: log)
        self.log = log
        self.benchmarks = file.value(or: [])
    }

    /// Почему ничего не сохраняется, если это так. Замер скорости —
    /// минуты занятой модели, и терять его из-за одного неудачного чтения
    /// незачем.
    public func persistenceProblem() -> String? { file.problem }

    public func all() -> [ModelBenchmark] {
        benchmarks.sorted { $0.textsPerSecond > $1.textsPerSecond }
    }

    public func benchmark(for model: String) -> ModelBenchmark? {
        benchmarks.first { $0.model == model }
    }

    /// A model is measured once; measuring it again replaces the old numbers
    /// rather than averaging with them — the machine or the LM Studio version
    /// may well have changed in between, and an average across those is a
    /// number describing nothing.
    public func store(_ benchmark: ModelBenchmark) {
        benchmarks.removeAll { $0.model == benchmark.model }
        benchmarks.append(benchmark)
        save()
    }

    public func remove(model: String) {
        benchmarks.removeAll { $0.model == model }
        save()
    }

    private func save() { file.write(benchmarks) }
}
