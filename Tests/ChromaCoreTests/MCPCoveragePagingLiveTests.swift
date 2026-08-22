import XCTest
@testable import ChromaCore

/// Листание по текстовому условию на живой базе.
///
/// Вопрос один: перечисляет ли `offset` **всю** выборку по `contains` — или
/// теряет и повторяет документы, как предупреждает комментарий в
/// `MCPFileChunks`. От ответа зависит, нужен ли отдельный инструмент «собери
/// по теме»: если листание надёжно, задача решается тем, что уже есть.
///
///     CHROMA_IT=1 CHROMA_LIVE_PORT=63849 CHROMA_LIVE_COLLECTION=base_adaptive \
///         CHROMA_LIVE_TERM=приемк swift test --filter MCPCoveragePagingLiveTests
final class MCPCoveragePagingLiveTests: XCTestCase {
    private var port = 0
    private var collectionName = ""
    private var term = ""

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["CHROMA_IT"] == "1", "Живая проверка включается CHROMA_IT=1")
        guard let port = environment["CHROMA_LIVE_PORT"].flatMap(Int.init),
              let name = environment["CHROMA_LIVE_COLLECTION"], !name.isEmpty
        else {
            throw XCTSkip("Нужны CHROMA_LIVE_PORT и CHROMA_LIVE_COLLECTION")
        }
        self.port = port
        self.collectionName = name
        self.term = environment["CHROMA_LIVE_TERM"] ?? "приемк"
    }

    func testPagingByOffsetEnumeratesTheWholeMatchWithoutGapsOrRepeats() async throws {
        let client = ChromaClient(endpoint: ChromaEndpoint(host: "127.0.0.1", port: port))
        let collections = try await client.listCollections(withCounts: false)
        guard let collection = collections.first(where: { $0.name == collectionName }) else {
            throw XCTSkip("Нет коллекции «\(collectionName)»")
        }

        // Условие строится ровно так, как его строит инструмент: варианты
        // написания через «или».
        let filter = try MCPToolService.filterForTesting(
            .object(["contains": .string(term)])
        ).get()

        let started = Date()
        let whole = try await client.getDocuments(
            collectionID: collection.id, limit: 20_000, offset: 0,
            filter: filter, includeDocuments: false
        )
        let wholeSeconds = Date().timeIntervalSince(started)
        try XCTSkipIf(whole.isEmpty, "Слова «\(term)» в коллекции нет")
        let expected = Set(whole.map(\.id))

        // То же самое страницами — как это делает агент.
        let pageSize = ProcessInfo.processInfo.environment["CHROMA_LIVE_PAGE"].flatMap(Int.init) ?? 100
        var collected: [String] = []
        var offset = 0
        let pagingStarted = Date()
        while true {
            let page = try await client.getDocuments(
                collectionID: collection.id, limit: pageSize, offset: offset,
                filter: filter, includeDocuments: false
            )
            collected += page.map(\.id)
            offset += page.count
            if page.count < pageSize { break }
            if offset > 20_000 { break }
        }
        let pagingSeconds = Date().timeIntervalSince(pagingStarted)

        let unique = Set(collected)
        let repeats = collected.count - unique.count
        let missing = expected.subtracting(unique)
        let extra = unique.subtracting(expected)
        let files = Set(whole.compactMap { record -> String? in
            guard case .string(let path)? = record.metadata?["source_file"] else { return nil }
            return path
        })

        print("""

        # Листание по «\(term)» в «\(collectionName)»
        одним запросом: \(whole.count) кусков из \(files.count) файлов за \(String(format: "%.2f", wholeSeconds)) с
        страницами по \(pageSize): \(collected.count) кусков, страниц \(Int(ceil(Double(collected.count) / Double(pageSize)))), \
        за \(String(format: "%.2f", pagingSeconds)) с
        повторов: \(repeats), потеряно: \(missing.count), лишних: \(extra.count)

        """)

        XCTAssertEqual(repeats, 0, "листание показало документ дважды")
        XCTAssertTrue(missing.isEmpty, "листание потеряло \(missing.count) документов")
        XCTAssertTrue(extra.isEmpty, "листание вернуло документы вне выборки")
    }

    /// «Собери по теме» целиком, настоящим `MCPToolService` на живых данных.
    ///
    /// Здесь и видно, ради чего инструмент сделан: один обход коллекции вместо
    /// страницы за страницей, и ответ, который агент может удержать, — файлы
    /// с числом совпадений, а не две тысячи кусков.
    func testCollectMentionsAnswersTheCoverageQuestionInOneCall() async throws {
        let client = ChromaClient(endpoint: ChromaEndpoint(host: "127.0.0.1", port: port))
        let collections = try await client.listCollections(withCounts: false)
        guard let collection = collections.first(where: { $0.name == collectionName }) else {
            throw XCTSkip("Нет коллекции «\(collectionName)»")
        }

        let key = "живой-ключ-проверки"
        let access = AccessController()
        await access.setClients([
            ExternalClient(
                name: "замер",
                keyHash: ClientKey.hash(key),
                keyPrefix: String(key.prefix(4)),
                permissions: ClientPermissions(collections: [collectionName], requestsPerMinute: 600, burst: 600)
            ),
        ])
        let service = MCPToolService(
            backend: LiveBackend(client: client, collectionID: collection.id, name: collectionName),
            access: access
        )

        let started = Date()
        let result = try await service.call(
            name: "collect_mentions",
            arguments: .object([
                "collection": .string(collectionName),
                "contains": .string(term),
                "limit": .int(10),
                "fields": .array([.string("source_file")]),
            ]),
            key: key
        ).get()
        let seconds = Date().timeIntervalSince(started)

        guard case .array(let files)? = result["structuredContent"]?["files"] else {
            return XCTFail("файлов в ответе нет")
        }
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        print("""

        # collect_mentions «\(term)» в «\(collectionName)»
        совпадений: \(result["structuredContent"]?["totalMatches"]?.intValue ?? -1),         файлов: \(result["structuredContent"]?["totalFiles"]?.intValue ?? -1),         показано файлов: \(files.count), за \(String(format: "%.2f", seconds)) с
        размер ответа: \(text.count) знаков
        \(text.split(separator: "\n").prefix(6).joined(separator: "\n"))

        """)

        XCTAssertFalse(files.isEmpty)
        XCTAssertEqual(result["isError"]?.boolValue ?? false, false)
        // Ответ обязан помещаться в бюджет: ради этого всё и затевалось.
        XCTAssertLessThanOrEqual(text.count, MCPOutputLimits.defaultResponseCharacters + 4000)
    }

    /// Минимальная подложка: инструменту нужен только обход коллекции.
    private struct LiveBackend: MCPToolBackend {
        let client: ChromaClient
        let collectionID: String
        let name: String

        func collections(allowed: [String]) async throws -> [MCPCollectionSummary] {
            [MCPCollectionSummary(name: name, documentCount: nil, model: nil, metric: nil, dimension: nil)]
        }
        func describe(collection: String) async throws -> MCPCollectionDescription {
            MCPCollectionDescription(
                summary: MCPCollectionSummary(name: name, documentCount: nil, model: nil, metric: nil, dimension: nil),
                fields: [], hasSchema: false, allowsExtraFields: true
            )
        }
        func search(_ request: MCPSearchRequest) async throws -> MCPSearchAnswer {
            MCPSearchAnswer(documents: [], metric: nil, model: nil)
        }
        func documents(_ request: MCPDocumentsRequest) async throws -> MCPDocumentsAnswer {
            let records = try await client.getDocuments(
                collectionID: collectionID, limit: request.limit, offset: request.offset,
                filter: request.filter
            )
            return MCPDocumentsAnswer(
                documents: records.map {
                    MCPDocumentPayload(id: $0.id, text: $0.document, metadata: $0.metadata)
                },
                hasMore: false
            )
        }
        func add(_ request: MCPAddRequest) async throws -> MCPAddAnswer {
            MCPAddAnswer(ids: [], model: nil)
        }
        func delete(_ request: MCPDeleteRequest) async throws -> MCPDeleteAnswer {
            MCPDeleteAnswer(deleted: [], missing: [], keptInTrash: false)
        }
    }
}
