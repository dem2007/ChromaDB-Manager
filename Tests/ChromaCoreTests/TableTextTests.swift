import XCTest
@testable import ChromaCore

/// один вид таблицы на все источники.
final class TableTextTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-tt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Главное: один вид

    /// Один и тот же прайс, сохранённый книгой и документом Word, даёт
    /// **один и тот же** текст таблицы. Пока это было не так, чанки одного
    /// прайса из двух форматов не совпадали ни текстом, ни длиной.
    func testTheSameTableFromWordAndFromAWorkbookReadsTheSame() async throws {
        let rows = [
            ["Артикул", "Наименование", "Кол-во"],
            ["АРТ-1001", "Кабель UTP 5e", "12"],
            ["АРТ-1002", "Розетка RJ-45", "40"],
        ]

        var body = "<w:tbl>"
        for row in rows {
            body += "<w:tr>" + row.map { DocxFixture.cell(DocxFixture.paragraph($0), nil) }.joined() + "</w:tr>"
        }
        body += "</w:tbl>"
        let word = root.appendingPathComponent("прайс.docx")
        try DocxFixture(body: body).build().write(to: word)
        let extracted = try await OfficeExtractor().extract(from: word, options: ExtractionOptions())

        let book = root.appendingPathComponent("прайс.xlsx")
        try XLSXFixtureBuilder(sheets: [.init(
            name: "Прайс", rows: rows.map { $0.map { XLSXFixtureBuilder.Cell.shared($0) } }
        )]).build().write(to: book)
        let reader = try XLSXReader(url: book)
        let sheet = try XCTUnwrap(reader.sheets.first)
        let rendered = SheetRenderer.render(rows: try reader.rows(of: sheet).rows, headerRow: 1)

        XCTAssertEqual(extracted.plainText, rendered.text)
    }

    // MARK: - Разметка

    /// Пустая ячейка остаётся на своём месте. Иначе значения соседних колонок
    /// съезжают влево, и строка, где не заполнили цену, приходит в базу так,
    /// будто цена стоит в колонке количества.
    func testAnEmptyCellKeepsItsPlace() {
        let text = TableText.render([
            ["Артикул", "Цена", "Склад"],
            ["АРТ-1", "", "Москва"],
        ])
        XCTAssertEqual(text.components(separatedBy: "\n").last, "| АРТ-1 |  | Москва |")
    }

    /// Труба внутри значения закрыла бы колонку раньше времени, перевод
    /// строки — строку. Значение чужое: его экранируют, а не выбрасывают.
    func testPipesAndNewlinesAreEscaped() {
        let text = TableText.render([["а", "б"], ["две|трубы", "две\nстроки"]])
        XCTAssertTrue(text.contains("| две\\|трубы | две строки |"), text)
    }

    /// Таблица из одной колонки — список строк, а не таблица: рамка вокруг
    /// него только мешает и человеку, и модели.
    func testASingleColumnIsNotDressedUpAsATable() {
        let text = TableText.render([["первая"], ["вторая"]])
        XCTAssertEqual(text, "первая\nвторая")
    }

    /// Шапку таблицы можно узнать машинно — на этом держится её повтор
    /// в кусках длинной таблицы.
    func testTheHeaderIsRecognisable() {
        let lines = TableText.render([["а", "б"], ["1", "2"]]).components(separatedBy: "\n")
        XCTAssertTrue(TableText.isRow(lines[0]))
        XCTAssertTrue(TableText.isSeparator(lines[1]))
        XCTAssertFalse(TableText.isSeparator(lines[2]))
        XCTAssertFalse(TableText.isRow("обычный абзац"))
    }
}

/// признак `has_tables` ставят все экстракторы, а не один Word.
///
/// Без него фильтр «документы с таблицами» не видел ни PDF, ни веб-страниц,
/// ни книг — то есть врал молча.
final class TableFlagTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-tf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Таблица веб-страницы приходит той же разметкой, что и остальные,
    /// а не ячейками через пробел, где колонки от слов неотличимы.
    func testAWebPageTableBecomesAMarkdownTable() throws {
        let html = """
        <html><body><h1>Прайс</h1><table>
        <tr><th>Артикул</th><th>Наименование</th><th>Цена</th></tr>
        <tr><td>АРТ-1001</td><td>Кабель UTP 5e</td><td>1250</td></tr>
        <tr><td>АРТ-1002</td><td>Розетка RJ-45</td><td>340</td></tr>
        </table></body></html>
        """
        let page = try HTMLParser.parse(html)
        XCTAssertTrue(page.plainText.contains("| Артикул | Наименование | Цена |"), page.plainText)
        XCTAssertTrue(page.plainText.contains("| --- | --- | --- |"), page.plainText)
        XCTAssertTrue(page.plainText.contains("| АРТ-1001 | Кабель UTP 5e | 1250 |"), page.plainText)
        XCTAssertTrue(page.hasTables)
    }

    /// Страница без таблицы этого признака не получает: предупреждать обо всём
    /// подряд — значит научить не читать предупреждения.
    func testAWebPageWithoutTablesSaysSo() throws {
        let page = try HTMLParser.parse("<html><body><p>Обычный абзац страницы.</p></body></html>")
        XCTAssertFalse(page.hasTables)
    }

    /// Markdown с таблицей: текст уже написан нужным видом — его надо только
    /// заметить.
    func testAMarkdownTableIsNoticed() async throws {
        let url = root.appendingPathComponent("прайс.md")
        try """
        # Прайс

        | Артикул | Цена |
        | --- | --- |
        | АРТ-1001 | 1250 |
        """.write(to: url, atomically: true, encoding: .utf8)
        let extracted = try await PlainTextExtractor().extract(from: url, options: ExtractionOptions())
        XCTAssertEqual(extracted.hasTables, true)
    }

    func testAPlainTextFileWithoutTablesSaysSo() async throws {
        let url = root.appendingPathComponent("записка.txt")
        try "Обычная записка без единой таблицы.".write(to: url, atomically: true, encoding: .utf8)
        let extracted = try await PlainTextExtractor().extract(from: url, options: ExtractionOptions())
        XCTAssertEqual(extracted.hasTables, false)
    }
}

/// ключ строки попадает в её текст, а не только в метаданные.
final class RowKeyInTextTests: XCTestCase {
    private func layout() -> SheetLayout {
        SheetLayout(headerRow: 1, columns: ["Артикул", "Наименование", "Цена"])
    }

    private func row() -> SheetRow {
        SheetRow(number: 2, cells: [
            0: .text("АРТ-1015"), 1: .text("Кабель UTP категории 5e"), 2: .number(1250),
        ])
    }

    private func mapping(template: String = "") -> TableMapping {
        TableMapping(
            sheetName: "Прайс", mode: .dataTable, headerRow: 1,
            columns: ["Артикул", "Наименование", "Цена"],
            roles: ["Артикул": .metadata, "Наименование": .text, "Цена": .metadata],
            keyColumn: "Артикул", textTemplate: template
        )
    }

    /// Главное: артикул есть в тексте документа. Раньше строка не находилась
    /// по нему ни вектором, ни текстовой стадией — работал только фильтр
    /// по метаданным, о чём человек знать не обязан.
    func testTheKeyIsPartOfTheText() {
        let text = RowMapper.text(for: row(), mapping: mapping(), layout: layout())
        XCTAssertEqual(text, "Артикул: АРТ-1015\nНаименование: Кабель UTP категории 5e")
    }

    /// Шаблон, в котором человек уже вывел артикул, не получает его дважды.
    func testATemplateThatAlreadyShowsTheKeyIsLeftAlone() {
        let text = RowMapper.text(
            for: row(), mapping: mapping(template: "{Артикул} — {Наименование}"), layout: layout()
        )
        XCTAssertEqual(text, "АРТ-1015 — Кабель UTP категории 5e")
    }

    /// Без ключевой колонки ничего не дописывается.
    func testWithoutAKeyNothingIsAdded() {
        var mapping = mapping()
        mapping.keyColumn = nil
        let text = RowMapper.text(for: row(), mapping: mapping, layout: layout())
        XCTAssertEqual(text, "Наименование: Кабель UTP категории 5e")
    }

    /// Пустой ключ — не ключ: строка без артикула не получает пустую подпись.
    func testAnEmptyKeyAddsNothing() {
        let empty = SheetRow(number: 3, cells: [1: .text("Кабель без артикула")])
        let text = RowMapper.text(for: empty, mapping: mapping(), layout: layout())
        XCTAssertEqual(text, "Наименование: Кабель без артикула")
    }
}

/// Разбор кода 15 августа 2026: что нашёл code-review по этой работе.
final class TableReviewFixesTests: XCTestCase {
    /// Ссылки из ячеек таблицы обязаны попадать в обход сайта: у каталога
    /// ссылки на товары живут именно там, и без них страницы товаров молча
    /// перестают индексироваться.
    func testLinksInsideAWebTableAreCollected() throws {
        let html = """
        <html><body><table>
        <tr><th>Товар</th><th>Ссылка</th></tr>
        <tr><td>Кабель</td><td><a href="/product/1">подробнее</a></td></tr>
        <tr><td>Розетка</td><td><a href="/product/2">подробнее</a></td></tr>
        </table><a href="/next">дальше</a></body></html>
        """
        let page = try HTMLParser.parse(html, baseURL: URL(string: "https://example.org/shop/"))
        XCTAssertEqual(page.links, [
            "https://example.org/product/1",
            "https://example.org/product/2",
            "https://example.org/next",
        ])
    }

    /// Ключ дописывается, даже если его значение случайно встретилось внутри
    /// другого слова: «12» внутри «2012» — не упоминание артикула.
    func testAKeyHiddenInsideAnotherNumberStillGetsItsLine() {
        let layout = SheetLayout(headerRow: 1, columns: ["Код", "Описание"])
        let row = SheetRow(number: 2, cells: [0: .text("12"), 1: .text("Отчёт за 2012 год")])
        let mapping = TableMapping(
            sheetName: "Лист", mode: .dataTable, headerRow: 1,
            columns: ["Код", "Описание"],
            roles: ["Код": .metadata, "Описание": .text],
            keyColumn: "Код"
        )
        XCTAssertEqual(
            RowMapper.text(for: row, mapping: mapping, layout: layout),
            "Код: 12\nОписание: Отчёт за 2012 год"
        )
    }

    /// А настоящее упоминание ключа второй раз не дописывается.
    func testAKeyAlreadyInTheTextIsNotRepeated() {
        let layout = SheetLayout(headerRow: 1, columns: ["Код", "Описание"])
        let row = SheetRow(number: 2, cells: [0: .text("АРТ-1"), 1: .text("АРТ-1, кабель")])
        let mapping = TableMapping(
            sheetName: "Лист", mode: .dataTable, headerRow: 1,
            columns: ["Код", "Описание"],
            roles: ["Код": .metadata, "Описание": .text],
            keyColumn: "Код"
        )
        XCTAssertEqual(
            RowMapper.text(for: row, mapping: mapping, layout: layout),
            "Описание: АРТ-1, кабель"
        )
    }
}
