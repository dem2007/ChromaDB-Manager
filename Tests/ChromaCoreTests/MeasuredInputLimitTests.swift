import XCTest
@testable import ChromaCore

/// Чанк дорезается под то, что модель читает **на самом деле**.
///
/// Живой случай: контекст модели 8192 токена, а замеренный предел — 2937
/// знаков. Чанк в 7159 знаков проходил проверку по токенам, не проходил
/// по знакам, и файл целиком уходил в пропущенные — а прогон обрывался
/// на нём, не разобрав остальные сотни файлов.
final class MeasuredInputLimitTests: XCTestCase {
    private func sentences(_ count: Int) -> String {
        (0..<count)
            .map { "Предложение номер \($0) про предмет договора и порядок расчётов между сторонами." }
            .joined(separator: " ")
    }

    /// Числа взяты с живого случая: 7159 знаков при пределе 2937.
    func testAChunkIsCutDownToTheMeasuredLimit() {
        let text = String(sentences(120).prefix(7159))
        let chunk = TextChunk(index: 0, text: text)
        // По токенам такой чанк проходит: 7159 знаков — это около 2700
        // токенов при контексте 8192. Тем и опасен.
        XCTAssertFalse(OversizeChunks.doesNotFit(text, limit: 8192))

        let result = OversizeChunks.fitted([chunk], contextLength: 8192, characterLimit: 2937)
        XCTAssertEqual(result.split, 1, "чанк обязан быть дорезан")
        XCTAssertGreaterThan(result.chunks.count, 1)
        for piece in result.chunks {
            XCTAssertLessThanOrEqual(
                piece.text.count, 2937,
                "кусок в \(piece.text.count) знаков модель прочитает не целиком"
            )
        }
        // Нумерация сплошная: идентификатор документа собирается из номера.
        XCTAssertEqual(result.chunks.map(\.index), Array(0..<result.chunks.count))
    }

    /// Сплошная строка без границ предложений — выгрузка, таблица, список —
    /// режется по словам и знакам, а не отменяет файл.
    func testATextWithoutSentenceBoundariesIsCutAnyway() {
        let text = String(repeating: "значение;", count: 900)
        let result = OversizeChunks.fitted(
            [TextChunk(index: 0, text: text)], contextLength: nil, characterLimit: 2000
        )
        XCTAssertGreaterThan(result.chunks.count, 1)
        for piece in result.chunks {
            XCTAssertLessThanOrEqual(piece.text.count, 2000)
        }
    }

    /// Предел неизвестен — резать не по чему, и старое поведение не меняется.
    func testNothingChangesWhenTheLimitWasNotMeasured() {
        let chunks = [TextChunk(index: 0, text: sentences(20))]
        XCTAssertEqual(OversizeChunks.fitted(chunks, contextLength: 8192).split, 0)
        XCTAssertEqual(
            OversizeChunks.fitted(chunks, contextLength: 8192, characterLimit: nil).split, 0
        )
    }

    // MARK: - Прогон целиком

    /// Модель, которая читает первые `limit` знаков и молчит об этом, —
    /// ровно то, что описано в.
    private actor TruncatingEmbeddings: EmbeddingProvider {
        let limit: Int
        private(set) var seen: [String] = []

        init(limit: Int) { self.limit = limit }

        func embed(texts: [String], model: String) async throws -> [[Double]] {
            seen.append(contentsOf: texts)
            return vectors(of: texts)
        }

        /// Проба предела идёт мимо кэша — и мимо счёта отправленного:
        /// её тексты по 64 000 знаков как раз и меряют, где модель обрывает
        /// чтение, а проверять надо чанки прогона.
        func embedIgnoringCache(texts: [String], model: String) async throws -> [[Double]] {
            vectors(of: texts)
        }

        private func vectors(of texts: [String]) -> [[Double]] {
            texts.map { MeasuredInputLimitTests.vector(of: $0, limit: limit) }
        }
    }

    private final class RecordingDatabase: SyncDatabase, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var written: [EmbeddedRecord] = []
        private(set) var deleted: [String] = []

        func createCollection(
            name: String, metadata: ChromaMetadata?, configuration: CollectionConfiguration?, getOrCreate: Bool
        ) async throws -> ChromaCollection {
            ChromaCollection(id: "id-\(name)", name: name)
        }
        func resolveID(of name: String) async throws -> String { "id-\(name)" }
        func updateCollection(id: String, newName: String?, metadata: ChromaMetadata?) async throws {}
        func upsert(collectionID: String, records: [EmbeddedRecord]) async throws {
            lock.lock(); written.append(contentsOf: records); lock.unlock()
        }
        func updateDocuments(collectionID: String, updates: [DocumentUpdate]) async throws {}
        func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord] { [] }
        func embeddings(collectionID: String, ids: [String]) async throws -> [String: [Double]] { [:] }
        func deleteDocuments(collectionID: String, ids: [String]) async throws {
            lock.lock(); deleted.append(contentsOf: ids); lock.unlock()
        }
        func deleteDocuments(collectionID: String, filter: DocumentFilter) async throws -> Int { 0 }
    }

    /// Главный тест пункта: файл с чанком длиннее замеренного предела
    /// индексируется, а не пропускается, и прогон доходит до соседних файлов.
    func testAFileWithAnOversizeChunkIsIndexedInsteadOfSkipped() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("measured-limit-\(UUID().uuidString)")
        let folder = directory.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Длинный файл — один чанк на 12 000 знаков: нарезка по 20 000 знаков
        // его не тронет, а модель прочитает первые 3000.
        try sentences(400).write(
            to: folder.appendingPathComponent("длинный.md"), atomically: true, encoding: .utf8
        )
        try "Короткий файл про акты.".write(
            to: folder.appendingPathComponent("короткий.md"), atomically: true, encoding: .utf8
        )

        let service = SourceSyncService(
            manifests: ManifestStore(directory: directory.appendingPathComponent("manifests")),
            journal: SyncJournal(directory: directory.appendingPathComponent("journal"))
        )
        let source = DataSource(
            name: "docs", path: folder.path, fileExtensions: ["md"],
            collectionName: "measured_limit",
            chunking: ChunkingConfiguration(
                strategy: .fixed, chunkSize: 20_000, sizeUnit: .characters, overlapPercent: 0
            )
        )
        let database = RecordingDatabase()
        let embeddings = TruncatingEmbeddings(limit: 3000)

        let summary = try await service.sync(
            source: source, embeddingModel: "усечённая", chroma: database,
            embeddings: embeddings, binding: ModelBindingService()
        ) { _ in }

        XCTAssertEqual(summary.added, 2, "оба файла обязаны попасть в базу: \(summary.skipped)")
        XCTAssertTrue(summary.skipped.isEmpty, "пропущенных быть не должно: \(summary.skipped)")
        XCTAssertGreaterThan(summary.chunksSplitToFit, 0, "длинный чанк обязан быть дорезан")

        // И главное: в модель не ушло ни одного текста длиннее её предела —
        // иначе вектор считался бы по началу, а хвост пропал бы молча.
        let sent = await embeddings.seen
        XCTAssertFalse(sent.isEmpty)
        for text in sent {
            XCTAssertLessThanOrEqual(
                text.count, 3000,
                "в модель ушёл текст в \(text.count) знаков при пределе 3000"
            )
        }
    }

    /// А если файл всё же не прошёл — прогон **продолжается**, и файл
    /// называется в отчёте.
    ///
    /// Случай не выдуманный: модель молчала, когда решался размер чанков
    /// (проба предела не удалась), и ответила, когда дело дошло до вектора.
    /// Дорезать было не по чему, и файл в базу не попал — а прежде вместе
    /// с ним обрывался весь прогон, и соседние файлы не читались вовсе.
    func testAFileThatStillDoesNotFitIsReportedAndTheRunGoesOn() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("still-too-long-\(UUID().uuidString)")
        let folder = directory.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try sentences(400).write(
            to: folder.appendingPathComponent("а_длинный.md"), atomically: true, encoding: .utf8
        )
        try "Короткий файл про акты.".write(
            to: folder.appendingPathComponent("б_короткий.md"), atomically: true, encoding: .utf8
        )

        let service = SourceSyncService(
            manifests: ManifestStore(directory: directory.appendingPathComponent("manifests")),
            journal: SyncJournal(directory: directory.appendingPathComponent("journal"))
        )
        let source = DataSource(
            name: "docs", path: folder.path, fileExtensions: ["md"],
            collectionName: "still_too_long",
            chunking: ChunkingConfiguration(
                strategy: .fixed, chunkSize: 20_000, sizeUnit: .characters, overlapPercent: 0
            )
        )
        let database = RecordingDatabase()

        let summary = try await service.sync(
            source: source, embeddingModel: "усечённая", chroma: database,
            embeddings: SilentAtFirstEmbeddings(limit: 3000), binding: ModelBindingService()
        ) { _ in }

        // Соседний файл разобран — прогон не оборвался на первом.
        XCTAssertEqual(summary.added, 1, "короткий файл обязан попасть в базу")
        XCTAssertTrue(
            summary.skipped.contains { $0.file.hasPrefix("а_длинный") },
            "непрошедший файл обязан быть назван в отчёте: \(summary.skipped)"
        )
        // И за собой он ничего не оставил: записанное до отказа снято — иначе
        // в базе висели бы чанки, на которые не ссылается даже манифест.
        let orphans = database.written.map(\.id).filter { !database.deleted.contains($0) }
        XCTAssertTrue(
            orphans.allSatisfy { !$0.contains("а_длинный") },
            "в базе остались чанки непрошедшего файла: \(orphans)"
        )
    }

    /// Модель, которая на первую пробу не отвечает, а дальше работает:
    /// LM Studio, занятая выгрузкой другой модели, ведёт себя ровно так.
    private actor SilentAtFirstEmbeddings: EmbeddingProvider {
        private let limit: Int
        private var probes = 0

        init(limit: Int) { self.limit = limit }

        func embed(texts: [String], model: String) async throws -> [[Double]] {
            texts.map { MeasuredInputLimitTests.vector(of: $0, limit: limit) }
        }

        func embedIgnoringCache(texts: [String], model: String) async throws -> [[Double]] {
            struct Silence: Error {}
            probes += 1
            guard probes > 1 else { throw Silence() }
            return texts.map { MeasuredInputLimitTests.vector(of: $0, limit: limit) }
        }
    }

    /// Вектор — псевдослучайная функция того, что модель успела прочитать.
    static func vector(of text: String, limit: Int) -> [Double] {
        let read = String(text.prefix(limit))
        var state = UInt64(2_166_136_261)
        for byte in read.utf8 { state = (state ^ UInt64(byte)) &* 16_777_619 }
        var vector: [Double] = []
        for _ in 0..<8 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            vector.append(Double(state % 1000) / 1000)
        }
        return vector
    }
}
