import Foundation

/// Ограничения обхода.
///
/// Все они обязательны и все настраиваются: без них источник превращается
/// в неуправляемого краулера, который однажды ночью выкачает чужой сайт целиком.
public struct CrawlLimits: Sendable, Hashable {
    public var maxDepth: Int
    public var maxPages: Int
    /// Пауза между запросами. Параллельных запросов к одному хосту нет вовсе —
    /// обход последовательный по построению.
    public var delay: TimeInterval
    /// Суммарный объём загруженного, вместе с `robots.txt` и картами сайта.
    public var maxTotalBytes: Int
    /// Выход за пределы исходного домена — только явным списком.
    public var extraHosts: [String]
    /// Снимается только для собственных доменов пользователя и только
    /// отдельной галочкой с предупреждением.
    public var respectsRobots: Bool
    public var usesSitemap: Bool

    public init(
        maxDepth: Int = 2,
        maxPages: Int = 200,
        delay: TimeInterval = 1,
        maxTotalBytes: Int = 200 * 1024 * 1024,
        extraHosts: [String] = [],
        respectsRobots: Bool = true,
        usesSitemap: Bool = true
    ) {
        self.maxDepth = max(0, maxDepth)
        self.maxPages = max(1, maxPages)
        self.delay = max(0, delay)
        self.maxTotalBytes = max(1024, maxTotalBytes)
        self.extraHosts = extraHosts
        self.respectsRobots = respectsRobots
        self.usesSitemap = usesSitemap
    }
}

/// Страница, до которой обход дошёл и которая готова к индексации.
public struct CrawledPage: Sendable {
    public let url: URL
    public let depth: Int
    public let resource: WebResource
    /// Разобранная страница — для HTML. Разбор уже сделан ради ссылок, и делать
    /// его второй раз в индексации незачем.
    public let page: HTMLPage?

    public init(url: URL, depth: Int, resource: WebResource, page: HTMLPage?) {
        self.url = url
        self.depth = depth
        self.resource = resource
        self.page = page
    }
}

/// Страница, которую не удалось взять. Обход из-за неё не прерывается:
/// одна недоступная страница не повод бросать остальные 199.
public struct CrawlProblem: Sendable, Hashable {
    public let url: String
    public let reason: String

    public init(url: String, reason: String) {
        self.url = url
        self.reason = reason
    }
}

/// Итог обхода — то, что человек увидит в сводке.
public struct CrawlSummary: Sendable {
    public enum Stop: Sendable, Equatable {
        case finished
        case pageLimit(Int)
        case volumeLimit(Int)
        case cancelled

        public var note: String? {
            switch self {
            case .finished:
                return nil
            case .pageLimit(let limit):
                return String(localized: "Обход остановлен на пределе в \(limit.plainDigits) страниц — на сайте их может быть больше.")
            case .volumeLimit(let bytes):
                let shown = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                return String(localized: "Обход остановлен на пределе объёма (\(shown)) — на сайте может быть больше.")
            case .cancelled:
                return String(localized: "Обход отменён — то, что успело загрузиться, осталось.")
            }
        }
    }

    public var visited: [String] = []
    public var problems: [CrawlProblem] = []
    /// Адреса, куда обход не пошёл сознательно: запрет `robots.txt` или чужой
    /// домен. Это не беда, а решение, и в «требуют решения» им не место.
    public var refused: [String] = []
    public var totalBytes: Int = 0
    public var stop: Stop = .finished
    public var usedSitemap = false
    public var robotsWasMissing = false
    public var robotsIgnored = false

    public var pageCount: Int { visited.count }
}

/// Что известно о странице с прошлого раза.
public struct CrawlHistory: Sendable, Hashable {
    public var etag: String?
    public var lastModified: String?
    /// Ссылки, найденные на этой странице в прошлый раз.
    ///
    /// Без них условные запросы ломали бы обход: сервер отвечает 304 без тела,
    /// брать ссылки становится неоткуда, и повторный обход находил бы одну
    /// стартовую страницу вместо двухсот.
    public var links: [String]

    public init(etag: String? = nil, lastModified: String? = nil, links: [String] = []) {
        self.etag = etag
        self.lastModified = lastModified
        self.links = links
    }
}

/// Обход сайта.
///
/// Отдельно от загрузки и от разбора: здесь живут только правила — куда можно,
/// как глубоко, как часто и когда остановиться. Сеть и разбор передаются
/// снаружи, поэтому обход проверяется тестом целиком, без единого запроса.
public final class SiteCrawler {
    public typealias Fetch = (URL, String?, String?) async throws -> WebResource
    public typealias Pause = (TimeInterval) async throws -> Void
    public typealias HistoryLookup = (URL) -> CrawlHistory?

    private let fetch: Fetch
    private let pause: Pause
    private let userAgent: String
    private let log: LogHandler

    public init(
        userAgent: String,
        fetch: @escaping Fetch,
        pause: @escaping Pause = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        log: @escaping LogHandler = noopLogHandler
    ) {
        self.userAgent = userAgent
        self.fetch = fetch
        self.pause = pause
        self.log = log
    }

    /// Готовый обход поверх настоящей сети.
    public convenience init(fetcher: WebFetcher, userAgent: String, log: @escaping LogHandler = noopLogHandler) {
        self.init(
            userAgent: userAgent,
            fetch: { try await fetcher.fetch($0, etag: $1, lastModified: $2) },
            log: log
        )
    }

    private struct Step {
        let url: URL
        let depth: Int
    }

    /// Обходит сайт от стартового адреса.
    ///
    /// Не бросает: обход, прерванный на середине, — это не ошибка, а результат
    /// с указанием причины. Отмена тоже: страницы, которые успели загрузиться,
    /// уже отданы `visit`, и делать вид, что их не было, было бы неправдой.
    public func crawl(
        from start: URL,
        limits: CrawlLimits = CrawlLimits(),
        /// Что мы знали об этих страницах в прошлый раз.
        history: HistoryLookup? = nil,
        also extraSeeds: [URL] = [],
        progress: ((_ processed: Int, _ queued: Int) async -> Void)? = nil,
        visit: (CrawledPage) async throws -> Void
    ) async -> CrawlSummary {
        var summary = CrawlSummary()
        guard let startHost = start.host?.lowercased() else {
            summary.problems.append(CrawlProblem(
                url: start.absoluteString,
                reason: String(localized: "В адресе нет имени сайта — обходить нечего.")
            ))
            return summary
        }

        let robots = await loadRobots(start: start, limits: limits, summary: &summary)
        // Сайт вправе попросить ходить реже, чем мы собирались, — и это его
        // право, а не пожелание. Наоборот — не работает: свою задержку мы можем
        // только увеличить.
        let delay = max(limits.delay, robots.group.crawlDelay ?? 0)

        var frontier: [Step] = [Step(url: start, depth: 0)]
        var seen: Set<String> = [Self.normalise(start)]

        if limits.usesSitemap {
            let mapped = await loadSitemapURLs(start: start, robots: robots, limits: limits, summary: &summary)
            for entry in mapped {
                guard let url = URL(string: entry) else { continue }
                let key = Self.normalise(url)
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                frontier.append(Step(url: url, depth: 0))
            }
            summary.usedSitemap = !mapped.isEmpty
        }

        // Список адресов вместо обхода: у источника «список URL» стартовая
        // страница такая же, как и все остальные.
        for url in extraSeeds {
            let key = Self.normalise(url)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            frontier.append(Step(url: url, depth: 0))
        }

        var isFirstRequest = true
        while !frontier.isEmpty {
            if Task.isCancelled {
                summary.stop = .cancelled
                break
            }
            let step = frontier.removeFirst()

            guard Self.sameSite(step.url.host, as: startHost, extra: limits.extraHosts) else {
                summary.refused.append(step.url.absoluteString)
                continue
            }
            guard robots.allows(url: step.url) else {
                summary.refused.append(step.url.absoluteString)
                continue
            }

            if !isFirstRequest, delay > 0 {
                do { try await pause(delay) } catch {
                    summary.stop = .cancelled
                    break
                }
            }
            isFirstRequest = false

            let known = history?(step.url)
            let resource: WebResource
            do {
                resource = try await fetch(step.url, known?.etag, known?.lastModified)
            } catch {
                // Сетевая ошибка не прерывает обход: страница помечается,
                // остальные продолжают загружаться.
                summary.problems.append(CrawlProblem(
                    url: step.url.absoluteString, reason: error.localizedDescription
                ))
                await progress?(summary.visited.count, frontier.count)
                continue
            }
            summary.totalBytes += resource.data.count

            guard resource.isSuccess || resource.isNotModified else {
                summary.problems.append(CrawlProblem(
                    url: step.url.absoluteString, reason: Self.reason(for: resource)
                ))
                await progress?(summary.visited.count, frontier.count)
                if summary.totalBytes > limits.maxTotalBytes {
                    summary.stop = .volumeLimit(limits.maxTotalBytes)
                    break
                }
                continue
            }

            var parsed: HTMLPage?
            // У ответа 304 тела нет вовсе — разбирать нечего, и это не беда,
            // а самый дешёвый из возможных ответов.
            if resource.isHTML, !resource.isNotModified {
                do {
                    parsed = try HTMLParser.parse(
                        resource.data, contentType: resource.contentType, baseURL: resource.url
                    )
                } catch {
                    summary.problems.append(CrawlProblem(
                        url: step.url.absoluteString, reason: error.localizedDescription
                    ))
                }
            }

            // Ссылки собираются до проверки на «страница рисуется скриптом»:
            // оглавление, нарисованное скриптом, всё равно бывает со ссылками.
            // На 304 берутся ссылки прошлого раза: страница не менялась, значит,
            // и ссылки на ней те же.
            let outgoing = parsed?.links ?? (resource.isNotModified ? (known?.links ?? []) : [])
            if !summary.usedSitemap, step.depth < limits.maxDepth {
                for href in outgoing {
                    guard let url = URL(string: href) else { continue }
                    let key = Self.normalise(url)
                    guard !seen.contains(key) else { continue }
                    guard Self.sameSite(url.host, as: startHost, extra: limits.extraHosts) else { continue }
                    seen.insert(key)
                    frontier.append(Step(url: url, depth: step.depth + 1))
                }
            }

            if let parsed, parsed.looksScriptRendered {
                // Точная причина, а не «пустая страница»: человек должен понять,
                // что делать, а сделать тут ничего нельзя, кроме как исключить
                // адрес.
                summary.problems.append(CrawlProblem(
                    url: step.url.absoluteString,
                    reason: String(localized: "Ответ получен, но текста в нём нет — страница, судя по всему, рисуется скриптом в браузере. Такие страницы приложение не индексирует.")
                ))
            } else {
                do {
                    try await visit(CrawledPage(
                        url: step.url, depth: step.depth, resource: resource, page: parsed
                    ))
                    summary.visited.append(step.url.absoluteString)
                } catch is CancellationError {
                    summary.stop = .cancelled
                    break
                } catch {
                    summary.problems.append(CrawlProblem(
                        url: step.url.absoluteString, reason: error.localizedDescription
                    ))
                }
            }

            await progress?(summary.visited.count, frontier.count)

            if summary.totalBytes > limits.maxTotalBytes {
                summary.stop = .volumeLimit(limits.maxTotalBytes)
                break
            }
            if summary.visited.count >= limits.maxPages {
                summary.stop = frontier.isEmpty ? .finished : .pageLimit(limits.maxPages)
                break
            }
        }

        log(.info, "Веб", "Обход \(start.host ?? start.absoluteString): страниц \(summary.visited.count.plainDigits), проблем \(summary.problems.count.plainDigits), не пошли \(summary.refused.count.plainDigits)")
        return summary
    }

    // MARK: - robots.txt и карта сайта

    private func loadRobots(start: URL, limits: CrawlLimits, summary: inout CrawlSummary) async -> RobotsTxt {
        guard limits.respectsRobots else {
            // Отключение — осознанный выбор для своего сайта, и он обязан быть
            // виден в логе: иначе однажды никто не вспомнит, почему приложение
            // ходило туда, куда просили не ходить.
            log(.warning, "Веб", "robots.txt для \(start.host ?? "") не соблюдается — так настроен источник")
            summary.robotsIgnored = true
            return .missing
        }
        var components = URLComponents(url: start, resolvingAgainstBaseURL: false)
        components?.path = "/robots.txt"
        components?.query = nil
        components?.fragment = nil
        guard let url = components?.url else {
            summary.robotsWasMissing = true
            return .missing
        }
        do {
            let resource = try await fetch(url, nil, nil)
            summary.totalBytes += resource.data.count
            guard resource.isSuccess, !resource.data.isEmpty else {
                summary.robotsWasMissing = true
                return .missing
            }
            return RobotsTxt.parse(
                HTMLParser.decode(resource.data, contentType: resource.contentType),
                userAgent: userAgent
            )
        } catch {
            // Не прочитали правила — значит, не знаем их. Считать это
            // разрешением приходится (иначе не обойти ни один сайт), но
            // рассказывать об этом как о разрешении нельзя.
            log(.warning, "Веб", "robots.txt не прочитался (\(error.localizedDescription)) — обход идёт без него")
            summary.robotsWasMissing = true
            return .missing
        }
    }

    /// Сколько вложенных карт разворачивать. Оглавление из тысячи файлов —
    /// это уже не «быстрее и вежливее», а тот же неуправляемый обход.
    static let maxSitemapFiles = 10

    private func loadSitemapURLs(
        start: URL, robots: RobotsTxt, limits: CrawlLimits, summary: inout CrawlSummary
    ) async -> [String] {
        var pending = robots.sitemaps
        if pending.isEmpty {
            var components = URLComponents(url: start, resolvingAgainstBaseURL: false)
            components?.path = "/sitemap.xml"
            components?.query = nil
            components?.fragment = nil
            if let guess = components?.url?.absoluteString { pending = [guess] }
        }

        var found: [String] = []
        var read = 0
        var visited: Set<String> = []
        while !pending.isEmpty, read < Self.maxSitemapFiles, found.count < limits.maxPages {
            if Task.isCancelled { break }
            let next = pending.removeFirst()
            guard visited.insert(next).inserted, let url = URL(string: next) else { continue }
            read += 1
            do {
                let resource = try await fetch(url, nil, nil)
                summary.totalBytes += resource.data.count
                guard resource.isSuccess else { continue }
                let sitemap = try SitemapParser.parse(resource.data)
                found.append(contentsOf: sitemap.pages.map(\.url))
                pending.append(contentsOf: sitemap.children)
            } catch {
                // Нет карты сайта — обычное дело, а не поломка: обход просто
                // пойдёт по ссылкам.
                log(.debug, "Веб", "Карта сайта \(next) не прочиталась: \(error.localizedDescription)")
            }
        }
        return Array(found.prefix(limits.maxPages))
    }

    // MARK: - Адреса

    /// Тот же сайт или уже чужой.
    ///
    /// `www.` не считается другим доменом: переадресация с голого имени на `www`
    /// (или наоборот) стоит на половине сайтов, и обход, честно посчитавший их
    /// разными, закончился бы на первой же странице.
    static func sameSite(_ host: String?, as startHost: String, extra: [String]) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let bare = { (name: String) in
            name.hasPrefix("www.") ? String(name.dropFirst(4)) : name
        }
        if bare(host) == bare(startHost) { return true }
        return extra.contains { bare(host) == bare($0.lowercased()) }
    }

    /// Ключ, по которому адрес считается уже виденным.
    static func normalise(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.fragment = nil
        let scheme = components.scheme?.lowercased()
        components.scheme = scheme
        components.host = components.host?.lowercased()
        // Порт по умолчанию, записанный явно, — тот же адрес.
        if let scheme, let port = components.port,
           (scheme == "http" && port == 80) || (scheme == "https" && port == 443) {
            components.port = nil
        }
        return components.url?.absoluteString ?? url.absoluteString
    }

    static func reason(for resource: WebResource) -> String {
        if resource.isGone {
            // Исчезнувшая страница не удаляется сама — правило 1 приложения 5
            // и общее правило 8.4.
            return String(localized: "Страница отдала \(resource.status.plainDigits) — её больше нет по этому адресу. Индексированное содержимое останется, пока вы не решите иначе.")
        }
        return String(localized: "Сервер ответил \(resource.status.plainDigits).")
    }
}
