import Foundation
import UniformTypeIdentifiers

/// PowerPoint `.pptx`.
///
/// **Почему свой разбор, а не системный.** `NSAttributedString` презентаций
/// не открывает, а Keynote, через который читаются `.key`, открывает `.pptx`
/// с потерями и только при включённом экспорте. Формат же открыт
/// (ECMA-376, часть 1, PresentationML) и устроен просто: ZIP, в нём
/// `ppt/presentation.xml` со списком слайдов и по XML на каждый слайд.
///
/// **Что читается.**
/// - Слайды в порядке `p:sldIdLst` — не в порядке файлов `slideN.xml`:
///   номер в имени файла — порядок создания, после перестановки слайдов он
///   с показом не совпадает.
/// - Фигуры слайда в порядке чтения: заголовок первым, остальное сверху
///   вниз и слева направо. В файле они стоят в порядке наложения, и подпись,
///   добавленная последней, оказалась бы в конце слайда.
/// - Таблицы — разметкой Markdown, как в Word и PDF.
/// - Текст SmartArt — из части данных схемы: на слайде его нет.
/// - Заголовок и ряды диаграмм — данные самой диаграммы.
/// - Заметки докладчика — в конце своего слайда: в них часто больше
///   смысла, чем в тезисах на слайде.
///
/// **Что не читается.** Номер слайда, дата и колонтитул — одинаковые на всех
/// слайдах, они только размывали бы каждый кусок; картинки и внедрённые
/// объекты — в них нет текста.
public struct PPTXExtractor: DocumentTextExtractor {
    public let id = "pptx"
    public let version = 1

    public init() {}

    public func canHandle(_ type: UTType) -> Bool {
        Self.kinds.contains { type.conforms(to: $0) }
    }

    /// Презентация и демонстрация — один формат. Тип, которого система
    /// не знает, пропускается, а не подменяется общим `.data`: тот
    /// подходит к любому файлу, и `.md` уходил бы сюда.
    static let kinds = [
        "org.openxmlformats.presentationml.presentation",
        "org.openxmlformats.presentationml.slideshow",
    ].compactMap { UTType($0) }

    public func extract(from url: URL, options: ExtractionOptions) async throws -> ExtractedDocument {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size <= options.maxFileSize else {
            throw ExtractionError.tooLarge(size: size, limit: options.maxFileSize)
        }
        let reader: ZIPContainerReader
        do {
            reader = try ZIPContainerReader(url: url)
        } catch let error as ZIPError {
            throw ExtractionError.corrupted(error.errorDescription ?? "")
        }
        // Зашифрованная презентация — это CFB-файл, а не ZIP, и до сюда
        // не доходит; ZIP без `presentation.xml` — не презентация.
        guard let presentation = Self.xml(reader, "ppt/presentation.xml") else {
            throw ExtractionError.corrupted(String(localized: "в архиве нет ppt/presentation.xml"))
        }

        let slidePaths = Self.slidePaths(presentation: presentation, reader: reader)
        guard !slidePaths.isEmpty else { throw ExtractionError.empty }

        var text = ""
        var parts: [DocumentPart] = []
        var pageStarts: [Int] = []
        var structure: [DocumentNode] = []
        var hasTables = false

        for (index, path) in slidePaths.enumerated() {
            // Номер страницы — номер слайда, и он считается по `pageStarts`:
            // у слайда без текста своё начало тоже есть — там, где начнётся
            // следующий, — иначе после пустого слайда номера страниц
            // отставали бы от номеров слайдов.
            let nextStart = text.isEmpty ? 0 : text.count + 2
            guard let slide = Self.xml(reader, path) else { pageStarts.append(nextStart); continue }
            let relations = Self.relationships(of: path, reader: reader)
            let content = Self.slideContent(slide, relations: relations, reader: reader)
            var body = content.lines.joined(separator: "\n")
            if let notesPath = relations.first(where: { $0.type.hasSuffix("/notesSlide") })?.target,
               let notes = Self.xml(reader, notesPath) {
                let noteText = Self.notesText(notes)
                if !noteText.isEmpty {
                    body += (body.isEmpty ? "" : "\n\n") + String(localized: "Заметки докладчика:") + "\n" + noteText
                }
            }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { pageStarts.append(nextStart); continue }
            if content.hasTables { hasTables = true }

            if !text.isEmpty { text += "\n\n" }
            let start = text.count
            parts.append(DocumentPart(kind: .slide, index: index, id: "slide-\(index + 1)", start: start))
            pageStarts.append(start)
            if let title = content.title ?? Self.fallbackTitle(of: content.lines) {
                structure.append(DocumentNode(level: 1, title: title, start: start, pageNumber: index + 1))
            }
            text += body
        }
        guard !text.isEmpty else { throw ExtractionError.empty }

        // Номер страницы — номер слайда: страниц у презентации нет, а место
        // куска найти надо.
        return ExtractedDocument(
            plainText: text,
            structure: structure,
            pageCount: slidePaths.count,
            pageStarts: pageStarts,
            parts: parts,
            warnings: structure.isEmpty ? [.noStructure] : [],
            structureSource: structure.isEmpty ? .none : .outline,
            containerFormat: url.pathExtension.lowercased().isEmpty ? "pptx" : url.pathExtension.lowercased(),
            extractorID: id,
            extractorVersion: version,
            hasTables: hasTables,
            documentMetadata: options.includeDocumentMetadata ? Self.metadata(reader) : [:]
        )
    }

    // MARK: - Пакет

    struct Relationship {
        var id: String
        var type: String
        /// Путь внутри архива, уже разрешённый; `nil` у внешней ссылки.
        var target: String
    }

    static func xml(_ reader: ZIPContainerReader, _ path: String) -> XMLDocument? {
        guard let data = try? reader.read(path) else { return nil }
        return try? XMLDocument(data: keepingSpaceRuns(data))
    }

    /// Прогон из одних пробелов — обычное дело: PowerPoint режет «Цифровое
    /// правосудие» на три прогона, и средний — пробел. `XMLDocument` такие
    /// текстовые узлы выбрасывает при любых опциях, и заголовок читался
    /// «Цифровоеправосудие». Пробелы в `<a:t>` заменяются неразрывными до
    /// разбора и снова становятся обычными в `paragraphs(of:)` — там же,
    /// где и неразрывные пробелы автора: нормализация текста сделала
    /// бы это и сама, но заголовков слайдов она не трогает.
    static func keepingSpaceRuns(_ data: Data) -> Data {
        let xml = String(decoding: data, as: UTF8.self)
        guard let regex = spaceRun, xml.contains("> </") || xml.contains(">  ") else { return data }
        let source = xml as NSString
        let result = NSMutableString(string: xml)
        for match in regex.matches(in: xml, range: NSRange(location: 0, length: source.length)).reversed() {
            let range = match.range(at: 1)
            result.replaceCharacters(in: range, with: String(repeating: "\u{00A0}", count: range.length))
        }
        return Data((result as String).utf8)
    }

    private static let spaceRun = try? NSRegularExpression(
        pattern: #"<(?:[A-Za-z0-9]+:)?t(?:\s[^>]*)?>([ \t]+)</(?:[A-Za-z0-9]+:)?t>"#
    )

    static func elements(_ node: XMLNode, _ xpath: String) -> [XMLElement] {
        ((try? node.nodes(forXPath: xpath)) ?? []).compactMap { $0 as? XMLElement }
    }

    /// Связи части: `ppt/slides/_rels/slide1.xml.rels` для `ppt/slides/slide1.xml`.
    static func relationships(of path: String, reader: ZIPContainerReader) -> [Relationship] {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let relsPath = directory.isEmpty ? "_rels/\(name).rels" : "\(directory)/_rels/\(name).rels"
        guard let document = xml(reader, relsPath) else { return [] }
        return elements(document, "//*[local-name()='Relationship']").compactMap { element in
            guard let id = element.attribute(forName: "Id")?.stringValue,
                  let type = element.attribute(forName: "Type")?.stringValue,
                  let target = element.attribute(forName: "Target")?.stringValue,
                  element.attribute(forName: "TargetMode")?.stringValue != "External" else { return nil }
            // Цель — относительно папки части, или от корня пакета, если
            // начинается с «/».
            let resolved = target.hasPrefix("/")
                ? String(target.dropFirst())
                : EPUBExtractor.resolve(target, relativeTo: directory)
            return Relationship(id: id, type: type, target: resolved)
        }
    }

    /// Слайды в порядке показа.
    static func slidePaths(presentation: XMLDocument, reader: ZIPContainerReader) -> [String] {
        let relations = relationships(of: "ppt/presentation.xml", reader: reader)
        let byID = Dictionary(relations.map { ($0.id, $0.target) }, uniquingKeysWith: { first, _ in first })
        return elements(presentation, "//*[local-name()='sldIdLst']/*[local-name()='sldId']").compactMap { element in
            let id = element.attributes?.first { $0.localName == "id" && $0.prefix == "r" }?.stringValue
                ?? element.attributes?.first { $0.name?.hasSuffix(":id") == true }?.stringValue
            return id.flatMap { byID[$0] }
        }
    }

    static func metadata(_ reader: ZIPContainerReader) -> [String: String] {
        guard let core = xml(reader, "docProps/core.xml") else { return [:] }
        var result: [String: String] = [:]
        for (key, name) in [("document_title", "title"), ("document_author", "creator")] {
            if let value = elements(core, "//*[local-name()='\(name)']").first?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                result[key] = value
            }
        }
        if let created = elements(core, "//*[local-name()='created']").first?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !created.isEmpty {
            result["document_created"] = created
        }
        return result
    }

    // MARK: - Слайд

    struct SlideContent {
        var title: String?
        var lines: [String] = []
        var hasTables = false
    }

    /// Заполнители, которые повторяются на каждом слайде.
    static let furniture: Set<String> = ["sldNum", "dt", "ftr", "hdr"]
    static let titles: Set<String> = ["title", "ctrTitle"]

    static func slideContent(_ slide: XMLDocument, relations: [Relationship], reader: ZIPContainerReader) -> SlideContent {
        var content = SlideContent()
        guard let tree = elements(slide, "//*[local-name()='cSld']/*[local-name()='spTree']").first else { return content }
        let relationByID = Dictionary(relations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var titleBlocks: [String] = []
        var blocks: [String] = []
        for shape in ordered(children(of: tree)) {
            collect(shape, relations: relationByID, reader: reader, title: &titleBlocks, blocks: &blocks, hasTables: &content.hasTables)
        }
        let title = titleBlocks.joined(separator: " ")
            .components(separatedBy: .newlines).joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        if !title.isEmpty { content.title = title }
        content.lines = titleBlocks + blocks
        return content
    }

    /// Заголовок слайда без заполнителя заголовка — первая строка, похожая
    /// на заголовок: не строка таблицы и не одиночная подпись вроде «М9»
    /// или «и» на схеме. Нет такой — слайд остаётся без заголовка: место
    /// куска и так видно по номеру слайда.
    static func fallbackTitle(of lines: [String]) -> String? {
        guard let first = lines.first?.split(whereSeparator: \.isNewline).first.map({
            String($0).trimmingCharacters(in: .whitespaces)
        }) else { return nil }
        guard !TableText.isRow(first), first.split(separator: " ").count >= 2 || first.count >= 12 else { return nil }
        return first
    }

    /// Фигуры дерева — без служебных `nvGrpSpPr` и `grpSpPr`.
    static func children(of tree: XMLElement) -> [XMLElement] {
        (tree.children ?? []).compactMap { $0 as? XMLElement }.filter {
            ["sp", "grpSp", "graphicFrame", "cxnSp", "pic", "AlternateContent"].contains($0.localName ?? "")
        }
    }

    /// Порядок чтения: сверху вниз, в одной полосе — слева направо.
    ///
    /// Полоса — чтобы две колонки текста, начатые на полсантиметра в
    /// разнобой, читались по строкам слайда, а не колонка за колонкой из-за
    /// случайной разницы в высоте. У фигуры без своего положения (заполнитель
    /// берёт его из макета) — место предыдущей: в файле она стоит рядом
    /// со своими соседями.
    static func ordered(_ shapes: [XMLElement]) -> [XMLElement] {
        var previous: (y: Int, x: Int) = (0, 0)
        let placed = shapes.enumerated().map { index, shape -> (index: Int, y: Int, x: Int, shape: XMLElement) in
            if let offset = offset(of: shape) { previous = offset }
            return (index, previous.y, previous.x, shape)
        }
        let byHeight = placed.sorted { ($0.y, $0.index) < ($1.y, $1.index) }
        // Полоса — фигуры не ниже верхней из них на 1/40 высоты слайда 16:9,
        // около 3 мм. Не деление на шаг: две фигуры по разные стороны
        // границы шага попали бы в разные полосы при любой малой разнице.
        let tolerance = 130_000
        var result: [XMLElement] = []
        var band: [(index: Int, y: Int, x: Int, shape: XMLElement)] = []
        func flush() {
            result += band.sorted { ($0.x, $0.index) < ($1.x, $1.index) }.map(\.shape)
            band = []
        }
        for item in byHeight {
            if let top = band.first, item.y - top.y > tolerance { flush() }
            band.append(item)
        }
        flush()
        return result
    }

    static func offset(of shape: XMLElement) -> (y: Int, x: Int)? {
        let xpath = "./*[local-name()='spPr' or local-name()='grpSpPr']/*[local-name()='xfrm']/*[local-name()='off'] | ./*[local-name()='xfrm']/*[local-name()='off']"
        guard let off = elements(shape, xpath).first,
              let x = off.attribute(forName: "x")?.stringValue.flatMap(Int.init),
              let y = off.attribute(forName: "y")?.stringValue.flatMap(Int.init) else { return nil }
        return (y, x)
    }

    static func placeholderType(of shape: XMLElement) -> String? {
        guard let placeholder = elements(shape, "./*[local-name()='nvSpPr']/*[local-name()='nvPr']/*[local-name()='ph']").first else {
            return nil
        }
        // Заполнитель без типа — основной текст (ECMA-376, 19.3.1.36).
        return placeholder.attribute(forName: "type")?.stringValue ?? "body"
    }

    static func collect(
        _ shape: XMLElement,
        relations: [String: Relationship],
        reader: ZIPContainerReader,
        title: inout [String],
        blocks: inout [String],
        hasTables: inout Bool
    ) {
        switch shape.localName ?? "" {
        case "sp":
            let type = placeholderType(of: shape)
            if let type, furniture.contains(type) { return }
            guard let body = elements(shape, "./*[local-name()='txBody']").first else { return }
            let text = paragraphs(of: body).joined(separator: "\n")
            guard !text.isEmpty else { return }
            if let type, titles.contains(type), title.isEmpty {
                title.append(text)
            } else {
                blocks.append(text)
            }
        case "grpSp":
            for child in ordered(children(of: shape)) {
                collect(child, relations: relations, reader: reader, title: &title, blocks: &blocks, hasTables: &hasTables)
            }
        case "AlternateContent":
            // Новое содержимое с запасным для старых версий: читается одно —
            // первое, что есть.
            if let choice = elements(shape, "./*[local-name()='Choice' or local-name()='Fallback']").first {
                for child in children(of: choice) {
                    collect(child, relations: relations, reader: reader, title: &title, blocks: &blocks, hasTables: &hasTables)
                }
            }
        case "graphicFrame":
            if let table = elements(shape, ".//*[local-name()='tbl']").first {
                let rendered = self.table(table)
                if !rendered.isEmpty {
                    blocks.append(rendered)
                    hasTables = true
                }
            } else if let id = relationID(in: shape, element: "relIds", attribute: "dm"),
                      let part = relations[id], let data = xml(reader, part.target) {
                let text = diagramText(data)
                if !text.isEmpty { blocks.append(text) }
            } else if let id = relationID(in: shape, element: "chart", attribute: "id"),
                      let part = relations[id], let chart = xml(reader, part.target) {
                let text = chartText(chart)
                if !text.isEmpty { blocks.append(text) }
            }
        default:
            return
        }
    }

    /// `r:dm` у SmartArt, `r:id` у диаграммы.
    static func relationID(in frame: XMLElement, element: String, attribute: String) -> String? {
        guard let node = elements(frame, ".//*[local-name()='\(element)']").first else { return nil }
        return node.attributes?.first { $0.localName == attribute && ($0.prefix == "r" || $0.name?.contains(":") == true) }?
            .stringValue
    }

    // MARK: - Текст

    /// Абзацы `a:p` тела фигуры. Поле номера слайда пропускается, `a:br` —
    /// перенос строки внутри абзаца.
    static func paragraphs(of body: XMLElement) -> [String] {
        elements(body, "./*[local-name()='p']").compactMap { paragraph in
            var line = ""
            for case let child as XMLElement in paragraph.children ?? [] {
                switch child.localName ?? "" {
                case "r":
                    line += elements(child, "./*[local-name()='t']").compactMap(\.stringValue).joined()
                case "fld":
                    if child.attribute(forName: "type")?.stringValue == "slidenum" { continue }
                    line += elements(child, "./*[local-name()='t']").compactMap(\.stringValue).joined()
                case "br":
                    line += "\n"
                default:
                    continue
                }
            }
            let trimmed = line.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    static func table(_ table: XMLElement) -> String {
        let rows = elements(table, "./*[local-name()='tr']").map { row in
            elements(row, "./*[local-name()='tc']").map { cell -> String in
                // Продолжение объединённой ячейки — пустое место, а не
                // повтор: текст объединённой ячейки стоит в первой.
                guard let body = elements(cell, "./*[local-name()='txBody']").first else { return "" }
                return paragraphs(of: body).joined(separator: " ")
                    .replacingOccurrences(of: "\n", with: " ")
            }
        }
        return TableText.render(rows)
    }

    /// Текст узлов SmartArt по порядку. Служебные точки схемы — переходы
    /// и точки оформления — текста не несут.
    static func diagramText(_ data: XMLDocument) -> String {
        elements(data, "//*[local-name()='ptLst']/*[local-name()='pt']").compactMap { point -> String? in
            let type = point.attribute(forName: "type")?.stringValue ?? "node"
            guard type == "node" else { return nil }
            guard let body = elements(point, "./*[local-name()='t']").first else { return nil }
            let text = paragraphs(of: body).joined(separator: " ")
            return text.isEmpty ? nil : text
        }.joined(separator: "\n")
    }

    /// Заголовок диаграммы и названия её рядов: по ним диаграмму и ищут.
    static func chartText(_ chart: XMLDocument) -> String {
        var lines: [String] = []
        if let title = elements(chart, "//*[local-name()='chart']/*[local-name()='title']").first {
            let text = elements(title, ".//*[local-name()='t']").compactMap(\.stringValue).joined()
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { lines.append(text) }
        }
        var series: [String] = []
        for name in elements(chart, "//*[local-name()='ser']/*[local-name()='tx']") {
            let value = elements(name, ".//*[local-name()='v']").first?.stringValue
                ?? elements(name, ".//*[local-name()='t']").compactMap(\.stringValue).joined()
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !series.contains(trimmed) { series.append(trimmed) }
        }
        if !series.isEmpty { lines.append(series.joined(separator: "; ")) }
        return lines.joined(separator: "\n")
    }

    /// Текст заметок — заполнитель основного текста на странице заметок.
    /// Образ слайда и номер страницы на той же странице текстом не являются.
    static func notesText(_ notes: XMLDocument) -> String {
        elements(notes, "//*[local-name()='sp']").filter { placeholderType(of: $0) == "body" }
            .compactMap { shape in elements(shape, "./*[local-name()='txBody']").first }
            .flatMap(paragraphs(of:))
            .joined(separator: "\n")
    }
}
