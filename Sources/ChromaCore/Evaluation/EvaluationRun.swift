import Foundation

/// One thing being compared: a collection plus the search parameters.
///
/// A pair «коллекция + профиль поиска» rather than a collection alone:
/// two variants that differ only by profile compare two settings of the same
/// data and cost no cloning at all, which is the cheapest useful comparison
/// there is.
///
/// The profile is stored **by value**. A variant that referred to a profile by
/// id would describe something different every time the profile was edited, and
/// a run from last month would then claim to have compared parameters it never
/// saw — D1.2 asks for «полные параметры вариантов» exactly to prevent that.
public struct EvaluationVariant: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// The column header in the report — the user's own words for what this
    /// variant is («512 символов», «модель bge»).
    public var name: String
    public var collectionID: String
    public var collectionName: String
    /// The embedding model bound to the collection. **The deduplication key**
    /// together with the query text: variants on the same model share a vector.
    public var model: String
    /// Taken from the collection, not chosen here — the metric is a property of
    /// the stored vectors.
    public var metric: DistanceMetric?
    public var nResults: Int
    public var filter: DocumentFilter?
    /// The full pipeline configuration this variant searched with.
    public var profile: SearchProfile
    public var note: String

    public init(
        id: UUID = UUID(),
        name: String,
        collectionID: String,
        collectionName: String,
        model: String,
        metric: DistanceMetric? = nil,
        nResults: Int = 10,
        filter: DocumentFilter? = nil,
        profile: SearchProfile,
        note: String = ""
    ) {
        self.id = id
        self.name = name
        self.collectionID = collectionID
        self.collectionName = collectionName
        self.model = model
        self.metric = metric
        self.nResults = nResults
        self.filter = filter
        self.profile = profile
        self.note = note
    }

    /// Whether this variant needs the query as a vector at all.
    ///
    /// «Только текстовый поиск» needs none, and a run of such variants must not
    /// call the model once — nor be charged for it in the estimate.
    public var needsVector: Bool {
        profile.vectorSearchEnabled || !profile.textSearchEnabled
    }

    public var line: String {
        var parts = [String(localized: "коллекция «\(collectionName)»"), String(localized: "профиль «\(profile.name)»")]
        parts.append(String(localized: "n_results \(nResults)"))
        if filter != nil { parts.append(String(localized: "с фильтром")) }
        return parts.joined(separator: " · ")
    }
}

/// One result of one variant, as it came back.
///
/// The text is kept in full, not a preview: marking turns it into ground
/// truth, and a fragment cut from an already-cut preview would be ground truth
/// for a passage nobody can find again.
public struct EvaluationHit: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var text: String?
    public var distance: Double?
    /// 1-based, as the variant ranked it.
    public var position: Int
    /// Метаданные результата — чтобы из прогона можно было открыть исходник
    /// (H1.3: «просмотр доступен и из результатов стенда оценки»).
    ///
    /// Хранятся в самом прогоне, а не добираются из базы при показе: прогон
    /// обязан оставаться читаемым через месяц, когда коллекции уже может
    /// не быть, — а без `source_id` и `source_file` файл не найти.
    public var metadata: ChromaMetadata?

    public init(
        id: String, text: String?, distance: Double?, position: Int,
        metadata: ChromaMetadata? = nil
    ) {
        self.id = id
        self.text = text
        self.distance = distance
        self.position = position
        self.metadata = metadata
    }

    /// Прогоны, записанные до появления метаданных, обязаны читаться.
    ///
    /// Синтезированный декодер потребовал бы новое поле, и все сохранённые
    /// прогоны стали бы нечитаемыми — ровно то, что уже случилось с файлом
    /// статистики. Отсутствующие метаданные — это «из этого прогона исходник
    /// не открыть», а не «файл испорчен».
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        distance = try container.decodeIfPresent(Double.self, forKey: .distance)
        position = try container.decode(Int.self, forKey: .position)
        metadata = try container.decodeIfPresent(ChromaMetadata.self, forKey: .metadata)
    }
}

/// One cell of the run: what a variant answered to a query.
public struct EvaluationResult: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var queryID: UUID
    public var variantID: UUID
    public var hits: [EvaluationHit]
    /// Time spent turning the query into a vector, or `nil` when this cell paid
    /// nothing for it — either because the vector was already computed for
    /// another variant, or because the variant needs no vector.
    ///
    /// Nil rather than zero, and `reusedVector` beside it, because latency
    /// is reported «отдельно эмбеддинг и поиск»: averaging a reused
    /// vector in as zero would make the second variant of every pair look
    /// faster than it is.
    public var embeddingSeconds: TimeInterval?
    public var reusedVector: Bool
    public var searchSeconds: TimeInterval
    /// Why this cell is empty, when it is. A failed cell is not an empty answer
    /// — metrics must not count it as «ничего не нашёл».
    public var failure: String?

    public init(
        id: UUID = UUID(),
        queryID: UUID,
        variantID: UUID,
        hits: [EvaluationHit] = [],
        embeddingSeconds: TimeInterval? = nil,
        reusedVector: Bool = false,
        searchSeconds: TimeInterval = 0,
        failure: String? = nil
    ) {
        self.id = id
        self.queryID = queryID
        self.variantID = variantID
        self.hits = hits
        self.embeddingSeconds = embeddingSeconds
        self.reusedVector = reusedVector
        self.searchSeconds = searchSeconds
        self.failure = failure
    }

    public var succeeded: Bool { failure == nil }
}

/// A set of queries run against a set of variants, kept whole.
///
/// Kept whole on purpose: «к нему можно было вернуться через месяц и понять,
/// что именно сравнивалось». The queries are snapshotted beside the variants
/// because the set goes on being edited afterwards — marking results
/// writes into it — and a run that showed today's ground truth against
/// yesterday's answers would explain nothing.
public struct EvaluationRun: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var querySetID: UUID
    public var querySetName: String
    public var queries: [EvaluationQuery]
    public var variants: [EvaluationVariant]
    public var results: [EvaluationResult]
    /// False when the run did not cover every cell — cancelled, or with cells
    /// that failed. Metrics computed over an incomplete run are still shown,
    /// and are labelled as such rather than quietly averaged.
    public var isComplete: Bool
    /// Why it is incomplete, in the user's words.
    public var note: String
    public var appVersion: String

    public init(
        id: UUID = UUID(),
        name: String,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        querySetID: UUID,
        querySetName: String,
        queries: [EvaluationQuery] = [],
        variants: [EvaluationVariant] = [],
        results: [EvaluationResult] = [],
        isComplete: Bool = false,
        note: String = "",
        appVersion: String = "dev"
    ) {
        self.id = id
        self.name = name
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.querySetID = querySetID
        self.querySetName = querySetName
        self.queries = queries
        self.variants = variants
        self.results = results
        self.isComplete = isComplete
        self.note = note
        self.appVersion = appVersion
    }

    /// How many cells a complete run would have.
    public var plannedCells: Int { queries.count * variants.count }

    public func result(query: UUID, variant: UUID) -> EvaluationResult? {
        results.first { $0.queryID == query && $0.variantID == variant }
    }

    public func results(variant: UUID) -> [EvaluationResult] {
        results.filter { $0.variantID == variant }
    }

    public var failedCells: Int { results.filter { !$0.succeeded }.count }

    /// How many embedding calls the run actually made — the number the
    /// deduplication is supposed to keep down, shown afterwards so the estimate
    /// can be judged against what happened.
    public var embeddingCalls: Int { results.filter { $0.embeddingSeconds != nil }.count }

    public var line: String {
        var parts = [
            RussianCount.phrase(queries.count, "запрос", "запроса", "запросов"),
            RussianCount.phrase(variants.count, "вариант", "варианта", "вариантов"),
        ]
        if !isComplete {
            parts.append(String(localized: "прогон неполный: \(results.count) из \(plannedCells)"))
        }
        return parts.joined(separator: " · ")
    }
}

/// What a run will cost, before it starts (rule 4 of Приложение 5).
///
/// 2 makes this mandatory rather than nice: a set of twenty queries against
/// four variants is eighty searches and up to eighty calls to a local model,
/// during which nothing else can use it. The user finds out afterwards
/// otherwise.
public struct EvaluationCost: Hashable, Sendable {
    public let queries: Int
    public let variants: Int
    /// Searches against the database — always queries × variants.
    public let searchCalls: Int
    /// Calls to the embedding model, **after** deduplication by (query, model).
    public let embeddingCalls: Int
    /// How many calls the deduplication removes — the number that makes the
    /// typical «одна модель, четыре стратегии» comparison four times cheaper,
    /// and worth showing precisely because it is not obvious.
    public let savedEmbeddingCalls: Int
    /// Estimated seconds of embedding, or `nil` when the models' speed has
    /// never been measured. Never a guess.
    public let seconds: Double?
    public let basis: TableRunEstimate.Basis

    public init(
        queries: Int,
        variants: Int,
        searchCalls: Int,
        embeddingCalls: Int,
        savedEmbeddingCalls: Int,
        seconds: Double?,
        basis: TableRunEstimate.Basis
    ) {
        self.queries = queries
        self.variants = variants
        self.searchCalls = searchCalls
        self.embeddingCalls = embeddingCalls
        self.savedEmbeddingCalls = savedEmbeddingCalls
        self.seconds = seconds
        self.basis = basis
    }

    /// The estimate for a concrete plan.
    ///
    /// Only the embedding is timed. A search against ChromaDB has no measured
    /// speed in the app, and inventing one would put a number on screen that
    /// will be believed — 12.7's rule is that an estimate comes from a
    /// measurement or does not come at all.
    public static func estimate(
        queries: [EvaluationQuery],
        variants: [EvaluationVariant],
        metrics: MetricsSnapshot,
        benchmarks: [ModelBenchmark] = []
    ) -> EvaluationCost {
        var callsPerModel: [String: Int] = [:]
        var naive = 0
        for variant in variants where variant.needsVector {
            naive += queries.count
        }
        // The deduplication this stage is built around: one vector per (query,
        // model), reused by every variant on that model.
        let models = Set(variants.filter(\.needsVector).map(\.model))
        var texts = Set<String>()
        for query in queries {
            texts.insert(query.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for model in models {
            callsPerModel[model] = texts.count
        }

        var seconds: Double = 0
        var basis = TableRunEstimate.Basis.unknown
        var measuredAll = !callsPerModel.isEmpty
        for (model, calls) in callsPerModel {
            if let measured = metrics.models.first(where: { $0.model == model }), measured.averageSeconds > 0 {
                seconds += measured.averageSeconds * Double(calls)
                if basis == .unknown { basis = .measuredWork }
            } else if let benchmark = benchmarks.first(where: { $0.model == model }), benchmark.secondsPerText > 0 {
                seconds += benchmark.secondsPerText * Double(calls)
                // The weaker source wins the label: an estimate that mixed both
                // must not claim to rest on the stronger one.
                basis = .benchmark
            } else {
                measuredAll = false
            }
        }

        let embeddingCalls = callsPerModel.values.reduce(0, +)
        return EvaluationCost(
            queries: queries.count,
            variants: variants.count,
            searchCalls: queries.count * variants.count,
            embeddingCalls: embeddingCalls,
            savedEmbeddingCalls: max(0, naive - embeddingCalls),
            seconds: measuredAll && seconds > 0 ? seconds : nil,
            basis: measuredAll ? basis : .unknown
        )
    }

    public var durationText: String? {
        guard let seconds, seconds > 0 else { return nil }
        // «Около 0 с» is what rounding says about a fast model and a short set,
        // and it reads as a bug rather than as «быстро». Found on a live run of
        // two queries.
        if seconds < 1 { return String(localized: "меньше секунды") }
        if seconds < 90 { return String(localized: "около \(Int(seconds.rounded())) с") }
        if seconds < 5_400 { return String(localized: "около \(Int((seconds / 60).rounded())) мин") }
        return String(localized: "около \(String(format: "%.1f", seconds / 3_600)) ч")
    }

    /// The line shown before the start — «столько запросов, столько вызовов».
    public var line: String {
        var parts = [String(localized: "\(queries) × \(variants) = \(Self.searches(searchCalls))")]
        parts.append(String(localized: "вызовов эмбеддинга: \(embeddingCalls)"))
        if savedEmbeddingCalls > 0 {
            parts.append(String(localized: "переиспользовано векторов: \(savedEmbeddingCalls)"))
        }
        if let durationText {
            parts.append(String(localized: "\(durationText) на эмбеддинг — \(basis.title)"))
        } else if embeddingCalls > 0 {
            parts.append(basis.title)
        }
        return parts.joined(separator: " · ")
    }

    /// «1 поисковых запрос» — прилагательное согласуется так же, как
    /// существительное, и рассогласование в первой же строке экрана выглядит
    /// как ошибка во всём остальном. Найдено на живом прогоне из одного запроса.
    public static func searches(_ count: Int) -> String {
        let adjective = RussianCount.word(count, "поисковый", "поисковых", "поисковых")
        return "\(count) \(adjective) \(RussianCount.word(count, "запрос", "запроса", "запросов"))"
    }

    /// Above this many searches the run is long enough that starting it by
    /// accident is a real cost (rule 4).
    public static let warningThreshold = 100

    public var isLong: Bool {
        searchCalls > Self.warningThreshold || (seconds ?? 0) > 120
    }
}
