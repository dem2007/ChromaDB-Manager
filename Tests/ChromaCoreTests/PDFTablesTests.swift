import XCTest
import AppKit
import PDFKit
@testable import ChromaCore

/// таблицы PDF собираются по координатам знаков.
///
/// Фикстуры рисуются здесь же: разбирается формат, а не чей-то документ.
/// Рисовать надо построчно (`CTLineDraw`), а не абзацем в рамке, — иначе
/// проверяется перенос текста, а не разбор таблицы.
final class PDFTablesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-pdft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Страница из строк: у каждой — свои отступы и текст.
    @MainActor
    private func draw(_ lines: [[(x: Double, text: String)]], name: String, size: Double = 10) throws -> URL {
        let url = root.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let font = NSFont.systemFont(ofSize: CGFloat(size))
        var y: CGFloat = 780
        for line in lines {
            for piece in line {
                let attributed = NSAttributedString(string: piece.text, attributes: [.font: font])
                context.textPosition = CGPoint(x: piece.x, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            }
            y -= 20
        }
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private func table(rows: Int) -> [[(x: Double, text: String)]] {
        var lines: [[(x: Double, text: String)]] = [[
            (40, "Артикул"), (120, "Наименование"), (380, "Кол-во"), (460, "Цена"),
        ]]
        for number in 1...rows {
            var line: [(x: Double, text: String)] = [
                (40, "АРТ-\(1000 + number)"),
                (120, "Кабель UTP 5e, бухта \(number * 100) м"),
                (460, "\(number * 1250) руб"),
            ]
            // У третьей строки количество не заполнено — и обязано остаться
            // пустой клеткой, а не съехать соседним значением.
            if number != 3 { line.append((380, "\(number)")) }
            lines.append(line)
        }
        return lines
    }

    // MARK: - Сборка

    /// Главное: строки и колонки возвращаются на место, а не рассыпаются
    /// по ячейке на строку и не слипаются в один абзац.
    @MainActor
    func testATableIsRebuiltFromCoordinates() async throws {
        let url = try draw(table(rows: 8), name: "прайс.pdf")
        let extracted = try await PDFExtractor().extract(from: url, options: ExtractionOptions())
        let lines = extracted.plainText.components(separatedBy: "\n")

        XCTAssertEqual(extracted.hasTables, true)
        XCTAssertEqual(lines.first, "| Артикул | Наименование | Кол-во | Цена |")
        XCTAssertEqual(lines[1], "| --- | --- | --- | --- |")
        XCTAssertTrue(
            lines.contains("| АРТ-1001 | Кабель UTP 5e, бухта 100 м | 1 | 1250 руб |"),
            extracted.plainText
        )
    }

    /// Незаполненная клетка остаётся пустой, а не подменяется соседним
    /// значением: цена в колонке количества — это неправда о документе.
    @MainActor
    func testAnEmptyCellKeepsItsColumn() async throws {
        let url = try draw(table(rows: 8), name: "пропуск.pdf")
        let extracted = try await PDFExtractor().extract(from: url, options: ExtractionOptions())
        XCTAssertTrue(
            extracted.plainText.contains("| АРТ-1003 | Кабель UTP 5e, бухта 300 м |  | 3750 руб |"),
            extracted.plainText
        )
    }

    /// Ни один знак не теряется: собранная таблица содержит всё, что было
    /// в тексте страницы.
    @MainActor
    func testNothingIsLostInTheRebuild() async throws {
        let url = try draw(table(rows: 8), name: "полнота.pdf")
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let rebuilt = try XCTUnwrap(PDFPageTables.page(page))

        func dense(_ text: String) -> [Character] {
            text.filter { !$0.isWhitespace && $0 != "|" && $0 != "-" }.sorted()
        }
        XCTAssertEqual(dense(rebuilt), dense(try XCTUnwrap(page.string)))
    }

    // MARK: - Что таблицей не считается

    /// Обычный текст таблицей не объявляется. Признак «в строке есть широкий
    /// промежуток» этого не различает: такие промежутки даёт и выключка
    /// по формату, и абзацный отступ.
    @MainActor
    func testProseIsNotDressedUpAsATable() async throws {
        let sentences = [
            "Настоящий приказ определяет порядок эксплуатации сетевого оборудования",
            "в подразделениях общества, включая порядок технического обслуживания,",
            "учёта неисправностей и планового обновления парка оборудования связи.",
            "Ответственность за исполнение возлагается на руководителей отделов,",
            "а контроль за исполнением приказа оставляю за собой до конца года.",
        ]
        let url = try draw(sentences.map { [(40, $0)] }, name: "проза.pdf")
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertNil(PDFPageTables.page(try XCTUnwrap(document.page(at: 0))))

        let extracted = try await PDFExtractor().extract(from: url, options: ExtractionOptions())
        XCTAssertEqual(extracted.hasTables, false)
    }

    /// Две строки с колонками — не таблица: столько даёт любая подпись
    /// с датой справа.
    @MainActor
    func testTwoAlignedLinesAreNotATable() async throws {
        let url = try draw([
            [(40, "Директор"), (400, "И. И. Петров")],
            [(40, "Главный бухгалтер"), (400, "А. А. Сидорова")],
            [(40, "Настоящим подтверждается, что документ составлен в двух экземплярах.")],
        ], name: "подписи.pdf")
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertNil(PDFPageTables.page(try XCTUnwrap(document.page(at: 0))))
    }
}

/// та же сборка работает и на распознанном скане.
///
/// Скан здесь настоящий: табличная страница рисуется в картинку, то есть
/// текстового слоя у неё не остаётся вовсе, и Vision читает её глазами.
final class OCRTableTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-ocrt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testAScannedTableIsRebuiltFromRecognisedWords() async throws {
        let url = root.appendingPathComponent("скан.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let font = NSFont.systemFont(ofSize: 13)
        let columns: [CGFloat] = [60, 200, 400]
        var y: CGFloat = 740
        let rows: [[String]] = [["Артикул", "Наименование", "Цена"]]
            + (1...7).map { ["АРТ-\(1000 + $0)", "Кабель силовой \($0 * 10) метров", "\($0 * 1250) руб"] }
        for row in rows {
            for (index, value) in row.enumerated() {
                let attributed = NSAttributedString(string: value, attributes: [.font: font])
                context.textPosition = CGPoint(x: columns[index], y: y)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            }
            y -= 40
        }
        context.endPDFPage()
        context.closePDF()

        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let image = try XCTUnwrap(VisionOCRExtractor.render(page))
        let recognised = try await VisionOCRExtractor.recognise(image, languages: ["ru-RU"], timeout: 60)
        try XCTSkipIf(recognised.confidence < 0.5, "распознавание на этой машине не справилось")

        let table = try XCTUnwrap(recognised.table, "таблица должна собраться из распознанных слов")
        let lines = table.components(separatedBy: "\n").filter { TableText.isRow($0) }
        XCTAssertTrue(lines.contains { TableText.isSeparator($0) }, table)
        // Строки таблицы целы: артикул и цена стоят в одной строке, а не
        // рассыпаны по ячейке на строку, как их отдаёт Vision.
        XCTAssertTrue(
            lines.contains { $0.contains("АРТ-1001") && $0.contains("1250") },
            "строка таблицы должна остаться одной строкой:\n\(table)"
        )
        XCTAssertTrue(
            lines.contains { $0.contains("Кабель силовой") },
            "слова внутри ячейки не должны слипаться:\n\(table)"
        )
    }
}
