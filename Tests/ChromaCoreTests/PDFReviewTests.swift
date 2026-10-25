import XCTest
import PDFKit
import AppKit
@testable import ChromaCore

/// Ультраревью среза «PDF и таблицы в документах».
final class PDFReviewTests: XCTestCase {
    // MARK: - Ссылки

    /// Рамки знаков нумеруются без переводов строки, которые PDFKit
    /// вставляет в текст сам: номер рамки — не смещение в тексте.
    func testBoundsNumberingSkipsTheInsertedNewlines() {
        // Рамки: а0 б1 в2 г3 д4 е5; в тексте «е» стоит шестой — после «\n».
        XCTAssertEqual(PDFExtractor.textOffsets(ofBounds: [5, 1], in: "абв\nгдеж"), [5: 6, 1: 1])
    }

    /// Маркер Wingdings выше ссылки — не буква и в исходном тексте: счёт
    /// знаков не съезжает на число маркеров, даже когда текст вокруг ссылки
    /// повторяется и сверка по знакам находит его не на том месте.
    func testLinkOffsetsReadSymbolCodesByTheirFont() {
        let original = "\u{F076}\u{F076}\u{F076}" + String(repeating: "аб", count: 20)
        let reflowed = "❖❖❖" + String(repeating: "аб", count: 20)
        let fonts = [0: "Wingdings", 1: "Wingdings", 2: "Wingdings"]
        XCTAssertEqual(PDFExtractor.significantOffsets(original: original, reflowed: reflowed, fonts: fonts)(3), 3)
    }

    /// Колонтитул убран из текста страницы — смещения ниже него не съезжают
    /// на его длину.
    func testAnOffsetSurvivesARemovedHeader() {
        let original = "ООО Ромашкаинвестстрой Договор 15\nпервая строка текста\nссылка стоит здесь"
        let reflowed = "первая строка текста ссылка стоит здесь"
        let map = PDFExtractor.significantOffsets(original: original, reflowed: reflowed)
        let inOriginal = original.distance(from: original.startIndex, to: original.range(of: "ссылка")!.lowerBound)
        let inReflowed = reflowed.distance(from: reflowed.startIndex, to: reflowed.range(of: "ссылка")!.lowerBound)
        XCTAssertEqual(map(inOriginal), inReflowed)
    }

    /// Живой путь: у каждой страницы колонтитул, со второй он убран,
    /// ссылка — в середине страницы. Адрес встаёт ровно на свою подпись.
    @MainActor
    func testLinksLandOnTheirCaptionsOnEveryPage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("links.pdf")

        let anchors = ["ЯКОРЬАЛЬФА стоит слева", "ЯКОРЬБЕТА лежит посередине", "ЯКОРЬГАММА висит справа"]
        let names = ["Альфа", "Бета", "Гамма"]
        let ordinals = ["первый", "второй", "третий", "четвёртый", "пятый", "шестой"]
        let colours = ["красный", "синий", "зелёный", "жёлтый", "белый"]
        let font = NSFont.systemFont(ofSize: 12)
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &box, nil))
        for page in 0..<3 {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            ("ООО Ромашкаинвестстрой Договор номер 15" as NSString)
                .draw(at: CGPoint(x: 60, y: 790), withAttributes: [.font: font])
            for line in 0..<30 {
                let text = line == 15
                    ? "Целевая строка \(anchors[page])."
                    : "\(names[page]) \(ordinals[line % 6]) пункт \(colours[line % 5]) \(line * 7 + page * 131) рублей."
                (text as NSString).draw(at: CGPoint(x: 60, y: 740 - CGFloat(line) * 20), withAttributes: [.font: font])
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()

        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        let prefix = ("Целевая строка " as NSString).size(withAttributes: [.font: font]).width
        for index in 0..<3 {
            let page = try XCTUnwrap(document.page(at: index))
            let annotation = PDFAnnotation(
                bounds: CGRect(x: 60 + prefix, y: 740 - 15 * 20, width: 60, height: 14), forType: .link, withProperties: nil
            )
            annotation.action = PDFActionURL(url: try XCTUnwrap(URL(string: "https://example.org/\(index)")))
            page.addAnnotation(annotation)
        }
        XCTAssertTrue(document.write(to: url))

        let extracted = try await ExtractorRegistry.standard().extract(from: url, options: ExtractionOptions())
        let text = extracted.plainText
        XCTAssertEqual(extracted.links.count, 3)
        for link in extracted.links {
            let index = try XCTUnwrap(Int(link.url.split(separator: "/").last ?? ""))
            let start = text.index(text.startIndex, offsetBy: link.start)
            XCTAssertTrue(
                text[start...].hasPrefix(anchors[index].prefix(9)),
                "ссылка \(link.url) встала на «\(text[start...].prefix(30))»"
            )
        }
    }

    // MARK: - Оглавление

    /// Строки бланка, кончающиеся подчёркиванием, — не оглавление.
    func testFormFillLinesAreNotTableOfContents() {
        let form = [
            "Наименование организации: ______________",
            "ИНН: 7700000002__________",
            "Директор _____________",
        ]
        let result = PDFContents.removing(form, continuing: false)
        XCTAssertEqual(result.removed, 0)
        XCTAssertEqual(result.lines, form)
    }

    /// Подчёркивание с номером страницы — по-прежнему запись оглавления.
    func testUnderscoreLeadersWithPageNumbersAreStillContents() {
        let contents = ["1. Общие положения ________ 3", "2. Предмет договора ________ 5", "3. Цена ________ 8"]
        XCTAssertEqual(PDFContents.removing(contents, continuing: false).removed, 3)
    }

    // MARK: - Знаки символьных шрифтов

    /// Код частной области читается по шрифту знака: в Wingdings `F076` —
    /// маркер, а не греческая буква Symbol.
    func testWingdingsBulletsAreReadByTheirFont() {
        XCTAssertEqual(TextNormalization.normalized("\u{F076} Поставка", fonts: [0: "Wingdings-Regular"]), "❖ Поставка")
        XCTAssertEqual(TextNormalization.normalized("\u{F0D8} Монтаж", fonts: [0: "Wingdings-Regular"]), "➢ Монтаж")
        // Шрифт неизвестен — как раньше, по Symbol.
        XCTAssertEqual(TextNormalization.normalized("\u{F076} Поставка", fonts: [:]), "ϖ Поставка")
        // Смещение — в UTF-16: знак после эмодзи находит свой шрифт.
        XCTAssertEqual(TextNormalization.normalized("😀\u{F06C}", fonts: [2: "Wingdings"]), "😀●")
    }

    // MARK: - Распознавание

    /// Срок страницы истёк — Vision больше не зовётся.
    func testAnExpiredPageDeadlineStopsBeforeVision() async throws {
        let image = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )?.makeImage())
        let expired = VisionOCRExtractor.PageDeadline(seconds: 5, now: Date().addingTimeInterval(-60))
        do {
            _ = try await VisionOCRExtractor.observe(image, languages: [], deadline: expired)
            XCTFail("истёкший срок должен остановить распознавание")
        } catch {
            XCTAssertEqual(error as? ExtractionError, .timedOut(seconds: 5))
        }
    }

    /// Плитки: таблица остаётся таблицей, повтор убирается только на стыке
    /// соседних плиток, а та же строка в дальней плитке остаётся.
    func testTilesKeepTablesAndDropRepeatsOnlyAtSeams() {
        typealias Page = VisionOCRExtractor.PageText
        let left = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let right = CGRect(x: 952, y: 0, width: 1000, height: 1000)
        let far = CGRect(x: 0, y: 3000, width: 1000, height: 1000)
        let table = TableGeometry.PageBlock.table(rows: [["Поз.", "Наименование"], ["1", "Щит"]], edges: nil)
        let merged = VisionOCRExtractor.mergedTiles([
            (left, Page(text: "Шапка схемы\nУзел связи", confidence: 0.9, blocks: nil)),
            (right, Page(text: "Узел связи\nСервер", confidence: 0.9, blocks: nil)),
            (far, Page(text: "", confidence: 0.8, blocks: [.text(["Узел связи"]), table])),
        ])
        XCTAssertTrue(merged.hasTable, "таблица плитки должна остаться таблицей")
        let lines = merged.blocks?.flatMap { block -> [String] in
            if case .text(let lines) = block { return lines } else { return [] }
        } ?? []
        XCTAssertEqual(lines, ["Шапка схемы", "Узел связи", "Сервер", "Узел связи"])
    }

    /// Срок страницы кончился раньше плиток — страница говорит, что
    /// прочитана не вся, а не выглядит прочитанной целиком.
    func testATiledPageCutByTheDeadlineSaysSo() async throws {
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 3_000, height: 2_000), for: .mediaBox)
        XCTAssertTrue(VisionOCRExtractor.needsTiling(page))
        let expired = VisionOCRExtractor.PageDeadline(seconds: 5, now: Date().addingTimeInterval(-60))
        let result = try await VisionOCRExtractor.recogniseByTiles(page, languages: [], deadline: expired)
        XCTAssertEqual(result.unreadTiles, VisionOCRExtractor.tiles(of: VisionOCRExtractor.displayBounds(page)).count)
        XCTAssertGreaterThan(result.unreadTiles, 1)
        let warning = try XCTUnwrap(VisionOCRExtractor.partialPagesWarning([3, 7]).first)
        XCTAssertTrue(warning.text.contains("3, 7"), warning.text)
        XCTAssertTrue(VisionOCRExtractor.partialPagesWarning([]).isEmpty)
    }

    /// Строка таблицы на стыке двух плиток — одна: перекрытие повторяет
    /// строки таблиц так же, как строки текста.
    func testTileTablesDropRowsRepeatedAtTheSeam() {
        typealias Page = VisionOCRExtractor.PageText
        let top = CGRect(x: 0, y: 952, width: 1000, height: 1000)
        let bottom = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let upper = TableGeometry.PageBlock.table(rows: [["Поз.", "Наименование"], ["1", "Щит"], ["2", "Кабель ВВГ"]], edges: nil)
        let lower = TableGeometry.PageBlock.table(rows: [["2", "Кабель ВВГ"], ["3", "Розетка"]], edges: nil)
        let merged = VisionOCRExtractor.mergedTiles([
            (top, Page(text: "", confidence: 0.9, blocks: [upper])),
            (bottom, Page(text: "", confidence: 0.9, blocks: [lower])),
        ])
        let rows = merged.blocks?.flatMap { block -> [[String]] in
            if case .table(let rows, _) = block { return rows } else { return [] }
        } ?? []
        XCTAssertEqual(rows, [["Поз.", "Наименование"], ["1", "Щит"], ["2", "Кабель ВВГ"], ["3", "Розетка"]])
    }

    /// `perform` идёт в своей очереди, а не в общем пуле Swift: застрявший
    /// вызов, брошенный по сроку, держал бы поток пула навсегда.
    func testVisionRunsOffTheCooperativePool() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ChromaCore/Extraction/VisionOCRExtractor.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        let calls = lines.indices.filter { lines[$0].contains(".perform([") }
        XCTAssertFalse(calls.isEmpty)
        for call in calls {
            let before = lines[max(0, call - 3)..<call].joined(separator: "\n")
            XCTAssertTrue(before.contains("visionQueue.async"), "строка \(call + 1): `perform` вне очереди Vision")
        }
    }
}
