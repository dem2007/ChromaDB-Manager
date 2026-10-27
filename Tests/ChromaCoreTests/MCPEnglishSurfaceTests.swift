import XCTest
@testable import ChromaCore

/// Текст, который MCP-сервер отдаёт модели, — по-английски.
///
/// Сторож заведён после того, как одно и то же нарушение всплыло четырежды и
/// каждый раз его находила живая проверка, а не тесты: объявил ответ
/// английским, нашёл русские отказы в `AccessController`, — русскую
/// подсказку при рукопожатии, разбор кода — русскую заметку о конвейере.
/// Проверки на подстроки такое не ловят: они смотрят, что ответ содержит нужное
/// слово, а не что в нём нет лишнего языка.
///
/// Кириллица разрешена ровно там, где это **данные**, а не обвязка: основы для
/// `contains` и имена колонок — буквальные подстроки корпуса, и по-английски
/// они ничего не найдут.
final class MCPEnglishSurfaceTests: XCTestCase {

    /// Куски корпуса, которые обязаны остаться русскими.
    ///
    /// Список закрытый нарочно: новая русская строка не притворится примером,
    /// пока её сюда не впишут руками — а вписывая, придётся объяснить, зачем.
    private static let allowed = [
        "приемк", "приемка", "приемки", "приемке",
        "резервн", "резервное копирование",
        "стоимость_тыс_руб", "стоимость", "тыс", "руб", "итого",
        "экранная форма",
    ]

    /// От длинных к коротким: иначе «приемк» съедает начало «приемки» и
    /// оставляет хвост «и», который выглядит как нарушение. Порядок постоянный,
    /// поэтому считается один раз, а не на каждый вызов.
    private static let allowedLongestFirst = allowed.sorted { $0.count > $1.count }

    static func cyrillicRuns(in text: String) -> [String] {
        var stripped = text
        for sample in allowedLongestFirst {
            stripped = stripped.replacingOccurrences(of: sample, with: " ")
        }
        // Тот же список букв, что вычёркивает боевой код: две копии
        // разошлись бы, и проверка судила бы не по той мерке.
        return stripped
            .components(separatedBy: MCPToolService.cyrillic.inverted)
            .filter { !$0.isEmpty }
    }

    /// Описания инструментов и схемы параметров — то, что модель читает раньше
    /// всего остального.
    func testToolCatalogueCarriesNoRussianOutsideDataSamples() {
        for tool in MCPToolCatalogue.all {
            for (label, text) in [
                ("title", tool.title),
                ("description", tool.description),
                ("inputSchema", String(describing: tool.inputSchema)),
                ("outputSchema", tool.outputSchema.map { String(describing: $0) } ?? ""),
            ] {
                let found = Self.cyrillicRuns(in: text)
                XCTAssertTrue(
                    found.isEmpty,
                    "\(tool.name).\(label): русский текст вне примеров данных — \(found.prefix(5))"
                )
            }
        }
    }

    /// Имена инструментов протокол требует машинные; кириллица в них сломала бы
    /// и вызов, и приставку `mcp__chromadb_manager__`.
    func testToolNamesAreASCII() {
        for tool in MCPToolCatalogue.all {
            XCTAssertTrue(
                tool.name.allSatisfy { $0.isASCII },
                "\(tool.name): имя инструмента обязано быть машинным"
            )
        }
    }

    /// Отказы MCP-транспорта. Их читает модель и по ним решает, что делать
    /// дальше, — значит и они по-английски.
    func testToolRefusalsAreEnglish() async {
        let controller = AccessController()
        let client = ExternalClient(
            name: "guard",
            keyHash: ClientKey.hash("k"),
            keyPrefix: "k",
            permissions: ClientPermissions(collections: ["open"], allowsWrite: false)
        )
        await controller.setClients([client])

        // Ключа нет, ключ чужой, коллекция закрыта, записи не разрешено —
        // четыре отказа, каждый со своим текстом.
        var refusals: [String] = []
        for decision in [
            await controller.decideTool(
                key: nil, permission: .read, collection: nil, isReadOnlyServer: false
            ),
            await controller.decideTool(
                key: "чужой", permission: .read, collection: nil, isReadOnlyServer: false
            ),
            await controller.decideTool(
                key: "k", permission: .read, collection: "закрытая", isReadOnlyServer: false
            ),
            await controller.decideTool(
                key: "k", permission: .write, collection: "open", isReadOnlyServer: false
            ),
        ] {
            if let refusal = decision.refusal { refusals.append(refusal) }
        }

        XCTAssertEqual(refusals.count, 4, "каждый из четырёх случаев обязан объяснить отказ")
        for refusal in refusals {
            // Имя коллекции сервер повторяет как есть: оно пришло от агента и
            // может быть любым. Ключ не повторяется нарочно — чтобы неверный
            // ключ не отражался обратно, — поэтому вычёркивать его не нужно.
            let frame = refusal.replacingOccurrences(of: "закрытая", with: "")
            XCTAssertTrue(
                Self.cyrillicRuns(in: frame).isEmpty,
                "отказ MCP по-русски: \(refusal)"
            )
        }
    }
}

/// Тот же запрет — но на **собранных ответах**, а не на определениях.
///
/// Разбор показал, где ошибка живёт на самом деле: описания инструментов
/// были английскими уже давно, а по-русски приходили заголовки выдачи, пометки
/// об обрезке, отказы записи и заметка о конвейере — всё, что склеивается в
/// момент вызова. Проверять определения и не проверять ответы значит стеречь
/// не ту дверь.
///
/// Данные заглушка отдаёт латиницей нарочно: тогда любая кириллица в готовом
/// ответе — обвязка, а не содержимое документа.
final class MCPAnswerSurfaceTests: XCTestCase {
    private let key = "surface-key"

    private struct Backend: MCPToolBackend {
        func collections(allowed: [String]) async throws -> [MCPCollectionSummary] {
            [MCPCollectionSummary(
                name: "notes", documentCount: 2048, model: "e5", metric: "cosine", dimension: 3
            )]
        }
        func describe(collection: String) async throws -> MCPCollectionDescription {
            MCPCollectionDescription(
                summary: MCPCollectionSummary(
                    name: collection, documentCount: 2048, model: "e5", metric: "cosine", dimension: 3
                ),
                fields: [], hasSchema: false, allowsExtraFields: true
            )
        }
        func search(_ request: MCPSearchRequest) async throws -> MCPSearchAnswer {
            MCPSearchAnswer(
                documents: [MCPDocumentPayload(
                    id: "one", text: "plain latin text", metadata: [:], distance: 0.1
                )],
                metric: "cosine", model: "e5"
            )
        }
        func documents(_ request: MCPDocumentsRequest) async throws -> MCPDocumentsAnswer {
            MCPDocumentsAnswer(
                // Латинский source_file: по нему collect_mentions группирует
                // файлы, а get_file собирает заголовок. Путей много и они
                // длинные нарочно: на одном файле перечень копеечный, и то,
                // что его зеркало не оплачено бюджетом, остаётся невидимым —
                // ровно так дыра и дожила до живого прогона на семидесяти
                // файлах.
                documents: (1...2048).map { number in
                    MCPDocumentPayload(
                        id: "id-\(number)", text: "plain latin text",
                        metadata: ["source_file": .string(
                            "latin/department/section-\(number % 200)/very-long-document-name-\(number % 200).docx"
                        )],
                        distance: nil
                    )
                },
                hasMore: true
            )
        }
        func add(_ request: MCPAddRequest) async throws -> MCPAddAnswer {
            MCPAddAnswer(ids: (1...2048).map { "id-\($0)" }, model: "e5")
        }
        func delete(_ request: MCPDeleteRequest) async throws -> MCPDeleteAnswer {
            MCPDeleteAnswer(deleted: ["one"], missing: ["two"], keptInTrash: true)
        }
    }

    /// Права сервиса и потолок, по которому его судят, — из одного места:
    /// разойдись они, проверка мерила бы ответ чужой меркой.
    /// `maxSearchResults: 100` — как у настоящего ключа. С умолчанием в десять
    /// перечень файлов выходит копеечным, и то, что его зеркало не оплачено
    /// бюджетом, остаётся невидимым: живой прогон на семидесяти файлах дал
    /// 30 174 при потолке 24 000, а сторож с десятью молчал.
    private static let permissions = ClientPermissions(
        collections: ["notes"], allowsWrite: true,
        maxSearchResults: 100, allowsDelete: true
    )

    private func service() async -> MCPToolService {
        let client = ExternalClient(
            name: "surface",
            keyHash: ClientKey.hash(key),
            keyPrefix: "surf",
            permissions: Self.permissions
        )
        let access = AccessController()
        await access.setClients([client])
        return MCPToolService(backend: Backend(), access: access)
    }

    static func anyCyrillic(_ text: String) -> String {
        String(text.filter {
            ("а"..."я").contains($0) || ("А"..."Я").contains($0) || $0 == "ё" || $0 == "Ё"
        })
    }

    private func text(of result: JSONValue) -> String {
        result["content"]?.arrayValue?
            .compactMap { $0["text"]?.stringValue }
            .joined(separator: "\n") ?? ""
    }

    /// Ошибка приложения не протаскивает русский текст в английский ответ.
    ///
    /// Живой случай: `add_documents` на коллекции без привязанной модели —
    /// `BindingError` написан для человека у экрана и по-русски, а уходил
    /// модели внутрь английской обвязки.
    func testAnApplicationErrorDoesNotLeakRussianIntoTheAnswer() async throws {
        struct RussianError: LocalizedError {
            var errorDescription: String? { "Для коллекции «notes» не указана эмбеддинг-модель." }
        }
        struct FailingBackend: MCPToolBackend {
            func collections(allowed: [String]) async throws -> [MCPCollectionSummary] { throw RussianError() }
            func describe(collection: String) async throws -> MCPCollectionDescription { throw RussianError() }
            func search(_ request: MCPSearchRequest) async throws -> MCPSearchAnswer { throw RussianError() }
            func documents(_ request: MCPDocumentsRequest) async throws -> MCPDocumentsAnswer { throw RussianError() }
            func add(_ request: MCPAddRequest) async throws -> MCPAddAnswer { throw RussianError() }
            func delete(_ request: MCPDeleteRequest) async throws -> MCPDeleteAnswer { throw RussianError() }
        }
        let client = ExternalClient(
            name: "surface", keyHash: ClientKey.hash(key), keyPrefix: "surf",
            permissions: Self.permissions
        )
        let access = AccessController()
        await access.setClients([client])
        let service = MCPToolService(backend: FailingBackend(), access: access)

        let result = try await service.call(
            name: "add_documents",
            arguments: .object([
                "collection": .string("notes"),
                "documents": .array([.object(["text": .string("plain latin text")])]),
            ]),
            key: key
        ).get()

        let answer = text(of: result)
        XCTAssertEqual(result["isError"], .bool(true))
        XCTAssertEqual(Self.anyCyrillic(answer), "", "в ответе кириллица: \(answer)")
        XCTAssertTrue(answer.contains("add_documents"), answer)
    }

    /// Ошибки, с которыми агент сталкивается чаще всего, называют причину
    /// по-английски, а не отсылают в журнал.
    ///
    /// Без этого «LM Studio не запущена» превращалось в «загляните в журнал»:
    /// язык починен, а причина потеряна — а её агент обязан передать человеку.
    /// Русское имя коллекции в причине — это **данные**, и они обязаны доехать.
    ///
    /// Прежний сторож вычёркивал причину целиком, наткнувшись на кириллицу, —
    /// и «collection not found: заметки» превращалось в «спроси хозяина».
    /// Первое агент чинит сам одной попыткой, второе не чинит никак.
    func testAReasonSurvivesARussianCollectionName() {
        for error in [
            ChromaError.collectionNotFound("заметки"),
            BindingError.notBound(collection: "заметки"),
        ] as [any Error] {
            let text = MCPToolService.englishFailure(tool: "search", error: error)
            XCTAssertTrue(text.contains("заметки"), "имя коллекции потеряно: \(text)")
            XCTAssertFalse(
                text.contains("ask the person who runs it"),
                "причина подменена отговоркой: \(text)"
            )
        }
    }

    /// Отмена — не поломка.
    ///
    /// Без своей ветки `CancellationError` приезжала агенту как «сломалось
    /// внутри приложения, спроси хозяина», и агент слал человека чинить
    /// то, что не ломалось.
    func testCancellationIsNotReportedAsAFailure() {
        let text = MCPToolService.englishFailure(tool: "search", error: CancellationError())
        XCTAssertTrue(text.contains("cancelled"), "отмена не названа отменой: \(text)")
        XCTAssertFalse(
            text.contains("ask the person who runs it"),
            "отмена выдана за поломку приложения: \(text)"
        )
    }

    func testTheCommonFailuresNameTheirReasonInEnglish() {
        let errors: [any Error] = [
            LMStudioError.unreachable("connection refused", server: .lmStudio),
            LMStudioError.modelNotEmbedding("qwen3-chat"),
            ChromaError.unreachable(endpoint: "http://127.0.0.1:8000", reason: "connection refused"),
            ChromaError.collectionNotFound("notes"),
            ChromaError.api(status: 500, code: nil, message: "internal error"),
            BindingError.notBound(collection: "notes"),
            BindingError.modelUnavailable(model: "e5", server: .lmStudio),
            FilterError.invalidRawJSON("unexpected token"),
        ]
        for error in errors {
            let text = MCPToolService.englishFailure(tool: "search", error: error)
            XCTAssertEqual(Self.anyCyrillic(text), "", "кириллица в ответе: \(text)")
            XCTAssertFalse(
                text.contains("application log"),
                "причина подменена отсылкой в журнал: \(text)"
            )
            // Причина должна быть причиной, а не одним названием инструмента:
            // пустой `mcpReason` прошёл бы обе проверки выше.
            XCTAssertGreaterThan(text.count, "The tool «search» failed: ".count + 10, text)
        }
    }

    /// Обещание протокола проверяется, а не принимается на слово: причина
    /// пишется руками, и русское слово в ней однажды появится.
    func testARussianReasonFromAConformanceDoesNotReachTheModel() {
        struct SloppyError: MCPReadableError {
            var mcpReason: String { "модель недоступна" }
        }
        let text = MCPToolService.englishFailure(tool: "search", error: SloppyError())
        XCTAssertEqual(Self.anyCyrillic(text), "", text)
        XCTAssertTrue(text.contains("application log"), text)
    }

    /// Английская причина проходит как есть: «collection not found: 404» модели
    /// полезнее общей отговорки.
    func testAnEnglishErrorIsPassedThrough() {
        struct PlainError: LocalizedError {
            var errorDescription: String? { "collection not found: 404" }
        }
        let text = MCPToolService.englishFailure(tool: "search", error: PlainError())
        XCTAssertTrue(text.contains("collection not found: 404"), text)
    }

    func testEveryToolAnswersInEnglish() async throws {
        let service = await service()
        let calls: [(String, JSONValue)] = [
            ("list_collections", .object([:])),
            ("describe_collection", .object(["collection": .string("notes")])),
            ("search", .object([
                "collection": .string("notes"), "query": .string("anything"),
                "n_results": .int(1),
            ])),
            ("get_documents", .object(["collection": .string("notes"), "limit": .int(1)])),
            ("add_documents", .object([
                "collection": .string("notes"),
                "documents": .array([.object(["text": .string("plain latin text")])]),
            ])),
            ("delete_documents", .object([
                "collection": .string("notes"),
                "ids": .array([.string("one"), .string("two")]),
            ])),
            ("get_file", .object([
                "collection": .string("notes"), "file_id": .string("latin/notes.txt"),
            ])),
            ("collect_mentions", .object([
                "collection": .string("notes"), "contains": .string("latin"),
            ])),
        ]
        for (name, arguments) in calls {
            let result = try await service.call(
                name: name, arguments: arguments, key: key
            ).get()
            let answer = text(of: result)
            XCTAssertFalse(answer.isEmpty, "\(name): ответ пуст")
            // Список поблажек тут не нужен и вреден: заглушка отдаёт одну
            // латиницу, поэтому любая кириллица — обвязка. Возьми мы список
            // из соседнего сторожа, «стоимость» или «итого» в заголовке
            // вычеркнулись бы и прошли незамеченными.
            XCTAssertTrue(
                Self.anyCyrillic(answer).isEmpty,
                "\(name): русский текст в собранном ответе — \(answer)"
            )
        }
    }

    /// Объявленный потолок ответа обязан покрывать **весь** ответ.
    ///
    /// Ответ уезжает к агенту дважды: текстом и зеркалом в `structuredContent`,
    /// а бюджет считал только текст. Измерено на живой базе до правки:
    /// 25 974 символа текста плюс 27 491 структуры — 54 365 при обещанных
    /// 24 000, вдвое с лишним. Из-за этого ответ не влезал в контекст, клиент
    /// сбрасывал его в файл, а агент разбирал текст самодельной регуляркой и
    /// ошибался в числах.
    func testAnswerFitsTheDeclaredCeilingWithStructuredContent() async throws {
        let service = await service()
        let ceiling = MCPOutputLimits.forClient(Self.permissions).responseCharacters

        // Заглушка отдаёт 2048 документов: без бюджета ответ разрастётся
        // настолько, что промах будет виден без всяких допусков.
        for (name, arguments) in [
            // Поиск — с шапкой и пометками, которые раньше прибавлялись
            // после рендера, мимо бюджета.
            ("search", JSONValue.object([
                "collection": .string("notes"), "query": .string("latin"), "n_results": .int(100),
            ])),
            ("get_documents", JSONValue.object(["collection": .string("notes"), "limit": .int(100)])),
            ("collect_mentions", .object([
                "collection": .string("notes"), "contains": .string("latin"), "limit": .int(100),
            ])),
        ] {
            let result = try await service.call(name: name, arguments: arguments, key: key).get()
            let textSize = text(of: result).count
            // Меряем настоящий JSON, а не отладочное описание Swift: у
            // `String(describing:)` на перечислении выходит вчетверо длиннее,
            // и промах был бы выдуман.
            let structuredSize = try result["structuredContent"].map {
                String(data: try JSONEncoder().encode($0), encoding: .utf8)?.count ?? 0
            } ?? 0
            XCTAssertLessThanOrEqual(
                textSize + structuredSize, ceiling,
                "\(name): весь ответ \(textSize + structuredSize) при потолке \(ceiling) — текст \(textSize), структура \(structuredSize)"
            )
        }
    }

    /// Урезанный перечень обязан сохранить **знаменатель**.
    ///
    /// Бюджет режет список файлов — на живой базе из семидесяти показывается
    /// сорок пять. Терпимо это ровно потому, что полное число остаётся:
    /// в заголовке, в `totalFiles` и в подсказке про `offset`. Считай тут
    /// `totalFiles` только показанные файлы — и знаменатель молча превратился
    /// бы в числитель, а вопрос «во всех ли» стал бы неотвечаемым.
    func testTrimmedListingKeepsTheTotalCount() async throws {
        let service = await service()
        let result = try await service.call(
            name: "collect_mentions",
            arguments: .object([
                "collection": .string("notes"), "contains": .string("latin"),
                "limit": .int(100), "per_file": .int(1),
            ]),
            key: key
        ).get()
        let structured = result["structuredContent"]
        guard case .array(let listed)? = structured?["files"],
              let total = structured?["totalFiles"]?.intValue else {
            return XCTFail("в ответе нет ни перечня, ни общего числа файлов")
        }
        XCTAssertLessThan(listed.count, total, "перечень обязан быть урезан — иначе случай не проверен")
        XCTAssertEqual(structured?["hasMore"]?.boolValue, true, "урезанный перечень обязан звать листать дальше")

        let answer = text(of: result)
        XCTAssertTrue(
            answer.contains("in \(total) files"),
            "заголовок обязан называть полное число файлов: \(answer.split(separator: "\n").first ?? "")"
        )
        XCTAssertTrue(
            answer.contains("continue with offset \(listed.count)"),
            "ответ обязан сказать, с какого места листать"
        )
    }

    /// Тот же потолок — на **длинных** документах.
    ///
    /// Заглушка сервиса отдаёт шестнадцать символов текста на документ, и на
    /// такой мелочи промах не виден: сторож был зелёным на 21 918 из 24 000,
    /// пока прямая проба длинными документами не дала 24 581. Поэтому здесь
    /// зовётся сам рендер, а тексты берутся в десять тысяч знаков.
    func testCeilingHoldsOnLongDocuments() throws {
        let limits = MCPOutputLimits()
        let long = String(repeating: "a", count: 10_000)
        let payloads = (1...20).map {
            MCPDocumentPayload(id: "id-\($0)", text: long, metadata: [:], distance: nil)
        }
        let out = MCPDocumentRendering.render(payloads, limits: limits)
        XCTAssertFalse(out.documents.isEmpty, "ответ без единого документа — не ответ")
        let delivered = try Self.delivered(out)
        XCTAssertLessThanOrEqual(
            delivered, limits.responseCharacters,
            "весь ответ \(delivered) при потолке \(limits.responseCharacters)"
        )
    }

    /// Потолок ответа у ключа **ниже**, чем потолок одного документа.
    ///
    /// Оба задаются независимо и связаны между собой ничем. Первый документ
    /// отдаётся всегда, и раньше он брал размер из `documentCharacters` в обход
    /// бюджета: ключ с потолком в 2000 получал 8190 — вчетверо больше
    /// обещанного.
    func testCeilingHoldsWhenItIsSmallerThanOneDocument() throws {
        let limits = MCPOutputLimits(
            ceiling: 10, documentCharacters: 4000, responseCharacters: 2000, collections: 5
        )
        let out = MCPDocumentRendering.render(
            [MCPDocumentPayload(
                id: "one", text: String(repeating: "a", count: 10_000),
                metadata: [:], distance: nil
            )],
            limits: limits
        )
        XCTAssertFalse(out.documents.isEmpty, "первый документ обязан дойти даже при тесном потолке")
        let delivered = try Self.delivered(out)
        XCTAssertLessThanOrEqual(
            delivered, limits.responseCharacters,
            "весь ответ \(delivered) при потолке \(limits.responseCharacters)"
        )
    }

    /// Сколько символов уедет к агенту: текст плюс зеркало в JSON.
    private static func delivered(_ out: MCPDocumentRendering.Output) throws -> Int {
        let text = out.lines.joined(separator: "\n").count
        let structured = try out.documents.reduce(0) {
            $0 + (String(data: try JSONEncoder().encode($1), encoding: .utf8)?.count ?? 0)
        }
        return text + structured
    }

    /// Счёт в ответе — без разделителя разрядов.
    ///
    /// `formatted()` брал его из локали, и на русской машине рядом стояли
    /// «2 048» и «2048» в одной фразе.
    ///
    /// Проверять надо там, где счётчик **правда** идёт через `EnglishCount`.
    /// У `list_collections` число печатается обычной интерполяцией и разрядов
    /// не знало никогда — на нём откат `plainDigits` → `formatted()` прошёл бы
    /// незамеченным. Заголовок `add_documents` собирает именно помощник,
    /// поэтому заглушка отдаёт 2048 идентификаторов: на числе меньше тысячи
    /// разницы не видно.
    func testCountsCarryNoLocaleGrouping() async throws {
        let service = await service()
        let result = try await service.call(
            name: "add_documents",
            arguments: .object([
                "collection": .string("notes"),
                "documents": .array([.object(["text": .string("plain latin text")])]),
            ]),
            key: key
        ).get()
        let answer = text(of: result)
        XCTAssertTrue(answer.contains("2048 documents"), "счёт помощником: \(answer)")
        XCTAssertFalse(
            answer.contains("2 048") || answer.contains("2\u{00A0}048"),
            "разделитель разрядов из локали просочился в ответ: \(answer)"
        )
    }
}
