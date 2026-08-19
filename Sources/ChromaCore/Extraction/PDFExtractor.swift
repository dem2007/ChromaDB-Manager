import Foundation
import PDFKit
import UniformTypeIdentifiers

/// PDF through PDFKit.
///
/// Page by page: the whole text of a document is never assembled twice, and the
/// page boundaries collected on the way are what let a chunk say which page it
/// came from.
public struct PDFExtractor: DocumentTextExtractor {
    public let id = "pdfkit"
    /// 6 — рост знака считается по буквам, а не по отточию оглавления
    ///: страница с точками-заполнителями рассыпалась на слоги и
    /// уходила в базу markdown-таблицей из них. Текст меняется —
    /// обязано предложить перечитать файлы.
    ///
    /// 5 — знаки препинания возвращены в свою строку таблицы:
    /// «31 585 738,00» приходило как «31 585 738 00», а номер позиции
    /// «11.1» — как «11 1». Меняется сам текст, значит обязано
    /// предложить перечитать файлы.
    ///
    /// 4 — адреса ссылок доходят до метаданных чанка: раньше они
    /// терялись целиком, потому что живут аннотациями, а не текстом.
    ///
    /// 3 — таблицы собираются по координатам знаков: строки и колонки
    /// возвращаются на место, страница с таблицей не сшивается в абзацы,
    /// и появляется `has_tables`.
    ///
    /// 2 — сшивка строк в абзацы меняет сам текст, а не только
    /// оговорки к нему: обязано предложить перечитать файлы.
    public let version = 6

    /// Below this many characters per page on average, a PDF is a picture of
    /// text rather than an empty document — the distinction decides whether the
    /// user is told «turn on OCR» or «there is nothing here».
    public static let scanCharactersPerPage = 20

    /// Порог «почти пустого слоя» применяется только к многостраничным
    /// документам.
    ///
    /// Одностраничный PDF с одной строкой — расписка, справка, титул — это
    /// нормальный короткий документ, и отправлять его в «требуют решения»
    /// значило бы терять текст, который есть. А вот три страницы, на которых
    /// всего три знака, никто как текст не набирал.
    public static let minimumPagesForScanCheck = 2

    public init() {}

    public func canHandle(_ type: UTType) -> Bool { type.conforms(to: .pdf) }

    /// Opens a locked document with the password the user gave, if there is one.
    ///
    /// Three outcomes, and they are deliberately three: no password to try is
    /// «дайте пароль», a password that fails is «этот пароль не подошёл», and
    /// the file that was never locked needs nothing. One error for the first two
    /// would send the user back to a dialog to retype what they already typed.
    static func unlockIfNeeded(_ document: PDFDocument, password: String?) throws {
        guard document.isLocked else { return }
        guard let password, !password.isEmpty else { throw ExtractionError.passwordProtected }
        guard document.unlock(withPassword: password) else { throw ExtractionError.wrongPassword }
    }

    public func extract(from url: URL, options: ExtractionOptions) async throws -> ExtractedDocument {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size <= options.maxFileSize else {
            throw ExtractionError.tooLarge(size: size, limit: options.maxFileSize)
        }
        guard let document = PDFDocument(url: url) else {
            throw ExtractionError.corrupted(String(localized: "PDF не открывается"))
        }
        // Checked before any attempt to read, as requires: asking PDFKit
        // for the text of a locked document returns nothing, which would be
        // reported as «no text layer» and send the user looking for OCR.
        try Self.unlockIfNeeded(document, password: options.password)

        // Страницы собираются в массив, а не приклеиваются к строке сразу:
        // судьбу дефиса на конце строки решает словарь **всего** документа
        //, а он не построится, пока не прочитаны все страницы.
        var raw: [String] = []
        /// Страницы, собранные по координатам знаков: таблица на них
        /// уже разобрана, и ни сшивать абзацы, ни доверять порядку строк
        /// от PDFKit на них не нужно.
        var tables: [Int: String] = [:]
        /// Страницы, где таблица была, а собрать её не вышло.
        var unassembled = 0
        raw.reserveCapacity(document.pageCount)
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let page = document.page(at: index)
            raw.append((page?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            guard let page else { continue }
            let assessed = PDFPageTables.assess(page)
            if let table = assessed.text { tables[index] = table }
            if assessed.unassembledTable { unassembled += 1 }
        }

        let vocabulary = PDFTextReflow.vocabulary(ofPages: raw)
        var text = ""
        var pageStarts: [Int] = []
        var pages: [String] = []
        // Счётчик вместо `text.count`: у строки это не поле, а обход, и на
        // 451-страничном файле пересчёт на каждой странице стоил 1.52 с
        // против 0.007 с со счётчиком.
        var length = 0
        for (index, page) in raw.enumerated() {
            // На табличной странице сшивать нечего: строка там — строка
            // таблицы, и склеить её со следующей значило бы смешать две записи.
            let reflowed = tables[index] ?? PDFTextReflow.page(page, vocabulary: vocabulary)
            pages.append(reflowed)
            guard !reflowed.isEmpty else {
                // An empty page still gets an offset, or every page after it
                // would be numbered one too low.
                pageStarts.append(length)
                continue
            }
            if length > 0 {
                text += "\n\n"
                length += 2
            }
            // **After** the separator, not before: the offset has to be where
            // this page's text actually begins. Recorded a line earlier, it
            // pointed at the tail of the previous page — which put the last two
            // characters of every page onto the next one, and made the first
            // line of a Keynote slide come out as the end of the slide before.
            pageStarts.append(length)
            text += reflowed
            length += reflowed.count
        }

        // Знаков на страницу — до `sanitized`, а не после.
        //
        // Раньше эта величина считалась только внутри `guard`, куда попадали
        // лишь документы с **нулевым** текстом, и потому она всегда равнялась
        // нулю: порог не работал ни разу. Скан с колонтитулом-номером страницы
        // (замер: 2 файла из 400, один из них — 3 страницы по одному знаку)
        // проходил проверку и уходил в базу горстью цифр, а OCR никто
        // не предлагал.
        let perPage = document.pageCount > 0 ? length / document.pageCount : 0
        let looksLikeScan = document.pageCount >= Self.minimumPagesForScanCheck
            && perPage < Self.scanCharactersPerPage

        // Only trimmed page text is appended, and nothing is appended for an
        // empty page, so `text` never starts with whitespace — `sanitized` can
        // only trim the tail, and the page offsets collected above stay valid.
        guard let plainText = PlainTextExtractor.sanitized(text), !looksLikeScan else {
            throw ExtractionError.noTextLayer(
                looksLikeScan: document.pageCount > 0 && perPage < Self.scanCharactersPerPage
            )
        }

        let (structure, source) = outline(
            of: document, pages: pages, pageStarts: pageStarts
        )

        var warnings: [ExtractionWarning] = []
        switch source {
        case .outline: break
        case .heuristic: warnings.append(.structureIsHeuristic)
        default: warnings.append(.noStructure)
        }

        if !tables.isEmpty { warnings.append(.tablesFlattened) }
        // Отдельная оговорка, и она о другом: не «оформление
        // потеряно», а «колонки не разделены». По такой странице нельзя
        // сказать, где цена, а где итог, — и агент, считающий по ней смету,
        // должен знать это до того, как посчитает.
        if unassembled > 0 { warnings.append(.tablesNotAssembled(pages: unassembled)) }

        return ExtractedDocument(
            plainText: plainText,
            structure: structure,
            pageCount: document.pageCount,
            pageStarts: pageStarts,
            links: Self.links(of: document, pages: pages, pageStarts: pageStarts),
            warnings: warnings,
            structureSource: source,
            containerFormat: "pdf",
            extractorID: id,
            extractorVersion: version,
            hasTables: !tables.isEmpty,
            documentMetadata: options.includeDocumentMetadata ? metadata(of: document) : [:]
        )
    }

    // MARK: - Structure

    /// The table of contents, where the document has one.
    ///
    /// A real outline gives both the title and the page. Раньше заголовок
    /// и вставал в **начало** этой страницы — на том основании, что цель
    /// в PDF указывает на страницу, а не на смещение. Но заголовков
    /// на странице бывает несколько, и тогда все они получали один и тот же
    /// offset: `heading_path` для текста, стоящего **выше** второго заголовка,
    /// называл второй заголовок.
    ///
    /// Поэтому заголовок ищется в тексте своей страницы по названию, а начало
    /// страницы остаётся запасным ответом — для случая, когда в тексте его
    /// нет (шрифтовая надпись, картинка, другая формулировка в оглавлении).
    private func outline(
        of document: PDFDocument,
        pages: [String],
        pageStarts: [Int]
    ) -> ([DocumentNode], StructureSource) {
        guard let root = document.outlineRoot, root.numberOfChildren > 0 else {
            return ([], .none)
        }

        var nodes: [(node: DocumentNode, order: Int)] = []
        var order = 0
        func walk(_ item: PDFOutline, level: Int) {
            for index in 0..<item.numberOfChildren {
                guard let child = item.child(at: index) else { continue }
                let title = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty,
                   let page = child.destination?.page,
                   let pageIndex = document.index(for: page) as Int?,
                   pageIndex >= 0, pageIndex < pageStarts.count {
                    nodes.append((DocumentNode(
                        level: level,
                        title: title,
                        start: pageStarts[pageIndex] + offset(of: title, in: pages[safe: pageIndex]),
                        pageNumber: pageIndex + 1
                    ), order))
                    order += 1
                }
                walk(child, level: level + 1)
            }
        }
        walk(root, level: 1)

        guard !nodes.isEmpty else { return ([], .none) }
        // Порядок обхода — вторым ключом, а не только `level`: сортировка
        // в Swift **не устойчива**, и два заголовка с одинаковым смещением
        // могли поменяться местами, то есть потерять порядок документа.
        let sorted = nodes.sorted {
            ($0.node.start, $0.node.level, $0.order) < ($1.node.start, $1.node.level, $1.order)
        }
        return (sorted.map(\.node), .outline)
    }

    /// Где на странице стоит заголовок. 0 — не нашёлся, значит начало страницы.
    private func offset(of title: String, in page: String?) -> Int {
        guard let page, !page.isEmpty else { return 0 }
        guard let range = page.range(
            of: title, options: [.caseInsensitive, .diacriticInsensitive]
        ) else { return 0 }
        return page.distance(from: page.startIndex, to: range.lowerBound)
    }

    // MARK: - Ссылки

    /// Адреса, на которые ссылается документ, с их местом в тексте.
    ///
    /// **Две трудности, и обе настоящие.**
    ///
    /// Первая: в PDF ссылка — не текст, а аннотация с прямоугольником
    /// на странице, и `page.string` о ней не знает ничего. Переводит
    /// прямоугольник в место в тексте `characterIndex(at:)`.
    ///
    /// Вторая: место это — в **исходном** тексте страницы, а в документ
    /// уходит сшитый, и смещения у них разные. Перевод делается
    /// по счёту букв и цифр: сшивка меняет пробелы, переводы строк и дефисы
    /// переноса, а буквы и цифры оставляет все и в том же порядке — это
    /// не предположение, а то, что проверяет живой тест на 721 странице.
    ///
    /// На **табличной** странице текст собран не сшивкой, а заново
    /// по координатам знаков, и порядок там строится построчно по таблице —
    /// счёт букв на ней точен не всегда. Живой замер общей точности: 97%
    /// на 4133 ссылках, и табличные страницы в это число входят.
    ///
    /// **Почему не `characterIndex(at:)`, которым это делается в одну строку.**
    /// Он отвечает про точку, а прямоугольник ссылки шире подписи и обычно
    /// накрывает пустоту вокруг букв. Замер: на 337 ссылках он попал в подпись
    /// **шесть раз**, а в остальных вернул `Int.max` — не `-1`, как ждёшь
    /// от «не нашлось», отчего проверка на отрицательное значение его
    /// и пропускала. Обход прямоугольников знаков попадает на тех же файлах
    /// в подпись почти всегда.
    static func links(
        of document: PDFDocument, pages: [String], pageStarts: [Int]
    ) -> [DocumentLink] {
        var result: [DocumentLink] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index),
                  index < pages.count, index < pageStarts.count else { continue }
            let original = page.string ?? ""
            guard !original.isEmpty else { continue }

            let annotations = page.annotations.compactMap { annotation -> (CGRect, String)? in
                guard let action = annotation.action as? PDFActionURL, let url = action.url
                else { return nil }
                return (annotation.bounds, url.absoluteString)
            }
            guard !annotations.isEmpty else { continue }

            // Один проход по знакам страницы на все её ссылки сразу: страниц
            // со ссылками мало, а перебирать знаки заново на каждую ссылку —
            // это множить самую дорогую часть на самую частую.
            var firstCharacter = [Int?](repeating: nil, count: annotations.count)
            var remaining = annotations.count
            for character in 0..<min(page.numberOfCharacters, original.count) {
                let bounds = page.characterBounds(at: character)
                for (position, annotation) in annotations.enumerated()
                where firstCharacter[position] == nil && annotation.0.intersects(bounds) {
                    firstCharacter[position] = character
                    remaining -= 1
                }
                if remaining == 0 { break }
            }

            let map = significantOffsets(original: original, reflowed: pages[index])
            for (position, annotation) in annotations.enumerated() {
                // Ссылка, под которой не нашлось ни одного знака, — это
                // ссылка на картинке. Места в тексте у неё нет, и выдумывать
                // его нельзя: адрес достался бы чужому чанку.
                guard let character = firstCharacter[position] else { continue }
                result.append(DocumentLink(
                    url: annotation.1, start: pageStarts[index] + map(character)
                ))
            }
        }
        return result
    }

    /// Перевод смещения из исходного текста страницы в сшитый — по счёту
    /// значимых знаков.
    ///
    /// Возвращает функцию, а не таблицу: обход обоих текстов делается один
    /// раз на страницу, а спрашивают его столько раз, сколько на странице
    /// ссылок, — обычно один-два.
    static func significantOffsets(original: String, reflowed: String) -> (Int) -> Int {
        func isSignificant(_ character: Character) -> Bool {
            character.isLetter || character.isNumber
        }
        // Сколько значимых знаков стоит до каждого смещения исходного текста.
        var significantBefore: [Int] = [0]
        significantBefore.reserveCapacity(original.count + 1)
        var count = 0
        for character in original {
            if isSignificant(character) { count += 1 }
            significantBefore.append(count)
        }
        // И где в сшитом тексте начинается n-й значимый знак.
        var offsetOfSignificant: [Int] = []
        offsetOfSignificant.reserveCapacity(count + 1)
        for (offset, character) in reflowed.enumerated() where isSignificant(character) {
            offsetOfSignificant.append(offset)
        }

        return { index in
            let clamped = max(0, min(index, significantBefore.count - 1))
            let significant = significantBefore[clamped]
            guard significant < offsetOfSignificant.count else { return reflowed.count }
            return offsetOfSignificant[significant]
        }
    }

    private func metadata(of document: PDFDocument) -> [String: String] {
        var result: [String: String] = [:]
        guard let attributes = document.documentAttributes else { return result }
        if let title = attributes[PDFDocumentAttribute.titleAttribute] as? String, !title.isEmpty {
            result["document_title"] = title
        }
        if let author = attributes[PDFDocumentAttribute.authorAttribute] as? String, !author.isEmpty {
            result["document_author"] = author
        }
        if let created = attributes[PDFDocumentAttribute.creationDateAttribute] as? Date {
            result["document_created"] = ISO8601DateFormatter().string(from: created)
        }
        return result
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
