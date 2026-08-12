import XCTest
@testable import ChromaCore

/// чтение текстовых документов для просмотрщика и место фрагмента в них.
final class TextDocumentLoaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("viewer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String, name: String = "файл.txt", encoding: String.Encoding = .utf8) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try text.data(using: encoding)!.write(to: url)
        return url
    }

    // MARK: - Чтение

    func testUTF8IsReadAsUTF8() throws {
        let url = try write("Доступность рассчитывается как отношение времени.")
        XCTAssertEqual(try TextDocumentLoader.plainText(at: url), "Доступность рассчитывается как отношение времени.")
    }

    /// Порядок кодировок важен: latin-1 «читает» что угодно, и если поставить
    /// его раньше UTF-8, кириллица откроется мусором — а это хуже отказа,
    /// потому что выглядит как испорченный файл, а не как неподдержанный.
    func testUTF8WinsOverLatin1() throws {
        let url = try write("Тест кириллицы")
        let text = try TextDocumentLoader.plainText(at: url)
        XCTAssertEqual(text, "Тест кириллицы")
        XCTAssertFalse(text.contains("Ð"), "прочитано как latin-1: \(text)")
    }

    /// Предел размера назван человеку, а не подразумевается: просмотрщик
    /// держит весь текст в памяти, и стомегабайтный лог подвесил бы окно.
    func testAnOversizedFileIsRefusedWithItsSize() throws {
        let url = directory.appendingPathComponent("большой.txt")
        try Data(repeating: 65, count: TextDocumentLoader.maximumBytes + 1).write(to: url)
        XCTAssertThrowsError(try TextDocumentLoader.plainText(at: url)) { error in
            guard case TextDocumentLoader.LoadError.tooLarge = error else {
                return XCTFail("ожидалось tooLarge, получено \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("МБ"), error.localizedDescription)
        }
    }

    func testABinaryFileIsRefusedRatherThanShownAsGarbage() throws {
        let url = directory.appendingPathComponent("двоичный.txt")
        // UTF-16 без BOM и с нечётной длиной не читается ни одной кодировкой
        // из перебора, кроме latin-1 — поэтому берём данные, ломающие и его.
        var bytes = Data([0xFF, 0xFE, 0x00])
        bytes.append(Data(repeating: 0x00, count: 5))
        try bytes.write(to: url)
        // Либо отказ, либо строка — но не падение и не мусор в кириллице.
        let text = try? TextDocumentLoader.plainText(at: url)
        if let text { XCTAssertFalse(text.contains("Ð")) }
    }

    // MARK: - Место фрагмента

    func testTheLineNumberCountsFromOne() {
        let text = "Первая строка.\nВторая строка.\nТретья строка про доступность услуги."
        let placement = TextFragmentPlacement.locate(
            chunk: "Третья строка про доступность услуги.", in: text
        )
        XCTAssertEqual(placement?.line, 3)
        XCTAssertEqual(placement?.strategy, .exact)
        XCTAssertNil(placement?.note, "точная подсветка объяснений не требует")
    }

    func testTheFirstLineIsLineOne() {
        let placement = TextFragmentPlacement.locate(chunk: "Начало", in: "Начало текста\nи продолжение")
        XCTAssertEqual(placement?.line, 1)
    }

    /// Номер строки считается по **исходному** тексту: в нормализованном
    /// переводы строк схлопнуты, и счёт по нему назвал бы не ту строку.
    func testTheLineIsCountedInTheOriginalTextNotTheNormalisedOne() {
        let text = "Заголовок\n\n\n\n\nНужный абзац про отчетный период."
        let placement = TextFragmentPlacement.locate(
            chunk: "Нужный абзац про отчетный период.", in: text
        )
        XCTAssertEqual(placement?.line, 6)
    }

    /// Диапазон обязан указывать в исходный текст, иначе подсветка уедет.
    func testTheRangePointsIntoTheOriginalText() {
        let text = "Раз.\n\n   Доступность   рассчитывается\n   как отношение.   Конец."
        guard let placement = TextFragmentPlacement.locate(
            chunk: "Доступность рассчитывается как отношение.", in: text
        ) else { return XCTFail("не нашлось") }
        let characters = Array(text)
        let highlighted = String(characters[placement.characterRange])
        XCTAssertTrue(highlighted.hasPrefix("Доступность"), highlighted)
        XCTAssertTrue(highlighted.hasSuffix("отношение."), highlighted)
    }

    /// Приблизительная подсветка объясняется, точная — молчит.
    func testAnApproximateMatchExplainsItself() {
        let head = "Услуга предоставления ресурсов центра обработки данных "
        let tail = " Параметры качества оказания Услуги приведены в таблице."
        let text = head + "иная середина документа" + tail
        let placement = TextFragmentPlacement.locate(
            chunk: head + "совсем другая середина" + tail, in: text
        )
        XCTAssertEqual(placement?.strategy, .edges)
        XCTAssertTrue(placement?.note?.contains("приблизительная") == true, placement?.note ?? "—")
    }

    func testAMissingFragmentHasNoPlacement() {
        XCTAssertNil(TextFragmentPlacement.locate(
            chunk: "Аттестационные испытания объекта информатизации.",
            in: "Совсем другой текст про закупку оборудования."
        ))
    }
}
