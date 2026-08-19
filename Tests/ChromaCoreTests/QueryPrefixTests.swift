import XCTest
@testable import ChromaCore

/// Приставка к запросу перед вектором.
///
/// Модели Qwen3-Embedding и nomic обучены на несимметричной паре: документ
/// идёт в модель как есть, а запрос — с инструкцией впереди. Приставка живёт
/// в профиле, чтобы стенд мог сравнить её с пустой на одной базе.
final class QueryPrefixTests: XCTestCase {

    private func profile(prefix: String) -> SearchProfile {
        var value = SearchProfile.plain(collectionName: "c", name: "п")
        value.queryPrefix = prefix
        return value
    }

    // MARK: - Что уходит в модель

    func testAnEmptyPrefixLeavesTheQueryAlone() {
        XCTAssertEqual(profile(prefix: "").embeddedQuery("сервер"), "сервер")
    }

    func testThePrefixGoesInFrontOfTheQuery() {
        XCTAssertEqual(
            profile(prefix: "search_query: ").embeddedQuery("сервер"),
            "search_query: сервер"
        )
    }

    /// Приставка сохраняется и читается: профиль, записанный прежней сборкой,
    /// обязан открыться с пустой приставкой, а не перестать открываться.
    func testAProfileWrittenBeforeThisFieldStillDecodes() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"старый","collectionName":"c","isDefault":false,
         "candidateMultiplier":5,"minimumCandidates":20,"vectorSearchEnabled":true,
         "textSearchEnabled":false,"vectorWeight":1,"textWeight":1,"fusionK":60,
         "searchLevel":"children","promotion":"parent","collapseByParent":true,
         "diversityEnabled":false,"diversityLambda":0.7,"contextWindow":0,
         "rerankEnabled":false,"rerankModel":"","rerankPrompt":"","rerankInstruction":"",
         "rerankMode":"chatSchema","marksEnabled":true,"splitQueryIntoWords":false}
        """
        let decoded = try JSONDecoder().decode(SearchProfile.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.queryPrefix, "")
    }

    func testThePrefixSurvivesASaveAndLoad() throws {
        let saved = profile(prefix: "Instruct: задача\nQuery: ")
        let data = try JSONEncoder().encode(saved)
        let loaded = try JSONDecoder().decode(SearchProfile.self, from: data)
        XCTAssertEqual(loaded.queryPrefix, saved.queryPrefix)
    }
}

/// Стенд обязан считать **разные** векторы для вариантов с разной приставкой.
///
/// Это тот же класс поломки, что, и: настройка меняется,
/// а выдача — нет. Здесь ловушка особенно тихая, потому что запас векторов
/// заведён ради экономии и работает правильно во всех остальных случаях.
final class QueryPrefixOnTheBenchTests: XCTestCase {

    private actor Recorder {
        private(set) var asked: [String] = []
        func record(_ text: String) { asked.append(text) }
    }

    private func variant(_ name: String, prefix: String) -> EvaluationVariant {
        var profile = SearchProfile.plain(collectionName: "c", name: "профиль \(name)")
        profile.queryPrefix = prefix
        return EvaluationVariant(
            name: name, collectionID: "id", collectionName: "c",
            model: "qwen3", nResults: 5, profile: profile
        )
    }

    private func outcome() -> RetrievalOutcome {
        RetrievalOutcome(
            hits: [RetrievalHit(id: "a", document: "текст", metadata: nil, distance: 0.1)],
            diagnostics: RetrievalDiagnostics()
        )
    }

    func testTwoPrefixesMeanTwoVectors() async {
        let recorder = Recorder()
        let runner = EvaluationRunner(
            embed: { text, _ in await recorder.record(text); return [1, 0] },
            search: { [self] _, _, _ in outcome() }
        )

        _ = await runner.run(
            set: QuerySet(name: "н", queries: [EvaluationQuery(text: "сервер")]),
            variants: [
                variant("без приставки", prefix: ""),
                variant("с приставкой", prefix: "search_query: "),
            ]
        )

        let asked = await recorder.asked
        XCTAssertEqual(asked, ["сервер", "search_query: сервер"],
                       "вариант с приставкой взял чужой вектор из запаса")
    }

    /// И обратное: одинаковая приставка по-прежнему считается один раз —
    /// экономия, ради которой запас и заведён, не должна пропасть.
    func testTheSamePrefixIsStillEmbeddedOnce() async {
        let recorder = Recorder()
        let runner = EvaluationRunner(
            embed: { text, _ in await recorder.record(text); return [1, 0] },
            search: { [self] _, _, _ in outcome() }
        )

        _ = await runner.run(
            set: QuerySet(name: "н", queries: [EvaluationQuery(text: "сервер")]),
            variants: [variant("A", prefix: "search_query: "), variant("B", prefix: "search_query: ")]
        )

        let asked = await recorder.asked
        XCTAssertEqual(asked, ["search_query: сервер"])
    }
}
