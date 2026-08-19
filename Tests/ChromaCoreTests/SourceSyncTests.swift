import XCTest
import PDFKit
@testable import ChromaCore

// MARK: - Mapping

final class CollectionRouterTests: XCTestCase {
    private let router = CollectionRouter()

    private func source(_ mapping: SourceMapping, pattern: String = "", template: String = "$1", fallback: Bool = false) -> DataSource {
        DataSource(
            name: "docs",
            path: "/tmp/docs",
            mapping: mapping,
            collectionName: "docs_col",
            rulePattern: pattern,
            ruleTemplate: template,
            ruleUsesFallbackCollection: fallback
        )
    }

    func testFolderToOneCollectionAddsNoPath() {
        let outcome = router.route(relativePath: "sub/a.md", source: source(.folderToCollection))
        XCTAssertEqual(outcome.route?.collectionName, "docs_col")
        XCTAssertTrue(outcome.route?.extraMetadata.isEmpty ?? false)
    }

    /// Путь файла хранит `source_file`, который пишет синхронизация всем
    /// режимам разом. Второе поле с тем же содержимым маршрутизатор больше
    /// не добавляет.
    func testSingleCollectionAddsNoSecondPathField() {
        let outcome = router.route(relativePath: "sub/deep/a.md", source: source(.singleCollectionWithRelativePath))
        XCTAssertEqual(outcome.route?.collectionName, "docs_col")
        XCTAssertNil(outcome.route?.extraMetadata["relative_path"])
    }

    func testSubfoldersBecomeCollections() {
        let mapping = source(.subfoldersToCollections)
        XCTAssertEqual(router.route(relativePath: "legal/a.md", source: mapping).route?.collectionName, "legal")
        XCTAssertEqual(router.route(relativePath: "legal/deep/b.md", source: mapping).route?.collectionName, "legal")
        // A file lying in the root has no subfolder to be named after.
        XCTAssertEqual(router.route(relativePath: "top.md", source: mapping).route?.collectionName, "docs_col")
    }

    func testSubfolderNamesAreSanitisedForChromaDB() {
        // ChromaDB accepts ASCII only, so a Russian folder name cannot be used as is.
        let outcome = router.route(relativePath: "Мои заметки/a.md", source: source(.subfoldersToCollections))
        let name = outcome.route?.collectionName ?? ""
        XCTAssertTrue(CollectionNaming.isValid(name), "«\(name)» должно быть валидным именем коллекции")
    }

    func testManualRuleExpandsTemplate() {
        let mapping = source(.manualRule, pattern: "^([^/]+)/", template: "kb_$1")
        XCTAssertEqual(router.route(relativePath: "legal/a.md", source: mapping).route?.collectionName, "kb_legal")
    }

    func testManualRuleWithoutMatchIsUnroutableUnlessFallbackIsOn() {
        let strict = source(.manualRule, pattern: "^docs/", template: "kb")
        guard case .unroutable = router.route(relativePath: "other/a.md", source: strict) else {
            return XCTFail("файл без совпадения не должен молча уходить в коллекцию по умолчанию")
        }

        let lenient = source(.manualRule, pattern: "^docs/", template: "kb", fallback: true)
        XCTAssertEqual(router.route(relativePath: "other/a.md", source: lenient).route?.collectionName, "docs_col")
    }

    func testBrokenRuleIsReportedInsteadOfCrashing() {
        let broken = source(.manualRule, pattern: "^([", template: "$1")
        guard case .unroutable(let reason) = router.route(relativePath: "a.md", source: broken) else {
            return XCTFail("некомпилируемое выражение должно давать понятную причину")
        }
        XCTAssertTrue(reason.contains("не компилируется"))
    }

    func testRuleProblemCatchesMissingCaptureGroup() {
        XCTAssertNil(CollectionRouter.ruleProblem(pattern: "^([^/]+)/", template: "$1"))
        XCTAssertNotNil(CollectionRouter.ruleProblem(pattern: "^docs/", template: "$2"))
        XCTAssertNotNil(CollectionRouter.ruleProblem(pattern: "", template: "$1"))
        XCTAssertNotNil(CollectionRouter.ruleProblem(pattern: "^([", template: "$1"))
    }

    func testTooShortFolderNameIsPaddedToAValidCollectionName() {
        // ChromaDB demands at least three characters, so a folder named "b"
        // cannot become a collection called "b".
        let name = router.route(relativePath: "b/1.md", source: source(.subfoldersToCollections)).route?.collectionName
        XCTAssertEqual(name, "b_col")
        XCTAssertTrue(CollectionNaming.isValid(name ?? ""))
    }
}

// MARK: - Chunking signature

final class ChunkingSignatureTests: XCTestCase {
    func testSignatureChangesWithEveryParameterThatAffectsChunks() {
        let base = ChunkingConfiguration()
        var other = base
        other.chunkSize = 256
        XCTAssertNotEqual(base.signature, other.signature)

        other = base
        other.overlapPercent = 30
        XCTAssertNotEqual(base.signature, other.signature)

        other = base
        other.sizeUnit = .characters
        XCTAssertNotEqual(base.signature, other.signature)

        other = base
        other.separators = ["\n"]
        XCTAssertNotEqual(base.signature, other.signature)

        other = base
        other.strategy = .fixed
        XCTAssertNotEqual(base.signature, other.signature)
    }

    func testSeparatorsDoNotAffectFixedSizeSignature() {
        // Fixed-size ignores separators, so changing them must not force a
        // pointless re-chunk of the whole source.
        var first = ChunkingConfiguration(strategy: .fixed)
        var second = first
        second.separators = ["!!!"]
        XCTAssertEqual(first.signature, second.signature)

        first.strategy = .recursive
        second.strategy = .recursive
        XCTAssertNotEqual(first.signature, second.signature)
    }

    func testSignatureIsStableAcrossCalls() {
        let configuration = ChunkingConfiguration()
        XCTAssertEqual(configuration.signature, ChunkingConfiguration().signature)
    }
}

// MARK: - Text extraction

final class DocumentExtractionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func extract(_ url: URL) async throws -> ExtractedDocument {
        try await ExtractorRegistry.standard().extract(from: url, options: ExtractionOptions())
    }

    func testPlainTextIsReadAndTrimmed() async throws {
        let url = try write("\n  привет  \n", "a.md")
        let extracted = try await extract(url)
        XCTAssertEqual(extracted.plainText, "привет")
        XCTAssertEqual(extracted.extractorID, "plaintext")
    }

    func testEmptyFileIsSkippedWithAReason() async throws {
        let url = try write("   \n", "empty.txt")
        await XCTAssertThrowsErrorAsync(try await extract(url)) { error in
            XCTAssertEqual(error as? ExtractionError, .empty)
        }
    }

    func testUnsupportedFormatsAreNamedNotGuessed() async throws {
        // `.numbers` is a spreadsheet and belongs to stage 5, not to extraction.
        let url = try write("PK\u{0003}\u{0004}", "budget.numbers")
        await XCTAssertThrowsErrorAsync(try await extract(url)) { error in
            guard case .unsupportedFormat = error as? ExtractionError else {
                return XCTFail("ожидался отказ по формату, получено \(error)")
            }
        }
    }

    /// `.docx` is read since 4.4, so a broken one is no longer «формат не
    /// поддерживается» — it is a file that did not open, with the reason the
    /// system gave (: never a silent skip).
    func testABrokenOfficeFileIsRefusedWithItsOwnReason() async throws {
        let url = try write("PK\u{0003}\u{0004}", "report.docx")
        await XCTAssertThrowsErrorAsync(try await extract(url)) { error in
            guard case .corrupted(let detail) = error as? ExtractionError else {
                return XCTFail("ожидалась причина отказа, получено \(error)")
            }
            XCTAssertFalse(detail.isEmpty)
        }
    }

    func testBinaryFileIsRefused() async throws {
        let url = root.appendingPathComponent("blob.txt")
        try Data([0x00, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04, 0x00, 0x05, 0x00, 0x06]).write(to: url)
        await XCTAssertThrowsErrorAsync(try await extract(url))
    }

    func testPDFWithTextLayerIsExtracted() async throws {
        let url = root.appendingPathComponent("doc.pdf")
        try makePDF(text: "Договор об оказании услуг", at: url)

        let extracted = try await extract(url)
        XCTAssertTrue(extracted.plainText.contains("Договор"), extracted.plainText)
        XCTAssertEqual(extracted.extractorID, "pdfkit")
        XCTAssertEqual(extracted.containerFormat, "pdf")
        XCTAssertEqual(extracted.pageCount, 1)
        XCTAssertEqual(extracted.pageNumber(forCharacter: 0), 1)
    }

    func testBrokenPDFIsReportedNotCrashed() async throws {
        let url = try write("это совсем не PDF", "fake.pdf")
        await XCTAssertThrowsErrorAsync(try await extract(url)) { error in
            guard case .corrupted = error as? ExtractionError else {
                return XCTFail("битый PDF должен давать причину, получено \(error)")
            }
        }
    }

    /// Draws one page with PDFKit so the test does not need a fixture binary.
    private func makePDF(text: String, at url: URL) throws {
        var bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else {
            throw XCTSkip("не удалось создать PDF-контекст")
        }
        context.beginPDFPage(nil as CFDictionary?)
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 24)])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 60, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        try data.write(to: url)
    }
}

// MARK: - Manifest and planning

final class SourceSyncPlanTests: XCTestCase {
    private var root: URL!
    private var manifestsDirectory: URL!
    private var service: SourceSyncService!
    private var store: ManifestStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-sync-\(UUID().uuidString)")
        manifestsDirectory = root.appendingPathComponent("manifests")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        store = ManifestStore(directory: manifestsDirectory)
        service = SourceSyncService(manifests: store)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var folder: URL { root.appendingPathComponent("docs") }

    private func makeSource() -> DataSource {
        DataSource(
            name: "docs",
            path: folder.path,
            fileExtensions: ["md"],
            recursive: true,
            collectionName: "docs_col"
        )
    }

    private func write(_ text: String, _ name: String) throws {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Pretends a file was already indexed, so the planner has something to
    /// compare against without needing a server.
    private func recordEntry(for name: String, in source: DataSource, text: String, model: String = "m") throws {
        let url = folder.appendingPathComponent(name)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        var manifest = store.load(sourceID: source.id)
        manifest.record(ManifestEntry(
            relativePath: name,
            contentHash: SourceSyncService.contentHash(of: text),
            modifiedAt: (attributes[.modificationDate] as? Date) ?? Date(),
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            chunkIDs: [SourceSyncService.documentID(relativePath: name, chunkIndex: 0)],
            collectionName: "docs_col",
            chunkingSignature: source.chunking.signature,
            embeddingModel: model
        ))
        store.save(manifest)
    }

    func testFirstRunSeesEverythingAsNew() async throws {
        try write("первый документ", "a.md")
        try write("второй документ", "sub/b.md")

        let plan = try await service.plan(source: makeSource(), embeddingModel: "m")
        XCTAssertEqual(plan.newCount, 2)
        XCTAssertEqual(plan.unchangedCount, 0)
        XCTAssertTrue(plan.hasWork)
        XCTAssertEqual(plan.targetCollections, ["docs_col"])
    }

    func testUnchangedFileIsNotRewritten() async throws {
        let source = makeSource()
        try write("текст", "a.md")
        try recordEntry(for: "a.md", in: source, text: "текст")

        let plan = try await service.plan(source: source, embeddingModel: "m")
        XCTAssertEqual(plan.unchangedCount, 1)
        XCTAssertEqual(plan.newCount, 0)
        XCTAssertFalse(plan.hasWork, "повторный запуск без изменений не должен пересчитывать векторы")
    }

    func testEditedFileIsMarkedChanged() async throws {
        let source = makeSource()
        try write("текст", "a.md")
        try recordEntry(for: "a.md", in: source, text: "текст")
        try write("другой текст", "a.md")

        let plan = try await service.plan(source: source, embeddingModel: "m")
        XCTAssertEqual(plan.changedCount, 1)
        guard case .changed(let reason) = plan.items.first?.kind else { return XCTFail("ожидался changed") }
        XCTAssertTrue(reason.contains("содержимое"), reason)
    }

    func testTouchedButIdenticalFileStaysUnchanged() async throws {
        let source = makeSource()
        try write("текст", "a.md")
        try recordEntry(for: "a.md", in: source, text: "текст")
        // Same bytes, new mtime — a copy or a re-save, not an edit.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(600)],
            ofItemAtPath: folder.appendingPathComponent("a.md").path
        )

        let plan = try await service.plan(source: source, embeddingModel: "m")
        XCTAssertEqual(plan.unchangedCount, 1, "изменился только timestamp — переэмбеживать нечего")
    }

    func testChangedChunkingParametersForceRechunk() async throws {
        var source = makeSource()
        try write("текст", "a.md")
        try recordEntry(for: "a.md", in: source, text: "текст")

        source.chunking.chunkSize = 128
        let plan = try await service.plan(source: source, embeddingModel: "m")
        guard case .changed(let reason) = plan.items.first?.kind else { return XCTFail("ожидался changed") }
        XCTAssertTrue(reason.contains("чанкинга"), reason)
    }

    func testChangedModelForcesRechunk() async throws {
        let source = makeSource()
        try write("текст", "a.md")
        try recordEntry(for: "a.md", in: source, text: "текст", model: "old-model")

        let plan = try await service.plan(source: source, embeddingModel: "new-model")
        guard case .changed(let reason) = plan.items.first?.kind else { return XCTFail("ожидался changed") }
        XCTAssertTrue(reason.contains("модель"), reason)
    }

    func testVanishedFileNeedsADecisionAndIsNotDeleted() async throws {
        let source = makeSource()
        try write("текст", "a.md")
        try recordEntry(for: "a.md", in: source, text: "текст")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("a.md"))

        let plan = try await service.plan(source: source, embeddingModel: "m")
        XCTAssertEqual(plan.newlyMissing.count, 1)
        XCTAssertEqual(plan.pendingRemovals.first?.relativePath, "a.md")
        XCTAssertFalse(plan.hasWork)
        // The manifest still holds the entry: nothing was deleted on our own.
        XCTAssertNotNil(store.load(sourceID: source.id).entries["a.md"])
    }

    /// Файл вернули на диск — решать нечего, и список требующих решения
    /// очищается сам. Иначе плашка «файлы исчезли с диска» висела на экране,
    /// пока по каждой строке не нажмут «Оставить в базе».
    func testReturnedFileLeavesTheDecisionList() async throws {
        let source = makeSource()
        try write("текст", "a.md")
        try recordEntry(for: "a.md", in: source, text: "текст")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("a.md"))

        let missing = try await service.plan(source: source, embeddingModel: "m")
        XCTAssertEqual(missing.pendingRemovals.count, 1)
        var manifest = store.load(sourceID: source.id)
        manifest.pendingRemovals = missing.pendingRemovals
        store.save(manifest)

        try write("текст", "a.md")
        let plan = try await service.plan(source: source, embeddingModel: "m")
        XCTAssertTrue(plan.pendingRemovals.isEmpty, "вернувшийся файл не требует решения")
    }

    func testFileKeptByUserIsNotReportedAgain() async throws {
        let source = makeSource()
        try write("текст", "a.md")
        try recordEntry(for: "a.md", in: source, text: "текст")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("a.md"))

        _ = try await service.resolve(
            removal: PendingRemoval(relativePath: "a.md", collectionName: "docs_col", chunkIDs: []),
            decision: .keepInDatabase,
            source: source,
            chroma: nil
        )

        let plan = try await service.plan(source: source, embeddingModel: "m")
        XCTAssertTrue(plan.pendingRemovals.isEmpty, "решение пользователя не должно спрашиваться повторно")
    }

    func testUnsupportedFileIsSkippedWithReasonAndNotCountedAsWork() async throws {
        var source = makeSource()
        source.fileExtensions = ["md", "docx"]
        try write("текст", "a.md")
        try write("PK", "b.docx")

        let plan = try await service.plan(source: source, embeddingModel: "m")
        XCTAssertEqual(plan.skippedCount, 1)
        XCTAssertEqual(plan.newCount, 1)
    }

    func testUnroutableFilesAreListedSeparately() async throws {
        var source = makeSource()
        source.mapping = .manualRule
        source.rulePattern = "^legal/"
        source.ruleTemplate = "legal_kb"
        try write("текст", "legal/a.md")
        try write("текст", "other/b.md")

        let plan = try await service.plan(source: source, embeddingModel: "m")
        XCTAssertEqual(plan.unroutableCount, 1)
        XCTAssertEqual(plan.newCount, 1)
        XCTAssertEqual(plan.targetCollections, ["legal_kb"])
    }

    func testPlanRefusesABrokenRuleUpFront() async throws {
        var source = makeSource()
        source.mapping = .manualRule
        source.rulePattern = "^(["
        try write("текст", "a.md")

        do {
            _ = try await service.plan(source: source, embeddingModel: "m")
            XCTFail("план должен отказаться работать с некорректным правилом")
        } catch let error as SyncError {
            guard case .ruleInvalid = error else { return XCTFail("ожидалась ruleInvalid, получено \(error)") }
        }
    }

    func testMissingFolderIsAClearError() async throws {
        var source = makeSource()
        source.path = root.appendingPathComponent("nope").path
        do {
            _ = try await service.plan(source: source, embeddingModel: "m")
            XCTFail("ожидалась ошибка")
        } catch let error as SyncError {
            guard case .folderMissing = error else { return XCTFail("ожидалась folderMissing") }
        }
    }

    func testManifestRoundTrip() throws {
        let id = UUID()
        var manifest = SourceManifest(sourceID: id)
        manifest.record(ManifestEntry(
            relativePath: "a.md",
            contentHash: "hash",
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            size: 12,
            chunkIDs: ["x-0", "x-1"],
            collectionName: "docs_col",
            chunkingSignature: "sig",
            embeddingModel: "m"
        ))
        store.save(manifest)

        let loaded = store.load(sourceID: id)
        XCTAssertEqual(loaded.fileCount, 1)
        XCTAssertEqual(loaded.chunkCount, 2)
        XCTAssertEqual(loaded.collections, ["docs_col"])
        XCTAssertEqual(loaded.entries["a.md"]?.contentHash, "hash")
    }

    func testCorruptManifestIsRebuiltInsteadOfBlockingSync() throws {
        let id = UUID()
        try FileManager.default.createDirectory(at: manifestsDirectory, withIntermediateDirectories: true)
        try "{ это не json".write(to: store.fileURL(for: id), atomically: true, encoding: .utf8)
        XCTAssertEqual(store.load(sourceID: id).fileCount, 0)
    }
}

// MARK: - Schema hookup

final class SourceSchemaCoverageTests: XCTestCase {
    private let service = SourceSyncService(manifests: ManifestStore(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cdbm-coverage")))

    private func source(metadata: [String: String] = [:], mapping: SourceMapping = .folderToCollection) -> DataSource {
        DataSource(
            name: "docs",
            path: "/tmp/docs",
            mapping: mapping,
            collectionName: "docs_col",
            customMetadata: metadata
        )
    }

    func testAutoFieldsCoverASchemaBuiltFromThem() async {
        let schema = MetadataSchema(collectionName: "docs_col", fields: [
            MetadataField(key: "source_file", type: .string, isRequired: true),
            MetadataField(key: "file_size", type: .integer, isRequired: true),
        ])
        let report = await service.coverage(source: source(), schema: schema)
        XCTAssertTrue(report.isSatisfied)
    }

    func testRequiredFieldNobodyFillsIsReported() async {
        let schema = MetadataSchema(collectionName: "docs_col", fields: [
            MetadataField(key: "department", type: .string, isRequired: true),
        ])
        let report = await service.coverage(source: source(), schema: schema)
        XCTAssertEqual(report.uncoveredRequiredFields, ["department"])
        XCTAssertFalse(report.isSatisfied)
    }

    func testSourceMetadataClosesTheGap() async {
        let schema = MetadataSchema(collectionName: "docs_col", fields: [
            MetadataField(key: "department", type: .string, isRequired: true),
        ])
        let report = await service.coverage(source: source(metadata: ["department": "legal"]), schema: schema)
        XCTAssertTrue(report.uncoveredRequiredFields.isEmpty)
    }

    func testFieldWithADefaultCountsAsCovered() async {
        let schema = MetadataSchema(collectionName: "docs_col", fields: [
            MetadataField(key: "department", type: .string, isRequired: true, defaultValue: "unknown"),
        ])
        let report = await service.coverage(source: source(), schema: schema)
        XCTAssertTrue(report.isSatisfied)
    }

    func testWrongTypeInSourceMetadataIsCaughtBeforeTheRun() async {
        let schema = MetadataSchema(collectionName: "docs_col", fields: [
            MetadataField(key: "year", type: .integer),
        ])
        let report = await service.coverage(source: source(metadata: ["year": "две тысячи"]), schema: schema)
        XCTAssertEqual(report.typeProblems.count, 1)
        XCTAssertFalse(report.isSatisfied)
    }

    /// Схема, требующая `relative_path`, больше не покрывается ничем: поле
    /// перестало писаться. Сказать об этом честно важнее, чем
    /// промолчать: коллекция со строгой схемой иначе получила бы чанки без
    /// обязательного поля.
    func testASchemaAskingForRelativePathIsNoLongerCovered() async {
        let schema = MetadataSchema(collectionName: "docs_col", fields: [
            MetadataField(key: "relative_path", type: .string, isRequired: true),
        ])
        let plain = await service.coverage(source: source(), schema: schema)
        XCTAssertEqual(plain.uncoveredRequiredFields, ["relative_path"])

        let pathAware = await service.coverage(
            source: source(mapping: .singleCollectionWithRelativePath),
            schema: schema
        )
        XCTAssertEqual(pathAware.uncoveredRequiredFields, ["relative_path"])
    }

    /// А путь файла покрыт всегда и любым режимом — полем `source_file`,
    /// вместе с отпечатком `file_id`.
    func testThePathAndTheFingerprintAreAlwaysProvided() async {
        let schema = MetadataSchema(collectionName: "docs_col", fields: [
            MetadataField(key: "source_file", type: .string, isRequired: true),
            MetadataField(key: "file_id", type: .string, isRequired: true),
        ])
        let report = await service.coverage(source: source(), schema: schema)
        XCTAssertTrue(report.isSatisfied, "\(report.uncoveredRequiredFields)")
    }

    func testStrictSchemaDoesNotFightTheSourcePipeline() {
        // A strict schema forbids extra fields, but the auto fields of a source
        // are technical and must not be reported as violations.
        let schema = MetadataSchema(
            collectionName: "docs_col",
            fields: [MetadataField(key: "department", type: .string)],
            allowsExtraFields: false
        )
        let metadata: ChromaMetadata = [
            "department": .string("legal"),
            "source_file": .string("a.md"),
            "chunk_index": .int(0),
            "content_hash": .string("abc"),
            "_cdbm_model": .string("m"),
        ]
        let result = MetadataSchemaValidator().validate(metadata, against: schema)
        XCTAssertTrue(result.isValid, result.violations.map(\.message).joined(separator: "; "))
    }

    func testSchemaDraftFromSourceSkipsTechnicalFields() {
        let draft = MetadataSchema.drafted(
            collectionName: "docs_col",
            from: source(metadata: ["department": "legal", "source_file": "нельзя"])
        )
        XCTAssertEqual(draft.fields.map(\.trimmedKey), ["department"])
        XCTAssertEqual(draft.fields.first?.defaultValue, "legal")
    }
}
