import XCTest
import PDFKit
@testable import ChromaCore

/// what the diagnostics screen is allowed to say, and where it gets it.
final class FileRemedyTests: XCTestCase {
    func testAScanIsOfferedRecognition() {
        XCTAssertEqual(FileProblem.remedy(for: ExtractionError.noTextLayer(looksLikeScan: true)), .enableOCR)
    }

    /// A PDF with no text and no sign of being a scan has nothing to recognise.
    /// Offering OCR there costs minutes per file and finds nothing.
    func testAnEmptyPDFIsNotOfferedRecognition() {
        XCTAssertEqual(FileProblem.remedy(for: ExtractionError.noTextLayer(looksLikeScan: false)), .exclude)
    }

    func testALockedFileAsksForAPassword() {
        XCTAssertEqual(FileProblem.remedy(for: ExtractionError.passwordProtected), .password)
    }

    /// The stored password did not work — the fix is still a password, and the
    /// reason text is what says the old one was wrong.
    func testAWrongPasswordStillAsksForAPassword() {
        XCTAssertEqual(FileProblem.remedy(for: ExtractionError.wrongPassword), .password)
        XCTAssertNotEqual(
            ExtractionError.wrongPassword.errorDescription,
            ExtractionError.passwordProtected.errorDescription
        )
    }

    func testWhatMayWorkNextTimeIsOfferedARetry() {
        XCTAssertEqual(FileProblem.remedy(for: ExtractionError.timedOut(seconds: 60)), .retry)
        XCTAssertEqual(FileProblem.remedy(for: ExtractionError.applicationUnavailable("Pages не отвечает")), .retry)
    }

    /// Nothing to try: DRM, a format nobody reads, a file that is not a file.
    func testWhatCannotBeFixedIsOfferedExclusion() {
        XCTAssertEqual(FileProblem.remedy(for: ExtractionError.drmProtected), .exclude)
        XCTAssertEqual(FileProblem.remedy(for: ExtractionError.unsupportedFormat("xyz")), .exclude)
        XCTAssertEqual(FileProblem.remedy(for: ExtractionError.corrupted("не архив")), .exclude)
        XCTAssertEqual(FileProblem.remedy(for: ExtractionError.empty), .exclude)
    }

    /// Anything that is not an extraction failure at all — a network blip, a
    /// cancelled task — is worth trying again rather than declared hopeless.
    func testAnUnknownFailureIsWorthRetrying() {
        XCTAssertEqual(FileProblem.remedy(for: URLError(.timedOut)), .retry)
    }
}

// MARK: - What the manifest remembers

final class ManifestDiagnosticsTests: XCTestCase {
    private func entry(_ path: String, warnings: [String] = []) -> ManifestEntry {
        ManifestEntry(
            relativePath: path, contentHash: "hash", modifiedAt: Date(), size: 10,
            chunkIDs: ["a"], collectionName: "col", chunkingSignature: "sig",
            embeddingModel: "model", warnings: warnings
        )
    }

    func testWarningsSurviveARoundTrip() throws {
        var manifest = SourceManifest(sourceID: UUID())
        manifest.record(entry("a.docx", warnings: ["таблицы приведены к тексту, разметка потеряна"]))
        manifest.record(entry("b.md"))
        manifest.problems = [FileProblem(relativePath: "c.pdf", reason: "файл защищён паролем", remedy: .password)]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(SourceManifest.self, from: try encoder.encode(manifest))

        XCTAssertEqual(restored.warnedEntries.map(\.relativePath), ["a.docx"])
        XCTAssertEqual(restored.problems.map(\.remedy), [.password])
    }

    /// A manifest written before 4.9 has neither field and must still load —
    /// the alternative is re-indexing every source on update.
    func testAManifestFromBeforeDiagnosticsStillLoads() throws {
        let json = """
        {"sourceID":"\(UUID().uuidString)","version":1,"entries":{},"pendingRemovals":[]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(SourceManifest.self, from: Data(json.utf8))
        XCTAssertTrue(manifest.problems.isEmpty)
        XCTAssertTrue(manifest.warnedEntries.isEmpty)
    }

    /// The screen must not keep accusing a file that has since been read.
    func testIndexingAFileClearsItsProblem() {
        var manifest = SourceManifest(sourceID: UUID())
        manifest.problems = [
            FileProblem(relativePath: "a.pdf", reason: "нет текстового слоя", remedy: .enableOCR),
            FileProblem(relativePath: "b.pdf", reason: "файл защищён паролем", remedy: .password),
        ]
        manifest.record(entry("a.pdf"))
        XCTAssertEqual(manifest.problems.map(\.relativePath), ["b.pdf"])
    }
}

// MARK: - Passwords

final class DocumentPasswordTests: XCTestCase {
    /// The same file name under two sources is two files; a password given for
    /// one is not an answer for the other.
    func testTheAccountIsPerSourceAndPerPath() {
        let first = UUID(), second = UUID()
        XCTAssertNotEqual(
            DocumentPasswordStore.account(sourceID: first, relativePath: "a.pdf"),
            DocumentPasswordStore.account(sourceID: second, relativePath: "a.pdf")
        )
        XCTAssertNotEqual(
            DocumentPasswordStore.account(sourceID: first, relativePath: "a.pdf"),
            DocumentPasswordStore.account(sourceID: first, relativePath: "b.pdf")
        )
        XCTAssertEqual(
            DocumentPasswordStore.account(sourceID: first, relativePath: "a.pdf"),
            DocumentPasswordStore.account(sourceID: first, relativePath: "a.pdf")
        )
    }

    /// The path itself is not written into the Keychain: that item list is
    /// readable in Keychain Access, and the user's folder tree is not this
    /// app's to publish there.
    func testTheAccountDoesNotContainThePath() {
        let account = DocumentPasswordStore.account(sourceID: UUID(), relativePath: "Личное/Договоры/аренда.pdf")
        XCTAssertFalse(account.contains("аренда"))
        XCTAssertFalse(account.contains("Договоры"))
    }

    /// And it never travels: settings transfer carries sources, so a password
    /// living on the source would land on another machine.
    func testThePasswordIsNotPartOfTheSource() throws {
        var source = DataSource(name: "s", path: "/tmp", collectionName: "c")
        source.excludedPaths = ["secret.pdf"]
        let encoded = try JSONEncoder().encode(source)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.lowercased().contains("password"))
    }
}

// MARK: - Unlocking

final class PDFUnlockTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A PDF with a real text layer, then encrypted — so «opened» can be checked
    /// by reading the words out of it rather than by which error came back.
    ///
    /// The password is ASCII because the PDF standard security handler encodes
    /// it as Latin-1; a Cyrillic one makes the write fail outright.
    @MainActor
    private func lockedPDF(password: String) throws -> URL {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var mediaBox = bounds
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("Sekretnyy dokument" as NSString).draw(
            in: bounds.insetBy(dx: 60, dy: 60),
            withAttributes: [.font: NSFont.systemFont(ofSize: 18)]
        )
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()

        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        let url = root.appendingPathComponent("locked.pdf")
        let options: [PDFDocumentWriteOption: Any] = [
            .userPasswordOption: password,
            .ownerPasswordOption: password,
        ]
        guard document.write(to: url, withOptions: options) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    @MainActor
    func testWithoutAPasswordTheFileAsksForOne() async throws {
        let url = try lockedPDF(password: "s3cret")
        await XCTAssertThrowsErrorAsync(
            try await PDFExtractor().extract(from: url, options: ExtractionOptions())
        ) { error in
            XCTAssertEqual(error as? ExtractionError, .passwordProtected)
        }
    }

    /// The distinction the whole `wrongPassword` case exists for: the user is
    /// told their password is wrong instead of being asked for it again.
    @MainActor
    func testAWrongPasswordSaysSoRatherThanAskingAgain() async throws {
        let url = try lockedPDF(password: "s3cret")
        await XCTAssertThrowsErrorAsync(
            try await PDFExtractor().extract(from: url, options: ExtractionOptions(password: "wrong-one"))
        ) { error in
            XCTAssertEqual(error as? ExtractionError, .wrongPassword)
        }
    }

    @MainActor
    func testTheRightPasswordOpensTheFile() async throws {
        let url = try lockedPDF(password: "s3cret")
        let extracted = try await PDFExtractor().extract(from: url, options: ExtractionOptions(password: "s3cret"))
        XCTAssertEqual(extracted.extractorID, "pdfkit")
        XCTAssertTrue(extracted.plainText.contains("Sekretnyy"), extracted.plainText)
    }

    func testAnUnlockedDocumentNeedsNothing() throws {
        XCTAssertNoThrow(try PDFExtractor.unlockIfNeeded(PDFDocument(), password: nil))
    }
}

// MARK: - Exclusion

/// 11's «исключить»: stop trying to read this file — which is not the same
/// as deleting what it already put in the collection (rule 1 of Приложение 5).
final class ExcludedPathTests: XCTestCase {
    private var root: URL!
    private var manifests: ManifestStore!
    private var service: SourceSyncService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-excl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        manifests = ManifestStore(directory: root.appendingPathComponent("manifests"))
        service = SourceSyncService(manifests: manifests)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var folder: URL { root.appendingPathComponent("docs") }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func makeSource(excluding: [String] = []) -> DataSource {
        var source = DataSource(
            name: "docs", path: folder.path, fileExtensions: ["md"], recursive: true, collectionName: "docs_col"
        )
        source.excludedPaths = excluding
        return source
    }

    func testAnExcludedFileIsNotPlanned() async throws {
        try write("keep.md", "текст первого файла")
        try write("skip.md", "текст второго файла")

        let plan = try await service.plan(source: makeSource(excluding: ["skip.md"]), embeddingModel: "m")
        XCTAssertEqual(plan.items.map(\.relativePath), ["keep.md"])
    }

    /// Excluding a file that is already in the collection does not silently drop
    /// its chunks: it becomes «требует решения», the same as a file that vanished.
    func testExcludingAnIndexedFileAsksRatherThanDeletes() async throws {
        try write("skip.md", "текст")
        // One source throughout: `DataSource` mints a new id on every init, and
        // a manifest saved under a different id is a manifest for another source.
        var source = makeSource()

        var manifest = manifests.load(sourceID: source.id)
        manifest.record(ManifestEntry(
            relativePath: "skip.md", contentHash: "h", modifiedAt: Date(), size: 5,
            chunkIDs: ["skip.md#0"], collectionName: "docs_col",
            chunkingSignature: source.chunking.signature, embeddingModel: "m"
        ))
        manifests.save(manifest)

        source.excludedPaths = ["skip.md"]
        let plan = try await service.plan(source: source, embeddingModel: "m")
        XCTAssertEqual(plan.newlyMissing.map(\.relativePath), ["skip.md"])
        XCTAssertEqual(plan.newlyMissing.first?.chunkIDs, ["skip.md#0"])
    }

    func testExclusionSurvivesAConfigurationRoundTrip() throws {
        var source = DataSource(name: "s", path: "/tmp", collectionName: "c")
        source.excludedPaths = ["a/b.pdf"]
        let decoded = try JSONDecoder().decode(DataSource.self, from: try JSONEncoder().encode(source))
        XCTAssertEqual(decoded.excludedPaths, ["a/b.pdf"])
    }

    /// Exclusion is about which files are read, not about how they are read —
    /// so it must not make every other file in the source look re-extractable.
    func testExclusionIsNotPartOfTheExtractionSignature() {
        var source = DataSource(name: "s", path: "/tmp", collectionName: "c")
        let before = source.extractionSignature
        source.excludedPaths = ["a.pdf"]
        XCTAssertEqual(before, source.extractionSignature)
    }
}

// MARK: - The preview and the sync agree

/// The preview exists to be believed, so it has to run the rule the sync runs.
final class PlannedChunksTests: XCTestCase {
    private func configuration(_ strategy: ChunkStrategy = .recursive) -> ChunkingConfiguration {
        ChunkingConfiguration(strategy: strategy, chunkSize: 200, sizeUnit: .characters, overlapPercent: 0)
    }

    private var pipeline: ChunkingPipeline { ChunkingPipeline(configuration: configuration()) }

    private func document(parts: [DocumentPart], text: String, ocr: Bool? = nil) -> ExtractedDocument {
        ExtractedDocument(
            plainText: text, pageStarts: parts.map(\.start), parts: parts,
            containerFormat: "key", extractorID: "iwork", extractorVersion: 1, ocrUsed: ocr
        )
    }

    func testAPresentationIsCutBySlideAndNotByTheStrategy() async throws {
        let text = "Слайд первый\nего текст\n\nСлайд второй\nего текст"
        let parts = [
            DocumentPart(kind: .slide, index: 0, id: "slide-1", start: 0),
            DocumentPart(kind: .slide, index: 1, id: "slide-2", start: text.distance(
                from: text.startIndex, to: text.range(of: "Слайд второй")!.lowerBound
            )),
        ]
        let chunks = try await SourceSyncService.plannedChunks(
            of: document(parts: parts, text: text),
            fileExtension: "key", pipeline: pipeline, ocrPipeline: pipeline,
            configuration: configuration()
        )
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(SourceSyncService.slideChunks(of: document(parts: parts, text: text))?.count, chunks.count)
    }

    /// подменяется не по происхождению текста, а по наличию структуры.
    ///
    /// Раньше условием было «текст распознан OCR», и оно подменяло стратегию
    /// **всем шести**. Структуру получают только две; semantic и llmBased на
    /// распознанном тексте ценнее прочих, и подменять их не на что.
    func testRecognisedTextKeepsTheStrategiesThatDoNotNeedStructure() async throws {
        var scanned = document(parts: [], text: String(repeating: "распознанный текст. ", count: 40), ocr: true)
        scanned.containerFormat = "pdf"

        for strategy in [ChunkStrategy.fixed, .recursive, .adaptive] {
            let chunks = try await SourceSyncService.plannedChunks(
                of: scanned, fileExtension: "pdf", pipeline: pipeline, ocrPipeline: pipeline,
                configuration: configuration(strategy)
            )
            XCTAssertFalse(chunks.isEmpty)
            XCTAssertTrue(
                chunks.allSatisfy { $0.note == nil },
                "\(strategy) структуру не использует — подменять её не на что"
            )
            XCTAssertNil(SourceSyncService.substitution(for: configuration(strategy), document: scanned))
        }
    }

    /// А структурная стратегия без структуры — подменяется, и говорит об этом.
    func testAStructuralStrategyWithoutStructureIsSubstitutedAndSaysSo() async throws {
        var scanned = document(parts: [], text: String(repeating: "распознанный текст. ", count: 40), ocr: true)
        scanned.containerFormat = "pdf"

        for strategy in [ChunkStrategy.documentBased, .hierarchical] {
            let decision = SourceSyncService.substitution(for: configuration(strategy), document: scanned)
            guard case .noStructure(let named)? = decision else {
                return XCTFail("\(strategy) без структуры обязана подмениться")
            }
            XCTAssertEqual(named, strategy, "в пометке должна стоять та стратегия, которую подменили")

            let chunks = try await SourceSyncService.plannedChunks(
                of: scanned, fileExtension: "pdf", pipeline: pipeline, ocrPipeline: pipeline,
                configuration: configuration(strategy)
            )
            XCTAssertTrue(chunks.allSatisfy { $0.note?.contains("структура") == true })
        }
    }

    /// Текстовый слой без оглавления — тот же случай: дело не в OCR.
    func testAStructuralStrategyIsSubstitutedOnAnyDocumentWithoutStructure() async throws {
        var plain = document(parts: [], text: String(repeating: "обычный текст. ", count: 40))
        plain.containerFormat = "pdf"
        XCTAssertNil(plain.ocrUsed, "проверяем именно не-OCR документ")

        let decision = SourceSyncService.substitution(for: configuration(.documentBased), document: plain)
        guard case .noStructure? = decision else {
            return XCTFail("структуры нет — подмена нужна независимо от происхождения текста")
        }
    }

    /// А со структурой структурная стратегия работает как выбрана.
    func testAStructuralStrategyWithStructureIsNotSubstituted() async throws {
        var structured = document(parts: [], text: "Заголовок\n\nТекст раздела.")
        structured.containerFormat = "md"
        structured.structure = [DocumentNode(level: 1, title: "Заголовок", start: 0)]

        XCTAssertNil(SourceSyncService.substitution(for: configuration(.documentBased), document: structured))
    }

    func testOrdinaryTextIsChunkedByTheStrategyWithoutANote() async throws {
        var plain = document(parts: [], text: String(repeating: "обычный текст. ", count: 40))
        plain.containerFormat = "md"
        let chunks = try await SourceSyncService.plannedChunks(
            of: plain, fileExtension: "md", pipeline: pipeline, ocrPipeline: pipeline,
            configuration: configuration()
        )
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(chunks.allSatisfy { $0.note == nil })
    }
}
