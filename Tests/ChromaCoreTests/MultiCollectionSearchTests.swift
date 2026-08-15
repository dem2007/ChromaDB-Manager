import XCTest
@testable import ChromaCore

/// Поиск сразу по нескольким коллекциям.
final class MultiCollectionSearchTests: XCTestCase {
    private func target(
        _ name: String, model: String = "bge-m3", metric: DistanceMetric = .cosine, weight: Double = 1
    ) -> MultiCollectionSearch.Target {
        MultiCollectionSearch.Target(
            collectionID: "id-\(name)", collectionName: name, model: model, metric: metric,
            profile: SearchProfile(collectionName: name), weight: weight
        )
    }

    private func hit(_ id: String, distance: Double) -> RetrievalHit {
        RetrievalHit(id: id, document: "текст \(id)", metadata: nil, distance: distance)
    }

    private func outcome(_ hits: [RetrievalHit]) -> RetrievalOutcome {
        RetrievalOutcome(hits: hits, diagnostics: RetrievalDiagnostics())
    }

    private final class Calls: @unchecked Sendable {
        var models: [String] = []
        var searched: [String] = []
    }

    /// Главное обещание: три коллекции на одной модели — один вектор запроса,
    /// а не три. Локальная модель — самое дорогое, что есть в приложении.
    func testTheQueryIsEmbeddedOncePerModelNotPerCollection() async {
        let calls = Calls()
        let search = MultiCollectionSearch(
            embed: { _, model in calls.models.append(model); return [1, 0, 0] },
            search: { target, _, _ in
                calls.searched.append(target.collectionName)
                return self.outcome([self.hit("d1", distance: 0.1)])
            }
        )
        let answer = await search.run(
            query: "отпуск", targets: [target("докиs"), target("код"), target("заметки")]
        )
        XCTAssertEqual(calls.models, ["bge-m3"], "модель одна — вектор считается один раз")
        XCTAssertEqual(answer.embeddingCalls, 1)
        XCTAssertEqual(calls.searched.count, 3, "а искать надо во всех трёх")
    }

    func testDifferentModelsGetTheirOwnVector() async {
        let calls = Calls()
        let search = MultiCollectionSearch(
            embed: { _, model in calls.models.append(model); return [1, 0] },
            search: { _, _, _ in self.outcome([self.hit("d1", distance: 0.1)]) }
        )
        let answer = await search.run(
            query: "запрос",
            targets: [target("а", model: "bge-m3"), target("б", model: "e5"), target("в", model: "bge-m3")]
        )
        XCTAssertEqual(answer.embeddingCalls, 2, "две модели — два вектора: \(calls.models)")
    }

    /// Списки чередуются по рангам, а не склеиваются по расстоянию.
    ///
    /// Первый результат каждой коллекции обязан стоять выше вторых результатов
    /// всех коллекций — даже если у одной из них расстояния «лучше»: у `l2`
    /// шкала не ограничена вовсе, и сравнивать её с косинусной нельзя. Ради
    /// этого RRF и выбран.
    func testListsAreInterleavedByRankNotByDistance() {
        let lists: [(target: MultiCollectionSearch.Target, hits: [RetrievalHit])] = [
            (target("докиs", metric: .cosine), [hit("доки-1", distance: 0.42), hit("доки-2", distance: 0.44)]),
            (target("код", metric: .l2), [hit("код-1", distance: 9.1), hit("код-2", distance: 12.7)]),
        ]
        let fused = MultiCollectionSearch.fuse(lists, k: ReciprocalRankFusion.defaultK, limit: 10)
        XCTAssertEqual(Set(fused.prefix(2).map(\.id)), ["доки-1", "код-1"], fused.map(\.id).joined(separator: ", "))
        XCTAssertEqual(Set(fused.suffix(2).map(\.id)), ["доки-2", "код-2"], fused.map(\.id).joined(separator: ", "))
    }

    /// Одинаковые идентификаторы в разных коллекциях — не один документ.
    /// `id` считается от пути внутри источника, и совпадений сколько угодно.
    func testIdenticalIdentifiersInDifferentCollectionsStayApart() {
        let lists: [(target: MultiCollectionSearch.Target, hits: [RetrievalHit])] = [
            (target("докиs"), [hit("a1b2-0", distance: 0.1)]),
            (target("код"), [hit("a1b2-0", distance: 0.1)]),
        ]
        let fused = MultiCollectionSearch.fuse(lists, k: ReciprocalRankFusion.defaultK, limit: 10)
        XCTAssertEqual(fused.count, 2, "два разных документа не должны слиться в один")
        XCTAssertEqual(Set(fused.compactMap(\.collectionName)), ["докиs", "код"])
    }

    /// У каждого результата написано, откуда он: выдача без этого —
    /// список без ответа на первый же вопрос.
    func testEveryHitSaysWhichCollectionItCameFrom() async {
        let search = MultiCollectionSearch(
            embed: { _, _ in [1, 0] },
            search: { target, _, _ in self.outcome([self.hit("\(target.collectionName)-1", distance: 0.1)]) }
        )
        let answer = await search.run(query: "запрос", targets: [target("докиs"), target("код")])
        XCTAssertEqual(Set(answer.hits.compactMap(\.collectionName)), ["докиs", "код"])
    }

    /// Одна коллекция отвалилась — остальные обязаны ответить, а про неё
    /// должно быть сказано.
    func testAFailingCollectionDoesNotTakeTheOthersDown() async {
        struct Broken: LocalizedError { var errorDescription: String? { "коллекция недоступна" } }
        let search = MultiCollectionSearch(
            embed: { _, _ in [1, 0] },
            search: { target, _, _ in
                if target.collectionName == "код" { throw Broken() }
                return self.outcome([self.hit("d1", distance: 0.1)])
            }
        )
        let answer = await search.run(
            query: "запрос", targets: [target("докиs"), target("код"), target("заметки")]
        )
        XCTAssertEqual(answer.hits.count, 2)
        let broken = answer.collections.first { $0.name == "код" }
        XCTAssertEqual(broken?.failure, "коллекция недоступна")
        XCTAssertTrue(answer.line.contains("не ответили: код"), answer.line)
    }

    func testTheAnswerIsCappedByTheRequestedCount() async {
        let search = MultiCollectionSearch(
            embed: { _, _ in [1, 0] },
            search: { target, _, _ in
                self.outcome((1...10).map { self.hit("\(target.collectionName)-\($0)", distance: Double($0) / 10) })
            }
        )
        let answer = await search.run(
            query: "запрос", targets: [target("а"), target("б")], nResults: 5
        )
        XCTAssertEqual(answer.hits.count, 5)
    }

    func testNoTargetsIsAnEmptyAnswerNotACrash() async {
        let search = MultiCollectionSearch(embed: { _, _ in [] }, search: { _, _, _ in
            self.outcome([])
        })
        let answer = await search.run(query: "запрос", targets: [])
        XCTAssertTrue(answer.hits.isEmpty)
        XCTAssertEqual(answer.embeddingCalls, 0)
    }

    /// Вес коллекции работает: у поднятой в весе результат идёт выше при
    /// прочих равных.
    func testCollectionWeightMovesResults() {
        let lists: [(target: MultiCollectionSearch.Target, hits: [RetrievalHit])] = [
            (target("обычная", weight: 1), [hit("из-обычной", distance: 0.1)]),
            (target("важная", weight: 3), [hit("из-важной", distance: 0.1)]),
        ]
        let fused = MultiCollectionSearch.fuse(lists, k: ReciprocalRankFusion.defaultK, limit: 10)
        XCTAssertEqual(fused.first?.id, "из-важной", fused.map(\.id).joined(separator: ", "))
    }
}

/// Экран поиска по нескольким коллекциям обязан пользоваться **этим** ядром,
/// а не заводить свой цикл по коллекциям.
///
/// Сторож читает исходник экрана: вторая реализация слияния скомпилировалась
/// бы, прошла бы все прочие тесты и разошлась бы с выдачей агента — который
/// ищет как раз через `MultiCollectionSearch`.
final class MultiCollectionScreenUsesTheCoreTests: XCTestCase {
    private var screenSource: String {
        get throws {
            let file = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/ChromaDBManagerApp/ViewModels/CollectionsViewModel.swift")
            return try String(contentsOf: file, encoding: .utf8)
        }
    }

    func testTheScreenSearchesThroughMultiCollectionSearch() throws {
        let text = try screenSource
        XCTAssertTrue(
            text.contains("MultiCollectionSearch("),
            "экран обязан искать тем же ядром, что и агент"
        )
        XCTAssertTrue(
            text.contains("RetrievalPipeline("),
            "каждая коллекция ищется тем же конвейером и своим профилем"
        )
    }

    /// Вектор считается по разу на модель — ради этого всё и делалось.
    func testTheScreenDoesNotEmbedPerCollection() throws {
        let text = try screenSource
        XCTAssertFalse(
            text.contains("for target in targets"),
            "перебор коллекций с эмбеддингом на каждую — работа ядра, а не экрана"
        )
    }
}
