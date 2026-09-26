import XCTest
@testable import ChromaCore

/// §I1.3 — `robots.txt` соблюдается. Каждая ошибка здесь — это чужой сервер,
/// к которому мы придём туда, куда нас не звали.
final class RobotsTxtTests: XCTestCase {
    private let agent = "ChromaDBManager/1.0 (+локальная индексация)"

    private func robots(_ text: String) -> RobotsTxt {
        RobotsTxt.parse(text, userAgent: agent)
    }

    func testDisallowedPathsAreRefusedAndTheRestIsAllowed() {
        let rules = robots("""
        User-agent: *
        Disallow: /private/
        Disallow: /tmp
        Allow: /private/public-note
        Sitemap: https://example.org/sitemap.xml
        """)

        XCTAssertFalse(rules.allows(path: "/private/secret"))
        XCTAssertFalse(rules.allows(path: "/tmp/file"))
        XCTAssertTrue(rules.allows(path: "/docs/page"))
        // Более точное `Allow` побеждает более общий `Disallow`.
        XCTAssertTrue(rules.allows(path: "/private/public-note"))
        XCTAssertEqual(rules.sitemaps, ["https://example.org/sitemap.xml"])
    }

    /// Пустой `Disallow:` означает «разрешено всё». Перепутать — значит либо
    /// не проиндексировать ничего, либо пойти туда, куда запретили.
    func testAnEmptyDisallowMeansEverythingIsAllowed() {
        let rules = robots("""
        User-agent: *
        Disallow:
        """)
        XCTAssertTrue(rules.allows(path: "/"))
        XCTAssertTrue(rules.allows(path: "/anything/at/all"))
    }

    func testARootDisallowClosesTheWholeSite() {
        let rules = robots("""
        User-agent: *
        Disallow: /
        """)
        XCTAssertFalse(rules.allows(path: "/"))
        XCTAssertFalse(rules.allows(path: "/docs"))
    }

    /// Группа для нашего имени отменяет группу `*` целиком, а не дополняет её.
    func testOurOwnGroupWinsOverTheWildcard() {
        let rules = robots("""
        User-agent: *
        Disallow: /

        User-agent: ChromaDBManager
        Disallow: /admin/
        """)
        XCTAssertTrue(rules.allows(path: "/docs"), "правила для нас разрешают всё, кроме /admin/")
        XCTAssertFalse(rules.allows(path: "/admin/panel"))
    }

    /// Несколько строк `User-agent` подряд — это одна группа на всех.
    func testSeveralAgentLinesShareOneGroup() {
        let rules = robots("""
        User-agent: SomeBot
        User-agent: ChromaDBManager
        Disallow: /closed/
        """)
        XCTAssertFalse(rules.allows(path: "/closed/x"))
        XCTAssertTrue(rules.allows(path: "/open/x"))
    }

    func testWildcardsAndEndAnchorsAreUnderstood() {
        let rules = robots("""
        User-agent: *
        Disallow: /*.pdf$
        Disallow: /search?
        """)
        XCTAssertFalse(rules.allows(path: "/files/report.pdf"))
        XCTAssertTrue(rules.allows(path: "/files/report.pdf.html"), "$ означает конец пути")
        XCTAssertFalse(rules.allows(url: URL(string: "https://example.org/search?q=1")!))
        XCTAssertTrue(rules.allows(path: "/searching"))
    }

    func testCommentsAndCaseDoNotConfuseTheParser() {
        let rules = robots("""
        # комментарий
        USER-AGENT: *
        DISALLOW: /nope/   # и здесь тоже
        Crawl-delay: 2.5
        """)
        XCTAssertFalse(rules.allows(path: "/nope/page"))
        XCTAssertEqual(rules.group.crawlDelay, 2.5)
    }

    /// «Файла нет» и «файл разрешает всё» — разные новости, и различать их
    /// нужно, чтобы не рассказывать человеку, будто сайт нас пустил.
    func testAMissingFileIsDistinguishableFromAPermissiveOne() {
        XCTAssertTrue(RobotsTxt.missing.isMissing)
        XCTAssertTrue(RobotsTxt.missing.allows(path: "/anything"))
        XCTAssertFalse(robots("User-agent: *\nDisallow:").isMissing)
    }

    func testAFileWithoutAnyGroupForUsAllowsEverything() {
        let rules = robots("""
        User-agent: GoogleBot
        Disallow: /
        """)
        XCTAssertTrue(rules.allows(path: "/docs"), "запрет чужому боту нас не касается")
    }

    /// `"\r\n"` для Swift — один знак: файл из Windows читался одной строкой,
    /// и не действовало ни одно правило.
    func testWindowsLineEndingsAreLinesToo() {
        let rules = robots("User-agent: *\r\nDisallow: /private/\r\nCrawl-delay: 2\r\n")
        XCTAssertFalse(rules.allows(path: "/private/report"))
        XCTAssertEqual(rules.group.crawlDelay, 2)
    }

    /// `URL.path` срезает косую черту в конце — и «/private/» не закрывал
    /// саму папку.
    func testTheTrailingSlashOfTheAddressCounts() {
        let rules = robots("User-agent: *\nDisallow: /private/\nDisallow: /каталог/")
        XCTAssertFalse(rules.allows(url: URL(string: "https://example.org/private/")!))
        XCTAssertFalse(rules.allows(url: URL(string: "https://example.org/%D0%BA%D0%B0%D1%82%D0%B0%D0%BB%D0%BE%D0%B3/")!))
        XCTAssertTrue(rules.allows(url: URL(string: "https://example.org/public/")!))
    }

    /// Задержка с чужого сервера не должна уметь уронить приложение.
    func testAnAbsurdCrawlDelayIsBoundedOrDropped() {
        XCTAssertEqual(robots("User-agent: *\nCrawl-delay: 1e20").group.crawlDelay, RobotsTxt.maximumCrawlDelay)
        XCTAssertNil(robots("User-agent: *\nCrawl-delay: inf").group.crawlDelay)
        XCTAssertNil(robots("User-agent: *\nCrawl-delay: -5").group.crawlDelay)
    }
}
