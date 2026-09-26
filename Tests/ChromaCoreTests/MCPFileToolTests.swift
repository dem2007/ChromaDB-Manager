import XCTest
@testable import ChromaCore

/// `get_file` — чанки одного файла по порядку и страницами.
///
/// Вопрос, из которого это выросло: «может ли приложение отдать агенту все
/// чанки конкретного файла». Могло — фильтром по `source_file`, — но порядка
/// у такой выдачи нет: `get` у ChromaDB его не обещает, а листание `offset`-ом
/// по неупорядоченному набору способно и пропустить кусок, и повторить его.
final class MCPFileToolTests: XCTestCase {
    // MARK: - Порядок и окно (чистая часть)

    private func chunk(_ id: String, index: Int?, text: String = "текст") -> MCPDocumentPayload {
        var metadata: ChromaMetadata = ["source_file": .string("папка/файл.md")]
        if let index { metadata[MCPFileChunks.orderKey] = .int(index) }
        return MCPDocumentPayload(id: id, text: text, metadata: metadata)
    }

    func testChunksComeBackInTheOrderTheFileWasCutIn() {
        let scrambled = [chunk("c", index: 2), chunk("a", index: 0), chunk("b", index: 1)]
        XCTAssertEqual(MCPFileChunks.ordered(scrambled).map(\.id), ["a", "b", "c"])
    }

    /// Десятый чанк идёт после девятого, а не после первого: сортировка
    /// числовая, а не по строке идентификатора.
    func testTheOrderIsNumericNotAlphabetical() {
        let documents = (0...12).map { (number: Int) in chunk("id-\(number)", index: number) }.shuffled()
        XCTAssertEqual(
            MCPFileChunks.ordered(documents).compactMap { MCPFileChunks.index(of: $0) },
            Array(0...12)
        )
    }

    /// Документ без `chunk_index` — не наш: его записал агент или импорт.
    /// Он уходит в конец, а не притворяется первым.
    func testDocumentsWithoutAChunkIndexGoLast() {
        let documents = [chunk("z", index: nil), chunk("a", index: 5), chunk("y", index: nil)]
        XCTAssertEqual(MCPFileChunks.ordered(documents).map(\.id), ["a", "y", "z"])
    }

    func testPagingIsDeterministicAndSaysWhenThereIsMore() {
        let documents = (0..<7).map { (number: Int) in chunk("id-\(number)", index: number) }
        let first = MCPFileChunks.page(documents, offset: 0, limit: 3)
        XCTAssertEqual(first.page.map(\.id), ["id-0", "id-1", "id-2"])
        XCTAssertTrue(first.hasMore)

        let last = MCPFileChunks.page(documents, offset: 6, limit: 3)
        XCTAssertEqual(last.page.map(\.id), ["id-6"])
        XCTAssertFalse(last.hasMore, "за последней страницей ничего нет")

        XCTAssertTrue(MCPFileChunks.page(documents, offset: 99, limit: 3).page.isEmpty)
    }

    // MARK: - Инструмент целиком

    private let key = "секретный-ключ"

    private struct Backend: MCPToolBackend {
        var chunks: [MCPDocumentPayload]
        var orderUnavailable = false
        final class Received: @unchecked Sendable {
            var documents: MCPDocumentsRequest?
        }
        let received = Received()

        func collections(allowed: [String]) async throws -> [MCPCollectionSummary] {
            [MCPCollectionSummary(name: "заметки", documentCount: chunks.count, model: "bge-m3", metric: "cosine", dimension: 8)]
        }

        func describe(collection: String) async throws -> MCPCollectionDescription {
            MCPCollectionDescription(
                summary: try await collections(allowed: [collection])[0],
                fields: [], hasSchema: false, allowsExtraFields: true
            )
        }

        func search(_ request: MCPSearchRequest) async throws -> MCPSearchAnswer {
            MCPSearchAnswer(documents: [], metric: "cosine", model: "bge-m3")
        }

        /// Ведёт себя как настоящий бэкенд: упорядочивает и режет окном.
        func documents(_ request: MCPDocumentsRequest) async throws -> MCPDocumentsAnswer {
            received.documents = request
            let ordered = request.orderedByChunkIndex ? MCPFileChunks.ordered(chunks) : chunks
            let window = MCPFileChunks.page(ordered, offset: request.offset, limit: request.limit)
            return MCPDocumentsAnswer(
                documents: window.page, hasMore: window.hasMore,
                total: request.orderedByChunkIndex ? ordered.count : nil,
                orderUnavailable: orderUnavailable
            )
        }

        func add(_ request: MCPAddRequest) async throws -> MCPAddAnswer {
            MCPAddAnswer(ids: [], model: "bge-m3")
        }

        func delete(_ request: MCPDeleteRequest) async throws -> MCPDeleteAnswer {
            MCPDeleteAnswer(deleted: [], missing: [], keptInTrash: false)
        }
    }

    private func service(
        _ backend: Backend, maxResults: Int? = nil, documentCharacters: Int? = nil
    ) async -> MCPToolService {
        let client = ExternalClient(
            name: "агент",
            keyHash: ClientKey.hash(key),
            keyPrefix: String(key.prefix(4)),
            permissions: ClientPermissions(
                collections: ["заметки"],
                requestsPerMinute: 600, burst: 600,
                maxSearchResults: maxResults,
                maxDocumentCharacters: documentCharacters
            )
        )
        let access = AccessController()
        await access.setClients([client])
        return MCPToolService(backend: backend, access: access, isReadOnlyServer: { false })
    }

    private func call(
        _ service: MCPToolService, _ arguments: [String: JSONValue]
    ) async throws -> JSONValue {
        // Ветка кусков называется явно: с этой правки умолчание
        // `get_file` — сплошной текст, а проверки ниже написаны про страницы
        // чанков. Подставляется только там, где вызов сам не назвал «as» и не
        // просит карту, — иначе проверка умолчания проверяла бы подстановку.
        var arguments = arguments
        if arguments["as"] == nil, arguments["outline"] == nil {
            arguments["as"] = .string("chunks")
        }
        return try await service.call(
            name: MCPToolCatalogue.getFile.name, arguments: .object(arguments), key: key
        ).get()
    }

    func testTheToolReturnsTheFileInOrderWithATotalAndTheNextOffset() async throws {
        let backend = Backend(chunks: (0..<7).map { (number: Int) in chunk("id-\(number)", index: number) }.shuffled())
        let service = await service(backend)

        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/файл.md"), "limit": .int(3),
        ])
        let structured = result["structuredContent"]
        XCTAssertEqual(structured?["file"]?.stringValue, "папка/файл.md")
        XCTAssertEqual(structured?["total"]?.intValue, 7)
        XCTAssertEqual(structured?["hasMore"]?.boolValue, true)
        XCTAssertEqual(structured?["nextOffset"]?.intValue, 3)
        XCTAssertEqual(
            structured?["documents"]?.arrayValue?.compactMap { $0["id"]?.stringValue },
            ["id-0", "id-1", "id-2"],
            "чанки обязаны идти по порядку файла"
        )
    }

    /// Фильтр строит приложение, а не агент: «файл целиком» — это ровно одно
    /// условие, и дописать к нему второе значит вернуть половину файла
    /// под видом целого.
    func testTheFilterIsBuiltByTheAppFromTheFileArgument() async throws {
        let backend = Backend(chunks: [chunk("id-0", index: 0)])
        let service = await service(backend)
        _ = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/файл.md"),
        ])

        let request = backend.received.documents
        XCTAssertEqual(request?.orderedByChunkIndex, true)
        XCTAssertEqual(request?.filter?.conditions.count, 1)
        XCTAssertEqual(request?.filter?.conditions.first?.field, "source_file")
        XCTAssertEqual(request?.filter?.conditions.first?.value, "папка/файл.md")
    }

    /// Файл ровно в предел упорядочивания — не переполнение.
    ///
    /// Счёт «набрано не меньше предела» не отличал файл, который на пределе
    /// кончился, от файла, который за ним продолжается. Первый объявлялся
    /// неупорядочиваемым: куски приходили вперемешку, а агент читал
    /// «в файле больше двадцати тысяч кусков» — которых в нём нет.
    func testAFileExactlyAtTheOrderingLimitIsNotCalledOverflowed() async throws {
        func page(_ from: Int, _ count: Int) -> [MCPDocumentPayload] {
            (from..<(from + count)).map {
                MCPDocumentPayload(id: "c\($0)", text: nil, metadata: [MCPFileChunks.orderKey: .int($0)])
            }
        }
        let limit = MCPFileChunks.maximumOrdered

        let exact = try await MCPFileChunks.collect(batch: MCPFileChunks.scanBatch) { batch, offset in
            offset >= limit ? [] : page(offset, min(batch, limit - offset))
        }
        XCTAssertEqual(exact.documents.count, limit)
        XCTAssertFalse(exact.overflowed, "файл кончился ровно на пределе — это не переполнение")

        // А тот, что за предел выходит, по-прежнему о себе говорит.
        let longer = try await MCPFileChunks.collect(batch: MCPFileChunks.scanBatch) { batch, offset in
            page(offset, batch)
        }
        XCTAssertTrue(longer.overflowed)
    }

    /// Смещение за концом файла — это смещение, а не пропавший файл.
    ///
    /// Раньше ответ гласил «в коллекции нет чанков с этим file_id» и советовал
    /// сменить отпечаток на путь: агент шёл чинить беду, которой нет, а в том
    /// же ответе стоял `total`. Чтение по разделу это говорит правильно
    /// с.
    func testAnOffsetPastTheEndSaysSoInsteadOfClaimingTheFileIsMissing() async throws {
        let backend = Backend(chunks: (0..<4).map { (number: Int) in chunk("id-\(number)", index: number) })
        let service = await service(backend)
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/файл.md"),
            "limit": .int(3), "offset": .int(40),
        ])
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("past its end"), text)
        XCTAssertFalse(text.contains("has no documents"), "файл на месте, и говорить обратное нельзя")
        XCTAssertFalse(text.contains("no chunks with file_id"), text)
        XCTAssertEqual(result["structuredContent"]?["total"]?.intValue, 4)
        XCTAssertEqual(result["structuredContent"]?["documents"]?.arrayValue?.count, 0)
    }

    /// «Влезает в один ответ» значит «весь файл здесь», а не «читать недорого».
    ///
    /// Поле стояло в `true` всюду, где приговор молчал, — а молчит он, пока
    /// вызовов меньше десяти. Файл на двадцать кусков, показанный по четыре,
    /// отвечал клиенту «влезает целиком», и `callsToReadWhole` не ставилось
    /// вовсе: узнать правду по структуре было неоткуда.
    func testAFileReadInSeveralCallsIsNotCalledWholeInOne() async throws {
        let backend = Backend(chunks: (0..<20).map { (number: Int) in chunk("id-\(number)", index: number) })
        let service = await service(backend)
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/файл.md"), "limit": .int(4),
        ])
        XCTAssertEqual(result["structuredContent"]?["fitsInOneAnswer"], .bool(false))
        XCTAssertEqual(result["structuredContent"]?["callsToFinish"], .int(4), "с нулевого смещения показано 4 из 20, дочитывать 16 — четыре вызова")
    }

    /// А когда весь файл действительно в ответе — `true`, и цены нет.
    func testAFileThatFitsWholeSaysSo() async throws {
        let backend = Backend(chunks: (0..<3).map { (number: Int) in chunk("id-\(number)", index: number) })
        let service = await service(backend)
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/файл.md"), "limit": .int(5),
        ])
        XCTAssertEqual(result["structuredContent"]?["fitsInOneAnswer"], .bool(true))
        XCTAssertNil(result["structuredContent"]?["callsToFinish"])
    }

    /// Пропавшему файлу «влезает целиком» не говорится вовсе: `0 >= 0` —
    /// правда, но о файле, которого в коллекции нет, она не значит ничего.
    func testAMissingFileIsNotCalledWholeEither() async throws {
        let service = await service(Backend(chunks: []))
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("нет/такого.md"),
        ])
        XCTAssertNil(result["structuredContent"]?["fitsInOneAnswer"])
    }

    /// Смещение за концом не делает файл влезающим: страница пуста, а в файле
    /// как была тысяча кусков, так и осталась.
    func testAnOffsetPastTheEndDoesNotCallTheFileSmall() async throws {
        let backend = Backend(chunks: (0..<20).map { (number: Int) in chunk("id-\(number)", index: number) })
        let service = await service(backend)
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/файл.md"),
            "limit": .int(4), "offset": .int(40),
        ])
        XCTAssertEqual(result["structuredContent"]?["fitsInOneAnswer"], .bool(false))
    }

    /// На последней странице приговор молчит: «читать так — двести пятьдесят
    /// семь вызовов» тому, кто дочитал тысячу двести семьдесят шесть, — это
    /// неправда о его положении, да ещё первой строкой. закрыл это
    /// у раздела и не перенёс сюда.
    func testTheLastPageOfAFileIsNotToldToGiveUp() async throws {
        let backend = Backend(chunks: (0..<200).map { (number: Int) in chunk("id-\(number)", index: number) })
        let service = await service(backend)
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/файл.md"),
            "limit": .int(4), "offset": .int(196),
        ])
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertFalse(text.contains("does not fit in one answer"), text)
        XCTAssertEqual(result["structuredContent"]?["hasMore"], .bool(false))
        XCTAssertNil(result["structuredContent"]?["callsToFinish"])
    }

    /// А с начала большого файла — говорит, и числом оставшегося.
    func testTheFirstPageOfALongFileStillWarns() async throws {
        let backend = Backend(chunks: (0..<200).map { (number: Int) in chunk("id-\(number)", index: number) })
        let service = await service(backend)
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/файл.md"),
            "limit": .int(4),
        ])
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.hasPrefix("This file does not fit in one answer as chunks"), text)
        XCTAssertTrue(text.contains("196 still unread"), text)
        XCTAssertEqual(result["structuredContent"]?["callsToFinish"], .int(49))
    }

    func testTheLastPageSaysTheFileIsFinished() async throws {
        let backend = Backend(chunks: (0..<4).map { (number: Int) in chunk("id-\(number)", index: number) })
        let service = await service(backend)
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/файл.md"),
            "limit": .int(3), "offset": .int(3),
        ])
        XCTAssertEqual(result["structuredContent"]?["hasMore"]?.boolValue, false)
        XCTAssertNil(result["structuredContent"]?["nextOffset"], "продолжать нечего")
    }

    /// Потолок объёма ответа обрывает страницу раньше, чем кончились чанки, —
    /// и тогда продолжать надо с того места, где оборвался **показ**, а не
    /// где кончилась выборка. Иначе агент теряет куски в середине файла.
    func testTruncationByResponseSizeMovesTheNextOffsetToWhatWasActuallyShown() async throws {
        let long = String(repeating: "щ", count: 3000)
        let backend = Backend(chunks: (0..<10).map { (number: Int) in chunk("id-\(number)", index: number, text: long) })
        let service = await service(backend, maxResults: 10)

        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/файл.md"), "limit": .int(10),
        ])
        let structured = result["structuredContent"]
        let shown = structured?["documents"]?.arrayValue?.count ?? 0
        XCTAssertLessThan(shown, 10, "24 000 символов на ответ не вмещают десять чанков по три тысячи")
        XCTAssertEqual(structured?["hasMore"]?.boolValue, true)
        XCTAssertEqual(structured?["nextOffset"]?.intValue, shown)
    }

    /// Потолки символов теперь принадлежат ключу: подняли — и файл приезжает
    /// за меньшее число вызовов.
    func testTheCharacterCeilingsComeFromTheKey() {
        let permissions = ClientPermissions(maxDocumentCharacters: 12_000, maxResponseCharacters: 200_000)
        let limits = MCPOutputLimits.forClient(permissions)
        XCTAssertEqual(limits.documentCharacters, 12_000)
        XCTAssertEqual(limits.responseCharacters, 200_000)

        let byDefault = MCPOutputLimits.forClient(ClientPermissions())
        XCTAssertEqual(byDefault.documentCharacters, MCPOutputLimits.defaultDocumentCharacters)
        XCTAssertEqual(byDefault.responseCharacters, MCPOutputLimits.defaultResponseCharacters)
    }

    /// Файл длиннее, чем приложение готово упорядочить, — об этом говорится,
    /// а не умалчивается: агент, склеивающий куски, обязан знать, что порядок
    /// не гарантирован.
    func testAFileTooBigToOrderSaysSo() async throws {
        var backend = Backend(chunks: (0..<3).map { (number: Int) in chunk("id-\(number)", index: number) })
        backend.orderUnavailable = true
        let service = await service(backend)
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("папка/файл.md"),
        ])
        let notes = result["structuredContent"]?["notes"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        XCTAssertTrue(notes.contains { $0.contains("arbitrary order") }, "\(notes)")
    }

    func testAnUnknownFileIsAnAnswerNotAnError() async throws {
        let backend = Backend(chunks: [])
        let service = await service(backend)
        let result = try await call(service, [
            "collection": .string("заметки"), "file": .string("нет/такого.md"),
        ])
        XCTAssertEqual(result["isError"]?.boolValue, false)
        XCTAssertTrue(
            result["content"]?[0]?["text"]?.stringValue?.contains("source_file") ?? false,
            "надо подсказать, откуда берётся путь"
        )
    }

    func testTheFileArgumentIsRequired() async {
        let service = await service(Backend(chunks: []))
        let result = await service.call(
            name: MCPToolCatalogue.getFile.name,
            arguments: .object(["collection": .string("заметки")]),
            key: key
        )
        guard case .failure(let error) = result else {
            return XCTFail("вызов без «file» обязан быть отвергнут")
        }
        XCTAssertEqual(error.code, -32602)
    }
}

/// Поиск сразу по нескольким коллекциям через MCP.
final class MCPMultiCollectionToolTests: XCTestCase {
    private let key = "ключ-агента"

    private struct Backend: MCPToolBackend {
        final class Received: @unchecked Sendable {
            var search: MCPSearchRequest?
        }
        let received = Received()

        func collections(allowed: [String]) async throws -> [MCPCollectionSummary] {
            allowed.map { MCPCollectionSummary(name: $0, documentCount: 1, model: "bge-m3", metric: "cosine", dimension: 8) }
        }
        func describe(collection: String) async throws -> MCPCollectionDescription {
            MCPCollectionDescription(
                summary: MCPCollectionSummary(name: collection, documentCount: 1, model: nil, metric: nil, dimension: nil),
                fields: [], hasSchema: false, allowsExtraFields: true
            )
        }
        func search(_ request: MCPSearchRequest) async throws -> MCPSearchAnswer {
            received.search = request
            return MCPSearchAnswer(
                documents: request.collections.map { name in
                    MCPDocumentPayload(
                        id: "\(name)-1", text: "текст из \(name)", metadata: nil,
                        distance: 0.1, collection: request.isMultiCollection ? name : nil
                    )
                },
                metric: request.isMultiCollection ? nil : "cosine",
                model: "bge-m3"
            )
        }
        func documents(_ request: MCPDocumentsRequest) async throws -> MCPDocumentsAnswer {
            MCPDocumentsAnswer(documents: [], hasMore: false)
        }
        func add(_ request: MCPAddRequest) async throws -> MCPAddAnswer { MCPAddAnswer(ids: [], model: nil) }
        func delete(_ request: MCPDeleteRequest) async throws -> MCPDeleteAnswer {
            MCPDeleteAnswer(deleted: [], missing: [], keptInTrash: false)
        }
    }

    private func service(
        _ backend: Backend, collections: [String] = ["доки", "код", "заметки"], maxCollections: Int? = nil
    ) async -> MCPToolService {
        let client = ExternalClient(
            name: "агент", keyHash: ClientKey.hash(key), keyPrefix: String(key.prefix(4)),
            permissions: ClientPermissions(
                collections: collections, requestsPerMinute: 600, burst: 600,
                maxSearchCollections: maxCollections
            )
        )
        let access = AccessController()
        await access.setClients([client])
        return MCPToolService(backend: backend, access: access, isReadOnlyServer: { false })
    }

    private func call(
        _ service: MCPToolService, _ arguments: [String: JSONValue]
    ) async -> Result<JSONValue, JSONRPCError> {
        await service.call(name: MCPToolCatalogue.search.name, arguments: .object(arguments), key: key)
    }

    func testTheAgentCanSearchSeveralCollectionsAtOnce() async throws {
        let backend = Backend()
        let service = await service(backend)
        let result = try await call(service, [
            "collections": .array([.string("доки"), .string("код")]),
            "query": .string("резервное копирование"),
        ]).get()

        XCTAssertEqual(backend.received.search?.collections, ["доки", "код"])
        let structured = result["structuredContent"]
        XCTAssertEqual(
            structured?["collections"]?.arrayValue?.compactMap { $0.stringValue }, ["доки", "код"]
        )
        // Из какой коллекции каждый результат — иначе агент не сможет
        // ни дочитать документ, ни объяснить, откуда он это взял.
        XCTAssertEqual(
            structured?["documents"]?.arrayValue?.compactMap { $0["collection"]?.stringValue },
            ["доки", "код"]
        )
    }

    /// Одно имя на выдачу из трёх коллекций — это неверный ответ: по нему
    /// агент пойдёт дочитывать документ не туда. Коллекция у каждого
    /// результата своя, а общего поля нет вовсе — схема его и не требует.
    func testTheAnswerNamesNoSingleCollectionWhenSeveralWereSearched() async throws {
        let backend = Backend()
        let service = await service(backend)
        let result = try await call(service, [
            "collections": .array([.string("доки"), .string("код")]),
            "query": .string("запрос"),
        ]).get()
        XCTAssertNil(result["structuredContent"]?["collection"])
    }

    /// Одна коллекция — как было: никакого списка в ответе, метрика на месте.
    func testASingleCollectionSearchIsUnchanged() async throws {
        let backend = Backend()
        let service = await service(backend)
        let result = try await call(service, [
            "collection": .string("доки"), "query": .string("запрос"),
        ]).get()
        XCTAssertEqual(backend.received.search?.collections, ["доки"])
        XCTAssertNil(result["structuredContent"]?["collections"])
        XCTAssertEqual(result["structuredContent"]?["collection"]?.stringValue, "доки")
        XCTAssertEqual(result["structuredContent"]?["metric"]?.stringValue, "cosine")
    }

    /// Список коллекций принимает **только** поиск. У остальных инструментов
    /// он не должен снимать проверку «не указана коллекция»: вызов ушёл бы
    /// дальше с пустым именем и упал как «Коллекция «» не найдена» — отказ,
    /// по которому агенту нечего исправлять.
    func testCollectionsDoesNotStandInForCollectionInOtherTools() async {
        let service = await service(Backend())
        for tool in [MCPToolCatalogue.getFile.name, MCPToolCatalogue.getDocuments.name] {
            let result = await service.call(
                name: tool,
                arguments: .object([
                    "collections": .array([.string("доки")]),
                    "file": .string("отчёт.md"),
                ]),
                key: key
            )
            guard case .failure(let error) = result else {
                XCTFail("\(tool): надо отказать до обращения к базе")
                continue
            }
            XCTAssertEqual(error.code, -32602)
            XCTAssertTrue(error.message.contains("collection"), "\(tool): \(error.message)")
        }
    }

    func testBothParametersAtOnceAreRefused() async {
        let result = await call(await service(Backend()), [
            "collection": .string("доки"),
            "collections": .array([.string("код")]),
            "query": .string("запрос"),
        ])
        guard case .failure(let error) = result else { return XCTFail("надо отказать") }
        XCTAssertEqual(error.code, -32602)
        XCTAssertTrue(error.message.contains("keep one of them"), error.message)
    }

    /// Коллекция вне списка доступа не ищется — и вызов отвергается целиком,
    /// а не молча урезается: «нашлось три документа» вместо «сюда нельзя» —
    /// это неверный ответ, а не ограничение.
    func testACollectionOutsideTheWhitelistRefusesTheWholeCall() async throws {
        let backend = Backend()
        let service = await service(backend, collections: ["доки"])
        let result = try await call(service, [
            "collections": .array([.string("доки"), .string("чужая")]),
            "query": .string("запрос"),
        ]).get()

        XCTAssertEqual(result["isError"]?.boolValue, true)
        XCTAssertTrue(
            result["content"]?[0]?["text"]?.stringValue?.contains("чужая") ?? false,
            "надо назвать, какая именно коллекция закрыта"
        )
        XCTAssertNil(backend.received.search, "до базы такой вызов доходить не должен")
    }

    func testTheNumberOfCollectionsIsCappedByTheKeyAndSaidOutLoud() async throws {
        let backend = Backend()
        let service = await service(backend, maxCollections: 2)
        let result = try await call(service, [
            "collections": .array([.string("доки"), .string("код"), .string("заметки")]),
            "query": .string("запрос"),
        ]).get()

        XCTAssertEqual(backend.received.search?.collections, ["доки", "код"])
        let notes = result["structuredContent"]?["notes"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        XCTAssertTrue(notes.contains { $0.contains("ceiling") }, "\(notes)")
    }

    func testRepeatedNamesAreCollapsed() async throws {
        let backend = Backend()
        let service = await service(backend)
        _ = try await call(service, [
            "collections": .array([.string("доки"), .string("доки"), .string("код")]),
            "query": .string("запрос"),
        ]).get()
        XCTAssertEqual(backend.received.search?.collections, ["доки", "код"], "повтор — это лишний поиск")
    }

    func testNeitherParameterIsRefusedWithAnUnderstandableReason() async {
        let result = await call(await service(Backend()), ["query": .string("запрос")])
        guard case .failure(let error) = result else { return XCTFail("надо отказать") }
        XCTAssertTrue(error.message.contains("collections"), error.message)
    }
}
