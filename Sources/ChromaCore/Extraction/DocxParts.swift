import Foundation

/// Разбор `.docx` по частям контейнера, а не через системный импортёр.
///
/// `NSAttributedString` отдаёт готовый текст со шрифтами — и на этом всё:
/// разметку заголовков стилями, номера пунктов, колонтитулы и сноски он
/// не показывает **никак**, ни текстом, ни признаком. Проверено зондом на
/// настоящих документах: файл с двенадцатью абзацами `Heading*` приходит
/// без единого указания на то, что это заголовки, и структуру приходилось
/// угадывать по кеглю — на документе с одним размером шрифта пятнадцать
/// «заголовков» получались все первого уровня.
///
/// `.docx` — тот же ZIP, что и `.xlsx`, и читалка частей у проекта уже есть.
/// Здесь разбираются те части, где лежит потерянное.
public struct DocxPartsReader {
    private let reader: ZIPContainerReader

    public init?(url: URL) {
        guard let reader = try? ZIPContainerReader(url: url),
              reader.entry(at: "word/document.xml") != nil
        else { return nil }
        self.reader = reader
    }

    /// Всё, что нужно экстрактору, одним проходом по частям.
    public func read() -> Document? {
        guard let documentData = try? reader.read("word/document.xml") else { return nil }

        let styles = (try? reader.read("word/styles.xml")).map(StyleTable.parse) ?? StyleTable()
        let numbering = (try? reader.read("word/numbering.xml")).map(NumberingTable.parse) ?? NumberingTable()
        let relationships = (try? reader.read("word/_rels/document.xml.rels"))
            .map(Self.parseRelationships) ?? [:]

        let body = BodyParser(styles: styles, numbering: numbering, relationships: relationships)
        guard body.parse(documentData) else { return nil }

        // Колонтитулы — по ссылкам из `sectPr`, а не по именам файлов: у документа
        // с несколькими разделами их бывает шесть, и половина не используется.
        var headers: [String] = []
        var footers: [String] = []
        for (id, isHeader) in body.furnitureReferences {
            guard let target = relationships[id] else { continue }
            guard let data = try? reader.read("word/" + target) else { continue }
            let piece = PlainPartParser.text(of: data)
            guard !piece.isEmpty else { continue }
            if isHeader { headers.append(piece) } else { footers.append(piece) }
        }

        var footnotes: [String: String] = [:]
        if !body.footnoteReferences.isEmpty, let data = try? reader.read("word/footnotes.xml") {
            footnotes = FootnoteParser.notes(of: data).filter { body.footnoteReferences.contains($0.key) }
        }

        // Комментарии — такой же написанный человеком текст, как сноска
        //. Берутся только те, на которые в документе есть ссылка:
        // Word оставляет в части и осиротевшие.
        var comments: [Comment] = []
        var commentsUnreadable = false
        let commentsPart = reader.entry(at: "word/comments.xml")
        if let commentsPart, commentsPart.uncompressedSize > 0 {
            if let data = try? reader.read("word/comments.xml") {
                comments = CommentParser.comments(of: data)
                    .filter { body.commentReferences.isEmpty || body.commentReferences.contains($0.id) }
            } else {
                commentsUnreadable = true
            }
        }

        return Document(
            paragraphs: body.paragraphs,
            headers: Array(Set(headers)).sorted(),
            footers: Array(Set(footers)).sorted(),
            footnotes: footnotes,
            comments: comments,
            hasRevisions: body.sawRevisions,
            commentsUnreadable: commentsUnreadable,
            hasTables: body.sawTables,
            hiddenParagraphs: body.paragraphs.filter(\.isHidden).count
        )
    }

    static func parseRelationships(_ data: Data) -> [String: String] {
        final class Delegate: NSObject, XMLParserDelegate {
            var map: [String: String] = [:]
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String]) {
                guard name.hasSuffix("Relationship"),
                      let id = attributes["Id"], let target = attributes["Target"] else { return }
                map[id] = target
            }
        }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.parse()
        return delegate.map
    }
}

// MARK: - styles.xml

extension DocxPartsReader {
    /// Что стиль абзаца говорит о его роли.
    struct StyleTable {
        /// styleId → уровень заголовка, 1 — верхний.
        var headingLevels: [String: Int] = [:]

        /// Уровень из `w:outlineLvl` (он 0-based) или из имени встроенного стиля.
        ///
        /// Имя разбирается по-английски: Word пишет `w:name w:val="heading 1"`
        /// независимо от языка интерфейса, а видимое «Заголовок 1» берётся
        /// из словаря самого Word.
        static func parse(_ data: Data) -> StyleTable {
            final class Delegate: NSObject, XMLParserDelegate {
                var table = StyleTable()
                private var styleID: String?
                private var name: String?
                private var outline: Int?

                func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                            qualifiedName: String?, attributes: [String: String]) {
                    switch element {
                    case "w:style":
                        styleID = attributes["w:styleId"]
                        name = nil
                        outline = nil
                    case "w:name": name = attributes["w:val"]
                    case "w:outlineLvl": outline = attributes["w:val"].flatMap(Int.init)
                    default: break
                    }
                }

                func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                            qualifiedName: String?) {
                    guard element == "w:style", let styleID else { return }
                    if let outline, outline >= 0, outline <= 8 {
                        table.headingLevels[styleID] = outline + 1
                    } else if let level = StyleTable.headingLevel(fromName: name) {
                        table.headingLevels[styleID] = level
                    }
                    self.styleID = nil
                }
            }
            let delegate = Delegate()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.shouldProcessNamespaces = false
            parser.parse()
            return delegate.table
        }

        static func headingLevel(fromName name: String?) -> Int? {
            guard let name else { return nil }
            let lower = name.lowercased()
            for prefix in ["heading ", "заголовок "] where lower.hasPrefix(prefix) {
                if let level = Int(lower.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)),
                   level >= 1, level <= 9 {
                    return level
                }
            }
            return nil
        }
    }
}

// MARK: - numbering.xml

extension DocxPartsReader {
    /// Нумерация списков: `numId` → уровни.
    ///
    /// Номер пункта — часть смысла: в регламенте ссылаются «по пункту 3.2»,
    /// и без номера этот пункт не найти.
    struct NumberingTable {
        /// abstractNumId → (уровень → формат)
        var levels: [String: [Int: Level]] = [:]
        /// numId → abstractNumId
        var instances: [String: String] = [:]

        struct Level {
            var format: String = "decimal"
            /// `%1.%2.` — где `%N` подставляется счётчиком уровня N.
            var text: String = ""
            var start: Int = 1
        }

        func level(numID: String, indent: Int) -> Level? {
            guard let abstract = instances[numID] else { return nil }
            return levels[abstract]?[indent]
        }

        static func parse(_ data: Data) -> NumberingTable {
            final class Delegate: NSObject, XMLParserDelegate {
                var table = NumberingTable()
                private var abstractID: String?
                private var numID: String?
                private var levelIndex: Int?
                private var level = Level()

                func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                            qualifiedName: String?, attributes: [String: String]) {
                    switch element {
                    case "w:abstractNum": abstractID = attributes["w:abstractNumId"]
                    case "w:num": numID = attributes["w:numId"]
                    case "w:abstractNumId":
                        if let numID, let value = attributes["w:val"] { table.instances[numID] = value }
                    case "w:lvl":
                        levelIndex = attributes["w:ilvl"].flatMap(Int.init)
                        level = Level()
                    case "w:numFmt": level.format = attributes["w:val"] ?? "decimal"
                    case "w:lvlText": level.text = attributes["w:val"] ?? ""
                    case "w:start": level.start = attributes["w:val"].flatMap(Int.init) ?? 1
                    default: break
                    }
                }

                func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                            qualifiedName: String?) {
                    switch element {
                    case "w:lvl":
                        if let abstractID, let levelIndex {
                            table.levels[abstractID, default: [:]][levelIndex] = level
                        }
                        levelIndex = nil
                    case "w:abstractNum": abstractID = nil
                    case "w:num": numID = nil
                    default: break
                    }
                }
            }
            let delegate = Delegate()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.shouldProcessNamespaces = false
            parser.parse()
            return delegate.table
        }
    }

    /// Считает номера так же, как их видно в Word: счётчик на уровень,
    /// вложенные уровни сбрасываются при переходе на верхний.
    struct NumberingCounter {
        private var counters: [String: [Int: Int]] = [:]

        mutating func next(numID: String, indent: Int, table: NumberingTable) -> String? {
            guard let level = table.level(numID: numID, indent: indent) else { return nil }
            // Маркированный список: номера нет, но пункт есть — ставим тире,
            // чтобы список не слился в сплошной текст.
            guard level.format != "bullet" else { return "—" }

            var levels = counters[numID] ?? [:]
            levels[indent] = (levels[indent] ?? level.start - 1) + 1
            // Уровни глубже текущего начинаются заново.
            for deeper in levels.keys where deeper > indent { levels[deeper] = nil }
            counters[numID] = levels

            var result = level.text.isEmpty ? "%\(indent + 1)." : level.text
            for position in 0...indent {
                let value = levels[position] ?? (table.level(numID: numID, indent: position)?.start ?? 1)
                result = result.replacingOccurrences(
                    of: "%\(position + 1)",
                    with: Self.format(value, as: table.level(numID: numID, indent: position)?.format ?? "decimal")
                )
            }
            return result.trimmingCharacters(in: .whitespaces)
        }

        static func format(_ value: Int, as format: String) -> String {
            switch format {
            case "lowerLetter": return letter(value, uppercase: false)
            case "upperLetter": return letter(value, uppercase: true)
            case "lowerRoman": return roman(value).lowercased()
            case "upperRoman": return roman(value)
            default: return String(value)
            }
        }

        private static func letter(_ value: Int, uppercase: Bool) -> String {
            guard value > 0 else { return "" }
            let base = uppercase ? 65 : 97
            let index = (value - 1) % 26
            let repeats = (value - 1) / 26 + 1
            return String(repeating: String(UnicodeScalar(base + index)!), count: repeats)
        }

        private static func roman(_ value: Int) -> String {
            guard value > 0, value < 4000 else { return String(value) }
            let table: [(Int, String)] = [
                (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
            ]
            var rest = value
            var result = ""
            for (number, letters) in table {
                while rest >= number {
                    result += letters
                    rest -= number
                }
            }
            return result
        }
    }
}

// MARK: - document.xml

extension DocxPartsReader {
    /// Потоковый разбор тела документа.
    ///
    /// Собирается **весь** видимый текст в порядке файла, включая надписи:
    /// `w:txbxContent` — обычные абзацы внутри прогона, и стек абзацев их
    /// подхватывает сам. Не собирается то, чего в документе не видно:
    /// удалённый правкой текст (`w:delText`), коды полей (`w:instrText`)
    /// и запасная ветка `mc:Fallback` — её текст уже взят из `mc:Choice`,
    /// и без пропуска надпись попала бы в базу дважды.
    final class BodyParser: NSObject, XMLParserDelegate {
        private let styles: StyleTable
        private let numbering: NumberingTable
        private let relationships: [String: String]
        private var counter = NumberingCounter()

        private(set) var paragraphs: [Paragraph] = []
        /// `rId` → это колонтитул сверху.
        private(set) var furnitureReferences: [(id: String, isHeader: Bool)] = []
        private(set) var footnoteReferences: Set<String> = []
        private(set) var commentReferences: Set<String> = []
        private(set) var sawRevisions = false
        private(set) var sawTables = false

        /// Стек абзацев: надпись вкладывает абзацы внутрь абзаца.
        private var stack: [Builder] = []
        private var skipDepth = 0
        private var capturing = false
        /// Текущий прогон скрыт (`w:vanish`).
        private var runIsHidden = false
        private var runIsBold = false
        private var runSize: Double?
        /// Внутри `w:pPr`: тамошний `w:rPr` описывает знак конца абзаца,
        /// а не его текст, и скрытость оттуда к тексту не относится.
        private var insideParagraphProperties = false

        // Таблицы
        private var tableStack: [Int] = []
        private var tableCount = 0
        private var rowIndex: [Int: Int] = [:]
        private var columnIndex = 0
        private var cellIsContinuation = false

        private struct Builder {
            var text = ""
            /// Сколько знаков пришло из скрытых прогонов. Абзац считается
            /// скрытым, только если скрыт **весь** его текст: полскрытого
            /// абзаца в Word не бывает видно наполовину, там просто дырка.
            var hiddenCharacters = 0
            var visibleCharacters = 0
            var boldCharacters = 0
            /// Кегль → сколько знаков им набрано: у абзаца берётся тот,
            /// которым набрано больше всего.
            var sizes: [Double: Int] = [:]
            var styleID: String?
            var outlineLevel: Int?
            var numID: String?
            var indent = 0
            var links: [String] = []
            var footnotes: [String] = []
            var cell: Cell?
        }

        init(styles: StyleTable, numbering: NumberingTable, relationships: [String: String]) {
            self.styles = styles
            self.numbering = numbering
            self.relationships = relationships
        }

        func parse(_ data: Data) -> Bool {
            let parser = XMLParser(data: data)
            parser.delegate = self
            parser.shouldProcessNamespaces = false
            return parser.parse()
        }

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            if skipDepth > 0 {
                // Внутри пропускаемой ветки считаем вложенность, иначе выход
                // из неё определился бы по первому же закрытию.
                if Self.skipped.contains(element) { skipDepth += 1 }
                return
            }
            switch element {
            case "mc:Fallback", "w:instrText", "w:delText", "w:proofErr":
                skipDepth = 1
            case "w:ins", "w:del":
                sawRevisions = true
            case "w:commentRangeStart", "w:commentReference":
                if let id = attributes["w:id"] { commentReferences.insert(id) }
            case "w:tbl":
                sawTables = true
                tableCount += 1
                tableStack.append(tableCount)
                rowIndex[tableCount] = -1
            case "w:tr":
                if let table = tableStack.last { rowIndex[table] = (rowIndex[table] ?? -1) + 1 }
                columnIndex = -1
            case "w:tc":
                columnIndex += 1
                cellIsContinuation = false
            case "w:vMerge":
                // Без `w:val` — продолжение объединения; `restart` — его начало.
                cellIsContinuation = (attributes["w:val"] ?? "continue") != "restart"
            case "w:gridSpan":
                // Ячейка занимает несколько колонок: следующая начнётся дальше.
                columnIndex += (attributes["w:val"].flatMap(Int.init) ?? 1) - 1
            case "w:p":
                var builder = Builder()
                if let table = tableStack.last {
                    builder.cell = Cell(
                        table: table, row: rowIndex[table] ?? 0, column: max(0, columnIndex),
                        isVerticalContinuation: cellIsContinuation
                    )
                }
                stack.append(builder)
            case "w:pStyle": stack.mutateLast { $0.styleID = attributes["w:val"] }
            case "w:outlineLvl":
                let value = attributes["w:val"].flatMap(Int.init)
                stack.mutateLast { $0.outlineLevel = value.map { $0 + 1 } }
            case "w:numPr": stack.mutateLast { $0.numID = nil; $0.indent = 0 }
            case "w:ilvl": stack.mutateLast { $0.indent = attributes["w:val"].flatMap(Int.init) ?? 0 }
            case "w:numId": stack.mutateLast { $0.numID = attributes["w:val"] }
            case "w:pPr": insideParagraphProperties = true
            case "w:r":
                runIsHidden = false
                runIsBold = false
                runSize = nil
            case "w:b", "w:bCs":
                // `w:val="0"` выключает жирность, унаследованную от стиля.
                if !insideParagraphProperties { runIsBold = (attributes["w:val"] ?? "1") != "0" }
            case "w:sz", "w:szCs":
                // Кегль в половинах пункта — так его пишет формат.
                if !insideParagraphProperties, let half = attributes["w:val"].flatMap(Double.init) {
                    runSize = half / 2
                }
            case "w:vanish", "w:webHidden":
                // Признак прогона, а не абзаца. `w:vanish` в `w:pPr` относится
                // к знаку конца абзаца — текст он не прячет.
                if !insideParagraphProperties { runIsHidden = true }
            case "w:hyperlink":
                if let id = attributes["r:id"], let target = relationships[id] {
                    stack.mutateLast { $0.links.append(target) }
                }
            case "w:footnoteReference", "w:endnoteReference":
                if let id = attributes["w:id"] {
                    footnoteReferences.insert(id)
                    stack.mutateLast { $0.footnotes.append(id) }
                }
            case "w:headerReference":
                if let id = attributes["r:id"] { furnitureReferences.append((id, true)) }
            case "w:footerReference":
                if let id = attributes["r:id"] { furnitureReferences.append((id, false)) }
            case "w:t", "w:tab":
                capturing = true
                if element == "w:tab" { stack.mutateLast { $0.text += "\t" } }
            case "w:br", "w:cr":
                stack.mutateLast { $0.text += "\n" }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard capturing, skipDepth == 0 else { return }
            let hidden = runIsHidden
            let bold = runIsBold
            let size = runSize
            stack.mutateLast {
                $0.text += string
                if hidden {
                    $0.hiddenCharacters += string.count
                } else {
                    $0.visibleCharacters += string.count
                    if bold { $0.boldCharacters += string.count }
                    if let size { $0.sizes[size, default: 0] += string.count }
                }
            }
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                    qualifiedName: String?) {
            if skipDepth > 0 {
                if Self.skipped.contains(element) { skipDepth -= 1 }
                return
            }
            switch element {
            case "w:t": capturing = false
            case "w:pPr": insideParagraphProperties = false
            case "w:r":
                runIsHidden = false
                runIsBold = false
                runSize = nil
            case "w:tbl":
                if let table = tableStack.popLast() { rowIndex[table] = nil }
            case "w:p":
                guard var builder = stack.popLast() else { return }
                finish(&builder)
            default:
                break
            }
        }

        /// Абзац готов: считается номер, определяется уровень заголовка.
        private func finish(_ builder: inout Builder) {
            let text = builder.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var marker: String?
            if let numID = builder.numID, !text.isEmpty {
                marker = counter.next(numID: numID, indent: builder.indent, table: numbering)
            }
            // Прямой `w:outlineLvl` главнее стиля: человек поставил его руками.
            let level = builder.outlineLevel ?? builder.styleID.flatMap { styles.headingLevels[$0] }
            // Пустой абзац выбрасывается — но не в таблице: пустая ячейка
            // хранит геометрию строки, и без неё объединение вниз некуда
            // размазывать, а колонки съезжают влево.
            guard !text.isEmpty || builder.cell != nil else {
                // Ссылка на сноску в пустом абзаце — примета вёрстки, а не
                // смысла: сноска принадлежит тому, что было до неё.
                // Выбросить абзац вместе со ссылкой значило бы потерять место
                // сноски, и она уехала бы в конец документа.
                if !builder.footnotes.isEmpty {
                    paragraphs.mutateLast { $0.footnotes += builder.footnotes }
                }
                return
            }
            paragraphs.append(Paragraph(
                text: text,
                headingLevel: level,
                marker: marker,
                isHidden: builder.hiddenCharacters > 0 && builder.visibleCharacters == 0,
                cell: builder.cell,
                links: builder.links,
                footnotes: builder.footnotes,
                isBold: builder.visibleCharacters > 0 && builder.boldCharacters == builder.visibleCharacters,
                size: builder.sizes.max { $0.value < $1.value }?.key
            ))
        }

        /// Элементы, чьё содержимое в документе не видно.
        static let skipped: Set<String> = ["mc:Fallback", "w:instrText", "w:delText", "w:proofErr"]
    }
}

private extension Array {
    mutating func mutateLast(_ change: (inout Element) -> Void) {
        guard !isEmpty else { return }
        change(&self[count - 1])
    }
}

// MARK: - Простые части: колонтитулы и сноски

extension DocxPartsReader {
    /// Текст части, где важен только он: колонтитул.
    enum PlainPartParser {
        static func text(of data: Data) -> String {
            final class Delegate: NSObject, XMLParserDelegate {
                var lines: [String] = []
                private var current = ""
                private var capturing = false
                private var skipDepth = 0

                func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                            qualifiedName: String?, attributes: [String: String]) {
                    if skipDepth > 0 {
                        if DocxPartsReader.BodyParser.skipped.contains(element) { skipDepth += 1 }
                        return
                    }
                    if DocxPartsReader.BodyParser.skipped.contains(element) { skipDepth = 1; return }
                    if element == "w:p" { current = "" }
                    if element == "w:t" { capturing = true }
                }

                func parser(_ parser: XMLParser, foundCharacters string: String) {
                    if capturing, skipDepth == 0 { current += string }
                }

                func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                            qualifiedName: String?) {
                    if skipDepth > 0 {
                        if DocxPartsReader.BodyParser.skipped.contains(element) { skipDepth -= 1 }
                        return
                    }
                    if element == "w:t" { capturing = false }
                    if element == "w:p" {
                        let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { lines.append(text) }
                        current = ""
                    }
                }
            }
            let delegate = Delegate()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.shouldProcessNamespaces = false
            parser.parse()
            return delegate.lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Комментарии: номер, автор, текст.
    enum CommentParser {
        static func comments(of data: Data) -> [Comment] {
            final class Delegate: NSObject, XMLParserDelegate {
                var comments: [Comment] = []
                private var id: String?
                private var author = ""
                private var text = ""
                private var capturing = false
                private var skipDepth = 0

                func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                            qualifiedName: String?, attributes: [String: String]) {
                    if skipDepth > 0 {
                        if DocxPartsReader.BodyParser.skipped.contains(element) { skipDepth += 1 }
                        return
                    }
                    if DocxPartsReader.BodyParser.skipped.contains(element) { skipDepth = 1; return }
                    switch element {
                    case "w:comment":
                        id = attributes["w:id"]
                        author = attributes["w:author"] ?? ""
                        text = ""
                    case "w:t": capturing = true
                    case "w:p" where !text.isEmpty:
                        // Комментарий из нескольких абзацев остаётся одним.
                        text += " "
                    default: break
                    }
                }

                func parser(_ parser: XMLParser, foundCharacters string: String) {
                    if capturing, skipDepth == 0 { text += string }
                }

                func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                            qualifiedName: String?) {
                    if skipDepth > 0 {
                        if DocxPartsReader.BodyParser.skipped.contains(element) { skipDepth -= 1 }
                        return
                    }
                    switch element {
                    case "w:t": capturing = false
                    case "w:comment":
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let id, !trimmed.isEmpty {
                            comments.append(Comment(id: id, author: author.trimmingCharacters(in: .whitespaces), text: trimmed))
                        }
                        id = nil
                    default: break
                    }
                }
            }
            let delegate = Delegate()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.shouldProcessNamespaces = false
            parser.parse()
            return delegate.comments.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        }
    }

    /// Сноски: номер → текст.
    enum FootnoteParser {
        static func notes(of data: Data) -> [String: String] {
            final class Delegate: NSObject, XMLParserDelegate {
                var notes: [String: String] = [:]
                private var id: String?
                private var text = ""
                private var capturing = false
                private var skipDepth = 0

                func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                            qualifiedName: String?, attributes: [String: String]) {
                    if skipDepth > 0 {
                        if DocxPartsReader.BodyParser.skipped.contains(element) { skipDepth += 1 }
                        return
                    }
                    if DocxPartsReader.BodyParser.skipped.contains(element) { skipDepth = 1; return }
                    switch element {
                    case "w:footnote", "w:endnote":
                        id = attributes["w:id"]
                        text = ""
                    case "w:t": capturing = true
                    default: break
                    }
                }

                func parser(_ parser: XMLParser, foundCharacters string: String) {
                    if capturing, skipDepth == 0 { text += string }
                }

                func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                            qualifiedName: String?) {
                    if skipDepth > 0 {
                        if DocxPartsReader.BodyParser.skipped.contains(element) { skipDepth -= 1 }
                        return
                    }
                    switch element {
                    case "w:t": capturing = false
                    case "w:footnote", "w:endnote":
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let id, !trimmed.isEmpty { notes[id] = trimmed }
                        id = nil
                    default: break
                    }
                }
            }
            let delegate = Delegate()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.shouldProcessNamespaces = false
            parser.parse()
            return delegate.notes
        }
    }
}
