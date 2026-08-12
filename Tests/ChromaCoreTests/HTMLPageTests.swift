import XCTest
@testable import ChromaCore

/// §I1.2 — HTML в текст и структуру.
final class HTMLPageTests: XCTestCase {
    private func parse(_ html: String, base: String = "https://example.org/docs/page") throws -> HTMLPage {
        try HTMLParser.parse(html, baseURL: URL(string: base))
    }

    func testHeadingsBecomeStructureWithHonestOffsets() throws {
        let page = try parse("""
        <html><head><title>Руководство</title></head><body>
        <h1>Введение</h1>
        <p>Первый абзац.</p>
        <h2>Установка</h2>
        <p>Второй абзац.</p>
        </body></html>
        """)

        XCTAssertEqual(page.title, "Руководство")
        XCTAssertEqual(page.headings.map(\.title), ["Введение", "Установка"])
        XCTAssertEqual(page.headings.map(\.level), [1, 2])
        // Смещение обязано указывать на сам заголовок в тексте, иначе раздел
        // начнётся не там, и Document-based чанкинг порежет мимо.
        for heading in page.headings {
            let index = page.plainText.index(page.plainText.startIndex, offsetBy: heading.start)
            XCTAssertTrue(
                page.plainText[index...].hasPrefix(heading.title),
                "заголовок «\(heading.title)» не на своём месте: \(page.plainText[index...].prefix(30))"
            )
        }
    }

    /// Меню и подвал есть на каждой странице сайта. Не выбросив их, мы получим
    /// коллекцию, где каждый чанк начинается одинаково, и поиск будет находить
    /// навигацию.
    func testNavigationAndScriptsAreDroppedBeforeText() throws {
        let page = try parse("""
        <html><body>
        <nav><a href="/">Главная</a> <a href="/about">О нас</a></nav>
        <header>Шапка сайта</header>
        <script>var x = "текст из скрипта";</script>
        <style>.a { content: "стиль"; }</style>
        <main><p>Настоящее содержание страницы, ради которого её и читают.</p></main>
        <footer>© 2026</footer>
        </body></html>
        """)

        XCTAssertTrue(page.plainText.contains("Настоящее содержание"))
        for noise in ["Главная", "Шапка сайта", "текст из скрипта", "стиль", "© 2026"] {
            XCTAssertFalse(page.plainText.contains(noise), "в тексте осталось: \(noise)")
        }
    }

    func testBlocksBecomeLineBreaksRatherThanGluedWords() throws {
        let page = try parse("""
        <html><body><p>Первый</p><p>Второй</p><ul><li>Раз</li><li>Два</li></ul></body></html>
        """)
        // Склеенное «ПервыйВторой» — самая заметная беда наивного обхода.
        XCTAssertFalse(page.plainText.contains("ПервыйВторой"))
        XCTAssertTrue(page.plainText.contains("Первый"))
        XCTAssertTrue(page.plainText.contains("Раз"))
        XCTAssertFalse(page.plainText.contains("РазДва"))
    }

    func testCanonicalAndRelativeLinksBecomeAbsolute() throws {
        let page = try parse("""
        <html><head>
        <link rel="canonical" href="/docs/page">
        <meta name="description" content="Описание страницы">
        </head><body>
        <a href="next">Дальше</a>
        <a href="/other">Другая</a>
        <a href="https://elsewhere.example/x">Чужая</a>
        <a href="#top">Наверх</a>
        <a href="mailto:a@b.c">Почта</a>
        </body></html>
        """)

        XCTAssertEqual(page.canonicalURL, "https://example.org/docs/page")
        XCTAssertEqual(page.summary, "Описание страницы")
        XCTAssertEqual(page.links, [
            "https://example.org/docs/next",
            "https://example.org/other",
            "https://elsewhere.example/x",
        ])
        // Якорь и почта — не страницы; обходить их значит скачать одно и то же
        // столько раз, сколько на странице оглавлений.
        XCTAssertFalse(page.links.contains { $0.contains("#") || $0.hasPrefix("mailto") })
    }

    func testAnchorsWithinAPageCollapseToThePageItself() throws {
        let page = try parse("""
        <html><body><a href="/guide#part1">Раз</a><a href="/guide#part2">Два</a></body></html>
        """)
        XCTAssertEqual(page.links, ["https://example.org/guide"])
    }

    /// Успешный ответ и пустой текст — это почти всегда приложение, которое
    /// рисует себя скриптом. Индексировать пустоту нельзя, но и молчать
    /// об этом тоже.
    func testAScriptRenderedPageIsRecognisable() throws {
        let page = try parse("""
        <html><body><div id="root"></div><script src="/app.js"></script></body></html>
        """)
        XCTAssertTrue(page.looksScriptRendered)

        let ordinary = try parse("""
        <html><body><p>Достаточно длинный текст настоящей страницы для проверки.</p></body></html>
        """)
        XCTAssertFalse(ordinary.looksScriptRendered)
    }

    /// Настоящий HTML в интернете почти никогда не является правильным XML:
    /// незакрытые теги, атрибуты без кавычек, регистр вперемешку.
    func testBrokenMarkupIsStillRead() throws {
        let page = try parse("""
        <HTML><BODY>
        <P>Первый абзац
        <p>Второй абзац <B>жирным
        <table><tr><td>Ячейка 1<td>Ячейка 2</table>
        </BODY>
        """)
        XCTAssertTrue(page.plainText.contains("Первый абзац"))
        XCTAssertTrue(page.plainText.contains("Второй абзац"))
        XCTAssertTrue(page.plainText.contains("жирным"))
        XCTAssertTrue(page.plainText.contains("Ячейка 1"))
        XCTAssertFalse(page.plainText.contains("Ячейка 1Ячейка 2"), page.plainText)
    }

    func testEntitiesAndWhitespaceAreNormalised() throws {
        let page = try parse("""
        <html><body><p>Кавычки &laquo;ёлочки&raquo; и   лишние    пробелы</p></body></html>
        """)
        XCTAssertTrue(page.plainText.contains("«ёлочки»"), page.plainText)
        XCTAssertFalse(page.plainText.contains("   "), page.plainText)
    }
}

/// §I1.2 — кодировка страницы.
///
/// Разбор байтов средствами tidy молча портит кириллицу: ошибки нет, текст
/// есть, но не тот. Поэтому байты декодируются до разбора — и по тем же
/// правилам, что у браузера.
final class HTMLEncodingTests: XCTestCase {
    func testCharsetFromTheHTTPHeaderWins() throws {
        let text = "<html><body><p>Проверка кодировки страницы</p></body></html>"
        let data = try XCTUnwrap(text.data(using: .windowsCP1251))
        let page = try HTMLParser.parse(data, contentType: "text/html; charset=windows-1251")
        XCTAssertTrue(page.plainText.contains("Проверка кодировки"), page.plainText)
    }

    func testCharsetFromTheDocumentIsUsedWhenTheHeaderIsSilent() throws {
        let text = "<html><head><meta charset=\"windows-1251\"></head><body><p>Русский текст страницы</p></body></html>"
        let data = try XCTUnwrap(text.data(using: .windowsCP1251))
        let page = try HTMLParser.parse(data, contentType: nil)
        XCTAssertTrue(page.plainText.contains("Русский текст"), page.plainText)
    }

    func testUTF8IsTheDefaultAndSurvivesTheParser() throws {
        let text = "<html><body><p>Обычная страница в UTF-8 с кириллицей</p></body></html>"
        let page = try HTMLParser.parse(Data(text.utf8), contentType: "text/html")
        XCTAssertTrue(page.plainText.contains("кириллицей"), page.plainText)
    }

    func testCharsetIsReadOutOfAMessyHeader() {
        XCTAssertEqual(HTMLParser.charset(inContentType: "text/html; charset=UTF-8"), "UTF-8")
        XCTAssertEqual(HTMLParser.charset(inContentType: "text/html;charset=\"windows-1251\""), "windows-1251")
        XCTAssertNil(HTMLParser.charset(inContentType: "text/html"))
        XCTAssertNil(HTMLParser.charset(inContentType: nil))
    }

    /// Служебные блоки вырезаются до разбора, потому что tidy разворачивает
    /// HTML5-элементы. Но осторожно: незакрытый тег не должен съедать страницу.
    func testAnUnclosedBlockDoesNotEatTheRestOfThePage() {
        let stripped = HTMLParser.stripIgnoredBlocks(
            "<html><body><nav><a href=\"/\">Меню<p>Содержание страницы</p></body></html>"
        )
        XCTAssertTrue(stripped.contains("Содержание страницы"), stripped)
    }

    func testATagWhoseNameOnlyStartsTheSameIsKept() {
        let stripped = HTMLParser.stripIgnoredBlocks("<formula>Формула</formula><form>Форма</form>")
        XCTAssertTrue(stripped.contains("Формула"), stripped)
        XCTAssertFalse(stripped.contains("Форма<"), stripped)
    }
}

extension HTMLPageTests {
    /// Верхний заголовок страницы часто лежит внутри `<header>` — так устроена
    /// Википедия и половина шаблонов CMS, — а `<header>` вырезается вместе
    /// с меню. Без корневого раздела Document-based чанкинг режет страницу
    /// как один безымянный кусок.
    func testThePageGetsATopLevelSectionEvenWhenItsH1LivesInTheHeader() throws {
        let page = try parse("""
        <html><head><title>Название статьи</title></head><body>
        <header><h1>Название статьи</h1></header>
        <h2>Раздел</h2><p>Достаточно длинный текст раздела статьи.</p>
        </body></html>
        """)
        XCTAssertEqual(page.headings.first?.level, 1)
        XCTAssertEqual(page.headings.first?.title, "Название статьи")
        XCTAssertEqual(page.headings.map(\.level), [1, 2])
    }

    /// Но если `h1` на странице есть, придумывать второй не надо.
    func testAnExistingH1IsNotDuplicated() throws {
        let page = try parse("""
        <html><head><title>Название</title></head><body>
        <h1>Настоящий заголовок</h1><p>Текст страницы, достаточно длинный.</p>
        </body></html>
        """)
        XCTAssertEqual(page.headings.map(\.title), ["Настоящий заголовок"])
    }
}
