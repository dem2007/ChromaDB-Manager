import Foundation
import AppKit
import UniformTypeIdentifiers

/// Word, RTF and OpenDocument through `NSAttributedString`.
///
/// The system already reads all four formats; what this adds is turning what it
/// gives back — fonts, paragraph styles, text blocks — into the structure and
/// warnings the rest of the app works with.
///
/// **On the main actor**, as requires: the importers behind `.html` and
/// `.officeOpenXML` are built on WebKit and are documented as needing the main
/// thread. Measured on this macOS they also work off it,
/// but «worked once» is not a promise.
///
/// Цена этого — **не** «несколько миллисекунд на файл», как здесь было
/// написано. Разбор идёт синхронно на главном потоке, и на файле
/// в десятки мегабайт это заметное подвисание интерфейса, которого не прервёт
/// и тайм-аут: синхронный системный вызов снаружи не прерывается. Платят эту
/// цену три формата из четырёх — `.docx` с читается своей читалкой
/// и главного потока не занимает вовсе.
public struct OfficeExtractor: DocumentTextExtractor {
    public let id = "office"
    /// 3 — `.docx` читается по частям контейнера: структура берётся
    /// из стилей, а не угадывается по кеглю, появляются номера пунктов,
    /// колонтитулы и сноски. Текст меняется, поэтому версия поднята:
    /// превратит это в **предложение** переизвлечь, а не в работу.
    ///
    /// 2 — comments, footnotes and tracked changes are detected through the ZIP
    /// container (4.5) and warned about. The text does not change; the warning
    /// in the chunk metadata does, and turns that into an offer to
    /// re-extract rather than into work.
    public var version: Int { Self.currentVersion }

    /// 8 — замечания и сноски `.odt` извлекаются текстом: импортёр
    /// отдавал номер сноски и молчал про её текст, а замечание терял целиком.
    ///
    /// 7 — адрес ссылки больше не дописывается к тексту абзаца, а уходит
    /// в метаданные чанка: в векторе адрес — набор цифр, а не слова,
    /// по которым ищут.
    ///
    /// 6 — сноска встаёт при своём абзаце, а не в конце документа:
    /// между ссылкой и текстом сноски было в среднем 46% документа, и оговорка
    /// с тем, что она оговаривает, не попадали в один чанк никогда.
    ///
    /// 5 — таблицы записываются разметкой Markdown, как у книги Excel
    ///: один и тот же прайс из двух форматов даёт один и тот же текст,
    /// а шапка таблицы становится опознаваемой — её повторяет нарезка.
    ///
    /// 4 — двоичный `.doc` читается своей читалкой: колонтитулы,
    /// сноски, замечания рецензентов и надписи, которых системный импортёр
    /// не отдаёт вовсе, приходят текстом; удалённый правкой и скрытый текст
    /// в базу не идут.
    public static let currentVersion = 8

    /// A paragraph this much larger than the body is a heading.
    static let headingSizeRatio: CGFloat = 1.15
    /// Longer than this and it is a paragraph that happens to be bold, not a
    /// heading. Headings are short — that is most of what makes them headings.
    static let headingLengthLimit = 120

    public init() {}

    public func canHandle(_ type: UTType) -> Bool {
        Self.documentType(for: type) != nil
    }

    /// Which importer the system should use. Chosen by `UTType` rather than by
    /// extension, and stated explicitly rather than left to the importer to
    /// guess: `.docx` renamed to `.doc` is still a `.docx`.
    static func documentType(for type: UTType) -> NSAttributedString.DocumentType? {
        if type.conforms(to: UTType("org.openxmlformats.wordprocessingml.document") ?? .data) {
            return .officeOpenXML
        }
        if type.conforms(to: UTType("org.oasis-open.opendocument.text") ?? .data) {
            return .openDocument
        }
        if type.conforms(to: .rtf) || type.conforms(to: .rtfd) { return .rtf }
        if type.conforms(to: UTType("com.microsoft.word.doc") ?? .data) { return .docFormat }
        return nil
    }

    public func extract(from url: URL, options: ExtractionOptions) async throws -> ExtractedDocument {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size <= options.maxFileSize else {
            throw ExtractionError.tooLarge(size: size, limit: options.maxFileSize)
        }
        guard let type = ExtractorRegistry.type(of: url), let documentType = Self.documentType(for: type) else {
            throw ExtractionError.unsupportedFormat(url.pathExtension)
        }

        // Своя читалка частей — для `.docx` и для двоичного `.doc`
        //. Форматы разные до последнего байта, а сборка дальше одна:
        // иначе документ, сохранённый в двух форматах, дал бы разные чанки.
        //
        // **Выбирает содержимое, а не имя**. Читалка `.docx` требует
        // внутри `word/document.xml`, читалка `.doc` — подписи OLE2 и годного
        // заголовка FIB; ни одна не притворится, что поняла чужой файл.
        // Раньше обе включались по расширению, и документ Word 97, названный
        // `.docx`, не читался вовсе — при том, что читалка для него есть.
        if let reader = DocxPartsReader(url: url), let parts = reader.read(),
           let native = try? Self.assemble(parts, url: url, type: type, options: options) {
            return native
        }
        if let reader = DocPartsReader(url: url), let parts = reader.read(),
           let native = try? Self.assemble(parts, url: url, type: type, options: options) {
            return native
        }

        let parsed = try await Self.parse(url: url, documentType: documentType)
        let paragraphs = Self.paragraphs(of: parsed.text)
        var body = Self.render(paragraphs)
        // Замечания и сноски OpenDocument импортёр не отдаёт: тело документа
        // он собирает, а текст сноски и текст замечания теряет.
        // Берём их из `content.xml` и дописываем тем же видом, что у Word.
        let extras = documentType == .openDocument ? ODTPartsReader(url: url)?.read() : nil
        if let extras { body += Self.rendered(extras) }
        guard let plainText = PlainTextExtractor.sanitized(body) else {
            throw ExtractionError.empty
        }

        let (structure, source) = Self.structure(of: paragraphs, in: plainText)
        var warnings: [ExtractionWarning] = []
        switch source {
        case .heuristic: warnings.append(.structureIsHeuristic)
        default: warnings.append(.noStructure)
        }
        let hasTables = paragraphs.contains { $0.table != nil }
        if hasTables { warnings.append(.tablesFlattened) }
        // Only the two ZIP-based formats: `.rtf` and `.doc` are not containers,
        // and there is nowhere in them to look.
        let isContainer = documentType == .officeOpenXML || documentType == .openDocument
        if documentType == .openDocument {
            // Оговорка ставится только там, где она правда: если замечания
            // и сноски извлечены, говорить «не извлечены» значит врать
            // о самом приложении.
            if extras == nil, Self.containsCommentsOrRevisions(at: url) {
                warnings.append(.commentsSkipped)
            }
            if extras?.hasRevisions == true {
                warnings.append(.other(String(localized: "в документе есть правки: индексируется финальная редакция, удалённый текст в базу не идёт")))
            }
        } else if isContainer {
            if Self.containsCommentsOrRevisions(at: url) { warnings.append(.commentsSkipped) }
        } else if documentType == .docFormat, let reader = DocPartsReader(url: url) {
            // Не контейнер — но заглянуть всё-таки есть куда: заголовок
            // FIB отвечает точно, что в файле лежит и сколько там знаков.
            warnings.append(contentsOf: Self.inventory(reader.inventory()))
        } else {
            // У `.doc` и `.rtf` заглянуть внутрь нечем — и это не то же самое,
            // что «комментариев и правок нет». Проверенный файл
            // с правками в названии прошёл без единой оговорки, и человек имел
            // все основания счесть, что их там нет.
            //
            // Это не нарушает правило «не предупреждать обо всём подряд»,
            // из-за которого у контейнеров стоит проверка, а не безусловная
            // оговорка: здесь говорится не про этот документ, а про то, чего
            // **не проверяли**, и только у двух форматов из четырёх.
            warnings.append(.other(String(localized: "формат \(type.preferredFilenameExtension ?? "doc") не контейнер: правки, комментарии и сноски в нём не проверялись")))
        }

        return ExtractedDocument(
            plainText: plainText,
            structure: structure,
            warnings: warnings,
            structureSource: source,
            containerFormat: type.preferredFilenameExtension ?? url.pathExtension.lowercased(),
            extractorID: id,
            extractorVersion: version,
            hasTables: hasTables,
            documentMetadata: options.includeDocumentMetadata ? parsed.metadata : [:]
        )
    }

    // MARK: - Свой разбор `.docx`

    /// Части контейнера → документ, каким его увидит нарезка.
    static func assemble(
        _ parts: DocxPartsReader.Document, url: URL, type: UTType, options: ExtractionOptions
    ) throws -> ExtractedDocument {
        let paragraphs = parts.paragraphs.filter { !$0.isHidden }
        let body = bodySize(of: paragraphs)

        var lines: [String] = []
        var offsets: [Int] = []
        var length = 0
        /// Заголовки по стилю и по начертанию собираются в один проход,
        /// а выбор между ними делается после: сопоставлять потом абзацы
        /// со строками нельзя — таблица из двадцати абзацев даёт одну строку.
        var byStyle: [DocumentNode] = []
        var byLook: [DocumentNode] = []

        func add(_ line: String) {
            guard !line.isEmpty else { return }
            offsets.append(length)
            lines.append(line)
            length += line.count + separator.count
        }


        // Колонтитул — впереди текста: гриф «ДСП» живёт именно там, и место
        // ему в первом же чанке, а не нигде.
        for header in parts.headers { add(String(localized: "Колонтитул: \(header)")) }

        // Сноска встаёт **при своём абзаце**, а не в конце документа.
        //
        // Раньше все сноски приписывались в хвост. Замер на 250 документах:
        // между ссылкой на сноску и её текстом оказывалось в среднем 46%
        // документа — то есть чанк с условием и чанк с самим условием
        // не встречались никогда. А в сносках делопроизводственных документов
        // лежит не библиография, а существенное: «категория сервиса понижается
        // до 4, если неисправность не влечёт сбой», «по требованию Заказчика
        // количество специалистов может быть скорректировано». Оговорка,
        // отрезанная от того, что она оговаривает, меняет смысл обоих кусков.
        //
        // Отдельной строкой, но **внутри блока** абзаца: блоки разделяются
        // пустой строкой, и сноска, ставшая своим блоком, уехала бы
        // от абзаца при первой же нарезке — а нижняя граница размера
        // приклеила бы её к следующему абзацу, то есть не к тому.
        // Адреса — с местом абзаца, в котором стоит ссылка.
        var links: [DocumentLink] = []
        func collectLinks(of paragraph: DocxPartsReader.Paragraph, at start: Int) {
            for link in paragraph.links where isExternal(link) {
                links.append(DocumentLink(url: link, start: start))
            }
        }

        var placed: Set<String> = []
        func notes(of paragraph: DocxPartsReader.Paragraph) -> [String] {
            paragraph.footnotes.compactMap { id in
                guard let text = parts.footnotes[id], placed.insert(id).inserted else { return nil }
                return String(localized: "Сноска \(id): \(text)")
            }
        }

        var index = 0
        while index < paragraphs.count {
            let paragraph = paragraphs[index]
            guard let cell = paragraph.cell else {
                let start = length
                add(([decorated(paragraph)] + notes(of: paragraph)).joined(separator: "\n"))
                collectLinks(of: paragraph, at: start)
                if let level = paragraph.headingLevel {
                    byStyle.append(DocumentNode(level: level, title: paragraph.rendered, start: start))
                } else if let guess = looksLikeHeading(paragraph, body: body) {
                    byLook.append(DocumentNode(level: guess, title: paragraph.rendered, start: start))
                }
                index += 1
                continue
            }
            // Таблица целиком: её строки идут подряд и разделяются переводом
            // строки, а не пустой строкой, — иначе нарезка по абзацам рвёт
            // таблицу на куски.
            var cells: [(row: Int, column: Int, text: String, continuation: Bool)] = []
            // Сноска из ячейки — **после** таблицы, а не в ячейке: строкой
            // внутри ячейки она сломала бы разметку Markdown, по которой
            // таблица и читается.
            var tableNotes: [String] = []
            let tableStart = length
            while index < paragraphs.count, let current = paragraphs[index].cell, current.table == cell.table {
                cells.append((current.row, current.column, decorated(paragraphs[index]), current.isVerticalContinuation))
                tableNotes += notes(of: paragraphs[index])
                // Ссылка из ячейки принадлежит таблице: точнее места у неё
                // нет — таблица собирается в одну строку текста.
                collectLinks(of: paragraphs[index], at: tableStart)
                index += 1
            }
            add(([renderTable(cells)] + tableNotes).joined(separator: "\n"))
        }

        // Сноска, ссылки на которую в тексте не нашлось, — всё равно текст,
        // написанный человеком, и терять его нельзя. Такая идёт в конец,
        // как шли раньше все.
        for (id, text) in parts.footnotes
            .filter({ !placed.contains($0.key) })
            .sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
            add(String(localized: "Сноска \(id): \(text)"))
        }
        // Замечание рецензента — такой же написанный человеком текст, как
        // сноска: «уточнить срок поставки» ищут теми же словами.
        // Автор в подписи: у замечания он есть, и по нему их и разбирают.
        for comment in parts.comments {
            add(comment.author.isEmpty
                ? String(localized: "Комментарий: \(comment.text)")
                : String(localized: "Комментарий (\(comment.author)): \(comment.text)"))
        }
        for footer in parts.footers { add(String(localized: "Нижний колонтитул: \(footer)")) }

        guard let plainText = PlainTextExtractor.sanitized(lines.joined(separator: separator)) else {
            throw ExtractionError.empty
        }

        // Документ, где заголовки только жирные, — плоский: второй уровень
        // без первого сбивает и путь заголовков, и иерархическую нарезку.
        if !byLook.contains(where: { $0.level == 1 }) {
            byLook = byLook.map { DocumentNode(level: 1, title: $0.title, start: $0.start) }
        }
        // Размеченное стилями главнее догадки, и они не смешиваются: половина
        // разметки от автора, половина от кегля — это не структура, а каша.
        let structure = byStyle.isEmpty ? byLook : byStyle
        let source: StructureSource = byStyle.isEmpty ? (byLook.isEmpty ? .none : .heuristic) : .headings

        var warnings: [ExtractionWarning] = []
        switch source {
        case .heuristic: warnings.append(.structureIsHeuristic)
        case .headings: break
        default: warnings.append(.noStructure)
        }
        if parts.hasTables { warnings.append(.tablesFlattened) }
        // Не общее «ничего не извлекается»: сноски и комментарии
        // теперь извлекаются, и прежняя оговорка стала неправдой о самом
        // приложении. Говорится ровно то, что есть.
        if parts.hasRevisions {
            warnings.append(.other(String(localized: "в документе есть правки: индексируется финальная редакция, удалённый текст в базу не идёт")))
        }
        if parts.commentsUnreadable { warnings.append(.commentsSkipped) }
        if parts.hiddenParagraphs > 0 {
            warnings.append(.other(String(localized: "пропущено скрытых абзацев: \(parts.hiddenParagraphs.plainDigits) — Word их не показывает и не печатает")))
        }

        return ExtractedDocument(
            plainText: plainText,
            structure: structure,
            links: links,
            warnings: warnings,
            structureSource: source,
            containerFormat: type.preferredFilenameExtension ?? url.pathExtension.lowercased(),
            extractorID: "office",
            extractorVersion: currentVersion,
            hasTables: parts.hasTables
        )
    }

    /// Абзацы разделяются пустой строкой — так их видит нарезка по абзацам.
    static let separator = "\n\n"

    /// Кегль, которым набрано больше всего текста.
    static func bodySize(of paragraphs: [DocxPartsReader.Paragraph]) -> Double {
        var weight: [Double: Int] = [:]
        for paragraph in paragraphs where paragraph.cell == nil {
            guard let size = paragraph.size else { continue }
            weight[size, default: 0] += paragraph.text.count
        }
        return weight.max { $0.value < $1.value }?.key ?? 0
    }

    /// Догадка по начертанию — для документов, не размеченных стилями вовсе.
    /// Из трёх проверенных настоящих файлов стили были только в одном.
    static func looksLikeHeading(_ paragraph: DocxPartsReader.Paragraph, body: Double) -> Int? {
        guard paragraph.cell == nil, paragraph.text.count <= headingLengthLimit else { return nil }
        let size = paragraph.size ?? body
        let larger = body > 0 && size >= body * Double(headingSizeRatio)
        if larger { return 1 }
        // Жирный абзац кегля тела — заголовок пониже рангом: документ, где есть
        // и то и другое, выглядит именно так.
        if paragraph.isBold, size >= body { return body > 0 && size > body ? 1 : 2 }
        return nil
    }

    /// Абзац с номером пункта и адресами ссылок.
    /// Текст абзаца, каким он уйдёт в документ.
    ///
    /// **Адрес ссылки сюда больше не дописывается.** Дописывался:
    /// абзац получал хвост « (https://…)». Замер на 400 PDF и 250 `.docx`
    /// объяснил, почему это неверно: адреса — почти сплошь непрозрачные
    /// редиректы вроде `internet.garant.ru/document/redirect/71886920/0`,
    /// в которых нет ни одного слова, по которому их станут искать, а в вектор
    /// они приносят набор цифр. Теперь адрес идёт в метаданные чанка
    /// (`source_urls`): человеку и агенту он доступен, вектор чист.
    static func decorated(_ paragraph: DocxPartsReader.Paragraph) -> String {
        paragraph.rendered
    }

    /// Адрес, годный в источники: ссылки внутрь документа (`#закладка`)
    /// и на файлы рядом источником не являются.
    static func isExternal(_ link: String) -> Bool {
        link.hasPrefix("http") || link.hasPrefix("mailto:")
    }

    /// Строки таблицы — разметкой Markdown, как у книги Excel.
    ///
    /// Ячейка из нескольких абзацев остаётся **одной** ячейкой — раньше её
    /// абзацы вставали соседними колонками, и таблица из двух колонок читалась
    /// как таблица из трёх. Объединённая вниз ячейка повторяет значение
    /// верхней: значение относится ко всем строкам диапазона.
    static func renderTable(_ cells: [(row: Int, column: Int, text: String, continuation: Bool)]) -> String {
        var byPosition: [Int: [Int: [String]]] = [:]
        var continuations: Set<String> = []
        for cell in cells {
            byPosition[cell.row, default: [:]][cell.column, default: []].append(cell.text)
            if cell.continuation { continuations.insert("\(cell.row)\u{0}\(cell.column)") }
        }
        var carried: [Int: String] = [:]
        var rows: [[String]] = []
        // Колонки перебираются по всей ширине таблицы, а не по тем, что
        // в этой строке нашлись: пустая ячейка обязана остаться на своём
        // месте, иначе значения соседних колонок съезжают влево, и строка
        // «— — 400 м» читается как «400 м» в первой колонке.
        let width = (cells.map(\.column).max() ?? 0) + 1
        for row in byPosition.keys.sorted() {
            var line: [String] = []
            let columns = byPosition[row] ?? [:]
            for column in 0..<width {
                let joined = (columns[column] ?? []).filter { !$0.isEmpty }.joined(separator: " / ")
                // Значение сверху подставляется только там, где ячейка
                // **объединена** вниз. Пустая ячейка остаётся пустой: раньше
                // она тоже брала значение верхней, и таблица, где цену просто
                // не заполнили, приходила в базу с ценой соседней строки —
                // выдуманные данные хуже отсутствующих.
                if continuations.contains("\(row)\u{0}\(column)"), let value = carried[column], !value.isEmpty {
                    line.append(value)
                } else {
                    if !joined.isEmpty { carried[column] = joined }
                    line.append(joined)
                }
            }
            rows.append(line)
        }
        return TableText.render(rows)
    }

    // MARK: - Reading

    private struct Parsed {
        let text: NSAttributedString
        let metadata: [String: String]
    }

    @MainActor
    private static func parse(url: URL, documentType: NSAttributedString.DocumentType) throws -> Parsed {
        var attributes: NSDictionary?
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: documentType]
        do {
            let text = try NSAttributedString(url: url, options: options, documentAttributes: &attributes)
            return Parsed(text: text, metadata: metadata(from: attributes as? [String: Any] ?? [:]))
        } catch {
            // Never a silent skip: the file lands in «требуют решения»
            // with the reason the system gave.
            throw ExtractionError.corrupted(error.localizedDescription)
        }
    }

    private static func metadata(from attributes: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        if let title = attributes[NSAttributedString.DocumentAttributeKey.title.rawValue] as? String, !title.isEmpty {
            result["document_title"] = title
        }
        if let author = attributes[NSAttributedString.DocumentAttributeKey.author.rawValue] as? String, !author.isEmpty {
            result["document_author"] = author
        }
        if let created = attributes[NSAttributedString.DocumentAttributeKey.creationTime.rawValue] as? Date {
            result["document_created"] = ISO8601DateFormatter().string(from: created)
        }
        return result
    }

    // MARK: - What the importer does not show

    /// Comments, footnotes and tracked changes.
    ///
    /// `NSAttributedString` shows none of them — not as text, not as a flag —
    /// so until there was a way into the container there was nothing to warn
    /// about, and warning every office file unconditionally would have taught
    /// the user to ignore it. `.docx` and `.odt` are ZIP archives, and the parts
    /// that hold this are named by the standards.
    ///
    /// A failure to open the container is not an error here: the document was
    /// already read, and the worst case is a warning that is not shown.
    static func containsCommentsOrRevisions(at url: URL) -> Bool {
        guard let reader = try? ZIPContainerReader(url: url) else { return false }

        // Word: separate parts. Empty ones are written by some producers, so a
        // part that exists but holds nothing does not count.
        for part in ["word/comments.xml", "word/footnotes.xml", "word/endnotes.xml"] {
            if let entry = reader.entry(at: part), entry.uncompressedSize > 512 { return true }
        }
        // Tracked changes live inside the document itself, as do OpenDocument's
        // annotations — a substring is enough to notice them.
        for (part, markers) in [
            ("word/document.xml", ["<w:ins ", "<w:del ", "<w:commentRangeStart"]),
            ("content.xml", ["<office:annotation", "<text:tracked-changes", "<text:note "]),
        ] {
            guard let data = try? reader.read(part), let xml = String(data: data, encoding: .utf8) else { continue }
            if markers.contains(where: { xml.contains($0) }) { return true }
        }
        return false
    }

    /// Замечания и сноски OpenDocument — текстом, тем же видом, что у Word.
    ///
    /// В конце документа, а не при своих абзацах: тело собирает импортёр,
    /// и мест, куда вставлять, он не называет. Это осознанный предел —
    /// у `.docx`, где разбор свой, сноска стоит при своём абзаце.
    static func rendered(_ extras: ODTPartsReader.Extras) -> String {
        var lines: [String] = []
        for footnote in extras.footnotes {
            lines.append(String(localized: "Сноска \(footnote.id): \(footnote.text)"))
        }
        for comment in extras.comments {
            lines.append(comment.author.isEmpty
                ? String(localized: "Комментарий: \(comment.text)")
                : String(localized: "Комментарий (\(comment.author)): \(comment.text)"))
        }
        guard !lines.isEmpty else { return "" }
        return separator + lines.joined(separator: separator)
    }

    // MARK: - Что лежит в двоичном `.doc`

    /// Опись подпотоков → оговорки, называющие числа.
    ///
    /// Раньше здесь стояла одна фраза на весь формат — «правки, комментарии
    /// и сноски не проверялись», — и она была честной ровно настолько,
    /// насколько честно «мы не смотрели». Теперь смотрели: каждая строка ниже
    /// говорит про **этот** файл и подкреплена числом из его заголовка.
    static func inventory(_ inventory: DocPartsReader.Inventory) -> [ExtractionWarning] {
        var result: [ExtractionWarning] = []
        if inventory.comments > 0 {
            let count = RussianCount.phrase(inventory.comments, "комментарий", "комментария", "комментариев")
            let characters = RussianCount.grouped(inventory.commentCharacters, "знак", "знака", "знаков")
            result.append(.other(String(localized: "в документе есть \(count) (\(characters)) — текст не извлекается")))
        }
        if inventory.footnotes > 0 {
            let count = RussianCount.phrase(inventory.footnotes, "сноска", "сноски", "сносок")
            let characters = RussianCount.grouped(inventory.footnoteCharacters, "знак", "знака", "знаков")
            result.append(.other(String(localized: "в документе есть \(count) (\(characters)) — текст не извлекается")))
        }
        if inventory.headerCharacters > 0 {
            let characters = RussianCount.grouped(inventory.headerCharacters, "знак", "знака", "знаков")
            result.append(.other(String(localized: "в колонтитулах \(characters) — они не извлекаются, а гриф документа живёт именно там")))
        }
        if inventory.endnoteCharacters > 0 {
            let characters = RussianCount.grouped(inventory.endnoteCharacters, "знак", "знака", "знаков")
            result.append(.other(String(localized: "в концевых сносках \(characters) — они не извлекаются")))
        }
        if inventory.textboxCharacters > 0 {
            let characters = RussianCount.grouped(inventory.textboxCharacters, "знак", "знака", "знаков")
            result.append(.other(String(localized: "в надписях и врезках \(characters) — они не извлекаются")))
        }
        // Про правки заголовок не говорит ничего: они помечаются свойствами
        // знаков, а не отдельным подпотоком. Молчать об этом нельзя — на файле
        // с правками в самом названии человек имел все основания счесть,
        // что их там нет.
        result.append(.other(String(localized: "правки в этом формате не проверялись: индексируется то, что вернул системный импортёр")))
        return result
    }

    // MARK: - Paragraphs

    struct Paragraph {
        var text: String
        var size: CGFloat
        var isBold: Bool
        /// Set when the paragraph is a table cell: which table, and where in it.
        var table: (id: ObjectIdentifier, row: Int, column: Int)?
    }

    static func paragraphs(of attributed: NSAttributedString) -> [Paragraph] {
        var result: [Paragraph] = []
        let string = attributed.string as NSString
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byParagraphs]) { piece, range, _, _ in
            let text = (piece ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, range.length > 0 else { return }
            let attributes = attributed.attributes(at: range.location, effectiveRange: nil)
            let font = attributes[.font] as? NSFont
            let block = (attributes[.paragraphStyle] as? NSParagraphStyle)?
                .textBlocks.compactMap { $0 as? NSTextTableBlock }.first
            result.append(Paragraph(
                text: text,
                size: font?.pointSize ?? 12,
                isBold: font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false,
                table: block.map { (ObjectIdentifier($0.table), $0.startingRow, $0.startingColumn) }
            ))
        }
        return result
    }

    /// Paragraphs back into text, with tables flattened.
    ///
    /// Таблица оформляется разметкой Markdown — тем же видом, что у книги Excel
    /// и у Word: один и тот же прайс, сохранённый в двух форматах,
    /// обязан давать один и тот же текст. Восстановление структуры таблицы
    /// в объём по-прежнему не входит; речь только о её записи.
    static func render(_ paragraphs: [Paragraph]) -> String {
        var lines: [String] = []
        var index = 0
        while index < paragraphs.count {
            guard let table = paragraphs[index].table else {
                lines.append(paragraphs[index].text)
                index += 1
                continue
            }
            var cells: [(row: Int, column: Int, text: String)] = []
            while index < paragraphs.count, let current = paragraphs[index].table, current.id == table.id {
                cells.append((current.row, current.column, paragraphs[index].text))
                index += 1
            }
            let width = (cells.map(\.column).max() ?? 0) + 1
            var rows: [[String]] = []
            for (_, row) in Dictionary(grouping: cells, by: \.row).sorted(by: { $0.key < $1.key }) {
                var line = Array(repeating: "", count: width)
                for cell in row where cell.column < width {
                    line[cell.column] = line[cell.column].isEmpty
                        ? cell.text
                        : line[cell.column] + " / " + cell.text
                }
                rows.append(line)
            }
            // Таблица идёт одним куском: строки внутри неё разделяются переводом
            // строки, а не пустой, иначе нарезка по абзацам рвёт её на строки.
            lines.append(TableText.render(rows))
        }
        return lines.joined(separator: "\n\n")
    }

    // MARK: - Structure

    /// Headings by size and weight.
    ///
    /// The style-name branch the spec allows first is not reachable: neither the
    /// Word nor the ODT importer puts a paragraph style name into the attributes
    /// on this system — only `NSFont` and `NSParagraphStyle` come back.
    /// So the structure is always a guess, and always says so.
    static func structure(of paragraphs: [Paragraph], in text: String) -> ([DocumentNode], StructureSource) {
        let body = bodySize(of: paragraphs)
        var headings: [(paragraph: Paragraph, size: CGFloat)] = []
        for paragraph in paragraphs where paragraph.table == nil {
            guard paragraph.text.count <= headingLengthLimit else { continue }
            let larger = paragraph.size >= body * headingSizeRatio
            let emphasised = paragraph.isBold && paragraph.size >= body
            guard larger || emphasised else { continue }
            headings.append((paragraph, paragraph.size))
        }
        guard !headings.isEmpty else { return ([], .none) }

        // Bigger heading, shallower level. Bold-at-body-size sorts below every
        // enlarged heading, which is what a document that uses both looks like.
        let sizes = Array(Set(headings.map(\.size))).sorted(by: >)
        let level = Dictionary(uniqueKeysWithValues: sizes.enumerated().map { ($0.element, $0.offset + 1) })

        var nodes: [DocumentNode] = []
        var searchFrom = text.startIndex
        for heading in headings {
            guard let range = text.range(of: heading.paragraph.text, range: searchFrom..<text.endIndex) else { continue }
            nodes.append(DocumentNode(
                level: level[heading.size] ?? 1,
                title: heading.paragraph.text,
                start: text.distance(from: text.startIndex, to: range.lowerBound)
            ))
            searchFrom = range.upperBound
        }
        return nodes.isEmpty ? ([], .none) : (nodes, .heuristic)
    }

    /// The size most of the text is set in, weighted by how much text that is —
    /// a document with one huge title is still a 12-point document.
    static func bodySize(of paragraphs: [Paragraph]) -> CGFloat {
        var weight: [CGFloat: Int] = [:]
        for paragraph in paragraphs {
            weight[paragraph.size, default: 0] += paragraph.text.count
        }
        return weight.max { $0.value < $1.value }?.key ?? 12
    }
}
