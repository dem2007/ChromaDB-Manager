import XCTest
@testable import ChromaCore

/// §E4 — RRF merges lists whose scales are not comparable.
final class ReciprocalRankFusionTests: XCTestCase {
    private func fuse(
        _ vector: [String], _ text: [String],
        vectorWeight: Double = 1, textWeight: Double = 1, k: Double = ReciprocalRankFusion.defaultK
    ) -> [ReciprocalRankFusion.Fused] {
        ReciprocalRankFusion.fuse(
            [
                .init(source: .vector, ids: vector, weight: vectorWeight),
                .init(source: .text, ids: text, weight: textWeight),
            ],
            k: k
        )
    }

    /// Worked out by hand with k = 60. Vector ["a","b","c"], text ["d","a"]:
    ///   a: 1/(60+1) + 1/(60+2) = 0.016393 + 0.016129 = 0.032522
    ///   d: 1/(60+1)            = 0.016393
    ///   b: 1/(60+2)            = 0.016129
    ///   c: 1/(60+3)            = 0.015873
    /// order: a, d, b, c
    func testTheOrderMatchesAHandComputedReference() {
        let fused = fuse(["a", "b", "c"], ["d", "a"])
        XCTAssertEqual(fused.map(\.id), ["a", "d", "b", "c"])
        XCTAssertEqual(fused[0].score, 1.0 / 61 + 1.0 / 62, accuracy: 1e-9)
        XCTAssertEqual(fused[1].score, 1.0 / 61, accuracy: 1e-9)
        XCTAssertEqual(fused[3].score, 1.0 / 63, accuracy: 1e-9)
    }

    func testADocumentInBothListsRisesAboveOneInASingleList() {
        // «b» is second in both; «a» is first in one and absent from the other.
        let fused = fuse(["a", "b"], ["c", "b"])
        XCTAssertEqual(fused.first?.id, "b")
        XCTAssertEqual(fused.first?.placements.count, 2)
    }

    func testAnEmptyTextListDoesNotBreakTheMerge() {
        let fused = fuse(["a", "b", "c"], [])
        XCTAssertEqual(fused.map(\.id), ["a", "b", "c"])
        XCTAssertTrue(fused.allSatisfy { $0.sources == [.vector] })
    }

    func testTwoEmptyListsAreAnEmptyAnswerNotACrash() {
        XCTAssertTrue(fuse([], []).isEmpty)
    }

    func testWeightsMoveTheOrderPredictably() {
        // Equal weights: the two firsts tie, and the vector list wins by having
        // been seen first.
        XCTAssertEqual(fuse(["a"], ["b"]).map(\.id), ["a", "b"])
        // Text weighted three times: its first beats the vector's first.
        XCTAssertEqual(fuse(["a"], ["b"], textWeight: 3).map(\.id), ["b", "a"])
        // And back again.
        XCTAssertEqual(fuse(["a"], ["b"], vectorWeight: 3).map(\.id), ["a", "b"])
    }

    func testASmallerKMakesTheTopPositionsMatterMore() {
        // Both lists agree, so first beats second by exactly the gap between
        // 1/(k+1) and 1/(k+2). With k = 1 that gap is a third; with k = 1000 it
        // is a millionth — which is what «сглаживает кривую» means.
        let sharp = fuse(["a", "b"], ["a", "b"], k: 1)
        let flat = fuse(["a", "b"], ["a", "b"], k: 1000)
        XCTAssertEqual(sharp.map(\.id), ["a", "b"])
        XCTAssertEqual(flat.map(\.id), ["a", "b"])
        XCTAssertGreaterThan(sharp[0].score - sharp[1].score, flat[0].score - flat[1].score)
    }

    func testEveryPlacementIsRecordedForTheDiagnostics() {
        let fused = fuse(["x", "y"], ["y"])
        let y = fused.first { $0.id == "y" }
        XCTAssertEqual(y?.placements.map(\.source), [.vector, .text])
        XCTAssertEqual(y?.placements.map(\.position), [2, 1])
    }

    func testTheSameInputGivesTheSameOrderEveryTime() {
        let first = fuse(["a", "b", "c", "d"], ["d", "c", "b", "a"]).map(\.id)
        for _ in 0..<20 {
            XCTAssertEqual(fuse(["a", "b", "c", "d"], ["d", "c", "b", "a"]).map(\.id), first)
        }
    }
}

/// §E4 — the app ranks text candidates itself, because `get` does not.
final class TextRelevanceTests: XCTestCase {
    private func record(_ id: String, _ text: String, heading: String? = nil) -> DocumentRecord {
        var metadata: ChromaMetadata = [:]
        if let heading { metadata["heading_path"] = .string(heading) }
        return DocumentRecord(id: id, document: text, metadata: metadata.isEmpty ? nil : metadata)
    }

    func testMoreOccurrencesRankHigher() {
        let ranked = TextRelevance.ranked(
            [record("один", "ORA-01555 упомянут один раз"),
             record("три", "ORA-01555, снова ORA-01555 и ещё ORA-01555")],
            terms: ["ORA-01555"]
        )
        XCTAssertEqual(ranked.map(\.record.id), ["три", "один"])
    }

    func testATermInTheHeadingCountsForSeveralInTheBody() {
        let ranked = TextRelevance.ranked(
            [record("в тексте", "ORA-01555 ORA-01555", heading: "Прочее"),
             record("в заголовке", "ORA-01555", heading: "Ошибка ORA-01555")],
            terms: ["ORA-01555"]
        )
        XCTAssertEqual(
            ranked.first?.record.id, "в заголовке",
            "чанк, чей заголовок — это термин, о термине и есть"
        )
    }

    func testALongDocumentDoesNotWinMerelyForBeingLong() {
        let short = record("короткий", "ORA-01555 — ошибка отката")
        let long = record("длинный", String(repeating: "текст без термина. ", count: 400) + "ORA-01555 ORA-01555")
        let ranked = TextRelevance.ranked([short, long], terms: ["ORA-01555"])
        XCTAssertEqual(ranked.first?.record.id, "короткий")
    }

    func testADocumentTheFormulaCannotSeeIsDropped() {
        let ranked = TextRelevance.ranked([record("пусто", "ничего похожего")], terms: ["ORA-01555"])
        XCTAssertTrue(ranked.isEmpty, "позиция документа с нулевым весом ничего не значит")
    }

    func testTiesBreakByIdSoTheOrderIsTheSameEveryRun() {
        let ranked = TextRelevance.ranked(
            [record("б", "ORA-01555"), record("а", "ORA-01555")],
            terms: ["ORA-01555"]
        )
        XCTAssertEqual(ranked.map(\.record.id), ["а", "б"])
    }

    func testTheSearchIsCaseInsensitive() {
        XCTAssertEqual(TextRelevance.occurrences(of: "ora-01555", in: "ORA-01555 и Ora-01555"), 2)
    }

    func testOccurrencesOfAnEmptyTermAreZeroRatherThanInfinite() {
        XCTAssertEqual(TextRelevance.occurrences(of: "", in: "что угодно"), 0)
    }

    // MARK: - Terms

    func testTheWholeQueryIsOneTermByDefault() {
        XCTAssertEqual(
            TextRelevance.terms(in: "ошибка ORA-01555", splitIntoWords: false),
            ["ошибка ORA-01555"]
        )
    }

    func testSplittingDropsSingleLetters() {
        XCTAssertEqual(
            TextRelevance.terms(in: "ошибка в ORA-01555!", splitIntoWords: true),
            ["ошибка", "ORA", "01555"]
        )
    }

    func testAnEmptyQueryHasNoTerms() {
        XCTAssertTrue(TextRelevance.terms(in: "   ", splitIntoWords: false).isEmpty)
        XCTAssertTrue(TextRelevance.terms(in: "   ", splitIntoWords: true).isEmpty)
    }
}

/// §E4 — the stage as the pipeline runs it.
final class FusionStageTests: XCTestCase {
    private func hit(_ id: String, distance: Double?, source: CandidateSource) -> RetrievalHit {
        RetrievalHit(id: id, document: id, metadata: nil, distance: distance, sources: [source])
    }

    func testADocumentFoundByBothCarriesBothSources() {
        let result = RetrievalPipeline.fusing(
            vector: [hit("a", distance: 0.1, source: .vector), hit("b", distance: 0.2, source: .vector)],
            text: [hit("b", distance: nil, source: .text)],
            vectorWeight: 1, textWeight: 1, k: 60
        )
        let b = result.hits.first { $0.id == "b" }
        XCTAssertEqual(b?.sources, [.vector, .text])
        XCTAssertEqual(b?.distance, 0.2, "поле берётся у векторного списка — он принёс расстояние")
    }

    func testAResultOnlyTheTextSearchFoundSurvivesTheMerge() {
        let result = RetrievalPipeline.fusing(
            vector: [hit("a", distance: 0.1, source: .vector)],
            text: [hit("код-ошибки", distance: nil, source: .text)],
            vectorWeight: 1, textWeight: 1, k: 60
        )
        XCTAssertEqual(Set(result.hits.map(\.id)), ["a", "код-ошибки"])
    }

    func testTheNoteSaysHowManyCameFromWhere() {
        let result = RetrievalPipeline.fusing(
            vector: [hit("a", distance: 0.1, source: .vector), hit("b", distance: 0.2, source: .vector)],
            text: [hit("b", distance: nil, source: .text)],
            vectorWeight: 1, textWeight: 1, k: 60
        )
        XCTAssertEqual(result.note, "векторных 2, текстовых 1, в обоих списках 1, rrf_k 60")
    }

    /// E4 asks the diagnostics to say which source found a result and from what
    /// position — the one thing the merged order itself no longer shows.
    func testEachResultRemembersWhereEachSourceHadIt() {
        let result = RetrievalPipeline.fusing(
            vector: [hit("a", distance: 0.1, source: .vector), hit("b", distance: 0.2, source: .vector)],
            text: [hit("b", distance: nil, source: .text)],
            vectorWeight: 1, textWeight: 1, k: 60
        )
        let b = result.hits.first { $0.id == "b" }
        XCTAssertEqual(
            b?.placements,
            [
                SourcePlacement(source: .vector, position: 2),
                SourcePlacement(source: .text, position: 1),
            ]
        )
        XCTAssertEqual(b?.originNote, "векторный поиск, позиция 2 · текстовый поиск, позиция 1")
        XCTAssertEqual(result.hits.first { $0.id == "a" }?.originNote, "векторный поиск, позиция 1")
    }
}

/// §E4 — the profile switches.
final class HybridProfileTests: XCTestCase {
    func testANewProfileSearchesByVectorOnly() {
        let profile = SearchProfile(collectionName: "к")
        XCTAssertTrue(profile.vectorSearchEnabled)
        XCTAssertFalse(profile.textSearchEnabled)
        XCTAssertFalse(profile.requestedStages.contains(.fusion))
        // Nothing to merge and — on a one-level collection, where the pipeline
        // drops the hierarchy stages — nothing to discard either.
        XCTAssertEqual(profile.poolSize(nResults: 5, stages: []), 5)
    }

    func testTwoSourcesAskForAPoolAndAMerge() {
        var profile = SearchProfile(collectionName: "к")
        profile.textSearchEnabled = true
        XCTAssertTrue(profile.requestedStages.contains(.fusion))
        XCTAssertEqual(profile.poolSize(nResults: 5, stages: profile.requestedStages), 25)
    }

    /// «Только текстовый поиск»: sometimes what is wanted is literally a string.
    func testTextOnlyNeedsNoMerge() {
        var profile = SearchProfile(collectionName: "к")
        profile.vectorSearchEnabled = false
        profile.textSearchEnabled = true
        XCTAssertFalse(profile.requestedStages.contains(.fusion))
    }

    func testTheDefaultKIsTheOneTheSectionFixes() {
        XCTAssertEqual(SearchProfile(collectionName: "к").fusionK, 60, accuracy: 0.0001)
    }
}

/// A collection where the vector search is unhelpful for an exact string: the
/// error code appears in one document, and the ten the embedding likes best are
/// not it.
private actor ErrorCodeDatabase: RetrievalDatabase {
    private let records: [DocumentRecord]
    private let ranked: [QueryHit]

    init(records: [DocumentRecord], ranked: [QueryHit]) {
        self.records = records
        self.ranked = ranked
    }

    func query(
        collectionID: String, embedding: [Double], nResults: Int, filter: DocumentFilter?,
        includeEmbeddings: Bool
    ) async throws -> [QueryHit] {
        Array(ranked.prefix(nResults))
    }

    func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord] {
        records.filter { ids.contains($0.id) }
    }

    /// Honours `$contains` the way the server does — on the document text.
    func documents(
        collectionID: String, matching filter: DocumentFilter, limit: Int
    ) async throws -> [DocumentRecord] {
        let terms = filter.textConditions.map(\.text)
        return records.filter { record in
            guard let document = record.document else { return false }
            return terms.contains { document.contains($0) }
        }
    }

    func anyDocument(collectionID: String, matching filter: DocumentFilter) async throws -> Bool { false }
}

/// §E4, Definition of Done — the scenario the section was written for.
final class HybridSearchFindsTheErrorCodeTests: XCTestCase {
    private let code = "ORA-01555"

    private func database() -> ErrorCodeDatabase {
        // Ten documents about databases in general, and one that actually names
        // the code. The embedding ranks the ten first — which is exactly the
        // failure a purely semantic search has with identifiers.
        var records = (0..<10).map { index in
            DocumentRecord(
                id: "общий-\(index)",
                document: "Общие сведения об откате транзакций, часть \(index)",
                metadata: nil
            )
        }
        records.append(DocumentRecord(
            id: "нужный",
            document: "Ошибка \(code): snapshot too old — увеличьте undo_retention",
            metadata: nil
        ))
        let ranked = records.prefix(10).enumerated().map { index, record in
            QueryHit(id: record.id, document: record.document, metadata: nil, distance: 0.1 + Double(index) / 100)
        }
        return ErrorCodeDatabase(records: records, ranked: Array(ranked))
    }

    private func request() -> RetrievalRequest {
        RetrievalRequest(text: code, collectionID: "col", collectionName: "заметки", nResults: 10)
    }

    func testTheVectorSearchAloneDoesNotFindIt() async throws {
        let pipeline = RetrievalPipeline(database: database(), embed: { _ in [1, 0] })
        let outcome = try await pipeline.run(request(), profile: SearchProfile(collectionName: "заметки"))

        XCTAssertEqual(outcome.hits.count, 10)
        XCTAssertFalse(outcome.hits.map(\.id).contains("нужный"), "иначе сценарий DoD ничего не проверяет")
    }

    /// **Тот самый случай.** `$contains` у ChromaDB различает регистр, а человек
    /// набирает запрос строчными. Документ со словами «Astra Linux Орел» не
    /// находился по запросу «astra linux», и текстовый поиск выглядел
    /// неработающим.
    func testALowercaseQueryFindsACapitalisedName() async throws {
        let records = [
            DocumentRecord(id: "лицензия", document: "Программный комплекс Astra Linux Орел, лицензия бессрочная", metadata: nil),
            DocumentRecord(id: "прочее", document: "Общие сведения о поставке оборудования", metadata: nil),
        ]
        let database = ErrorCodeDatabase(
            records: records,
            ranked: [QueryHit(id: "прочее", document: records[1].document, metadata: nil, distance: 0.1)]
        )
        var profile = SearchProfile(collectionName: "заметки")
        profile.textSearchEnabled = true

        let outcome = try await RetrievalPipeline(database: database, embed: { _ in [1, 0] }).run(
            RetrievalRequest(text: "astra linux", collectionID: "col", collectionName: "заметки", nResults: 5),
            profile: profile
        )

        XCTAssertTrue(outcome.hits.map(\.id).contains("лицензия"), "написание не должно решать, найдётся документ или нет")
    }

    func testTheCaseVariantsAreTheOnesPeopleActuallyType() {
        let variants = TextRelevance.caseVariants(of: ["astra linux"])
        XCTAssertTrue(variants.contains("astra linux"))
        XCTAssertTrue(variants.contains("Astra Linux"), variants.joined(separator: ", "))
        // Заглавными — только короткое: «ASTRA LINUX» не нужен никому, а «IOPS» —
        // ровно то, что ищут набранным как «iops».
        XCTAssertFalse(variants.contains("ASTRA LINUX"))
        XCTAssertTrue(TextRelevance.caseVariants(of: ["iops"]).contains("IOPS"))
        // Ничего лишнего: уже правильное написание не удваивается.
        XCTAssertEqual(TextRelevance.caseVariants(of: ["IOPS"]).count, Set(TextRelevance.caseVariants(of: ["IOPS"])).count)
    }

    func testTheNumberOfVariantsIsBounded() {
        let many = (0..<40).map { "слово\($0)" }
        XCTAssertLessThanOrEqual(TextRelevance.caseVariants(of: many).count, 24)
    }

    func testWithTheTextSourceItIsFound() async throws {
        var profile = SearchProfile(collectionName: "заметки")
        profile.textSearchEnabled = true
        let pipeline = RetrievalPipeline(database: database(), embed: { _ in [1, 0] })

        let outcome = try await pipeline.run(request(), profile: profile)

        let found = try XCTUnwrap(outcome.hits.first { $0.id == "нужный" })
        XCTAssertTrue(found.sources.contains(.text))
        // And the diagnostics say where it came from, which is what makes the
        // difference explainable rather than magic.
        XCTAssertEqual(found.originNote, "текстовый поиск, позиция 1")
    }
}
