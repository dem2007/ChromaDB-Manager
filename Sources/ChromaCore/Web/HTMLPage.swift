import Foundation

/// Страница, разобранная в текст и структуру.
public struct HTMLPage: Sendable, Hashable {
    public var title: String?
    /// `<link rel="canonical">`, если он есть. По нему считается идентификатор
    /// документа: одна и та же страница по трём адресам иначе станет тремя.
    public var canonicalURL: String?
    public var plainText: String
    /// Заголовки `h1`–`h6` — то, из чего получается `structure` (11.1),
    /// а значит и Document-based чанкинг для веба.
    public var headings: [DocumentNode]
    /// Ссылки со страницы, как они в ней записаны, — для обхода сайта.
    public var links: [String]
    /// Те же ссылки, но с местом в тексте и уже абсолютные, — для метаданных
    /// чанка. Повторы здесь **остаются**: одна и та же ссылка,
    /// стоящая в двух местах, принадлежит двум разным чанкам.
    public var placedLinks: [DocumentLink] = []
    /// Язык из `<html lang>`, если объявлен.
    public var language: String?
    /// Описание из `<meta name="description">` — им подписывают страницу
    /// в списке источника.
    public var summary: String?
    /// На странице есть таблица. Без этого признака фильтр «документы
    /// с таблицами» не видел ни одной веб-страницы.
    public var hasTables: Bool = false

    public init(
        title: String? = nil,
        canonicalURL: String? = nil,
        plainText: String,
        headings: [DocumentNode] = [],
        links: [String] = [],
        language: String? = nil,
        summary: String? = nil
    ) {
        self.title = title
        self.canonicalURL = canonicalURL
        self.plainText = plainText
        self.headings = headings
        self.links = links
        self.language = language
        self.summary = summary
    }

    /// Похоже ли, что страница рисуется скриптом.
    ///
    /// Успешный ответ и пустой текст — это не «пустая страница», а чаще всего
    /// приложение, которое рисует себя в браузере. Спецификация требует
    /// отправлять такое в «требуют решения» с точной причиной, а не молча
    /// индексировать пустоту.
    public var looksScriptRendered: Bool {
        plainText.trimmingCharacters(in: .whitespacesAndNewlines).count < 40
    }
}

/// Разбор HTML без единой сторонней библиотеки (правило 6 приложения 5).
///
/// **Не `NSAttributedString` с `.html`**, хотя спецификация называет именно его.
/// Импортёр HTML у `NSAttributedString` обязан работать на главном потоке —
/// вызванный с другого, он пытается синхронизироваться с ним, не может и
/// отваливается по таймауту. Для обхода сайта в двести страниц это означало бы
/// либо занятый на минуты интерфейс, либо неработающий обход. И заголовки он
/// всё равно теряет, а без них не будет ни `structure`, ни Document-based
/// чанкинга — то есть за разметкой пришлось бы лезть вторым разбором.
/// `XMLDocument` в режиме `.documentTidyHTML` даёт и то и другое, и работает
/// в любом потоке.
public enum HTMLParser {
    /// Блоки, которые выкидываются до извлечения текста: в них никогда нет
    /// содержания страницы, зато всегда есть меню, которое иначе попадёт
    /// в каждый чанк.
    static let ignoredElements: Set<String> = [
        "script", "style", "nav", "header", "footer", "aside", "noscript",
        "svg", "form", "iframe", "template", "figure",
    ]

    public enum ParseError: LocalizedError {
        case notHTML

        public var errorDescription: String? {
            String(localized: "Ответ не разобрался как HTML.")
        }
    }

    /// Разбирает страницу, полученную из сети.
    ///
    /// - Parameter contentType: заголовок ответа целиком — из него берётся
    ///   объявленная кодировка. Она главнее того, что написано в самой
    ///   странице: так велит HTTP, и так же ведут себя браузеры.
    public static func parse(
        _ data: Data, contentType: String? = nil, baseURL: URL? = nil
    ) throws -> HTMLPage {
        try parse(decode(data, contentType: contentType), baseURL: baseURL)
    }

    /// Вырезает служебные блоки **до** разбора.
    ///
    /// Приходится делать это по тексту, а не по дереву: tidy на macOS — эпохи
    /// HTML 4 и приводит документ к XHTML 1.0, где нет ни `nav`, ни `header`,
    /// ни `footer`, ни `main`. Он их **разворачивает**: элементы исчезают, а их
    /// содержимое остаётся, и к моменту обхода дерева выбрасывать уже нечего —
    /// меню сайта оказывается в тексте каждой страницы. Проверено на разборе,
    /// а не выведено из документации.
    ///
    /// Сканер простой и намеренно осторожный: если закрывающего тега нет,
    /// не вырезается ничего. Испортить страницу — хуже, чем оставить в ней
    /// лишний блок.
    static func stripIgnoredBlocks(_ html: String) -> String {
        var result = html
        for tag in ignoredElements.sorted() {
            result = removeBlocks(named: tag, from: result)
        }
        return result
    }

    private static func removeBlocks(named tag: String, from html: String) -> String {
        var result = ""
        var rest = Substring(html)
        while let open = rest.range(of: "<\(tag)", options: .caseInsensitive) {
            // «<form» не должно съедать «<formula»: за именем тега обязан идти
            // пробел, `>` или `/`.
            let after = rest[open.upperBound...].first
            guard after == nil || after == ">" || after == "/" || after == " " || after == "\n" || after == "\t" else {
                result += rest[..<open.upperBound]
                rest = rest[open.upperBound...]
                continue
            }
            guard let close = rest.range(of: "</\(tag)", options: .caseInsensitive, range: open.upperBound..<rest.endIndex),
                  let end = rest.range(of: ">", range: close.upperBound..<rest.endIndex) else {
                break
            }
            result += rest[..<open.lowerBound]
            // Разрыв на месте вырезанного: без него соседние слова склеятся.
            result += "\n"
            rest = rest[end.upperBound...]
        }
        result += rest
        return result
    }

    public static func parse(_ html: String, baseURL: URL? = nil) throws -> HTMLPage {
        // `.documentTidyHTML` — тот самый толерантный разбор: настоящий HTML
        // в интернете почти никогда не является правильным XML.
        //
        // **Из строки, а не из `Data`.** Разбор байтов молча теряет кириллицу:
        // tidy решает про кодировку сам и решает неправильно — «Первый»
        // приезжает пустотой или «ÐŸÐµÑ€Ð²Ñ‹Ð¹», и никакой ошибки при этом нет.
        // Найдено первым же тестом на русской странице.
        let document: XMLDocument
        do {
            document = try XMLDocument(
                xmlString: stripIgnoredBlocks(html), options: [.documentTidyHTML, .nodePreserveCDATA]
            )
        } catch {
            throw ParseError.notHTML
        }
        guard let root = document.rootElement() else { throw ParseError.notHTML }

        var page = HTMLPage(plainText: "")
        page.title = text(ofFirst: "//title", in: document)
        page.language = attribute("lang", ofFirst: "//html", in: document)
        page.summary = attribute("content", ofFirst: "//meta[@name='description']", in: document)
        page.canonicalURL = attribute("href", ofFirst: "//link[@rel='canonical']", in: document)
            .flatMap { absolute($0, base: baseURL) }

        let body = (try? document.nodes(forXPath: "//body").first) as? XMLElement
        var builder = TextBuilder()
        collect(body ?? root, into: &builder)
        page.plainText = builder.finish()
        page.headings = builder.headings
        page.hasTables = builder.sawTable
        // Повторы убираются **после** приведения к абсолютным: «/guide#part1»
        // и «/guide#part2» — разные строки и одна страница.
        var seen = Set<String>()
        page.links = builder.links.compactMap { absolute($0, base: baseURL) }
            .filter { seen.insert($0).inserted }
        // А здесь повторы нужны: ссылка, стоящая в двух местах страницы,
        // принадлежит двум разным чанкам. Ссылка внутрь той же
        // страницы (`#часть`) источником не является.
        page.placedLinks = builder.placed.compactMap { link in
            guard !link.url.hasPrefix("#"), let url = absolute(link.url, base: baseURL) else {
                return nil
            }
            return DocumentLink(url: url, start: link.start)
        }

        // Верхний заголовок часто лежит в `<header>` — так устроена и Википедия,
        // и половина шаблонов CMS, — а `<header>` мы вырезаем вместе с меню.
        // Без него у страницы нет корневого раздела, и Document-based чанкинг
        // режет её как один безымянный кусок. Название страницы для этой роли
        // годится: оно и есть её заголовок.
        if let title = page.title, !title.isEmpty,
           !page.headings.contains(where: { $0.level == 1 }), !page.plainText.isEmpty {
            page.headings.insert(DocumentNode(level: 1, title: title, start: 0), at: 0)
        }
        return page
    }

    // MARK: - Обход дерева

    private struct TextBuilder {
        private var text = ""
        private(set) var headings: [DocumentNode] = []
        private(set) var links: [String] = []
        /// Те же ссылки, но с местом в тексте — для метаданных чанка.
        private(set) var placed: [DocumentLink] = []
        /// На странице была таблица — из этого получается `has_tables`.
        var sawTable = false
        /// Нужен ли разрыв перед следующим куском текста. Не пишется сразу:
        /// иначе пустой блок оставит после себя лишнюю пустую строку.
        private var pendingBreak: String?

        mutating func append(_ piece: String) {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if !text.isEmpty, let pendingBreak { text += pendingBreak }
            else if !text.isEmpty, pendingBreak == nil { text += " " }
            pendingBreak = nil
            text += trimmed
        }

        mutating func breakLine(_ separator: String = "\n") {
            guard !text.isEmpty else { return }
            // Более крупный разрыв побеждает: абзац после переноса строки
            // остаётся абзацем.
            if let existing = pendingBreak, existing.count >= separator.count { return }
            pendingBreak = separator
        }

        mutating func heading(level: Int, title: String) {
            breakLine("\n\n")
            // Позиция считается по тексту, который уже накоплен, **с учётом**
            // отложенного разрыва: иначе заголовок указывал бы на конец
            // предыдущего абзаца, и раздел начинался бы на строку раньше.
            let start = text.isEmpty ? 0 : text.count + (pendingBreak?.count ?? 0)
            headings.append(DocumentNode(level: level, title: title, start: start))
            append(title)
            breakLine("\n\n")
        }

        mutating func link(_ href: String) {
            links.append(href)
            // Место ссылки в тексте — тем же счётом, что у заголовка: с учётом
            // отложенного разрыва, иначе ссылка указывала бы на конец
            // предыдущего абзаца.
            placed.append(DocumentLink(
                url: href, start: text.isEmpty ? 0 : text.count + (pendingBreak?.count ?? 0)
            ))
        }

        /// Вложенные перечисления: `nil` — маркированное, число — счётчик
        /// нумерованного. Стопкой, потому что списки вкладываются друг в друга.
        private var lists: [Int?] = []

        mutating func openList(ordered: Bool) { lists.append(ordered ? 0 : nil) }
        mutating func closeList() { if !lists.isEmpty { lists.removeLast() } }

        /// Маркер очередного пункта — тем же видом, каким его пишет Word
        ///: «—» у маркированного, «1.» у нумерованного.
        ///
        /// До этого пункты HTML приходили голым текстом, без всякого признака
        /// перечисления, и правило «вводная фраза списка» их не узнавало
        /// вовсе — то есть работало на Markdown и Word, но не на вебе.
        mutating func item() {
            guard !lists.isEmpty else { return }
            if let number = lists[lists.count - 1] {
                lists[lists.count - 1] = number + 1
                append("\(number + 1).")
            } else {
                append("—")
            }
        }

        mutating func finish() -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func collect(_ node: XMLNode, into builder: inout TextBuilder) {
        if let element = node as? XMLElement {
            let name = (element.name ?? "").lowercased()
            guard !ignoredElements.contains(name) else { return }

            if let href = element.attribute(forName: "href")?.stringValue, name == "a" {
                builder.link(href)
            }

            if name.count == 2, name.hasPrefix("h"), let level = Int(name.dropFirst()),
               (1...6).contains(level) {
                builder.heading(level: level, title: plainText(of: element))
                return
            }

            // Таблица целиком — разметкой Markdown, тем же видом, что у книги
            // Excel, Word и PDF (11.13). Раньше ячейки разделялись
            // пробелом: колонки от слов становились неотличимы, и шапку
            // таблицы нельзя было ни узнать, ни повторить в куске.
            if name == "table" {
                let rows = tableRows(of: element)
                if rows.count > 1 {
                    builder.breakLine("\n\n")
                    builder.sawTable = true
                    // Ссылки из ячеек — **до** выхода: дальше по дереву обход
                    // не пойдёт, а у каталога ссылки на товары живут именно
                    // в таблице. Без этого обход сайта переставал их видеть,
                    // и страницы товаров молча не индексировались.
                    for href in links(in: element) { builder.link(href) }
                    builder.append(TableText.render(rows))
                    builder.breakLine("\n\n")
                    return
                }
            }

            // Перечисление открывается до обхода детей и закрывается после,
            // иначе вложенный список сбил бы счёт внешнему.
            if name == "ul" || name == "ol" {
                builder.breakLine("\n\n")
                builder.openList(ordered: name == "ol")
                for child in element.children ?? [] { collect(child, into: &builder) }
                builder.closeList()
                builder.breakLine("\n\n")
                return
            }

            if name == "li" { builder.breakLine("\n\n"); builder.item() }
            else if blockElements.contains(name) { builder.breakLine("\n\n") }
            else if name == "br" { builder.breakLine("\n") }
            else if name == "td" || name == "th" { builder.breakLine(" ") }
            else if name == "tr" { builder.breakLine("\n") }

            for child in element.children ?? [] { collect(child, into: &builder) }
            if blockElements.contains(name) { builder.breakLine("\n\n") }
            return
        }

        if node.kind == .text, let value = node.stringValue {
            builder.append(value)
        }
    }

    /// Все адреса из поддерева — тем же порядком, каким их встретил бы обход.
    private static func links(in element: XMLElement) -> [String] {
        var result: [String] = []
        func walk(_ node: XMLElement) {
            if (node.name ?? "").lowercased() == "a",
               let href = node.attribute(forName: "href")?.stringValue {
                result.append(href)
            }
            for child in node.children ?? [] {
                guard let child = child as? XMLElement else { continue }
                walk(child)
            }
        }
        walk(element)
        return result
    }

    /// Строки таблицы: по ячейке на клетку, вложенные таблицы разворачиваются
    /// в текст своей клетки.
    private static func tableRows(of table: XMLElement) -> [[String]] {
        var rows: [[String]] = []
        func walk(_ element: XMLElement) {
            for child in element.children ?? [] {
                guard let node = child as? XMLElement else { continue }
                let name = (node.name ?? "").lowercased()
                if name == "tr" {
                    let cells = (node.children ?? []).compactMap { cell -> String? in
                        guard let cell = cell as? XMLElement,
                              ["td", "th"].contains((cell.name ?? "").lowercased())
                        else { return nil }
                        return plainText(of: cell)
                    }
                    if !cells.isEmpty { rows.append(cells) }
                } else {
                    walk(node)
                }
            }
        }
        walk(table)
        return rows
    }

    private static let blockElements: Set<String> = [
        "p", "div", "section", "article", "main", "ul", "ol", "li", "blockquote",
        "pre", "table", "dl", "dt", "dd", "hr",
    ]

    /// Текст элемента без разметки — им подписан заголовок.
    private static func plainText(of element: XMLElement) -> String {
        let raw = element.stringValue ?? ""
        return raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    // MARK: - Мелочи

    private static func text(ofFirst xpath: String, in document: XMLDocument) -> String? {
        guard let node = try? document.nodes(forXPath: xpath).first,
              let value = node.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func attribute(
        _ name: String, ofFirst xpath: String, in document: XMLDocument
    ) -> String? {
        guard let node = try? document.nodes(forXPath: xpath).first,
              let element = node as? XMLElement,
              let value = element.attribute(forName: name)?.stringValue?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    /// Байты страницы в текст.
    ///
    /// Порядок источников кодировки — как у браузера: заголовок ответа,
    /// затем объявление в самой странице, затем UTF-8. Если UTF-8 не сошёлся —
    /// windows-1251: русские сайты в ней ещё живут, и молча испорченный текст
    /// хуже, чем текст, прочитанный по догадке, о которой сказано в логе.
    static func decode(_ data: Data, contentType: String?) -> String {
        if let name = charset(inContentType: contentType),
           let text = string(from: data, charset: name) {
            return text
        }
        // Объявление внутри страницы ищется по первым килобайтам: спецификация
        // HTML требует, чтобы оно стояло в начале, а разбирать весь документ
        // ради этого незачем.
        let head = String(decoding: data.prefix(2048), as: UTF8.self)
        if let declared = declaredCharset(inHead: head), let text = string(from: data, charset: declared) {
            return text
        }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let cp1251 = String(data: data, encoding: .windowsCP1251) { return cp1251 }
        return String(decoding: data, as: UTF8.self)
    }

    static func charset(inContentType header: String?) -> String? {
        guard let header else { return nil }
        guard let range = header.range(of: "charset=", options: .caseInsensitive) else { return nil }
        let tail = header[range.upperBound...]
        let value = tail.prefix { $0 != ";" && $0 != " " }
        return value.isEmpty ? nil : String(value).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }

    private static func declaredCharset(inHead head: String) -> String? {
        // `<meta charset="…">` и старая форма `<meta http-equiv="content-type" content="…charset=…">`.
        if let range = head.range(of: "charset", options: .caseInsensitive) {
            let tail = head[range.upperBound...].drop { $0 == "=" || $0 == "\"" || $0 == "'" || $0 == " " }
            let value = tail.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            if !value.isEmpty { return String(value) }
        }
        return nil
    }

    private static func string(from data: Data, charset: String) -> String? {
        let encoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        )
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        return String(data: data, encoding: String.Encoding(rawValue: encoding))
    }

    /// Ссылка, приведённая к абсолютной. Относительные адреса — обычное дело,
    /// а обходить их без базы нечем.
    static func absolute(_ href: String, base: URL?) -> String? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
              !trimmed.lowercased().hasPrefix("javascript:"),
              !trimmed.lowercased().hasPrefix("mailto:"),
              !trimmed.lowercased().hasPrefix("tel:") else { return nil }
        guard let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        // Якорь — та же страница: обходить его отдельно значит скачать её
        // столько раз, сколько на ней оглавлений.
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url?.absoluteString ?? url.absoluteString
    }
}
