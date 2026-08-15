import XCTest
@testable import ChromaCore

/// «Последняя активность» ключа считается и по вызовам MCP.
///
/// Дефект, с которого это началось: карточка клиента говорила «ещё
/// не подключался» про ключ, которым минуту назад искали, — и говорила это
/// на том же экране, где ниже перечислены его вызовы. Отметку ставил только
/// прокси, а MCP-сервер — нет.
final class MCPClientSeenTests: XCTestCase {
    private let key = "ключ-агента"

    private struct Backend: MCPToolBackend {
        func collections(allowed: [String]) async throws -> [MCPCollectionSummary] {
            [MCPCollectionSummary(name: "заметки", documentCount: 1, model: nil, metric: nil, dimension: nil)]
        }
        func describe(collection: String) async throws -> MCPCollectionDescription {
            MCPCollectionDescription(
                summary: MCPCollectionSummary(name: collection, documentCount: 1, model: nil, metric: nil, dimension: nil),
                fields: [], hasSchema: false, allowsExtraFields: true
            )
        }
        func search(_ request: MCPSearchRequest) async throws -> MCPSearchAnswer {
            MCPSearchAnswer(documents: [], metric: nil, model: nil)
        }
        func documents(_ request: MCPDocumentsRequest) async throws -> MCPDocumentsAnswer {
            MCPDocumentsAnswer(documents: [], hasMore: false)
        }
        func add(_ request: MCPAddRequest) async throws -> MCPAddAnswer {
            MCPAddAnswer(ids: [], model: nil)
        }
        func delete(_ request: MCPDeleteRequest) async throws -> MCPDeleteAnswer {
            MCPDeleteAnswer(deleted: [], missing: [], keptInTrash: false)
        }
    }

    private final class Seen: @unchecked Sendable {
        var ids: [UUID] = []
    }

    private func service(_ seen: Seen, client: ExternalClient) async -> MCPToolService {
        let access = AccessController()
        await access.setClients([client])
        return MCPToolService(
            backend: Backend(), access: access,
            onClientSeen: { id in seen.ids.append(id) }
        )
    }

    private func client(enabled: Bool = true, write: Bool = false) -> ExternalClient {
        ExternalClient(
            name: "hermes",
            keyHash: ClientKey.hash(key),
            keyPrefix: String(key.prefix(4)),
            isEnabled: enabled,
            permissions: ClientPermissions(
                collections: ["заметки"], allowsWrite: write,
                requestsPerMinute: 600, burst: 600
            )
        )
    }

    func testASearchMarksTheKeyAsSeen() async throws {
        let seen = Seen()
        let client = client()
        let service = await service(seen, client: client)

        _ = try await service.call(
            name: MCPToolCatalogue.search.name,
            arguments: .object(["collection": .string("заметки"), "query": .string("отпуск")]),
            key: key
        ).get()

        XCTAssertEqual(seen.ids, [client.id], "ключ, которым только что искали, обязан считаться работавшим")
    }

    /// Отметка ставится по факту допуска, а не по успеху вызова: агент,
    /// которому отказали в записи, всё равно подключался.
    func testARefusedButRegisteredKeyStillCountsAsSeen() async throws {
        let seen = Seen()
        let client = client(write: false)
        let service = await service(seen, client: client)

        let result = try await service.call(
            name: MCPToolCatalogue.addDocuments.name,
            arguments: .object([
                "collection": .string("заметки"),
                "documents": .array([.object(["text": .string("текст")])]),
            ]),
            key: key
        ).get()

        XCTAssertEqual(result["isError"]?.boolValue, true, "записи нет — отказ")
        XCTAssertEqual(seen.ids, [client.id])
    }

    /// А вот чужой ключ активностью не считается: иначе перебор ключей
    /// оставлял бы на карточках следы работы, которой не было.
    func testAnUnknownKeyIsNotCountedAsActivity() async {
        let seen = Seen()
        let service = await service(seen, client: client())
        _ = await service.call(
            name: MCPToolCatalogue.search.name,
            arguments: .object(["collection": .string("заметки"), "query": .string("что-нибудь")]),
            key: "чужой-ключ"
        )
        XCTAssertTrue(seen.ids.isEmpty)
    }

    func testADisabledKeyIsNotCountedEither() async {
        let seen = Seen()
        let service = await service(seen, client: client(enabled: false))
        _ = await service.call(
            name: MCPToolCatalogue.search.name,
            arguments: .object(["collection": .string("заметки"), "query": .string("что-нибудь")]),
            key: key
        )
        XCTAssertTrue(seen.ids.isEmpty, "выключенный ключ не работает — и следов работы оставлять не должен")
    }
}
