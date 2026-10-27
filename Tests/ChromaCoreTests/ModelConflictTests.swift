import XCTest
@testable import ChromaCore

/// запись в коллекцию сверяет модель, а не только размерность.
///
/// Источник «по умолчанию» после смены сервера моделей идёт моделью нового
/// сервера, а размерность у разных моделей часто одна. База в тесте ведёт
/// себя как ChromaDB 1.4.4: существующая коллекция приходит со **своими**
/// метаданными, `dimension` у неё есть только после первой записи.
final class ModelConflictTests: XCTestCase {
    private final class Database: SyncDatabase, @unchecked Sendable {
        var existing: ChromaCollection?
        /// Записей в существующей коллекции; `nil` — база не говорит.
        var records: Int? = 0
        var updatedMetadata: ChromaMetadata?
        var writes = 0
        func createCollection(name: String, metadata: ChromaMetadata?, configuration: CollectionConfiguration?, getOrCreate: Bool) async throws -> ChromaCollection {
            existing ?? ChromaCollection(id: "col", name: name, metadata: metadata)
        }
        func resolveID(of name: String) async throws -> String { "col" }
        func updateCollection(id: String, newName: String?, metadata: ChromaMetadata?) async throws {
            updatedMetadata = metadata
        }
        func upsert(collectionID: String, records: [EmbeddedRecord]) async throws { writes += 1 }
        func updateDocuments(collectionID: String, updates: [DocumentUpdate]) async throws {}
        func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord] { [] }
        func embeddings(collectionID: String, ids: [String]) async throws -> [String: [Double]] { [:] }
        func deleteDocuments(collectionID: String, ids: [String]) async throws {}
        func deleteDocuments(collectionID: String, filter: DocumentFilter) async throws -> Int { 0 }
        func documentCount(collectionID: String) async throws -> Int? { existing == nil ? 0 : records }
    }

    /// Обе модели выдают по четыре числа — размерность их не различит.
    private struct Embeddings: EmbeddingProvider {
        var server: LLMProvider = .lmStudio
        var length = 4
        func embed(texts: [String], model: String) async throws -> [[Double]] {
            texts.map { _ in (0..<length).map(Double.init) }
        }
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("model-conflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "Текст файла для проверки.".write(to: directory.appendingPathComponent("а.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sync(_ database: Database, model: String, server: LLMProvider = .lmStudio) async throws {
        let service = SourceSyncService(manifests: ManifestStore(directory: directory.appendingPathComponent("manifests")))
        let source = DataSource(name: "docs", path: directory.path, fileExtensions: ["md"], collectionName: "notes")
        _ = try await service.sync(
            source: source, embeddingModel: model, chroma: database,
            embeddings: Embeddings(server: server), binding: ModelBindingService()
        ) { _ in }
    }

    /// `server: nil` — коллекция, привязанная до: ключа сервера нет.
    private func collection(model: String, server: LLMProvider? = .lmStudio, filled: Bool) -> ChromaCollection {
        var metadata: ChromaMetadata = [CollectionBindingKeys.model: .string(model), CollectionBindingKeys.dimension: .int(4)]
        if let server { metadata[CollectionBindingKeys.modelServer] = .string(server.rawValue) }
        return ChromaCollection(id: "col", name: "notes", metadata: metadata, dimension: filled ? 4 : nil)
    }

    func testAFilledCollectionOfAnotherModelIsNotWrittenTo() async throws {
        let database = Database()
        database.existing = collection(model: "text-embedding-bge-m3", filled: true)
        database.records = 3
        do {
            try await sync(database, model: "qwen3-embedding:0.6b")
            XCTFail("запись чужой моделью должна быть остановлена")
        } catch BindingError.modelConflict(let name, let bound, let requested) {
            XCTAssertEqual(name, "notes")
            XCTAssertEqual(bound, BoundModel(model: "text-embedding-bge-m3", server: .lmStudio))
            XCTAssertEqual(requested, BoundModel(model: "qwen3-embedding:0.6b", server: .lmStudio))
        }
        XCTAssertEqual(database.writes, 0)
        XCTAssertNil(database.updatedMetadata, "привязка заполненной коллекции не меняется")
    }

    func testAnEmptyCollectionIsReboundToTheNewModel() async throws {
        let database = Database()
        database.existing = collection(model: "text-embedding-bge-m3", filled: false)
        try await sync(database, model: "qwen3-embedding:0.6b")
        XCTAssertEqual(database.updatedMetadata?[CollectionBindingKeys.model], .string("qwen3-embedding:0.6b"))
        XCTAssertGreaterThan(database.writes, 0)
    }

    // MARK: - Пара «модель + сервер»

    /// Одно имя у двух серверов — две модели: заполненную моделью LM Studio
    /// коллекцию одноимённая модель Ollama не доливает.
    func testTheSameNameFromAnotherServerIsAnotherModel() async throws {
        let database = Database()
        database.existing = collection(model: "nomic-embed-text", server: .lmStudio, filled: true)
        database.records = 3
        do {
            try await sync(database, model: "nomic-embed-text", server: .ollama)
            XCTFail("одноимённая модель другого сервера писать не должна")
        } catch BindingError.modelConflict(_, let bound, let requested) {
            XCTAssertEqual(bound.server, .lmStudio)
            XCTAssertEqual(requested.server, .ollama)
            let text = BindingError.modelConflict(collection: "notes", bound: bound, requested: requested).errorDescription ?? ""
            XCTAssertTrue(text.contains("LM Studio") && text.contains("Ollama"), text)
        }
        XCTAssertEqual(database.writes, 0)
    }

    /// Новая коллекция и перепривязанная пустая записывают свой сервер.
    func testTheServerIsWrittenWithTheModel() async throws {
        let fresh = Database()
        try await sync(fresh, model: "nomic-embed-text:latest", server: .ollama)
        XCTAssertGreaterThan(fresh.writes, 0)

        let empty = Database()
        empty.existing = collection(model: "nomic-embed-text", server: .lmStudio, filled: false)
        try await sync(empty, model: "nomic-embed-text", server: .ollama)
        XCTAssertEqual(empty.updatedMetadata?[CollectionBindingKeys.modelServer], .string("ollama"))
    }

    /// Коллекция, привязанная до, — коллекция LM Studio: другого
    /// сервера тогда не было, и её синхронизация идёт как шла.
    func testACollectionWithoutAServerIsLMStudios() async throws {
        let legacy = collection(model: "text-embedding-bge-m3", server: nil, filled: true)
        XCTAssertEqual(legacy.boundServer, .lmStudio)
        let database = Database()
        database.existing = legacy
        database.records = 3
        try await sync(database, model: "text-embedding-bge-m3", server: .lmStudio)
        XCTAssertGreaterThan(database.writes, 0)
    }

    /// Поиск — тоже: вектор запроса посчитала бы одноимённая модель другого
    /// сервера.
    func testASearchAsksForTheCollectionsServer() throws {
        let binding = ModelBindingService()
        let filled = collection(model: "nomic-embed-text", server: .lmStudio, filled: true)
        XCTAssertEqual(try binding.requiredModel(for: filled, server: .lmStudio), "nomic-embed-text")
        XCTAssertThrowsError(try binding.requiredModel(for: filled, server: .ollama)) { error in
            guard case BindingError.serverConflict(_, let bound, let current) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(bound.server, .lmStudio)
            XCTAssertEqual(current, .ollama)
            XCTAssertTrue((error as? BindingError)?.recoverySuggestion?.contains("LM Studio") ?? false)
        }
    }

    /// Кэши различают одноимённые модели двух серверов: размерность одной
    /// не выдаётся за размерность другой.
    func testCachesTellTheServersApart() async throws {
        let binding = ModelBindingService()
        let studio = try await binding.dimension(of: "nomic-embed-text", lmStudio: Embeddings(server: .lmStudio, length: 4))
        let ollama = try await binding.dimension(of: "nomic-embed-text", lmStudio: Embeddings(server: .ollama, length: 8))
        XCTAssertEqual(studio, 4)
        XCTAssertEqual(ollama, 8)
        XCTAssertEqual(LLMProvider.lmStudio.cacheName(of: "m"), "m", "кэш LM Studio — под прежними ключами")
        XCTAssertNotEqual(LLMProvider.ollama.cacheName(of: "m"), "m")
    }

    func testTheSameModelWritesWithoutRebinding() async throws {
        let database = Database()
        database.existing = collection(model: "text-embedding-bge-m3", filled: true)
        database.records = 3
        try await sync(database, model: "text-embedding-bge-m3")
        // Метаданные может дописать перенос подписи нарезки — модель
        // при этом та же.
        XCTAssertEqual(database.updatedMetadata?[CollectionBindingKeys.model] ?? .string("text-embedding-bge-m3"),
                       .string("text-embedding-bge-m3"))
        XCTAssertGreaterThan(database.writes, 0)
    }

    /// Сервер, который не сообщает `dimension`, не выдаёт заполненную
    /// коллекцию за пустую: пустоту подтверждает счёт записей.
    func testACollectionWithoutAReportedDimensionIsCountedNotGuessed() async throws {
        let database = Database()
        database.existing = collection(model: "text-embedding-bge-m3", filled: false)
        database.records = 12
        do {
            try await sync(database, model: "qwen3-embedding:0.6b")
            XCTFail("заполненная коллекция не перепривязывается")
        } catch BindingError.modelConflict {}
        XCTAssertEqual(database.writes, 0)
        XCTAssertNil(database.updatedMetadata)

        // Не знаем, сколько записей, — значит, не пустая.
        let silent = Database()
        silent.existing = collection(model: "text-embedding-bge-m3", filled: false)
        silent.records = nil
        do {
            try await sync(silent, model: "qwen3-embedding:0.6b")
            XCTFail("без счёта перепривязки нет")
        } catch BindingError.modelConflict {}
    }

    /// Сервер, которого эта сборка не знает, — не LM Studio и не Ollama.
    func testAnUnknownServerMatchesNothing() throws {
        var metadata: ChromaMetadata = [CollectionBindingKeys.model: .string("nomic-embed-text")]
        metadata[CollectionBindingKeys.modelServer] = .string("vllm")
        let future = ChromaCollection(id: "col", name: "notes", metadata: metadata, dimension: 4)
        XCTAssertNil(future.boundServer)
        XCTAssertEqual(future.binding?.serverTitle, "vllm")
        let binding = ModelBindingService()
        XCTAssertNotEqual(binding.check(model: "nomic-embed-text", server: .lmStudio, for: future), .matches)
        XCTAssertThrowsError(try binding.requiredModel(for: future, server: .lmStudio))
    }

    func testTheReasonIsReadableForAnAgent() {
        let error = BindingError.modelConflict(
            collection: "notes",
            bound: BoundModel(model: "a", server: .lmStudio),
            requested: BoundModel(model: "b", server: .ollama)
        )
        XCTAssertTrue(error.mcpReason.contains("«a»") && error.mcpReason.contains("«b»"), error.mcpReason)
        XCTAssertTrue((error.recoverySuggestion ?? "").contains("Пересчёт"))
    }
}
