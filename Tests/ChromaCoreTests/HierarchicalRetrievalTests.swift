import XCTest
@testable import ChromaCore

/// A collection with a two-level structure the test dictates.
private actor HierarchicalDatabase: RetrievalDatabase {
    /// Documents by id, with their metadata.
    private var records: [DocumentRecord]
    /// What `query` answers, in order.
    private let ranked: [QueryHit]
    private(set) var levelFilters: [DocumentFilter?] = []
    private(set) var fetchCalls: Int = 0
    private(set) var fetchedIDs: [[String]] = []
    private let pretendFlat: Bool

    init(records: [DocumentRecord], ranked: [QueryHit], pretendFlat: Bool = false) {
        self.records = records
        self.ranked = ranked
        self.pretendFlat = pretendFlat
    }

    func query(
        collectionID: String, embedding: [Double], nResults: Int, filter: DocumentFilter?,
        includeEmbeddings: Bool
    ) async throws -> [QueryHit] {
        levelFilters.append(filter)
        return Array(ranked.prefix(nResults))
    }

    func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord] {
        fetchCalls += 1
        fetchedIDs.append(ids.sorted())
        return records.filter { ids.contains($0.id) }
    }

    /// E2 does not apply to these tests: no neighbours exist to attach.
    func documents(
        collectionID: String, matching filter: DocumentFilter, limit: Int
    ) async throws -> [DocumentRecord] { [] }

    func anyDocument(collectionID: String, matching filter: DocumentFilter) async throws -> Bool {
        guard !pretendFlat else {
            // A flat collection: everything is level 0, nothing above it.
            let clause = (try? filter.whereClause()) ?? nil
            let level = (clause?["chunk_level"] as? [String: Any])
            return level?["$eq"] != nil
        }
        return true
    }

    func filters() -> [DocumentFilter?] { levelFilters }
    func calls() -> Int { fetchCalls }
    func ids() -> [[String]] { fetchedIDs }
}

/// §E1 — children for the hit, parents for the context.
final class HierarchicalRetrievalTests: XCTestCase {
    private func child(_ id: String, parent: String, text: String, distance: Double) -> (DocumentRecord, QueryHit) {
        let metadata: ChromaMetadata = ["chunk_level": .int(0), "parent_chunk_id": .string(parent)]
        return (
            DocumentRecord(id: id, document: text, metadata: metadata),
            QueryHit(id: id, document: text, metadata: metadata, distance: distance)
        )
    }

    private func parent(_ id: String, text: String) -> DocumentRecord {
        DocumentRecord(id: id, document: text, metadata: ["chunk_level": .int(1)])
    }

    /// Three children of one parent plus one child of another.
    private func corpus() -> (records: [DocumentRecord], ranked: [QueryHit]) {
        let a1 = child("a1", parent: "P1", text: "первый фрагмент раздела", distance: 0.10)
        let a2 = child("a2", parent: "P1", text: "второй фрагмент раздела", distance: 0.15)
        let a3 = child("a3", parent: "P1", text: "третий фрагмент раздела", distance: 0.05)
        let b1 = child("b1", parent: "P2", text: "фрагмент другого раздела", distance: 0.20)
        return (
            [parent("P1", text: "весь первый раздел целиком"),
             parent("P2", text: "весь второй раздел целиком"),
             a1.0, a2.0, a3.0, b1.0],
            [a1.1, a2.1, a3.1, b1.1]
        )
    }

    private func pipeline(_ database: HierarchicalDatabase) -> RetrievalPipeline {
        RetrievalPipeline(database: database, embed: { _ in [1, 0, 0] })
    }

    private func request(nResults: Int = 5) -> RetrievalRequest {
        RetrievalRequest(text: "запрос", collectionID: "col", collectionName: "книга", nResults: nResults)
    }

    // MARK: - Collapsing

    func testThreeChildrenOfOneParentAreOneResult() async throws {
        let corpus = corpus()
        let database = HierarchicalDatabase(records: corpus.records, ranked: corpus.ranked)
        let outcome = try await pipeline(database)
            .run(request(), profile: SearchProfile(collectionName: "книга"))

        XCTAssertEqual(outcome.hits.count, 2, "три дочерних чанка одного родителя должны дать один результат")
        XCTAssertEqual(outcome.hits[0].collapsed, 2, "свёрнутые совпадения должны быть посчитаны")
        XCTAssertEqual(outcome.hits[1].collapsed, 0)
        XCTAssertEqual(outcome.hits[0].collapsedNote, "ещё 2 совпадения в этом разделе")
    }

    func testTheCollapsedResultKeepsTheBestDistance() async throws {
        let corpus = corpus()
        let database = HierarchicalDatabase(records: corpus.records, ranked: corpus.ranked)
        let outcome = try await pipeline(database)
            .run(request(), profile: SearchProfile(collectionName: "книга"))

        // Best of 0.10, 0.15 and 0.05 — not the one that happened to come first.
        XCTAssertEqual(outcome.hits[0].distance ?? 0, 0.05, accuracy: 0.0001)
    }

    func testCollapsingKeepsTheOrderTheCollectionReturned() {
        let hits = [
            RetrievalHit(id: "b", document: nil, metadata: ["parent_chunk_id": .string("P2")], distance: 0.1),
            RetrievalHit(id: "a", document: nil, metadata: ["parent_chunk_id": .string("P1")], distance: 0.2),
            RetrievalHit(id: "a2", document: nil, metadata: ["parent_chunk_id": .string("P1")], distance: 0.3),
        ]
        XCTAssertEqual(RetrievalPipeline.collapsingByParent(hits).map(\.id), ["b", "a"])
    }

    func testAChunkWithoutAParentPassesThroughUntouched() {
        let hits = [
            RetrievalHit(id: "lone", document: nil, metadata: ["chunk_level": .int(0)], distance: 0.1),
            RetrievalHit(id: "other", document: nil, metadata: nil, distance: 0.2),
        ]
        let result = RetrievalPipeline.collapsingByParent(hits)
        XCTAssertEqual(result.map(\.id), ["lone", "other"], "чанки без родителя не должны сливаться друг с другом")
        XCTAssertTrue(result.allSatisfy { $0.collapsed == 0 })
    }

    // MARK: - Promotion

    func testByDefaultTheParentIsReturnedInsteadOfTheChild() async throws {
        let corpus = corpus()
        let database = HierarchicalDatabase(records: corpus.records, ranked: corpus.ranked)
        let outcome = try await pipeline(database)
            .run(request(), profile: SearchProfile(collectionName: "книга"))

        XCTAssertEqual(outcome.hits[0].document, "весь первый раздел целиком")
        // The distance stays the child's: it is what was matched.
        XCTAssertEqual(outcome.hits[0].distance ?? 0, 0.05, accuracy: 0.0001)
    }

    func testBothReturnsTheChildAndTheParentInDifferentRoles() async throws {
        let corpus = corpus()
        let database = HierarchicalDatabase(records: corpus.records, ranked: corpus.ranked)
        var profile = SearchProfile(collectionName: "книга")
        profile.promotion = .both

        let outcome = try await pipeline(database).run(request(), profile: profile)

        let first = outcome.hits[0]
        XCTAssertEqual(first.role, .match)
        XCTAssertEqual(first.document, "первый фрагмент раздела", "найденным остаётся дочерний чанк")
        XCTAssertEqual(first.context.count, 1)
        XCTAssertEqual(first.context[0].role, .context)
        XCTAssertEqual(first.context[0].document, "весь первый раздел целиком")
    }

    func testContextDoesNotPushOutAResult() async throws {
        let corpus = corpus()
        let database = HierarchicalDatabase(records: corpus.records, ranked: corpus.ranked)
        var profile = SearchProfile(collectionName: "книга")
        profile.promotion = .both

        let outcome = try await pipeline(database).run(request(nResults: 2), profile: profile)

        XCTAssertEqual(outcome.hits.count, 2, "родитель как контекст не должен занимать место результата")
        XCTAssertTrue(outcome.hits.allSatisfy { $0.role == .match })
    }

    func testChildModeLeavesTheChunkAlone() async throws {
        let corpus = corpus()
        let database = HierarchicalDatabase(records: corpus.records, ranked: corpus.ranked)
        var profile = SearchProfile(collectionName: "книга")
        profile.promotion = .child

        let outcome = try await pipeline(database).run(request(), profile: profile)

        XCTAssertEqual(outcome.hits[0].document, "первый фрагмент раздела")
        XCTAssertTrue(outcome.hits[0].context.isEmpty)
        let calls = await database.calls()
        XCTAssertEqual(calls, 0, "без подъёма родителей запрашивать незачем")
    }

    func testParentsAreFetchedInOneRequestForThePage() async throws {
        let corpus = corpus()
        let database = HierarchicalDatabase(records: corpus.records, ranked: corpus.ranked)
        _ = try await pipeline(database).run(request(), profile: SearchProfile(collectionName: "книга"))

        let calls = await database.calls()
        let ids = await database.ids()
        XCTAssertEqual(calls, 1, "один запрос на страницу, а не по одному на результат")
        XCTAssertEqual(ids.first, ["P1", "P2"])
    }

    func testAMissingParentLeavesTheChildAndSaysSo() async throws {
        let corpus = corpus()
        // The parents are gone — a re-index that rewrote one level only.
        let database = HierarchicalDatabase(
            records: corpus.records.filter { $0.id.hasPrefix("a") || $0.id.hasPrefix("b") },
            ranked: corpus.ranked
        )
        let outcome = try await pipeline(database).run(request(), profile: SearchProfile(collectionName: "книга"))

        XCTAssertEqual(outcome.hits[0].document, "первый фрагмент раздела")
        let promote = outcome.diagnostics.stages.first { $0.stage == .promote }
        XCTAssertEqual(promote?.note, "родительские чанки не найдены в коллекции — возвращены дочерние")
    }

    // MARK: - The level filter (stage 1)

    func testTheSearchIsNarrowedToChildrenByDefault() async throws {
        let corpus = corpus()
        let database = HierarchicalDatabase(records: corpus.records, ranked: corpus.ranked)
        _ = try await pipeline(database).run(request(), profile: SearchProfile(collectionName: "книга"))

        let filters = await database.filters()
        let clause = try XCTUnwrap(filters.first ?? nil).whereClause()
        XCTAssertEqual((try clause?["chunk_level"] as? [String: Any])?["$eq"] as? Int, 0)
    }

    func testAManualJSONFilterIsLeftExactlyAsWritten() async throws {
        let corpus = corpus()
        let database = HierarchicalDatabase(records: corpus.records, ranked: corpus.ranked)
        var filter = DocumentFilter()
        filter.rawWhereJSON = #"{"page_number": {"$gt": 3}}"#

        let outcome = try await pipeline(database).run(
            RetrievalRequest(text: "з", collectionID: "col", collectionName: "книга", filter: filter),
            profile: SearchProfile(collectionName: "книга")
        )

        let filters = await database.filters()
        XCTAssertEqual((filters.first ?? nil)?.rawWhereJSON, filter.rawWhereJSON)
        let candidates = outcome.diagnostics.stages.first { $0.stage == .candidates }
        XCTAssertEqual(
            candidates?.note?.contains("фильтр задан вручную в JSON"), true,
            "молчаливое дополнение чужого JSON нарушило бы правило 2 Приложения 5"
        )
    }

    func testTheUsersOwnConditionsSurviveAlongsideTheLevel() async throws {
        let corpus = corpus()
        let database = HierarchicalDatabase(records: corpus.records, ranked: corpus.ranked)
        let filter = DocumentFilter(conditions: [
            MetadataCondition(field: "page_number", op: .greater, value: "3"),
        ])

        _ = try await pipeline(database).run(
            RetrievalRequest(text: "з", collectionID: "col", collectionName: "книга", filter: filter),
            profile: SearchProfile(collectionName: "книга")
        )

        let filters = await database.filters()
        let sent = try XCTUnwrap(filters.first ?? nil)
        let clause = try XCTUnwrap(sent.whereClause())
        let parts = try XCTUnwrap(clause["$and"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts.contains { $0["page_number"] != nil })
        XCTAssertTrue(parts.contains { $0["chunk_level"] != nil })
    }

    // MARK: - A collection with one level

    func testAFlatCollectionRunsNeitherStageAndIsNotFiltered() async throws {
        let hits = (0..<4).map {
            QueryHit(id: "d\($0)", document: "т\($0)", metadata: ["chunk_level": .int(0)], distance: Double($0) / 10)
        }
        let database = HierarchicalDatabase(records: [], ranked: hits, pretendFlat: true)

        let outcome = try await pipeline(database)
            .run(request(nResults: 4), profile: SearchProfile(collectionName: "заметки"))

        XCTAssertEqual(outcome.hits.map(\.id), ["d0", "d1", "d2", "d3"])
        let ran = outcome.diagnostics.stages.filter(\.ran).map(\.stage)
        XCTAssertEqual(ran, [.candidates, .truncate])
        for stage in [RetrievalStage.collapse, .promote] {
            let report = outcome.diagnostics.stages.first { $0.stage == stage }
            XCTAssertEqual(report?.note, "коллекция нарезана одним уровнем")
        }
        // No condition on chunk_level: a document written by another client may
        // not have the field at all, and filtering on it would drop it.
        let filters = await database.filters()
        XCTAssertNil(filters.first ?? nil)
    }

    func testAFlatCollectionAsksForNoLargerPool() async throws {
        let hits = (0..<40).map {
            QueryHit(id: "d\($0)", document: "т", metadata: nil, distance: Double($0) / 100)
        }
        let database = HierarchicalDatabase(records: [], ranked: hits, pretendFlat: true)
        let counting = CountingDatabase(inner: database)

        _ = try await RetrievalPipeline(database: counting, embed: { _ in [1] })
            .run(request(nResults: 5), profile: SearchProfile(collectionName: "заметки"))

        let asked = await counting.asked()
        XCTAssertEqual(asked, [5], "иерархические стадии на плоской коллекции не должны стоить даже пула")
    }
}

/// Records what `nResults` the pipeline asked for, delegating everything else.
private actor CountingDatabase: RetrievalDatabase {
    private let inner: any RetrievalDatabase
    private var requested: [Int] = []

    init(inner: any RetrievalDatabase) { self.inner = inner }

    func query(
        collectionID: String, embedding: [Double], nResults: Int, filter: DocumentFilter?,
        includeEmbeddings: Bool
    ) async throws -> [QueryHit] {
        requested.append(nResults)
        return try await inner.query(
            collectionID: collectionID, embedding: embedding, nResults: nResults,
            filter: filter, includeEmbeddings: includeEmbeddings
        )
    }

    func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord] {
        try await inner.documents(collectionID: collectionID, ids: ids)
    }

    func documents(
        collectionID: String, matching filter: DocumentFilter, limit: Int
    ) async throws -> [DocumentRecord] {
        try await inner.documents(collectionID: collectionID, matching: filter, limit: limit)
    }

    func anyDocument(collectionID: String, matching filter: DocumentFilter) async throws -> Bool {
        try await inner.anyDocument(collectionID: collectionID, matching: filter)
    }

    func asked() -> [Int] { requested }
}

/// §E1 — the shape of a collection is established, not sampled.
final class CollectionShapeCacheTests: XCTestCase {
    private actor ProbeDatabase: RetrievalDatabase {
        private(set) var probes: [[String: Any]] = []
        private let hasParents: Bool
        private let hasChildren: Bool
        private let failing: Bool

        init(hasParents: Bool, hasChildren: Bool, failing: Bool = false) {
            self.hasParents = hasParents
            self.hasChildren = hasChildren
            self.failing = failing
        }

        func query(collectionID: String, embedding: [Double], nResults: Int, filter: DocumentFilter?, includeEmbeddings: Bool) async throws -> [QueryHit] { [] }
        func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord] { [] }
        func documents(collectionID: String, matching filter: DocumentFilter, limit: Int) async throws -> [DocumentRecord] { [] }

        func anyDocument(collectionID: String, matching filter: DocumentFilter) async throws -> Bool {
            if failing { throw ChromaError.unreachable(endpoint: "localhost", reason: "нет связи") }
            let clause = ((try? filter.whereClause()) ?? nil)?["chunk_level"] as? [String: Any] ?? [:]
            probes.append(clause)
            return clause["$gt"] != nil ? hasParents : hasChildren
        }

        func probeCount() -> Int { probes.count }
        func operators() -> [String] { probes.flatMap { $0.keys }.sorted() }
    }

    func testACollectionWithBothLevelsIsHierarchical() async {
        let database = ProbeDatabase(hasParents: true, hasChildren: true)
        let shape = await CollectionShapeCache().shape(of: "id", collectionName: "книга", database: database)
        XCTAssertEqual(shape, .hierarchical)
    }

    /// The case the specification's single probe would get wrong: `levels: 1`
    /// produces parents and no children at all.
    func testParentsWithoutChildrenAreNotAHierarchy() async {
        let database = ProbeDatabase(hasParents: true, hasChildren: false)
        let shape = await CollectionShapeCache().shape(of: "id", collectionName: "книга", database: database)
        XCTAssertEqual(shape, .flat, "иначе поиск по «дочерним» не нашёл бы ничего")
    }

    func testAFlatCollectionIsFlat() async {
        let database = ProbeDatabase(hasParents: false, hasChildren: true)
        let shape = await CollectionShapeCache().shape(of: "id", collectionName: "заметки", database: database)
        XCTAssertEqual(shape, .flat)
    }

    func testTheAnswerIsAskedOncePerCollection() async {
        let database = ProbeDatabase(hasParents: true, hasChildren: true)
        let cache = CollectionShapeCache()
        for _ in 0..<5 {
            _ = await cache.shape(of: "id", collectionName: "книга", database: database)
        }
        let probes = await database.probeCount()
        XCTAssertEqual(probes, 2, "две точечные проверки на коллекцию, а не на запрос")
    }

    func testForgettingMakesItAskAgain() async {
        let database = ProbeDatabase(hasParents: true, hasChildren: true)
        let cache = CollectionShapeCache()
        _ = await cache.shape(of: "id", collectionName: "книга", database: database)
        await cache.forget(collectionID: "id")
        _ = await cache.shape(of: "id", collectionName: "книга", database: database)
        let probes = await database.probeCount()
        XCTAssertEqual(probes, 4)
    }

    func testAFailedProbeIsFlatAndIsNotRemembered() async {
        let database = ProbeDatabase(hasParents: true, hasChildren: true, failing: true)
        let cache = CollectionShapeCache()
        let shape = await cache.shape(of: "id", collectionName: "книга", database: database)
        XCTAssertEqual(shape, .flat, "неизвестная форма не должна уметь ухудшить поиск")

        let working = ProbeDatabase(hasParents: true, hasChildren: true)
        let second = await cache.shape(of: "id", collectionName: "книга", database: working)
        XCTAssertEqual(second, .hierarchical, "неудачная проверка не должна закрепляться как ответ")
    }

    func testTheProbesAskAboutLevelsRatherThanSampling() async {
        let database = ProbeDatabase(hasParents: true, hasChildren: true)
        _ = await CollectionShapeCache().shape(of: "id", collectionName: "книга", database: database)
        let operators = await database.operators()
        XCTAssertEqual(operators, ["$eq", "$gt"])
    }
}

/// §E1 — a promoted result must not show one document's id beside another's text.
extension HierarchicalRetrievalTests {
    func testAPromotedResultIsTheParentIdentityAndSaysWhatMatched() async throws {
        let corpus = corpus()
        let database = HierarchicalDatabase(records: corpus.records, ranked: corpus.ranked)
        let outcome = try await RetrievalPipeline(database: database, embed: { _ in [1] })
            .run(
                RetrievalRequest(text: "з", collectionID: "col", collectionName: "книга"),
                profile: SearchProfile(collectionName: "книга")
            )

        let first = outcome.hits[0]
        XCTAssertEqual(first.id, "P1", "карточка показывает текст родителя — значит и id должен быть его")
        XCTAssertEqual(first.matchedChunkID, "a1", "какой чанк совпал, должно остаться видно")
        XCTAssertEqual(first.metadata?["chunk_level"], .int(1))
    }

    func testInBothModeTheResultStaysTheChild() async throws {
        let corpus = corpus()
        let database = HierarchicalDatabase(records: corpus.records, ranked: corpus.ranked)
        var profile = SearchProfile(collectionName: "книга")
        profile.promotion = .both

        let outcome = try await RetrievalPipeline(database: database, embed: { _ in [1] })
            .run(RetrievalRequest(text: "з", collectionID: "col", collectionName: "книга"), profile: profile)

        XCTAssertEqual(outcome.hits[0].id, "a1")
        XCTAssertNil(outcome.hits[0].matchedChunkID, "подменять нечего — найденное и показанное совпадают")
        XCTAssertEqual(outcome.hits[0].context.first?.id, "P1")
    }
}

/// Счёт по-русски: 1 совпадение, 2 совпадения, 5 совпадений.
final class CollapsedNoteTests: XCTestCase {
    private func note(_ count: Int) -> String? {
        RetrievalHit(id: "x", document: nil, metadata: nil, distance: nil, collapsed: count).collapsedNote
    }

    func testTheWordAgreesWithTheNumber() {
        XCTAssertEqual(note(1), "ещё 1 совпадение в этом разделе")
        XCTAssertEqual(note(2), "ещё 2 совпадения в этом разделе")
        XCTAssertEqual(note(5), "ещё 5 совпадений в этом разделе")
        XCTAssertEqual(note(11), "ещё 11 совпадений в этом разделе")
        XCTAssertEqual(note(21), "ещё 21 совпадение в этом разделе")
        XCTAssertEqual(note(112), "ещё 112 совпадений в этом разделе")
    }

    func testNothingCollapsedSaysNothing() {
        XCTAssertNil(note(0))
    }
}
