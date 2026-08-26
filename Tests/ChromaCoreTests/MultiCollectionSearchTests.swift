import XCTest
@testable import ChromaCore

/// Поиск сразу по нескольким коллекциям.
final class MultiCollectionSearchTests: XCTestCase {
    private func target(
        _ name: String, model: String = "bge-m3", metric: DistanceMetric = .cosine, weight: Double = 1,
        queryPrefix: String = ""
    ) -> MultiCollectionSearch.Target {
        var profile = SearchProfile(collectionName: name)
        profile.queryPrefix = queryPrefix
        return MultiCollectionSearch.Target(
            collectionID: "id-\(name)", collectionName: name, model: model, metric: metric,
            profile: profile, weight: weight
        )
    }

    // MARK: - Приставка к запросу

    /// Здесь вектор передаётся в конвейер готовым, и свою приставку он
    /// применить уже не может — значит применить её обязан этот поиск.
    /// Иначе одна и та же настройка работала бы в поиске по одной коллекции
    /// и молча не работала в поиске по нескольким.
    func testThePrefixOfEachTargetReachesTheModel() async {
        let calls = Calls()
        let search = MultiCollectionSearch(
            embed: { text, _ in calls.texts.append(text); return [1, 0] },
            search: { _, _, _ in self.outcome([self.hit("d1", distance: 0.1)]) }
        )
        _ = await search.run(query: "сервер", targets: [target("без"), target("с", queryPrefix: "search_query: ")])
        XCTAssertEqual(calls.texts, ["сервер", "search_query: сервер"])
    }

    /// Одна модель, но разные приставки — это два разных запроса к ней.
    /// Запас по одной лишь модели отдал бы второй цели чужой вектор.
    func testTwoPrefixesOnOneModelAreTwoVectors() async {
        let calls = Calls()
        let search = MultiCollectionSearch(
            embed: { text, _ in calls.texts.append(text); return [1, 0] },
            search: { _, _, _ in self.outcome([self.hit("d1", distance: 0.1)]) }
        )
        let answer = await search.run(
            query: "сервер",
            targets: [target("а", queryPrefix: "A: "), target("б", queryPrefix: "Б: ")]
        )
        XCTAssertEqual(answer.embeddingCalls, 2, "приставки разные: \(calls.texts)")
    }

    /// И экономия остаётся: одинаковая приставка на одной модели — один вызов.
    func testTheSamePrefixOnOneModelIsStillOneCall() async {
        let search = MultiCollectionSearch(
            embed: { _, _ in [1, 0] },
            search: { _, _, _ in self.outcome([self.hit("d1", distance: 0.1)]) }
        )
        let answer = await search.run(
            query: "сервер",
            targets: [target("а", queryPrefix: "A: "), target("б", queryPrefix: "A: ")]
        )
        XCTAssertEqual(answer.embeddingCalls, 1)
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
        var texts: [String] = []
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

/// Стадия 7 на слитой выдаче.
///
/// Прежде переранжирования на этом пути не было вовсе: конвейер каждой
/// коллекции собирался без вызовов модели, и профиль, просивший стадию,
/// молча её не получал. Теперь она есть — и одна на всех, после слияния.
final class MultiCollectionRerankTests: XCTestCase {

    private func target(
        _ name: String, rerank: Bool = true, mode: RerankMode = .crossEncoder,
        model: String = "qwen3-reranker-0.6b", candidates: Int = 20
    ) -> MultiCollectionSearch.Target {
        var profile = SearchProfile(collectionName: name)
        profile.rerankEnabled = rerank
        profile.rerankMode = mode
        profile.rerankModel = model
        profile.rerankCandidates = candidates
        return MultiCollectionSearch.Target(
            collectionID: "id-\(name)", collectionName: name, model: "bge-m3",
            metric: .cosine, profile: profile
        )
    }

    private func hit(_ id: String, distance: Double) -> RetrievalHit {
        RetrievalHit(id: id, document: "текст \(id)", metadata: nil, distance: distance)
    }

    private func outcome(_ hits: [RetrievalHit]) -> RetrievalOutcome {
        RetrievalOutcome(hits: hits, diagnostics: RetrievalDiagnostics())
    }

    private actor Asked {
        private(set) var documents: [String] = []
        private(set) var rerankFlags: [Bool] = []
        func record(prompt: String) { documents.append(prompt) }
        func record(rerankEnabled: Bool) { rerankFlags.append(rerankEnabled) }
    }

    /// Стадия, которая говорит «да» только про названный документ.
    private func stage(saysYesTo wanted: String, asked: Asked) -> RerankStage {
        RerankStage(completePlain: { prompt, _, _ in
            await asked.record(prompt: prompt)
            return prompt.contains("<Document>: текст \(wanted)") ? "yes" : "no"
        })
    }

    /// Главное: модель сравнивает кандидатов **между** коллекциями.
    ///
    /// Лучший ответ лежит в чужой коллекции и на последнем месте слияния.
    /// Пока каждую коллекцию переранжировали отдельно, поднять его выше
    /// земляков было нечем: списки сливались уже после того, как модель
    /// высказалась.
    func testTheModelComparesCandidatesFromDifferentCollections() async {
        let asked = Asked()
        let search = MultiCollectionSearch(
            embed: { _, _ in [1, 0] },
            search: { target, _, _ in
                target.collectionName == "а"
                    ? self.outcome([self.hit("a1", distance: 0.1), self.hit("a2", distance: 0.2)])
                    : self.outcome([self.hit("b1", distance: 0.1), self.hit("b2", distance: 0.2)])
            },
            rerank: stage(saysYesTo: "b2", asked: asked)
        )
        let answer = await search.run(query: "q", targets: [target("а"), target("б")], nResults: 4)
        XCTAssertEqual(answer.hits.first?.id, "b2")
        XCTAssertEqual(answer.hits.first?.collectionName, "б")
        // Спрошено по разу про каждого кандидата слитого списка, а не по разу
        // на коллекцию: в этом вся разница.
        let documents = await asked.documents
        XCTAssertEqual(documents.count, 4)
    }

    /// Коллекции ищутся **без** стадии 7: иначе модель спросят дважды —
    /// сперва внутри коллекции, потом на слиянии.
    func testEachCollectionIsSearchedWithoutRerank() async {
        let asked = Asked()
        let search = MultiCollectionSearch(
            embed: { _, _ in [1, 0] },
            search: { target, _, _ in
                await asked.record(rerankEnabled: target.profile.rerankEnabled)
                return self.outcome([self.hit("d1", distance: 0.1)])
            },
            rerank: stage(saysYesTo: "нет такого", asked: asked)
        )
        _ = await search.run(query: "q", targets: [target("а"), target("б")], nResults: 4)
        let flags = await asked.rerankFlags
        XCTAssertEqual(flags, [false, false])
    }

    /// Разные настройки — не повод решать за человека, чьи главнее.
    func testCollectionsAskingDifferentThingsAreNotReranked() async {
        let asked = Asked()
        let search = MultiCollectionSearch(
            embed: { _, _ in [1, 0] },
            search: { _, _, _ in self.outcome([self.hit("d1", distance: 0.1)]) },
            rerank: stage(saysYesTo: "d1", asked: asked)
        )
        let answer = await search.run(
            query: "q", targets: [target("а"), target("б", mode: .chatSchema)], nResults: 4
        )
        let documents = await asked.documents
        XCTAssertTrue(documents.isEmpty, "модель спрошена вопреки несогласию профилей")
        XCTAssertEqual(answer.rerankNote, "коллекции просят разного переранжирования — выдача слита рангами")
    }

    /// Одна коллекция стадию выключила — значит её документы не судят
    /// настройками чужого профиля. Молчание об этом было бы хуже отказа.
    func testWhenNotEveryCollectionAsksTheMergedListIsLeftAlone() async {
        let asked = Asked()
        let search = MultiCollectionSearch(
            embed: { _, _ in [1, 0] },
            search: { _, _, _ in self.outcome([self.hit("d1", distance: 0.1)]) },
            rerank: stage(saysYesTo: "d1", asked: asked)
        )
        let answer = await search.run(
            query: "q", targets: [target("а"), target("заметки", rerank: false)], nResults: 4
        )
        let documents = await asked.documents
        XCTAssertTrue(documents.isEmpty)
        XCTAssertEqual(
            answer.rerankNote,
            "переранжирование просят не все коллекции (без него: заметки) — выдача слита рангами"
        )
    }

    /// Профили просят, а вызывать нечем — это говорится вслух, как в конвейере
    ///. Ровно тот случай, из-за которого стадия здесь и пропадала.
    func testWithoutAStageTheReasonIsNamed() async {
        let search = MultiCollectionSearch(
            embed: { _, _ in [1, 0] },
            search: { _, _, _ in self.outcome([self.hit("d1", distance: 0.1)]) }
        )
        let answer = await search.run(query: "q", targets: [target("а")], nResults: 4)
        XCTAssertEqual(
            answer.rerankNote,
            "переранжировать нечем: прямой вызов модели этому поиску не передан"
        )
    }

    /// Пул под стадию шире выдачи: треть выигрыша приходит из хвоста, куда
    /// десятка не достаёт. Обрезка — после модели, а не до неё.
    func testThePoolIsWiderThanTheAnswer() async {
        let asked = Asked()
        let search = MultiCollectionSearch(
            embed: { _, _ in [1, 0] },
            search: { target, _, _ in
                self.outcome((0..<10).map {
                    self.hit("\(target.collectionName)\($0)", distance: Double($0) / 100)
                })
            },
            rerank: stage(saysYesTo: "б9", asked: asked)
        )
        let answer = await search.run(query: "q", targets: [target("а"), target("б")], nResults: 2)
        let documents = await asked.documents
        XCTAssertEqual(documents.count, 20, "модели показали только выдачу, а не пул")
        XCTAssertEqual(answer.hits.count, 2)
        XCTAssertEqual(answer.hits.first?.id, "б9", "поднятое моделью не пережило обрезку")
    }
}
