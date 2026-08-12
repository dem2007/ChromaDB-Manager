import XCTest
@testable import ChromaCore

/// A flat collection of files cut into numbered chunks.
private actor ChunkedDatabase: RetrievalDatabase {
    private let records: [DocumentRecord]
    private let ranked: [QueryHit]
    private(set) var fetchFilters: [DocumentFilter] = []

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

    func documents(
        collectionID: String, matching filter: DocumentFilter, limit: Int
    ) async throws -> [DocumentRecord] {
        fetchFilters.append(filter)
        // Interprets the clause the pipeline built, so the test checks the real
        // request rather than a convenient stand-in.
        guard let clause = try filter.whereClause() else { return [] }
        let branches = (clause["$or"] as? [[String: Any]]) ?? [clause]
        var wanted: Set<String> = []
        for branch in branches {
            let parts = (branch["$and"] as? [[String: Any]]) ?? [branch]
            var file: String?
            var indices: [Int] = []
            for part in parts {
                if let condition = part["source_file"] as? [String: Any], let value = condition["$eq"] as? String {
                    file = value
                }
                if let condition = part["chunk_index"] as? [String: Any], let values = condition["$in"] as? [Any] {
                    indices = values.compactMap { $0 as? Int }
                }
            }
            guard let file else { continue }
            for index in indices { wanted.insert("\(file)\u{0}\(index)") }
        }
        return records.filter { record in
            guard case .string(let file)? = record.metadata?["source_file"],
                  case .int(let index)? = record.metadata?["chunk_index"] else { return false }
            return wanted.contains("\(file)\u{0}\(index)")
        }
    }

    func anyDocument(collectionID: String, matching filter: DocumentFilter) async throws -> Bool {
        // Flat: everything is level 0.
        let clause = ((try? filter.whereClause()) ?? nil)?["chunk_level"] as? [String: Any] ?? [:]
        return clause["$eq"] != nil
    }

    func requests() -> Int { fetchFilters.count }
    func filters() -> [DocumentFilter] { fetchFilters }
}

/// §E2 — a result should not start in the middle of a thought.
final class ContextExpansionTests: XCTestCase {
    /// One file, chunks 0…5, and a second file whose numbering has a gap.
    private func corpus() -> [DocumentRecord] {
        var records: [DocumentRecord] = []
        for index in 0...5 {
            records.append(DocumentRecord(
                id: "a-\(index)", document: "часть \(index)",
                metadata: ["source_file": .string("книга.txt"), "chunk_index": .int(index), "chunk_level": .int(0)]
            ))
        }
        // 10, 11, then a hole at 12, then 13.
        for index in [10, 11, 13] {
            records.append(DocumentRecord(
                id: "b-\(index)", document: "кусок \(index)",
                metadata: ["source_file": .string("отчёт.txt"), "chunk_index": .int(index), "chunk_level": .int(0)]
            ))
        }
        return records
    }

    private func hit(_ id: String, distance: Double) -> QueryHit {
        let record = corpus().first { $0.id == id }!
        return QueryHit(id: id, document: record.document, metadata: record.metadata, distance: distance)
    }

    private func profile(window: Int?) -> SearchProfile {
        SearchProfile(collectionName: "книги", contextWindow: window)
    }

    private func run(
        _ ranked: [QueryHit], window: Int?, nResults: Int = 5
    ) async throws -> (RetrievalOutcome, ChunkedDatabase) {
        let database = ChunkedDatabase(records: corpus(), ranked: ranked)
        let outcome = try await RetrievalPipeline(database: database, embed: { _ in [1] })
            .run(
                RetrievalRequest(text: "з", collectionID: "col", collectionName: "книги", nResults: nResults),
                profile: profile(window: window)
            )
        return (outcome, database)
    }

    // MARK: - The middle, and the edges

    func testAChunkInTheMiddleGetsNeighboursOnBothSides() async throws {
        let (outcome, _) = try await run([hit("a-3", distance: 0.1)], window: 1)
        let context = outcome.hits[0].context
        XCTAssertEqual(context.map(\.id), ["a-2", "a-4"])
        XCTAssertTrue(context.allSatisfy { $0.role == .context && $0.contextKind == .neighbour })
    }

    func testTheFirstChunkExpandsOnlyForward() async throws {
        let (outcome, _) = try await run([hit("a-0", distance: 0.1)], window: 2)
        XCTAssertEqual(outcome.hits[0].context.map(\.id), ["a-1", "a-2"])
    }

    func testTheLastChunkExpandsOnlyBackward() async throws {
        let (outcome, _) = try await run([hit("a-5", distance: 0.1)], window: 2)
        XCTAssertEqual(outcome.hits[0].context.map(\.id), ["a-3", "a-4"])
    }

    func testTheWindowIsHonouredOnBothSides() async throws {
        let (outcome, _) = try await run([hit("a-3", distance: 0.1)], window: 2)
        XCTAssertEqual(outcome.hits[0].context.map(\.id), ["a-1", "a-2", "a-4", "a-5"])
    }

    // MARK: - A gap ends the expansion

    func testAHoleInTheNumberingStopsExpansionInThatDirection() async throws {
        // 11 has 10 behind it and a hole at 12 in front.
        let (outcome, _) = try await run([hit("b-11", distance: 0.1)], window: 2)
        XCTAssertEqual(
            outcome.hits[0].context.map(\.id), ["b-10"],
            "перепрыгнув дыру, мы склеили бы два куска текста, которые никогда не соприкасались"
        )
    }

    // MARK: - One request per page

    func testNeighboursForTheWholePageComeInOneRequest() async throws {
        let (outcome, database) = try await run(
            [hit("a-1", distance: 0.1), hit("a-4", distance: 0.2), hit("b-10", distance: 0.3)],
            window: 1
        )
        let requests = await database.requests()
        XCTAssertEqual(requests, 1, "по вызову на результат — это одиннадцать запросов на страницу из десяти")
        XCTAssertEqual(outcome.hits.count, 3)
        XCTAssertTrue(outcome.hits.allSatisfy { !$0.context.isEmpty })
    }

    func testTheRequestAsksAboutBothFilesAtOnce() async throws {
        let (_, database) = try await run(
            [hit("a-1", distance: 0.1), hit("b-10", distance: 0.3)], window: 1
        )
        let filters = await database.filters()
        let clause = try XCTUnwrap(try XCTUnwrap(filters.first).whereClause())
        let branches = try XCTUnwrap(clause["$or"] as? [[String: Any]])
        XCTAssertEqual(branches.count, 2)
    }

    func testAChunkAlreadyOnThePageIsNotAskedForAgain() async throws {
        let (_, database) = try await run(
            [hit("a-1", distance: 0.1), hit("a-2", distance: 0.2)], window: 1
        )
        let filters = await database.filters()
        let clause = try XCTUnwrap(try XCTUnwrap(filters.first).whereClause())
        let indices = ((clause["$and"] as? [[String: Any]]) ?? [])
            .compactMap { ($0["chunk_index"] as? [String: Any])?["$in"] as? [Any] }
            .flatMap { $0.compactMap { $0 as? Int } }
        XCTAssertEqual(Set(indices), [0, 3], "1 и 2 уже на странице — просить их незачем")
    }

    // MARK: - Ranking and the switch

    func testTheDistanceStaysTheMatchedChunks() async throws {
        let (outcome, _) = try await run([hit("a-3", distance: 0.42)], window: 1)
        XCTAssertEqual(outcome.hits[0].distance ?? 0, 0.42, accuracy: 0.0001)
        XCTAssertEqual(outcome.hits[0].document, "часть 3", "текст результата — найденный чанк, соседи приложены")
    }

    func testZeroMeansOff() async throws {
        let (outcome, database) = try await run([hit("a-3", distance: 0.1)], window: 0)
        XCTAssertTrue(outcome.hits[0].context.isEmpty)
        let requests = await database.requests()
        XCTAssertEqual(requests, 0)
        let report = outcome.diagnostics.stages.first { $0.stage == .context }
        XCTAssertEqual(report?.ran, false)
    }

    func testContextRowsDoNotCountAgainstTheRequestedNumber() async throws {
        let (outcome, _) = try await run(
            [hit("a-1", distance: 0.1), hit("a-4", distance: 0.2)], window: 1, nResults: 2
        )
        XCTAssertEqual(outcome.hits.count, 2)
        XCTAssertTrue(outcome.hits.allSatisfy { $0.role == .match })
    }

    func testTheDiagnosticsSayHowManyWereAttachedAndInHowManyRequests() async throws {
        let (outcome, _) = try await run([hit("a-3", distance: 0.1)], window: 1)
        let report = outcome.diagnostics.stages.first { $0.stage == .context }
        XCTAssertEqual(report?.ran, true)
        XCTAssertEqual(report?.note, "присоединено соседних чанков: 2, запросов: 1")
    }
}

/// §E2 — what the window is when nobody chose one.
final class ContextWindowDefaultTests: XCTestCase {
    /// 1 and the Definition of Done require an untuned profile to behave
    /// exactly like the search of stage 2. Attaching neighbours by default
    /// would change every result on every collection nobody has configured.
    func testNobodyChoseMeansOff() {
        XCTAssertEqual(SearchProfile(collectionName: "к").resolvedContextWindow, 0)
        XCTAssertFalse(SearchProfile(collectionName: "к").requestedStages.contains(.context))
    }

    func testAChosenWindowIsWhatRuns() {
        var profile = SearchProfile(collectionName: "к")
        profile.contextWindow = 2
        XCTAssertEqual(profile.resolvedContextWindow, 2)
        XCTAssertTrue(profile.requestedStages.contains(.context))
    }

    /// «Ноль, потому что я так решил» must stay distinguishable from «никто не
    /// решал» — the two look the same on screen and mean different things when
    /// the defaults change.
    func testAnExplicitZeroIsNotTheSameAsUnset() {
        var profile = SearchProfile(collectionName: "к")
        profile.contextWindow = 0
        XCTAssertNotNil(profile.contextWindow)
        XCTAssertEqual(profile.resolvedContextWindow, 0)
    }

    func testTheWindowIsClampedToWhatTheSectionAllows() {
        var profile = SearchProfile(collectionName: "к")
        profile.contextWindow = 99
        XCTAssertEqual(profile.resolvedContextWindow, SearchProfile.maximumContextWindow)
        profile.contextWindow = -5
        XCTAssertEqual(profile.resolvedContextWindow, 0)
    }

    func testTurningItOnOffersOneNeighbourEachSide() {
        XCTAssertEqual(SearchProfile.suggestedContextWindow, 1)
    }
}

/// §E2 — a neighbour that is itself a result is neither duplicated nor treated
/// as a hole in the text.
extension ContextExpansionTests {
    func testANeighbourAlreadyOnThePageIsSkippedWithoutEndingTheWalk() async throws {
        // 2 and 4 are results; with a window of 2, result 2 should reach 0 past
        // its neighbour 1... and past 3, which is not a result.
        let (outcome, _) = try await run(
            [hit("a-2", distance: 0.1), hit("a-4", distance: 0.2)], window: 2
        )
        let first = outcome.hits[0].context.map(\.id)
        XCTAssertEqual(first, ["a-0", "a-1", "a-3"], "a-4 — сам результат: не дублируется и не обрывает обход")
        let second = outcome.hits[1].context.map(\.id)
        XCTAssertEqual(second, ["a-3", "a-5"], "a-2 — результат: пропущен, обход продолжился")
    }

    func testAnUnfetchableGapStillEndsTheWalk() async throws {
        // Nothing is at 12: the hole is real, not «оно уже на странице».
        let (outcome, _) = try await run([hit("b-13", distance: 0.1)], window: 3)
        XCTAssertTrue(outcome.hits[0].context.isEmpty)
    }
}
