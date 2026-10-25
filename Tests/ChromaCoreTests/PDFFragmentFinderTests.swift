import XCTest
import PDFKit
@testable import ChromaCore

/// какую страницу PDF открыть и что на ней подсветить.
///
/// Тесты идут по настоящему `PDFDocument`, собранному здесь же: правило
/// «страница из метаданных может не совпасть» проверяется только так.
final class PDFFragmentFinderTests: XCTestCase {

    /// Собирает PDF, по странице на переданный текст.
    private func document(pages: [String]) throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { throw XCTSkip("не удалось создать PDF-контекст") }

        for text in pages {
            context.beginPDFPage(nil)
            let attributed = NSAttributedString(
                string: text,
                attributes: [.font: NSFont.systemFont(ofSize: 12)]
            )
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let path = CGPath(rect: box.insetBy(dx: 40, dy: 40), transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter, CFRange(location: 0, length: 0), path, nil
            )
            CTFrameDraw(frame, context)
            context.endPDFPage()
        }
        context.closePDF()

        guard let made = PDFDocument(data: data as Data) else {
            throw XCTSkip("PDFKit не открыл собранный документ")
        }
        return made
    }

    private let target = "Доступность рассчитывается как отношение времени оказания Услуги."

    // MARK: - Нашлось там, где сказано

    func testTheFragmentIsFoundOnThePageFromTheMetadata() throws {
        let pdf = try document(pages: [
            "Первая страница про совсем другое.",
            "Вторая страница. \(target) Продолжение абзаца.",
            "Третья страница про третье.",
        ])
        guard let location = PDFFragmentFinder.locate(chunk: target, in: pdf, startingAt: 2) else {
            return XCTFail("место должно найтись")
        }
        XCTAssertEqual(location.pageIndex, 1, "страница 2 — это индекс 1")
        XCTAssertEqual(location.strategy, .exact)
        XCTAssertNotNil(location.characterRange)
        XCTAssertFalse(location.pageDiffersFromMetadata)
        XCTAssertNil(location.note, "когда всё точно, говорить нечего")
        XCTAssertNotNil(PDFFragmentFinder.selection(for: location, in: pdf))
    }

    // MARK: - Номер страницы сдвинут

    /// Номер приходит из извлечения, а оно нумерует своим счётом: расхождение
    /// на обложку — обычное дело. Функция, ограниченная одной страницей,
    /// работала бы «через раз» ровно на тех документах, ради которых нужна.
    func testAShiftedPageNumberStillFindsTheFragmentAndSaysSo() throws {
        let pdf = try document(pages: [
            "Обложка.",
            "Оглавление.",
            "Текст. \(target) Дальше по тексту.",
        ])
        // Метаданные говорят «страница 1» — извлечение считало без обложки.
        guard let location = PDFFragmentFinder.locate(chunk: target, in: pdf, startingAt: 1) else {
            return XCTFail("место должно найтись и при сдвинутом номере")
        }
        XCTAssertEqual(location.pageIndex, 2)
        XCTAssertTrue(location.pageDiffersFromMetadata)
        XCTAssertTrue(location.note?.contains("странице 3") == true, location.note ?? "—")
    }

    /// Номера нет вовсе — ищем по всему документу.
    func testWithoutAPageHintTheWholeDocumentIsSearched() throws {
        let pdf = try document(pages: ["Раз.", "Два.", "Три. \(target)"])
        let location = PDFFragmentFinder.locate(chunk: target, in: pdf, startingAt: nil)
        XCTAssertEqual(location?.pageIndex, 2)
        XCTAssertEqual(location?.strategy, .exact)
        XCTAssertFalse(location?.pageDiffersFromMetadata ?? true)
    }

    // MARK: - Не нашлось — это исход, а не ошибка

    func testAFragmentThatIsNotThereOpensThePageWithoutHighlight() throws {
        let pdf = try document(pages: ["Раз.", "Два.", "Три."])
        guard let location = PDFFragmentFinder.locate(
            chunk: "Аттестационные испытания объекта информатизации проводятся Исполнителем.",
            in: pdf, startingAt: 2
        ) else { return XCTFail("должен вернуться исход, а не nil") }
        XCTAssertNil(location.characterRange)
        XCTAssertNil(location.strategy)
        XCTAssertEqual(location.pageIndex, 1, "открыта названная страница")
        XCTAssertTrue(location.note?.contains("определить не удалось") == true, location.note ?? "—")
        XCTAssertNil(PDFFragmentFinder.selection(for: location, in: pdf))
    }

    /// Ячейка таблицы на соседней странице не опережает предложение куска,
    /// найденное на другой соседней: ячейки там — после текста.
    func testATableCellOnANeighbourDoesNotBeatTheTextOnAnotherOne() throws {
        let pdf = try document(pages: [
            "Спецификация: Контроллер Альфа Плюс 7848R поставляется в составе сервера.",
            "Раз.",
            "Сервисная поддержка оборудования комплекса длится три года с даты подписания акта.",
        ])
        let chunk = """
        Сервисная поддержка оборудования комплекса длится три года с даты подписания акта.
        | № | Наименование |
        | --- | --- |
        | 1 | Контроллер Альфа Плюс 7848R |
        """
        let location = try XCTUnwrap(PDFFragmentFinder.locate(chunk: chunk, in: pdf, startingAt: 2))
        XCTAssertEqual(location.pageIndex, 2)
        XCTAssertNotEqual(location.strategy, .tableCells)
    }

    /// Названная страница — раньше соседних: кусок находится там, где он
    /// начинается, а не его хвост на следующей. И находится целиком —
    /// таблица на названной странице, текст на следующей.
    func testTheTableOnTheHintedPageBeatsTheTailOnTheNextOne() throws {
        let pdf = try document(pages: [
            "12. Контроллер тип 5 Контроллер Альфа 7718R 13. Контроллер тип 6 Контроллер Альфа 7414R",
            "Требования к условиям замены Товара приведены в разделе девятом настоящего договора.",
        ])
        let chunk = """
        | № | Наименование | Значение |
        | --- | --- | --- |
        | 12. | Контроллер тип 5 | Контроллер Альфа 7718R |
        | 13. | Контроллер тип 6 | Контроллер Альфа 7414R |
        Требования к условиям замены Товара приведены в разделе девятом настоящего договора.
        """
        let location = try XCTUnwrap(PDFFragmentFinder.locate(chunk: chunk, in: pdf, startingAt: 1))
        XCTAssertEqual(location.pageIndex, 0)
        XCTAssertEqual(location.strategy, .allParts)
        XCTAssertEqual(location.end?.pageIndex, 1, "подсветка переходит на следующую страницу")
        XCTAssertFalse(location.pageDiffersFromMetadata)
        let selection = try XCTUnwrap(PDFFragmentFinder.selection(for: location, in: pdf))
        XCTAssertEqual(selection.pages.count, 2)
    }

    /// Окно из трёх страниц не возвращает (ревью…): хвост
    /// куска на следующей странице, найденный самым длинным предложением,
    /// не опережает таблицу на названной. PDFKit читает таблицу колонками,
    /// частей по порядку набирается меньше половины, и таблицу находят её
    /// ячейки — на названной странице, как и до окна.
    func testTheTailSentenceOnTheNextPageDoesNotBeatTheHintedTable() throws {
        let columns: [[String]] = [
            (1...5).map { "Контроллер тип \($0) первой поставки" },
            (1...5).map { "Альфа Плюс 77\($0)8R с частотой 3,\($0) ГГц" },
            (1...5).map { "Гарантия поставщика \($0)6 месяцев с даты" },
            (1...5).map { "Склад заказчика в городе номер \($0)" },
        ]
        let page = columns.map { $0.joined(separator: " ") }.joined(separator: "\n")
        let tail = "Поставка партиями. Требования к замене Товара приведены в разделе девятом."
        let pdf = try document(pages: [page, tail])
        var chunk = "| № | Наименование | Значение | Гарантия | Склад |\n| --- | --- | --- | --- | --- |\n"
        for row in 0..<5 {
            chunk += "| \(row + 1). | " + columns.map { $0[row] }.joined(separator: " | ") + " |\n"
        }
        chunk += tail
        let location = try XCTUnwrap(PDFFragmentFinder.locate(chunk: chunk, in: pdf, startingAt: 1))
        XCTAssertEqual(location.pageIndex, 0, "таблица на названной странице, а не хвост на следующей")
        XCTAssertEqual(location.strategy, .tableCells)
    }

    /// Номер за пределами документа не должен ронять просмотр — страница
    /// прижимается к последней.
    func testAPageNumberBeyondTheDocumentIsClamped() throws {
        let pdf = try document(pages: ["Раз.", "Два."])
        let location = PDFFragmentFinder.locate(chunk: "ничего похожего", in: pdf, startingAt: 99)
        XCTAssertEqual(location?.pageIndex, 1)
    }

    func testAnEmptyDocumentHasNoLocation() {
        XCTAssertNil(PDFFragmentFinder.locate(chunk: "текст", in: PDFDocument(), startingAt: 1))
    }

    // MARK: - Порядок обхода

    /// Кольцом от подсказки, а не подряд с начала: если номер сдвинут, то на
    /// единицы, и правильная страница найдётся первой же. На документе
    /// в тысячу страниц это разница между мгновением и секундами.
    func testTheSearchOrderExpandsAroundTheHint() {
        XCTAssertEqual(
            PDFFragmentFinder.searchOrder(hint: 5, pageCount: 10),
            [5, 4, 6, 3, 7, 2, 8, 1, 9, 0]
        )
        // У края кольцо не выходит за границы и ничего не теряет.
        XCTAssertEqual(PDFFragmentFinder.searchOrder(hint: 0, pageCount: 4), [0, 1, 2, 3])
        XCTAssertEqual(PDFFragmentFinder.searchOrder(hint: 3, pageCount: 4), [3, 2, 1, 0])
        // Без подсказки — просто по порядку.
        XCTAssertEqual(PDFFragmentFinder.searchOrder(hint: nil, pageCount: 3), [0, 1, 2])
        // Каждая страница ровно один раз, сколько бы их ни было.
        let order = PDFFragmentFinder.searchOrder(hint: 7, pageCount: 20)
        XCTAssertEqual(Set(order).count, 20)
        XCTAssertEqual(order.count, 20)
    }
}
