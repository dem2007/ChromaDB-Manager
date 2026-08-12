import XCTest
@testable import ChromaCore

/// §D1.3 — метрики. Каждая формула проверяется на вручную посчитанном примере.
final class EvaluationMetricsTests: XCTestCase {

    // MARK: - Кэш оценок

    /// Ключ кэша — «запрос + вариант + документ», и обе добавки не
    /// перестраховка: обе ошибки были допущены и пойманы этими проверками.
    ///
    /// Градация зависит от **текста** результата, а текст под одним
    /// идентификатором различается и между вариантами (один отдаёт раздел
    /// целиком, другой чанк), и между запросами одного варианта (расширение
    /// контекста прикладывает соседей, а они зависят от того, что совпало).
    func testTheGradeCacheDoesNotCarryTextBetweenVariantsOrQueries() {
        let fragment = ExpectedFragment(fragment: "нужное")
        let first = EvaluationQuery(text: "первый", fragments: [fragment])
        let second = EvaluationQuery(text: "второй", fragments: [fragment])
        let a = UUID(), b = UUID()

        func hit(_ text: String) -> [EvaluationHit] {
            [EvaluationHit(id: "одинаковый-id", text: text, distance: nil, position: 1)]
        }
        let results = [
            // Один и тот же идентификатор, четыре разных текста.
            EvaluationResult(queryID: first.id, variantID: a, hits: hit("нужное")),
            EvaluationResult(queryID: first.id, variantID: b, hits: hit("мимо")),
            EvaluationResult(queryID: second.id, variantID: a, hits: hit("мимо")),
            EvaluationResult(queryID: second.id, variantID: b, hits: hit("нужное")),
        ]
        let truth = [first.id: first, second.id: second]
        let index = EvaluationMetrics.GradeIndex(results: results, truth: truth)

        XCTAssertEqual(index.grade(query: first.id, variant: a, document: "одинаковый-id"), .relevant)
        XCTAssertNil(index.grade(query: first.id, variant: b, document: "одинаковый-id"),
                     "текст другого варианта не должен приносить чужую оценку")
        XCTAssertNil(index.grade(query: second.id, variant: a, document: "одинаковый-id"),
                     "текст другого запроса не должен приносить чужую оценку")
        XCTAssertEqual(index.grade(query: second.id, variant: b, document: "одинаковый-id"), .relevant)
    }

    /// Кэш обязан давать ровно то же, что прямое вычисление, — иначе ускорение
    /// куплено за счёт правильности.
    func testTheCacheAgreesWithComputingTheGradeDirectly() {
        let query = EvaluationQuery(
            text: "з",
            fragments: [
                ExpectedFragment(fragment: "формула доступности", grade: .relevant),
                ExpectedFragment(fragment: "отчетный период", grade: .partial),
            ]
        )
        let variant = UUID()
        let texts = [
            "Здесь приведена формула доступности услуги.",
            "Расчёт за отчетный период выполняется ежемесячно.",
            "Формула доступности за отчетный период.",
            "Совсем про другое.",
        ]
        let hits = texts.enumerated().map {
            EvaluationHit(id: "d\($0.offset)", text: $0.element, distance: nil, position: $0.offset + 1)
        }
        let results = [EvaluationResult(queryID: query.id, variantID: variant, hits: hits)]
        let index = EvaluationMetrics.GradeIndex(results: results, truth: [query.id: query])

        for hit in hits {
            XCTAssertEqual(
                index.grade(query: query.id, variant: variant, document: hit.id),
                query.grade(forDocument: hit.id, text: hit.text),
                hit.text ?? ""
            )
        }
    }

    // MARK: - Стенд

    private func hits(_ ids: [String]) -> [EvaluationHit] {
        ids.enumerated().map { index, id in
            EvaluationHit(id: id, text: "текст \(id)", distance: nil, position: index + 1)
        }
    }

    private func result(_ queryID: UUID, _ variantID: UUID, _ ids: [String], search: TimeInterval = 0.01) -> EvaluationResult {
        EvaluationResult(
            queryID: queryID, variantID: variantID, hits: hits(ids), searchSeconds: search
        )
    }

    private func variant(_ name: String = "A", nResults: Int = 10) -> EvaluationVariant {
        EvaluationVariant(
            name: name, collectionID: "id", collectionName: "c", model: "m",
            nResults: nResults,
            profile: SearchProfile.plain(collectionName: "c", name: "п")
        )
    }

    /// Эталон по идентификаторам: он полон, а значит по нему считается полнота.
    private func query(_ text: String, relevant: [String], partial: [String] = [], irrelevant: [String] = []) -> EvaluationQuery {
        var query = EvaluationQuery(text: text)
        query.documents = relevant.map { ExpectedDocument(id: $0, grade: .relevant) }
            + partial.map { ExpectedDocument(id: $0, grade: .partial) }
            + irrelevant.map { ExpectedDocument(id: $0, grade: .irrelevant) }
        return query
    }

    private func run(queries: [EvaluationQuery], variants: [EvaluationVariant], results: [EvaluationResult]) -> EvaluationRun {
        EvaluationRun(
            name: "прогон", querySetID: UUID(), querySetName: "н",
            queries: queries, variants: variants, results: results, isComplete: true
        )
    }

    private func truth(_ queries: [EvaluationQuery]) -> [UUID: EvaluationQuery] {
        Dictionary(uniqueKeysWithValues: queries.map { ($0.id, $0) })
    }

    // MARK: - Hit rate @k

    func testHitRateIsTheShareOfQueriesWithSomethingRelevantInTheTop() {
        let first = query("а", relevant: ["a1"])
        let second = query("б", relevant: ["b1"])
        let third = query("в", relevant: ["c1"])
        let v = UUID()
        let results = [
            result(first.id, v, ["a1", "x", "y"]),   // попал
            result(second.id, v, ["x", "y", "b1"]),  // попал, третьим
            result(third.id, v, ["x", "y", "z"]),    // не попал
        ]
        let score = EvaluationMetrics.hitRateScore(results: results, truth: truth([first, second, third]), k: 5)
        XCTAssertEqual(score.value ?? 0, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(score.queries, 3)
    }

    /// Граничный случай: релевантный есть, но стоит за пределами k.
    func testARelevantResultBeyondKIsAMiss() {
        let q = query("а", relevant: ["a5"])
        let v = UUID()
        let results = [result(q.id, v, ["x", "y", "z", "w", "a5"])]
        XCTAssertEqual(EvaluationMetrics.hitRateScore(results: results, truth: truth([q]), k: 5).value, 1)
        XCTAssertEqual(EvaluationMetrics.hitRateScore(results: results, truth: truth([q]), k: 4).value, 0)
    }

    /// Запрос, у которого всё размечено «нерелевантно», попасть не может —
    /// считать его промахом значит наказывать поиск за разметку.
    func testAQueryMarkedEntirelyIrrelevantIsNotCountedAtAll() {
        let q = query("а", relevant: [], irrelevant: ["x"])
        let v = UUID()
        let score = EvaluationMetrics.hitRateScore(results: [result(q.id, v, ["x"])], truth: truth([q]), k: 5)
        XCTAssertNil(score.value)
        XCTAssertEqual(score.queries, 0)
        XCTAssertNotNil(score.reason)
    }

    func testAQueryWithoutGroundTruthIsSkippedRatherThanScoredZero() {
        let bare = EvaluationQuery(text: "без эталона")
        let marked = query("с эталоном", relevant: ["a1"])
        let v = UUID()
        let results = [result(bare.id, v, ["x"]), result(marked.id, v, ["a1"])]
        let score = EvaluationMetrics.hitRateScore(results: results, truth: truth([bare, marked]), k: 5)
        XCTAssertEqual(score.value, 1)
        XCTAssertEqual(score.queries, 1)
    }

    // MARK: - Recall @k

    func testRecallIsTheShareOfKnownRelevantThatWasFound() {
        // Известно четыре релевантных, в топ-5 нашлось два: 0.5.
        let q = query("а", relevant: ["a1", "a2", "a3", "a4"])
        let v = UUID()
        let results = [result(q.id, v, ["a1", "x", "a3", "y", "z"])]
        let score = EvaluationMetrics.recallScore(results: results, truth: truth([q]), k: 5)
        XCTAssertEqual(score.value ?? 0, 0.5, accuracy: 0.0001)
    }

    func testRecallCountsPartialAsFound() {
        // Полный список — два: релевантный и частичный. Найден частичный.
        let q = query("а", relevant: ["a1"], partial: ["a2"])
        let v = UUID()
        let score = EvaluationMetrics.recallScore(results: [result(q.id, v, ["a2"])], truth: truth([q]), k: 5)
        XCTAssertEqual(score.value ?? 0, 0.5, accuracy: 0.0001)
    }

    /// Полнота по фрагментам не считается: список фрагментов не полон.
    func testRecallIsInapplicableWithFragmentsAlone() {
        var q = EvaluationQuery(text: "а")
        q.fragments = [ExpectedFragment(fragment: "текст a1")]
        let v = UUID()
        let score = EvaluationMetrics.recallScore(results: [result(q.id, v, ["a1"])], truth: truth([q]), k: 5)
        XCTAssertNil(score.value)
        XCTAssertTrue(score.reason?.contains("фрагмент") ?? false, score.reason ?? "")
    }

    func testRecallNeverExceedsOne() {
        // Один релевантный по эталону, но фрагмент совпал ещё и с соседом.
        var q = query("а", relevant: ["a1"])
        q.fragments = [ExpectedFragment(fragment: "текст a")]
        let v = UUID()
        let score = EvaluationMetrics.recallScore(results: [result(q.id, v, ["a1", "a2", "a3"])], truth: truth([q]), k: 5)
        XCTAssertEqual(score.value, 1)
    }

    // MARK: - MRR

    func testMRRIsTheReciprocalRankOfTheFirstRelevant() {
        let q = query("а", relevant: ["a1"])
        let v = UUID()
        let score = EvaluationMetrics.mrrScore(results: [result(q.id, v, ["x", "y", "a1"])], truth: truth([q]))
        XCTAssertEqual(score.value ?? 0, 1.0 / 3.0, accuracy: 0.0001)
    }

    /// Ноль релевантных в выдаче — вклад 0, а не исключение из счёта:
    /// «не нашёл вовсе» — это ровно тот ответ, ради которого метрика есть.
    func testAQueryThatFoundNothingContributesZero() {
        let found = query("а", relevant: ["a1"])
        let missed = query("б", relevant: ["b1"])
        let v = UUID()
        let results = [result(found.id, v, ["a1"]), result(missed.id, v, ["x", "y"])]
        let score = EvaluationMetrics.mrrScore(results: results, truth: truth([found, missed]))
        XCTAssertEqual(score.value ?? 0, 0.5, accuracy: 0.0001)
    }

    // MARK: - nDCG @k

    /// Посчитано руками: выдача [релевантен, нерелевантен, частично].
    /// DCG = 1/log2(2) + 0 + 0.5/log2(4) = 1 + 0.25 = 1.25
    /// IDCG = 1/log2(2) + 0.5/log2(3) = 1 + 0.31546 = 1.31546
    /// nDCG = 1.25 / 1.31546 = 0.95023
    func testNDCGOnAHandCountedExample() {
        let q = query("а", relevant: ["a1"], partial: ["a3"], irrelevant: ["a2"])
        let v = UUID()
        let score = EvaluationMetrics.ndcgScore(results: [result(q.id, v, ["a1", "a2", "a3"])], truth: truth([q]), k: 3)
        XCTAssertEqual(score.value ?? 0, 0.95023, accuracy: 0.0001)
    }

    func testAPerfectRankingScoresOne() {
        let q = query("а", relevant: ["a1", "a2", "a3"])
        let v = UUID()
        let score = EvaluationMetrics.ndcgScore(results: [result(q.id, v, ["a1", "a2", "a3"])], truth: truth([q]), k: 5)
        XCTAssertEqual(score.value ?? 0, 1, accuracy: 0.0001)
    }

    func testFindingNothingScoresZero() {
        let q = query("а", relevant: ["a1"])
        let v = UUID()
        let score = EvaluationMetrics.ndcgScore(results: [result(q.id, v, ["x", "y"])], truth: truth([q]), k: 5)
        XCTAssertEqual(score.value, 0)
    }

    /// Порядок — это и есть то, что меряет nDCG: та же выдача задом наперёд
    /// обязана дать меньше.
    func testTheSameResultsInAWorseOrderScoreLower() {
        let q = query("а", relevant: ["a1"], partial: ["a2"])
        let v = UUID()
        let good = EvaluationMetrics.ndcgScore(results: [result(q.id, v, ["a1", "a2"])], truth: truth([q]), k: 5).value ?? 0
        let bad = EvaluationMetrics.ndcgScore(results: [result(q.id, v, ["a2", "a1"])], truth: truth([q]), k: 5).value ?? 0
        XCTAssertGreaterThan(good, bad)
    }

    /// Один фрагмент может совпасть с тремя чанками — идеал обязан это
    /// учитывать, иначе nDCG выйдет за единицу и покажет, что сломан инструмент,
    /// а не что хорош поиск.
    func testNDCGNeverExceedsOneWhenOneFragmentMatchesSeveralChunks() {
        var q = EvaluationQuery(text: "а")
        q.fragments = [ExpectedFragment(fragment: "текст a")]
        let v = UUID()
        let score = EvaluationMetrics.ndcgScore(
            results: [result(q.id, v, ["a1", "a2", "a3"])], truth: truth([q]), k: 5
        )
        XCTAssertEqual(score.value ?? 0, 1, accuracy: 0.0001)
    }

    // MARK: - Задержка

    func testLatencyIsMedianAndP95ByNearestRank() {
        let summary = LatencySummary.of([0.1, 0.2, 0.3, 0.4, 0.5])
        XCTAssertEqual(summary?.median ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertEqual(summary?.p95 ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(summary?.samples, 5)
        XCTAssertNil(LatencySummary.of([]))
    }

    /// Переиспользованный вектор не считается быстрым: он вообще не считался.
    func testEmbeddingLatencyIgnoresReusedVectors() {
        let q = query("а", relevant: ["a1"])
        let v = variant()
        let computed = EvaluationResult(
            queryID: q.id, variantID: v.id, hits: hits(["a1"]),
            embeddingSeconds: 0.4, searchSeconds: 0.01
        )
        let reused = EvaluationResult(
            queryID: q.id, variantID: v.id, hits: hits(["a1"]),
            embeddingSeconds: nil, reusedVector: true, searchSeconds: 0.02
        )
        let metrics = EvaluationMetrics.compute(
            run: run(queries: [q], variants: [v], results: [computed, reused])
        )[0]
        XCTAssertEqual(metrics.embeddingLatency?.samples, 1)
        XCTAssertEqual(metrics.embeddingLatency?.median ?? 0, 0.4, accuracy: 0.0001)
        XCTAssertEqual(metrics.searchLatency?.samples, 2)
    }

    // MARK: - Покрытие разметки и сбои

    func testCoverageCountsMarkedResultsAgainstAllOfThem() {
        let q = query("а", relevant: ["a1"])
        let v = variant()
        let metrics = EvaluationMetrics.compute(
            run: run(queries: [q], variants: [v], results: [result(q.id, v.id, ["a1", "x", "y"])])
        )[0]
        XCTAssertEqual(metrics.coverage.marked, 1)
        XCTAssertEqual(metrics.coverage.total, 3)
        XCTAssertFalse(metrics.coverage.isComplete)
        XCTAssertEqual(metrics.coverage.line, "размечено 1 из 3 результатов")
    }

    /// Упавшая ячейка — не промах: её вообще нет в знаменателе.
    func testAFailedCellIsExcludedFromEveryMetric() {
        let good = query("а", relevant: ["a1"])
        let broken = query("б", relevant: ["b1"])
        let v = variant()
        let metrics = EvaluationMetrics.compute(run: run(
            queries: [good, broken], variants: [v],
            results: [
                result(good.id, v.id, ["a1"]),
                EvaluationResult(queryID: broken.id, variantID: v.id, failure: "сервер не ответил"),
            ]
        ))[0]
        XCTAssertEqual(metrics.hitRate[5]?.value, 1)
        XCTAssertEqual(metrics.hitRate[5]?.queries, 1)
        XCTAssertEqual(metrics.failedCells, 1)
    }

    // MARK: - Пересчёт по новой разметке

    /// Разметка живёт в наборе, а не в прогоне: метрики обязаны пересчитаться
    /// по свежему набору без повторного прогона.
    func testMarkingAfterTheRunChangesTheMetricsWithoutRerunning() {
        let asRun = EvaluationQuery(text: "а")
        let v = variant()
        let stored = run(queries: [asRun], variants: [v], results: [result(asRun.id, v.id, ["a1", "a2"])])

        XCTAssertNil(EvaluationMetrics.compute(run: stored)[0].hitRate[5]?.value, "эталона ещё нет")

        var marked = asRun
        marked.fragments = [ExpectedFragment(fragment: "текст a2")]
        let set = QuerySet(name: "н", queries: [marked])

        let after = EvaluationMetrics.compute(run: stored, set: set)[0]
        XCTAssertEqual(after.hitRate[5]?.value, 1)
        XCTAssertEqual(after.mrr.value ?? 0, 0.5, accuracy: 0.0001, "релевантный оказался вторым")
        XCTAssertEqual(after.coverage.marked, 1)
    }

    /// Набор удалён — прогон продолжает считаться по своему снимку.
    func testADeletedSetDoesNotEraseTheRunsNumbers() {
        let q = query("а", relevant: ["a1"])
        let v = variant()
        let stored = run(queries: [q], variants: [v], results: [result(q.id, v.id, ["a1"])])
        XCTAssertEqual(EvaluationMetrics.compute(run: stored, set: nil)[0].hitRate[5]?.value, 1)
    }

    // MARK: - k

    func testDefaultKsAreFiveAndTenTogether() {
        XCTAssertEqual(EvaluationMetrics.defaultKs, [5, 10])
    }

    func testAVariantAskedForFewerResultsSaysSoInsteadOfPretending() {
        let q = query("а", relevant: ["a1"])
        let v = variant("узкий", nResults: 5)
        let metrics = EvaluationMetrics.compute(
            run: run(queries: [q], variants: [v], results: [result(q.id, v.id, ["a1"])])
        )[0]
        XCTAssertEqual(metrics.truncatedKs, [10])
        XCTAssertNotNil(metrics.note(for: 10))
        XCTAssertNil(metrics.note(for: 5))
    }

    // MARK: - Запрещённое

    /// «Общей оценки качества» одним числом не существует — ни в модели, ни в
    /// отчёте. Тест держит границу: свойство с таким именем не должно завестись.
    func testThereIsNoSingleQualityScore() {
        let q = query("а", relevant: ["a1"])
        let v = variant()
        let metrics = EvaluationMetrics.compute(
            run: run(queries: [q], variants: [v], results: [result(q.id, v.id, ["a1"])])
        )[0]
        let names = Mirror(reflecting: metrics).children.compactMap(\.label).map { $0.lowercased() }
        for forbidden in ["score", "overall", "quality", "total", "rating"] {
            XCTAssertFalse(names.contains { $0.contains(forbidden) }, "\(forbidden) в \(names)")
        }
    }
}
