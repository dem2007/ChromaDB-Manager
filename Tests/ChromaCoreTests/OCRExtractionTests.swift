import XCTest
import PDFKit
import AppKit
import UniformTypeIdentifiers
@testable import ChromaCore

/// The scan is drawn here — text rendered into an image, the image into
/// a PDF — so the fixture really has no text layer, which is the whole point.
final class OCRExtractionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-ocr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A page of text as a picture: drawn into an image and inserted as an
    /// image page, so PDFKit finds nothing to read.
    @MainActor
    private func makeScan(_ lines: [String], at url: URL) throws {
        let size = CGSize(width: 1240, height: 1754)   // A4 at 150 dpi
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        CGRect(origin: .zero, size: size).fill()
        for (index, line) in lines.enumerated() {
            (line as NSString).draw(
                at: CGPoint(x: 90, y: size.height - 160 - CGFloat(index) * 90),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 56),
                    .foregroundColor: NSColor.black,
                ]
            )
        }
        image.unlockFocus()

        let document = PDFDocument()
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        guard document.write(to: url) else { throw CocoaError(.fileWriteUnknown) }
    }

    // MARK: - Opt-in

    /// The rule the whole section rests on: OCR does not run unless the source
    /// asked for it, and the file is reported as a scan instead.
    @MainActor
    func testAScanIsNotRecognisedUnlessTheSourceAsks() async throws {
        let url = root.appendingPathComponent("scan.pdf")
        try makeScan(["Договор оказания услуг"], at: url)

        await XCTAssertThrowsErrorAsync(
            try await ExtractorRegistry.standard().extract(from: url, options: ExtractionOptions())
        ) { error in
            XCTAssertEqual(error as? ExtractionError, .noTextLayer(looksLikeScan: true))
        }
    }

    func testTheExtractorRefusesToRunWithOCRTurnedOff() {
        XCTAssertFalse(VisionOCRExtractor().isAvailable(for: ExtractionOptions()))
        XCTAssertTrue(VisionOCRExtractor().isAvailable(for: ExtractionOptions(ocrEnabled: true)))
    }

    /// And an extractor that is not available is not even a candidate, so a
    /// registry without OCR enabled behaves exactly as it did before 4.7.
    func testTheRegistryDoesNotOfferOCRWhenItIsOff() {
        let url = root.appendingPathComponent("any.pdf")
        XCTAssertEqual(ExtractorRegistry.standard().candidate(for: url)?.id, "pdfkit")
        XCTAssertEqual(
            ExtractorRegistry.standard().candidate(for: url, options: ExtractionOptions(ocrEnabled: true))?.id,
            "pdfkit",
            "OCR остаётся запасным путём, а не заменой PDFKit"
        )
    }

    // MARK: - Recognition

    /// Slow and dependent on the system's recognition models, so it is gated the
    /// same way the live LM Studio tests are.
    @MainActor
    func testAScanIsRecognisedWhenAsked() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CDBM_LIVE_OCR"] == "1",
            "Медленный тест: CDBM_LIVE_OCR=1"
        )
        let url = root.appendingPathComponent("scan.pdf")
        try makeScan(["CONTRACT OF SERVICES", "Section one"], at: url)

        let extracted = try await ExtractorRegistry.standard().extract(
            from: url, options: ExtractionOptions(ocrEnabled: true, ocrLanguages: ["en-US"])
        )

        XCTAssertEqual(extracted.extractorID, "vision-ocr")
        XCTAssertEqual(extracted.ocrUsed, true)
        XCTAssertTrue(extracted.plainText.uppercased().contains("CONTRACT"), extracted.plainText)
        let confidence = try XCTUnwrap(extracted.ocrConfidence)
        XCTAssertGreaterThan(confidence, 0)
        XCTAssertLessThanOrEqual(confidence, 1)
        // no structure from recognised text.
        XCTAssertTrue(extracted.structure.isEmpty)
        XCTAssertEqual(extracted.structureSource, .none)
        XCTAssertTrue(extracted.warnings.contains { if case .ocrUsed = $0 { return true }; return false })
    }

    // MARK: - Languages

    /// Never a hardcoded list: the set differs between macOS versions, so what
    /// the app shows has to come from the system it is running on.
    func testTheLanguageListComesFromTheSystem() {
        let languages = VisionOCRExtractor.supportedLanguages()
        XCTAssertFalse(languages.isEmpty, "система должна сообщать хотя бы один язык")
        XCTAssertTrue(languages.contains { $0.hasPrefix("en") }, languages.joined(separator: ", "))
    }

    func testAnUnsupportedLanguageIsRefusedWithAReason() {
        XCTAssertThrowsError(try VisionOCRExtractor.resolvedLanguages(["xx-XX"])) { error in
            guard case .unsupportedFormat = error as? ExtractionError else {
                return XCTFail("ожидался отказ по языку, получено \(error)")
            }
        }
    }

    func testAnEmptyLanguageListMeansLetVisionDecide() throws {
        XCTAssertEqual(try VisionOCRExtractor.resolvedLanguages([]), [])
    }

    func testSupportedLanguagesAreKept() throws {
        let supported = VisionOCRExtractor.supportedLanguages()
        let english = try XCTUnwrap(supported.first { $0.hasPrefix("en") })
        XCTAssertEqual(try VisionOCRExtractor.resolvedLanguages([english, "xx-XX"]), [english])
    }

    // MARK: - The chunking rule

    /// 3 forbids structural chunking of recognised text. The sizes the user
    /// chose are kept; only the strategy changes.
    func testRecognisedTextFallsBackToRecursiveKeepingTheUsersSizes() {
        let configuration = ChunkingConfiguration(
            strategy: .documentBased, chunkSize: 700, sizeUnit: .characters,
            overlapPercent: 12, separators: ["\n\n", ". "]
        )
        let fallback = SourceSyncService.recursiveEquivalent(of: configuration)

        XCTAssertEqual(fallback.strategy, .recursive)
        XCTAssertEqual(fallback.chunkSize, 700)
        XCTAssertEqual(fallback.overlapPercent, 12)
        XCTAssertEqual(fallback.separators, ["\n\n", ". "])
    }

    // MARK: - Settings

    /// Turning OCR on has to re-index, the same way turning document metadata on
    /// does — otherwise the checkbox would change nothing visible.
    func testOCRSettingsAreInTheExtractionSignature() {
        let off = DataSource(name: "a", path: "/tmp", collectionName: "a")
        var on = off
        on.ocrEnabled = true
        var withLanguages = on
        withLanguages.ocrLanguages = ["ru-RU", "en-US"]

        XCTAssertNotEqual(off.extractionSignature, on.extractionSignature)
        XCTAssertNotEqual(on.extractionSignature, withLanguages.extractionSignature)
        // The order the user clicked them in is not a difference.
        var reordered = withLanguages
        reordered.ocrLanguages = ["en-US", "ru-RU"]
        XCTAssertEqual(withLanguages.extractionSignature, reordered.extractionSignature)
    }

    /// Languages only matter while OCR is on, so toggling them with it off must
    /// not re-index a folder for nothing.
    func testLanguagesDoNotCountWhileOCRIsOff() {
        var a = DataSource(name: "a", path: "/tmp", collectionName: "a")
        a.ocrLanguages = ["ru-RU"]
        let b = DataSource(name: "a", path: "/tmp", collectionName: "a")
        XCTAssertEqual(a.extractionSignature, b.extractionSignature)
    }

    // MARK: - Progress

    func testProgressIsReportedPerPage() {
        let progress = ExtractionProgress(stage: .recognising, unit: 3, total: 40)
        XCTAssertTrue(progress.text.contains("3"))
        XCTAssertTrue(progress.text.contains("40"))
    }
}
