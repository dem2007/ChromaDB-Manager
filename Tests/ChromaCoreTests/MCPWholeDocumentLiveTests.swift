import XCTest
@testable import ChromaCore

/// Живая проверка чтения документа целиком.
///
/// Замеры до сих пор делались на подложке, а разбор — по журналу чужого
/// сеанса. Здесь то же самое, но своими руками и на настоящей коллекции:
/// умолчание инструмента, страницы по «offset» до конца файла, потолок
/// ответа на каждой странице и обещание карты против того, что вышло.
///
///     CHROMA_IT=1 CHROMA_LIVE_PORT=51400 CHROMA_LIVE_COLLECTION=base_docs_4b \
///         CHROMA_LIVE_FILE=71cd6b2212be8a4f swift test --filter MCPWholeDocumentLiveTests
final class MCPWholeDocumentLiveTests: XCTestCase {
    private var port = 0
    private var collectionName = ""
    private var fileID = ""

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["CHROMA_IT"] == "1", "Живая проверка включается CHROMA_IT=1")
        guard let port = environment["CHROMA_LIVE_PORT"].flatMap(Int.init),
              let name = environment["CHROMA_LIVE_COLLECTION"], !name.isEmpty,
              let file = environment["CHROMA_LIVE_FILE"], !file.isEmpty
        else {
            throw XCTSkip("Нужны CHROMA_LIVE_PORT, CHROMA_LIVE_COLLECTION и CHROMA_LIVE_FILE")
        }
        self.port = port
        self.collectionName = name
        self.fileID = file
    }

    /// Ключ проверки: свой, с потолками настоящего ключа.
    private let key = "живой-ключ-чтения"

    private func service() async throws -> MCPToolService {
        let client = ChromaClient(endpoint: ChromaEndpoint(host: "127.0.0.1", port: port))
        let collections = try await client.listCollections(withCounts: false)
        guard let collection = collections.first(where: { $0.name == collectionName }) else {
            throw XCTSkip("Нет коллекции «\(collectionName)»")
        }
        let access = AccessController()
        await access.setClients([
            ExternalClient(
                name: "замер",
                keyHash: ClientKey.hash(key),
                keyPrefix: String(key.prefix(4)),
                permissions: ClientPermissions(
                    collections: [collectionName], requestsPerMinute: 6000, burst: 6000
                ),
            ),
        ])
        return MCPToolService(
            backend: Backend(client: client, collectionID: collection.id, name: collectionName),
            access: access
        )
    }

    private func call(
        _ service: MCPToolService, _ arguments: [String: JSONValue]
    ) async throws -> JSONValue {
        var arguments = arguments
        arguments["collection"] = .string(collectionName)
        arguments["file_id"] = arguments["file_id"] ?? .string(fileID)
        return try await service.call(
            name: "get_file", arguments: .object(arguments), key: key
        ).get()
    }

    /// Размер ответа так, как его видит агент: строки и зеркало, в знаках.
    private func size(of result: JSONValue) -> (text: String, total: Int) {
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        let mirror = result["structuredContent"].map { $0.deliveredSize } ?? 0
        return (text, text.count + mirror)
    }

    /// Знаки самого документа: всё после пустой строки, без меток кусков.
    private func documentCharacters(in text: String) -> Int {
        guard let body = text.range(of: "\n\n") else { return 0 }
        let tail = String(text[body.upperBound...])
        let marks = tail.ranges(ofPattern: "[chunk ")
        var carried = tail.count
        for start in marks {
            guard let end = tail.range(of: "]", range: start.lowerBound..<tail.endIndex) else { continue }
            carried -= tail.distance(from: start.lowerBound, to: end.upperBound)
        }
        return max(0, carried)
    }

    func testTheWholeDocumentIsReadableAndEveryPageFitsTheCeiling() async throws {
        let service = try await service()

        // 1. Умолчание: без «as» приходит сплошной текст.
        let first = try await call(service, [:])
        XCTAssertEqual(
            first["structuredContent"]?["as"], .string("text"),
            "умолчание инструмента — сплошной текст"
        )

        // 2. Карта: во что она оценивает чтение целиком.
        let map = try await call(service, ["outline": .bool(true)])
        let promised = map["structuredContent"]?["callsToReadWhole"]?.intValue
        let estimate = map["structuredContent"]?["charactersEstimate"]?.intValue
        let totalChunks = map["structuredContent"]?["totalChunks"]?.intValue ?? 0
        let ceiling = MCPOutputLimits.defaultResponseCharacters
        XCTAssertLessThanOrEqual(size(of: map).total, ceiling, "карта за потолком")

        // 3. Весь документ страницами — ровно так, как его читал бы агент.
        var calls = 0
        var carried = 0
        var spent = 0
        var largest = 0
        var offset = 0
        var result = first
        while calls < 400 {
            calls += 1
            let page = size(of: result)
            carried += documentCharacters(in: page.text)
            spent += page.total
            largest = max(largest, page.total)
            XCTAssertLessThanOrEqual(
                page.total, ceiling,
                "страница \(calls) со смещения \(offset) вышла за потолок: \(page.total)"
            )
            guard result["structuredContent"]?["hasMore"]?.boolValue == true,
                  let next = result["structuredContent"]?["nextOffset"]?.intValue, next > offset
            else { break }
            offset = next
            result = try await call(service, ["offset": .int(offset)])
        }

        XCTAssertEqual(
            result["structuredContent"]?["hasMore"], .bool(false),
            "документ не дочитан до конца за \(calls) вызовов"
        )
        XCTAssertEqual(offset + (result["structuredContent"]?["chunksShown"]?.intValue ?? 0), totalChunks,
                       "прочитано кусков меньше, чем в файле")

        print("""

        # Чтение целиком: «\(collectionName)» / \(fileID)
        кусков в файле: \(totalChunks)
        карта обещала: \(promised.map(String.init) ?? "—") вызовов, \(estimate.map(String.init) ?? "—") знаков
        вышло: \(calls) вызовов, \(carried) знаков документа
        потрачено на ответы: \(spent), самый большой \(largest) при потолке \(ceiling)
        полезного в ответе: \(spent > 0 ? carried * 100 / spent : 0) %

        """)

        if let promised {
            // Обещание — «около»: оценка знаков идёт от токенов. Но раз в
            // полтора оно расходиться не должно, иначе это не оценка.
            XCTAssertGreaterThan(calls * 3, promised * 2, "вышло вдвое меньше обещанного")
            XCTAssertLessThan(calls * 2, promised * 3, "вышло в полтора раза больше обещанного")
        }
    }

    /// Подложка — настоящая база, обход как у приложения: по порядку кусков.
    private struct Backend: MCPToolBackend {
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
            // Выборка по идентификаторам — отдельная ветка, как у настоящей
            // подложки: сплошной текст сперва берёт метаданные всего файла,
            // а тексты страницы добирает **по id**. Без этой ветки
            // страницы приходили пустыми, и первый прогон проверки показал
            // ноль знаков документа — дефект был в самой проверке.
            if !request.ids.isEmpty {
                let found = try await client.getDocuments(
                    collectionID: collectionID, limit: request.ids.count, offset: 0,
                    ids: request.ids
                )
                return MCPDocumentsAnswer(
                    documents: found.map {
                        MCPDocumentPayload(id: $0.id, text: $0.document, metadata: $0.metadata)
                    },
                    hasMore: false
                )
            }
            let records = try await client.getDocuments(
                collectionID: collectionID, limit: max(request.limit, 1), offset: 0,
                filter: request.filter
            )
            let payloads = records.map {
                MCPDocumentPayload(id: $0.id, text: $0.document, metadata: $0.metadata)
            }
            let ordered = request.orderedByChunkIndex ? MCPFileChunks.ordered(payloads) : payloads
            let window = MCPFileChunks.page(ordered, offset: request.offset, limit: request.limit)
            let page = request.needsText ? window.page : window.page.map {
                MCPDocumentPayload(id: $0.id, text: nil, metadata: $0.metadata)
            }
            return MCPDocumentsAnswer(
                documents: page, hasMore: window.hasMore, total: ordered.count
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

private extension String {
    /// Все вхождения подстроки — для счёта меток в собранном тексте.
    func ranges(ofPattern pattern: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var from = startIndex
        while let next = range(of: pattern, range: from..<endIndex) {
            found.append(next)
            from = next.upperBound
        }
        return found
    }
}
