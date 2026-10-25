import XCTest
import PDFKit
@testable import ChromaCore

/// записи нумерованной таблицы, абзац через страницу, детальность скана.
final class TableRecordsTests: XCTestCase {
    private let header = ["№", "Наименование", "Кол-во, шт.", "Поставщик", "Цена"]

    // MARK: - Записи

    /// Главное: строки без номера — часть позиции над ними, в её главной
    /// ячейке, со своими значениями под подписями колонок.
    func testUnnumberedRowsJoinTheirPosition() {
        let rows = TableRecords.merged([
            header,
            ["1", "Сервер Тип 1 в составе:", "1", "РФ", "10 000,00"],
            ["", "CPU Альфа 7848R", "2", "", ""],
            ["", "RAM DDR5 32GB", "16", "", ""],
            ["2", "Сервер Тип 2", "1", "РФ", "9 000,00"],
        ])
        XCTAssertEqual(rows, [
            header,
            ["1", "Сервер Тип 1 в составе: CPU Альфа 7848R (Кол-во, шт.: 2); RAM DDR5 32GB (Кол-во, шт.: 16)",
             "1", "РФ", "10 000,00"],
            ["2", "Сервер Тип 2", "1", "РФ", "9 000,00"],
        ])
    }

    /// Хвост названия, вынесенный отдельной строкой, — перенос, а не часть.
    func testAWrappedTailIsJoinedWithASpace() {
        let rows = TableRecords.merged([
            header,
            ["1", "Контроллер дисков C,", "1", "РФ", "100"],
            ["", "2 порта (модель D)", "", "", ""],
            ["2", "ИТ-", "1", "РФ", "50"],
            ["", "инфраструктура", "", "", ""],
        ])
        XCTAssertEqual(rows[1][1], "Контроллер дисков C, 2 порта (модель D)")
        XCTAssertEqual(rows[2][1], "ИТ-инфраструктура")
    }

    /// Строка, разрезанная сборкой надвое, — одна: цена встаёт в свою ячейку.
    func testASplitRowFillsItsGaps() {
        let rows = TableRecords.merged([
            header,
            ["1", "Пусконаладочные работы", "1", "", ""],
            ["", "", "", "РФ", "123 456,00"],
            ["2", "Сертификат", "1", "РФ", "100"],
        ])
        XCTAssertEqual(rows[1], ["1", "Пусконаладочные работы", "1", "РФ", "123 456,00"])
    }

    /// Итог, примечание и полная позиция без номера остаются строками.
    func testTotalsNotesAndCompleteRowsStay() {
        let rows = TableRecords.merged([
            header,
            ["1", "Сервер", "1", "РФ", "100"],
            ["", "Коммутатор", "2", "РФ", "50"],
            ["", "Итого:", "", "", "200"],
            ["2", "Стойка", "1", "РФ", "30"],
            ["", "* Цены указаны с НДС", "", "", ""],
        ])
        XCTAssertEqual(rows.count, 6, "\(rows)")
        XCTAssertEqual(rows[2], ["", "Коммутатор", "2", "РФ", "50"])
    }

    /// Таблица без колонки номера не меняется; колонка количеств за номер
    /// не сходит — значения скачут.
    func testATableWithoutNumberingIsUntouched() {
        let rows = [
            ["Позиция", "Кол-во", "Цена"],
            ["Сервер", "40", "100"],
            ["", "110", "50"],
            ["Стойка", "200", "30"],
        ]
        XCTAssertEqual(TableRecords.merged(rows), rows)
        let quantities = [
            ["Кол-во", "Позиция", "Цена"],
            ["40", "Сервер", "100"],
            ["", "Кабель", ""],
            ["110", "Стойка", "30"],
        ]
        XCTAssertEqual(TableRecords.merged(quantities), quantities)
    }

    /// Колонка «Раздел» служебная: в скобки не попадает, обрывок узнаётся.
    func testTheSectionColumnIsIgnored() {
        let rows = TableRecords.merged([
            ["Раздел", "№", "Позиция", "Кол-во"],
            ["Энск", "4.11", "Пусконаладочные Работы #9", "1"],
            ["Энск", "", "ЭТАП 2", ""],
            ["Энск", "4.12", "Сертификат", "2"],
        ])
        XCTAssertEqual(rows[1], ["Энск", "4.11", "Пусконаладочные Работы #9 ЭТАП 2", "1"])
    }

    /// Позиция, разорванная страницей: части с новой страницы — к ней.
    func testAPositionContinuesOnTheNextPage() {
        let edges = [40.0, 80, 300, 360, 420, 500]
        var blocks: [Int: [TableGeometry.PageBlock]] = [
            0: [.table(rows: [header, ["1", "Сервер в составе:", "1", "РФ", "100"],
                              ["", "CPU", "2", "", ""]], edges: edges)],
            1: [.table(rows: [["", "RAM", "16", "", ""], ["2", "Стойка", "1", "РФ", "30"]], edges: edges)],
        ]
        PDFExtractor.continueTables(&blocks, pageCount: 2)
        guard case .table(let first, _) = blocks[0]?.first, case .table(let second, _) = blocks[1]?.first else {
            return XCTFail("\(blocks)")
        }
        // Сводятся записи при выводе — с настоящей шапкой.
        XCTAssertEqual(TableRecords.merged(first).last?[1], "Сервер в составе: CPU (Кол-во, шт.: 2); RAM (Кол-во, шт.: 16)")
        XCTAssertEqual(second, [header, ["2", "Стойка", "1", "РФ", "30"]])
    }

    /// Неровные строки — сборка, не нашедшая колонок, отдаёт ячейки как
    /// есть: строка длиннее шапки не должна ронять разбор.
    func testRaggedRowsDoNotCrash() {
        let rows = TableRecords.merged([
            ["№", "Позиция"],
            ["1", "Сервер"],
            ["", "CPU", "2", "РФ", "100"],
            ["2", "Стойка"],
        ])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1][1], "Сервер; CPU (2, РФ, 100)")
    }

    /// Позиция длиной в три страницы: средняя страница целиком уходит
    /// к записи, третья всё ещё продолжает ту же таблицу.
    func testAPositionSpanningThreePages() {
        let edges = [40.0, 80, 300, 360, 420, 500]
        var blocks: [Int: [TableGeometry.PageBlock]] = [
            0: [.table(rows: [header, ["1", "Сервер в составе:", "1", "РФ", "100"]], edges: edges)],
            1: [.table(rows: [["", "CPU", "2", "", ""], ["", "RAM", "16", "", ""]], edges: edges)],
            2: [.table(rows: [["", "SSD", "2", "", ""], ["2", "Стойка", "1", "РФ", "30"]], edges: edges)],
        ]
        PDFExtractor.continueTables(&blocks, pageCount: 3)
        guard case .table(let first, _) = blocks[0]?.first else { return XCTFail("\(blocks)") }
        XCTAssertEqual(TableRecords.merged(first).last?[1],
                       "Сервер в составе: CPU (Кол-во, шт.: 2); RAM (Кол-во, шт.: 16); SSD (Кол-во, шт.: 2)")
        XCTAssertEqual(blocks[1], [])
        XCTAssertEqual(blocks[2], [.table(rows: [header, ["2", "Стойка", "1", "РФ", "30"]], edges: edges)])
    }

    // MARK: - Абзац через страницу

    func testAParagraphBrokenByAPageIsBridged() {
        let bridge = { PDFTextReflow.bridge($0, $1, vocabulary: .empty) }
        XCTAssertEqual(bridge("Заказчик вправе направить требование", "об уплате неустойки.")?.separator, " ")
        XCTAssertNil(bridge("Договор вступает в силу.", "после подписания"), "конец предложения")
        XCTAssertNil(bridge("Покупатель вправе", "Поставщик обязан"), "новый абзац с прописной")
        XCTAssertNil(bridge("| Сервер | 1 |", "продолжение"), "таблица на стыке")
        XCTAssertNil(bridge("Текст.\n\n1 Приказ Ведомства № 1 от 01.01.2030", "далее"), "сноска внизу страницы")
    }

    func testAHyphenAtThePageEdgeFollowsTheVocabulary() {
        // Словарь строится, только если в документе есть переносы внутри
        // страниц, — один такой здесь.
        let vocabulary = PDFTextReflow.vocabulary(ofPages: [
            "оборудование поставляется", "ИТ-инфраструктура", "перенос по сло-\nгам и слогам",
        ])
        let solid = PDFTextReflow.bridge("поставка обору-", "дование в срок", vocabulary: vocabulary)
        XCTAssertEqual(solid?.drop, 1)
        XCTAssertEqual(solid?.separator, "")
        let dashed = PDFTextReflow.bridge("сегмент ИТ-", "инфраструктура", vocabulary: vocabulary)
        XCTAssertEqual(dashed?.drop, 0)
        XCTAssertEqual(dashed?.separator, "")
    }

    // MARK: - Детальность скана

    /// Скан 300 dpi на листе A4 — около 4,2 точки на пункт.
    @MainActor
    func testTheScanDetailIsMeasured() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-detail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pixels = try XCTUnwrap(CGContext(
            data: nil, width: 2480, height: 3508, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        pixels.setFillColor(gray: 1, alpha: 1)
        pixels.fill(CGRect(x: 0, y: 0, width: 2480, height: 3508))
        let scan = try XCTUnwrap(pixels.makeImage())
        let url = root.appendingPathComponent("скан.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.draw(scan, in: box)
        context.endPDFPage()
        context.closePDF()
        let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        let detail = try XCTUnwrap(VisionOCRExtractor.detailScale(of: page))
        XCTAssertEqual(Double(detail), 4.17, accuracy: 0.05)
    }
}
