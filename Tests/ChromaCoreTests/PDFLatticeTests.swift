import XCTest
import AppKit
import PDFKit
@testable import ChromaCore

/// таблицы PDF по рамке, выключка, переносы, края страниц.
final class PDFLatticeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-lattice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private struct Text { var x: Double; var y: Double; var text: String }

    /// Страница: линии и надписи. Линии — обводкой, как рисует их Word.
    @MainActor
    private func draw(lines: [(CGPoint, CGPoint)], texts: [Text], name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setLineWidth(0.5)
        for (from, to) in lines {
            context.move(to: from)
            context.addLine(to: to)
        }
        context.strokePath()
        let font = NSFont.systemFont(ofSize: 10)
        for text in texts {
            let attributed = NSAttributedString(string: text.text, attributes: [.font: font])
            context.textPosition = CGPoint(x: text.x, y: text.y)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        context.endPDFPage()
        context.closePDF()
        return url
    }

    /// Расчёт КП: «Поставка…» объединена на три позиции — между её клетками
    /// линии нет. Строки сетки: 760 (верх) … 680 (низ), по 20 пунктов.
    @MainActor
    private func offer() throws -> URL {
        let xs: [CGFloat] = [40, 200, 380, 480]
        let ys: [CGFloat] = [760, 740, 720, 700, 680]
        var lines: [(CGPoint, CGPoint)] = []
        // Вертикали — на всю высоту.
        for x in xs { lines.append((CGPoint(x: x, y: ys[0]), CGPoint(x: x, y: ys[4]))) }
        // Горизонтали: верх, низ шапки и низ таблицы — на всю ширину; между
        // позициями — только справа от объединённой ячейки.
        for y in [ys[0], ys[1], ys[4]] { lines.append((CGPoint(x: xs[0], y: y), CGPoint(x: xs[3], y: y))) }
        for y in [ys[2], ys[3]] { lines.append((CGPoint(x: xs[1], y: y), CGPoint(x: xs[3], y: y))) }
        let texts = [
            Text(x: 44, y: 746, text: "Наименование"), Text(x: 204, y: 746, text: "Позиция"),
            Text(x: 384, y: 746, text: "Цена"),
            Text(x: 44, y: 712, text: "Поставка в г. Энск"),
            Text(x: 204, y: 726, text: "Узел управления #1"), Text(x: 384, y: 726, text: "123 456 789"),
            Text(x: 204, y: 706, text: "Узел хранения #1"), Text(x: 384, y: 706, text: "112 233 445"),
            Text(x: 204, y: 686, text: "Пусконаладка #1"), Text(x: 384, y: 686, text: "101 202 303"),
        ]
        return try draw(lines: lines, texts: texts, name: "кп.pdf")
    }

    /// Главное: объединённая ячейка рамки — в каждой строке.
    @MainActor
    func testARuledTableKeepsAMergedCellInEveryRow() async throws {
        let extracted = try await PDFExtractor().extract(from: try offer(), options: ExtractionOptions())
        let rows = extracted.plainText.components(separatedBy: "\n").filter { $0.hasPrefix("|") }
        XCTAssertEqual(rows, [
            "| Наименование | Позиция | Цена |", "| --- | --- | --- |",
            "| Поставка в г. Энск | Узел управления #1 | 123 456 789 |",
            "| Поставка в г. Энск | Узел хранения #1 | 112 233 445 |",
            "| Поставка в г. Энск | Пусконаладка #1 | 101 202 303 |",
        ], extracted.plainText)
        XCTAssertEqual(extracted.hasTables, true)
    }

    /// Ячейка в две строки — одно значение, а не две строки таблицы.
    @MainActor
    func testATwoLineCellIsOneValue() async throws {
        let xs: [CGFloat] = [40, 250, 400]
        let ys: [CGFloat] = [760, 740, 700]
        var lines: [(CGPoint, CGPoint)] = xs.map { (CGPoint(x: $0, y: ys[0]), CGPoint(x: $0, y: ys[2])) }
        lines += ys.map { (CGPoint(x: xs[0], y: $0), CGPoint(x: xs[2], y: $0)) }
        let url = try draw(lines: lines, texts: [
            Text(x: 44, y: 746, text: "Позиция"), Text(x: 254, y: 746, text: "Кол-во"),
            Text(x: 44, y: 726, text: "Контроллер дисков C,"), Text(x: 44, y: 712, text: "2 порта (модель D)"),
            Text(x: 254, y: 718, text: "1"),
        ], name: "две-строки.pdf")
        let extracted = try await PDFExtractor().extract(from: url, options: ExtractionOptions())
        XCTAssertTrue(
            extracted.plainText.contains("| Контроллер дисков C, 2 порта (модель D) | 1 |"),
            extracted.plainText
        )
    }

    /// Рамка вокруг абзаца — не таблица.
    func testASingleFrameIsNotATable() {
        let rulings = TableLattice.Rulings(
            horizontal: [.init(position: 700, from: 40, to: 500), .init(position: 600, from: 40, to: 500)],
            vertical: [.init(position: 40, from: 600, to: 700), .init(position: 500, from: 600, to: 700)]
        )
        XCTAssertTrue(TableLattice.grids(from: rulings, tolerance: 2.5).isEmpty)
    }

    // MARK: - Выключка и переносы

    private func cells(_ starts: [(Double, String)], width: Double = 8) -> [TableGeometry.Cell] {
        starts.map { TableGeometry.Cell(minX: $0.0, maxX: $0.0 + Double($0.1.count) * width / 2, text: $0.1) }
    }

    /// Строка, растянутая по ширине, — одна ячейка.
    func testAJustifiedLineIsOneCell() {
        var x = 62.0
        var parts: [TableGeometry.Cell] = []
        for word in ["порядке", "утверждённых", "Сторонами", "Планов", "направлять", "Заказчику"] {
            let width = Double(word.count) * 5
            parts.append(TableGeometry.Cell(minX: x, maxX: x + width, text: word))
            x += width + 7
        }
        let joined = TableGeometry.joiningJustified(parts)
        XCTAssertEqual(joined.map(\.text), ["порядке утверждённых Сторонами Планов направлять Заказчику"])
    }

    /// Номер пункта с табуляцией остаётся отдельной ячейкой, числовая
    /// строка таблицы не склеивается.
    func testAWideGapAndNumbersSurvive() {
        var parts = [TableGeometry.Cell(minX: 92, maxX: 116, text: "1.1.5.")]
        var x = 134.0
        for word in ["Отчётный", "период", "–", "календарный", "месяц", "при"] {
            let width = Double(word.count) * 5
            parts.append(TableGeometry.Cell(minX: x, maxX: x + width, text: word))
            x += width + 5
        }
        XCTAssertEqual(TableGeometry.joiningJustified(parts).map(\.text), ["1.1.5.", "Отчётный период – календарный месяц при"])

        let numbers = [("1", 40.0), ("1 234,50", 100), ("246,90", 180), ("1 481,40", 260)].map {
            TableGeometry.Cell(minX: $0.1, maxX: $0.1 + 40, text: $0.0)
        }
        XCTAssertEqual(TableGeometry.joiningJustified(numbers).count, 4)
    }

    /// Перенос названия позиции не рвёт таблицу.
    func testAWrappedValueDoesNotBreakTheTable() {
        func line(_ y: Double, _ parts: [(Double, String)]) -> TableGeometry.Line {
            TableGeometry.Line(y: y, height: 6, cells: parts.map {
                TableGeometry.Cell(minX: $0.0, maxX: $0.0 + 60, text: $0.1)
            })
        }
        let lines = [
            line(700, [(110, "Сетевая карта A"), (390, "2")]),
            line(690, [(110, "Модуль связи B"), (390, "4")]),
            line(680, [(110, "Контроллер дисков C,")]),
            line(670, [(110, "2 порта (модель D)"), (390, "1")]),
            line(660, [(110, "Блок питания E"), (390, "2")]),
        ]
        let blocks = TableGeometry.assess(lines).blocks ?? []
        XCTAssertEqual(blocks.count, 1, "одна таблица, а не таблица и текст: \(blocks)")
    }

    /// Пункты с номером на табуляции — список, а не таблица, и оговорки
    /// «таблица не собрана» не дают.
    func testNumberedItemsAreNotATable() {
        func line(_ y: Double, _ parts: [(Double, String)]) -> TableGeometry.Line {
            TableGeometry.Line(y: y, height: 5, cells: parts.map {
                TableGeometry.Cell(minX: $0.0, maxX: $0.0 + Double($0.1.count) * 5, text: $0.1)
            })
        }
        let lines = [
            line(700, [(92, "1.1.1."), (133, "Заявка – запрос на выполнение Работ, принятый Сторонами")]),
            line(690, [(69, "разделом 5 настоящего Договора.")]),
            line(680, [(92, "1.1.2."), (133, "Место работ – это указанный в принятой Заявке адрес")]),
            line(670, [(92, "1.1.3."), (133, "Этап Работ – совокупность частей Работ")]),
            line(660, [(69, "этапа): не позднее"), (177, "01.03.2031г.")]),
            line(650, [(92, "1.1.4."), (133, "Сдача – передача результата Работ")]),
        ]
        let assessed = TableGeometry.assess(lines)
        XCTAssertNil(assessed.blocks)
        XCTAssertFalse(assessed.unassembledTable)
    }

    // MARK: - Края страниц

    func testARepeatedStampIsRemovedFromTheEdges() {
        let topics = ["поставка", "приёмка", "оплата", "гарантия", "споры"]
        let pages = topics.enumerated().map { number, topic in
            "Раздел про \(topic).\nУсловия: \(topic) по договору.\nПередан через Диадок 01.02.2030 10:00 GMT+03:00\n"
                + "Страница \(number + 1) из 5"
        }
        let furniture = PDFFurniture(pages: pages)
        var seen: Set<String> = []
        // Первое появление остаётся — один раз в тексте штампу место.
        XCTAssertEqual(furniture.cleaned(pages[0].components(separatedBy: "\n"), seen: &seen).count, 4)
        XCTAssertEqual(
            furniture.cleaned(pages[2].components(separatedBy: "\n"), seen: &seen),
            ["Раздел про оплата.", "Условия: оплата по договору."]
        )
    }

    func testARepeatedPhraseInTheMiddleStays() {
        let middle = (1...12).map { "строка \($0) обычного текста страницы" }
        let pages = (1...5).map { _ in (["Шапка"] + middle.prefix(3) + ["Значение не может изменяться"] + middle).joined(separator: "\n") }
        let furniture = PDFFurniture(pages: pages)
        var seen: Set<String> = []
        _ = furniture.cleaned(pages[0].components(separatedBy: "\n"), seen: &seen)
        XCTAssertTrue(furniture.cleaned(pages[1].components(separatedBy: "\n"), seen: &seen)
            .contains("Значение не может изменяться"))
    }

    // MARK: - Продолжение таблицы

    func testAContinuedTableGetsItsHeader() {
        let edges = [40.0, 200, 380, 480]
        var blocks: [Int: [TableGeometry.PageBlock]] = [
            0: [.text(["Расчёт"]), .table(rows: [["Позиция", "Кол-во", "Цена"], ["Сервер", "1", "100"]], edges: edges)],
            1: [.table(rows: [["Коммутатор", "2", "50"]], edges: edges.map { $0 + 1 })],
        ]
        PDFExtractor.continueTables(&blocks, pageCount: 2)
        XCTAssertEqual(blocks[1], [.table(rows: [["Позиция", "Кол-во", "Цена"], ["Коммутатор", "2", "50"]],
                                          edges: edges.map { $0 + 1 })])
    }

    /// Строка, разорванная страницей: хвост значения — к своей ячейке
    /// на предыдущей странице, а не отдельной строкой без названия.
    func testACellCutByThePageJoinsItsRow() {
        let edges = [40.0, 260, 560]
        let header = ["Параметр", "Тип 6"]
        var blocks: [Int: [TableGeometry.PageBlock]] = [
            0: [.table(rows: [header, ["Кол-во адаптеров шт.", "2"],
                              ["Возможности портов", "- Ускорение обработки (XFER, ABC/DEF/GH stateless assist, QSO, PQS,"]],
                       edges: edges)],
            1: [.table(rows: [header, ["", "Parity Mode, Adaptive event batching);"],
                              ["Системное управление", "Наличие"]], edges: edges)],
        ]
        PDFExtractor.continueTables(&blocks, pageCount: 2)
        guard case .table(let first, _) = blocks[0]?.first, case .table(let second, _) = blocks[1]?.first else {
            return XCTFail("\(blocks)")
        }
        XCTAssertEqual(first.last, ["Возможности портов",
                                    "- Ускорение обработки (XFER, ABC/DEF/GH stateless assist, QSO, PQS, Parity Mode, Adaptive event batching);"])
        XCTAssertEqual(second, [header, ["Системное управление", "Наличие"]])
    }

    /// Следующая запись под названием, объединённым вниз через страницу,
    /// своей остаётся: значение предыдущей не оборвано.
    func testTheNextValueUnderAMergedNameStaysItsOwnRow() {
        let edges = [40.0, 260, 400, 560]
        let header = ["Наименование характеристики", "Значение", "Единица"]
        var blocks: [Int: [TableGeometry.PageBlock]] = [
            0: [.table(rows: [header, ["Количество ядер процессора", "≥ 2", "Штука"]], edges: edges)],
            1: [.table(rows: [header, ["", "≥ 4", "Штука"], ["", "≥ 6", "Штука"]], edges: edges)],
        ]
        PDFExtractor.continueTables(&blocks, pageCount: 2)
        guard case .table(let second, _) = blocks[1]?.first else { return XCTFail("\(blocks)") }
        XCTAssertEqual(second.count, 3, "обе записи на месте")
    }

    /// Перенос слова по дефису — без пробела, тире перечисления — с ним.
    func testAHyphenJoinsAWordButADashKeepsItsSpace() {
        XCTAssertEqual(PDFExtractor.joiningCells(of: ["", "поддержка ИТ-"], with: ["", "инфраструктуры"]), ["", "поддержка ИТ-инфраструктуры"])
        XCTAssertEqual(PDFExtractor.joiningCells(of: ["", "stateless assist -"], with: ["", "XFER over Shared Fabric"]),
                       ["", "stateless assist - XFER over Shared Fabric"])
    }

    /// Прочерк — это «нет», а не обрыв.
    func testADashIsNotACutOff() {
        XCTAssertFalse(PDFExtractor.isCutOff("-"))
        XCTAssertFalse(PDFExtractor.isCutOff("—"))
        XCTAssertTrue(PDFExtractor.isCutOff("checksum assist, PQS,"))
        XCTAssertTrue(PDFExtractor.isCutOff("Поддержка протоколов (RoCEv2"))
        XCTAssertFalse(PDFExtractor.isCutOff("наличие"))
    }

    // MARK: - Скан

    /// Страница с поворотом рисуется целиком, а не обрезанной.
    @MainActor
    func testARotatedPageIsRenderedWhole() throws {
        let url = try draw(lines: [], texts: [Text(x: 40, y: 800, text: "Верх страницы")], name: "поворот.pdf")
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        page.rotation = 90
        let bounds = VisionOCRExtractor.displayBounds(page)
        XCTAssertEqual(bounds.width, 842)
        XCTAssertEqual(bounds.height, 595)
        let image = try XCTUnwrap(VisionOCRExtractor.render(page))
        XCTAssertEqual(image.width, 1684)
        XCTAssertEqual(image.height, 1190)
    }

    /// Картинка поворачивается на четверть оборота в нужную сторону.
    func testAnImageTurnsAQuarter() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 10, width: 10, height: 10))   // левый верхний угол
        let image = try XCTUnwrap(context.makeImage())
        let turned = try XCTUnwrap(VisionOCRExtractor.rotated(image, clockwise: true))
        XCTAssertEqual(turned.width, 20)
        XCTAssertEqual(turned.height, 40)
        // По часовой левый верхний угол уходит в правый верхний.
        let raster = try XCTUnwrap(VisionOCRExtractor.Raster(turned))
        XCTAssertGreaterThan(raster.ink(in: CGRect(x: 12, y: 32, width: 6, height: 6)), 20)
        XCTAssertEqual(raster.ink(in: CGRect(x: 2, y: 32, width: 6, height: 6)), 0)
    }
}
