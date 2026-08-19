import XCTest
@testable import ChromaCore

/// `get_file` находит файл в любой форме записи пути и подсказывает на
/// промах.
///
/// Из живого случая: агент нашёл фрагмент поиском, скопировал `source_file`
/// в `get_file` и получил «нет документов файла». Файл лежал в коллекции —
/// разошлась только форма записи букв: файловая система хранит «й» двумя
/// знаками, а всякий, кто путь перепечатал, набирает его одним.
final class MCPFilePathFormTests: XCTestCase {
    private let key = "ключ-агента"

    /// Бэкенд сравнивает **байты**, как настоящая база.
    ///
    /// Обычное `==` у Swift канонично: с ним фейк отвечал бы «нашёл» на любую
    /// форму, и тест проходил бы даже на сломанном приложении.
    private struct Backend: MCPToolBackend {
        /// Путь в базе → его чанки. Ключ — ровно те байты, что записаны.
        var files: [String: [MCPDocumentPayload]]
        final class Calls: @unchecked Sendable {
            var documents: [MCPDocumentsRequest] = []
        }
        let calls = Calls()

        func collections(allowed: [String]) async throws -> [MCPCollectionSummary] {
            [MCPCollectionSummary(name: "заметки", documentCount: 1, model: "bge-m3", metric: "cosine", dimension: 8)]
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

        func documents(_ request: MCPDocumentsRequest) async throws -> MCPDocumentsAnswer {
            calls.documents.append(request)
            guard let condition = request.filter?.conditions.first else {
                return MCPDocumentsAnswer(documents: [], hasMore: false)
            }
            let asked = Array(condition.value.utf8)
            var matched: [MCPDocumentPayload] = []
            for (path, chunks) in files.sorted(by: { $0.key < $1.key }) {
                let field = condition.field == "file_name"
                    ? (path as NSString).lastPathComponent
                    : path
                if Array(field.utf8) == asked { matched += chunks }
            }
            let window = MCPFileChunks.page(
                MCPFileChunks.ordered(matched), offset: request.offset, limit: request.limit
            )
            return MCPDocumentsAnswer(
                documents: window.page, hasMore: window.hasMore,
                total: request.orderedByChunkIndex ? matched.count : nil
            )
        }

        func add(_ request: MCPAddRequest) async throws -> MCPAddAnswer {
            MCPAddAnswer(ids: [], model: "bge-m3")
        }

        func delete(_ request: MCPDeleteRequest) async throws -> MCPDeleteAnswer {
            MCPDeleteAnswer(deleted: [], missing: [], keptInTrash: false)
        }
    }

    private func chunks(of path: String, count: Int = 2) -> [MCPDocumentPayload] {
        (0..<count).map { number in
            MCPDocumentPayload(
                id: "\(path)#\(number)",
                text: "текст \(number)",
                metadata: [
                    "source_file": .string(path),
                    "file_name": .string((path as NSString).lastPathComponent),
                    MCPFileChunks.orderKey: .int(number),
                ]
            )
        }
    }

    private func service(_ backend: Backend) async -> MCPToolService {
        let client = ExternalClient(
            name: "агент",
            keyHash: ClientKey.hash(key),
            keyPrefix: String(key.prefix(4)),
            permissions: ClientPermissions(collections: ["заметки"], requestsPerMinute: 600, burst: 600)
        )
        let access = AccessController()
        await access.setClients([client])
        return MCPToolService(backend: backend, access: access, isReadOnlyServer: { false })
    }

    private func call(_ service: MCPToolService, file: String) async throws -> JSONValue {
        try await service.call(
            name: MCPToolCatalogue.getFile.name,
            arguments: .object(["collection": .string("заметки"), "file": .string(file)]),
            key: key
        ).get()
    }

    /// Файл записан так, как его отдала файловая система; спрашивают слитно.
    func testAFileStoredDecomposedIsFoundByTheTypedPath() async throws {
        let stored = "Отчёты/Первый/Договор.pdf".decomposedStringWithCanonicalMapping
        let backend = Backend(files: [stored: chunks(of: stored)])
        let service = await service(backend)

        let result = try await call(service, file: "Отчёты/Первый/Договор.pdf")
        let structured = result["structuredContent"]
        XCTAssertEqual(structured?["documents"]?.arrayValue?.count, 2, "файл лежит в коллекции — его надо отдать")
        XCTAssertEqual(
            structured?["file"]?.stringValue.map { Array($0.utf8) }, Array(stored.utf8),
            "в ответе — путь, под которым файл лежит в базе: им же агент попросит следующую страницу"
        )
    }

    /// Форма файловой системы отличается от обычного разложения: «≠» она
    /// оставляет целым. Ровно на таком файле агент и споткнулся.
    func testTheFileSystemFormIsTriedToo() async throws {
        let typed = "ЦОД/Смета ≠ 5/Первый лист.pdf"
        let stored = FilePathKey.fileSystemDecomposed(typed)
        XCTAssertNotEqual(
            Array(stored.utf8), Array(typed.decomposedStringWithCanonicalMapping.utf8),
            "иначе проверяется не тот вариант"
        )
        let backend = Backend(files: [stored: chunks(of: stored)])
        let service = await service(backend)

        let result = try await call(service, file: typed)
        XCTAssertEqual(result["structuredContent"]?["documents"]?.arrayValue?.count, 2)
    }

    /// Попадание с первого раза не должно стоить лишних запросов к базе.
    func testAHitCostsOneRequest() async throws {
        let path = "docs/readme.md"
        let backend = Backend(files: [path: chunks(of: path)])
        let service = await service(backend)

        _ = try await call(service, file: path)
        XCTAssertEqual(backend.calls.documents.count, 1)
    }

    /// Агент потерял верхние папки пути. Живой случай: спросил
    /// «125326/Документ/…», а лежит «ФНС России/ЦОД/125326/Документ/…».
    func testAMissingPrefixIsAnsweredWithTheRealPath() async throws {
        let stored = "ФНС России/ЦОД/125326/Документ/Акт.pdf"
        let backend = Backend(files: [stored: chunks(of: stored)])
        let service = await service(backend)

        let result = try await call(service, file: "125326/Документ/Акт.pdf")
        XCTAssertEqual(result["isError"]?.boolValue, false, "это ответ, а не сбой")
        let similar = result["structuredContent"]?["similarFiles"]?.arrayValue?.compactMap { $0.stringValue }
        XCTAssertEqual(similar, [stored], "имя файла то же — путь надо назвать целиком")
        XCTAssertTrue(
            result["content"]?[0]?["text"]?.stringValue?.contains(stored) ?? false,
            "путь должен быть виден и словами: структурированный ответ читают не все"
        )
    }

    /// Подсказывать нечего — остаётся объяснение, откуда берётся путь.
    func testWithoutAnythingSimilarTheOldExplanationStays() async throws {
        let backend = Backend(files: ["docs/readme.md": chunks(of: "docs/readme.md")])
        let service = await service(backend)

        let result = try await call(service, file: "нет/такого.md")
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("source_file"), text)
        XCTAssertNil(result["structuredContent"]?["similarFiles"])
    }

    /// Подсказка не выдаёт файлы, к которым ключ не имеет отношения: она
    /// строится тем же запросом, что и всё остальное, — по одной коллекции.
    func testTheHintStaysInsideTheAskedCollection() async throws {
        let stored = "ФНС России/ЦОД/125326/Документ/Акт.pdf"
        let backend = Backend(files: [stored: chunks(of: stored)])
        let service = await service(backend)

        _ = try await call(service, file: "125326/Документ/Акт.pdf")
        XCTAssertTrue(
            backend.calls.documents.allSatisfy { $0.collection == "заметки" },
            "все запросы — в коллекцию, которую агент назвал"
        )
    }
}

/// Файл берётся по отпечатку, а не по пути.
///
/// Идея пользователя: путь агент перепечатывает и портит — формой записи,
/// потерянными верхними папками, кодировкой. Отпечаток из шестнадцати
/// шестнадцатеричных знаков испортить нечем.
final class MCPFileFingerprintTests: XCTestCase {
    private let key = "ключ-агента"

    private struct Backend: MCPToolBackend {
        var path: String
        var fingerprint: String?
        final class Calls: @unchecked Sendable {
            var documents: [MCPDocumentsRequest] = []
        }
        let calls = Calls()

        func collections(allowed: [String]) async throws -> [MCPCollectionSummary] {
            [MCPCollectionSummary(name: "заметки", documentCount: 2, model: "bge-m3", metric: "cosine", dimension: 8)]
        }
        func describe(collection: String) async throws -> MCPCollectionDescription {
            MCPCollectionDescription(
                summary: try await collections(allowed: [collection])[0],
                fields: [], hasSchema: false, allowsExtraFields: true
            )
        }
        func search(_ request: MCPSearchRequest) async throws -> MCPSearchAnswer {
            MCPSearchAnswer(documents: chunks, metric: "cosine", model: "bge-m3")
        }
        func documents(_ request: MCPDocumentsRequest) async throws -> MCPDocumentsAnswer {
            calls.documents.append(request)
            guard let condition = request.filter?.conditions.first else {
                return MCPDocumentsAnswer(documents: [], hasMore: false)
            }
            let matches: Bool
            switch condition.field {
            case "file_id": matches = condition.value == fingerprint
            case "source_file": matches = Array(condition.value.utf8) == Array(path.utf8)
            default: matches = false
            }
            guard matches else { return MCPDocumentsAnswer(documents: [], hasMore: false) }
            return MCPDocumentsAnswer(documents: chunks, hasMore: false, total: chunks.count)
        }
        func add(_ request: MCPAddRequest) async throws -> MCPAddAnswer { MCPAddAnswer(ids: [], model: "bge-m3") }
        func delete(_ request: MCPDeleteRequest) async throws -> MCPDeleteAnswer {
            MCPDeleteAnswer(deleted: [], missing: [], keptInTrash: false)
        }

        var chunks: [MCPDocumentPayload] {
            (0..<2).map { number in
                var metadata: ChromaMetadata = [
                    "source_file": .string(path),
                    MCPFileChunks.orderKey: .int(number),
                ]
                if let fingerprint { metadata["file_id"] = .string(fingerprint) }
                return MCPDocumentPayload(id: "\(number)", text: "текст", metadata: metadata)
            }
        }
    }

    private func service(_ backend: Backend) async -> MCPToolService {
        let client = ExternalClient(
            name: "агент", keyHash: ClientKey.hash(key), keyPrefix: String(key.prefix(4)),
            permissions: ClientPermissions(collections: ["заметки"], requestsPerMinute: 600, burst: 600)
        )
        let access = AccessController()
        await access.setClients([client])
        return MCPToolService(backend: backend, access: access, isReadOnlyServer: { false })
    }

    private func call(_ service: MCPToolService, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        try await service.call(
            name: MCPToolCatalogue.getFile.name,
            arguments: .object(arguments.merging(["collection": .string("заметки")]) { left, _ in left }),
            key: key
        ).get()
    }

    /// Отпечаток — тот самый, что приложение пишет в метаданные при синхронизации.
    func testTheFingerprintIsTheOneSynchronisationWrites() async throws {
        let path = "Отчёты/Первый/Договор.pdf"
        let fingerprint = SourceSyncService.fileFingerprint(path)
        let backend = Backend(path: path, fingerprint: fingerprint)
        let service = await service(backend)

        let result = try await call(service, ["file_id": .string(fingerprint)])
        let structured = result["structuredContent"]
        XCTAssertEqual(structured?["documents"]?.arrayValue?.count, 2)
        XCTAssertEqual(structured?["fileId"]?.stringValue, fingerprint)
        XCTAssertEqual(structured?["file"]?.stringValue, path, "по отпечатку возвращается и путь — его показывают человеку")
        XCTAssertEqual(backend.calls.documents.count, 1, "перебирать формы записи тут нечего")
    }

    /// Спросили путём — отпечаток всё равно назван: следующая страница
    /// обойдётся без пути вовсе.
    func testAskingByPathStillAnswersWithTheFingerprint() async throws {
        let path = "Отчёты/Первый/Договор.pdf"
        let fingerprint = SourceSyncService.fileFingerprint(path)
        let service = await service(Backend(path: path, fingerprint: fingerprint))

        let result = try await call(service, ["file": .string(path)])
        XCTAssertEqual(result["structuredContent"]?["fileId"]?.stringValue, fingerprint)
    }

    /// В коллекции прежних сборок поля file_id нет. Выдумывать его нельзя —
    /// агент позвал бы с ним и получил пустоту.
    func testAnOldCollectionDoesNotPretendToHaveFingerprints() async throws {
        let path = "Отчёты/Первый/Договор.pdf"
        let service = await service(Backend(path: path, fingerprint: nil))

        let result = try await call(service, ["file": .string(path)])
        XCTAssertNil(result["structuredContent"]?["fileId"])

        let miss = try await call(service, ["file_id": .string(SourceSyncService.fileFingerprint(path))])
        let text = miss["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("прежними сборками"), "надо сказать, почему промах и что делать: \(text)")
    }

    /// Без обоих параметров вызов отвергается — но текст ошибки называет оба
    /// способа, а не один.
    func testTheCallNamesBothWaysToAskForAFile() async throws {
        let service = await service(Backend(path: "файл.md", fingerprint: "abc"))
        let result = await service.call(
            name: MCPToolCatalogue.getFile.name,
            arguments: .object(["collection": .string("заметки")]),
            key: key
        )
        guard case .failure(let error) = result else { return XCTFail("вызов без файла обязан быть отвергнут") }
        XCTAssertEqual(error.code, -32602)
        XCTAssertTrue(error.message.contains("file_id"), error.message)
        XCTAssertTrue(error.message.contains("source_file"), error.message)
    }

    /// Выдача поиска показывает отпечаток отдельным полем — иначе он теряется
    /// среди трёх десятков метаданных, и агент опять хватается за путь.
    func testSearchResultsCarryTheFingerprint() async throws {
        let path = "Отчёты/Первый/Договор.pdf"
        let fingerprint = SourceSyncService.fileFingerprint(path)
        let service = await service(Backend(path: path, fingerprint: fingerprint))

        let result = try await service.call(
            name: MCPToolCatalogue.search.name,
            arguments: .object(["collection": .string("заметки"), "query": .string("договор")]),
            key: key
        ).get()
        let documents = result["structuredContent"]?["documents"]?.arrayValue ?? []
        XCTAssertEqual(documents.first?["fileId"]?.stringValue, fingerprint)
        XCTAssertTrue(
            result["content"]?[0]?["text"]?.stringValue?.contains("get_file с file_id \(fingerprint)") ?? false,
            "и словами тоже: модель читает текст"
        )
    }
}
