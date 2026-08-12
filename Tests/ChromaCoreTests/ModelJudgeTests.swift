import XCTest
@testable import ChromaCore

/// оценка выдачи чат-моделью: необязательный режим, чей главный
/// признак не «работает», а «не подменяет собой разметку».
final class ModelJudgeTests: XCTestCase {

    // MARK: - Фикстуры

    private func variant(_ name: String) -> EvaluationVariant {
        EvaluationVariant(
            name: name, collectionID: "c", collectionName: "коллекция",
            model: "модель", nResults: 5,
            profile: SearchProfile(collectionName: "коллекция")
        )
    }

    private func run(hits: [String]) -> (EvaluationRun, EvaluationQuery, EvaluationVariant) {
        let query = EvaluationQuery(text: "как считается доступность")
        let variant = self.variant("A")
        let run = EvaluationRun(
            name: "прогон", querySetID: UUID(), querySetName: "набор",
            queries: [query], variants: [variant],
            results: [EvaluationResult(
                queryID: query.id, variantID: variant.id,
                hits: hits.enumerated().map {
                    EvaluationHit(id: "d\($0.offset)", text: $0.element, distance: nil, position: $0.offset + 1)
                }
            )],
            isComplete: true
        )
        return (run, query, variant)
    }

    /// Модель, отвечающая по схеме. Считает вызовы — на этом стоит проверка
    /// того, что уже оценённое не переспрашивается.
    private actor FakeJudge {
        private(set) var calls = 0
        private let answers: [String]

        init(answers: [String]) { self.answers = answers }

        func answer(_ prompt: String, _ model: String, _ schema: ChatJSONSchema) async throws -> String {
            calls += 1
            return answers[min(calls - 1, answers.count - 1)]
        }
    }

    private func judge(_ fake: FakeJudge) -> ModelJudge {
        ModelJudge(grade: { prompt, model, schema in
            try await fake.answer(prompt, model, schema)
        })
    }

    // MARK: - Разбор ответа

    /// Схема гарантирует форму, но не то, что перед нами вообще JSON: модель
    /// без поддержки Structured Output ответит прозой, и разбор обязан это
    /// пережить, а не уронить прогон.
    func testProseInsteadOfJSONIsNotAJudgement() {
        XCTAssertNil(ModelJudge.parse("Думаю, фрагмент подходит."))
        XCTAssertNil(ModelJudge.parse(""))
        XCTAssertNil(ModelJudge.parse(#"{"grade": "может быть", "reason": "…"}"#))
    }

    func testTheThreeGradesAreRecognised() {
        XCTAssertEqual(ModelJudge.gradeFromModel("relevant"), .relevant)
        XCTAssertEqual(ModelJudge.gradeFromModel("PARTIAL"), .partial)
        XCTAssertEqual(ModelJudge.gradeFromModel("irrelevant"), .irrelevant)
        XCTAssertNil(ModelJudge.gradeFromModel("yes"))
    }

    // MARK: - Прогон оценки

    func testEveryResultGetsAJudgementWithItsReason() async {
        let (run, query, variant) = run(hits: ["формула доступности", "прайс-лист"])
        let fake = FakeJudge(answers: [
            #"{"grade": "relevant", "reason": "прямо отвечает"}"#,
            #"{"grade": "irrelevant", "reason": "про другое"}"#,
        ])
        let set = await judge(fake).run(
            run: run, model: "м", prompt: JudgePrompt(), existing: nil
        )
        XCTAssertEqual(set.judgements.count, 2)
        XCTAssertTrue(set.isComplete)
        let first = set.judgement(query: query.id, variant: variant.id, document: "d0")
        XCTAssertEqual(first?.grade, .relevant)
        XCTAssertEqual(first?.reason, "прямо отвечает")
        XCTAssertEqual(
            set.judgement(query: query.id, variant: variant.id, document: "d1")?.grade,
            .irrelevant
        )
    }

    /// Уже оценённое той же редакцией промпта не переспрашивается: это минуты
    /// работы модели, потраченные впустую.
    func testAlreadyJudgedResultsAreNotAskedAgain() async {
        let (run, _, _) = run(hits: ["раз", "два"])
        let firstFake = FakeJudge(answers: [#"{"grade": "relevant", "reason": "р"}"#])
        let first = await judge(firstFake).run(run: run, model: "м", prompt: JudgePrompt())
        let callsAfterFirst = await firstFake.calls
        XCTAssertEqual(callsAfterFirst, 2)

        let secondFake = FakeJudge(answers: [#"{"grade": "relevant", "reason": "р"}"#])
        _ = await judge(secondFake).run(
            run: run, model: "м", prompt: JudgePrompt(), existing: first
        )
        let callsAfterSecond = await secondFake.calls
        XCTAssertEqual(callsAfterSecond, 0, "повторный прогон тем же промптом не должен звать модель")
    }

    /// Правка промпта делает прежние оценки несравнимыми — значит их надо
    /// снять заново, а не выдавать старые за новые.
    func testEditingThePromptMakesTheJudgementsStale() async {
        let (run, _, _) = run(hits: ["раз"])
        let first = await judge(FakeJudge(answers: [#"{"grade": "relevant", "reason": "р"}"#]))
            .run(run: run, model: "м", prompt: JudgePrompt())

        let edited = JudgePrompt(text: JudgePrompt.defaultText + " Отвечай строго.")
        let fake = FakeJudge(answers: [#"{"grade": "partial", "reason": "иначе"}"#])
        let second = await judge(fake).run(
            run: run, model: "м", prompt: edited, existing: first
        )
        let calls = await fake.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(second.judgements.count, 1, "переоценка заменяет, а не копится вторым мнением")
        XCTAssertEqual(second.judgements.first?.grade, .partial)
        XCTAssertEqual(second.judgements.first?.promptFingerprint, edited.fingerprint)
    }

    /// Ответ, который не удалось разобрать, — не оценка «нерелевантен».
    /// Прогон помечается неполным, и сказано, сколько результатов остались
    /// без оценки.
    func testAnUnparsableAnswerLeavesTheResultUnjudged() async {
        let (run, _, _) = run(hits: ["раз", "два"])
        let set = await judge(FakeJudge(answers: ["не знаю"]))
            .run(run: run, model: "м", prompt: JudgePrompt())
        XCTAssertTrue(set.judgements.isEmpty)
        XCTAssertFalse(set.isComplete)
        XCTAssertFalse(set.note.isEmpty)
    }

    // MARK: - Граница между оценкой и эталоном

    /// Главное свойство пункта: оценка модели не может попасть в набор
    /// запросов. Проверяется не соглашением, а типами — `JudgementSet`
    /// не содержит ничего, что `QuerySet` умеет принять.
    func testAJudgementCannotBecomeGroundTruthByItself() async {
        let (run, query, variant) = run(hits: ["формула доступности"])
        let set = await judge(FakeJudge(answers: [#"{"grade": "relevant", "reason": "р"}"#]))
            .run(run: run, model: "м", prompt: JudgePrompt())
        XCTAssertEqual(set.judgements.count, 1)

        // Эталон запроса при этом пуст, и метрики его не видят.
        XCTAssertFalse(query.hasGroundTruth)
        let metrics = EvaluationMetrics.compute(run: run, set: nil)
        XCTAssertNil(metrics.first?.hitRate[5]?.value, "оценка модели не считается метрикой")
        XCTAssertEqual(
            set.judgement(query: query.id, variant: variant.id, document: "d0")?.grade,
            .relevant
        )
    }

    // MARK: - Промпт

    /// Промпт без подстановок показал бы модели один и тот же текст на каждом
    /// результате. Ловится до запуска, а не после десяти минут работы.
    func testAPromptWithoutPlaceholdersIsRefusedBeforeTheRun() {
        XCTAssertNil(JudgePrompt().problem)
        XCTAssertNotNil(JudgePrompt(text: "Оцени результат.").problem)
        XCTAssertNotNil(JudgePrompt(text: "Запрос: {query}").problem)
        XCTAssertNotNil(JudgePrompt(text: "   ").problem)
    }

    func testTheFingerprintFollowsTheMeaningNotTheWhitespace() {
        let one = JudgePrompt(text: "Запрос: {query}\nФрагмент: {document}")
        let same = JudgePrompt(text: "Запрос:   {query}\n\n  Фрагмент: {document}")
        let other = JudgePrompt(text: "Запрос: {query}\nФрагмент: {document}\nСтрого.")
        XCTAssertEqual(one.fingerprint, same.fingerprint)
        XCTAssertNotEqual(one.fingerprint, other.fingerprint)
    }

    // MARK: - Стоимость

    /// ТЗ делает предупреждение обязательным. Число вызовов известно всегда,
    /// время — только если эту модель уже мерили (12.7).
    func testTheCostNamesTheCallsAndOnlyGuessesNothing() {
        let (run, _, _) = run(hits: ["раз", "два", "три"])
        let unmeasured = JudgementCost.estimate(
            run: run, existing: nil, promptFingerprint: "x", secondsPerCall: nil
        )
        XCTAssertEqual(unmeasured.calls, 3)
        XCTAssertNil(unmeasured.seconds)
        XCTAssertTrue(unmeasured.line.contains("не измерена"), unmeasured.line)

        let measured = JudgementCost.estimate(
            run: run, existing: nil, promptFingerprint: "x", secondsPerCall: 7
        )
        XCTAssertEqual(measured.seconds, 21)
        XCTAssertNotNil(measured.durationText)
    }

    /// Уже оценённое вычитается из стоимости и называется отдельно — иначе
    /// человек второй раз платит за то, что у него уже есть.
    func testTheCostSubtractsWhatIsAlreadyJudged() async {
        let (run, _, _) = run(hits: ["раз", "два"])
        let existing = await judge(FakeJudge(answers: [#"{"grade": "relevant", "reason": "р"}"#]))
            .run(run: run, model: "м", prompt: JudgePrompt())
        let cost = JudgementCost.estimate(
            run: run, existing: existing,
            promptFingerprint: JudgePrompt().fingerprint, secondsPerCall: nil
        )
        XCTAssertEqual(cost.calls, 0)
        XCTAssertEqual(cost.alreadyJudged, 2)
    }

    /// Сбойная ячейка прогона не оценивается: у неё нет выдачи, и звать
    /// модель не на что.
    func testAFailedCellCostsNothing() {
        let query = EvaluationQuery(text: "з")
        let variant = self.variant("A")
        let run = EvaluationRun(
            name: "п", querySetID: UUID(), querySetName: "н",
            queries: [query], variants: [variant],
            results: [EvaluationResult(
                queryID: query.id, variantID: variant.id, failure: "вектор не посчитан"
            )]
        )
        XCTAssertEqual(
            JudgementCost.estimate(run: run, existing: nil, promptFingerprint: "x", secondsPerCall: 1).calls,
            0
        )
    }

    // MARK: - Хранение

    func testJudgementsSurviveReopeningAndAreKeptApartFromTheRun() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("judgements-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = JudgementStore(directory: directory)
        let runID = UUID()
        var set = JudgementSet(runID: runID)
        set.judgements.append(ModelJudgement(
            queryID: UUID(), variantID: UUID(), documentID: "d0",
            grade: .partial, reason: "касается темы", model: "м", promptFingerprint: "f"
        ))
        XCTAssertTrue(store.save(set))

        let reopened = JudgementStore(directory: directory).set(for: runID)
        XCTAssertEqual(reopened?.judgements.first?.grade, .partial)
        XCTAssertEqual(reopened?.judgements.first?.reason, "касается темы")

        store.remove(runID: runID)
        XCTAssertNil(JudgementStore(directory: directory).set(for: runID))
    }

    /// Скорость оценки копится отдельно от скорости эмбеддинга: одно имя
    /// модели, две разные работы, и подмешать одно в другое значило бы
    /// испортить оценку стоимости прогона стенда.
    func testJudgeSpeedIsKeptApartFromEmbeddingSpeed() async {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("metrics-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let store = MetricsStore(fileURL: file)
        await store.recordEmbedding(model: "м", texts: 10, duration: 1)
        await store.recordJudgement(model: "м", calls: 2, duration: 14)

        let snapshot = await store.current()
        XCTAssertEqual(snapshot.models.first?.averageSeconds, 0.1)
        XCTAssertEqual(snapshot.judgeSecondsPerCall(model: "м"), 7)
        XCTAssertNil(snapshot.judgeSecondsPerCall(model: "другая"))
    }
}
