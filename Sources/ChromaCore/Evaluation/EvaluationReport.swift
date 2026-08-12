import Foundation

/// Отчёт по прогону: таблица «вариант × метрика», детализация по запросам
/// и сравнение двух прогонов.
///
/// **Почему отдельный тип, а не разметка экрана.** Три требования пункта —
/// подсветка лучшего, «где какой вариант провалился» и экспорт — это три вида
/// одного и того же решения о том, что считать лучше и что считать провалом.
/// Разложенные по вьюхам, они разошлись бы: таблица подсвечивала бы одно,
/// Markdown писал бы другое. Здесь решение одно, и оно под тестами.
public enum EvaluationReport {

    // MARK: - Таблица «вариант × метрика»

    /// В какую сторону лучше. У задержки — вниз, у всего остального — вверх;
    /// без этого «подсветить лучшее» превратилось бы в «подсветить наибольшее»
    /// и хвалило бы самый медленный вариант.
    public enum Direction: Sendable, Equatable {
        case higherIsBetter
        case lowerIsBetter
    }

    public struct Cell: Sendable, Equatable {
        /// Число для сравнения. `nil` — метрика неприменима; такая ячейка
        /// никогда не побеждает и никогда не проигрывает, она просто вне
        /// сравнения (`MetricScore` с `nil` — полноценный ответ, а не ноль).
        public let value: Double?
        /// Как это показать человеку: «0.83», «медиана 120 мс · p95 300 мс», «—».
        public let text: String
        public let isBest: Bool

        public init(value: Double?, text: String, isBest: Bool) {
            self.value = value
            self.text = text
            self.isBest = isBest
        }
    }

    public struct Column: Sendable, Equatable, Identifiable {
        public let key: String
        public let title: String
        public let direction: Direction
        /// По варианту, в том же порядке, что `variants` отчёта.
        public let cells: [Cell]

        public var id: String { key }
    }

    public struct Table: Sendable, Equatable {
        public let variantNames: [String]
        public let columns: [Column]
        /// Подсветка выключена, когда сравнивать не с чем: один вариант —
        /// это не «лучший», это единственный.
        public let highlightsBest: Bool
    }

    /// Собирает таблицу.
    ///
    /// **Подсветка ставится только там, где она что-то говорит.** Не ставится:
    /// когда вариант один; когда сравнимых значений в столбце меньше двух;
    /// когда все сравнимые значения равны — «лучший» из одинаковых это не
    /// вывод, а украшение, которое человек прочтёт как вывод.
    public static func table(_ metrics: [VariantMetrics], ks: [Int] = EvaluationMetrics.defaultKs) -> Table {
        let names = metrics.map(\.variantName)
        var columns: [Column] = []

        for k in ks {
            columns.append(column(
                key: "hit@\(k)", title: "hit rate@\(k)", direction: .higherIsBetter,
                scores: metrics.map { $0.hitRate[k] }
            ))
        }
        for k in ks {
            columns.append(column(
                key: "recall@\(k)", title: "recall@\(k)", direction: .higherIsBetter,
                scores: metrics.map { $0.recall[k] }
            ))
        }
        columns.append(column(
            key: "mrr", title: "MRR", direction: .higherIsBetter, scores: metrics.map(\.mrr)
        ))
        for k in ks {
            columns.append(column(
                key: "ndcg@\(k)", title: "nDCG@\(k)", direction: .higherIsBetter,
                scores: metrics.map { $0.ndcg[k] }
            ))
        }
        // Заголовок без слова «медиана»: сама ячейка уже пишет «медиана 5 мс ·
        // p95 11 мс», и строка читалась как «поиск, медиана: медиана 5 мс».
        // В сравнении прогонов заголовок другой — там в ячейке одно число.
        columns.append(latencyColumn(
            key: "embedding", title: String(localized: "вектор запроса"),
            summaries: metrics.map(\.embeddingLatency)
        ))
        columns.append(latencyColumn(
            key: "search", title: String(localized: "поиск"),
            summaries: metrics.map(\.searchLatency)
        ))

        return Table(variantNames: names, columns: columns, highlightsBest: metrics.count > 1)
    }

    private static func column(
        key: String, title: String, direction: Direction, scores: [MetricScore?]
    ) -> Column {
        let values = scores.map { $0?.value }
        let best = bestIndices(values, direction: direction, comparable: scores.count > 1)
        let cells = scores.enumerated().map { index, score in
            Cell(
                value: score?.value,
                text: score?.text ?? "—",
                isBest: best.contains(index)
            )
        }
        return Column(key: key, title: title, direction: direction, cells: cells)
    }

    private static func latencyColumn(
        key: String, title: String, summaries: [LatencySummary?]
    ) -> Column {
        let values = summaries.map { $0.map(\.median) }
        let best = bestIndices(values, direction: .lowerIsBetter, comparable: summaries.count > 1)
        let cells = summaries.enumerated().map { index, summary in
            Cell(
                value: summary?.median,
                text: summary?.line ?? "—",
                isBest: best.contains(index)
            )
        }
        return Column(key: key, title: title, direction: .lowerIsBetter, cells: cells)
    }

    /// Индексы лучших значений — все при равенстве, ни одного при полном
    /// равенстве всего столбца.
    static func bestIndices(_ values: [Double?], direction: Direction, comparable: Bool) -> Set<Int> {
        guard comparable else { return [] }
        let present = values.enumerated().compactMap { index, value in value.map { (index, $0) } }
        guard present.count > 1 else { return [] }
        let numbers = present.map(\.1)
        guard let minimum = numbers.min(), let maximum = numbers.max(), minimum != maximum else {
            return []
        }
        let target = direction == .higherIsBetter ? maximum : minimum
        return Set(present.filter { $0.1 == target }.map(\.0))
    }
}

// MARK: - Детализация по запросам

public extension EvaluationReport {
    /// Что вариант сделал с одним запросом.
    ///
    /// Четыре исхода, и все четыре разные. «Не нашёл» и «не размечено» путать
    /// нельзя: первое — вывод о варианте, второе — о том, что вывода пока нет.
    /// Сбой ячейки — тем более не «ничего не нашёл».
    enum QueryOutcome: Sendable, Equatable {
        /// Первый релевантный результат стоял на этой позиции (1-based).
        case found(rank: Int)
        /// Размеченные результаты есть, релевантных среди выдачи нет.
        case missed
        /// В выдаче нет ни одного размеченного результата — судить не о чем.
        case unmarked
        case failed(reason: String)

        public var text: String {
            switch self {
            case .found(let rank): return String(localized: "позиция \(rank)")
            case .missed: return String(localized: "не нашёл")
            case .unmarked: return String(localized: "не размечено")
            case .failed: return String(localized: "сбой")
            }
        }

        /// Ранг для сравнения вариантов между собой. «Не нашёл» — хуже любой
        /// позиции, поэтому получает ранг за пределами выдачи. «Не размечено»
        /// и «сбой» в сравнении не участвуют вовсе: у них нет исхода.
        func comparableRank(outOf nResults: Int) -> Int? {
            switch self {
            case .found(let rank): return rank
            case .missed: return nResults + 1
            case .unmarked, .failed: return nil
            }
        }
    }

    struct QueryRow: Sendable, Equatable, Identifiable {
        public let queryID: UUID
        public let text: String
        /// По варианту, в порядке `variants` прогона.
        public let outcomes: [QueryOutcome]
        /// Насколько варианты разошлись: разница между лучшей и худшей
        /// позицией среди тех, у кого исход есть. Ноль — разошлись не заметно.
        public let spread: Int

        public var id: UUID { queryID }
        /// Есть ли о чём говорить: запрос, на котором все повели себя
        /// одинаково, в список «разошлись сильнее всего» не попадает.
        public var variantsDisagree: Bool { spread > 0 }
    }

    // MARK: - Оговорка о длине результатов

    /// Медианная длина результата по варианту, в символах.
    static func medianResultLengths(_ run: EvaluationRun) -> [Int?] {
        run.variants.map { variant in
            let lengths = run.results(variant: variant.id)
                .flatMap(\.hits)
                .compactMap { $0.text?.count }
                .sorted()
            guard !lengths.isEmpty else { return nil }
            return lengths[lengths.count / 2]
        }
    }

    /// Во сколько раз длина результатов должна разойтись, чтобы об этом стоило
    /// говорить. Двукратная разница — это уже другой разговор о попадании.
    static let lengthRatioThreshold = 2.0

    /// Предупреждение, когда варианты отдают куски несопоставимого размера.
    ///
    /// **Зачем.** Эталон — фрагмент текста, и попадание засчитывается, если
    /// найденный текст его содержит. Вариант, отдающий раздел целиком, почти
    /// всегда содержит любой фрагмент из этого раздела: его hit rate растёт не
    /// потому, что он ищет лучше, а потому, что отвечает крупнее. Сравнивать
    /// такие числа в лоб нельзя, и молчать об этом — значит выдать за вывод
    /// свойство нарезки. Найдено на живом прогоне: 7 120 символов против 1 731.
    static func lengthCaveat(_ run: EvaluationRun) -> String? {
        let lengths = medianResultLengths(run)
        let known = zip(run.variants.map(\.name), lengths).compactMap { name, length in
            length.map { (name: name, length: $0) }
        }
        guard known.count > 1,
              let shortest = known.min(by: { $0.length < $1.length }),
              let longest = known.max(by: { $0.length < $1.length }),
              shortest.length > 0,
              Double(longest.length) / Double(shortest.length) >= lengthRatioThreshold
        else { return nil }

        return String(localized: """
            Варианты отдают тексты очень разной длины: «\(longest.name)» — \
            \(RussianCount.grouped(longest.length, "символ", "символа", "символов")) в медиане, \
            «\(shortest.name)» — \(RussianCount.grouped(shortest.length, "символ", "символа", "символов")). \
            Эталон — фрагмент текста, и длинный кусок содержит его чаще просто \
            потому, что он длинный: hit rate и nDCG у таких вариантов сравнимы \
            лишь с оговоркой.
            """)
    }

    /// Строка на каждый запрос набора, в порядке набора.
    static func queryRows(
        run: EvaluationRun, set: QuerySet? = nil,
        grades precomputed: EvaluationMetrics.GradeIndex? = nil
    ) -> [QueryRow] {
        let truth = EvaluationMetrics.groundTruth(for: run, set: set)
        // Тот же общий индекс, что у метрик: без него детализация приводила
        // текст каждого результата заново — 132 мс на живом прогоне, и это
        // повторялось при каждой перерисовке экрана.
        let grades = precomputed ?? EvaluationMetrics.GradeIndex(run: run, truth: truth)
        let order = run.queries.map(\.id)
        return order.compactMap { queryID -> QueryRow? in
            guard let query = truth[queryID] else { return nil }
            let outcomes = run.variants.map { variant -> QueryOutcome in
                outcome(run: run, query: query, variant: variant, grades: grades)
            }
            let ranks = zip(outcomes, run.variants).compactMap { outcome, variant in
                outcome.comparableRank(outOf: variant.nResults)
            }
            let spread = (ranks.max() ?? 0) - (ranks.min() ?? 0)
            return QueryRow(queryID: queryID, text: query.text, outcomes: outcomes, spread: spread)
        }
    }

    private static func outcome(
        run: EvaluationRun, query: EvaluationQuery, variant: EvaluationVariant,
        grades: EvaluationMetrics.GradeIndex
    ) -> QueryOutcome {
        guard let result = run.results.first(where: {
            $0.queryID == query.id && $0.variantID == variant.id
        }) else {
            return .failed(reason: String(localized: "ячейка не выполнялась"))
        }
        if let failure = result.failure { return .failed(reason: failure) }

        for (index, hit) in result.hits.enumerated() {
            guard let grade = grades.grade(query: query.id, variant: variant.id, document: hit.id) else { continue }
            if grade != .irrelevant { return .found(rank: index + 1) }
        }
        // «Не нашёл» решается разметкой **запроса**, а не выдачи. Первая
        // редакция смотрела, попалось ли в выдаче хоть что-то размеченное, —
        // и вариант, не нашедший вообще ничего нужного, объявлялся
        // «не размечено», то есть его провал выглядел отсутствием данных.
        // Эталон есть — значит про этот вариант есть что сказать.
        //
        // Но эталон эталону рознь: запрос, у которого размечено только
        // «нерелевантен», найти нечего — и «не нашёл» обвиняло бы вариант в
        // том, чего никто не объявлял находимым. Метрики такой запрос уже
        // пропускают (`hasRelevantGroundTruth`), а детализация — считала его
        // провалом; найдено на живом прогоне.
        return query.hasRelevantGroundTruth ? .missed : .unmarked
    }

    /// Запросы, на которых варианты разошлись сильнее всего, — то, ради чего
    /// детализация и нужна: среднее по больнице не показывает, где именно
    /// вариант провалился.
    static func mostDivergent(_ rows: [QueryRow], limit: Int = 10) -> [QueryRow] {
        rows.filter(\.variantsDisagree)
            .sorted { ($0.spread, $0.text) > ($1.spread, $1.text) }
            .prefix(limit)
            .map { $0 }
    }
}

// MARK: - Сравнение двух прогонов (было/стало)

public extension EvaluationReport {
    /// В чём измеряется строка сравнения.
    ///
    /// Доли и секунды нельзя показывать одним форматом: «0.01 → 0.00 (-0.00)»
    /// — это две миллисекунды, но выглядит как сломанный ноль. Найдено на
    /// живом сравнении двух прогонов.
    enum Scale: Sendable, Equatable {
        /// Значение от нуля до единицы — две цифры после запятой.
        case ratio
        /// Секунды — показываются миллисекундами, целыми.
        case seconds

        public func text(_ value: Double?) -> String {
            guard let value else { return "—" }
            switch self {
            case .ratio: return String(format: "%.2f", value)
            // Разряды разделяются так же, как в таблице выше: «5 473 мс».
            case .seconds: return String(localized: "\(Int((value * 1000).rounded())) мс")
            }
        }

        /// Изменение со знаком, или `nil`, если на выбранной точности его не
        /// видно: «(+0)» рядом с двумя одинаковыми числами — не вывод.
        public func changeText(_ change: Double?) -> String? {
            guard let change else { return nil }
            switch self {
            case .ratio:
                guard abs(change) >= 0.005 else { return nil }
                return String(format: "%+.2f", change)
            case .seconds:
                let milliseconds = Int((change * 1000).rounded())
                guard milliseconds != 0 else { return nil }
                // Знак ставится отдельно, а разряды разделяются как везде:
                // «+3 088 мс». `%+d` разрядов не разделяет. Минус — обычный
                // дефис, как в строках долей выше («-0.01»).
                let sign = milliseconds > 0 ? "+" : "-"
                return sign + String(localized: "\(abs(milliseconds)) мс")
            }
        }
    }

    struct MetricDelta: Sendable, Equatable, Identifiable {
        public let key: String
        public let title: String
        public let direction: Direction
        public let before: Double?
        public let after: Double?
        public var scale: Scale = .ratio

        public var id: String { key }

        public var change: Double? {
            guard let before, let after else { return nil }
            return after - before
        }

        /// Стало ли лучше. `nil` — сравнить не с чем или ничего не изменилось;
        /// это не «не изменилось к лучшему», а «вывода нет».
        ///
        /// Изменение, которого не видно на показанной точности, тоже вывода не
        /// даёт: красить строку в зелёное, когда рядом стоят два одинаковых
        /// числа, значит утверждать улучшение, которого человек не видит.
        public var improved: Bool? {
            guard let change, change != 0, scale.changeText(change) != nil else { return nil }
            return direction == .higherIsBetter ? change > 0 : change < 0
        }

        public var beforeText: String { scale.text(before) }
        public var afterText: String { scale.text(after) }
        public var changeText: String? { scale.changeText(change) }
    }

    struct VariantComparison: Sendable, Equatable, Identifiable {
        public let variantName: String
        public let deltas: [MetricDelta]
        public var id: String { variantName }
    }

    struct RunComparison: Sendable, Equatable {
        public let before: String
        public let after: String
        public let variants: [VariantComparison]
        /// Варианты, которых нет во втором прогоне, и наоборот. Молча
        /// выбрасывать их нельзя: сравнение, умолчавшее о том, что половина
        /// вариантов исчезла, читается как сравнение равного с равным.
        public let onlyInBefore: [String]
        public let onlyInAfter: [String]
    }

    /// Сопоставляет два прогона.
    ///
    /// **Варианты сопоставляются по имени, а не по идентификатору.** Имя —
    /// это то, что человек написал сам («512 символов», «модель bge»), и оно
    /// переживает пересоздание варианта. Идентификатор — нет: вариант,
    /// собранный заново с теми же параметрами, получит новый UUID, и сравнение
    /// «было/стало» показало бы два непересекающихся набора.
    static func compare(
        before: EvaluationRun, after: EvaluationRun,
        beforeSet: QuerySet? = nil, afterSet: QuerySet? = nil,
        ks: [Int] = EvaluationMetrics.defaultKs
    ) -> RunComparison {
        let beforeMetrics = EvaluationMetrics.compute(run: before, set: beforeSet, ks: ks)
        let afterMetrics = EvaluationMetrics.compute(run: after, set: afterSet, ks: ks)
        let beforeByName = Dictionary(beforeMetrics.map { ($0.variantName, $0) }) { first, _ in first }
        let afterByName = Dictionary(afterMetrics.map { ($0.variantName, $0) }) { first, _ in first }

        let shared = beforeMetrics.map(\.variantName).filter { afterByName[$0] != nil }
        let comparisons = shared.compactMap { name -> VariantComparison? in
            guard let old = beforeByName[name], let new = afterByName[name] else { return nil }
            return VariantComparison(variantName: name, deltas: deltas(old: old, new: new, ks: ks))
        }
        return RunComparison(
            before: before.name,
            after: after.name,
            variants: comparisons,
            onlyInBefore: beforeMetrics.map(\.variantName).filter { afterByName[$0] == nil },
            onlyInAfter: afterMetrics.map(\.variantName).filter { beforeByName[$0] == nil }
        )
    }

    private static func deltas(old: VariantMetrics, new: VariantMetrics, ks: [Int]) -> [MetricDelta] {
        var result: [MetricDelta] = []
        for k in ks {
            result.append(MetricDelta(
                key: "hit@\(k)", title: "hit rate@\(k)", direction: .higherIsBetter,
                before: old.hitRate[k]?.value, after: new.hitRate[k]?.value
            ))
        }
        for k in ks {
            result.append(MetricDelta(
                key: "recall@\(k)", title: "recall@\(k)", direction: .higherIsBetter,
                before: old.recall[k]?.value, after: new.recall[k]?.value
            ))
        }
        result.append(MetricDelta(
            key: "mrr", title: "MRR", direction: .higherIsBetter,
            before: old.mrr.value, after: new.mrr.value
        ))
        for k in ks {
            result.append(MetricDelta(
                key: "ndcg@\(k)", title: "nDCG@\(k)", direction: .higherIsBetter,
                before: old.ndcg[k]?.value, after: new.ndcg[k]?.value
            ))
        }
        // Единица в заголовке: остальные строки сравнения — доли от нуля до
        // единицы, и «2.39 → 5.47» без «с» читается как ещё одна метрика
        // качества, а не как секунды. Найдено на живом сравнении.
        result.append(MetricDelta(
            key: "search", title: String(localized: "поиск, медиана"), direction: .lowerIsBetter,
            before: old.searchLatency?.median, after: new.searchLatency?.median,
            scale: .seconds
        ))
        return result
    }
}
