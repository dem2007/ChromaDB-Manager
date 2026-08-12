import Compression
import Foundation

/// Одна запись карты сайта.
public struct SitemapEntry: Sendable, Hashable {
    public var url: String
    /// `lastmod`, если объявлен. Он не заменяет условные запросы, но позволяет
    /// не спрашивать сервер о странице, которая по его же словам не менялась.
    public var lastModified: Date?

    public init(url: String, lastModified: Date? = nil) {
        self.url = url
        self.lastModified = lastModified
    }
}

/// Карта сайта: либо список страниц, либо список других карт.
///
/// Она предпочтительнее обхода по ссылкам — быстрее, вежливее и полнее:
/// страницу, на которую нет ссылок с главной, обход по ссылкам не найдёт вовсе.
public struct Sitemap: Sendable, Hashable {
    public var pages: [SitemapEntry]
    /// Адреса вложенных карт (`<sitemapindex>`). Крупные сайты хранят карту
    /// десятком файлов, и первый из них — только оглавление.
    public var children: [String]

    public init(pages: [SitemapEntry] = [], children: [String] = []) {
        self.pages = pages
        self.children = children
    }

    public var isIndex: Bool { pages.isEmpty && !children.isEmpty }
    public var isEmpty: Bool { pages.isEmpty && children.isEmpty }
}

public enum SitemapParser {
    /// Предел на разжатую карту. Сжатый файл в сотню килобайт разворачивается
    /// в гигабайты, если его таким сделали нарочно, — размер известен заранее,
    /// и проверить его дешевле, чем потом искать, куда делась память.
    public static let maxUncompressedBytes = 64 * 1024 * 1024

    public enum SitemapError: LocalizedError, Equatable {
        case notSitemap
        case tooLarge(Int)

        public var errorDescription: String? {
            switch self {
            case .notSitemap:
                return String(localized: "Файл по адресу карты сайта картой сайта не оказался.")
            case .tooLarge(let size):
                let shown = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                return String(localized: "Карта сайта в разжатом виде занимает \(shown) — это слишком много, чтобы её читать.")
            }
        }
    }

    /// Разбирает карту сайта: XML, XML в gzip или просто список адресов.
    ///
    /// Все три формы разрешены sitemaps.org, и все три встречаются: `.xml.gz`
    /// отдаёт, например, Википедия.
    public static func parse(_ data: Data) throws -> Sitemap {
        let unpacked = try gunzipIfNeeded(data)
        let text = HTMLParser.decode(unpacked, contentType: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SitemapError.notSitemap }
        guard text.hasPrefix("<") else { return plainList(text) }

        guard let document = try? XMLDocument(xmlString: text, options: [.nodePreserveWhitespace]),
              let root = document.rootElement()
        else { throw SitemapError.notSitemap }

        // Обход по именам элементов, а не через XPath: у карт сайта своё
        // пространство имён, и половина сайтов объявляет его по-своему —
        // выражение с префиксом на них молча вернёт пустой список.
        var sitemap = Sitemap()
        collect(root, into: &sitemap)
        guard !sitemap.isEmpty else { throw SitemapError.notSitemap }
        return sitemap
    }

    private static func collect(_ element: XMLElement, into sitemap: inout Sitemap) {
        switch element.localName?.lowercased() {
        case "url":
            if let location = childText(element, "loc") {
                sitemap.pages.append(
                    SitemapEntry(url: location, lastModified: date(childText(element, "lastmod")))
                )
            }
        case "sitemap":
            if let location = childText(element, "loc") { sitemap.children.append(location) }
        default:
            for child in element.children ?? [] {
                if let child = child as? XMLElement { collect(child, into: &sitemap) }
            }
        }
    }

    private static func childText(_ element: XMLElement, _ name: String) -> String? {
        for child in element.children ?? [] {
            guard let child = child as? XMLElement, child.localName?.lowercased() == name else { continue }
            let value = (child.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// Карта в виде списка адресов, по одному на строку, — тоже законный формат.
    private static func plainList(_ text: String) -> Sitemap {
        let pages = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
            .map { SitemapEntry(url: $0) }
        return Sitemap(pages: pages)
    }

    /// `lastmod` записывается по W3C: и полной датой со временем, и одной датой.
    static func date(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(secondsFromGMT: 0)
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: value)
    }

    // MARK: - gzip

    /// Разжимает, если это gzip, и возвращает как есть, если нет.
    ///
    /// Своими руками: в системе есть только «сырой» deflate, а gzip — это он же
    /// с заголовком и хвостом. Заголовок разбирается по флагам, длина берётся
    /// из хвоста — она там записана специально для этого.
    static func gunzipIfNeeded(_ data: Data) throws -> Data {
        let bytes = [UInt8](data.prefix(3))
        guard bytes.count >= 3, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 0x08 else { return data }
        guard data.count > 18 else { throw SitemapError.notSitemap }

        let all = [UInt8](data)
        let flags = all[3]
        var offset = 10
        if flags & 0b0000_0100 != 0 {  // FEXTRA
            guard offset + 2 <= all.count else { throw SitemapError.notSitemap }
            offset += 2 + Int(all[offset]) + Int(all[offset + 1]) << 8
        }
        if flags & 0b0000_1000 != 0 {  // FNAME — строка до нуля
            while offset < all.count, all[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0b0001_0000 != 0 {  // FCOMMENT
            while offset < all.count, all[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0b0000_0010 != 0 { offset += 2 }  // FHCRC
        guard offset < all.count - 8 else { throw SitemapError.notSitemap }

        // Последние четыре байта — длина исходных данных. Проверяется **до**
        // выделения памяти, иначе проверка бессмысленна.
        let tail = all.suffix(4)
        let size = tail.enumerated().reduce(0) { $0 + Int($1.element) << (8 * $1.offset) }
        guard size > 0 else { throw SitemapError.notSitemap }
        guard size <= maxUncompressedBytes else { throw SitemapError.tooLarge(size) }

        // Из массива, а не из `data.subdata`: `offset` посчитан по `all`,
        // который всегда начинается с нуля, а у среза `Data` индексы
        // начинаются с `startIndex`. Смешав их, разжатие пошло бы по чужим
        // байтам — молча, без падения, потому что диапазон при этом обычно
        // остаётся допустимым.
        let payload = Data(all[offset..<(all.count - 8)])
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let base = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return payload.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(base, size, sourceBase, payload.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw SitemapError.notSitemap }
        return output
    }
}
