import XCTest
@testable import ChromaCore

/// Плоская коллекция, где векторный поиск отдаёт кандидатов по порядку.
private actor FlatDatabase: RetrievalDatabase {
    private let ranked: [QueryHit]
    private let records: [DocumentRecord]
    private(set) var requestedSizes: [Int] = []

    init(count: Int, marked: Set<String> = []) {
        records = (0..<count).map { index in
            let id = "d-\(index)"
            var metadata: ChromaMetadata = [:]
            if marked.contains(id) {
                metadata = DocumentMarks(mark: .pinned).applied(to: nil)
            }
            return DocumentRecord(
                id: id,
                document: "ГЕОП: аренда виртуальных процессоров, часть \(index)",
                metadata: metadata.isEmpty ? nil : metadata
            )
        }
        ranked = records.enumerated().map { index, record in
            QueryHit(
                id: record.id, document: record.document,
                metadata: record.metadata, distance: 0.1 + Double(index) / 100
            )
        }
    }

    func query(
        collectionID: String, embedding: [Double], nResults: Int, filter: DocumentFilter?,
        includeEmbeddings: Bool
    ) async throws -> [QueryHit] {
        requestedSizes.append(nResults)
        return Array(ranked.prefix(nResults))
    }
    func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord] {
        records.filter { ids.contains($0.id) }
    }
    /// Отвечает на запрос по метаданным так же, как сервер: по условиям
    /// равенства. Нужен ради добора закреплённых.
    func documents(collectionID: String, matching filter: DocumentFilter, limit: Int) async throws -> [DocumentRecord] {
        let conditions = filter.conditions
        guard !conditions.isEmpty else { return [] }
        return records.filter { record in
            conditions.allSatisfy { condition in
                guard case .string(let value)? = record.metadata?[condition.field] else { return false }
                return value == condition.value
            }
        }
    }
    func anyDocument(collectionID: String, matching filter: DocumentFilter) async throws -> Bool {
        try await !documents(collectionID: collectionID, matching: filter, limit: 1).isEmpty
    }
    func sizes() -> [Int] { requestedSizes }
}

/// Чем «умный поиск» отличается от обычного на плоской коллекции.
///
/// Живая жалоба: «настройки по умолчанию выдают одинаковые результаты».
/// Так и есть, и это не случайность — заводской профиль включает свёртку
/// по родителю, подъём к разделу и пометки; первых двух у коллекции,
/// нарезанной одним уровнем, не бывает, а третья без единой пометки ничего
/// не двигает. Приложение обязано сказать об этом вслух, а не оставлять
/// человека думать, что переключатель сломан.
final class SmartSearchDifferenceTests: XCTestCase {
    private func request(_ n: Int = 5) -> RetrievalRequest {
        RetrievalRequest(
            text: "ГЕОП аренда виртуальных процессоров",
            collectionID: "col", collectionName: "base_adaptive", nResults: n
        )
    }

    /// Тот же список и тот же запрос к базе — до последнего идентификатора.
    func testTheDefaultProfileMatchesPlainSearchOnAFlatCollection() async throws {
        let database = FlatDatabase(count: 40)
        let pipeline = RetrievalPipeline(database: database, embed: { _ in [1, 0] })
        let smart = SearchProfile(collectionName: "base_adaptive")
        let plain = SearchProfile.plain(collectionName: "base_adaptive", name: smart.name)

        let withProfile = try await pipeline.run(request(), profile: smart)
        let withoutProfile = try await pipeline.run(request(), profile: plain)

        XCTAssertEqual(withProfile.hits.map(\.id), withoutProfile.hits.map(\.id))
        // И база спрошена одинаково: пул не расширяется под пометки —
        // закреплённое добирается отдельным запросом, а не за счёт всех
        // поисков подряд.
        let sizes = await database.sizes()
        XCTAssertEqual(sizes, [5, 5])
    }

    /// …и приложение это признаёт.
    func testTheRunSaysTheProfileChangedNothing() async throws {
        let pipeline = RetrievalPipeline(database: FlatDatabase(count: 40), embed: { _ in [1, 0] })
        let outcome = try await pipeline.run(request(), profile: SearchProfile(collectionName: "base_adaptive"))
        XCTAssertTrue(outcome.diagnostics.unchangedByProfile)
    }

    /// Пометка человека — разница настоящая, и признания «ничего не изменилось»
    /// в этом случае быть не должно.
    func testAPinnedDocumentIsARealDifference() async throws {
        let database = FlatDatabase(count: 10, marked: ["d-7"])
        let pipeline = RetrievalPipeline(database: database, embed: { _ in [1, 0] })

        let smart = try await pipeline.run(request(), profile: SearchProfile(collectionName: "base_adaptive"))
        let plain = try await pipeline.run(
            request(),
            profile: SearchProfile.plain(collectionName: "base_adaptive", name: "По умолчанию")
        )

        XCTAssertEqual(smart.hits.first?.id, "d-7", "закреплённое обязано подняться наверх")
        XCTAssertNotEqual(smart.hits.map(\.id), plain.hits.map(\.id))
        XCTAssertFalse(smart.diagnostics.unchangedByProfile)
    }

    /// Включённый текстовый источник — тоже настоящая разница: стадия слияния
    /// работает, и признания «ничего не изменилось» быть не должно.
    func testTheTextSourceIsARealDifference() async throws {
        var profile = SearchProfile(collectionName: "base_adaptive")
        profile.textSearchEnabled = true
        let pipeline = RetrievalPipeline(database: FlatDatabase(count: 10), embed: { _ in [1, 0] })

        let outcome = try await pipeline.run(request(), profile: profile)

        // Текстовая половина этой базы ничего не находит, поэтому выдача та же;
        // но пул кандидатов уже расширен под слияние, и стадия отчиталась.
        XCTAssertTrue(outcome.diagnostics.stages.contains { $0.stage == .fusion })
    }
}
