import XCTest
@testable import ChromaCore

/// презентации PowerPoint.
final class PPTXExtractorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pptx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let namespaces = """
    xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
    xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
    """
    private let relationNamespace = "http://schemas.openxmlformats.org/package/2006/relationships"
    private let typeBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"

    private func shape(_ text: [String], placeholder: String? = nil, x: Int? = nil, y: Int? = nil) -> String {
        let ph = placeholder.map { "<p:nvPr><p:ph type=\"\($0)\"/></p:nvPr>" } ?? "<p:nvPr/>"
        let position = (x != nil && y != nil) ? "<a:xfrm><a:off x=\"\(x!)\" y=\"\(y!)\"/><a:ext cx=\"10\" cy=\"10\"/></a:xfrm>" : ""
        let paragraphs = text.map { "<a:p><a:r><a:t>\($0)</a:t></a:r></a:p>" }.joined()
        return "<p:sp><p:nvSpPr><p:cNvPr id=\"1\" name=\"s\"/><p:cNvSpPr/>\(ph)</p:nvSpPr><p:spPr>\(position)</p:spPr><p:txBody><a:bodyPr/>\(paragraphs)</p:txBody></p:sp>"
    }

    private func slide(_ shapes: String) -> String {
        "<p:sld \(namespaces)><p:cSld><p:spTree><p:nvGrpSpPr/><p:grpSpPr/>\(shapes)</p:spTree></p:cSld></p:sld>"
    }

    private func relationships(_ items: [(id: String, type: String, target: String)]) -> String {
        "<Relationships xmlns=\"\(relationNamespace)\">"
            + items.map { "<Relationship Id=\"\($0.id)\" Type=\"\(typeBase)\($0.type)\" Target=\"\($0.target)\"/>" }.joined()
            + "</Relationships>"
    }

    /// Презентация, в которой слайды переставлены: `slide2.xml` показывается
    /// первым.
    private func deck(_ slides: [String: String], order: [String], extra: [(String, String)] = []) throws -> URL {
        let list = order.enumerated().map { "<p:sldId id=\"\(256 + $0.offset)\" r:id=\"rId\($0.offset + 1)\"/>" }.joined()
        var parts: [(String, String)] = [
            ("ppt/presentation.xml", "<p:presentation \(namespaces)><p:sldIdLst>\(list)</p:sldIdLst></p:presentation>"),
            ("ppt/_rels/presentation.xml.rels", relationships(order.enumerated().map {
                (id: "rId\($0.offset + 1)", type: "slide", target: "slides/\($0.element)")
            })),
            ("docProps/core.xml", "<cp:coreProperties xmlns:cp=\"c\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>Отчёт</dc:title><dc:creator>Иванов</dc:creator></cp:coreProperties>"),
        ]
        parts += slides.map { ("ppt/slides/\($0.key)", $0.value) }
        parts += extra
        let url = root.appendingPathComponent("deck-\(UUID().uuidString).pptx")
        try ZIPFixtureBuilder(entries: parts.map {
            ZIPFixtureBuilder.Entry(path: $0.0, contents: Data($0.1.utf8), deflated: true)
        }).build().write(to: url)
        return url
    }

    func testSlidesComeInShowOrderWithTitlesAndWithoutFurniture() async throws {
        let first = slide(
            shape(["Итоги года"], placeholder: "title")
                + shape(["Выручка выросла на 12 %"], placeholder: "body")
                + shape(["7"], placeholder: "sldNum")
                + shape(["Конфиденциально"], placeholder: "ftr")
        )
        let second = slide(shape(["План работ"], placeholder: "ctrTitle") + shape(["Запуск в марте"]))
        let url = try deck(["slide1.xml": first, "slide2.xml": second], order: ["slide2.xml", "slide1.xml"])

        let document = try await PPTXExtractor().extract(
            from: url, options: ExtractionOptions(includeDocumentMetadata: true)
        )
        XCTAssertEqual(document.plainText, "План работ\nЗапуск в марте\n\nИтоги года\nВыручка выросла на 12 %")
        XCTAssertEqual(document.structure.map(\.title), ["План работ", "Итоги года"])
        XCTAssertEqual(document.parts.map(\.kind), [.slide, .slide])
        XCTAssertEqual(document.pageNumber(forCharacter: document.plainText.count - 1), 2)
        XCTAssertEqual(document.documentMetadata["document_title"], "Отчёт")
        XCTAssertEqual(document.documentMetadata["document_author"], "Иванов")

        // Слайд — единица нарезки, как у Keynote.
        let chunks = try XCTUnwrap(SourceSyncService.slideChunks(of: document))
        XCTAssertEqual(chunks.map(\.text), ["План работ\nЗапуск в марте", "Итоги года\nВыручка выросла на 12 %"])
    }

    /// Фигуры в файле стоят в порядке наложения; читаются — сверху вниз,
    /// слева направо.
    func testShapesAreReadTopToBottomLeftToRight() async throws {
        let shapes = shape(["низ"], x: 0, y: 4_000_000)
            + shape(["справа"], x: 5_000_000, y: 1_000_000)
            + shape(["слева"], x: 0, y: 1_050_000)
            + shape(["Заголовок слайда"], placeholder: "title")
        let url = try deck(["slide1.xml": slide(shapes)], order: ["slide1.xml"])
        let document = try await PPTXExtractor().extract(from: url, options: ExtractionOptions())
        XCTAssertEqual(document.plainText, "Заголовок слайда\nслева\nсправа\nниз")
    }

    /// Прогон из одного пробела между словами — обычное дело.
    func testSpaceOnlyRunsAreKept() async throws {
        let title = "<p:sp><p:nvSpPr><p:cNvPr id=\"1\" name=\"t\"/><p:cNvSpPr/><p:nvPr><p:ph type=\"title\"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:p><a:r><a:t>Цифровое</a:t></a:r><a:r><a:t> </a:t></a:r><a:r><a:t>правосудие</a:t></a:r></a:p></p:txBody></p:sp>"
        let url = try deck(["slide1.xml": slide(title)], order: ["slide1.xml"])
        let document = try await PPTXExtractor().extract(from: url, options: ExtractionOptions())
        XCTAssertEqual(document.plainText, "Цифровое правосудие")
        XCTAssertEqual(document.structure.first?.title, "Цифровое правосудие")
    }

    func testTablesNotesAndSmartArtAreRead() async throws {
        let table = """
        <p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="2" name="t"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>\
        <p:xfrm><a:off x="0" y="2000000"/><a:ext cx="1" cy="1"/></p:xfrm><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table">\
        <a:tbl><a:tr h="1"><a:tc><a:txBody><a:bodyPr/><a:p><a:r><a:t>Система</a:t></a:r></a:p></a:txBody></a:tc>\
        <a:tc><a:txBody><a:bodyPr/><a:p><a:r><a:t>Срок</a:t></a:r></a:p></a:txBody></a:tc></a:tr>\
        <a:tr h="1"><a:tc><a:txBody><a:bodyPr/><a:p><a:r><a:t>ЕГИССО</a:t></a:r></a:p></a:txBody></a:tc>\
        <a:tc><a:txBody><a:bodyPr/><a:p><a:r><a:t>2026</a:t></a:r></a:p></a:txBody></a:tc></a:tr></a:tbl>\
        </a:graphicData></a:graphic></p:graphicFrame>
        """
        let smartArt = """
        <p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="3" name="d"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>\
        <p:xfrm><a:off x="0" y="3000000"/><a:ext cx="1" cy="1"/></p:xfrm><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/diagram">\
        <dgm:relIds xmlns:dgm="http://schemas.openxmlformats.org/drawingml/2006/diagram" r:dm="rId5" r:lo="rId6" r:qs="rId7" r:cs="rId8"/>\
        </a:graphicData></a:graphic></p:graphicFrame>
        """
        let data = """
        <dgm:dataModel xmlns:dgm="http://schemas.openxmlformats.org/drawingml/2006/diagram" \(namespaces)><dgm:ptLst>\
        <dgm:pt modelId="0" type="doc"><dgm:t><a:bodyPr/><a:p><a:r><a:t>корень</a:t></a:r></a:p></dgm:t></dgm:pt>\
        <dgm:pt modelId="1"><dgm:t><a:bodyPr/><a:p><a:r><a:t>Сбор данных</a:t></a:r></a:p></dgm:t></dgm:pt>\
        <dgm:pt modelId="2" type="parTrans"><dgm:t><a:bodyPr/><a:p><a:r><a:t>переход</a:t></a:r></a:p></dgm:t></dgm:pt>\
        <dgm:pt modelId="3"><dgm:t><a:bodyPr/><a:p><a:r><a:t>Анализ</a:t></a:r></a:p></dgm:t></dgm:pt>\
        </dgm:ptLst></dgm:dataModel>
        """
        let notes = "<p:notes \(namespaces)><p:cSld><p:spTree>"
            + shape(["образ слайда"], placeholder: "sldImg")
            + shape(["Сказать про сроки"], placeholder: "body")
            + shape(["3"], placeholder: "sldNum")
            + "</p:spTree></p:cSld></p:notes>"
        let url = try deck(
            ["slide1.xml": slide(shape(["Сроки"], placeholder: "title") + table + smartArt)],
            order: ["slide1.xml"],
            extra: [
                ("ppt/slides/_rels/slide1.xml.rels", relationships([
                    (id: "rId2", type: "notesSlide", target: "../notesSlides/notesSlide1.xml"),
                    (id: "rId5", type: "diagramData", target: "../diagrams/data1.xml"),
                ])),
                ("ppt/notesSlides/notesSlide1.xml", notes),
                ("ppt/diagrams/data1.xml", data),
            ]
        )
        let document = try await PPTXExtractor().extract(from: url, options: ExtractionOptions())
        XCTAssertEqual(document.plainText, """
        Сроки
        | Система | Срок |
        | --- | --- |
        | ЕГИССО | 2026 |
        Сбор данных
        Анализ

        Заметки докладчика:
        Сказать про сроки
        """)
        XCTAssertEqual(document.hasTables, true)
    }

    /// Строка таблицы — не заголовок слайда, одиночная подпись — тоже.
    func testASlideWithoutTitlePlaceholderGetsOnlyAPlausibleTitle() async throws {
        let url = try deck(
            ["slide1.xml": slide(shape(["М9"], x: 0, y: 0) + shape(["Что-то ниже"], x: 0, y: 900_000)),
             "slide2.xml": slide(shape(["Этапы развития ЦОД"], x: 0, y: 0))],
            order: ["slide1.xml", "slide2.xml"]
        )
        let document = try await PPTXExtractor().extract(from: url, options: ExtractionOptions())
        XCTAssertEqual(document.structure.map(\.title), ["Этапы развития ЦОД"])
        XCTAssertEqual(document.structure.first?.pageNumber, 2)
    }

    /// Слайд без текста номер не сбивает: страница — номер слайда.
    func testAnEmptySlideDoesNotShiftPageNumbers() async throws {
        let url = try deck(
            ["slide1.xml": slide(shape(["Первый слайд"], placeholder: "title")),
             "slide2.xml": slide(""),
             "slide3.xml": slide(shape(["Третий слайд"], placeholder: "title"))],
            order: ["slide1.xml", "slide2.xml", "slide3.xml"]
        )
        let document = try await PPTXExtractor().extract(from: url, options: ExtractionOptions())
        let third = try XCTUnwrap(document.plainText.range(of: "Третий"))
        let offset = document.plainText.distance(from: document.plainText.startIndex, to: third.lowerBound)
        XCTAssertEqual(document.pageNumber(forCharacter: offset), 3)
        XCTAssertEqual(document.part(forCharacter: offset)?.index, 2)
        XCTAssertEqual(document.pageNumber(forCharacter: 0), 1)
    }

    func testTheRegistryReadsPPTX() throws {
        let url = try deck(["slide1.xml": slide(shape(["Текст"]))], order: ["slide1.xml"])
        XCTAssertEqual(ExtractorRegistry.standard().candidate(for: url)?.id, "pptx")
        XCTAssertTrue(TextExtractor.supportedExtensions.contains("pptx"))
    }
}
