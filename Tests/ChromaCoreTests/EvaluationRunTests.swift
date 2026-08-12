import XCTest
@testable import ChromaCore

/// §D1.2 — варианты и прогон.
final class EvaluationRunTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("evaluation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Стенд

    private func variant(
        _ name: String,
        model: String = "bge-m3",
        textOnly: Bool = false,
        nResults: Int = 5
    ) -> EvaluationVariant {
        var profile = SearchProfile.plain(collectionName: "c-\(name)", name: "профиль \(name)")
        if textOnly {
            profile.vectorSearchEnabled = false
            profile.textSearchEnabled = true
        }
        return EvaluationVariant(
            name: name,
            collectionID: "id-\(name)",
            collectionName: "c-\(name)",
            model: model,
            nResults: nResults,
            profile: profile
        )
    }

    private func outcome(_ ids: [String], texts: [String] = []) -> RetrievalOutcome {
        RetrievalOutcome(
            hits: ids.enumerated().map { index, id in
                RetrievalHit(
                    id: id,
                    document: index < texts.count ? texts[index] : "текст \(id)",
                    metadata: nil,
                    distance: Double(index) / 10
                )
            },
            diagnostics: RetrievalDiagnostics()
        )
    }

    private func set(_ texts: [String]) -> QuerySet {
        QuerySet(name: "набор", queries: texts.map { EvaluationQuery(text: $0) })
    }

    // MARK: - Дедупликация вектора

    /// Главное свойство прогона: вектор считается один раз на (запрос, модель).
    /// Четыре варианта одной модели — это один вызов эмбеддинга на запрос,
    /// а не четыре.
    func testTheQueryIsEmbeddedOncePerModelRatherThanOncePerVariant() async {
        let calls = Counter()
        let runner = EvaluationRunner(
            embed: { text, model in
                await calls.record("\(model)|\(text)")
                return [1, 0]
            },
            search: { [self] _, _, _ in outcome(["a"]) }
        )

        let run = await runner.run(
            set: set(["первый", "второй"]),
            variants: [
                variant("512", model: "bge-m3"),
                variant("1024", model: "bge-m3"),
                variant("другая модель", model: "e5-large"),
            ]
        )

        // 2 запроса × 2 модели = 4 вызова вместо шести.
        let recorded = await calls.values
        XCTAssertEqual(recorded.count, 4, recorded.joined(separator: ", "))
        let embeddingCalls = await runner.embeddingCallCount
        XCTAssertEqual(embeddingCalls, 4)
        XCTAssertEqual(run.results.count, 6, "поиск выполняется для каждого варианта")
        XCTAssertEqual(run.embeddingCalls, 4)
    }

    func testAReusedVectorIsMarkedAsReusedRatherThanAsInstant() async {
        let runner = EvaluationRunner(
            embed: { _, _ in [1] },
            search: { [self] _, _, _ in outcome(["a"]) }
        )
        let run = await runner.run(set: set(["запрос"]), variants: [variant("A"), variant("B")])

        let first = run.results[0]
        let second = run.results[1]
        XCTAssertNotNil(first.embeddingSeconds)
        XCTAssertFalse(first.reusedVector)
        // Ноль секунд был бы неправдой в статистике задержки: второй
        // вариант не «мгновенно посчитал вектор», он его не считал вовсе.
        XCTAssertNil(second.embeddingSeconds)
        XCTAssertTrue(second.reusedVector)
    }

    func testAVariantThatNeedsNoVectorCallsNoModel() async {
        let calls = Counter()
        let runner = EvaluationRunner(
            embed: { text, model in
                await calls.record(model)
                return [1]
            },
            search: { [self] _, _, vector in
                XCTAssertNil(vector, "текстовому поиску вектор не передаётся")
                return outcome(["a"])
            }
        )
        let run = await runner.run(set: set(["запрос"]), variants: [variant("текст", textOnly: true)])

        let recorded = await calls.values
        XCTAssertEqual(recorded.count, 0)
        XCTAssertEqual(run.results.count, 1)
    }

    // MARK: - Что попадает в результат

    /// Контекст (родитель, сосед) — это текст рядом с результатом, а не
    /// результат. Иначе вариант с включённым контекстом получил бы более
    /// длинный список, по которому его же и оценивают.
    func testAttachedContextIsNotCountedAsAResult() {
        let hit = RetrievalHit(id: "child", document: "нашлось", metadata: nil, distance: 0.1)
        let context = RetrievalHit(
            id: "parent", document: "раздел целиком", metadata: nil, distance: nil,
            role: .context, contextKind: .parent
        )
        let hits = EvaluationRunner.hits(from: RetrievalOutcome(
            hits: [hit, context], diagnostics: RetrievalDiagnostics()
        ))
        XCTAssertEqual(hits.map(\.id), ["child"])
        XCTAssertEqual(hits.first?.position, 1)
    }

    func testTheFullTextIsStoredRatherThanAPreview() async {
        let long = String(repeating: "слово ", count: 300)
        let runner = EvaluationRunner(
            embed: { _, _ in [1] },
            search: { [self] _, _, _ in outcome(["a"], texts: [long]) }
        )
        let run = await runner.run(set: set(["з"]), variants: [variant("A")])
        XCTAssertEqual(run.results.first?.hits.first?.text, long)
    }

    // MARK: - Отмена

    /// Отмена в середине сохраняет уже полученное и помечает прогон неполным.
    func testCancellingMidRunKeepsWhatItHasAndSaysSo() async {
        let first = expectation(description: "первый запрос выполнен")
        let counter = Counter()
        let runner = EvaluationRunner(
            embed: { _, _ in [1] },
            search: { [self] _, _, _ in
                await counter.record("cell")
                let count = await counter.values.count
                if count == 1 {
                    first.fulfill()
                    return outcome(["a"])
                }
                // Второй запрос стоит долго — на нём прогон и отменяют, как
                // отменяют настоящий: посреди обращения к базе.
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return outcome(["a"])
            }
        )

        let task = Task { () -> EvaluationRun in
            await runner.run(
                set: set(["первый", "второй", "третий", "четвёртый"]),
                variants: [self.variant("A")]
            )
        }
        await fulfillment(of: [first], timeout: 5)
        task.cancel()
        let run = await task.value

        XCTAssertFalse(run.isComplete)
        XCTAssertEqual(run.results.count, 1, "выполненный запрос сохранён, недоделанный — нет")
        XCTAssertTrue(run.note.contains("отменён"), run.note)
        XCTAssertTrue(run.note.contains("\(run.results.count) из 4"), run.note)
    }

    // MARK: - Неудача ячейки

    /// Упавший запрос — это не «ничего не нашлось». Ноль результатов и ошибка
    /// сети — разные факты, и метрика не имеет права считать их одинаково.
    func testAFailedCellIsRecordedAsAFailureRatherThanAnEmptyAnswer() async {
        struct Boom: LocalizedError { var errorDescription: String? { "сервер не ответил" } }
        let runner = EvaluationRunner(
            embed: { _, _ in [1] },
            search: { variant, _, _ in
                if variant.name == "B" { throw Boom() }
                return RetrievalOutcome(hits: [], diagnostics: RetrievalDiagnostics())
            }
        )
        let run = await runner.run(set: set(["з"]), variants: [variant("A"), variant("B")])

        let failed = run.result(query: run.queries[0].id, variant: run.variants[1].id)
        XCTAssertEqual(failed?.failure, "сервер не ответил")
        XCTAssertFalse(failed?.succeeded ?? true)
        // Пустая выдача варианта A — настоящий факт о поиске, а не сбой.
        XCTAssertTrue(run.result(query: run.queries[0].id, variant: run.variants[0].id)?.succeeded ?? false)
        XCTAssertFalse(run.isComplete)
        XCTAssertTrue(run.note.contains("Не выполнено"), run.note)
    }

    func testAnEmbeddingFailureStillLeavesTheOtherVariantsRunning() async {
        struct Boom: LocalizedError { var errorDescription: String? { "модель выгружена" } }
        let runner = EvaluationRunner(
            embed: { _, model in
                if model == "сломанная" { throw Boom() }
                return [1]
            },
            search: { [self] _, _, _ in outcome(["a"]) }
        )
        let run = await runner.run(
            set: set(["з"]),
            variants: [variant("A", model: "сломанная"), variant("B", model: "рабочая")]
        )
        XCTAssertEqual(run.results.count, 2)
        XCTAssertTrue(run.results[0].failure?.contains("модель выгружена") ?? false)
        XCTAssertTrue(run.results[1].succeeded)
    }

    // MARK: - Эталон переживает перенарезку

    /// Два варианта нарезаны по-разному: идентификаторы чанков не совпадают
    /// ни в чём. Эталон-подстрока находит нужный текст в обоих — ради этого
    /// он и подстрока.
    func testGroundTruthByFragmentMatchesBothVariantsDespiteDifferentIDs() async {
        let runner = EvaluationRunner(
            embed: { _, _ in [1] },
            search: { [self] variant, _, _ in
                variant.name == "512"
                    ? outcome(["doc.md#0"], texts: ["Срок действия лицензии: бессрочная. Обновления 36 месяцев."])
                    : outcome(["doc.md#0-1"], texts: ["…комплекс 1 ALD Pro.\nСрок действия\nлицензии: бессрочная."])
            }
        )
        var query = EvaluationQuery(text: "срок лицензии")
        query.fragments = [ExpectedFragment(fragment: "срок действия лицензии: бессрочная")]
        let run = await runner.run(
            set: QuerySet(name: "н", queries: [query]),
            variants: [variant("512"), variant("1024")]
        )

        for result in run.results {
            let hit = result.hits.first
            XCTAssertEqual(
                run.queries[0].grade(forDocument: hit?.id ?? "", text: hit?.text),
                .relevant,
                "вариант \(result.variantID) не сопоставился с эталоном"
            )
        }
        XCTAssertEqual(Set(run.results.flatMap { $0.hits.map(\.id) }).count, 2, "id действительно разные")
    }

    // MARK: - Оценка стоимости

    func testTheEstimateCountsCallsAfterDeduplication() {
        let cost = EvaluationCost.estimate(
            queries: (1...10).map { EvaluationQuery(text: "запрос \($0)") },
            variants: [variant("A"), variant("B"), variant("C"), variant("D")],
            metrics: MetricsSnapshot()
        )
        XCTAssertEqual(cost.searchCalls, 40)
        XCTAssertEqual(cost.embeddingCalls, 10, "одна модель — десять вызовов, а не сорок")
        XCTAssertEqual(cost.savedEmbeddingCalls, 30)
        XCTAssertTrue(cost.line.contains("10 × 4 = 40"), cost.line)
    }

    /// Строка стоимости читается вслух, и «2 поисковых запросов» в ней выглядит
    /// как ошибка во всём остальном на экране. Найдено на живом прогоне.
    func testTheCostLineAgreesWithItsNumbers() {
        let line = EvaluationCost.estimate(
            queries: [EvaluationQuery(text: "a"), EvaluationQuery(text: "b")],
            variants: [variant("A")],
            metrics: MetricsSnapshot()
        ).line
        XCTAssertTrue(line.contains("2 поисковых запроса"), line)
        XCTAssertFalse(line.contains("запросов"), line)

        // Прилагательное согласуется так же, как существительное: «1 поисковых
        // запрос» в первой же строке экрана выглядит как ошибка во всём
        // остальном. Найдено на живом прогоне из одного запроса.
        XCTAssertEqual(EvaluationCost.searches(1), "1 поисковый запрос")
        XCTAssertEqual(EvaluationCost.searches(4), "4 поисковых запроса")
        XCTAssertEqual(EvaluationCost.searches(11), "11 поисковых запросов")
    }

    /// Быстрая модель на коротком наборе — это «меньше секунды», а не
    /// «около 0 с»: округление до нуля читается как сломанный счётчик.
    func testASubSecondEstimateSaysSoInsteadOfSayingZero() {
        var metrics = MetricsSnapshot()
        metrics.models = [.init(model: "bge-m3", texts: 100, seconds: 5)]
        let cost = EvaluationCost.estimate(
            queries: [EvaluationQuery(text: "a")], variants: [variant("A")], metrics: metrics
        )
        XCTAssertEqual(cost.durationText, "меньше секунды")
    }

    func testTwoModelsAreCountedSeparately() {
        let cost = EvaluationCost.estimate(
            queries: [EvaluationQuery(text: "a"), EvaluationQuery(text: "b")],
            variants: [variant("A", model: "one"), variant("B", model: "two"), variant("C", model: "two")],
            metrics: MetricsSnapshot()
        )
        XCTAssertEqual(cost.embeddingCalls, 4)
        XCTAssertEqual(cost.savedEmbeddingCalls, 2)
    }

    func testATextOnlyVariantAddsSearchesButNoEmbeddings() {
        let cost = EvaluationCost.estimate(
            queries: [EvaluationQuery(text: "a")],
            variants: [variant("текст", textOnly: true)],
            metrics: MetricsSnapshot()
        )
        XCTAssertEqual(cost.searchCalls, 1)
        XCTAssertEqual(cost.embeddingCalls, 0)
        XCTAssertNil(cost.seconds)
    }

    /// Скорость берётся из измеренного, иначе времени нет вовсе: выдуманному
    /// числу поверят (12.7).
    func testTimeComesFromMeasurementOrNotAtAll() {
        let variants = [variant("A", model: "bge-m3")]
        let queries = (1...4).map { EvaluationQuery(text: "q\($0)") }

        XCTAssertNil(EvaluationCost.estimate(
            queries: queries, variants: variants, metrics: MetricsSnapshot()
        ).seconds)

        var metrics = MetricsSnapshot()
        metrics.models = [.init(model: "bge-m3", texts: 100, seconds: 50)]
        let measured = EvaluationCost.estimate(queries: queries, variants: variants, metrics: metrics)
        XCTAssertEqual(measured.seconds ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(measured.basis, .measuredWork)

        let benchmarked = EvaluationCost.estimate(
            queries: queries, variants: variants, metrics: MetricsSnapshot(),
            benchmarks: [ModelBenchmark(
                model: "bge-m3", measuredAt: Date(), dimension: 8, firstCallSeconds: 1,
                batches: [BenchmarkBatchResult(batchSize: 1, texts: 10, seconds: 5)]
            )]
        )
        XCTAssertEqual(benchmarked.seconds ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(benchmarked.basis, .benchmark)
    }

    /// Одна модель измерена, другая нет — времени нет: сумма, в которой не
    /// хватает слагаемого, меньше правды и выглядит как правда.
    func testAPartiallyMeasuredEstimateGivesNoTime() {
        var metrics = MetricsSnapshot()
        metrics.models = [.init(model: "one", texts: 10, seconds: 5)]
        let cost = EvaluationCost.estimate(
            queries: [EvaluationQuery(text: "a")],
            variants: [variant("A", model: "one"), variant("B", model: "two")],
            metrics: metrics
        )
        XCTAssertNil(cost.seconds)
        XCTAssertEqual(cost.basis, .unknown)
    }

    // MARK: - Хранение прогона

    func testARunSurvivesReopeningWithItsVariantsIntact() async {
        let store = EvaluationRunStore(directory: directory)
        let runner = EvaluationRunner(
            embed: { _, _ in [1] },
            search: { [self] _, _, _ in outcome(["a", "b"]) }
        )
        var made = await runner.run(set: set(["з"]), variants: [variant("512", nResults: 7)])
        made.name = "первое сравнение"
        XCTAssertTrue(store.save(made))

        let reopened = EvaluationRunStore(directory: directory).run(id: made.id)
        XCTAssertEqual(reopened?.name, "первое сравнение")
        XCTAssertEqual(reopened?.results.first?.hits.count, 2)
        // Полные параметры варианта — иначе через месяц не понять, что
        // сравнивалось.
        XCTAssertEqual(reopened?.variants.first?.nResults, 7)
        XCTAssertEqual(reopened?.variants.first?.profile.name, "профиль 512")
        XCTAssertEqual(reopened?.variants.first?.model, "bge-m3")
    }

    func testTheListShowsNewestFirstAndSurvivesAStrayFile() throws {
        let store = EvaluationRunStore(directory: directory)
        let old = EvaluationRun(
            name: "старый", startedAt: Date(timeIntervalSinceNow: -3_600),
            querySetID: UUID(), querySetName: "н"
        )
        let recent = EvaluationRun(name: "свежий", querySetID: UUID(), querySetName: "н")
        store.save(old)
        store.save(recent)
        try Data("не json".utf8).write(to: directory.appendingPathComponent("мусор.json"))

        let names = EvaluationRunStore(directory: directory).summaries().map(\.name)
        XCTAssertEqual(names, ["свежий", "старый"])
    }

    func testRemovingARunTakesOnlyThatRun() async {
        let store = EvaluationRunStore(directory: directory)
        let first = EvaluationRun(name: "один", querySetID: UUID(), querySetName: "н")
        let second = EvaluationRun(name: "два", querySetID: UUID(), querySetName: "н")
        store.save(first)
        store.save(second)
        store.remove(id: first.id)

        XCTAssertNil(store.run(id: first.id))
        XCTAssertEqual(store.summaries().map(\.name), ["два"])
    }
}

/// Счётчик вызовов, годный для проверки из акторного кода.
private actor Counter {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}
