import XCTest
@testable import ChromaCore

/// A collection whose answers the test dictates, and which remembers what it
/// was asked.
private actor FakeRetrievalDatabase: RetrievalDatabase {
    private(set) var requestedResults: [Int] = []
    private(set) var requestedFilters: [DocumentFilter?] = []
    private let hits: [QueryHit]

    init(hits: [QueryHit]) { self.hits = hits }

    func query(
        collectionID: String, embedding: [Double], nResults: Int, filter: DocumentFilter?,
        includeEmbeddings: Bool
    ) async throws -> [QueryHit] {
        requestedResults.append(nResults)
        requestedFilters.append(filter)
        return Array(hits.prefix(nResults))
    }

    /// A flat collection: it is the pipeline of stage 2 that these tests are
    /// about, and the hierarchy stages must cost nothing on one.
    func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord] { [] }

    private(set) var textFilters: [DocumentFilter] = []

    /// E2 does not apply to these tests: no neighbours exist to attach.
    func documents(
        collectionID: String, matching filter: DocumentFilter, limit: Int
    ) async throws -> [DocumentRecord] {
        textFilters.append(filter)
        return []
    }

    func anyDocument(collectionID: String, matching filter: DocumentFilter) async throws -> Bool {
        let clause = ((try? filter.whereClause()) ?? nil)?["chunk_level"] as? [String: Any] ?? [:]
        return clause["$eq"] != nil
    }

    func asked() -> [Int] { requestedResults }
    func filters() -> [DocumentFilter?] { requestedFilters }
    func textStageFilters() -> [DocumentFilter] { textFilters }
}

/// §E0 — the pipeline, its fixed stage order and its diagnostics.
final class RetrievalPipelineTests: XCTestCase {
    private func hits(_ count: Int) -> [QueryHit] {
        (0..<count).map {
            QueryHit(id: "d\($0)", document: "документ \($0)", metadata: nil, distance: Double($0) / 100)
        }
    }

    private func pipeline(_ database: FakeRetrievalDatabase) -> RetrievalPipeline {
        RetrievalPipeline(database: database, embed: { _ in [1, 0, 0] })
    }

    private func request(nResults: Int = 5, filter: DocumentFilter? = nil) -> RetrievalRequest {
        RetrievalRequest(
            text: "запрос", collectionID: "col", collectionName: "заметки",
            nResults: nResults, filter: filter
        )
    }

    // MARK: - The empty pipeline is the search of stage 2

    func testAnUntunedProfileAsksForExactlyWhatWasRequested() async throws {
        let database = FakeRetrievalDatabase(hits: hits(50))
        let pipeline = RetrievalPipeline(database: database, embed: { _ in [1, 0, 0] })

        let outcome = try await pipeline.run(request(nResults: 5), profile: SearchProfile(collectionName: "заметки"))

        // Not «просит пул и обрезает»: a larger pool can change which
        // neighbours an HNSW index returns at all, so «то же, что этап 2» has
        // to be literal.
        let asked = await database.asked()
        XCTAssertEqual(asked, [5])
        XCTAssertEqual(outcome.hits.map(\.id), ["d0", "d1", "d2", "d3", "d4"])
    }

    func testTheResultIsTheSameAsAPlainQuery() async throws {
        let expected = hits(5)
        let database = FakeRetrievalDatabase(hits: expected)
        let pipeline = RetrievalPipeline(database: database, embed: { _ in [1, 0, 0] })

        let outcome = try await pipeline.run(request(), profile: SearchProfile(collectionName: "заметки"))

        XCTAssertEqual(outcome.hits.map(\.queryHit), expected)
    }

    func testTheFilterIsPassedThroughUntouched() async throws {
        var filter = DocumentFilter()
        filter.textConditions = [DocumentTextCondition(op: .contains, text: "ORA-01555")]
        let database = FakeRetrievalDatabase(hits: hits(3))
        let pipeline = RetrievalPipeline(database: database, embed: { _ in [1] })

        _ = try await pipeline.run(request(filter: filter), profile: SearchProfile(collectionName: "заметки"))

        let passed = await database.filters()
        XCTAssertEqual(passed.count, 1)
        XCTAssertEqual(passed.first ?? nil, filter)
    }

    /// The Definition of Done asks for this literally: with the pipeline off the
    /// answer must be the answer of stage 2. Not «почти» — the same request to
    /// the collection and the same documents back, even when the profile that
    /// was switched off had every stage turned on.
    func testWithSmartSearchOffATunedProfileSearchesLikeStageTwo() async throws {
        let expected = hits(5)
        let tuned = FakeRetrievalDatabase(hits: expected)
        let plainDatabase = FakeRetrievalDatabase(hits: expected)

        var profile = SearchProfile(name: "настроенный", collectionName: "заметки")
        profile.diversityEnabled = true
        profile.textSearchEnabled = true
        profile.contextWindow = 3
        profile.collapseByParent = true

        let off = try await pipeline(tuned).run(
            request(), profile: SearchProfile.plain(collectionName: "заметки", name: profile.name)
        )
        let plain = try await pipeline(plainDatabase).run(
            request(), profile: SearchProfile(collectionName: "заметки", collapseByParent: false, promotion: .child)
        )

        XCTAssertEqual(off.hits.map(\.queryHit), expected)
        XCTAssertEqual(off.hits.map(\.id), plain.hits.map(\.id))
        // The pool matters as much as the result: asking an HNSW index for more
        // candidates can change which neighbours it returns at all.
        let asked = await tuned.asked()
        XCTAssertEqual(asked, [5])
        XCTAssertTrue(off.diagnostics.stages.filter(\.ran).map(\.stage) == [.candidates, .truncate])
    }

    /// Условие по тексту, заданное вызывающим, — ограничение, а не подсказка.
    /// Дописанное в тот же список, оно соединялось бы с вариантами запроса
    /// через `$or`, и текстовая стадия возвращала бы документы, которые его
    /// не выполняют вовсе.
    func testACallersTextConditionSurvivesTheTextStage() async throws {
        let database = FakeRetrievalDatabase(hits: hits(3))
        var profile = SearchProfile(collectionName: "заметки")
        profile.textSearchEnabled = true

        var filter = DocumentFilter()
        filter.textConditions = [DocumentTextCondition(op: .contains, text: "лицензия")]

        _ = try await pipeline(database).run(request(filter: filter), profile: profile)

        let asked = await database.textStageFilters()
        let clause = try XCTUnwrap(asked.first?.whereDocumentClause())
        let parts = try XCTUnwrap(clause["$and"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2, "условие вызывающего и варианты запроса должны быть двумя частями")
        XCTAssertEqual(parts.first?["$contains"] as? String, "лицензия")
        let variants = try XCTUnwrap(parts.last?["$or"] as? [[String: String]])
        XCTAssertTrue(variants.contains { $0["$contains"] == "запрос" }, "\(variants)")
        XCTAssertTrue(variants.contains { $0["$contains"] == "Запрос" }, "\(variants)")
    }

    // MARK: - Bounds

    func testTheNumberOfResultsIsClampedToWhatTheServerWillAnswer() async throws {
        let database = FakeRetrievalDatabase(hits: hits(200))
        let pipeline = RetrievalPipeline(database: database, embed: { _ in [1] })

        _ = try await pipeline.run(request(nResults: 5000), profile: SearchProfile(collectionName: "заметки"))
        _ = try await pipeline.run(request(nResults: 0), profile: SearchProfile(collectionName: "заметки"))

        let asked = await database.asked()
        XCTAssertEqual(asked, [100, 1])
    }

    func testFewerResultsThanRequestedIsNotAnError() async throws {
        let database = FakeRetrievalDatabase(hits: hits(2))
        let pipeline = RetrievalPipeline(database: database, embed: { _ in [1] })

        let outcome = try await pipeline.run(request(nResults: 10), profile: SearchProfile(collectionName: "заметки"))

        XCTAssertEqual(outcome.hits.count, 2)
    }

    // MARK: - Diagnostics

    func testEveryStageIsReportedInOrderIncludingTheOnesThatDidNotRun() async throws {
        let database = FakeRetrievalDatabase(hits: hits(5))
        let pipeline = RetrievalPipeline(database: database, embed: { _ in [1] })

        let outcome = try await pipeline.run(request(), profile: SearchProfile(collectionName: "заметки"))
        let stages = outcome.diagnostics.stages

        XCTAssertEqual(stages.map(\.stage), RetrievalStage.allCases.sorted { $0.order < $1.order })
        XCTAssertEqual(stages.filter(\.ran).map(\.stage), [.candidates, .marks, .truncate])
        // A stage that is absent from the report is indistinguishable from one
        // that ran and changed nothing.
        for report in stages where !report.ran {
            XCTAssertNotNil(report.note, "\(report.stage) не объяснил, почему не сработал")
        }
    }

    func testEmbeddingTimeIsReportedApartFromTheSearch() async throws {
        let database = FakeRetrievalDatabase(hits: hits(3))
        let pipeline = RetrievalPipeline(database: database, embed: { _ in
            try await Task.sleep(nanoseconds: 20_000_000)
            return [1]
        })

        let outcome = try await pipeline.run(request(), profile: SearchProfile(collectionName: "заметки"))

        let embedding = try XCTUnwrap(outcome.diagnostics.embeddingDuration)
        XCTAssertGreaterThan(embedding, 0.01)
        let candidates = outcome.diagnostics.stages.first { $0.stage == .candidates }
        XCTAssertLessThan(candidates?.duration ?? 1, embedding)
    }

    func testTheProfileNameIsInTheDiagnostics() async throws {
        let database = FakeRetrievalDatabase(hits: hits(3))
        let pipeline = RetrievalPipeline(database: database, embed: { _ in [1] })
        let profile = SearchProfile(name: "по коду ошибки", collectionName: "заметки")

        let outcome = try await pipeline.run(request(), profile: profile)

        XCTAssertEqual(outcome.diagnostics.profileName, "по коду ошибки")
        XCTAssertTrue(outcome.diagnostics.summary.contains("по коду ошибки"))
    }

    // MARK: - The panel of E0.4

    /// «Что и почему было отброшено» has to have an answer for the one stage
    /// that always discards something — otherwise the last line of the panel is
    /// the only one that explains nothing.
    func testTruncationSaysHowMuchItThrewAway() async throws {
        let database = FakeRetrievalDatabase(hits: hits(50))
        var profile = SearchProfile(collectionName: "заметки")
        // Any optional stage will do: what is needed is a pool larger than
        // `n_results` reaching stage 8.
        profile.contextWindow = 0
        profile.diversityEnabled = true

        let outcome = try await pipeline(database).run(request(nResults: 5), profile: profile)
        let truncate = outcome.diagnostics.stages.first { $0.stage == .truncate }

        XCTAssertEqual(truncate?.inputCount, 25, "пул дошёл до восьмой стадии целиком")
        XCTAssertEqual(truncate?.note, "отброшено 20 сверх n_results")
    }

    func testTruncationSaysSoWhenItDiscardedNothing() async throws {
        let database = FakeRetrievalDatabase(hits: hits(3))

        let outcome = try await pipeline(database).run(request(nResults: 5), profile: SearchProfile(collectionName: "заметки"))

        XCTAssertEqual(
            outcome.diagnostics.stages.first { $0.stage == .truncate }?.note,
            "отбрасывать нечего: кандидатов не больше, чем запрошено"
        )
    }

    func testTruncationCountsWhatItCut() async throws {
        let report = RetrievalDiagnostics.StageReport(
            stage: .truncate, ran: true, inputCount: 25, outputCount: 5
        )
        XCTAssertEqual(report.line, "Усечение: 25 → 5, 0 мс")
    }

    /// A result found by the vector search alone still has a position, and the
    /// panel says it: after MMR or a rerank the list on screen is not the list
    /// the search produced.
    func testAVectorResultCarriesThePositionTheSearchGaveIt() async throws {
        let database = FakeRetrievalDatabase(hits: hits(3))

        let outcome = try await pipeline(database).run(request(), profile: SearchProfile(collectionName: "заметки"))

        XCTAssertEqual(outcome.hits.map(\.originNote), [
            "векторный поиск, позиция 1",
            "векторный поиск, позиция 2",
            "векторный поиск, позиция 3",
        ])
    }

    func testTheWholePanelCanBeCopiedAsText() async throws {
        let database = FakeRetrievalDatabase(hits: hits(3))
        let profile = SearchProfile(name: "по коду ошибки", collectionName: "заметки")

        let outcome = try await pipeline(database).run(request(), profile: profile)
        let text = outcome.diagnostics.plainText

        XCTAssertTrue(text.hasPrefix("Как получен этот результат — профиль «по коду ошибки»"))
        // Every stage, in pipeline order, including the ones that did not run:
        // a stage missing from the copied text is a stage the reader cannot
        // rule out.
        for stage in RetrievalStage.allCases {
            XCTAssertTrue(text.contains(stage.title), "\(stage) не попала в скопированный текст")
        }
        // Eight stages, the header, and the embedding — which belongs to the
        // model rather than to any stage and is therefore its own line.
        XCTAssertTrue(text.contains("Вектор запроса"))
        XCTAssertEqual(text.split(separator: "\n").count, RetrievalStage.allCases.count + 2)
    }

    /// The panel marks the slowest stage only when there is one. On a query
    /// that took two milliseconds every stage is «the slowest» by noise, and an
    /// orange number would send somebody optimising nothing.
    func testNoStageIsBlamedWhenTheQueryWasFast() {
        var diagnostics = RetrievalDiagnostics()
        diagnostics.totalDuration = 0.004
        diagnostics.stages = [
            .init(stage: .candidates, ran: true, inputCount: 0, outputCount: 5, duration: 0.003),
        ]
        XCTAssertNil(diagnostics.slowestStage)
    }

    func testTheStageThatTookTheTimeIsNamed() {
        var diagnostics = RetrievalDiagnostics()
        diagnostics.totalDuration = 2.0
        diagnostics.stages = [
            .init(stage: .candidates, ran: true, inputCount: 0, outputCount: 20, duration: 0.1),
            .init(stage: .rerank, ran: true, inputCount: 20, outputCount: 20, duration: 1.8),
            .init(stage: .truncate, ran: true, inputCount: 20, outputCount: 5, duration: 0.001),
        ]
        XCTAssertEqual(diagnostics.slowestStage, .rerank)
    }

    /// Embedding is timed apart from the stages and shown apart from them: on a
    /// slow query it is usually most of the wait.
    func testTheEmbeddingLineAppearsOnlyWhenAVectorWasComputed() {
        var diagnostics = RetrievalDiagnostics()
        XCTAssertNil(diagnostics.embeddingLine, "текстовый поиск вектор не считает")
        diagnostics.embeddingDuration = 0.32
        XCTAssertEqual(diagnostics.embeddingLine, "Вектор запроса: 320 мс")
    }

    /// Zero is not «не считался»: it is what a cache hit looks like, and
    /// it is the most interesting number the line ever shows.
    func testAnInstantVectorIsStillReported() {
        var diagnostics = RetrievalDiagnostics()
        diagnostics.embeddingDuration = 0
        XCTAssertEqual(diagnostics.embeddingLine, "Вектор запроса: 0 мс")
    }
}

/// §E0.1 — the stage order is a fixed property, not the enum's declaration.
final class RetrievalStageTests: XCTestCase {
    func testTheOrderIsTheOneTheSpecificationFixes() {
        XCTAssertEqual(
            RetrievalStage.allCases.sorted { $0.order < $1.order },
            [.candidates, .fusion, .collapse, .diversity, .promote, .context, .rerank, .marks, .truncate]
        )
    }

    func testOnlyCandidatesAndTruncationAreMandatory() {
        XCTAssertEqual(RetrievalStage.allCases.filter { !$0.isOptional }, [.candidates, .truncate])
    }

    func testTheOrderIsUniqueSoTwoStagesCanNotSwap() {
        XCTAssertEqual(Set(RetrievalStage.allCases.map(\.order)).count, RetrievalStage.allCases.count)
    }
}

/// §E0.2 — the candidate pool.
final class SearchProfilePoolTests: XCTestCase {
    func testWithNothingToDiscardNoPoolIsAskedFor() {
        let profile = SearchProfile(collectionName: "заметки")
        XCTAssertEqual(profile.poolSize(nResults: 5, stages: []), 5)
        XCTAssertEqual(profile.poolSize(nResults: 100, stages: []), 100)
    }

    /// Promotion changes what a result is, not how many there are.
    func testPromotionAloneNeedsNoSpareCandidates() {
        let profile = SearchProfile(collectionName: "заметки")
        XCTAssertEqual(profile.poolSize(nResults: 5, stages: [.promote]), 5)
    }

    func testCollapsingAsksForAPool() {
        let profile = SearchProfile(collectionName: "заметки")
        XCTAssertEqual(profile.poolSize(nResults: 5, stages: [.collapse]), 25)
        XCTAssertEqual(profile.poolSize(nResults: 2, stages: [.collapse]), 20, "минимум держит запас для мелких запросов")
    }

    func testThePoolIsNeverSmallerThanWhatWasRequested() {
        let profile = SearchProfile(collectionName: "заметки", minimumCandidates: 20)
        XCTAssertGreaterThanOrEqual(profile.poolSize(nResults: 50, stages: [.collapse]), 50)
    }
}
