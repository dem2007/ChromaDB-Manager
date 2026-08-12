import XCTest
import UniformTypeIdentifiers
import PDFKit
import AppKit
@testable import ChromaCore

// MARK: -: heading_path and page_number

final class ExtractedDocumentStructureTests: XCTestCase {
    /// «Глава 2 > Раздел 2.1» — built once here so every extractor spells it the
    /// same way.
    private func book() -> ExtractedDocument {
        ExtractedDocument(
            plainText: String(repeating: "x", count: 400),
            structure: [
                DocumentNode(level: 1, title: "Глава 1", start: 0),
                DocumentNode(level: 2, title: "Раздел 1.1", start: 50),
                DocumentNode(level: 1, title: "Глава 2", start: 200),
                DocumentNode(level: 2, title: "Раздел 2.1", start: 250),
                DocumentNode(level: 3, title: "Пункт 2.1.1", start: 300),
            ],
            containerFormat: "epub",
            extractorID: "test",
            extractorVersion: 1
        )
    }

    func testHeadingPathWalksBackToTheTopLevel() {
        XCTAssertEqual(book().headingPath(forCharacter: 320), "Глава 2 > Раздел 2.1 > Пункт 2.1.1")
    }

    func testASectionKeepsItsPathUntilTheNextHeading() {
        XCTAssertEqual(book().headingPath(forCharacter: 260), "Глава 2 > Раздел 2.1")
        XCTAssertEqual(book().headingPath(forCharacter: 210), "Глава 2")
    }

    /// A deeper heading must not drag the previous chapter's siblings into the
    /// path: «Глава 2» replaces «Глава 1», it does not follow it.
    func testAnEarlierChapterIsNotInThePathOfALaterOne() {
        let path = book().headingPath(forCharacter: 320) ?? ""
        XCTAssertFalse(path.contains("Глава 1"), path)
        XCTAssertFalse(path.contains("Раздел 1.1"), path)
    }

    func testTextBeforeTheFirstHeadingHasNoPath() {
        let document = ExtractedDocument(
            plainText: "abc",
            structure: [DocumentNode(level: 1, title: "Позже", start: 10)],
            containerFormat: "pdf", extractorID: "t", extractorVersion: 1
        )
        XCTAssertNil(document.headingPath(forCharacter: 0))
    }

    func testPageNumberFollowsThePageBoundaries() {
        let document = ExtractedDocument(
            plainText: String(repeating: "y", count: 100),
            pageStarts: [0, 30, 70],
            containerFormat: "pdf", extractorID: "t", extractorVersion: 1
        )
        XCTAssertEqual(document.pageNumber(forCharacter: 0), 1)
        XCTAssertEqual(document.pageNumber(forCharacter: 29), 1)
        XCTAssertEqual(document.pageNumber(forCharacter: 30), 2)
        XCTAssertEqual(document.pageNumber(forCharacter: 99), 3)
    }

    func testAFormatWithoutPagesReportsNoPage() {
        let document = ExtractedDocument(
            plainText: "abc", containerFormat: "md", extractorID: "t", extractorVersion: 1
        )
        XCTAssertNil(document.pageNumber(forCharacter: 1))
    }
}

// MARK: -: the registry's decisions

private struct StubExtractor: DocumentTextExtractor {
    let id: String
    let version = 1
    let handles: UTType
    let result: Result<String, ExtractionError>

    func canHandle(_ type: UTType) -> Bool { type.conforms(to: handles) }

    func extract(from url: URL, options: ExtractionOptions) async throws -> ExtractedDocument {
        switch result {
        case .success(let text):
            return ExtractedDocument(
                plainText: text, containerFormat: "stub", extractorID: id, extractorVersion: version
            )
        case .failure(let error):
            throw error
        }
    }
}

final class ExtractorRegistryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cdbm-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func file(_ name: String, _ text: String = "содержимое") throws -> URL {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testTheFirstMatchingExtractorWins() async throws {
        let registry = ExtractorRegistry(extractors: [
            StubExtractor(id: "first", handles: .text, result: .success("от первого")),
            StubExtractor(id: "second", handles: .text, result: .success("от второго")),
        ])
        let extracted = try await registry.extract(from: try file("a.txt"), options: ExtractionOptions())
        XCTAssertEqual(extracted.extractorID, "first")
    }

    /// A PDF with no text layer is exactly the case OCR exists for, so that one
    /// error hands over to the next extractor.
    func testNoTextLayerFallsThroughToTheNextExtractor() async throws {
        let registry = ExtractorRegistry(extractors: [
            StubExtractor(id: "first", handles: .text, result: .failure(.noTextLayer(looksLikeScan: true))),
            StubExtractor(id: "ocr", handles: .text, result: .success("распознано")),
        ])
        let extracted = try await registry.extract(from: try file("a.txt"), options: ExtractionOptions())
        XCTAssertEqual(extracted.extractorID, "ocr")
    }

    /// A locked file is not something another extractor can do better, and
    /// retrying would replace a precise reason with a vaguer one.
    func testAPasswordIsNotRetriedWithAnotherExtractor() async throws {
        let registry = ExtractorRegistry(extractors: [
            StubExtractor(id: "first", handles: .text, result: .failure(.passwordProtected)),
            StubExtractor(id: "second", handles: .text, result: .success("не должно случиться")),
        ])
        await XCTAssertThrowsErrorAsync(
            try await registry.extract(from: try self.file("a.txt"), options: ExtractionOptions())
        ) { error in
            XCTAssertEqual(error as? ExtractionError, .passwordProtected)
        }
    }

    func testAnUnknownFormatSaysSoRatherThanReturningNothing() async throws {
        let registry = ExtractorRegistry(extractors: [
            StubExtractor(id: "pdf-only", handles: .pdf, result: .success("x")),
        ])
        await XCTAssertThrowsErrorAsync(
            try await registry.extract(from: try self.file("a.txt"), options: ExtractionOptions())
        ) { error in
            guard case .unsupportedFormat = error as? ExtractionError else {
                return XCTFail("ожидался отказ по формату, получено \(error)")
            }
        }
    }

    /// Type comes from the system, not from the extension string: the standard
    /// registry must route by what the file *is*.
    func testTheStandardRegistryRoutesPlainTextAndPDFDifferently() throws {
        let registry = ExtractorRegistry.standard()
        XCTAssertTrue(registry.canExtract(try file("a.md")))
        XCTAssertNotNil(registry.extractor(id: "pdfkit"))
        XCTAssertNotNil(registry.extractor(id: "plaintext"))
    }

    /// Rich text is markup; reading it as plain text would index the markup.
    func testRichTextIsNotClaimedByThePlainTextExtractor() {
        XCTAssertFalse(PlainTextExtractor().canHandle(.rtf))
        XCTAssertTrue(PlainTextExtractor().canHandle(.plainText))
        XCTAssertTrue(PlainTextExtractor().canHandle(.swiftSource))
    }
}

// MARK: -: a package is one document

final class DocumentPackageScanTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cdbm-package-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A `.pages` on disk is a directory. Asking only for regular files drops it
    /// silently; walking into it indexes `preview.jpg` as a document of its own.
    func testAPackageDirectoryCountsAsAFileNotAFolder() throws {
        let package = root.appendingPathComponent("Договор.pages")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8]).write(to: package.appendingPathComponent("preview.jpg"))

        XCTAssertTrue(
            SourceSyncService.isIndexableEntry(package),
            "каталог-пакет — это один документ, а не папка с файлами"
        )
        XCTAssertTrue(ExtractorRegistry.isDocumentPackage(package))
    }

    func testAnOrdinaryFolderIsNotADocument() throws {
        let folder = root.appendingPathComponent("обычная папка")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertFalse(SourceSyncService.isIndexableEntry(folder))
    }

    func testAnOrdinaryFileIsIndexable() throws {
        let url = root.appendingPathComponent("a.txt")
        try "текст".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(SourceSyncService.isIndexableEntry(url))
    }

    /// Найдено по журналу приложения 10 и 11 августа.
    func testAnOfficeLockFileIsSkippedSilently() throws {
        // Word кладёт рядом с открытым документом `~$имя.docx`: там имя
        // владельца, а не документ. Расширение то же самое, скрытым на macOS
        // он не помечен — значит, в отбор проходит, а извлечение на нём
        // ломается, и пользователь видит в журнале «файл не читается» про
        // файл, которого он не создавал.
        let lock = root.appendingPathComponent("~$договор.docx")
        try Data([0x00, 0x01]).write(to: lock)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
        XCTAssertFalse(
            SourceSyncService.isIndexableEntry(lock),
            "файл-замок Office — не документ"
        )

        // А документ с тем же расширением рядом обязан остаться видимым.
        let real = root.appendingPathComponent("договор.docx")
        try Data([0x50, 0x4B]).write(to: real)
        XCTAssertTrue(SourceSyncService.isIndexableEntry(real))
    }

    func testATildeInAnOrdinaryNameIsNotMistakenForALock() throws {
        // Отсеивается ровно `~$` в начале имени, а не тильда где угодно:
        // «~черновик.md» — обычный файл, и терять его нельзя.
        let url = root.appendingPathComponent("~черновик.md")
        try "текст".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(SourceSyncService.isIndexableEntry(url))
    }
}

// MARK: -: a real PDF, with a real outline

final class PDFStructureTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cdbm-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Draws a multi-page PDF with a text layer and, optionally, a table of
    /// contents — built here rather than committed as a fixture, per
    @MainActor
    private func makePDF(pages: [String], outline titles: [String]?, at url: URL) throws {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var mediaBox = bounds
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for body in pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (body as NSString).draw(
                in: bounds.insetBy(dx: 60, dy: 60),
                withAttributes: [.font: NSFont.systemFont(ofSize: 18)]
            )
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()

        guard let document = PDFDocument(data: data as Data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if let titles {
            let outlineRoot = PDFOutline()
            for (index, title) in titles.enumerated() {
                let child = PDFOutline()
                child.label = title
                if let page = document.page(at: index) {
                    child.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: bounds.height))
                }
                outlineRoot.insertChild(child, at: index)
            }
            document.outlineRoot = outlineRoot
        }
        guard document.write(to: url) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// The point of: a table of contents becomes structure, and structure
    /// is what lets Document-based chunking cut along sections instead of along
    /// a character count.
    @MainActor
    func testAnOutlineBecomesStructureWithPages() async throws {
        let url = root.appendingPathComponent("book.pdf")
        try makePDF(
            pages: ["Глава первая\n\nО векторном поиске.", "Глава вторая\n\nО структуре."],
            outline: ["Глава первая", "Глава вторая"],
            at: url
        )

        let extracted = try await PDFExtractor().extract(from: url, options: ExtractionOptions())

        XCTAssertEqual(extracted.structureSource, .outline)
        XCTAssertEqual(extracted.structure.map(\.title), ["Глава первая", "Глава вторая"])
        XCTAssertEqual(extracted.structure.map(\.pageNumber), [1, 2])
        XCTAssertEqual(extracted.pageCount, 2)
        XCTAssertFalse(extracted.warnings.contains(.noStructure))

        // The second chapter starts where the second page starts.
        let secondStart = try XCTUnwrap(extracted.structure.last?.start)
        XCTAssertEqual(extracted.pageNumber(forCharacter: secondStart), 2)
        XCTAssertEqual(extracted.headingPath(forCharacter: secondStart), "Глава вторая")
    }

    /// Without a table of contents the extractor says so instead of inventing
    /// one — the warning is what the preview screen shows the user.
    @MainActor
    func testAPDFWithoutAnOutlineSaysItHasNoStructure() async throws {
        let url = root.appendingPathComponent("flat.pdf")
        try makePDF(pages: ["Просто текст без оглавления."], outline: nil, at: url)

        let extracted = try await PDFExtractor().extract(from: url, options: ExtractionOptions())

        XCTAssertEqual(extracted.structureSource, .none)
        XCTAssertTrue(extracted.structure.isEmpty)
        XCTAssertTrue(extracted.warnings.contains(.noStructure))
    }

    /// A page with no text layer is a picture of text, and the difference from
    /// «empty» is what tells the user to turn OCR on.
    @MainActor
    func testAPageWithNoTextLayerIsReportedAsAScan() async throws {
        let url = root.appendingPathComponent("scan.pdf")
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        NSColor.white.setFill()
        bounds.fill()
        image.unlockFocus()
        let document = PDFDocument()
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        XCTAssertTrue(document.write(to: url))

        await XCTAssertThrowsErrorAsync(
            try await PDFExtractor().extract(from: url, options: ExtractionOptions())
        ) { error in
            XCTAssertEqual(error as? ExtractionError, .noTextLayer(looksLikeScan: true))
        }
    }
}
