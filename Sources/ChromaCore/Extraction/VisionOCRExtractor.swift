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
    /// 3 — таблицы распознанной страницы собираются по координатам слов
    ///, тем же разбором, что и у PDF с текстовым слоем.
    ///
    /// 2 — сшивка строк в абзацы и смещения страниц, считаемые после
    /// разделителя.
    /// 4 — большие страницы распознаются плитками: лист А0 приходил
    /// пустым, потому что при обзорном масштабе буквы на нём мельче, чем
    /// видит Vision. Меняется сам текст — предложит перечитать файлы.
    public let version = 4

    /// Rendering scale for a page before recognition. 2× the nominal 72 dpi is
    /// the usual floor for Vision on scanned text; below it the accuracy drops
    /// sharply, above it the time grows faster than the accuracy.
    static let renderScale: CGFloat = 2

    /// Страница крупнее этого по любой стороне распознаётся плитками.
    ///
    /// Замер на живом файле — схеме архитектуры размером 1649×1040 мм:
    /// страница целиком при двукратном увеличении даёт изображение
    /// 9354×5901 и **ноль** распознанных строк, четверть страницы при
    /// четырёхкратном — сорок две. Дело не в числе пикселей, а в размере
    /// буквы: на плакате шрифт мелкий, и при обзорном масштабе от него
    /// остаётся несколько точек.
    static let tileThreshold: CGFloat = 1_600
    /// Сторона плитки в пунктах — примерно лист A4.
    static let tileSide: CGFloat = 1_000
    /// Перекрытие плиток: строка, попавшая на стык, должна целиком войти
    /// хотя бы в одну из них.
    static let tileOverlap: CGFloat = 48
    /// Плитка мельче страницы, поэтому её можно рисовать крупнее.
    static let tileScale: CGFloat = 4

    /// Нужны ли этой странице плитки.
    static func needsTiling(_ page: PDFPage) -> Bool {
        let bounds = page.bounds(for: .mediaBox)
        return max(bounds.width, bounds.height) > tileThreshold
    }

    /// Плитки страницы — слева направо, сверху вниз, с перекрытием.
    static func tiles(of bounds: CGRect) -> [CGRect] {
        let step = tileSide - tileOverlap
        guard step > 0 else { return [bounds] }
        var result: [CGRect] = []
        var top = bounds.maxY
        while top > bounds.minY {
            let height = min(tileSide, top - bounds.minY)
            var left = bounds.minX
            while left < bounds.maxX {
                let width = min(tileSide, bounds.maxX - left)
                result.append(CGRect(x: left, y: top - height, width: width, height: height))
                left += step
            }
            top -= step
        }
        return result
    }

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
        var length = 0
        var confidenceSum = 0.0
        var confidenceWeight = 0.0
        /// Нашлась ли хоть на одной странице таблица. До этого
        /// у распознанного скана признака таблиц не было вовсе — при том,
        /// что ведомость и смета обычно и приходят сканами.
        var hasTables = false

        for index in 0..<document.pageCount {
            // Cancellation between pages, not inside one: a Vision request is a
            // single system call, and a folder of scans has to stay stoppable.
            try Task.checkCancellation()
            options.progress?(ExtractionProgress(
                stage: .recognising, unit: index + 1, total: document.pageCount
            ))

            guard let page = document.page(at: index) else {
                pageStarts.append(length)
                continue
            }
            let recognised: PageText
            if Self.needsTiling(page) {
                // Плакат, чертёж, схема на лист А0: целиком такая
                // страница распознаётся в ноль строк — буквы на ней мельче,
                // чем видит Vision при обзорном масштабе.
                recognised = try await Self.recogniseByTiles(
                    page, languages: languages, timeout: options.ocrPageTimeout
                )
            } else {
                guard let image = Self.render(page) else {
                    pageStarts.append(length)
                    continue
                }
                recognised = try await Self.recognise(
                    image, languages: languages, timeout: options.ocrPageTimeout
                )
            }
            // Vision отдаёт по строке на наблюдение, то есть ровно ту же
            // построчную россыпь, что и текстовый слой PDF, — и сшивается
            // она тем же способом. Словаря документа здесь нет:
            // страницы распознаются по одной, и ждать всех ради дефисов
            // значило бы держать в памяти весь распознанный текст дважды.
            // На табличной странице сшивать нечего: строка там — строка
            // таблицы, и склеить её со следующей значило бы смешать записи.
            let reflowed = recognised.table ?? PDFTextReflow.page(recognised.text)
            if recognised.table != nil { hasTables = true }
            guard !reflowed.isEmpty else {
                pageStarts.append(length)
                continue
            }

            // Смещение записывается **после** разделителя, как в PDFExtractor:
            // записанное раньше, оно указывало на хвост предыдущей страницы
            //.
            if length > 0 {
                text += "\n\n"
                length += 2
            }
            pageStarts.append(length)
            text += reflowed
            length += reflowed.count
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
            warnings: hasTables
                ? [.ocrUsed(averageConfidence: confidence), .tablesFlattened]
                : [.ocrUsed(averageConfidence: confidence)],
            structureSource: .none,
            containerFormat: "pdf",
            extractorID: id,
            extractorVersion: version,
            hasTables: hasTables,
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
        /// Страница, собранная по координатам слов, если на ней таблица
        ///. Сшивать её в абзацы нельзя: строка там — строка таблицы.
        var table: String?
    }

    /// Слова распознанной строки с их рамками в точках изображения.
    ///
    /// Vision считает рамки долями страницы, а пороги разбора — в тех же
    /// единицах, что и рост знака, поэтому доли переводятся в точки. Если
    /// рамку слова получить не удалось, берётся рамка всего наблюдения:
    /// одна ячейка на строку — хуже, чем колонки, но лучше, чем ничего.
    static func words(
        of candidate: VNRecognizedText, in image: CGImage, fallback: VNRecognizedTextObservation
    ) -> [TableGeometry.Word] {
        let string = candidate.string
        var result: [TableGeometry.Word] = []
        var start = string.startIndex
        while start < string.endIndex {
            guard let from = string[start...].firstIndex(where: { !$0.isWhitespace }) else { break }
            let to = string[from...].firstIndex(where: { $0.isWhitespace }) ?? string.endIndex
            let text = String(string[from..<to])
            if let box = try? candidate.boundingBox(for: from..<to) {
                result.append(TableGeometry.Word(
                    box: VNImageRectForNormalizedRect(box.boundingBox, image.width, image.height),
                    text: text
                ))
            }
            start = to
        }
        guard result.isEmpty else { return result }
        let whole = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !whole.isEmpty else { return [] }
        return [TableGeometry.Word(
            box: VNImageRectForNormalizedRect(fallback.boundingBox, image.width, image.height),
            text: whole
        )]
    }

    static func render(_ page: PDFPage, region: CGRect? = nil, scale: CGFloat = renderScale) -> CGImage? {
        let bounds = region ?? page.bounds(for: .mediaBox)
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0 else { return nil }

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    /// Большая страница — по плиткам.
    ///
    /// Плитки идут слева направо и сверху вниз, с перекрытием, и их тексты
    /// склеиваются в том же порядке. Порядок чтения у схемы условен, но
    /// «сверху вниз» — то же, что делает человек, а главное, текст вообще
    /// попадает в базу: до этого лист А0 приходил пустым.
    static func recogniseByTiles(
        _ page: PDFPage, languages: [String], timeout: TimeInterval
    ) async throws -> PageText {
        let bounds = page.bounds(for: .mediaBox)
        var parts: [String] = []
        var confidenceSum = 0.0
        var counted = 0

        for tile in tiles(of: bounds) {
            try Task.checkCancellation()
            guard let image = render(page, region: tile, scale: tileScale) else { continue }
            let recognised = try await recognise(image, languages: languages, timeout: timeout)
            let text = (recognised.table ?? recognised.text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            parts.append(text)
            confidenceSum += recognised.confidence
            counted += 1
        }

        guard !parts.isEmpty else { return PageText(text: "", confidence: 0, table: nil) }
        // Перекрытие плиток повторяет строки на стыках — повторы убираются
        // здесь, иначе половина строк схемы придёт дважды.
        var seen: Set<String> = []
        let lines = parts.joined(separator: "\n").split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard line.count > 2 else { return true }
                return seen.insert(line).inserted
            }
        return PageText(
            text: lines.joined(separator: "\n"),
            confidence: counted > 0 ? confidenceSum / Double(counted) : 0,
            table: nil
        )
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
                        var words: [TableGeometry.Word] = []
                        var weighted = 0.0
                        var weight = 0.0
                        for observation in observations {
                            guard let candidate = observation.topCandidates(1).first else { continue }
                            let line = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !line.isEmpty else { continue }
                            lines.append(line)
                            words.append(contentsOf: Self.words(of: candidate, in: image, fallback: observation))
                            weighted += Double(candidate.confidence) * Double(line.count)
                            weight += Double(line.count)
                        }
                        // Таблица на скане — не редкость, а типичный случай:
                        // ведомость, смета, реестр. Vision отдаёт наблюдения
                        // россыпью, и без координат строка таблицы теряется
                        // ровно так же, как в текстовом слое PDF.
                        let height = TableGeometry.medianHeight(of: words)
                        let table = height > 0
                            ? TableGeometry.text(of: TableGeometry.lines(from: words, height: height, separated: true))
                            : nil
                        continuation.resume(returning: PageText(
                            text: lines.joined(separator: "\n"),
                            confidence: weight > 0 ? weighted / weight : 0,
                            table: table
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
