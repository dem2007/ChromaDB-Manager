import Foundation

/// One number of the report, with what it was counted on.
///
/// `nil` is a first-class answer: «метрика неприменима» is different from
/// «метрика равна нулю», and a table that printed 0 for both would be read as
/// «этот вариант ничего не нашёл». The reason travels with the absence, because
/// «—» in a cell nobody can explain is worse than no cell at all.
public struct MetricScore: Hashable, Sendable {
    public let value: Double?
    /// How many queries the number rests on — a hit rate over two queries and
    /// one over two hundred are not the same claim.
    public let queries: Int
    public let reason: String?

    public init(value: Double?, queries: Int, reason: String? = nil) {
        self.value = value
        self.queries = queries
        self.reason = reason
    }

    public static func inapplicable(_ reason: String) -> MetricScore {
        MetricScore(value: nil, queries: 0, reason: reason)
    }

    public var text: String {
        guard let value else { return "—" }
        return String(format: "%.2f", value)
    }
}

/// Median and 95th percentile of one kind of wait.
public struct LatencySummary: Hashable, Sendable {
    public let median: TimeInterval
    public let p95: TimeInterval
    public let samples: Int

    public init(median: TimeInterval, p95: TimeInterval, samples: Int) {
        self.median = median
        self.p95 = p95
        self.samples = samples
    }

    /// Nearest-rank, not interpolated: on the handful of queries a run usually
    /// has, an interpolated percentile invents a value between two measurements
    /// and reads as more precise than the measurement was.
    public static func of(_ values: [TimeInterval]) -> LatencySummary? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        func percentile(_ share: Double) -> TimeInterval {
            let rank = Int((share * Double(sorted.count)).rounded(.up))
            return sorted[min(max(rank, 1), sorted.count) - 1]
        }
        return LatencySummary(median: percentile(0.5), p95: percentile(0.95), samples: sorted.count)
    }

    public var line: String {
        String(localized: "медиана \(Int(median * 1000)) мс · p95 \(Int(p95 * 1000)) мс")
    }
}

/// How much of a variant's output has been judged.
///
/// Metrics computed over a partly marked run are shown, and are labelled
/// preliminary rather than presented as final: hiding them would remove the
/// only reason to mark anything, and presenting them as final would give a
/// number more weight than the marking behind it.
public struct MarkingCoverage: Hashable, Sendable {
    public let marked: Int
    public let total: Int

    public init(marked: Int, total: Int) {
        self.marked = marked
        self.total = total
    }

    public var isComplete: Bool { total == 0 || marked >= total }

    public var line: String {
        String(localized: "размечено \(marked) из \(total) результатов")
    }
}

/// Everything the report knows about one variant.
///
/// Deliberately a set of numbers and never a single one: D1.3 forbids an
/// aggregate «оценка качества», because one number hides which of its parts
/// moved and creates confidence the measurement does not support.
public struct VariantMetrics: Identifiable, Hashable, Sendable {
    public let variantID: UUID
    public let variantName: String
    /// Hit rate and nDCG by `k`; recall too, where the relevant set is known.
    public let hitRate: [Int: MetricScore]
    public let recall: [Int: MetricScore]
    public let ndcg: [Int: MetricScore]
    public let mrr: MetricScore
    /// Only cells that actually called the model — a reused vector is not a
    /// fast one, and averaging it in as zero would make every variant after the
    /// first look quicker than it is.
    public let embeddingLatency: LatencySummary?
    public let searchLatency: LatencySummary?
    public let coverage: MarkingCoverage
    public let failedCells: Int
    /// `k` values the variant cannot honestly answer for, because it was asked
    /// for fewer results than that.
    public let truncatedKs: [Int]

    public var id: UUID { variantID }

    public func note(for k: Int) -> String? {
        guard truncatedKs.contains(k) else { return nil }
        return String(localized: "вариант отдаёт меньше \(k) результатов — @\(k) считается по тому, что есть")
    }
}

/// The formulas, fixed and covered by tests with hand-counted examples.
public enum EvaluationMetrics {
    /// The `k` values shown side by side unless the user changes them.
    ///
    /// Both at once on purpose: @5 says whether the answer is on the first
    /// screen, @10 whether it is in the list at all, and a variant that wins one
    /// and loses the other is the interesting case.
    public static let defaultKs = [5, 10]

    /// Приводит набор `k` к пригодному для расчёта виду (D1.3 — «значение k
    /// настраивается»).
    ///
    /// Ноль и отрицательные выкидываются, повторы схлопываются, порядок —
    /// возрастающий: столбцы отчёта читаются слева направо, и «@10, @3»
    /// заставляет перечитывать заголовки. Пустой список — не пустая таблица,
    /// а умолчание: экран без единой метрики выглядит поломкой, а не
    /// настройкой.
    public static func sanitisedKs(_ raw: [Int]) -> [Int] {
        let cleaned = Set(raw.filter { $0 > 0 }).sorted()
        return cleaned.isEmpty ? defaultKs : cleaned
    }

    /// Ground truth as it stands **now**, not as it stood during the run.
    ///
    /// Marking writes into the set afterwards, and the whole point is
    /// that metrics recompute without re-running. Queries the set no longer has
    /// fall back to the run's own snapshot, so a deleted set does not erase the
    /// run's numbers.
    public static func groundTruth(for run: EvaluationRun, set: QuerySet?) -> [UUID: EvaluationQuery] {
        var result: [UUID: EvaluationQuery] = [:]
        for query in run.queries { result[query.id] = query }
        for query in set?.queries ?? [] where result[query.id] != nil {
            result[query.id] = query
        }
        return result
    }

    /// Оценки «(запрос, документ) → градация», посчитанные один раз на прогон.
    ///
    /// Без него каждая метрика считала их заново: hit rate, recall и nDCG на
    /// каждом `k`, плюс MRR и охват — семь проходов по всей выдаче, и в каждом
    /// приведение текста документа к сравнимому виду. На живом прогоне
    /// (5 вариантов, 200 результатов, 654 000 символов, 11 фрагментов эталона)
    /// это стоило 873 мс на каждый пересчёт метрик — а пересчёт случается
    /// при каждой отметке.
    ///
    /// Отсутствие ключа означает «не размечено» — то же, что `nil` у
    /// `grade(forDocument:text:)`, и хранить `nil` отдельно незачем.
    public struct GradeIndex: Sendable {
        /// Вариант — часть ключа, и это не перестраховка.
        ///
        /// Градация зависит от **текста** результата, а один и тот же
        /// идентификатор у разных вариантов может нести разный текст: вариант
        /// с расширением контекста отдаёт раздел целиком там, где другой отдаёт
        /// чанк. Ключ без варианта переносил оценку с одного на другой —
        /// поймано тестом сразу после первой редакции.
        private struct Key: Hashable {
            let query: UUID
            let variant: UUID
            let document: String
        }

        private let grades: [Key: RelevanceGrade]
        /// Приведённый текст каждого результата — самое дорогое, что здесь
        /// есть, и потому считается по одному разу.
        ///
        /// Ключ тот же полный: один вариант возвращает под одним и тем же
        /// идентификатором **разный** текст на разные запросы — расширение
        /// контекста прикладывает к чанку соседей, а они зависят от того, что
        /// именно совпало. Ключ без запроса переносил текст с одного запроса
        /// на другой; поймано тестом.
        private let normalisedTexts: [Key: String]
        /// Какие фрагменты эталона встретились в тексте результата.
        ///
        /// Считается там же, где градация, — сравнение уже проделано, и
        /// хранить его ответ дешевле, чем повторять. Ради этого и заведено:
        /// nDCG спрашивал «какие ожидания не сбылись» заново на каждом `k`
        /// и на каждом варианте, перебирая фрагменты по текстам. На живом
        /// прогоне (3 варианта × 18 запросов × 10 результатов, 1,67 млн
        /// знаков, 483 фрагмента) это и было теми 1097 мс, которые расчёт
        /// метрик занимал при каждой отметке.
        private let matchedFragments: [Key: Set<UUID>]
        /// Ключи прогона по запросам — чтобы отметка пересчитывала свой
        /// запрос, а не весь прогон.
        private let keysByQuery: [UUID: [Key]]
        /// Какие фрагменты индекс видел, когда строился.
        ///
        /// Эталон живёт своей жизнью: его правят, переносят, читают из файла.
        /// Фрагмент, которого индекс не видел, считается по тексту — как
        /// раньше, — а не молча объявляется ненайденным.
        private let knownFragments: [UUID: Set<UUID>]

        public init(run: EvaluationRun, truth: [UUID: EvaluationQuery]) {
            self.init(results: run.results, truth: truth)
        }

        public init(results: [EvaluationResult], truth: [UUID: EvaluationQuery]) {
            var texts: [Key: String] = [:]
            var keysByQuery: [UUID: [Key]] = [:]
            var seen: Set<Key> = []
            for result in results {
                for hit in result.hits {
                    let key = Key(query: result.queryID, variant: result.variantID, document: hit.id)
                    if seen.insert(key).inserted {
                        keysByQuery[result.queryID, default: []].append(key)
                    }
                    guard texts[key] == nil, let text = hit.text else { continue }
                    texts[key] = ExpectedFragment.normalised(text)
                }
            }

            var grades: [Key: RelevanceGrade] = [:]
            var matched: [Key: Set<UUID>] = [:]
            var known: [UUID: Set<UUID>] = [:]
            for (queryID, keys) in keysByQuery {
                guard let query = truth[queryID] else { continue }
                Self.grade(query: query, keys: keys, texts: texts, into: &grades, matched: &matched)
                known[queryID] = Set(query.fragments.map(\.id))
            }
            self.grades = grades
            self.normalisedTexts = texts
            self.matchedFragments = matched
            self.keysByQuery = keysByQuery
            self.knownFragments = known
        }

        private init(
            grades: [Key: RelevanceGrade],
            normalisedTexts: [Key: String],
            matchedFragments: [Key: Set<UUID>],
            keysByQuery: [UUID: [Key]],
            knownFragments: [UUID: Set<UUID>]
        ) {
            self.grades = grades
            self.normalisedTexts = normalisedTexts
            self.matchedFragments = matchedFragments
            self.keysByQuery = keysByQuery
            self.knownFragments = knownFragments
        }

        /// Тот же индекс, но с заново посчитанным **одним** запросом.
        ///
        /// Отметка меняет эталон ровно одного запроса, а пересборка индекса
        /// целиком приводила к сравнимому виду все 1,67 млн знаков выдачи —
        /// 1547 мс на каждое нажатие, и тем дороже, чем больше размечено.
        /// Приведённые тексты не зависят от разметки вовсе, поэтому
        /// переиспользуются как есть, а сравнение с фрагментами повторяется
        /// только для тех тридцати результатов, которых отметка касается.
        public func regrading(query queryID: UUID, truth: [UUID: EvaluationQuery]) -> GradeIndex {
            let keys = keysByQuery[queryID] ?? []
            var grades = self.grades
            var matched = self.matchedFragments
            var known = self.knownFragments
            for key in keys {
                grades[key] = nil
                matched[key] = nil
            }
            if let query = truth[queryID] {
                Self.grade(query: query, keys: keys, texts: normalisedTexts, into: &grades, matched: &matched)
                known[queryID] = Set(query.fragments.map(\.id))
            } else {
                known[queryID] = nil
            }
            return GradeIndex(
                grades: grades, normalisedTexts: normalisedTexts, matchedFragments: matched,
                keysByQuery: keysByQuery, knownFragments: known
            )
        }

        /// То же правило, что в `EvaluationQuery.grade(forDocument:text:)`,
        /// но сразу по всем результатам одного запроса.
        ///
        /// Разом, а не по одному: фрагмент эталона приводится к сравнимому
        /// виду один раз на запрос, а не один раз на каждое сравнение. При
        /// отметке фрагментом становится найденный текст целиком — до 120
        /// знаков, — и приводить его заново на каждый из тридцати результатов
        /// значило повторять одну и ту же работу.
        private static func grade(
            query: EvaluationQuery,
            keys: [Key],
            texts: [Key: String],
            into grades: inout [Key: RelevanceGrade],
            matched: inout [Key: Set<UUID>]
        ) {
            let fragments: [(id: UUID, needle: String, grade: RelevanceGrade)] = query.fragments
                .map { (id: $0.id, needle: ExpectedFragment.normalised($0.fragment), grade: $0.grade) }
                .filter { !$0.needle.isEmpty }
            var documents: [String: RelevanceGrade] = [:]
            for document in query.documents where documents[document.id] == nil {
                documents[document.id] = document.grade
            }

            for key in keys {
                var best: RelevanceGrade?
                if let text = texts[key], !fragments.isEmpty {
                    var found: Set<UUID> = []
                    for fragment in fragments where ExpectedFragment.contains(text, fragment.needle) {
                        found.insert(fragment.id)
                        if best == nil || fragment.grade.gain > best!.gain { best = fragment.grade }
                    }
                    if !found.isEmpty { matched[key] = found }
                }
                if let best {
                    grades[key] = best
                } else if let byID = documents[key.document] {
                    grades[key] = byID
                }
            }
        }

        public func grade(query: UUID, variant: UUID, document: String) -> RelevanceGrade? {
            grades[Key(query: query, variant: variant, document: document)]
        }

        /// Приведённый текст результата — для тех мест, где спрашивают не
        /// «какая градация», а «встретился ли **этот** фрагмент».
        public func normalisedText(query: UUID, variant: UUID, document: String) -> String? {
            normalisedTexts[Key(query: query, variant: variant, document: document)]
        }

        /// Фрагменты эталона, встретившиеся в тексте этого результата.
        public func matched(query: UUID, variant: UUID, document: String) -> Set<UUID> {
            matchedFragments[Key(query: query, variant: variant, document: document)] ?? []
        }

        /// Знал ли индекс про этот фрагмент, когда строился.
        public func knows(fragment: UUID, of query: UUID) -> Bool {
            knownFragments[query]?.contains(fragment) ?? false
        }
    }

    public static func compute(
        run: EvaluationRun,
        set: QuerySet? = nil,
        ks: [Int] = defaultKs,
        /// Готовый индекс, если вызывающий уже его построил. Построение —
        /// самая дорогая часть расчёта (119 мс на живом прогоне), и экран
        /// строит его один раз на все три потребителя.
        grades precomputed: GradeIndex? = nil
    ) -> [VariantMetrics] {
        let truth = groundTruth(for: run, set: set)
        let grades = precomputed ?? GradeIndex(run: run, truth: truth)
        return run.variants.map { variant in
            metrics(for: variant, run: run, truth: truth, grades: grades, ks: ks)
        }
    }

    private static func metrics(
        for variant: EvaluationVariant,
        run: EvaluationRun,
        truth: [UUID: EvaluationQuery],
        grades: GradeIndex,
        ks: [Int]
    ) -> VariantMetrics {
        let results = run.results(variant: variant.id).filter(\.succeeded)

        var hitRate: [Int: MetricScore] = [:]
        var recall: [Int: MetricScore] = [:]
        var ndcg: [Int: MetricScore] = [:]
        for k in ks {
            hitRate[k] = hitRateScore(results: results, truth: truth, grades: grades, k: k)
            recall[k] = recallScore(results: results, truth: truth, grades: grades, k: k)
            ndcg[k] = ndcgScore(results: results, truth: truth, grades: grades, k: k)
        }

        var marked = 0
        var total = 0
        for result in results {
            for hit in result.hits {
                total += 1
                if grades.grade(query: result.queryID, variant: result.variantID, document: hit.id) != nil { marked += 1 }
            }
        }

        return VariantMetrics(
            variantID: variant.id,
            variantName: variant.name,
            hitRate: hitRate,
            recall: recall,
            ndcg: ndcg,
            mrr: mrrScore(results: results, truth: truth, grades: grades),
            embeddingLatency: LatencySummary.of(results.compactMap(\.embeddingSeconds)),
            searchLatency: LatencySummary.of(results.map(\.searchSeconds)),
            coverage: MarkingCoverage(marked: marked, total: total),
            failedCells: run.results(variant: variant.id).filter { !$0.succeeded }.count,
            truncatedKs: ks.filter { variant.nResults < $0 }
        )
    }

    // MARK: - Формулы

    /// Доля запросов, где в топ-k попал хотя бы один релевантный.
    ///
    /// Counted over queries that have something relevant in their ground truth
    /// at all: a query marked «всё нерелевантно» cannot be hit, and counting it
    /// as a miss would punish the search for the marking.
    static func hitRateScore(
        results: [EvaluationResult], truth: [UUID: EvaluationQuery],
        grades: GradeIndex? = nil, k: Int
    ) -> MetricScore {
        // Индекс необязателен: формулу можно посчитать и в одиночку — так её
        // проверяют тесты. Полный расчёт передаёт общий индекс, и тогда
        // приведение текстов не повторяется на каждой метрике.
        let grades = grades ?? GradeIndex(results: results, truth: truth)
        var applicable = 0
        var hits = 0
        for result in results {
            guard let query = truth[result.queryID], query.hasRelevantGroundTruth else { continue }
            applicable += 1
            if result.hits.prefix(k).contains(where: {
                grades.grade(query: result.queryID, variant: result.variantID, document: $0.id)?.isHit == true
            }) {
                hits += 1
            }
        }
        guard applicable > 0 else {
            return .inapplicable(String(localized: "ни у одного запроса нет эталона с релевантным документом"))
        }
        return MetricScore(value: Double(hits) / Double(applicable), queries: applicable)
    }

    /// Какая доля известных релевантных найдена.
    ///
    /// Only for queries whose relevant set is **complete**, which only ids make
    /// it: a denominator invented from the number of fragments would
    /// report a share of something nobody stated.
    ///
    /// «Частично» counts as found here while it counts as half in nDCG. The
    /// difference is deliberate: recall asks whether the passage was retrieved
    /// at all, nDCG asks how good the answer is.
    static func recallScore(
        results: [EvaluationResult], truth: [UUID: EvaluationQuery],
        grades: GradeIndex? = nil, k: Int
    ) -> MetricScore {
        // Оценки индекса полноте не нужны: она считается по идентификаторам
        // эталона. Параметр оставлен, чтобы все метрики звались одинаково.
        var applicable = 0
        var total = 0.0
        for result in results {
            guard let query = truth[result.queryID],
                  let known = query.knownRelevantCount, known > 0 else { continue }
            applicable += 1
            // Числитель — из того же множества, что знаменатель: **разные**
            // документы из списка эталона, оказавшиеся в первых k. Прежде
            // считался любой результат с оценкой «попал», включая совпавший
            // по фрагменту документ вне списка и повтор одного и того же
            // идентификатора, — и полнота выходила единицей там, где один
            // из известных документов так и не нашёлся.
            let relevant = Set(query.documents.filter { $0.grade.isHit }.map(\.id))
            let found = Set(result.hits.prefix(k).map(\.id)).intersection(relevant).count
            total += min(1, Double(found) / Double(max(1, min(known, relevant.count))))
        }
        guard applicable > 0 else {
            return .inapplicable(String(localized: "полнота считается только по эталону из идентификаторов — список фрагментов не полон"))
        }
        return MetricScore(value: total / Double(applicable), queries: applicable)
    }

    /// Насколько высоко первый релевантный результат.
    ///
    /// A query that found nothing relevant contributes 0 rather than being
    /// dropped: «не нашёл вовсе» is the answer the metric exists to report.
    static func mrrScore(
        results: [EvaluationResult], truth: [UUID: EvaluationQuery],
        grades: GradeIndex? = nil
    ) -> MetricScore {
        // Индекс необязателен: формулу можно посчитать и в одиночку — так её
        // проверяют тесты. Полный расчёт передаёт общий индекс, и тогда
        // приведение текстов не повторяется на каждой метрике.
        let grades = grades ?? GradeIndex(results: results, truth: truth)
        var applicable = 0
        var total = 0.0
        for result in results {
            guard let query = truth[result.queryID], query.hasRelevantGroundTruth else { continue }
            applicable += 1
            if let rank = result.hits.first(where: {
                grades.grade(query: result.queryID, variant: result.variantID, document: $0.id)?.isHit == true
            })?.position {
                total += 1 / Double(rank)
            }
        }
        guard applicable > 0 else {
            return .inapplicable(String(localized: "ни у одного запроса нет эталона с релевантным документом"))
        }
        return MetricScore(value: total / Double(applicable), queries: applicable)
    }

    /// Учитывает и позицию, и степень релевантности.
    ///
    /// The ideal ranking is built from what is known **and** from what was
    /// actually found: one fragment can match three different chunks, and an
    /// ideal that ignored them would let nDCG exceed 1 — a number that tells the
    /// reader the tool is broken rather than that the search is good.
    static func ndcgScore(
        results: [EvaluationResult], truth: [UUID: EvaluationQuery],
        grades: GradeIndex? = nil, k: Int
    ) -> MetricScore {
        // Индекс необязателен: формулу можно посчитать и в одиночку — так её
        // проверяют тесты. Полный расчёт передаёт общий индекс, и тогда
        // приведение текстов не повторяется на каждой метрике.
        let grades = grades ?? GradeIndex(results: results, truth: truth)
        var applicable = 0
        var total = 0.0
        for result in results {
            guard let query = truth[result.queryID], query.hasRelevantGroundTruth else { continue }
            applicable += 1

            let gains = result.hits.prefix(k).map {
                grades.grade(query: result.queryID, variant: result.variantID, document: $0.id)?.gain ?? 0
            }
            let discounted = gains.enumerated().reduce(0.0) { sum, pair in
                sum + pair.element / log2(Double(pair.offset + 2))
            }

            // What a perfect ranking of this query could have scored: every gain
            // that was achieved, plus every expected one that was missed, best
            // first.
            var ideal = gains.filter { $0 > 0 }
            ideal += missedGains(
                query: query, hits: Array(result.hits.prefix(k)),
                variant: result.variantID, grades: grades
            )
            let idealDiscounted = ideal.sorted(by: >).prefix(k).enumerated().reduce(0.0) { sum, pair in
                sum + pair.element / log2(Double(pair.offset + 2))
            }
            guard idealDiscounted > 0 else { continue }
            total += min(1, discounted / idealDiscounted)
        }
        guard applicable > 0 else {
            return .inapplicable(String(localized: "ни у одного запроса нет эталона с релевантным документом"))
        }
        return MetricScore(value: total / Double(applicable), queries: applicable)
    }

    /// Gains of the expectations this result did not satisfy — what the ideal
    /// ranking would have shown and this one did not.
    private static func missedGains(
        query: EvaluationQuery, hits: [EvaluationHit], variant: UUID, grades: GradeIndex
    ) -> [Double] {
        let queryID = query.id
        // Совпадения берутся у индекса готовыми: он их уже искал, когда
        // считал градации. Раньше здесь каждый фрагмент эталона сверялся с
        // текстом каждого результата — заново на каждом `k` и на каждом
        // варианте.
        var matched: Set<UUID> = []
        for hit in hits {
            matched.formUnion(grades.matched(query: queryID, variant: variant, document: hit.id))
        }
        // Тексты — только если попался фрагмент, которого индекс не видел:
        // эталон могли поправить после того, как индекс построили.
        var texts: [String]?
        var gains: [Double] = []
        for fragment in query.fragments where fragment.grade.isHit {
            if grades.knows(fragment: fragment.id, of: queryID) {
                if !matched.contains(fragment.id) { gains.append(fragment.grade.gain) }
                continue
            }
            let known = texts ?? hits.compactMap {
                grades.normalisedText(query: queryID, variant: variant, document: $0.id)
            }
            texts = known
            if !known.contains(where: { fragment.matches(normalisedDocument: $0) }) {
                gains.append(fragment.grade.gain)
            }
        }
        for document in query.documents where document.grade.isHit {
            if !hits.contains(where: { $0.id == document.id }) { gains.append(document.grade.gain) }
        }
        return gains
    }
}

public extension EvaluationQuery {
    /// Whether anything is stated to be relevant — the condition every metric
    /// but latency depends on.
    ///
    /// A query marked entirely «нерелевантно» has ground truth and still cannot
    /// be hit; counting it as a miss would score the search on the marking.
    var hasRelevantGroundTruth: Bool {
        fragments.contains { $0.grade.isHit } || documents.contains { $0.grade.isHit }
    }
}
