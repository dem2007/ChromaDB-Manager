import Foundation

/// Разбор `robots.txt`.
///
/// Свой, без библиотек (правило 6). Формат маленький, но с ловушками, и каждая
/// из них — это чужой сервер, к которому мы придём туда, куда нас не звали.
public struct RobotsTxt: Sendable, Hashable {
    /// Правила группы, к которой мы относимся.
    public struct Group: Sendable, Hashable {
        public var allow: [String] = []
        public var disallow: [String] = []
        public var crawlDelay: TimeInterval?

        public init(allow: [String] = [], disallow: [String] = [], crawlDelay: TimeInterval? = nil) {
            self.allow = allow
            self.disallow = disallow
            self.crawlDelay = crawlDelay
        }
    }

    public var group: Group
    /// Карты сайта — они предпочтительнее обхода по ссылкам: быстрее, вежливее,
    /// полнее.
    public var sitemaps: [String]
    /// Файла не было или он не прочитался. Тогда запрещать нечего — но и
    /// молчать об этом не следует: «robots.txt недоступен» и «robots.txt
    /// разрешает всё» — разные новости.
    public var isMissing: Bool

    public init(group: Group = Group(), sitemaps: [String] = [], isMissing: Bool = false) {
        self.group = group
        self.sitemaps = sitemaps
        self.isMissing = isMissing
    }

    public static let missing = RobotsTxt(isMissing: true)

    /// Разбирает файл для конкретного агента.
    ///
    /// Правила действуют по самой **точной** подходящей группе: если есть
    /// группа для нашего имени, группа `*` не применяется вовсе. Так велит
    /// стандарт, и путать это опасно в обе стороны.
    public static func parse(_ text: String, userAgent: String) -> RobotsTxt {
        let ourName = userAgent.split(separator: "/").first.map(String.init)?.lowercased()
            ?? userAgent.lowercased()

        var groups: [String: Group] = [:]
        var currentAgents: [String] = []
        var sitemaps: [String] = []
        /// Строки `User-agent` идут подряд — и все относятся к одной группе.
        var expectingAgents = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // Комментарий может стоять и в конце строки.
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let colon = line.firstIndex(of: ":") else { continue }
            let field = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

            switch field {
            case "user-agent":
                if !expectingAgents { currentAgents = [] }
                expectingAgents = true
                let name = value.lowercased()
                currentAgents.append(name)
                if groups[name] == nil { groups[name] = Group() }
            case "sitemap":
                if !value.isEmpty { sitemaps.append(value) }
            case "allow", "disallow", "crawl-delay":
                expectingAgents = false
                for agent in currentAgents {
                    var group = groups[agent] ?? Group()
                    switch field {
                    case "allow": if !value.isEmpty { group.allow.append(value) }
                    // Пустой `Disallow:` — это «разрешено всё», а не «запрещён
                    // корень». Перепутать значит либо не индексировать ничего,
                    // либо индексировать всё вопреки запрету.
                    case "disallow": if !value.isEmpty { group.disallow.append(value) }
                    default: group.crawlDelay = TimeInterval(value.replacingOccurrences(of: ",", with: "."))
                    }
                    groups[agent] = group
                }
            default:
                continue
            }
        }

        // Наиболее точная подходящая группа: наше имя, иначе `*`.
        let chosen = groups.first { key, _ in ourName.hasPrefix(key) && key != "*" }?.value
            ?? groups["*"]
            ?? Group()
        return RobotsTxt(group: chosen, sitemaps: sitemaps)
    }

    /// Можно ли обращаться по этому пути.
    ///
    /// При равной длине побеждает `Allow` — так разрешают спорные случаи
    /// и Google, и черновик стандарта: запрет по ошибке дороже разрешения.
    public func allows(path: String) -> Bool {
        let target = path.isEmpty ? "/" : path
        let bestDisallow = group.disallow.filter { Self.matches(pattern: $0, path: target) }
            .map(\.count).max()
        guard let bestDisallow else { return true }
        let bestAllow = group.allow.filter { Self.matches(pattern: $0, path: target) }
            .map(\.count).max() ?? -1
        return bestAllow >= bestDisallow
    }

    public func allows(url: URL) -> Bool {
        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty { path += "?" + query }
        return allows(path: path)
    }

    /// Сопоставление с учётом `*` и `$` — они встречаются в каждом втором файле.
    static func matches(pattern: String, path: String) -> Bool {
        var anchored = false
        var body = pattern
        if body.hasSuffix("$") {
            anchored = true
            body.removeLast()
        }
        let parts = body.components(separatedBy: "*")
        var index = path.startIndex
        for (number, part) in parts.enumerated() {
            if part.isEmpty {
                if number == parts.count - 1, anchored { return true }
                continue
            }
            if number == 0 {
                guard path[index...].hasPrefix(part) else { return false }
                index = path.index(index, offsetBy: part.count)
            } else {
                guard let found = path[index...].range(of: part) else { return false }
                index = found.upperBound
            }
        }
        return anchored ? index == path.endIndex : true
    }
}
