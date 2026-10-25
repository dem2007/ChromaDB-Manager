import XCTest
import AppKit
import PDFKit
@testable import ChromaCore

/// Пробел из текста страницы — граница слова и без видимого промежутка
///: в ужатой ячейке таблицы пробел шириной 0,2 пункта, и по одному
/// промежутку «Наименование характеристики» склеивалось в одно слово.
final class TextLayerSpaceTests: XCTestCase {
    private func glyphs(_ text: String, from x: Double, spaceBefore: Bool = false) -> [TableGeometry.Word] {
        text.enumerated().map { offset, character in
            TableGeometry.Word(
                box: CGRect(x: x + Double(offset) * 4, y: 100, width: 4, height: 5),
                text: String(character),
                spaceBefore: spaceBefore && offset == 0
            )
        }
    }

    func testATextLayerSpaceSeparatesWordsWithoutAGap() {
        // «е» кончается на 48, «х» начинается на 48.2 — промежутка не видно.
        let words = glyphs("Наименование", from: 0) + glyphs("характеристики", from: 48.2, spaceBefore: true)
        let lines = TableGeometry.lines(from: words, height: 5)
        XCTAssertEqual(lines.map(\.text), ["Наименование характеристики"])
    }

    func testWithoutASpaceTheLettersStayOneWord() {
        let words = glyphs("Наименование", from: 0) + glyphs("характеристики", from: 48.2)
        XCTAssertEqual(TableGeometry.lines(from: words, height: 5).map(\.text), ["Наименованиехарактеристики"])
    }

    /// Пробел не делит строку на колонки: граница колонки — по промежутку.
    func testASpaceDoesNotSplitACell() {
        let words = glyphs("Наименование", from: 0) + glyphs("характеристики", from: 48.2, spaceBefore: true)
        XCTAssertEqual(TableGeometry.lines(from: words, height: 5).first?.cells.count, 1)
    }

    // MARK: - Настоящая страница

    /// Страница, где у пробела «Наименование характеристики» ширина 0,2
    /// пункта, а «АРТ-1001» набрано двумя шрифтами — между кусками PDFKit
    /// вставляет в текст пробел от себя.
    private func condensedPage() throws -> PDFPage {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let font = NSFont.systemFont(ofSize: 10)
        let space = NSAttributedString(string: " ", attributes: [.font: font]).size().width
        let condensed = NSMutableAttributedString(string: "Наименование характеристики", attributes: [.font: font])
        condensed.addAttribute(.kern, value: -(space - 0.2), range: NSRange(location: 12, length: 1))
        let lines: [NSAttributedString] = [
            condensed,
            NSAttributedString(string: "АРТ-1001", attributes: [.font: font]),
            NSAttributedString(string: "Объём оперативной памяти не менее шестидесяти четырёх гигабайт", attributes: [.font: font]),
        ]
        var y: CGFloat = 780
        for line in lines {
            context.textPosition = CGPoint(x: 40, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(line), context)
            y -= 20
        }
        context.endPDFPage()
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data)?.page(at: 0))
    }

    /// Пробел самого документа — граница слова и без промежутка; пробел,
    /// вставленный PDFKit на стыке шрифтов, — нет.
    func testOnlyTheDocumentsOwnSpaceSeparatesWords() throws {
        let page = try condensedPage()
        let words = try XCTUnwrap(PDFPageTables.words(of: page), "у страницы есть координаты знаков")
        let text = words.map(\.text).joined()
        let x = try XCTUnwrap(text.range(of: "ехар").map { text.distance(from: text.startIndex, to: $0.lowerBound) + 1 })
        XCTAssertTrue(words[x].spaceBefore, "перед «х» — пробел документа шириной 0,2 пункта")
        let dash = try XCTUnwrap(text.range(of: "АРТ-").map { text.distance(from: text.startIndex, to: $0.lowerBound) + 3 })
        XCTAssertFalse(words[dash].spaceBefore, "пробел перед «-1001» вставил PDFKit — его в документе нет")
        let lines = TableGeometry.lines(from: words, height: TableGeometry.medianHeight(of: words))
        XCTAssertTrue(lines.map(\.text).contains("Наименование характеристики"), lines.map(\.text).joined(separator: " / "))
        XCTAssertTrue(lines.map(\.text).contains("АРТ-1001"), lines.map(\.text).joined(separator: " / "))
    }
}

