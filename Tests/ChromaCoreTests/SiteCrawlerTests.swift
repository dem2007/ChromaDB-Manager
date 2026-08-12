import XCTest
@testable import ChromaCore

/// §I1.3, I1.4 — обход сайта и его обязательные ограничения.
///
/// Сеть подставная: обход проверяется целиком, без единого запроса наружу,
/// и тест не зависит от чужого сайта, который завтра поменяют.
final class SiteCrawlerTests: XCTestCase {
    /// Маленький сайт, которым распоряжается тест.
    private final class FakeSite: @unchecked Sendable {
        var pages: [String: String] = [:]
        var robots: String?
        var sitemap: String?
        var failures: [String: Error] = [:]
        var statuses: [String: Int] = [:]
        var types: [String: String] = [:]
        private(set) var requested: [String] = []
        private(set) var pauses: [TimeInterval] = []

        func page(_ path: String, links: [String] = [], text: String = "Достаточно длинный текст страницы, чтобы он не сошёл за пустой.") {
            let body = links.map { "<a href=\"\($0)\">ссылка</a>" }.joined()
            pages[path] = "<html><body><h1>Заголовок</h1><p>\(text)</p>\(body)</body></html>"
        }

        /// Страницы, которые сервер считает не изменившимися, если о них
        /// спросили условным запросом.
        var unchangedIfAsked: Set<String> = []
        private(set) var conditional: [String: String] = [:]

        func fetch(_ url: URL, _ etag: String?, _ lastModified: String?) async throws -> WebResource {
            requested.append(url.absoluteString)
            let path = url.path.isEmpty ? "/" : url.path
            if let error = failures[path] { throw error }
            if let etag { conditional[path] = etag }
            if etag != nil || lastModified != nil, unchangedIfAsked.contains(path) {
                return WebResource(url: url, status: 304, data: Data(), contentType: nil, etag: etag, lastModified: lastModified)
            }
            if path == "/robots.txt" {
                guard let robots else {
                    return WebResource(url: url, status: 404, data: Data(), contentType: nil, etag: nil, lastModified: nil)
                }
                return WebResource(url: url, status: 200, data: Data(robots.utf8), contentType: "text/plain", etag: nil, lastModified: nil)
            }
            if path == "/sitemap.xml" {
                guard let sitemap else {
                    return WebResource(url: url, status: 404, data: Data(), contentType: nil, etag: nil, lastModified: nil)
                }
                return WebResource(url: url, status: 200, data: Data(sitemap.utf8), contentType: "application/xml", etag: nil, lastModified: nil)
            }
            if let status = statuses[path] {
                return WebResource(url: url, status: status, data: Data(), contentType: nil, etag: nil, lastModified: nil)
            }
            guard let body = pages[path] else {
                return WebResource(url: url, status: 404, data: Data(), contentType: nil, etag: nil, lastModified: nil)
            }
            return WebResource(
                url: url, status: 200, data: Data(body.utf8),
                contentType: types[path] ?? "text/html; charset=utf-8",
                etag: nil, lastModified: nil
            )
        }

        func pause(_ seconds: TimeInterval) async throws { pauses.append(seconds) }
    }

    private func crawler(_ site: FakeSite) -> SiteCrawler {
        SiteCrawler(
            userAgent: "ChromaDBManager/1.0",
            fetch: { try await site.fetch($0, $1, $2) },
            pause: { try await site.pause($0) }
        )
    }

    private let start = URL(string: "https://example.org/")!

    private func run(
        _ site: FakeSite, limits: CrawlLimits = CrawlLimits(usesSitemap: false)
    ) async -> (CrawlSummary, [String]) {
        var seen: [String] = []
        let summary = await crawler(site).crawl(from: start, limits: limits) { page in
            seen.append(page.url.absoluteString)
        }
        return (summary, seen)
    }

    // MARK: - Ограничения

    func testDepthIsLimited() async {
        let site = FakeSite()
        site.page("/", links: ["/one"])
        site.page("/one", links: ["/two"])
        site.page("/two", links: ["/three"])
        site.page("/three")

        let (summary, seen) = await run(site, limits: CrawlLimits(maxDepth: 1, usesSitemap: false))
        XCTAssertEqual(seen, ["https://example.org/", "https://example.org/one"])
        XCTAssertEqual(summary.stop, .finished)
    }

    func testThePageCountIsLimitedAndTheSummarySaysSo() async {
        let site = FakeSite()
        site.page("/", links: ["/a", "/b", "/c"])
        for path in ["/a", "/b", "/c"] { site.page(path) }

        let (summary, seen) = await run(site, limits: CrawlLimits(maxPages: 2, usesSitemap: false))
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(summary.stop, .pageLimit(2))
        // Человек должен узнать, что сайт кончился не сам.
        XCTAssertTrue(summary.stop.note?.contains("предел") ?? false, summary.stop.note ?? "")
    }

    func testTheCrawlStaysOnTheStartingSite() async {
        let site = FakeSite()
        site.page("/", links: ["https://elsewhere.example/page", "/inside"])
        site.page("/inside")

        let (summary, seen) = await run(site)
        XCTAssertEqual(seen, ["https://example.org/", "https://example.org/inside"])
        XCTAssertFalse(site.requested.contains { $0.contains("elsewhere") }, "чужой домен даже не запрашивался")
        XCTAssertTrue(summary.refused.isEmpty, "чужой адрес отсеян до очереди, а не отказом в ней")
    }

    /// `www.example.org` и `example.org` — один сайт. Считать их разными значит
    /// закончить обход на первой же переадресации.
    func testWWWIsNotADifferentSite() async {
        let site = FakeSite()
        site.page("/", links: ["https://www.example.org/second"])
        site.page("/second")

        let (_, seen) = await run(site)
        XCTAssertEqual(seen.count, 2)
    }

    func testAnotherHostCanBeAllowedExplicitly() async {
        XCTAssertTrue(SiteCrawler.sameSite("docs.example.net", as: "example.org", extra: ["docs.example.net"]))
        XCTAssertFalse(SiteCrawler.sameSite("docs.example.net", as: "example.org", extra: []))
    }

    func testTheTotalVolumeIsCapped() async {
        let site = FakeSite()
        site.page("/", links: ["/a", "/b"], text: String(repeating: "текст ", count: 400))
        site.page("/a", text: String(repeating: "текст ", count: 400))
        site.page("/b", text: String(repeating: "текст ", count: 400))

        let (summary, seen) = await run(site, limits: CrawlLimits(maxTotalBytes: 4096, usesSitemap: false))
        XCTAssertEqual(summary.stop, .volumeLimit(4096))
        XCTAssertLessThan(seen.count, 3)
    }

    /// Пауза между запросами — обязательная, и не перед первым: ждать секунду
    /// до единственного запроса незачем.
    func testThereIsAPauseBetweenRequestsButNotBeforeTheFirst() async {
        let site = FakeSite()
        site.page("/", links: ["/a"])
        site.page("/a")

        _ = await run(site)
        XCTAssertEqual(site.pauses, [1], "две страницы — одна пауза")
    }

    /// Сайт вправе попросить ходить реже, чем мы собирались.
    func testTheSiteCanAskForALongerPause() async {
        let site = FakeSite()
        site.robots = "User-agent: *\nCrawl-delay: 5"
        site.page("/", links: ["/a"])
        site.page("/a")

        _ = await run(site, limits: CrawlLimits(delay: 1, usesSitemap: false))
        XCTAssertEqual(site.pauses, [5])
    }

    // MARK: - robots.txt

    func testForbiddenPathsAreNotRequestedAtAll() async {
        let site = FakeSite()
        site.robots = "User-agent: *\nDisallow: /private/"
        site.page("/", links: ["/private/secret", "/open"])
        site.page("/private/secret")
        site.page("/open")

        let (summary, seen) = await run(site)
        XCTAssertEqual(seen, ["https://example.org/", "https://example.org/open"])
        XCTAssertEqual(summary.refused, ["https://example.org/private/secret"])
        XCTAssertFalse(site.requested.contains("https://example.org/private/secret"))
    }

    func testAMissingRobotsFileIsRecordedRatherThanReadAsPermission() async {
        let site = FakeSite()
        site.page("/")

        let (summary, _) = await run(site)
        XCTAssertTrue(summary.robotsWasMissing)
        XCTAssertFalse(summary.robotsIgnored)
    }

    func testRobotsCanBeSwitchedOffAndThatIsVisibleInTheSummary() async {
        let site = FakeSite()
        site.robots = "User-agent: *\nDisallow: /"
        site.page("/", links: ["/anything"])
        site.page("/anything")

        let (summary, seen) = await run(
            site, limits: CrawlLimits(respectsRobots: false, usesSitemap: false)
        )
        XCTAssertTrue(summary.robotsIgnored)
        XCTAssertEqual(seen.count, 2)
        XCTAssertFalse(site.requested.contains("https://example.org/robots.txt"), "не спрашиваем то, чего не собираемся соблюдать")
    }

    // MARK: - Карта сайта

    /// Карта сайта предпочтительнее обхода по ссылкам: полнее и вежливее.
    func testASitemapIsPreferredOverFollowingLinks() async {
        let site = FakeSite()
        site.sitemap = """
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>https://example.org/from-map</loc></url>
        </urlset>
        """
        site.page("/", links: ["/only-linked"])
        site.page("/from-map")
        site.page("/only-linked")

        var seen: [String] = []
        let summary = await crawler(site).crawl(from: start, limits: CrawlLimits()) { seen.append($0.url.absoluteString) }

        XCTAssertTrue(summary.usedSitemap)
        XCTAssertEqual(seen, ["https://example.org/", "https://example.org/from-map"])
        XCTAssertFalse(seen.contains("https://example.org/only-linked"), "при карте сайта по ссылкам не ходим")
    }

    func testAnAbsentSitemapJustMeansCrawlingByLinks() async {
        let site = FakeSite()
        site.page("/", links: ["/a"])
        site.page("/a")

        var seen: [String] = []
        let summary = await crawler(site).crawl(from: start, limits: CrawlLimits()) { seen.append($0.url.absoluteString) }
        XCTAssertFalse(summary.usedSitemap)
        XCTAssertEqual(seen.count, 2)
    }

    // MARK: - Беды отдельных страниц

    /// Сетевая ошибка не прерывает обход: остальные страницы не виноваты.
    func testANetworkErrorDoesNotStopTheCrawl() async {
        let site = FakeSite()
        site.page("/", links: ["/broken", "/fine"])
        site.page("/fine")
        site.failures["/broken"] = URLError(.timedOut)

        let (summary, seen) = await run(site)
        XCTAssertEqual(seen, ["https://example.org/", "https://example.org/fine"])
        XCTAssertEqual(summary.problems.map(\.url), ["https://example.org/broken"])
        XCTAssertEqual(summary.stop, .finished)
    }

    /// Исчезнувшая страница не удаляется сама (правило 1 приложения 5, 8.4).
    func testAGonePageBecomesAProblemNotADeletion() async {
        let site = FakeSite()
        site.page("/", links: ["/gone"])
        site.statuses["/gone"] = 410

        let (summary, seen) = await run(site)
        XCTAssertEqual(seen, ["https://example.org/"])
        let problem = try? XCTUnwrap(summary.problems.first)
        XCTAssertEqual(problem?.url, "https://example.org/gone")
        XCTAssertTrue(problem?.reason.contains("останется") ?? false, problem?.reason ?? "")
    }

    /// Пустой текст при успешном ответе — это не пустая страница, а страница,
    /// которую рисует скрипт. Причина обязана быть точной.
    func testAScriptRenderedPageIsReportedWithItsRealReason() async {
        let site = FakeSite()
        site.page("/", links: ["/app"])
        site.pages["/app"] = "<html><body><div id=\"root\"></div></body></html>"

        let (summary, seen) = await run(site)
        XCTAssertEqual(seen, ["https://example.org/"])
        XCTAssertTrue(
            summary.problems.first?.reason.contains("рисуется скриптом") ?? false,
            summary.problems.first?.reason ?? ""
        )
    }

    /// PDF по ссылке отдаётся как есть — разбирать его будет экстрактор
    /// этапа 4, и решается это по типу ответа, а не по расширению в адресе.
    func testNonHTMLIsHandedOverUnparsed() async {
        let site = FakeSite()
        site.page("/", links: ["/report.html"])
        site.pages["/report.html"] = "%PDF-1.4 …"
        site.types["/report.html"] = "application/pdf"

        var delivered: [CrawledPage] = []
        _ = await crawler(site).crawl(from: start, limits: CrawlLimits(usesSitemap: false)) { delivered.append($0) }

        let pdf = delivered.first { $0.url.absoluteString.hasSuffix("report.html") }
        XCTAssertNotNil(pdf)
        XCTAssertNil(pdf?.page, "не HTML — и разбирать как HTML нечего")
        XCTAssertEqual(pdf?.resource.mediaType, "application/pdf")
    }

    // MARK: - Отмена и прогресс

    /// Отменённый обход — это результат с причиной, а не потерянная работа:
    /// страницы, которые успели загрузиться, уже отданы.
    func testCancellationStopsTheCrawlAndKeepsWhatWasDone() async {
        let site = FakeSite()
        site.page("/", links: ["/a", "/b", "/c"])
        for path in ["/a", "/b", "/c"] { site.page(path) }

        var seen: [String] = []
        let summary = await crawler(site).crawl(from: start, limits: CrawlLimits(usesSitemap: false)) { page in
            seen.append(page.url.absoluteString)
            if seen.count == 2 { throw CancellationError() }
        }

        XCTAssertEqual(summary.stop, .cancelled)
        XCTAssertEqual(summary.visited, ["https://example.org/"])
        XCTAssertEqual(summary.stop.note?.contains("отменён"), true)
    }

    func testProgressReportsWhatIsDoneAndWhatIsLeft() async {
        let site = FakeSite()
        site.page("/", links: ["/a", "/b"])
        site.page("/a")
        site.page("/b")

        var reports: [(Int, Int)] = []
        _ = await crawler(site).crawl(
            from: start, limits: CrawlLimits(usesSitemap: false),
            progress: { processed, queued in reports.append((processed, queued)) },
            visit: { _ in }
        )

        XCTAssertEqual(reports.map(\.0), [1, 2, 3])
        XCTAssertEqual(reports.map(\.1), [2, 1, 0], "«в очереди» убывает по мере обхода")
    }

    // MARK: - Условные запросы

    /// Ответ 304 — самый дешёвый из возможных: тела нет, пересчитывать нечего.
    /// Но и ссылок в нём нет, поэтому обход берёт их из прошлого раза — иначе
    /// вторая синхронизация сайта находила бы одну стартовую страницу.
    func testAnUnchangedPageStillLetsTheCrawlGoOn() async {
        let site = FakeSite()
        site.page("/", links: ["/a"])
        site.page("/a")
        site.unchangedIfAsked = ["/"]

        var delivered: [CrawledPage] = []
        let summary = await crawler(site).crawl(
            from: start, limits: CrawlLimits(usesSitemap: false),
            history: { url in
                url.path == "/" ? CrawlHistory(etag: "\"v1\"", links: ["https://example.org/a"]) : nil
            },
            visit: { delivered.append($0) }
        )

        XCTAssertEqual(site.conditional["/"], "\"v1\"", "валидатор ушёл на сервер")
        XCTAssertEqual(delivered.map { $0.url.absoluteString }, ["https://example.org/", "https://example.org/a"])
        XCTAssertTrue(delivered[0].resource.isNotModified)
        XCTAssertNil(delivered[0].page, "разбирать нечего — тела нет")
        XCTAssertEqual(summary.stop, .finished)
    }

    /// Источник «список URL»: стартовой страницы как таковой нет, есть набор
    /// адресов.
    func testAListOfAddressesIsCrawledWithoutFollowingLinks() async {
        let site = FakeSite()
        site.page("/", links: ["/nowhere"])
        site.page("/first")
        site.page("/second")

        var seen: [String] = []
        _ = await crawler(site).crawl(
            from: start, limits: CrawlLimits(maxDepth: 0, usesSitemap: false),
            also: [URL(string: "https://example.org/first")!, URL(string: "https://example.org/second")!],
            visit: { seen.append($0.url.absoluteString) }
        )
        XCTAssertEqual(seen, ["https://example.org/", "https://example.org/first", "https://example.org/second"])
    }

    // MARK: - Адреса

    func testTheSameAddressIsNotVisitedTwice() async {
        let site = FakeSite()
        site.page("/", links: ["/a", "/a#вниз", "https://EXAMPLE.org:443/a", "/"])
        site.page("/a")

        let (_, seen) = await run(site)
        XCTAssertEqual(seen, ["https://example.org/", "https://example.org/a"])
    }
}
