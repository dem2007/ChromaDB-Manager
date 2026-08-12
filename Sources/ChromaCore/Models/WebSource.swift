import Foundation

/// Настройки веб-источника.
///
/// Живут на источнике, а не спрашиваются перед каждым запуском: сайт, который
/// перечитывается по расписанию, спросить некого.
public struct WebSourceSettings: Codable, Hashable, Sendable {
    /// Три вида веб-источника из I1.1.
    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Одна страница, перечитывается по расписанию.
        case page
        /// Набор адресов, введённых вручную.
        case list
        /// Обход от стартового адреса с обязательными ограничениями.
        case site

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .page: return String(localized: "Одна страница")
            case .list: return String(localized: "Список адресов")
            case .site: return String(localized: "Обход сайта")
            }
        }

        public var explanation: String {
            switch self {
            case .page:
                return String(localized: "Один адрес. Перечитывается целиком, ссылки не обходятся.")
            case .list:
                return String(localized: "Несколько адресов, по одному в строке. Каждый читается сам по себе, ссылки не обходятся.")
            case .site:
                return String(localized: "От стартового адреса по ссылкам или по карте сайта — в пределах ограничений ниже.")
            }
        }
    }

    public var kind: Kind
    /// Стартовый адрес — он же единственный для одиночной страницы.
    public var startURL: String
    /// Дополнительные адреса для списка.
    public var additionalURLs: [String]
    public var maxDepth: Int
    public var maxPages: Int
    public var delaySeconds: Double
    public var maxTotalMegabytes: Int
    /// Домены, кроме исходного, куда обходу разрешено выходить.
    public var extraHosts: [String]
    /// Снимается только для собственных доменов и только сознательно.
    public var respectsRobots: Bool
    public var usesSitemap: Bool

    public init(
        kind: Kind = .page,
        startURL: String = "",
        additionalURLs: [String] = [],
        maxDepth: Int = 2,
        maxPages: Int = 200,
        delaySeconds: Double = 1,
        maxTotalMegabytes: Int = 200,
        extraHosts: [String] = [],
        respectsRobots: Bool = true,
        usesSitemap: Bool = true
    ) {
        self.kind = kind
        self.startURL = startURL
        self.additionalURLs = additionalURLs
        self.maxDepth = maxDepth
        self.maxPages = maxPages
        self.delaySeconds = delaySeconds
        self.maxTotalMegabytes = maxTotalMegabytes
        self.extraHosts = extraHosts
        self.respectsRobots = respectsRobots
        self.usesSitemap = usesSitemap
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = ((try? container.decodeIfPresent(Kind.self, forKey: .kind)) ?? nil) ?? .page
        startURL = try container.decodeIfPresent(String.self, forKey: .startURL) ?? ""
        additionalURLs = try container.decodeIfPresent([String].self, forKey: .additionalURLs) ?? []
        maxDepth = try container.decodeIfPresent(Int.self, forKey: .maxDepth) ?? 2
        maxPages = try container.decodeIfPresent(Int.self, forKey: .maxPages) ?? 200
        delaySeconds = try container.decodeIfPresent(Double.self, forKey: .delaySeconds) ?? 1
        maxTotalMegabytes = try container.decodeIfPresent(Int.self, forKey: .maxTotalMegabytes) ?? 200
        extraHosts = try container.decodeIfPresent([String].self, forKey: .extraHosts) ?? []
        respectsRobots = try container.decodeIfPresent(Bool.self, forKey: .respectsRobots) ?? true
        usesSitemap = try container.decodeIfPresent(Bool.self, forKey: .usesSitemap) ?? true
    }

    public var start: URL? { Self.address(startURL) }

    /// Адреса, кроме стартового, которые надо прочитать.
    public var seeds: [URL] {
        guard kind == .list else { return [] }
        return additionalURLs.compactMap(Self.address)
    }

    /// Ограничения для обхода. Для одиночной страницы и списка они жёсткие:
    /// ходить по ссылкам такой источник не должен вовсе, чего бы ни было
    /// записано в полях обхода.
    public var limits: CrawlLimits {
        switch kind {
        case .page:
            return CrawlLimits(
                maxDepth: 0, maxPages: 1, delay: delaySeconds,
                maxTotalBytes: maxTotalMegabytes * 1024 * 1024,
                respectsRobots: respectsRobots, usesSitemap: false
            )
        case .list:
            return CrawlLimits(
                maxDepth: 0, maxPages: max(1, additionalURLs.count + 1), delay: delaySeconds,
                maxTotalBytes: maxTotalMegabytes * 1024 * 1024,
                // Список адресов может быть с разных доменов — на то он и список,
                // составленный человеком.
                extraHosts: additionalURLs.compactMap { Self.address($0)?.host },
                respectsRobots: respectsRobots, usesSitemap: false
            )
        case .site:
            return CrawlLimits(
                maxDepth: maxDepth, maxPages: maxPages, delay: delaySeconds,
                maxTotalBytes: maxTotalMegabytes * 1024 * 1024,
                extraHosts: extraHosts,
                respectsRobots: respectsRobots, usesSitemap: usesSitemap
            )
        }
    }

    /// Что мешает запустить такой источник. `nil` — можно.
    public var problem: String? {
        guard start != nil else {
            return String(localized: "Адрес не похож на веб-адрес: нужен http:// или https://.")
        }
        if kind == .list, seeds.isEmpty, additionalURLs.contains(where: { !$0.trimmed.isEmpty }) {
            return String(localized: "Ни один из дополнительных адресов не разобрался — нужен http:// или https://.")
        }
        if maxPages < 1 { return String(localized: "Число страниц должно быть хотя бы 1.") }
        if maxDepth < 0 { return String(localized: "Глубина не может быть отрицательной.") }
        if delaySeconds < 0 { return String(localized: "Задержка не может быть отрицательной.") }
        return nil
    }

    /// Разбирает адрес, дописывая `https://`, если человек его не написал.
    public static func address(_ text: String) -> URL? {
        let trimmed = text.trimmed
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false
        else { return nil }
        return url
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
