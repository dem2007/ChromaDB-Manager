import XCTest
@testable import ChromaCore

/// Поиск по нескольким коллекциям на живой базе и живой модели.
///
/// Здесь проверяется то, чего не видит подставной стенд: что запрос
/// действительно доходит до трёх разных коллекций настоящего сервера, что
/// вектор считается по разу на модель, и что в выдаче перемешаны документы
/// из всех трёх.
///
///     CHROMA_IT=1 swift test --filter MultiCollectionLiveTests
final class MultiCollectionLiveTests: XCTestCase {
    private var model = ""
    private var lmStudio: LMStudioClient!

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CHROMA_IT"] == "1",
            "Живая проверка включается CHROMA_IT=1"
        )
        try XCTSkipIf(ToolLocator().locate("chroma") == nil, "chroma не установлен")
        lmStudio = try LMStudioClient(baseURLString: "http://localhost:1234")
        guard let models = try? await lmStudio.models(),
              let embedding = models.first(where: { $0.kind == .embedding })
        else { throw XCTSkip("LM Studio не отвечает или в нём нет модели эмбеддингов") }
        model = embedding.id
    }

    @MainActor
    func testOneQueryReachesEveryCollectionAndTheAnswerIsMixed() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-multi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = ChromaProcessManager()
        let endpoint = try await manager.start(ServerLaunchConfiguration(
            label: "multi", databasePath: directory,
            host: "127.0.0.1", port: PortUtility.freePort(), allowReset: true
        ))
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }

        let client = ChromaClient(endpoint: endpoint)
        let shapes = CollectionShapeCache()

        // Три коллекции про одно и то же с разных сторон — ровно тот случай,
        // ради которого всё делалось: «ищу по документации, коду и заметкам».
        let content: [(collection: String, documents: [String])] = [
            ("docs-live", [
                "Резервное копирование базы выполняется ежедневно в полночь.",
                "Отпуск оформляется заявлением за две недели.",
            ]),
            ("code-live", [
                "func runBackup() { schedule(at: .midnight) } — точка входа ночного копирования.",
                "struct VacationRequest { let days: Int }",
            ]),
            ("notes-live", [
                "Проверить, что ночное копирование доезжает до архивного сервера.",
                "Купить кофе.",
            ]),
        ]

        var targets: [MultiCollectionSearch.Target] = []
        for entry in content {
            let collection = try await client.createCollection(
                name: entry.collection, configuration: CollectionConfiguration(metric: .cosine)
            )
            let vectors = try await lmStudio.embed(texts: entry.documents, model: model)
            try await client.upsert(
                collectionID: collection.id,
                records: zip(entry.documents.indices, zip(entry.documents, vectors)).map { index, pair in
                    EmbeddedRecord(
                        id: "\(entry.collection)-\(index)", document: pair.0,
                        embedding: pair.1, metadata: ["kind": .string(entry.collection)]
                    )
                }
            )
            targets.append(MultiCollectionSearch.Target(
                collectionID: collection.id, collectionName: collection.name,
                model: model, metric: .cosine,
                profile: SearchProfile(collectionName: collection.name)
            ))
        }

        let search = MultiCollectionSearch(
            embed: { [lmStudio] text, model in try await lmStudio!.embed(text: text, model: model) },
            search: { target, query, vector in
                let pipeline = RetrievalPipeline(
                    database: client, shapes: shapes, embed: { _ in vector }
                )
                return try await pipeline.run(
                    RetrievalRequest(
                        text: query, collectionID: target.collectionID,
                        collectionName: target.collectionName, nResults: 3, metric: target.metric
                    ),
                    profile: target.profile
                )
            }
        )

        let answer = await search.run(query: "ночное резервное копирование", targets: targets, nResults: 6)

        print("несколько коллекций: \(answer.line)")
        for hit in answer.hits.prefix(6) {
            print("  [\(hit.collectionName ?? "—")] \(hit.document?.prefix(60) ?? "")")
        }

        XCTAssertEqual(answer.embeddingCalls, 1, "модель одна на все три коллекции — вектор обязан считаться один раз")
        XCTAssertTrue(answer.collections.allSatisfy { $0.failure == nil }, "\(answer.collections)")
        XCTAssertEqual(
            Set(answer.hits.compactMap(\.collectionName)).count, 3,
            "в выдаче обязаны быть все три коллекции: \(answer.hits.map { $0.collectionName ?? "—" })"
        )
        // Первым — то, что действительно про запрос, из любой коллекции.
        XCTAssertTrue(
            answer.hits.first?.document?.contains("копирован") ?? false,
            answer.hits.first?.document ?? "пусто"
        )

        for entry in content { try await client.deleteCollection(name: entry.collection) }
    }
}
