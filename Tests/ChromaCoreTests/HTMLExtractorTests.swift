import XCTest
import UniformTypeIdentifiers
@testable import ChromaCore

/// 1, I1.2 — HTML читается как документ, а не как текст с разметкой.
final class HTMLExtractorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("html-extractor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(_ name: String, _ contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private let page = """
    <html lang="ru">
      <head>
        <title>Заметка о базах</title>
        <meta name="description" content="Коротко о том, зачем нужны базы данных.">
      </head>
      <body>
        <nav><a href="/">Меню, которого не должно быть в тексте</a></nav>
        <h1>Базы данных</h1>
        <p>Первый абзац про хранение.</p>
        <h2>Векторные</h2>
        <p>Второй абзац про поиск по смыслу.</p>
        <script>console.log("и это тоже не текст")</script>
      </body>
    </html>
    """

    /// Главное: до этого экстрактора `.html` доставался текстовому, и в базу
    /// попадали теги — искать по такому чанку бесполезно.
    func testMarkupDoesNotGetIndexedAsText() async throws {
        let url = try file("page.html", page)
        let extracted = try await ExtractorRegistry.standard().extract(from: url, options: ExtractionOptions())

        XCTAssertEqual(extracted.extractorID, "html", "HTML достаётся HTML-экстрактору, а не текстовому")
        XCTAssertFalse(extracted.plainText.contains("<p>"), extracted.plainText)
        XCTAssertFalse(extracted.plainText.contains("console.log"), "скрипт — не содержание страницы")
        XCTAssertFalse(extracted.plainText.contains("Меню"), "меню иначе попадёт в каждый чанк")
        XCTAssertTrue(extracted.plainText.contains("Первый абзац про хранение."))
    }

    /// Заголовки — это `structure`, а `structure` — это Document-based чанкинг.
    func testHeadingsBecomeStructure() async throws {
        let url = try file("page.html", page)
        let extracted = try await ExtractorRegistry.standard().extract(from: url, options: ExtractionOptions())

        XCTAssertEqual(extracted.structure.map(\.title), ["Базы данных", "Векторные"])
        XCTAssertEqual(extracted.structure.map(\.level), [1, 2])
        XCTAssertEqual(extracted.structureSource, .headings)
        // Смещения обязаны указывать в текст, иначе чанкер режет не там.
        for node in extracted.structure {
            XCTAssertTrue(
                extracted.plainText.dropFirst(node.start).hasPrefix(node.title),
                "заголовок «\(node.title)» не на своём месте"
            )
        }
    }

    func testTitleAndLanguageAreExposedAsDocumentMetadata() async throws {
        let url = try file("page.html", page)
        let extracted = try await ExtractorRegistry.standard().extract(from: url, options: ExtractionOptions())

        XCTAssertEqual(extracted.documentMetadata["title"], "Заметка о базах")
        XCTAssertEqual(extracted.documentMetadata["language"], "ru")
        XCTAssertEqual(extracted.documentMetadata["description"], "Коротко о том, зачем нужны базы данных.")
        XCTAssertEqual(extracted.containerFormat, "html")
    }

    /// Обычный текст и Markdown остаются у текстового экстрактора: HTML-разбор
    /// им только навредил бы.
    func testPlainTextIsStillPlainText() throws {
        XCTAssertTrue(HTMLExtractor().canHandle(.html))
        XCTAssertFalse(HTMLExtractor().canHandle(.plainText))
        XCTAssertFalse(HTMLExtractor().canHandle(UTType(filenameExtension: "md") ?? .plainText))
    }

    func testAPageWithoutTextIsRefusedRatherThanIndexedEmpty() async throws {
        let url = try file("empty.html", "<html><body><div id=\"root\"></div></body></html>")
        do {
            _ = try await ExtractorRegistry.standard().extract(from: url, options: ExtractionOptions())
            XCTFail("пустая страница проиндексирована")
        } catch let error as ExtractionError {
            guard case .empty = error else { return XCTFail("не та ошибка: \(error)") }
        }
    }
}
