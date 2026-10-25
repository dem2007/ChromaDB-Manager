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
    /// 6 — текст читается в родном разрешении скана, недочитанная ячейка
    /// перечитывается вырезкой из него; записи нумерованной таблицы —
    /// одной строкой; абзац через границу страницы — одним абзацем.
    ///
    /// 5 — страница с поворотом рисуется целиком: холст был размером
    /// с неповёрнутую страницу, и у письма с поворотом 270° верх — шапка
    /// и пять строк расчёта КП — обрезался до распознавания. Повёрнутый
    /// внутри картинки текст (альбомная таблица на книжном листе)
    /// разворачивается, таблицы скана собираются по линиям рамки
    /// с объединёнными ячейками, а пустая на вид ячейка с «чернилами»
    /// распознаётся ещё раз отдельно — Vision теряет одиночные цифры
    /// в колонке количества.
    ///
    /// 3 — таблицы распознанной страницы собираются по координатам слов
    ///, тем же разбором, что и у PDF с текстовым слоем.
    ///
    /// 2 — сшивка строк в абзацы и смещения страниц, считаемые после
    /// разделителя.
    /// 4 — большие страницы распознаются плитками: лист А0 приходил
    /// пустым, потому что при обзорном масштабе буквы на нём мельче, чем
    /// видит Vision. Меняется сам текст — предложит перечитать файлы.
    ///
    /// 9 — знаки нормализуются, оглавление скана не индексируется.
    ///
    /// 10 — схема со скана не собирается в таблицу.
    ///
    /// 11 — подпись во всю ширину распознанной таблицы один раз.
    ///
    /// 12 — таблицы большой страницы, распознанной плитками, остаются
    /// таблицами, а повтор строки убирается только на стыке соседних
    /// плиток.
    public let version = 12

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
        var lastPage: String?

        var contentsContinues = false
        var contentsLines = 0
        /// Страницы, которые распознать не вышло, — по номерам.
        var failedPages: [Int] = []
        /// Большие страницы, у которых прочитались не все плитки.
        var partialPages: [Int] = []
        var lastFailure: Error?
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
            // Одна страница, не уложившаяся в срок или сломавшая Vision, —
            // пропуск этой страницы, а не всего скана: раньше ошибка
            // сто пятидесятой страницы выбрасывала сто сорок девять уже
            // распознанных, и файл уходил в «требуют решения».
            let result: PageText?
            do {
                result = try await Self.recognisePage(page, languages: languages, timeout: options.ocrPageTimeout)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failedPages.append(index + 1)
                lastFailure = error
                pageStarts.append(length)
                lastPage = nil
                contentsContinues = false
                continue
            }
            guard let recognised = result else {
                pageStarts.append(length)
                continue
            }
            if recognised.unreadTiles > 0 { partialPages.append(index + 1) }
            // Vision отдаёт по строке на наблюдение, то есть ровно ту же
            // построчную россыпь, что и текстовый слой PDF, — и сшивается
            // она тем же способом. Словаря документа здесь нет:
            // страницы распознаются по одной, и ждать всех ради дефисов
            // значило бы держать в памяти весь распознанный текст дважды.
            // На табличной странице сшивать нечего: строка там — строка
            // таблицы, и склеить её со следующей значило бы смешать записи.
            // Оглавление скана — тем же правилом, что у текстового слоя
            //: страница, им кончившаяся, передаёт это следующей.
            let reflowed: String
            if let blocks = recognised.blocks {
                reflowed = TableGeometry.render(blocks, vocabulary: .empty)
                contentsContinues = false
            } else {
                let contents = PDFContents.removing(
                    TextNormalization.normalized(recognised.text).components(separatedBy: .newlines),
                    continuing: contentsContinues
                )
                contentsContinues = contents.endsInContents
                contentsLines += contents.removed
                reflowed = PDFTextReflow.page(contents.lines.joined(separator: "\n"))
            }
            if recognised.hasTable { hasTables = true }
            guard !reflowed.isEmpty else {
                pageStarts.append(length)
                // Пустая страница — граница: абзац через неё не склеивается.
                lastPage = nil
                continue
            }

            // Смещение записывается **после** разделителя, как в PDFExtractor:
            // записанное раньше, оно указывало на хвост предыдущей страницы
            //.
            if length > 0 {
                // Абзац через границу страницы — одним абзацем.
                if let previous = lastPage,
                   let bridge = PDFTextReflow.bridge(previous, reflowed, vocabulary: .empty) {
                    text.removeLast(bridge.drop)
                    text += bridge.separator
                    length += bridge.separator.count - bridge.drop
                } else {
                    text += "\n\n"
                    length += 2
                }
            }
            lastPage = reflowed
            pageStarts.append(length)
            text += reflowed
            length += reflowed.count
            confidenceSum += recognised.confidence * Double(recognised.text.count)
            confidenceWeight += Double(recognised.text.count)
        }

        guard let plainText = PlainTextExtractor.sanitized(text) else {
            // Не распозналась ни одна страница — причина в самой ошибке:
            // «превышен срок» говорит человеку больше, чем «пусто».
            if let lastFailure { throw lastFailure }
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
            warnings: [.ocrUsed(averageConfidence: confidence)]
                + (hasTables ? [.tablesFlattened] : [])
                + (contentsLines > 0
                    ? [.other(String(localized: "оглавление не индексируется: \(contentsLines.plainDigits) строк — те же заголовки есть в тексте документа"))]
                    : [])
                + (failedPages.isEmpty
                    ? []
                    : [.other(String(localized: "страницы не распознаны (\(failedPages.map(String.init).joined(separator: ", "))) — их текста в базе нет"))])
                + Self.partialPagesWarning(partialPages),
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
        /// Страница кусками — таблицы и строки текста, — если на ней нашлась
        /// таблица. Сшивать таблицу в абзацы нельзя: строка
        /// там — строка таблицы.
        var blocks: [TableGeometry.PageBlock]?

        /// Плиток большой страницы, которые не прочитались: не хватило срока
        /// страницы или Vision отказал (ревью…).
        var unreadTiles = 0

        var hasTable: Bool {
            blocks?.contains { if case .table = $0 { return true } else { return false } } ?? false
        }

        /// Страница с таблицей — текстом.
        var table: String? {
            hasTable ? blocks.map { TableGeometry.render($0, vocabulary: .empty) } : nil
        }
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

    /// Страница в координатах показа — с учётом её поворота.
    ///
    /// `PDFPage.draw` рисует страницу уже повёрнутой, а холст раньше брался
    /// размером с неповёрнутую: у письма с поворотом 270° книжная страница
    /// ложилась на альбомный холст, и верхняя треть — шапка и пять строк
    /// расчёта КП — до распознавания не доходила вовсе.
    static func displayBounds(_ page: PDFPage) -> CGRect {
        let box = page.bounds(for: .mediaBox)
        guard page.rotation % 180 != 0 else { return box }
        return CGRect(x: 0, y: 0, width: box.height, height: box.width)
    }

    static func render(_ page: PDFPage, region: CGRect? = nil, scale: CGFloat = renderScale) -> CGImage? {
        let bounds = region ?? displayBounds(page)
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

    /// Оговорка о больших страницах, прочитанных не целиком: часть плиток
    /// не прочлась, и текста с них в базе нет. Пустой список — оговорки нет.
    /// - Parameter pages: номера страниц, с единицы.
    static func partialPagesWarning(_ pages: [Int]) -> [ExtractionWarning] {
        guard !pages.isEmpty else { return [] }
        return [.other(String(localized: "страницы распознаны не целиком (\(pages.map(String.init).joined(separator: ", "))) — часть листа не прочиталась, её текста в базе нет"))]
    }

    /// Срок одной страницы — один на все вызовы Vision ради неё.
    ///
    /// Раньше срок давался каждому вызову: два прочтения страницы, каждая
    /// плитка и до восьми попыток у каждой из сорока ячеек — больше трёхсот
    /// вызовов по 120 с. Страница, у которой каждый вызов укладывался
    /// в срок, могла идти часами, и ничто выше её не останавливало.
    struct PageDeadline: Sendable {
        /// Назначенный срок — для сообщения об ошибке.
        let seconds: TimeInterval
        let end: Date

        init(seconds: TimeInterval, now: Date = Date()) {
            self.seconds = max(1, seconds)
            end = now.addingTimeInterval(self.seconds)
        }

        var remaining: TimeInterval { end.timeIntervalSinceNow }
        var expired: Bool { remaining <= 0 }
    }

    /// Одна страница: целиком или плитками.
    /// - Parameter rulings: уже сделанный разбор страницы, если он есть.
    static func recognisePage(
        _ page: PDFPage, languages: [String], timeout: TimeInterval, rulings: PDFRulings? = nil
    ) async throws -> PageText? {
        let deadline = PageDeadline(seconds: timeout)
        if needsTiling(page) {
            // Плакат, чертёж, схема на лист А0: целиком такая
            // страница распознаётся в ноль строк — буквы на ней мельче,
            // чем видит Vision при обзорном масштабе.
            return try await recogniseByTiles(page, languages: languages, deadline: deadline)
        }
        guard let image = render(page) else { return nil }
        let detailed = detailScale(of: page, rulings: rulings).flatMap { render(page, scale: $0) }
        return try await recognise(image, detailed: detailed, languages: languages, deadline: deadline)
    }

    /// Не детальнее этого: дальше Vision точнее не становится, а память растёт.
    static let maximumDetail: CGFloat = 4.5
    /// И не больше стольких точек на картинку.
    static let maximumDetailPixels: CGFloat = 30_000_000

    /// Масштаб, в котором скан на странице виден целиком, без потерь
    ///, или `nil`, если обычного хватает.
    ///
    /// Скан внутри PDF — картинка 300 dpi, около 4,2 точки на пункт, а
    /// страница рисуется вдвое. Одиночная «1» в колонке «№» превращалась
    /// в штрих три точки на пятнадцать и не читалась ни в каком варианте;
    /// та же ячейка в родном разрешении читается. Замер на трёх письмах:
    /// страница целиком в родном разрешении распознаётся за то же время
    /// и даёт на 6–12 % больше текста.
    static func detailScale(of page: PDFPage, rulings: PDFRulings? = nil) -> CGFloat? {
        let rulings = rulings ?? PDFRulings.scan(page)
        guard rulings.imageCoverage >= 0.3, let detail = rulings.imageDetail else { return nil }
        let bounds = displayBounds(page)
        let byPixels = (maximumDetailPixels / max(1, bounds.width * bounds.height)).squareRoot()
        let scale = min(CGFloat(detail), maximumDetail, byPixels)
        return scale > renderScale * 1.15 ? scale : nil
    }

    /// Большая страница — по плиткам.
    ///
    /// Плитки идут слева направо и сверху вниз, с перекрытием, и их тексты
    /// склеиваются в том же порядке. Порядок чтения у схемы условен, но
    /// «сверху вниз» — то же, что делает человек, а главное, текст вообще
    /// попадает в базу: до этого лист А0 приходил пустым.
    static func recogniseByTiles(
        _ page: PDFPage, languages: [String], deadline: PageDeadline
    ) async throws -> PageText {
        let rects = tiles(of: displayBounds(page))
        var read: [(rect: CGRect, text: PageText)] = []
        var lastFailure: Error?
        // Срок страницы кончился посреди плиток или плитка не прочлась —
        // страница прочитана не вся, и об этом надо сказать: раньше у каждой
        // плитки был свой срок, а теперь хвост большого листа пропадал молча
        // (ревью…). Считаются только эти два случая: полоска
        // у края листа тоньше точки картинки не рисуется, и текста на ней нет.
        var unread = 0
        for (position, tile) in rects.enumerated() {
            try Task.checkCancellation()
            guard !deadline.expired else {
                unread += rects.count - position
                break
            }
            guard let image = render(page, region: tile, scale: tileScale) else { continue }
            // Плитка — кусок схемы или чертежа: рамку там не ищем, иначе
            // блоки схемы шли за таблицы, а время — на каждую плитку.
            do {
                read.append((tile, try await recognise(image, languages: languages, deadline: deadline, rulings: false)))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Плитка не прочлась — остальные от этого хуже не станут.
                lastFailure = error
                unread += 1
            }
        }
        var merged = mergedTiles(read)
        if merged.text.isEmpty, !merged.hasTable, let lastFailure { throw lastFailure }
        merged.unreadTiles = unread
        return merged
    }

    /// Плитки страницы — в одну страницу.
    ///
    /// Таблицы плитки остаются таблицами: раньше плитка сводилась к тексту,
    /// признак таблицы пропадал, и строки таблицы сшивались в абзацы как
    /// проза. А повтор строки убирается только на стыке — если она есть
    /// в соседней плитке, с которой эта перекрывается. Общий список на всю
    /// страницу съедал и законные повторы: одинаковые строки в разных концах
    /// чертежа. Строки таблиц сверяются так же: строка, легшая в перекрытие,
    /// приходила в таблицах обеих плиток (ревью…).
    static func mergedTiles(_ tiles: [(rect: CGRect, text: PageText)]) -> PageText {
        var blocks: [TableGeometry.PageBlock] = []
        var lines: [String] = []
        var linesOfTile: [Set<String>] = []
        var confidenceSum = 0.0
        var counted = 0
        for (index, tile) in tiles.enumerated() {
            let neighbours = tiles[..<index].indices.filter { tiles[$0].rect.intersects(tile.rect) }
            var own: Set<String> = []
            /// Строка, которая есть и в соседней плитке, — повтор на стыке.
            func isRepeat(_ line: String) -> Bool {
                own.insert(line)
                return line.count > 2 && neighbours.contains { linesOfTile[$0].contains(line) }
            }
            var any = false
            for block in tile.text.blocks ?? [.text(tile.text.text.components(separatedBy: .newlines))] {
                switch block {
                case .table(let rows, let edges):
                    let kept = rows.filter { !isRepeat($0.joined(separator: " ").trimmingCharacters(in: .whitespaces)) }
                    guard !kept.isEmpty else { continue }
                    blocks.append(.table(rows: kept, edges: edges))
                    // Текст страницы — всё прочитанное: по нему взвешивается
                    // уверенность.
                    lines += kept.map { $0.joined(separator: " ") }
                    any = true
                case .text(let text):
                    let kept = text.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !isRepeat($0) }
                    guard !kept.isEmpty else { continue }
                    blocks.append(.text(kept))
                    lines += kept
                    any = true
                }
            }
            linesOfTile.append(own)
            guard any else { continue }
            confidenceSum += tile.text.confidence
            counted += 1
        }
        let result = PageText(
            text: lines.joined(separator: "\n"),
            confidence: counted > 0 ? confidenceSum / Double(counted) : 0,
            blocks: blocks
        )
        // Без таблиц — обычный текст: его сшивает в абзацы вызывающий.
        return result.hasTable ? result : PageText(text: result.text, confidence: result.confidence, blocks: nil)
    }

    /// Картинка страницы: распознать, при нужде развернуть, собрать таблицы.
    ///
    /// - Parameter detailed: та же страница в родном разрешении скана
    ///. Текст читается по ней, слова переводятся в точки обычной
    ///   картинки; рамка ищется по обычной — пороги поиска подобраны под неё.
    static func recognise(
        _ image: CGImage, detailed: CGImage? = nil, languages: [String], deadline: PageDeadline,
        rulings: Bool = true
    ) async throws -> PageText {
        var image = image
        var detailed = detailed
        func read(_ image: CGImage, _ detailed: CGImage?) async throws -> Observed {
            guard let detailed else { return try await observe(image, languages: languages, deadline: deadline) }
            var seen = try await observe(detailed, languages: languages, deadline: deadline)
            let factor = CGFloat(image.width) / CGFloat(detailed.width)
            seen.words = seen.words.map { word in
                TableGeometry.Word(box: CGRect(
                    x: word.box.minX * factor, y: word.box.minY * factor,
                    width: word.box.width * factor, height: word.box.height * factor
                ), text: word.text)
            }
            return seen
        }
        var seen = try await read(image, detailed)
        // Текст повёрнут внутри картинки — альбомная таблица на книжном
        // листе. Vision слова такого текста читает, но рамки отдаёт в осях
        // картинки, и строки таблицы шли столбцами: «софт» «Системный»,
        // суммы по кускам. Картинка разворачивается, и всё читается заново.
        if let turn = seen.turn, let upright = rotated(image, clockwise: turn == .clockwise) {
            let uprightDetailed = detailed.flatMap { rotated($0, clockwise: turn == .clockwise) }
            // Второе прочтение — попытка лучше, а не условие: не вышло
            // в срок — остаётся первое.
            let again: Observed?
            do {
                again = try await read(upright, uprightDetailed)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                again = nil
            }
            if let again, again.characters * 2 >= seen.characters {
                image = upright
                detailed = uprightDetailed
                seen = again
            }
        }
        return try await analyse(
            seen, image: image, detailed: detailed, languages: languages, deadline: deadline, rulings: rulings
        )
    }

    // MARK: - Наблюдения Vision

    struct Observed {
        var lines: [String] = []
        var words: [TableGeometry.Word] = []
        var confidence = 0.0
        var characters = 0
        /// Куда развернуть картинку, чтобы текст встал строками.
        var turn: Turn?
    }

    enum Turn { case clockwise, counterclockwise }

    /// Доля знаков в вертикальных строках, с которой картинка считается
    /// повёрнутой. Подписи осей и боковые штампы бывают и на обычной
    /// странице — их мало.
    static let rotatedShare = 0.6

    /// Очередь вызовов Vision.
    ///
    /// `perform` синхронный и может застрять. Вызванный прямо из задачи, он
    /// занимал поток общего пула Swift, а таких потоков столько, сколько
    /// ядер: срок истекал, ответ уходил дальше, а поток оставался занят.
    /// Несколько застрявших страниц — и вставала вся асинхронная работа
    /// приложения. Потоки этой очереди — потоки GCD: застрявший держит
    /// только себя.
    static let visionQueue = DispatchQueue(
        label: "chromadb.ocr.vision", qos: .userInitiated, attributes: .concurrent
    )

    /// One image through Vision, bounded by the page's deadline.
    ///
    /// The deadline is per page, as requires: a single unreadable page
    /// must not decide how long a two-hundred-page scan takes.
    static func observe(
        _ image: CGImage, languages: [String], deadline: PageDeadline, correction: Bool = true
    ) async throws -> Observed {
        // Остаток — один раз: `Deadline.race` с нулём и меньше ждёт без срока,
        // и срок, истёкший между проверкой и вызовом, пускал застрявший
        // `perform` ждать вечно (ревью…).
        let remaining = deadline.remaining
        guard remaining > 0 else { throw ExtractionError.timedOut(seconds: deadline.seconds) }
        // Срок — через `Deadline`, а не группу задач: `perform` синхронный,
        // и группа ждала бы застрявшую страницу до конца, какой бы срок
        // ни был назначен.
        return try await Deadline.race(
            seconds: remaining,
            timeoutError: { ExtractionError.timedOut(seconds: deadline.seconds) }
        ) {
            try await withCheckedThrowingContinuation { (checked: CheckedContinuation<Observed, Error>) in
                // Ошибку Vision сообщает дважды: обработчику запроса и
                // броском из `perform`. Возобновить продолжение второй
                // раз — ловушка посреди прогона OCR.
                let continuation = OnceContinuation(checked)
                let request = VNRecognizeTextRequest { request, error in
                    if let error {
                        continuation.resume(with: .failure(ExtractionError.corrupted(error.localizedDescription)))
                        return
                    }
                    var observed = Observed()
                    var weighted = 0.0
                    var vertical = 0
                    var upward = 0
                    for observation in (request.results as? [VNRecognizedTextObservation]) ?? [] {
                        guard let candidate = observation.topCandidates(1).first else { continue }
                        let line = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !line.isEmpty else { continue }
                        observed.lines.append(line)
                        observed.words.append(contentsOf: Self.words(of: candidate, in: image, fallback: observation))
                        weighted += Double(candidate.confidence) * Double(line.count)
                        observed.characters += line.count
                        // Направление строки — от левого верхнего угла
                        // к правому верхнему, в точках картинки.
                        let dx = (observation.topRight.x - observation.topLeft.x) * CGFloat(image.width)
                        let dy = (observation.topRight.y - observation.topLeft.y) * CGFloat(image.height)
                        if abs(dy) > abs(dx) {
                            vertical += line.count
                            if dy > 0 { upward += line.count }
                        }
                    }
                    observed.confidence = observed.characters > 0 ? weighted / Double(observed.characters) : 0
                    if observed.characters >= 20, Double(vertical) >= Double(observed.characters) * Self.rotatedShare {
                        // Строка снизу вверх — лист повёрнут против часовой,
                        // и разворачивать его надо по часовой.
                        observed.turn = upward * 2 >= vertical ? .clockwise : .counterclockwise
                    }
                    continuation.resume(with: .success(observed))
                }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = correction
                if !languages.isEmpty { request.recognitionLanguages = languages }

                let job = VisionJob(request: request)
                Self.visionQueue.async {
                    do {
                        try VNImageRequestHandler(cgImage: image, options: [:]).perform([job.request])
                    } catch {
                        continuation.resume(with: .failure(ExtractionError.corrupted(error.localizedDescription)))
                    }
                }
            }
        }
    }

    /// Запрос Vision, переданный в очередь: сам он не `Sendable`, но после
    /// передачи его трогает только `perform`.
    private struct VisionJob: @unchecked Sendable {
        let request: VNRecognizeTextRequest
    }

    /// Картинка, повёрнутая на четверть оборота.
    static func rotated(_ image: CGImage, clockwise: Bool) -> CGImage? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        guard let context = CGContext(
            data: nil, width: image.height, height: image.width,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        // По часовой: точка (x, y) встаёт в (y, ширина − x); против — в
        // (высота − y, x).
        context.concatenate(clockwise
            ? CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
            : CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    // MARK: - Таблицы скана

    /// Допуск рамки на картинке, в точках изображения: линия скана толщиной
    /// в несколько точек, и стороны соседних ячеек расходятся сильнее, чем
    /// в векторе.
    static let rasterTolerance = 5.0
    /// Ячеек, распознаваемых повторно, — не больше стольких на страницу.
    /// Попыток у ячейки до восьми, так что худший случай — 320 вызовов
    /// Vision. Ограничивать вызовы, а не ячейки, пробовали: на плотной
    /// странице КП десятки ячеек количества читаются только повторно,
    /// и при 60 вызовах сходящихся строк стало 197 против 205, при 160 —
    /// 202. Время КП на 11 страниц при этом — около 24 с.
    static let maximumRereads = 40
    /// С какой доли заполненных ячеек сетка перечитывается.
    static let rereadFilledShare = 0.4

    /// Слова — в таблицы и текст страницы.
    static func analyse(
        _ seen: Observed, image: CGImage, detailed: CGImage? = nil, languages: [String], deadline: PageDeadline,
        rulings: Bool = true
    ) async throws -> PageText {
        var words = seen.words
        let height = TableGeometry.medianHeight(of: words)
        var blocks: [TableGeometry.PageBlock]?
        if height > 0 {
            var grids: [TableLattice.Grid] = []
            if rulings, let raster = Raster(image) {
                grids = TableLattice.grids(
                    from: Self.clear(raster.rulings(), of: words), tolerance: rasterTolerance,
                    sparse: (columns: 0.5, rows: 0.3)
                )
                // Перечитывать — только в сетке, похожей на таблицу: текст уже
                // есть хотя бы в двух ячейках из пяти. Рамки блоков схемы
                // со значками внутри — не таблица, и перечитывать там нечего:
                // на схеме архитектуры это было восемьдесят лишних вызовов.
                let tables = grids.filter { TableLattice.filledShare($0, words: words) >= rereadFilledShare }
                if !tables.isEmpty {
                    words = try await rereadCells(
                        tables, words: words, raster: raster, image: image, detailed: detailed,
                        languages: languages, deadline: deadline
                    )
                }
            }
            blocks = TableGeometry.page(words: words, grids: grids, height: height, separated: true).blocks
        }
        return PageText(text: seen.lines.joined(separator: "\n"), confidence: seen.confidence, blocks: blocks)
    }

    /// Линии, которые идут сквозь слова, — не рамка.
    ///
    /// Рамка проходит между словами, а не через них. А сквозь слова идут
    /// ложные линии: палочки букв соседних строк таблицы, склеенные через
    /// линию рамки между строками, — на повёрнутом КП они резали колонку
    /// «Наименование» на семь, и слово «сертификатов» распадалось на два.
    /// Рамка слова берётся с запасом внутрь: Vision обводит слово чуть
    /// шире, и настоящая линия рядом его задевает.
    static func clear(_ rulings: TableLattice.Rulings, of words: [TableGeometry.Word]) -> TableLattice.Rulings {
        let boxes = words.map { word in
            word.box.insetBy(dx: word.box.width * 0.15, dy: word.box.height * 0.2)
        }
        func overlap(_ segment: TableLattice.Segment, horizontal: Bool) -> Double {
            boxes.reduce(0) { total, box in
                let across = horizontal ? Double(box.minY)...Double(box.maxY) : Double(box.minX)...Double(box.maxX)
                guard across.contains(segment.position) else { return total }
                let low = horizontal ? Double(box.minX) : Double(box.minY)
                let high = horizontal ? Double(box.maxX) : Double(box.maxY)
                return total + max(0, min(high, segment.to) - max(low, segment.from))
            }
        }
        func keeps(_ segment: TableLattice.Segment, horizontal: Bool) -> Bool {
            overlap(segment, horizontal: horizontal) < (segment.to - segment.from) * 0.3
        }
        return TableLattice.Rulings(
            horizontal: rulings.horizontal.filter { keeps($0, horizontal: true) },
            vertical: rulings.vertical.filter { keeps($0, horizontal: false) }
        )
    }

    /// Ячейки, где Vision прочёл меньше, чем напечатано, — ещё раз,
    /// по одной.
    ///
    /// Vision при обзоре страницы теряет одиночные знаки и целые строки:
    /// в расчёте КП из восьми количеств «1» осталось три, а из описания
    /// работ в объединённой ячейке пропали две строки из семи. Та же ячейка,
    /// вырезанная, увеличенная и с полями, читается верно. Сколько
    /// напечатано, видно по «краске» внутри ячейки без рамки: краска вне
    /// рамок прочитанных слов — непрочитанный текст. Перечитанное заменяет
    /// слова ячейки, если в нём больше знаков.
    ///
    /// Перечитывание — добавка к уже прочитанному, а не условие:
    /// истёк срок страницы или Vision отказал на вырезке — перечитывание
    /// кончается, а страница остаётся с тем, что уже есть.
    static func rereadCells(
        _ grids: [TableLattice.Grid], words: [TableGeometry.Word], raster: Raster,
        image: CGImage, detailed: CGImage? = nil, languages: [String], deadline: PageDeadline
    ) async throws -> [TableGeometry.Word] {
        var words = words
        var budget = maximumRereads
        var stopped = false
        for grid in grids where !stopped {
            var byRegion: [Int: [Int]] = [:]
            for (index, word) in words.enumerated() {
                if let region = grid.region(at: CGPoint(x: word.box.midX, y: word.box.midY)) {
                    byRegion[region, default: []].append(index)
                }
            }
            var replaced: Set<Int> = []
            var added: [TableGeometry.Word] = []
            for (index, region) in grid.regions.enumerated() {
                guard budget > 0, !stopped, !deadline.expired else { break }
                let inset = max(4, min(region.rect.width, region.rect.height) * 0.15)
                let inner = region.rect.insetBy(dx: inset, dy: inset)
                guard inner.width >= 4, inner.height >= 4 else { continue }
                let mine = byRegion[index] ?? []
                let boxes = mine.map { words[$0].box.insetBy(dx: -3, dy: -3) }
                let total = raster.ink(in: inner)
                let unread = mine.isEmpty ? total : raster.ink(in: inner, excluding: boxes)
                let worth = mine.isEmpty ? unread >= 15 : unread >= max(150, total / 6)
                guard worth else { continue }
                budget -= 1
                try Task.checkCancellation()
                // Вырезается ячейка целиком, с рамкой: краска считается без
                // неё, а вот Vision одиночную цифру без рамки вокруг не
                // видит — замер на расчёте КП: с рамкой «1» и «3» читаются,
                // с отступом в две точки внутрь — нет.
                // Одиночную цифру Vision читает капризно: одной ячейке нужно
                // увеличение вдвое с узкими полями, другой — втрое с широкими,
                // третьей — вырезка по самой краске. Замер на трёх КП: ни один
                // вариант не берёт все количества, очередь из трёх — берёт.
                // Ячейку, где слова уже есть, хватает перечитать один раз.
                // Попытка: что вырезать, откуда (обычная картинка или
                // детальная), во сколько увеличить и какие поля дать.
                var attempts: [(rect: CGRect, detail: Bool, scale: CGFloat, padding: CGFloat)] = [
                    (region.rect, false, 3, 20),
                ]
                let ink = raster.inkBounds(in: inner)
                if mine.isEmpty {
                    attempts = [(region.rect, false, 2, 10), (region.rect, false, 3, 20)]
                    // Вокруг самой краски — с запасом за край ячейки: в узкой
                    // высокой ячейке «№» одиночная «1», вырезанная по ячейке,
                    // не читалась ни в каком увеличении, а с запасом читается
                    // почти в любом. Чужое, попавшее в запас, отбрасывается
                    // ниже — остаётся только то, что стоит в самой ячейке.
                    if let ink { attempts.append((ink.insetBy(dx: -30, dy: -30), false, 3, 20)) }
                }
                // Детальная картинка — последней: тонкая цифра, потерянная при
                // уменьшении страницы, на ней цела.
                // Какая вырезка подойдёт, у каждой ячейки своё: у «Прайм Групп»
                // «1» читается в тесной вырезке по ячейке, у «ТС Интеграция» —
                // только с запасом за край. Очередь кончается на первом
                // прочитанном, так что лишние попытки стоят только там, где
                // предыдущие не прочли ничего.
                if detailed != nil {
                    if mine.isEmpty, let ink {
                        let tight = ink.insetBy(dx: -15, dy: -15).intersection(region.rect)
                        let around = ink.insetBy(dx: -30, dy: -30)
                        attempts += [(tight, true, 1, 10), (tight, true, 1.5, 10),
                                     (around, true, 1.5, 20), (around, true, 1, 40)]
                    }
                    attempts.append((region.rect, true, 1, 20))
                }
                var fresh: [TableGeometry.Word] = []
                let before = mine.reduce(0) { $0 + words[$1].text.count }
                for attempt in attempts where fresh.reduce(0, { $0 + $1.text.count }) <= before {
                    let source = attempt.detail ? detailed ?? image : image
                    do {
                        fresh = try await reread(
                            attempt.rect, of: source, factor: CGFloat(source.width) / CGFloat(image.width),
                            languages: languages, deadline: deadline, scale: attempt.scale, padding: attempt.padding
                        )
                        .filter { region.rect.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        stopped = true
                        break
                    }
                }
                guard fresh.reduce(0, { $0 + $1.text.count }) > before else { continue }
                replaced.formUnion(mine)
                added += fresh
            }
            words = words.enumerated().filter { !replaced.contains($0.offset) }.map(\.element) + added
        }
        return words
    }

    /// Кусок картинки — отдельно, крупнее и с полями.
    static func reread(
        _ rect: CGRect, of image: CGImage, factor: CGFloat = 1, languages: [String], deadline: PageDeadline,
        scale: CGFloat = 3, padding: CGFloat = 20
    ) async throws -> [TableGeometry.Word] {
        // `rect` — в точках обычной картинки; `factor` — во сколько раз
        // источник детальнее. `cropping` считает от верхнего края, рамки —
        // от нижнего.
        let source = CGRect(x: rect.minX * factor, y: rect.minY * factor,
                            width: rect.width * factor, height: rect.height * factor)
        let crop = CGRect(x: source.minX, y: CGFloat(image.height) - source.maxY,
                          width: source.width, height: source.height).integral
        guard let piece = image.cropping(to: crop) else { return [] }
        let width = Int(CGFloat(piece.width) * scale + padding * 2)
        let height = Int(CGFloat(piece.height) * scale + padding * 2)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return [] }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(piece, in: CGRect(
            x: padding, y: padding, width: CGFloat(piece.width) * scale, height: CGFloat(piece.height) * scale
        ))
        guard let enlarged = context.makeImage() else { return [] }
        // Без языковой поправки: одиночная цифра — не слово, и словарь
        // её «поправляет» в букву.
        let seen = try await observe(enlarged, languages: languages, deadline: deadline, correction: false)
        let origin = CGPoint(x: crop.minX, y: CGFloat(image.height) - crop.maxY)
        return seen.words.map { word in
            TableGeometry.Word(box: CGRect(
                x: (origin.x + (word.box.minX - padding) / scale) / factor,
                y: (origin.y + (word.box.minY - padding) / scale) / factor,
                width: word.box.width / scale / factor, height: word.box.height / scale / factor
            ), text: word.text)
        }
    }

    /// Картинка в оттенках серого — для поиска рамки и «чернил».
    struct Raster {
        let width: Int
        let height: Int
        /// Строка 0 — верхняя.
        let pixels: [UInt8]

        /// Темнее этого — краска.
        static let inkLevel: UInt8 = 140

        init?(_ image: CGImage) {
            let width = image.width, height = image.height
            self.width = width
            self.height = height
            guard width > 0, height > 0 else { return nil }
            var buffer = [UInt8](repeating: 255, count: width * height)
            let drawn = buffer.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(
                    data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            pixels = buffer
        }

        private func ink(_ x: Int, _ row: Int) -> Bool { pixels[row * width + x] < Self.inkLevel }

        /// Сколько точек краски внутри прямоугольника (координаты — от
        /// нижнего края, как у рамок слов).
        func ink(in rect: CGRect) -> Int { ink(in: rect, excluding: []) }

        /// Прямоугольник, охватывающий краску внутри данного.
        func inkBounds(in rect: CGRect) -> CGRect? {
            let left = max(0, Int(rect.minX)), right = min(width, Int(rect.maxX))
            let top = max(0, height - Int(rect.maxY)), bottom = min(height, height - Int(rect.minY))
            guard left < right, top < bottom else { return nil }
            var minX = Int.max, maxX = -1, minRow = Int.max, maxRow = -1
            for row in top..<bottom {
                for x in left..<right where ink(x, row) {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minRow = min(minRow, row); maxRow = max(maxRow, row)
                }
            }
            guard maxX >= 0 else { return nil }
            return CGRect(x: minX, y: height - maxRow - 1, width: maxX - minX + 1, height: maxRow - minRow + 1)
        }

        /// То же, не считая точек внутри данных прямоугольников.
        func ink(in rect: CGRect, excluding boxes: [CGRect]) -> Int {
            // Только рамки, задевающие прямоугольник: остальные точку
            // не накроют, а проверять их на каждой точке — лишняя работа.
            let boxes = boxes.filter { $0.intersects(rect) }
            let left = max(0, Int(rect.minX)), right = min(width, Int(rect.maxX))
            let top = max(0, height - Int(rect.maxY)), bottom = min(height, height - Int(rect.minY))
            guard left < right, top < bottom else { return 0 }
            var count = 0
            for row in top..<bottom {
                let y = CGFloat(height - row) - 0.5
                for x in left..<right where ink(x, row) {
                    let point = CGPoint(x: CGFloat(x) + 0.5, y: y)
                    if boxes.contains(where: { $0.contains(point) }) { continue }
                    count += 1
                }
            }
            return count
        }

        /// Линии рамки — длинные отрезки краски.
        ///
        /// Горизонталь — сплошной отрезок длиннее, чем бывает штрих буквы.
        /// Склеивать её из кусков нельзя: верхние штрихи букв одной строки
        /// («т», «п», «Т») стоят ближе, чем разрыв линии скана, и через
        /// строку текста прошла бы ложная линия.
        ///
        /// Вертикаль — в два шага. Линия скана рваная, и вертикаль строки
        /// высотой в 50 точек приходит кусками по 10–15, каждый короче
        /// порога. Куски на одной прямой склеиваются через разрывы, и только
        /// потом короткое отбрасывается — всё, что короче двух строк текста.
        /// Палочки букв соседних строк не склеиваются: между строками
        /// разрыв больше.
        func rulings() -> TableLattice.Rulings {
            let horizontalRun = Double(max(30, min(width, height) / 40))
            let verticalRun = Double(max(18, min(width, height) / 70))
            let piece = 6
            let gap = 2
            var horizontal: [TableLattice.Segment] = []
            var vertical: [TableLattice.Segment] = []
            for row in 0..<height {
                var start: Int?
                var last = 0
                for x in 0...width {
                    if x < width, ink(x, row) {
                        if start == nil { start = x }
                        last = x
                    } else if let begin = start, x - last > gap || x == width {
                        if Double(last - begin + 1) >= horizontalRun {
                            horizontal.append(.init(position: Double(height - row), from: Double(begin), to: Double(last + 1)))
                        }
                        start = nil
                    }
                }
            }
            for x in 0..<width {
                var start: Int?
                var last = 0
                for row in 0...height {
                    if row < height, ink(x, row) {
                        if start == nil { start = row }
                        last = row
                    } else if let begin = start, row - last > gap || row == height {
                        if last - begin + 1 >= piece {
                            vertical.append(.init(
                                position: Double(x), from: Double(height - last - 1), to: Double(height - begin)
                            ))
                        }
                        start = nil
                    }
                }
            }
            return TableLattice.Rulings(
                horizontal: horizontal,
                vertical: TableLattice.merged(vertical, tolerance: 2, gap: 3)
                    .filter { $0.to - $0.from >= verticalRun }
            )
        }
    }
}
