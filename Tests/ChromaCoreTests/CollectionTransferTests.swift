import XCTest
@testable import ChromaCore

/// §D4 — перенос коллекции пакетом `.chromaexport`.
final class CollectionTransferTests: XCTestCase {
    private var box: URL!

    override func setUpWithError() throws {
        box = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: box)
    }

    // MARK: - Стенды

    /// Откуда выгружаем: только чтение.
    private final class Source: CollectionExporter.Source, @unchecked Sendable {
        var documents: [ExportedDocument] = []
        var failsAfter: Int?
        private(set) var pages = 0

        func count(collectionID: String) async throws -> Int { documents.count }

        func page(
            collectionID: String, limit: Int, offset: Int,
            filter: DocumentFilter?, includeEmbeddings: Bool
        ) async throws -> [ExportedDocument] {
            pages += 1
            if let failsAfter, offset >= failsAfter { throw ChromaError.api(status: 500, code: nil, message: "сервер устал") }
            var all = documents
            if let filter, let condition = filter.conditions.first {
                all = all.filter { $0.metadata?[condition.field]?.displayString == condition.value }
            }
            guard offset < all.count else { return [] }
            return Array(all[offset..<min(offset + limit, all.count)]).map { document in
                includeEmbeddings ? document : ExportedDocument(
                    id: document.id, document: document.document,
                    metadata: document.metadata, embedding: nil
                )
            }
        }
    }

    /// Куда импортируем.
    private final class Destination: CollectionImporter.Destination, @unchecked Sendable {
        var stored: [String: EmbeddedRecord] = [:]
        private(set) var upserts = 0
        /// Обрыв на середине — так же, как его устроила бы упавшая сеть.
        var failsAfterUpserts: Int?

        func existingIDs(collectionID: String, ids: [String]) async throws -> Set<String> {
            Set(ids.filter { stored[$0] != nil })
        }

        func upsert(collectionID: String, records: [EmbeddedRecord]) async throws {
            if let failsAfterUpserts, upserts >= failsAfterUpserts {
                throw ChromaError.unreachable(endpoint: "стенд", reason: "связь оборвалась")
            }
            upserts += 1
            for record in records { stored[record.id] = record }
        }
    }

    /// Приёмник, который ничего не хранит: в тесте на память важно мерить
    /// перенос, а не словарь стенда.
    private final class CountingDestination: CollectionImporter.Destination, @unchecked Sendable {
        private(set) var written = 0
        func existingIDs(collectionID: String, ids: [String]) async throws -> Set<String> { [] }
        func upsert(collectionID: String, records: [EmbeddedRecord]) async throws { written += records.count }
    }

    private final class Embedder: EmbeddingProvider, @unchecked Sendable {
        private(set) var calls = 0
        private(set) var asked: [String] = []
        func embed(texts: [String], model: String) async throws -> [[Double]] {
            calls += 1
            asked += texts
            return texts.map { text in [Double(text.count), 1, 0, 0] }
        }
    }

    private func collection(dimension: Int = 4, metric: DistanceMetric = .cosine, model: String = "e5") -> ChromaCollection {
        ChromaCollection(
            id: "cid", name: "проба",
            metadata: [
                CollectionBindingKeys.model: .string(model),
                CollectionBindingKeys.dimension: .int(dimension),
                CollectionBindingKeys.space: .string(metric.rawValue),
            ]
        )
    }

    private func documents(_ count: Int) -> [ExportedDocument] {
        (0..<count).map { index in
            ExportedDocument(
                id: "d\(index)",
                document: "Документ номер \(index) с текстом достаточной длины.",
                metadata: ["группа": .string(index % 2 == 0 ? "чёт" : "нечет"), "номер": .int(index)],
                embedding: [Double(index) / 10, 0.5, -0.25, 0.125]
            )
        }
    }

    private func exportPackage(
        _ source: Source, options: CollectionExporter.Options = CollectionExporter.Options(),
        collection: ChromaCollection? = nil
    ) async throws -> CollectionExporter.Result {
        try await CollectionExporter(source: source).export(
            collection: collection ?? self.collection(),
            to: box.appendingPathComponent("пакет.chromaexport"),
            serverVersion: "1.0.0", tenant: "default_tenant", database: "default_database",
            options: options
        )
    }

    // MARK: - Круг: экспорт → импорт

    /// Главный тест этапа: то, что уехало, обязано вернуться тем же самым.
    func testRoundTripKeepsTextsMetadataAndVectors() async throws {
        let source = Source()
        source.documents = documents(25)
        let exported = try await exportPackage(source)

        XCTAssertEqual(exported.manifest.documentCount, 25)
        XCTAssertTrue(exported.manifest.includesEmbeddings)
        XCTAssertFalse(exported.manifest.dataSHA256.isEmpty)

        let manifest = try CollectionImporter.readManifest(at: exported.url)
        try CollectionImporter.verifyChecksum(at: exported.url, manifest: manifest)

        let destination = Destination()
        let report = try await CollectionImporter(destination: destination).import(
            package: exported.url, manifest: manifest,
            into: "target", collectionName: "цель",
            options: .init(resumesFromCheckpoint: false)
        )

        XCTAssertEqual(report.written, 25)
        XCTAssertTrue(report.finished)
        XCTAssertTrue(report.brokenLines.isEmpty)
        for original in source.documents {
            let restored = try XCTUnwrap(destination.stored[original.id])
            XCTAssertEqual(restored.document, original.document)
            XCTAssertEqual(restored.metadata["группа"], original.metadata?["группа"])
            XCTAssertEqual(restored.metadata["номер"], original.metadata?["номер"])
            // Векторы — побайтово те же: JSON печатает Double так, что чтение
            // возвращает ровно то же значение.
            XCTAssertEqual(restored.embedding, original.embedding ?? [])
        }
    }

    func testAFilterExportsExactlyTheSubset() async throws {
        let source = Source()
        source.documents = documents(10)
        let exported = try await exportPackage(source, options: .init(
            filter: DocumentFilter(conditions: [MetadataCondition(field: "группа", op: .equals, value: "чёт")])
        ))

        XCTAssertEqual(exported.manifest.documentCount, 5)
        XCTAssertEqual(exported.manifest.filterDescription?.contains("группа"), true)
    }

    func testExportWithoutVectorsIsSmallerAndSaysSo() async throws {
        let source = Source()
        source.documents = documents(10)
        let withVectors = try await exportPackage(source)
        let sizeWith = withVectors.manifest.dataBytes

        let without = try await CollectionExporter(source: source).export(
            collection: collection(),
            to: box.appendingPathComponent("без-векторов.chromaexport"),
            serverVersion: "1.0.0", tenant: "t", database: "d",
            options: .init(includesEmbeddings: false)
        )
        XCTAssertFalse(without.manifest.includesEmbeddings)
        XCTAssertLessThan(without.manifest.dataBytes, sizeWith)
    }

    /// Отменённый экспорт не оставляет пакета: недописанный файл выглядит
    /// как готовый и однажды будет импортирован.
    func testAFailedExportLeavesNoPackageBehind() async throws {
        let source = Source()
        source.documents = documents(500)
        source.failsAfter = 200

        do {
            _ = try await exportPackage(source, options: .init(pageSize: 100))
            XCTFail("экспорт должен был упасть")
        } catch {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: box.appendingPathComponent("пакет.chromaexport").path),
                "после неудачи пакета остаться не должно"
            )
        }
    }

    // MARK: - Проверки перед импортом

    func testADimensionMismatchIsRefusedBeforeAnythingIsWritten() async throws {
        let source = Source()
        source.documents = documents(3)
        let exported = try await exportPackage(source)
        let manifest = try CollectionImporter.readManifest(at: exported.url)

        XCTAssertThrowsError(
            try CollectionImporter.problems(manifest: manifest, target: collection(dimension: 768))
        ) { error in
            XCTAssertEqual(error as? TransferError, .dimensionMismatch(expected: 768, got: 4))
        }
    }

    /// Метрика и модель — не запрет, а предупреждение: данные останутся
    /// валидными, изменится смысл поиска.
    func testMetricAndModelMismatchesAreWarningsNotRefusals() async throws {
        let source = Source()
        source.documents = documents(3)
        let exported = try await exportPackage(source)
        let manifest = try CollectionImporter.readManifest(at: exported.url)

        let warnings = try CollectionImporter.problems(
            manifest: manifest, target: collection(metric: .l2, model: "другая-модель")
        )
        XCTAssertEqual(warnings.count, 2)
        XCTAssertTrue(warnings.contains { $0.contains("Метрика не совпадает") })
        XCTAssertTrue(warnings.contains { $0.contains("Модель не совпадает") })
    }

    func testAPackageFromTheFutureIsRefusedRatherThanGuessedAt() async throws {
        let source = Source()
        source.documents = documents(2)
        let exported = try await exportPackage(source)
        // Правим версию в манифесте: так выглядел бы пакет из будущей сборки.
        let manifestURL = exported.url.appendingPathComponent("manifest.json")
        var text = try String(contentsOf: manifestURL, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"formatVersion\" : 1", with: "\"formatVersion\" : 99")
        try Data(text.utf8).write(to: manifestURL)

        XCTAssertThrowsError(try CollectionImporter.readManifest(at: exported.url)) { error in
            XCTAssertEqual(error as? TransferError, .futureFormat(99))
        }
    }

    func testACorruptedPackageIsCaughtByItsChecksum() async throws {
        let source = Source()
        source.documents = documents(5)
        let exported = try await exportPackage(source)
        let dataURL = exported.url.appendingPathComponent("documents.jsonl")
        var bytes = try Data(contentsOf: dataURL)
        bytes.append(contentsOf: Array("{\"id\":\"лишнее\"}\n".utf8))
        try bytes.write(to: dataURL)

        let manifest = try CollectionImporter.readManifest(at: exported.url)
        XCTAssertThrowsError(try CollectionImporter.verifyChecksum(at: exported.url, manifest: manifest)) { error in
            XCTAssertEqual(error as? TransferError, .checksumMismatch)
        }
    }

    /// Сверка суммы отменяется, не дочитав пакет до конца.
    ///
    /// Она идёт до первой записи в базу и читает весь файл — в гигабайты,
    /// если пакет большой. Человек, передумавший импортировать, не должен
    /// ждать конца чтения.
    func testTheChecksumCheckStopsWhenTheImportIsCancelled() async throws {
        let source = Source()
        source.documents = documents(5)
        let exported = try await exportPackage(source)
        let manifest = try CollectionImporter.readManifest(at: exported.url)

        let task = Task {
            try CollectionImporter.verifyChecksum(at: exported.url, manifest: manifest)
        }
        task.cancel()

        do {
            try await task.value
            XCTFail("отменённая сверка не должна доходить до конца")
        } catch is CancellationError {
            // Именно это и ожидается.
        }
    }

    func testSomethingThatIsNotAPackageIsRefused() {
        XCTAssertThrowsError(try CollectionImporter.readManifest(at: box)) { error in
            guard case .notAPackage = error as? TransferError else {
                return XCTFail("не та ошибка: \(error)")
            }
        }
    }

    // MARK: - Поведение импорта

    func testConflictPoliciesDoWhatTheySay() async throws {
        let source = Source()
        source.documents = documents(4)
        let exported = try await exportPackage(source)
        let manifest = try CollectionImporter.readManifest(at: exported.url)

        // Пропустить.
        let skipping = Destination()
        skipping.stored["d0"] = EmbeddedRecord(id: "d0", document: "старое", embedding: [9, 9, 9, 9], metadata: [:])
        let skipReport = try await CollectionImporter(destination: skipping).import(
            package: exported.url, manifest: manifest, into: "t", collectionName: "цель",
            options: .init(conflictPolicy: .skip, resumesFromCheckpoint: false)
        )
        XCTAssertEqual(skipReport.skipped, 1)
        XCTAssertEqual(skipping.stored["d0"]?.document, "старое", "пропущенный документ не тронут")

        // Перезаписать.
        let overwriting = Destination()
        overwriting.stored["d0"] = EmbeddedRecord(id: "d0", document: "старое", embedding: [9, 9, 9, 9], metadata: [:])
        let overwriteReport = try await CollectionImporter(destination: overwriting).import(
            package: exported.url, manifest: manifest, into: "t", collectionName: "цель",
            options: .init(conflictPolicy: .overwrite, resumesFromCheckpoint: false)
        )
        XCTAssertEqual(overwriteReport.overwritten, 1)
        XCTAssertNotEqual(overwriting.stored["d0"]?.document, "старое")

        // Прервать.
        let stopping = Destination()
        stopping.stored["d0"] = EmbeddedRecord(id: "d0", document: "старое", embedding: [9, 9, 9, 9], metadata: [:])
        let stopReport = try await CollectionImporter(destination: stopping).import(
            package: exported.url, manifest: manifest, into: "t", collectionName: "цель",
            options: .init(conflictPolicy: .stop, resumesFromCheckpoint: false)
        )
        XCTAssertEqual(stopReport.stoppedAtConflict, "d0")
        XCTAssertFalse(stopReport.finished)
    }

    /// Страница экспорта не просит векторы, которые всё равно выбросит.
    ///
    /// `DocumentRecord` хранит только длину вектора, а не сам вектор: векторы,
    /// запрошенные страницей, приезжали по сети, разбирались и выбрасывались,
    /// после чего те же самые запрашивались вторым вызовом.
    func testTheExportPageDoesNotAskForVectorsItThrowsAway() async throws {
        final class Fake: HTTPTransport, @unchecked Sendable {
            var bodies: [[String: Any]] = []
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                if let body = request.httpBody,
                   let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    bodies.append(object)
                }
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!
                return (Data(#"{"ids":[],"documents":[],"metadatas":[]}"#.utf8), response)
            }
        }
        let fake = Fake()
        let client = ChromaClient(endpoint: ChromaEndpoint(host: "127.0.0.1", port: 8000), transport: fake)
        _ = try await client.page(
            collectionID: "c", limit: 100, offset: 0,
            filter: DocumentFilter?.none, includeEmbeddings: true
        )

        let include = (fake.bodies.first?["include"] as? [String]) ?? []
        XCTAssertFalse(include.contains("embeddings"), "страница просит векторы, хотя выбросит их: \(include)")
        XCTAssertTrue(include.contains("documents"))
    }

    /// Готовые векторы из пакета не пересчитываются.
    ///
    /// Прежде хватало одного документа без вектора, чтобы в модель ушла вся
    /// пачка, и привезённые векторы затирались векторами выбранной модели.
    /// Размерности совпадают, отказа нет — а в коллекции с одной привязкой
    /// лежит смесь двух моделей.
    func testOnlyTheMissingVectorsAreComputed() async throws {
        let source = Source()
        source.documents = documents(4)
        // У двух документов вектора нет — как в пакете, собранном частично.
        source.documents[1] = ExportedDocument(
            id: source.documents[1].id, document: source.documents[1].document,
            metadata: source.documents[1].metadata, embedding: nil
        )
        source.documents[3] = ExportedDocument(
            id: source.documents[3].id, document: source.documents[3].document,
            metadata: source.documents[3].metadata, embedding: nil
        )
        let exported = try await exportPackage(source)
        let manifest = try CollectionImporter.readManifest(at: exported.url)

        let destination = Destination()
        let embedder = Embedder()
        let report = try await CollectionImporter(destination: destination, embeddings: embedder).import(
            package: exported.url, manifest: manifest, into: "t", collectionName: "цель",
            options: .init(resumesFromCheckpoint: false, embeddingModel: "модель")
        )

        XCTAssertEqual(report.reembedded, 2, "пересчитаны только пустые места")
        XCTAssertEqual(embedder.asked.count, 2, "в модель ушли только документы без вектора")
        XCTAssertEqual(Set(embedder.asked), Set([source.documents[1].document, source.documents[3].document].compactMap { $0 }))
        // Привезённые пакетом векторы остались нетронутыми.
        XCTAssertEqual(destination.stored["d0"]?.embedding, [0, 0.5, -0.25, 0.125])
        XCTAssertEqual(destination.stored["d2"]?.embedding, [0.2, 0.5, -0.25, 0.125])
        // А пустые получили вектор модели — по длине текста, как её стенд.
        XCTAssertEqual(destination.stored["d1"]?.embedding.first, Double(source.documents[1].document?.count ?? 0))
    }

    /// Остановка на конфликте не уносит с собой чистые документы.
    ///
    /// Раньше `write` выходил, не записав **ничего**, — включая документы
    /// пачки до конфликтного, — а отметка о месте остановки всё равно
    /// вставала на конец пачки и не снималась. Следующий заход начинал уже
    /// после неё: пропадали и чистые документы, и сам конфликт, ради которого
    /// импорт останавливали. Молча, без следа в сводке.
    func testStoppingAtAConflictKeepsWhatCameBeforeIt() async throws {
        let source = Source()
        source.documents = documents(6)
        let exported = try await exportPackage(source)
        let manifest = try CollectionImporter.readManifest(at: exported.url)
        let store = ImportCheckpointStore(directory: box.appendingPathComponent("checkpoints-stop"))

        // Конфликт — на четвёртом документе, то есть в середине второй пачки.
        let destination = Destination()
        destination.stored["d3"] = EmbeddedRecord(id: "d3", document: "старое", embedding: [9, 9, 9, 9], metadata: [:])
        let importer = CollectionImporter(destination: destination, checkpoints: store)
        let stopped = try await importer.import(
            package: exported.url, manifest: manifest, into: "t", collectionName: "цель",
            options: .init(conflictPolicy: .stop, batchSize: 3)
        )

        XCTAssertEqual(stopped.stoppedAtConflict, "d3")
        XCTAssertFalse(stopped.finished)
        XCTAssertEqual(stopped.written, 3, "первая пачка обязана быть записана")
        XCTAssertEqual(destination.stored["d0"]?.document, source.documents[0].document)
        XCTAssertEqual(destination.stored["d2"]?.document, source.documents[2].document)

        // Отметка стоит на последнем записанном, а не на конце пачки.
        let checkpoint = try XCTUnwrap(store.load(checksum: manifest.dataSHA256))
        XCTAssertEqual(checkpoint.processedLines, 3, "отметка обязана указывать на записанное")

        // Продолжение после того, как человек разобрался с конфликтом:
        // ни один документ не потерян.
        let second = try await importer.import(
            package: exported.url, manifest: manifest, into: "t", collectionName: "цель",
            options: .init(conflictPolicy: .overwrite, batchSize: 3)
        )
        XCTAssertTrue(second.finished)
        XCTAssertEqual(destination.stored.count, 6, "после продолжения на месте все шесть")
        XCTAssertNotEqual(destination.stored["d3"]?.document, "старое", "конфликтный документ не пропущен")
    }

    /// Конфликт на первом документе пачки: записывать нечего, и отметка
    /// не должна уехать вперёд.
    func testAConflictOnTheFirstDocumentMovesNothing() async throws {
        let source = Source()
        source.documents = documents(4)
        let exported = try await exportPackage(source)
        let manifest = try CollectionImporter.readManifest(at: exported.url)
        let store = ImportCheckpointStore(directory: box.appendingPathComponent("checkpoints-first"))

        let destination = Destination()
        destination.stored["d0"] = EmbeddedRecord(id: "d0", document: "старое", embedding: [9, 9, 9, 9], metadata: [:])
        let report = try await CollectionImporter(destination: destination, checkpoints: store).import(
            package: exported.url, manifest: manifest, into: "t", collectionName: "цель",
            options: .init(conflictPolicy: .stop, batchSize: 2)
        )
        XCTAssertEqual(report.written, 0)
        let checkpoint = try XCTUnwrap(store.load(checksum: manifest.dataSHA256))
        XCTAssertEqual(checkpoint.processedLines, 0, "ничего не записано — отметке некуда двигаться")
    }

    /// Один битый документ не роняет перенос миллиона — и не исчезает молча.
    func testABrokenLineIsSkippedAndReported() async throws {
        let source = Source()
        source.documents = documents(5)
        let exported = try await exportPackage(source)
        let dataURL = exported.url.appendingPathComponent("documents.jsonl")
        var lines = try String(contentsOf: dataURL, encoding: .utf8).components(separatedBy: "\n")
        lines[2] = "{это не json"
        try Data(lines.joined(separator: "\n").utf8).write(to: dataURL)

        var manifest = try CollectionImporter.readManifest(at: exported.url)
        manifest.dataSHA256 = ""  // сумму мы только что сломали намеренно
        let destination = Destination()
        let report = try await CollectionImporter(destination: destination).import(
            package: exported.url, manifest: manifest, into: "t", collectionName: "цель",
            options: .init(resumesFromCheckpoint: false)
        )

        XCTAssertEqual(report.brokenLines, [3])
        XCTAssertEqual(report.written, 4, "остальные четыре записаны")
        XCTAssertTrue(report.finished)
    }

    /// Прерванный импорт продолжается с места остановки и даёт то же
    /// состояние, что непрерывный.
    func testAnInterruptedImportContinuesWhereItStopped() async throws {
        let source = Source()
        source.documents = documents(20)
        let exported = try await exportPackage(source)
        let manifest = try CollectionImporter.readManifest(at: exported.url)
        let store = ImportCheckpointStore(directory: box.appendingPathComponent("checkpoints"))

        // Первый заход обрывается на третьей пачке: так же, как его оборвала
        // бы упавшая сеть.
        let destination = Destination()
        destination.failsAfterUpserts = 2
        let importer = CollectionImporter(destination: destination, checkpoints: store)
        await XCTAssertThrowsErrorAsync(
            try await importer.import(
                package: exported.url, manifest: manifest, into: "t", collectionName: "цель",
                options: .init(batchSize: 5)
            )
        )
        XCTAssertEqual(destination.stored.count, 10, "успело записаться две пачки")

        // Отметка о месте остановки записана.
        let checkpoint = try XCTUnwrap(store.load(checksum: manifest.dataSHA256))
        XCTAssertEqual(checkpoint.processedLines, 10)

        // Второй заход дописывает остальное — и итог совпадает с непрерывным.
        destination.failsAfterUpserts = nil
        let second = try await importer.import(
            package: exported.url, manifest: manifest, into: "t", collectionName: "цель",
            options: .init(batchSize: 5)
        )
        XCTAssertEqual(second.written, 10, "второй заход дописал ровно оставшееся")
        XCTAssertTrue(second.finished)
        XCTAssertEqual(destination.stored.count, 20)
        XCTAssertNil(store.load(checksum: manifest.dataSHA256), "законченный импорт снимает отметку")
    }

    /// Коллекция с тем же именем, но другая — заведённая заново или на другом
    /// сервере — не продолжает чужой импорт с середины: первые строки иначе
    /// не записались бы вовсе, а отчёт сказал бы «готово».
    func testACheckpointIsNotReusedForAnotherCollectionWithTheSameName() async throws {
        let source = Source()
        source.documents = documents(20)
        let exported = try await exportPackage(source)
        let manifest = try CollectionImporter.readManifest(at: exported.url)
        let store = ImportCheckpointStore(directory: box.appendingPathComponent("checkpoints-other"))

        let first = Destination()
        first.failsAfterUpserts = 2
        await XCTAssertThrowsErrorAsync(
            try await CollectionImporter(destination: first, checkpoints: store).import(
                package: exported.url, manifest: manifest, into: "старая", collectionName: "цель",
                options: .init(batchSize: 5)
            )
        )

        let recreated = Destination()
        let report = try await CollectionImporter(destination: recreated, checkpoints: store).import(
            package: exported.url, manifest: manifest, into: "новая", collectionName: "цель",
            options: .init(batchSize: 5)
        )
        XCTAssertEqual(report.written, 20, "импорт в новую коллекцию начат с середины")
        XCTAssertEqual(recreated.stored.count, 20)
    }

    /// Пакет без векторов: модель обязательна, и она действительно вызывается.
    func testAPackageWithoutVectorsNeedsAModelAndUsesIt() async throws {
        let source = Source()
        source.documents = documents(6)
        let exported = try await CollectionExporter(source: source).export(
            collection: collection(),
            to: box.appendingPathComponent("без.chromaexport"),
            serverVersion: "1.0.0", tenant: "t", database: "d",
            options: .init(includesEmbeddings: false)
        )
        let manifest = try CollectionImporter.readManifest(at: exported.url)

        let destination = Destination()
        let embedder = Embedder()
        await XCTAssertThrowsErrorAsync(
            try await CollectionImporter(destination: destination, embeddings: embedder).import(
                package: exported.url, manifest: manifest, into: "t", collectionName: "цель",
                options: .init(resumesFromCheckpoint: false)
            )
        )

        let report = try await CollectionImporter(destination: destination, embeddings: embedder).import(
            package: exported.url, manifest: manifest, into: "t", collectionName: "цель",
            options: .init(resumesFromCheckpoint: false, embeddingModel: "e5")
        )
        XCTAssertEqual(report.written, 6)
        XCTAssertEqual(report.reembedded, 6)
        XCTAssertGreaterThan(embedder.calls, 0)
    }


    /// DoD этапа: сто тысяч документов не приводят к росту памяти приложения.
    ///
    /// Ради этого пункта формат и выбран построчным: и запись, и чтение идут
    /// потоком, и ни одна сторона не собирает файл целиком.
    func testAHundredThousandDocumentsDoNotGrowMemory() async throws {
        let source = Source()
        source.documents = (0..<100_000).map { index in
            ExportedDocument(
                id: "d\(index)",
                document: "Документ номер \(index). Текст, похожий на настоящий чанк по длине.",
                metadata: ["группа": .string(index % 2 == 0 ? "чёт" : "нечет")],
                embedding: [Double(index) / 1000, 0.5, -0.25, 0.125, 1, 2, 3, 4]
            )
        }

        let before = Self.footprintBytes()
        let exported = try await CollectionExporter(source: source).export(
            collection: collection(dimension: 8),
            to: box.appendingPathComponent("большой.chromaexport"),
            serverVersion: "1.0.0", tenant: "t", database: "d",
            options: .init(pageSize: 500)
        )
        let afterExport = Self.footprintBytes()
        XCTAssertEqual(exported.manifest.documentCount, 100_000)

        // Импорт идёт **настоящий**, через `CollectionImporter`: мерить надо
        // тот код, который поедет к пользователю, а не его подобие в тесте.
        // База-приёмник ничего не хранит — иначе мы бы мерили её память.
        let counting = CountingDestination()
        let report = try await CollectionImporter(
            destination: counting,
            checkpoints: ImportCheckpointStore(directory: box.appendingPathComponent("cp"))
        ).import(
            package: exported.url, manifest: exported.manifest,
            into: "t", collectionName: "цель",
            options: .init(batchSize: 500, resumesFromCheckpoint: false)
        )
        XCTAssertEqual(report.written, 100_000)
        let afterImport = Self.footprintBytes()

        // Стенд держит все сто тысяч документов в массиве — это его память,
        // а не память переноса; поэтому меряем рост **после** их создания.
        // Замер на этой машине: рост 25 МБ. Без пула вокруг разбора было 628 —
        // ради этой цифры тест и написан.
        let growth = max(afterExport, afterImport) - before
        XCTAssertLessThan(
            growth, 100 * 1024 * 1024,
            "перенос вырос в памяти на \(ByteCountFormatter.string(fromByteCount: growth, countStyle: .memory)) — значит, где-то файл собирается целиком"
        )
    }

    /// Сколько памяти занимает процесс сейчас.
    private static func footprintBytes() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    // MARK: - Размер и память

    /// Оценка размера — шестнадцать байт на компоненту вектора, а не восемь:
    /// в JSON она печатается текстом. Заниженная оценка опаснее завышенной.
    func testTheSizeEstimateCountsAVectorComponentAsText() {
        let estimate = CollectionExporter.estimatedBytes(documents: 1000, dimension: 1024)
        XCTAssertGreaterThan(estimate, Int64(1000 * 1024 * 8), "восьми байт на компоненту заведомо мало")
        XCTAssertGreaterThanOrEqual(estimate, Int64(1000 * 1024 * 16))
    }

    /// Файл читается кусками: длинная строка не должна ни теряться, ни
    /// собирать в память весь файл.
    func testTheReaderReturnsLinesLongerThanItsBuffer() throws {
        let url = box.appendingPathComponent("длинные.jsonl")
        let long = String(repeating: "я", count: JSONLinesReader.chunkSize + 5000)
        let text = "первая\n\(long)\nтретья\n"
        try Data(text.utf8).write(to: url)

        let reader = try JSONLinesReader(url: url)
        defer { reader.close() }
        XCTAssertEqual(String(data: try XCTUnwrap(reader.next()), encoding: .utf8), "первая")
        XCTAssertEqual(String(data: try XCTUnwrap(reader.next()), encoding: .utf8), long)
        XCTAssertEqual(String(data: try XCTUnwrap(reader.next()), encoding: .utf8), "третья")
        XCTAssertNil(try reader.next())
    }
}

/// `XCTAssertThrowsError` не умеет `async` — маленькая обёртка.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("ожидалась ошибка", file: file, line: line)
    } catch {}
}

extension CollectionTransferTests {
    /// Пакет без векторов в коллекцию **без** привязанной модели: векторы
    /// посчитает модель пакета, и сверка размерности нужна та же, что у
    /// пакета с векторами.
    func testAPackageWithoutVectorsIsCheckedAgainstAnUnboundCollection() async throws {
        let source = Source()
        source.documents = documents(3)
        let exported = try await exportPackage(source, options: CollectionExporter.Options(includesEmbeddings: false))
        let manifest = try CollectionImporter.readManifest(at: exported.url)
        XCTAssertFalse(manifest.includesEmbeddings)

        let unbound = ChromaCollection(
            id: "cid", name: "чужая",
            metadata: [CollectionBindingKeys.dimension: .int(768)]
        )
        XCTAssertThrowsError(try CollectionImporter.problems(manifest: manifest, target: unbound)) { error in
            XCTAssertEqual(error as? TransferError, .dimensionMismatch(expected: 768, got: 4))
        }
        // Той же размерности — не запрет, а предупреждение о модели.
        let sameSize = ChromaCollection(
            id: "cid", name: "чужая", metadata: [CollectionBindingKeys.dimension: .int(4)]
        )
        let warnings = try CollectionImporter.problems(manifest: manifest, target: sameSize)
        XCTAssertTrue(warnings.contains { $0.contains("не привязана модель") }, "\(warnings)")
        // Коллекция со своей моделью пересчитывает пакет ею — сверять нечего.
        XCTAssertEqual(try CollectionImporter.problems(manifest: manifest, target: collection(dimension: 768)), [])
    }
}
