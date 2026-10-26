import XCTest
@testable import ChromaCore

/// `list_files`: что лежит в коллекции — по строке на файл, с ID, который
/// принимает `get_file`.
final class MCPListFilesTests: XCTestCase {
    private let key = "ключ-файлов"

    private struct Backend: MCPToolBackend {
        var chunks: [MCPDocumentPayload]

        static func chunk(_ path: String?, id: String?, index: Int, count: Int? = nil) -> MCPDocumentPayload {
            var metadata: ChromaMetadata = [MCPFileChunks.orderKey: .int(index)]
            if let path { metadata["source_file"] = .string(path) }
            if let id { metadata["file_id"] = .string(id) }
            if let count { metadata["chunk_count"] = .int(count) }
            return MCPDocumentPayload(id: "\(path ?? "-")#\(index)", text: "кусок \(index)", metadata: metadata)
        }

        static let sample: [MCPDocumentPayload] = [
            chunk("Договоры/2030/Договор.pdf", id: "aaaa", index: 0),
            chunk("Договоры/2030/Договор.pdf", id: "aaaa", index: 1),
            chunk("Договоры/2030/Договор.pdf", id: "aaaa", index: 2),
            chunk("Договоры/2031/Акт.docx", id: "bbbb", index: 0),
            chunk("Папка-соседка/Заметка.md", id: "cccc", index: 0),
            chunk("Старое/Отчёт.txt", id: nil, index: 0),
            chunk(nil, id: nil, index: 0),
        ]

        func collections(allowed: [String]) async throws -> [MCPCollectionSummary] {
            [MCPCollectionSummary(name: "заметки", documentCount: chunks.count, model: "e5", metric: "cosine", dimension: 8)]
        }
        func describe(collection: String) async throws -> MCPCollectionDescription {
            MCPCollectionDescription(
                summary: MCPCollectionSummary(name: collection, documentCount: chunks.count, model: "e5", metric: "cosine", dimension: 8),
                fields: [], hasSchema: false, allowsExtraFields: true
            )
        }
        func search(_ request: MCPSearchRequest) async throws -> MCPSearchAnswer {
            MCPSearchAnswer(documents: [], metric: "cosine", model: "e5")
        }
        func documents(_ request: MCPDocumentsRequest) async throws -> MCPDocumentsAnswer {
            let matched: [MCPDocumentPayload]
            if let condition = request.filter?.conditions.first {
                matched = chunks.filter {
                    guard case .string(let stored)? = $0.metadata?[condition.field] else { return false }
                    return stored == condition.value
                }
            } else {
                matched = chunks
            }
            let ordered = request.orderedByChunkIndex ? MCPFileChunks.ordered(matched) : matched
            let window = MCPFileChunks.page(ordered, offset: request.offset, limit: request.limit)
            return MCPDocumentsAnswer(
                documents: window.page, hasMore: window.hasMore,
                total: request.orderedByChunkIndex ? ordered.count : nil
            )
        }
        func add(_ request: MCPAddRequest) async throws -> MCPAddAnswer { MCPAddAnswer(ids: [], model: "e5") }
        func delete(_ request: MCPDeleteRequest) async throws -> MCPDeleteAnswer {
            MCPDeleteAnswer(deleted: [], missing: [], keptInTrash: true)
        }
    }

    private func service(
        _ chunks: [MCPDocumentPayload] = Backend.sample, collections: [String] = ["заметки"]
    ) async -> MCPToolService {
        let client = ExternalClient(
            name: "агент", keyHash: ClientKey.hash(key), keyPrefix: String(key.prefix(4)),
            permissions: ClientPermissions(collections: collections, burst: 100)
        )
        let access = AccessController()
        await access.setClients([client])
        return MCPToolService(backend: Backend(chunks: chunks), access: access)
    }

    private func call(_ service: MCPToolService, _ arguments: [String: JSONValue]) async throws -> (text: String, structured: JSONValue?) {
        let result = try await service.call(name: "list_files", arguments: .object(arguments), key: key).get()
        return (result["content"]?[0]?["text"]?.stringValue ?? "", result["structuredContent"])
    }

    private func paths(_ structured: JSONValue?) -> [String] {
        structured?["files"]?.arrayValue?.compactMap { $0["file"]?.stringValue } ?? []
    }

    /// Главное: каждый файл — одной строкой, с ID и числом кусков, а ID из
    /// ответа открывает в get_file ровно этот файл.
    func testEveryFileIsListedOnceAndItsIDOpensIt() async throws {
        let service = await service()
        let answer = try await call(service, ["collection": .string("заметки")])
        XCTAssertEqual(paths(answer.structured), [
            "Договоры/2030/Договор.pdf", "Договоры/2031/Акт.docx", "Папка-соседка/Заметка.md", "Старое/Отчёт.txt",
        ])
        XCTAssertEqual(answer.structured?["totalFiles"], .int(4))
        XCTAssertEqual(answer.structured?["totalChunks"], .int(7))
        XCTAssertEqual(answer.structured?["withoutFile"], .int(1))
        XCTAssertEqual(answer.structured?["hasMore"], .bool(false))
        let contract = try XCTUnwrap(answer.structured?["files"]?.arrayValue?.first)
        XCTAssertEqual(contract["fileId"], .string("aaaa"))
        XCTAssertEqual(contract["chunks"], .int(3))
        XCTAssertTrue(answer.text.contains("file_id aaaa · 3 chunks"), answer.text)
        XCTAssertTrue(answer.text.contains("no file_id"), "файл ранней сборки назван без ID")
        XCTAssertTrue(answer.text.contains("Give the path to get_file as «file»"), answer.text)
        XCTAssertTrue(answer.text.contains("1 record carries no source file"), answer.text)

        let file = try await service.call(
            name: "get_file", arguments: .object(["collection": .string("заметки"), "file_id": .string("aaaa")]), key: key
        ).get()
        let fileText = file["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(fileText.contains("Договоры/2030/Договор.pdf"), fileText)
    }

    /// «name» — часть имени или пути без учёта регистра и «ё»; «folder» —
    /// начало пути целыми папками: «Папка» не берёт «Папка-соседка».
    func testNameAndFolderNarrowTheList() async throws {
        let service = await service()
        let byName = try await call(service, ["collection": .string("заметки"), "name": .string("ОТЧЕТ")])
        XCTAssertEqual(paths(byName.structured), ["Старое/Отчёт.txt"])
        let byFolder = try await call(service, ["collection": .string("заметки"), "folder": .string("/договоры/")])
        XCTAssertEqual(paths(byFolder.structured), ["Договоры/2030/Договор.pdf", "Договоры/2031/Акт.docx"])
        let partial = try await call(service, ["collection": .string("заметки"), "folder": .string("Папка")])
        XCTAssertEqual(paths(partial.structured), [], "папка — целиком, а не начало её имени")
        XCTAssertTrue(partial.text.contains("No file of the collection"), partial.text)
    }

    /// Страницы: продолжение названо смещением, за концом — прямо сказано.
    func testPagingNamesTheNextOffset() async throws {
        let service = await service()
        let first = try await call(service, ["collection": .string("заметки"), "limit": .int(2), "sort": .string("chunks")])
        XCTAssertEqual(paths(first.structured).first, "Договоры/2030/Договор.pdf", "крупнейший — первым")
        XCTAssertEqual(first.structured?["hasMore"], .bool(true))
        XCTAssertTrue(first.text.contains("continue with offset 2"), first.text)
        let past = try await call(service, ["collection": .string("заметки"), "offset": .int(10)])
        XCTAssertEqual(paths(past.structured), [])
        XCTAssertTrue(past.text.contains("already past the end"), past.text)
    }

    func testABadSortIsRefusedWithTheAllowedValues() async throws {
        let service = await service()
        let result = await service.call(
            name: "list_files", arguments: .object(["collection": .string("заметки"), "sort": .string("size")]), key: key
        )
        let message: String
        switch result {
        case .success(let value): message = value["content"]?[0]?["text"]?.stringValue ?? ""
        case .failure(let error): message = error.message
        }
        XCTAssertTrue(message.contains("«path», «chunks», «modified»"), message)
    }

    /// Ключ без этой коллекции списка не получает — как и у остальных
    /// инструментов с коллекцией.
    func testAKeyWithoutTheCollectionIsRefused() async throws {
        let service = await service(collections: ["другая"])
        let answer = try await call(service, ["collection": .string("заметки")])
        XCTAssertNil(answer.structured?["files"])
        XCTAssertFalse(answer.text.contains("Договор.pdf"), answer.text)
    }

    /// Пометки платят из бюджета ответа: страница с файлами без ID,
    /// записями без файла и продолжением укладывается в потолок ключа.
    func testThePageWithAllItsNotesStaysUnderTheCeiling() async throws {
        let chunks = (0..<400).map { index in
            Backend.chunk("Папка-\(index % 7)/Документ номер \(index).txt", id: nil, index: 0)
        } + [Backend.chunk(nil, id: nil, index: 0)]
        let ceiling = 3_000
        let client = ExternalClient(
            name: "агент", keyHash: ClientKey.hash(key), keyPrefix: String(key.prefix(4)),
            permissions: ClientPermissions(collections: ["заметки"], burst: 100, maxResponseCharacters: ceiling)
        )
        let access = AccessController()
        await access.setClients([client])
        let service = MCPToolService(backend: Backend(chunks: chunks), access: access)
        let result = try await service.call(
            name: "list_files", arguments: .object(["collection": .string("заметки"), "limit": .int(500)]), key: key
        ).get()
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        let mirror = result["structuredContent"].map { $0.deliveredSize } ?? 0
        XCTAssertTrue(text.contains("continue with offset"), text)
        XCTAssertTrue(text.contains("no file_id"), text)
        XCTAssertLessThanOrEqual(text.count + mirror, ceiling, "текст \(text.count) + зеркало \(mirror)")
    }

    /// Список в памяти снимается записью в коллекцию и сменой счёта.
    func testTheRememberedListGoesStaleOnWritesAndCountChanges() {
        let cache = MCPFileChunkCache()
        let key = MCPFileChunkCache.Key(collectionID: "col", filter: nil)
        var grouping = CollectionFiles.Grouping()
        grouping.take(["source_file": .string("a.txt"), "file_id": .string("a")])
        let list = grouping.list(documentCount: 1, builtAt: Date())

        cache.storeFileList(list, for: key, stamp: 1, ticket: cache.ticket(for: key), now: 0)
        XCTAssertNotNil(cache.fileList(for: key, stamp: 1, now: 10))
        XCTAssertNil(cache.fileList(for: key, stamp: 2, now: 10), "другой счёт — другая коллекция")

        cache.storeFileList(list, for: key, stamp: 1, ticket: cache.ticket(for: key), now: 0)
        cache.invalidate(collectionID: "col")
        XCTAssertNil(cache.fileList(for: key, stamp: 1, now: 10), "запись через приложение снимает список")

        let ticket = cache.ticket(for: key)
        cache.invalidate(collectionID: "col")
        cache.storeFileList(list, for: key, stamp: 1, ticket: ticket, now: 0)
        XCTAssertNil(cache.fileList(for: key, stamp: 1, now: 10), "обход, начатый до записи, не запоминается")

        cache.storeFileList(list, for: key, stamp: 1, ticket: cache.ticket(for: key), now: 0)
        XCTAssertNil(cache.fileList(for: key, stamp: 1, now: MCPFileChunkCache.listLifetime + 1), "срок жизни")
    }
}
