import XCTest
@testable import ChromaCore

/// §I1.3 — карта сайта как источник списка адресов.
final class SitemapTests: XCTestCase {
    /// Настоящий файл, сжатый `gzip` — так карту отдаёт, например, Википедия.
    /// Первый вариант без имени файла в заголовке, второй с именем: флаги
    /// заголовка разные, и разбирать надо оба.
    private let gzippedWithoutName = "H4sIAAAAAAACA32Oyw6DIBBFf4Wwh0EXjW0Ad35B+wFUiZrwikOrn198rLuce+85Gdlu3pGvXXCOQdGKC0ps6OMwh1HR17NjDW21/CwObSZlG1DRKef0AFjXleOcrTcJeVxGwH4qB8IVguB3erBautjrHcPC2c345OyBGAl7JZ3B7OOga1HfmGiYqEpxZRIOxV/P+/KcUzj/1T86PE0G3gAAAA=="
    private let gzippedWithName = "H4sICDVUdmoCA3NtLnhtbAB9jssOgyAQRX+FsIdBF41tAHd+QfsBVIma8IpDq59ffKy7nHvvORnZbt6Rr11wjkHRigtKbOjjMIdR0dezYw1ttfwsDm0mZRtQ0Snn9ABY15XjnK03CXlcRsB+KgfCFYLgd3qwWrrY6x3DwtnN+OTsgRgJeyWdwezjoGtR35homKhKcWUSDsVfz/vynFM4/9U/OjxNBt4AAAA="

    func testPagesAndDatesAreRead() throws {
        let sitemap = try SitemapParser.parse(Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>https://example.org/a</loc><lastmod>2026-08-01</lastmod></url>
          <url><loc>https://example.org/b</loc><lastmod>2026-08-02T10:30:00+03:00</lastmod></url>
          <url><changefreq>daily</changefreq></url>
        </urlset>
        """.utf8))

        XCTAssertEqual(sitemap.pages.map(\.url), ["https://example.org/a", "https://example.org/b"])
        XCTAssertNotNil(sitemap.pages[0].lastModified)
        XCTAssertNotNil(sitemap.pages[1].lastModified)
        XCTAssertFalse(sitemap.isIndex)
    }

    /// У крупных сайтов первая карта — только оглавление.
    func testAnIndexListsOtherSitemaps() throws {
        let sitemap = try SitemapParser.parse(Data("""
        <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <sitemap><loc>https://example.org/sitemap-1.xml</loc></sitemap>
          <sitemap><loc>https://example.org/sitemap-2.xml</loc></sitemap>
        </sitemapindex>
        """.utf8))

        XCTAssertTrue(sitemap.isIndex)
        XCTAssertEqual(sitemap.children.count, 2)
    }

    /// Пространство имён объявляют кто как: разбор по именам элементов не
    /// зависит от префикса, а выражение с префиксом молча вернуло бы пустоту.
    func testAnUnusualNamespacePrefixDoesNotHideTheURLs() throws {
        let sitemap = try SitemapParser.parse(Data("""
        <sm:urlset xmlns:sm="http://www.sitemaps.org/schemas/sitemap/0.9">
          <sm:url><sm:loc>https://example.org/one</sm:loc></sm:url>
        </sm:urlset>
        """.utf8))
        XCTAssertEqual(sitemap.pages.map(\.url), ["https://example.org/one"])
    }

    func testAPlainListOfAddressesIsAlsoASitemap() throws {
        let sitemap = try SitemapParser.parse(Data("""
        https://example.org/one
        https://example.org/two
        # заметка, не адрес
        """.utf8))
        XCTAssertEqual(sitemap.pages.map(\.url), ["https://example.org/one", "https://example.org/two"])
    }

    func testAGzippedSitemapIsUnpacked() throws {
        for encoded in [gzippedWithoutName, gzippedWithName] {
            let data = try XCTUnwrap(Data(base64Encoded: encoded))
            let sitemap = try SitemapParser.parse(data)
            XCTAssertEqual(sitemap.pages.map(\.url), ["https://example.org/a", "https://example.org/b"])
        }
    }

    /// Разжатие не должно зависеть от того, срез это или самостоятельный `Data`.
    ///
    /// Смещения считаются по массиву байтов (всегда с нуля), а брались из
    /// `data.subdata`, где у среза индексы начинаются с `startIndex`. Разжатие
    /// уходило по чужим байтам — без падения, потому что диапазон при этом
    /// обычно остаётся допустимым, то есть тихо.
    func testAGzippedSitemapArrivingAsASliceIsUnpackedToo() throws {
        let data = try XCTUnwrap(Data(base64Encoded: gzippedWithName))

        // Тот же файл, но внутри буфера побольше — ровно то, чем окажется
        // ответ, прочитанный не целиком, а куском.
        var padded = Data(repeating: 0xEE, count: 16)
        padded.append(data)
        let slice = padded[16...]
        XCTAssertEqual(slice.startIndex, 16, "срез должен начинаться не с нуля, иначе тест ничего не проверяет")

        let sitemap = try SitemapParser.parse(slice)
        XCTAssertEqual(sitemap.pages.map(\.url), ["https://example.org/a", "https://example.org/b"])
    }

    /// Сжатый файл, который разворачивается в гигабайты, — известный приём.
    /// Размер записан в хвосте, и проверить его надо **до** выделения памяти.
    func testAnAbsurdlyLargeUnpackedSizeIsRefusedBeforeAllocating() throws {
        var bomb = Data([0x1f, 0x8b, 0x08, 0x00])
        bomb.append(Data(repeating: 0, count: 6))
        bomb.append(Data(repeating: 0x00, count: 10))
        // ISIZE в хвосте: два гигабайта.
        bomb.append(Data([0, 0, 0, 0, 0x00, 0x00, 0x00, 0x80]))

        XCTAssertThrowsError(try SitemapParser.parse(bomb)) { error in
            XCTAssertEqual(error as? SitemapParser.SitemapError, .tooLarge(2_147_483_648))
        }
    }

    func testSomethingThatIsNotASitemapIsRefusedRatherThanReadAsEmpty() {
        XCTAssertThrowsError(try SitemapParser.parse(Data("<html><body>привет</body></html>".utf8)))
        XCTAssertThrowsError(try SitemapParser.parse(Data()))
    }
}
