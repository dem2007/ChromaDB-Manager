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

        // Сноски и концевые сноски — два разных счёта, и оба начинаются
        // с единицы. Пока ссылки обоих видов искались в одной только
        // `footnotes.xml`, концевая сноска 1 получала текст обычной сноски 1,
        // а её собственный текст не извлекался вовсе.
        var footnotes: [String: String] = [:]
        if !body.footnoteReferences.isEmpty {
            if let data = try? reader.read("word/footnotes.xml") {
                footnotes.merge(FootnoteParser.notes(of: data)) { first, _ in first }
            }
            if let data = try? reader.read("word/endnotes.xml") {
                let endnotes = FootnoteParser.notes(of: data)
                footnotes.merge(
                    Dictionary(uniqueKeysWithValues: endnotes.map { (Self.endnoteKey($0.key), $0.value) })
                ) { first, _ in first }
            }
            footnotes = footnotes.filter { body.footnoteReferences.contains($0.key) }
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
        /// Нумерация, заданная самим стилем (`w:pPr/w:numPr`).
        ///
        /// «Заголовок 1» с номером «1», «Заголовок 2» — «1.1»: абзац такого
        /// стиля нумеруется без своей разметки (ECMA-376, 17.3.1.19). Раньше
        /// номер брался только из разметки абзаца, и в ТЗ на 25 тысяч строк
        /// терялись номера у 4207 абзацев — пункт «4.2.3» находился только
        /// в оглавлении.
        var numbering: [String: StyleNumbering] = [:]
        /// Стиль → его базовый (`w:basedOn`): нумерация наследуется.
        var basedOn: [String: String] = [:]
        /// Стили строк оглавления: «toc 1» … «toc 9» и заголовок
        /// оглавления «TOC Heading».
        var tableOfContents: Set<String> = []

        /// Имя стиля оглавления — так его пишет Word на любом языке.
        static func isTableOfContents(name: String?) -> Bool {
            guard let lower = name?.lowercased() else { return false }
            if lower == "toc heading" { return true }
            guard lower.hasPrefix("toc ") else { return false }
            return Int(lower.dropFirst(4).trimmingCharacters(in: .whitespaces)).map { (1...9).contains($0) } ?? false
        }

        struct StyleNumbering: Equatable {
            var numID: String?
            /// `w:ilvl` стиля. По стандарту им пользоваться не положено —
            /// уровень берётся у определения списка, связанного со стилем
            /// (`w:lvl/w:pStyle`), — но связи бывает не найти, и тогда он
            /// лучше нуля.
            var indent: Int?
        }

        /// Нумерация стиля с учётом наследования. `nil` — стиль её не задаёт;
        /// `numID` "0" — стиль её снимает.
        func numbering(ofStyle styleID: String) -> StyleNumbering? {
            var current: String? = styleID
            var visited: Set<String> = []
            while let id = current, visited.insert(id).inserted {
                if let own = numbering[id] { return own }
                current = basedOn[id]
            }
            return nil
        }

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
                private var styleNumbering = StyleNumbering()
                private var insideNumbering = false

                func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                            qualifiedName: String?, attributes: [String: String]) {
                    switch element {
                    case "w:style":
                        styleID = attributes["w:styleId"]
                        name = nil
                        outline = nil
                        styleNumbering = StyleNumbering()
                    case "w:name": name = attributes["w:val"]
                    case "w:basedOn":
                        if let styleID, let base = attributes["w:val"] { table.basedOn[styleID] = base }
                    case "w:outlineLvl": outline = attributes["w:val"].flatMap(Int.init)
                    case "w:numPr": insideNumbering = true
                    case "w:numId" where insideNumbering: styleNumbering.numID = attributes["w:val"]
                    case "w:ilvl" where insideNumbering:
                        styleNumbering.indent = attributes["w:val"].flatMap(Int.init)
                    default: break
                    }
                }

                func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                            qualifiedName: String?) {
                    if element == "w:numPr" { insideNumbering = false }
                    guard element == "w:style", let styleID else { return }
                    if let outline, outline >= 0, outline <= 8 {
                        table.headingLevels[styleID] = outline + 1
                    } else if let level = StyleTable.headingLevel(fromName: name) {
                        table.headingLevels[styleID] = level
                    }
                    if styleNumbering.numID != nil { table.numbering[styleID] = styleNumbering }
                    if StyleTable.isTableOfContents(name: name) { table.tableOfContents.insert(styleID) }
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
        /// numId → (уровень → номер, с которого список начинается заново):
        /// `w:lvlOverride/w:startOverride` — так Word записывает «начать
        /// нумерацию заново».
        var startOverrides: [String: [Int: Int]] = [:]
        /// numId → (уровень → свой вид уровня): `w:lvlOverride/w:lvl`.
        var levelOverrides: [String: [Int: Level]] = [:]
        /// abstractNumId → стиль нумерации, на который определение
        /// ссылается вместо своих уровней (`w:numStyleLink`).
        var styleLinks: [String: String] = [:]

        struct Level {
            var format: String = "decimal"
            /// `%1.%2.` — где `%N` подставляется счётчиком уровня N.
            var text: String = ""
            var start: Int = 1
            /// Стиль абзаца, связанный с этим уровнем (`w:pStyle`): абзац
            /// этого стиля, нумерованный стилем, стоит на этом уровне.
            var paragraphStyle: String?
            /// `w:isLgl`: все уровни номера — арабскими цифрами («1.2», а не
            /// «I.b»).
            var isLegal = false
        }

        /// Определение списка, по которому считает экземпляр `numID`.
        ///
        /// Определение со ссылкой на стиль нумерации (`w:numStyleLink`)
        /// своих уровней не несёт — они у определения, на которое указывает
        /// этот стиль.
        func abstract(of numID: String, styles: StyleTable = StyleTable()) -> String? {
            var current = instances[numID]
            var visited: Set<String> = []
            while let id = current, visited.insert(id).inserted {
                guard levels[id]?.isEmpty ?? true, let link = styleLinks[id],
                      let linked = styles.numbering(ofStyle: link)?.numID,
                      let target = instances[linked] else { return id }
                current = target
            }
            return current
        }

        func level(numID: String, indent: Int, styles: StyleTable = StyleTable()) -> Level? {
            if let own = levelOverrides[numID]?[indent] { return own }
            guard let abstract = abstract(of: numID, styles: styles) else { return nil }
            return levels[abstract]?[indent]
        }

        /// Уровень, связанный со стилем абзаца, — у абзаца, которому номер
        /// дал стиль (ECMA-376, 17.9.23).
        func indent(numID: String, paragraphStyle: String, styles: StyleTable = StyleTable()) -> Int? {
            guard let abstract = abstract(of: numID, styles: styles) else { return nil }
            return levels[abstract]?.first { $0.value.paragraphStyle == paragraphStyle }?.key
        }

        static func parse(_ data: Data) -> NumberingTable {
            final class Delegate: NSObject, XMLParserDelegate {
                var table = NumberingTable()
                private var abstractID: String?
                private var numID: String?
                private var levelIndex: Int?
                private var level = Level()
                /// Уровень внутри `w:lvlOverride` текущего `w:num`.
                private var overrideIndex: Int?

                func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                            qualifiedName: String?, attributes: [String: String]) {
                    switch element {
                    case "w:abstractNum": abstractID = attributes["w:abstractNumId"]
                    case "w:num": numID = attributes["w:numId"]
                    case "w:abstractNumId":
                        if let numID, let value = attributes["w:val"] { table.instances[numID] = value }
                    case "w:numStyleLink":
                        if let abstractID, let value = attributes["w:val"] { table.styleLinks[abstractID] = value }
                    case "w:lvlOverride":
                        overrideIndex = attributes["w:ilvl"].flatMap(Int.init)
                    case "w:startOverride":
                        if let numID, let overrideIndex, let value = attributes["w:val"].flatMap(Int.init) {
                            table.startOverrides[numID, default: [:]][overrideIndex] = value
                        }
                    case "w:lvl":
                        levelIndex = attributes["w:ilvl"].flatMap(Int.init)
                        level = Level()
                    case "w:numFmt": level.format = attributes["w:val"] ?? "decimal"
                    case "w:lvlText": level.text = attributes["w:val"] ?? ""
                    case "w:start": level.start = attributes["w:val"].flatMap(Int.init) ?? 1
                    case "w:pStyle" where levelIndex != nil: level.paragraphStyle = attributes["w:val"]
                    case "w:isLgl": level.isLegal = (attributes["w:val"] ?? "1") != "0"
                    default: break
                    }
                }

                func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                            qualifiedName: String?) {
                    switch element {
                    case "w:lvl":
                        if let numID, let overrideIndex {
                            // Уровень, переопределённый у экземпляра, — его вид.
                            // Начальный номер Word у такого уровня не берёт:
                            // заново список начинает только `startOverride`.
                            table.levelOverrides[numID, default: [:]][levelIndex ?? overrideIndex] = level
                        } else if let abstractID, let levelIndex {
                            table.levels[abstractID, default: [:]][levelIndex] = level
                        }
                        levelIndex = nil
                    case "w:lvlOverride": overrideIndex = nil
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
    ///
    /// Счётчик — **у определения списка** (`abstractNum`), а не у экземпляра
    /// (`num`): два экземпляра одного определения продолжают общий счёт.
    /// Экземпляр с `startOverride` («начать нумерацию заново») — отдельный
    /// список со своим счётом: он начинается с заданного номера и общий
    /// счёт не трогает. Так считает Word. Проверено по оглавлению ТЗ на
    /// 344 пункта: подпункты, перезапущенные с единицы посреди раздела 9,
    /// не сбивают следующих заголовков — за «9.8.2» идёт «9.8.3».
    ///
    /// **У `.doc` перезапуск — другой.** Экземпляр списка (`LFO`)
    /// с «начать заново» не заводит своего счёта: он перезапускает **общий**
    /// счёт определения при первом своём абзаце — с уровня этого абзаца, —
    /// и дальше все экземпляры считают вместе. Проверено по оглавлениям самих документов: на 296
    /// файлах `.doc` правило `.docx` даёт 1400 совпадений из 1933, это —
    /// 1792; на 791 файле `.docx` наоборот — 2339 против 2025. Типичный
    /// случай `.doc`: первый заголовок «1» стоит в экземпляре, начинающем
    /// список заново, а остальные — в основном, и по правилу `.docx`
    /// второй заголовок снова получал «1».
    struct NumberingCounter {
        private var counters: [String: [Int: Int]] = [:]
        /// Перезапуск продолжает общий счёт — правило `.doc`.
        private let restartsSharedCount: Bool
        /// Экземпляры, чей перезапуск уже случился.
        private var restarted: Set<String> = []

        init(restartsSharedCount: Bool = false) {
            self.restartsSharedCount = restartsSharedCount
        }

        mutating func next(
            numID: String, indent: Int, table: NumberingTable, styles: StyleTable = StyleTable()
        ) -> String? {
            guard let level = table.level(numID: numID, indent: indent, styles: styles),
                  let abstract = table.abstract(of: numID, styles: styles) else { return nil }
            // Маркированный список: номера нет, но пункт есть — ставим тире,
            // чтобы список не слился в сплошной текст.
            guard level.format != "bullet" else { return "—" }

            var overrides = table.startOverrides[numID]
            var key = overrides == nil ? "abstract:" + abstract : "num:" + numID
            if restartsSharedCount, let own = overrides {
                key = "abstract:" + abstract
                if restarted.insert(numID).inserted {
                    // Первый абзац экземпляра: его уровень и глубже
                    // начинаются заново, с номера экземпляра. Верхние уровни
                    // идут дальше общим счётом, хотя «начать заново» Word
                    // пишет на все девять: пункт, перезапущенный посреди
                    // раздела 4.1, — «4.1.1», а не «1.1.1», и следующий
                    // заголовок раздела — «4.1.10» (проверено по оглавлению).
                    let restarting = own.filter { $0.key >= indent }
                    var shared = counters[key] ?? [:]
                    for position in restarting.keys { shared[position] = nil }
                    counters[key] = shared
                    overrides = restarting
                } else {
                    overrides = nil
                }
            }
            var levels = counters[key] ?? [:]
            func start(_ position: Int) -> Int {
                overrides?[position] ?? table.level(numID: numID, indent: position, styles: styles)?.start ?? 1
            }
            levels[indent] = (levels[indent] ?? start(indent) - 1) + 1
            // Уровни глубже текущего начинаются заново.
            for deeper in levels.keys where deeper > indent { levels[deeper] = nil }

            var result = level.text.isEmpty ? "%\(indent + 1)." : level.text
            for position in (0...indent).reversed() {
                let shown = table.level(numID: numID, indent: position, styles: styles)
                // Верхний уровень, ещё не встречавшийся, в номере стоит своим
                // начальным значением — и с этой минуты он начат: следующий
                // пункт этого уровня получит следующий номер. Так считает Word
                // («2.2.1» без пункта «2.2» перед ним, а за ним — «2.3»).
                if levels[position] == nil, result.contains("%\(position + 1)") {
                    levels[position] = start(position)
                }
                let value = levels[position] ?? start(position)
                let format = level.isLegal ? "decimal" : (shown?.format ?? "decimal")
                result = result.replacingOccurrences(of: "%\(position + 1)", with: Self.format(value, as: format))
            }
            counters[key] = levels
            return result.trimmingCharacters(in: .whitespaces)
        }

        static func format(_ value: Int, as format: String) -> String {
            switch format {
            case "none": return ""
            case "decimalZero": return value < 10 && value >= 0 ? "0\(value)" : String(value)
            case "lowerLetter": return letter(value, uppercase: false)
            case "upperLetter": return letter(value, uppercase: true)
            case "lowerRoman": return roman(value).lowercased()
            case "upperRoman": return roman(value)
            case "russianLower": return russian(value, uppercase: false)
            case "russianUpper": return russian(value, uppercase: true)
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

        /// Буквы русского списка — без «ё», «й», «ъ», «ы», «ь», как у Word:
        /// пунктов «й)» и «ь)» в документах не бывает.
        private static let russianLetters = Array("абвгдежзиклмнопрстуфхцчшщэюя")

        private static func russian(_ value: Int, uppercase: Bool) -> String {
            guard value > 0 else { return "" }
            let index = (value - 1) % russianLetters.count
            let repeats = (value - 1) / russianLetters.count + 1
            let letter = String(repeating: String(russianLetters[index]), count: repeats)
            return uppercase ? letter.uppercased() : letter
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
    /// Знак, который Word пишет элементом, а не текстом прогона.
    ///
    /// - `w:noBreakHyphen` — неразрывный дефис: «№ 99-ФЗ». Без него в базу
    ///   шло «99ФЗ», и закон не находился по своему номеру (315 мест в пяти
    ///   файлах корпуса).
    /// - `w:sym` — знак символьного шрифта: стрелки и маркеры Wingdings,
    ///   «≤» и «±» из Symbol.
    /// - `w:softHyphen` — мягкий перенос: в тексте его не видно.
    static func inlineCharacter(_ element: String, attributes: [String: String]) -> String? {
        switch element {
        case "w:noBreakHyphen":
            return "-"
        case "w:sym":
            guard let raw = attributes["w:char"], let code = UInt32(raw, radix: 16) else { return nil }
            let font = attributes["w:font"]?.lowercased() ?? ""
            let symbolic = font.hasPrefix("symbol") || font.hasPrefix("wingdings") || font.hasPrefix("webdings")
            // В обычном шрифте код — сам знак Юникода: «Вставка → Символ»
            // в Times New Roman пишет «№» как `2116`. Через таблицу Symbol по
            // младшему байту он пропадал.
            if !symbolic, !(0xF000...0xF0FF).contains(code), code >= 0x20, let scalar = Unicode.Scalar(code) {
                return String(Character(scalar))
            }
            // Символьный шрифт: код пишется и как `F0E0`, и как `E0` —
            // значим младший байт.
            let character = TextNormalization.symbolCharacter(UInt8(code & 0xFF), font: attributes["w:font"])
            return character.map(String.init)
        default:
            return nil
        }
    }

    /// Ключ концевой сноски — отдельно от обычных: у них свой счёт.
    static func endnoteKey(_ id: String) -> String { "endnote:\(id)" }

    /// Номер сноски, как его видит человек, и концевая ли она.
    static func noteLabel(_ key: String) -> (number: String, isEndnote: Bool) {
        let prefix = endnoteKey("")
        return key.hasPrefix(prefix) ? (String(key.dropFirst(prefix.count)), true) : (key, false)
    }
}

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
        /// Внутри удалённого правкой фрагмента (`w:del`).
        private var deletedDepth = 0

        // Таблицы
        //
        // Состояние — **на каждый уровень** вложенности. Раньше номер
        // колонки был один на все таблицы, и после вложенной таблицы внешняя
        // продолжала счёт с её последней колонки.
        private struct TableLevel {
            var id: Int
            var row = -1
            /// Где начинается текущая ячейка, сколько колонок она занимает
            /// и где начнётся следующая. Раздельно: `w:gridSpan` стоит
            /// в свойствах ячейки **до** её текста, и прибавленный сразу
            /// к номеру колонки, он ставил текст в последнюю колонку
            /// объединения, а не в первую.
            var column = 0
            var span = 1
            var next = 0
            var continuation = false
            var rowIsHeader = false
        }
        private var tables: [TableLevel] = []
        private var tableCount = 0

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
            /// Нумерация из разметки самого абзаца. `indent` без `numID` —
            /// абзац меняет только уровень номера, данного стилем.
            var numID: String?
            var indent: Int?
            var links: [String] = []
            var footnotes: [String] = []
            var comments: [String] = []
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
            case _ where Self.skipped.contains(element):
                skipDepth = 1
                if Self.revisionRecords.contains(element) { sawRevisions = true }
            case "w:ins":
                sawRevisions = true
            case "w:del":
                sawRevisions = true
                deletedDepth += 1
            case "w:commentRangeStart", "w:commentReference":
                if let id = attributes["w:id"] {
                    commentReferences.insert(id)
                    // Место замечания — абзац, где стоит его отметка.
                    stack.mutateLast { if !$0.comments.contains(id) { $0.comments.append(id) } }
                }
            case "w:tbl":
                sawTables = true
                tableCount += 1
                tables.append(TableLevel(id: tableCount))
            case "w:tr":
                tables.mutateLast {
                    $0.row += 1
                    $0.next = 0
                    $0.rowIsHeader = false
                }
            case "w:gridBefore":
                // Строка начинается не с первой колонки сетки: пропущенные
                // клетки пусты, но место занимают. Без этого строка съезжала
                // влево на столько колонок, сколько пропущено.
                let skipped = attributes["w:val"].flatMap(Int.init) ?? 0
                tables.mutateLast { $0.next += max(0, skipped) }
            case "w:tblHeader":
                let value = attributes["w:val"] ?? "1"
                tables.mutateLast { $0.rowIsHeader = value != "0" && value != "false" }
            case "w:tc":
                tables.mutateLast {
                    $0.column = $0.next
                    $0.span = 1
                    $0.continuation = false
                }
            case "w:vMerge":
                // Без `w:val` — продолжение объединения; `restart` — его начало.
                let continuation = (attributes["w:val"] ?? "continue") != "restart"
                tables.mutateLast { $0.continuation = continuation }
            case "w:gridSpan":
                let span = attributes["w:val"].flatMap(Int.init) ?? 1
                tables.mutateLast { $0.span = max(1, span) }
            case "w:p":
                var builder = Builder()
                // Абзац вложенной таблицы — текст **клетки внешней**: строка
                // и колонка у таблицы в клетке свои, и отдельной таблицей она
                // разрывала внешнюю надвое. Так же поступает HTML.
                if let outer = tables.first {
                    builder.cell = Cell(
                        table: outer.id, row: max(0, outer.row), column: outer.column,
                        isVerticalContinuation: outer.continuation,
                        columnSpan: outer.span, isHeaderRow: outer.rowIsHeader
                    )
                }
                stack.append(builder)
            case "w:pStyle": stack.mutateLast { $0.styleID = attributes["w:val"] }
            case "w:outlineLvl":
                let value = attributes["w:val"].flatMap(Int.init)
                stack.mutateLast { $0.outlineLevel = value.map { $0 + 1 } }
            case "w:numPr": stack.mutateLast { $0.numID = nil; $0.indent = nil }
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
                if let raw = attributes["w:id"] {
                    let id = element == "w:endnoteReference" ? DocxPartsReader.endnoteKey(raw) : raw
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
            case "w:noBreakHyphen", "w:sym":
                // Удалённый правкой текст лежит в `w:delText` и не берётся;
                // знак-элемент в том же удалённом прогоне — тоже.
                if deletedDepth == 0,
                   let character = DocxPartsReader.inlineCharacter(element, attributes: attributes) {
                    append(character)
                }
            case "w:br", "w:cr":
                stack.mutateLast { $0.text += "\n" }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard capturing, skipDepth == 0 else { return }
            append(string)
        }

        /// Текст прогона — в абзац, со счётом видимых, скрытых и жирных знаков.
        private func append(_ string: String) {
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
            case "w:del": deletedDepth = max(0, deletedDepth - 1)
            case "w:pPr": insideParagraphProperties = false
            case "w:r":
                runIsHidden = false
                runIsBold = false
                runSize = nil
            case "w:tc":
                tables.mutateLast { $0.next = $0.column + $0.span }
            case "w:tbl":
                _ = tables.popLast()
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
            // Счёт идёт и по пустым, и по скрытым абзацам: Word их считает,
            // и без них пункты после скрытого шли со сдвигом — «3.1» там,
            // где документ и его оглавление пишут «6.1».
            var marker: String?
            if let (numID, indent) = numbering(of: builder) {
                marker = counter.next(numID: numID, indent: indent, table: numbering, styles: styles)
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
                if !builder.comments.isEmpty {
                    paragraphs.mutateLast { $0.comments += builder.comments }
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
                comments: builder.comments,
                isBold: builder.visibleCharacters > 0 && builder.boldCharacters == builder.visibleCharacters,
                size: builder.sizes.max { $0.value < $1.value }?.key,
                isTableOfContents: builder.cell == nil && builder.styleID.map(styles.tableOfContents.contains) == true
            ))
        }

        /// Номер абзаца: из его разметки, а если её нет — из стиля
        /// (ECMA-376, 17.3.1.19). `numId` "0" снимает нумерацию.
        ///
        /// Уровень абзаца, нумерованного стилем, — тот, что связан с этим
        /// стилем в определении списка (`w:lvl/w:pStyle`); `w:ilvl` в стиле
        /// по стандарту не учитывается и берётся, только если связи нет.
        private func numbering(of builder: Builder) -> (numID: String, indent: Int)? {
            let style = builder.styleID.flatMap { styles.numbering(ofStyle: $0) }
            guard let numID = builder.numID ?? style?.numID, numID != "0" else { return nil }
            if let indent = builder.indent { return (numID, indent) }
            if builder.numID == nil, let styleID = builder.styleID {
                let linked = numbering.indent(numID: numID, paragraphStyle: styleID, styles: styles)
                return (numID, linked ?? style?.indent ?? 0)
            }
            return (numID, 0)
        }

        /// Элементы, чьё содержимое в документе не видно.
        static let skipped = Set(["mc:Fallback", "w:instrText", "w:delText", "w:proofErr"])
            .union(revisionRecords)

        /// Записи правок: прежнее состояние, а не нынешнее.
        ///
        /// `w:moveFrom` — перенесённый **отсюда** текст, и лежит он в обычных
        /// `w:t`: без пропуска абзац, перенесённый при включённых правках,
        /// попадал в базу дважды. `…PrChange` хранят прежние свойства и
        /// разбираются **после** нынешних — прежний стиль «Заголовок 1»
        /// затирал нынешний «Обычный», и абзац резал нарезку как заголовок.
        static let revisionRecords: Set<String> = [
            "w:moveFrom", "w:pPrChange", "w:rPrChange", "w:sectPrChange",
            "w:tblPrChange", "w:tblPrExChange", "w:trPrChange", "w:tcPrChange", "w:numberingChange",
        ]
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
                    if let character = DocxPartsReader.inlineCharacter(element, attributes: attributes) {
                        current += character
                    }
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
                    case "w:noBreakHyphen", "w:sym":
                        text += DocxPartsReader.inlineCharacter(element, attributes: attributes) ?? ""
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
                    case "w:noBreakHyphen", "w:sym":
                        text += DocxPartsReader.inlineCharacter(element, attributes: attributes) ?? ""
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
