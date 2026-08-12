import Foundation
import Vision
import PDFKit
import CoreGraphics
import UniformTypeIdentifiers

/// Text recognition for PDFs that are pictures of text.
///
/// Off unless the source asks for it. OCR is an order of magnitude slower than
/// reading a text layer, and the user has to learn that **before** pointing it
/// at a folder of a thousand files, not after.
public struct VisionOCRExtractor: DocumentTextExtractor {
    public let id = "vision-ocr"
    public let version = 1

    /// Rendering scale for a page before recognition. 2× the nominal 72 dpi is
    /// the usual floor for Vision on scanned text; below it the accuracy drops
    /// sharply, above it the time grows faster than the accuracy.
    static let renderScale: CGFloat = 2

    public init() {}

    public func canHandle(_ type: UTType) -> Bool { type.conforms(to: .pdf) }

    /// The registry skips this extractor entirely unless the source turned OCR
    /// on — that is what makes it opt-in rather than a surprise.
    public func isAvailable(for options: ExtractionOptions) -> Bool { options.ocrEnabled }

    /// No file-level limit: recognition is bounded per page and cancellable
    /// between pages, and a single number over a whole document would
    /// mean a forty-page scan dies at page thirty for no reason anyone chose.
    public func timeout(for options: ExtractionOptions) -> TimeInterval { 0 }

    public func extract(from url: URL, options: ExtractionOptions) async throws -> ExtractedDocument {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size <= options.maxFileSize else {
            throw ExtractionError.tooLarge(size: size, limit: options.maxFileSize)
        }
        guard let document = PDFDocument(url: url) else {
            throw ExtractionError.corrupted(String(localized: "PDF не открывается"))
        }
        try PDFExtractor.unlockIfNeeded(document, password: options.password)

        let languages = try Self.resolvedLanguages(options.ocrLanguages)
        var text = ""
        var pageStarts: [Int] = []
        var confidenceSum = 0.0
        var confidenceWeight = 0.0

        for index in 0..<document.pageCount {
            // Cancellation between pages, not inside one: a Vision request is a
            // single system call, and a folder of scans has to stay stoppable.
            try Task.checkCancellation()
            options.progress?(ExtractionProgress(
                stage: .recognising, unit: index + 1, total: document.pageCount
            ))

            pageStarts.append(text.count)
            guard let page = document.page(at: index), let image = Self.render(page) else { continue }
            let recognised = try await Self.recognise(
                image, languages: languages, timeout: options.ocrPageTimeout
            )
            guard !recognised.text.isEmpty else { continue }

            if !text.isEmpty { text += "\n\n" }
            text += recognised.text
            confidenceSum += recognised.confidence * Double(recognised.text.count)
            confidenceWeight += Double(recognised.text.count)
        }

        guard let plainText = PlainTextExtractor.sanitized(text) else {
            // OCR ran and found nothing. That is a different answer from «no
            // text layer» — there is nothing more to try.
            throw ExtractionError.empty
        }

        let confidence = confidenceWeight > 0 ? confidenceSum / confidenceWeight : 0
        return ExtractedDocument(
            plainText: plainText,
            // Deliberately none: says structural chunking is not available
            // for recognised text, and a heading guessed from OCR output would
            // be a guess on top of a guess.
            structure: [],
            pageCount: document.pageCount,
            pageStarts: pageStarts,
            warnings: [.ocrUsed(averageConfidence: confidence)],
            structureSource: .none,
            containerFormat: "pdf",
            extractorID: id,
            extractorVersion: version,
            ocrUsed: true,
            ocrConfidence: confidence,
            documentMetadata: [:]
        )
    }

    // MARK: - Languages

    /// What this system can actually recognise.
    ///
    /// Never a hardcoded list: the set differs between macOS versions, and a
    /// list written into the app would promise languages the machine does not
    /// have and hide ones it does.
    public static func supportedLanguages() -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? []
    }

    /// The languages a run will use, refusing the ones this system cannot do.
    static func resolvedLanguages(_ requested: [String]) throws -> [String] {
        let supported = supportedLanguages()
        guard !requested.isEmpty else { return [] }
        let usable = requested.filter { supported.contains($0) }
        guard !usable.isEmpty else {
            throw ExtractionError.unsupportedFormat(
                String(localized: "языки распознавания \(requested.joined(separator: ", ")) недоступны на этой системе")
            )
        }
        return usable
    }

    // MARK: - One page

    struct PageText {
        let text: String
        /// 0…1, weighted by how much text each observation carried.
        let confidence: Double
    }

    static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width * renderScale)
        let height = Int(bounds.height * renderScale)
        guard width > 0, height > 0 else { return nil }

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: renderScale, y: renderScale)
        context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    /// One page through Vision, bounded in time.
    ///
    /// The timeout is per page, as requires: a single unreadable page must
    /// not decide how long a two-hundred-page scan takes.
    static func recognise(_ image: CGImage, languages: [String], timeout: TimeInterval) async throws -> PageText {
        try await withThrowingTaskGroup(of: PageText.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    let request = VNRecognizeTextRequest { request, error in
                        if let error {
                            continuation.resume(throwing: ExtractionError.corrupted(error.localizedDescription))
                            return
                        }
                        let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                        var lines: [String] = []
                        var weighted = 0.0
                        var weight = 0.0
                        for observation in observations {
                            guard let candidate = observation.topCandidates(1).first else { continue }
                            let line = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !line.isEmpty else { continue }
                            lines.append(line)
                            weighted += Double(candidate.confidence) * Double(line.count)
                            weight += Double(line.count)
                        }
                        continuation.resume(returning: PageText(
                            text: lines.joined(separator: "\n"),
                            confidence: weight > 0 ? weighted / weight : 0
                        ))
                    }
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    if !languages.isEmpty { request.recognitionLanguages = languages }

                    do {
                        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                    } catch {
                        continuation.resume(throwing: ExtractionError.corrupted(error.localizedDescription))
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
                throw ExtractionError.timedOut(seconds: timeout)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw ExtractionError.empty }
            return first
        }
    }
}
