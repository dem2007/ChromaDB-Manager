import XCTest
@testable import ChromaCore

/// Стенд оценки на живых данных: настоящий `chroma run`, настоящая модель
/// в LM Studio, настоящий конвейер поиска.
///
/// Отдельно от `EvaluationRunTests`, где всё подставное: там проверяется
/// арифметика и порядок вызовов, а здесь — что стенд считает **то, что видно
/// глазами**. Вопрос «как у нас работает evaluation» без такого прогона
/// отвечается только рассуждением.
///
/// Пропускается, если не задано `CHROMA_IT=1`, нет `chroma` или молчит
/// LM Studio.
///
///     CHROMA_IT=1 swift test --filter EvaluationLiveTests
final class EvaluationLiveTests: XCTestCase {
    private let lmStudioURL = "http://localhost:1234"
    private var embeddingModel = ""

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CHROMA_IT"] == "1",
            "Живой прогон стенда включается CHROMA_IT=1"
        )
        try XCTSkipIf(ToolLocator().locate("chroma") == nil, "chroma не установлен")

        let lmStudio = try LMStudioClient(baseURLString: lmStudioURL)
        guard let models = try? await lmStudio.models(),
              let embedding = models.first(where: { $0.kind == .embedding })
        else { throw XCTSkip("LM Studio не отвечает или в нём нет модели эмбеддингов") }
        embeddingModel = embedding.id
    }

    /// Восемь коротких документов, среди которых у каждого запроса есть
    /// ровно один очевидный ответ — и несколько похожих по словам соседей.
    private let documents: [(id: String, text: String)] = [
        ("d1", "Отпуск оформляется заявлением за две недели до начала. Заявление подписывает руководитель отдела."),
        ("d2", "Больничный лист передаётся в бухгалтерию в течение трёх дней после закрытия."),
        ("d3", "Командировочные расходы возмещаются по авансовому отчёту с чеками."),
        ("d4", "Пароль от рабочей почты меняется раз в девяносто дней, длина не меньше двенадцати символов."),
        ("d5", "Ноутбук выдаётся под подпись на складе, возврат при увольнении."),
        ("d6", "Обед с 13:00 до 14:00, кухня на третьем этаже."),
        ("d7", "Астра Линукс Орёл ставится на рабочие станции отдела разработки."),
        ("d8", "Пропуск восстанавливается в бюро пропусков при предъявлении паспорта."),
    ]

    @MainActor
    func testTheBenchMeasuresWhatIsActuallyRetrieved() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-eval-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = ChromaProcessManager()
        let endpoint = try await manager.start(ServerLaunchConfiguration(
            label: "eval", databasePath: directory,
            host: "127.0.0.1", port: PortUtility.freePort(), allowReset: true
        ))
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }

        let client = ChromaClient(endpoint: endpoint)
        let lmStudio = try LMStudioClient(baseURLString: lmStudioURL)

        // MARK: данные

        let collection = try await client.createCollection(
            name: "eval-live", configuration: CollectionConfiguration(metric: .cosine)
        )
        let vectors = try await lmStudio.embed(texts: documents.map(\.text), model: embeddingModel)
        try await client.upsert(
            collectionID: collection.id,
            records: zip(documents, vectors).map { document, vector in
                EmbeddedRecord(
                    id: document.id, document: document.text,
                    embedding: vector, metadata: ["kind": .string("правило")]
                )
            }
        )

        // MARK: набор запросов с эталоном

        let set = QuerySet(
            name: "живой набор",
            queries: [
                EvaluationQuery(text: "как оформить отпуск", fragments: [ExpectedFragment(fragment: "Отпуск оформляется заявлением")]),
                EvaluationQuery(text: "требования к паролю", fragments: [ExpectedFragment(fragment: "меняется раз в девяносто дней")]),
                EvaluationQuery(text: "astra linux орел", fragments: [ExpectedFragment(fragment: "Астра Линукс Орёл")]),
            ]
        )

        // MARK: два варианта — только вектор и вектор с текстом

        func variant(_ name: String, text: Bool) -> EvaluationVariant {
            var profile = SearchProfile(name: name, collectionName: collection.name)
            profile.textSearchEnabled = text
            profile.splitQueryIntoWords = text
            return EvaluationVariant(
                name: name, collectionID: collection.id, collectionName: collection.name,
                model: embeddingModel, metric: .cosine, nResults: 5, profile: profile
            )
        }
        let variants = [variant("только вектор", text: false), variant("вектор + текст", text: true)]

        // MARK: прогон

        let shapes = CollectionShapeCache()
        let runner = EvaluationRunner(
            embed: { text, model in try await lmStudio.embed(text: text, model: model) },
            search: { variant, query, vector in
                let pipeline = RetrievalPipeline(
                    database: client, shapes: shapes, embed: { _ in vector ?? [] }
                )
                return try await pipeline.run(
                    RetrievalRequest(
                        text: query.text, collectionID: variant.collectionID,
                        collectionName: variant.collectionName,
                        nResults: variant.nResults, metric: variant.metric
                    ),
                    profile: variant.profile
                )
            }
        )
        let run = await runner.run(set: set, variants: variants, name: "живой прогон")

        // MARK: что должно быть правдой

        XCTAssertEqual(run.results.count, set.queries.count * variants.count, "по ячейке на «запрос × вариант»")
        XCTAssertTrue(run.results.allSatisfy { $0.succeeded }, "живой прогон не должен падать: \(run.results.compactMap { $0.failure })")

        // один вектор на «запрос + модель», а не по одному на вариант.
        let calls = await runner.embeddingCallCount
        XCTAssertEqual(calls, set.queries.count, "вектор запроса считается один раз на модель, а не на каждый вариант")

        let metrics = EvaluationMetrics.compute(run: run, set: set, ks: [1, 5])
        for variant in metrics {
            let hit = variant.hitRate[5]?.value
            XCTAssertEqual(
                hit, 1.0,
                "вариант «\(variant.variantName)»: hit rate@5 должен быть 1 — у каждого запроса ответ лежит в коллекции"
            )
            XCTAssertNotNil(variant.mrr.value)
            XCTAssertNotNil(variant.searchLatency, "время поиска обязано измеряться")
            print("""
            вариант «\(variant.variantName)»: \
            hit@1 \(variant.hitRate[1]?.value.map { String(format: "%.2f", $0) } ?? "—"), \
            hit@5 \(variant.hitRate[5]?.value.map { String(format: "%.2f", $0) } ?? "—"), \
            ndcg@5 \(variant.ndcg[5]?.value.map { String(format: "%.2f", $0) } ?? "—"), \
            mrr \(variant.mrr.value.map { String(format: "%.2f", $0) } ?? "—"), \
            поиск \(variant.searchLatency.map { String(format: "%.0f мс", $0.median * 1000) } ?? "—")
            """)
        }

        // Что именно нашлось — по запросу и варианту. Это и есть ответ на
        // вопрос «как оно работает»: цифра без выдачи ничего не объясняет.
        for variant in variants {
            for query in set.queries {
                guard let result = run.results.first(where: {
                    $0.variantID == variant.id && $0.queryID == query.id
                }) else { continue }
                let top = result.hits.prefix(3).map { hit in
                    hit.distance.map { "\(hit.id) (\(String(format: "%.3f", $0)))" } ?? hit.id
                }
                print("«\(query.text)» · \(variant.name): \(top.joined(separator: ", "))")
            }
        }

        // Эталон по фрагменту: попадание засчитывается по тексту документа,
        // а не по его идентификатору — иначе набор запросов нельзя было бы
        // перенести на другую коллекцию.
        let truth = EvaluationMetrics.groundTruth(for: run, set: set)
        XCTAssertEqual(truth.count, set.queries.count)

        try await client.deleteCollection(name: collection.name)
    }
}
