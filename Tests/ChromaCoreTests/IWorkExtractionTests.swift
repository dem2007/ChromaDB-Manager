import XCTest
import PDFKit
import AppKit
import UniformTypeIdentifiers
@testable import ChromaCore

/// The export itself raises Pages or Keynote and needs a permission no
/// test target can grant, so it is behind a protocol and faked here. Everything
/// around it — the order of fallbacks, the temporary files, the slide rule, the
/// refusal when nothing worked — is real.
final class IWorkExtractionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-iwork-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Doubles

    /// Writes a PDF where the application would have, or fails the way the
    /// system does when the permission is missing.
    struct FakeExporter: IWorkExporting {
        var pages: [String] = ["Слайд первый\nСодержимое первого", "Слайд второй\nСодержимое второго"]
        var notes: [Int: String] = [:]
        var failure: ExtractionError?
        /// Set by the test to see that only one export runs at a time.
        final class Counter: @unchecked Sendable { var exports = 0; var notes = 0 }
        var counter = Counter()

        func exportPDF(from url: URL, to destination: URL, kind: IWorkExtractor.Kind, timeout: TimeInterval) async throws {
            counter.exports += 1
            if let failure { throw failure }
            let pages = pages
            try await MainActor.run { try IWorkExtractionTests.writePDF(pages: pages, to: destination) }
        }

        func presenterNotes(from url: URL, timeout: TimeInterval) async throws -> [Int: String] {
            counter.notes += 1
            if let failure { throw failure }
            return notes
        }
    }

    @MainActor
    static func writePDF(pages: [String], to url: URL) throws {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { throw CocoaError(.fileWriteUnknown) }
        var box = bounds
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        for body in pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (body as NSString).draw(in: bounds.insetBy(dx: 60, dy: 60),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 20)])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        try (data as Data).write(to: url)
    }

    /// A `.key`/`.pages` as a single ZIP file.
    private func zipDocument(_ name: String, entries: [(String, Data)]) throws -> URL {
        let url = root.appendingPathComponent(name)
        try ZIPFixtureBuilder(entries: entries.map {
            ZIPFixtureBuilder.Entry(path: $0.0, contents: $0.1, deflated: true)
        }).build().write(to: url)
        return url
    }

    /// …and as a package directory, which is the other half of's rule.
    private func packageDocument(_ name: String, files: [(String, Data)]) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (path, data) in files {
            let file = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        return url
    }

    // MARK: - The export path

    @MainActor
    func testAKeynoteIsReadThroughTheApplicationExport() async throws {
        let url = try zipDocument("deck.key", entries: [("Index/Document.iwa", Data([0, 1, 2]))])
        let exporter = FakeExporter()
        let extracted = try await IWorkExtractor(exporter: exporter).extract(
            from: url, options: ExtractionOptions(allowApplicationExport: true)
        )

        XCTAssertEqual(extracted.extractorID, "iwork")
        XCTAssertEqual(extracted.containerFormat, "key")
        XCTAssertTrue(extracted.plainText.contains("Слайд первый"))
        XCTAssertEqual(exporter.counter.exports, 1)
    }

    /// One PDF page is one slide, and the slide's first line is its title.
    @MainActor
    func testSlidesBecomePartsWithTitles() async throws {
        let url = try zipDocument("titles.key", entries: [("Index/Document.iwa", Data([0]))])
        let extracted = try await IWorkExtractor(exporter: FakeExporter()).extract(
            from: url, options: ExtractionOptions(allowApplicationExport: true)
        )

        XCTAssertEqual(extracted.parts.map(\.kind), [.slide, .slide])
        XCTAssertEqual(extracted.parts.map(\.index), [0, 1])
        XCTAssertEqual(extracted.structure.map(\.title), ["Слайд первый", "Слайд второй"])
        XCTAssertEqual(extracted.headingPath(forCharacter: extracted.parts[1].start), "Слайд второй")
    }

    /// one slide, one chunk — no further splitting.
    @MainActor
    func testAPresentationIsCutBySlide() async throws {
        let url = try zipDocument("chunks.key", entries: [("Index/Document.iwa", Data([0]))])
        let extracted = try await IWorkExtractor(exporter: FakeExporter()).extract(
            from: url, options: ExtractionOptions(allowApplicationExport: true)
        )

        let chunks = try XCTUnwrap(SourceSyncService.slideChunks(of: extracted))
        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(chunks[0].text.contains("Слайд первый"))
        XCTAssertTrue(chunks[1].text.contains("Слайд второй"))
        XCTAssertNotNil(chunks[0].note, "подмена стратегии должна быть названа")
    }

    func testADocumentThatIsNotAPresentationIsNotCutBySlide() {
        let document = ExtractedDocument(
            plainText: "обычный текст", containerFormat: "pdf", extractorID: "pdfkit", extractorVersion: 1
        )
        XCTAssertNil(SourceSyncService.slideChunks(of: document))
    }

    /// Presenter notes are often the substance of a deck and only exist on the
    /// export path.
    @MainActor
    func testPresenterNotesAreFetchedSeparately() async throws {
        let url = try zipDocument("notes.key", entries: [("Index/Document.iwa", Data([0]))])
        var exporter = FakeExporter()
        exporter.notes = [0: "То, что докладчик скажет вслух по первому слайду."]

        let extracted = try await IWorkExtractor(exporter: exporter).extract(
            from: url, options: ExtractionOptions(allowApplicationExport: true)
        )

        XCTAssertTrue(extracted.plainText.contains("То, что докладчик скажет вслух"))
        XCTAssertEqual(exporter.counter.notes, 1)
        XCTAssertFalse(extracted.warnings.contains(.speakerNotesUnavailable))
        // The slides keep their offsets: notes are appended, never woven in.
        XCTAssertEqual(extracted.parts.prefix(2).map(\.index), [0, 1])
        XCTAssertEqual(extracted.part(forCharacter: extracted.parts[1].start)?.index, 1)
    }

    /// Found live: the notes for slides 1 and 2 arrived in the chunk for slide 3,
    /// wearing its number and its title. Appending them after the last slide is
    /// right; letting the last slide own them is not.
    @MainActor
    func testNotesBelongToTheirOwnSlideAndNotToTheLastOne() async throws {
        let url = try zipDocument("attribution.key", entries: [("Index/Document.iwa", Data([0]))])
        var exporter = FakeExporter()
        exporter.notes = [0: "Сказать про первый слайд."]

        let extracted = try await IWorkExtractor(exporter: exporter).extract(
            from: url, options: ExtractionOptions(allowApplicationExport: true)
        )

        let notesStart = try XCTUnwrap(extracted.plainText.range(of: "Сказать про первый слайд."))
        let offset = extracted.plainText.distance(from: extracted.plainText.startIndex, to: notesStart.lowerBound)

        XCTAssertEqual(extracted.part(forCharacter: offset)?.index, 0, "заметка первого слайда — первому слайду")
        XCTAssertEqual(extracted.headingPath(forCharacter: offset), "Заметки к слайду 1")
        // The words are in the presentation, not on any page Keynote exported.
        XCTAssertNil(extracted.pageNumber(forCharacter: offset))
        // And the last slide still knows which page it is on.
        XCTAssertEqual(extracted.pageNumber(forCharacter: extracted.parts[1].start), 2)
    }

    /// A notes block is a chunk of its own, so its slide number is written from
    /// its own part rather than inherited from whatever came before it.
    @MainActor
    func testNotesBecomeTheirOwnChunk() async throws {
        let url = try zipDocument("notes-chunks.key", entries: [("Index/Document.iwa", Data([0]))])
        var exporter = FakeExporter()
        exporter.notes = [0: "Сказать про первый слайд."]

        let extracted = try await IWorkExtractor(exporter: exporter).extract(
            from: url, options: ExtractionOptions(allowApplicationExport: true)
        )
        let chunks = try XCTUnwrap(SourceSyncService.slideChunks(of: extracted))

        XCTAssertEqual(chunks.count, 3, "два слайда и блок заметок")
        XCTAssertFalse(chunks[1].text.contains("Сказать про первый слайд."),
                       "заметки первого слайда не должны попасть в чанк второго")
        XCTAssertTrue(chunks[2].text.contains("Сказать про первый слайд."))

        let placements = ChunkLocator.placements(of: chunks, in: extracted)
        XCTAssertEqual(placements[2]?.part?.index, 0, "slide_number заметки — номер её слайда")
        XCTAssertNil(placements[2]?.pageNumber)
    }

    /// The PDF had no outline of its own; the slides are one. A warning saying
    /// otherwise next to a filled-in structure is just noise.
    @MainActor
    func testTheStructureWarningIsDroppedOnceTheSlidesProvideOne() async throws {
        let url = try zipDocument("warning.key", entries: [("Index/Document.iwa", Data([0]))])
        let extracted = try await IWorkExtractor(exporter: FakeExporter()).extract(
            from: url, options: ExtractionOptions(allowApplicationExport: true)
        )

        XCTAssertFalse(extracted.structure.isEmpty)
        XCTAssertEqual(extracted.structureSource, .outline)
        XCTAssertFalse(extracted.warnings.contains(.noStructure))
    }

    @MainActor
    func testADeckWithoutNotesSaysSo() async throws {
        let url = try zipDocument("silent.key", entries: [("Index/Document.iwa", Data([0]))])
        let extracted = try await IWorkExtractor(exporter: FakeExporter()).extract(
            from: url, options: ExtractionOptions(allowApplicationExport: true)
        )
        XCTAssertTrue(extracted.warnings.contains(.speakerNotesUnavailable))
    }

    // MARK: - The fallbacks, in the order fixes

    /// A modern file with export turned off has nothing left to try, and says
    /// which permission is missing rather than «формат не поддерживается».
    @MainActor
    func testWithoutExportAModernFileIsRefusedWithAReason() async throws {
        let url = try zipDocument("modern.pages", entries: [("Index/Document.iwa", Data([0, 1]))])
        await XCTAssertThrowsErrorAsync(
            try await IWorkExtractor(exporter: FakeExporter()).extract(from: url, options: ExtractionOptions())
        ) { error in
            guard case .applicationUnavailable(let detail) = error as? ExtractionError else {
                return XCTFail("ожидалась причина, получено \(error)")
            }
            XCTAssertTrue(detail.contains("выключен"), detail)
        }
    }

    /// iWork '09 kept a real PDF inside, and it is a legitimate fallback — with
    /// the quality said out loud.
    @MainActor
    func testThePreviewPDFIsUsedWhenTheExportFails() async throws {
        let pdf = root.appendingPathComponent("inner.pdf")
        try Self.writePDF(pages: ["Текст из внутреннего PDF"], to: pdf)
        let url = try zipDocument("legacy.pages", entries: [
            ("QuickLook/Preview.pdf", try Data(contentsOf: pdf)),
        ])
        var exporter = FakeExporter()
        exporter.failure = .applicationUnavailable("Pages не отвечает")

        let extracted = try await IWorkExtractor(exporter: exporter).extract(
            from: url, options: ExtractionOptions(allowApplicationExport: true)
        )

        XCTAssertEqual(extracted.structureSource, .previewPDF)
        XCTAssertTrue(extracted.plainText.contains("внутреннего PDF"))
        XCTAssertTrue(extracted.warnings.contains { $0.text.contains("качество ниже") })
    }

    @MainActor
    func testTheLegacyXMLIsReadWhenThereIsNoPreview() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <document xmlns:sf="http://developer.apple.com/namespaces/sf">
        <sf:text><sf:p>Первый абзац старого документа.</sf:p><sf:p>Второй абзац.</sf:p></sf:text>
        </document>
        """
        let url = try zipDocument("old.pages", entries: [("index.xml", Data(xml.utf8))])

        let extracted = try await IWorkExtractor(exporter: FakeExporter()).extract(
            from: url, options: ExtractionOptions()
        )

        XCTAssertEqual(extracted.structureSource, .legacyXML)
        XCTAssertTrue(extracted.plainText.contains("Первый абзац старого документа."))
        XCTAssertTrue(extracted.plainText.contains("Второй абзац."))
        XCTAssertTrue(extracted.warnings.contains { $0.text.contains("iWork '09") })
    }

    /// A `.pages` is sometimes a directory, and the same fallbacks have to work
    /// on it.
    @MainActor
    func testAPackageDirectoryIsReadTheSameWay() async throws {
        let xml = "<document><p>Текст из каталога-пакета.</p></document>"
        let url = try packageDocument("package.pages", files: [("index.xml", Data(xml.utf8))])

        let extracted = try await IWorkExtractor(exporter: FakeExporter()).extract(
            from: url, options: ExtractionOptions()
        )
        XCTAssertEqual(extracted.structureSource, .legacyXML)
        XCTAssertTrue(extracted.plainText.contains("каталога-пакета"))
    }

    /// The one thing the spec forbids using: `preview.jpg`. One page of text
    /// pretending to be a whole document is worse than an honest refusal.
    @MainActor
    func testTheJPEGPreviewIsNeverUsed() async throws {
        let url = try zipDocument("jpeg.pages", entries: [
            ("Index/Document.iwa", Data([0, 1])),
            ("preview.jpg", Data(repeating: 0xFF, count: 2048)),
            ("preview-micro.jpg", Data(repeating: 0xFF, count: 256)),
        ])
        await XCTAssertThrowsErrorAsync(
            try await IWorkExtractor(exporter: FakeExporter()).extract(from: url, options: ExtractionOptions())
        ) { error in
            guard case .applicationUnavailable = error as? ExtractionError else {
                return XCTFail("ожидался отказ, получено \(error)")
            }
        }
    }

    // MARK: - Permission and errors

    /// The system's -1743 is the error the spec warns is mistaken for a bug in
    /// our code. It has to name the permission and where to grant it.
    func testTheAutomationRefusalIsExplained() {
        let message = AppleScriptIWorkExporter.explain(
            "execution error: Not authorized to send Apple events to Pages. (-1743)",
            application: "Pages"
        )
        XCTAssertTrue(message.contains("Автоматизация"), message)
        XCTAssertTrue(message.contains("Pages"), message)
    }

    func testAMissingApplicationIsExplained() {
        let message = AppleScriptIWorkExporter.explain("error -1728", application: "Keynote")
        XCTAssertTrue(message.contains("не установлен"), message)
    }

    func testPresenterNotesAreParsedPerSlide() {
        let output = "<<<CDBM-SLIDE 1>>>Первая заметка\n<<<CDBM-SLIDE 2>>>\n<<<CDBM-SLIDE 3>>>Третья заметка\n"
        let notes = AppleScriptIWorkExporter.parseNotes(output)
        XCTAssertEqual(notes[0], "Первая заметка")
        XCTAssertNil(notes[1], "пустая заметка — это не заметка")
        XCTAssertEqual(notes[2], "Третья заметка")
    }

    func testAPathWithAQuoteCannotBreakTheScript() {
        XCTAssertEqual(
            AppleScriptIWorkExporter.escaped("/tmp/про\"верка/файл.key"),
            "/tmp/про\\\"верка/файл.key"
        )
    }

    // MARK: - Routing and settings

    func testTheRegistryRoutesIWorkFiles() {
        for name in ["deck.key", "letter.pages"] {
            XCTAssertEqual(
                SourceSyncService.stamp(of: root.appendingPathComponent(name), registry: .standard()).id,
                "iwork",
                name
            )
        }
    }

    /// Automatic runs do not open Pages unless that was allowed separately.
    func testAutomaticRunsDoNotRaisePagesByDefault() {
        var source = DataSource(name: "a", path: "/tmp", collectionName: "a")
        source.iWorkExportEnabled = true

        XCTAssertTrue(ExtractionOptions(allowApplicationExport: true).allowApplicationExport)
        // The rule itself, as the service computes it.
        for (reason, expected) in [(SyncReason.manual, true), (.schedule, false), (.launch, false), (.fileChanges, false)] {
            let allowed = source.iWorkExportEnabled && (!reason.isAutomatic || source.iWorkExportInAutomaticRuns)
            XCTAssertEqual(allowed, expected, reason.rawValue)
        }

        source.iWorkExportInAutomaticRuns = true
        let allowed = source.iWorkExportEnabled && (!SyncReason.schedule.isAutomatic || source.iWorkExportInAutomaticRuns)
        XCTAssertTrue(allowed)
    }

    func testTheExportSettingIsInTheExtractionSignature() {
        let off = DataSource(name: "a", path: "/tmp", collectionName: "a")
        var on = off
        on.iWorkExportEnabled = true
        XCTAssertNotEqual(off.extractionSignature, on.extractionSignature)
    }

    /// Temporary PDFs must not outlive the extraction — not even a failed one.
    @MainActor
    func testTemporaryFilesAreRemovedEvenWhenTheExportFails() async throws {
        let before = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("cdbm-iwork-") }.count

        let url = try zipDocument("temp.pages", entries: [("Index/Document.iwa", Data([0]))])
        var exporter = FakeExporter()
        exporter.failure = .timedOut(seconds: 1)
        _ = try? await IWorkExtractor(exporter: exporter).extract(
            from: url, options: ExtractionOptions(allowApplicationExport: true)
        )

        let after = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("cdbm-iwork-") }.count
        XCTAssertEqual(after, before, "временный каталог остался на диске")
    }
}

// MARK: - The slow paths get their own limit

/// Found live: the first export waits for the automation prompt and took 63 s,
/// while the registry's ordinary 60 s per-file limit killed it — reporting a
/// timeout for a document Keynote was in the middle of exporting.
final class ExtractionTimeoutBudgetTests: XCTestCase {
    func testTheExportKeepsItsOwnLimitEvenWhenTheFileLimitIsShorter() {
        let options = ExtractionOptions(perFileTimeout: 60, exportTimeout: 120)
        XCTAssertEqual(IWorkExtractor().timeout(for: options), 120)
    }

    /// And a longer per-file limit is not shortened by the export one.
    func testTheLongerOfTheTwoWins() {
        let options = ExtractionOptions(perFileTimeout: 300, exportTimeout: 120)
        XCTAssertEqual(IWorkExtractor().timeout(for: options), 300)
    }

    /// OCR bounds itself per page, so a whole-file number would only ever cut a
    /// long scan off in the middle.
    func testOCRHasNoFileLevelLimit() {
        XCTAssertEqual(VisionOCRExtractor().timeout(for: ExtractionOptions(perFileTimeout: 60)), 0)
    }

    /// Everything else keeps the ordinary limit.
    func testOrdinaryExtractorsUseThePerFileTimeout() {
        let options = ExtractionOptions(perFileTimeout: 42)
        XCTAssertEqual(PDFExtractor().timeout(for: options), 42)
        XCTAssertEqual(PlainTextExtractor().timeout(for: options), 42)
        XCTAssertEqual(OfficeExtractor().timeout(for: options), 42)
        XCTAssertEqual(EPUBExtractor().timeout(for: options), 42)
    }
}
