import XCTest
@testable import ChromaCore

/// двоичный `.doc` перестал быть «нечем заглянуть».
final class DocPartsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-doc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ fixture: DocFixture, name: String = "проба.doc") throws -> URL {
        let url = root.appendingPathComponent(name)
        try fixture.build().write(to: url)
        return url
    }

    // MARK: - Контейнер OLE2

    /// Крупный поток лежит в секторах файла, мелкий — в мини-потоке внутри
    /// корневой записи. Это два разных пути чтения, и оба нужны: у настоящего
    /// `.doc` текст всегда крупный, а таблица диапазонов у короткого письма —
    /// мелкая.
    func testBothLargeAndSmallStreamsAreRead() throws {
        let large = Data((0..<9000).map { UInt8($0 % 251) })
        let small = Data((0..<300).map { UInt8($0 % 97) })
        let url = root.appendingPathComponent("оба.bin")
        try DocFixture.container(streams: [
            (name: "WordDocument", data: large), (name: "1Table", data: small),
        ]).write(to: url)

        let reader = try CFBContainerReader(url: url)
        XCTAssertEqual(try reader.read("WordDocument"), large)
        XCTAssertEqual(try reader.read("1Table"), small)
    }

    /// Не составной документ — отказ с внятной причиной, а не разбор мусора.
    func testAPlainFileIsNotACompoundDocument() throws {
        let url = root.appendingPathComponent("текст.doc")
        try Data("это просто текст".utf8).write(to: url)
        XCTAssertThrowsError(try CFBContainerReader(url: url)) { error in
            XCTAssertEqual(error as? CFBError, .notACompoundFile)
        }
        XCTAssertNil(DocPartsReader(url: url))
    }

    // MARK: - Опись по заголовку (ступень 1)

    /// Главное, ради чего всё затевалось: сказать про файл точно, что в нём
    /// есть, — а не «мы не смотрели».
    func testTheHeaderSaysWhatTheFileHolds() throws {
        let url = try write(DocFixture(
            paragraphs: ["Приказываю утвердить положение.", "Контроль оставляю за собой."],
            header: "Для служебного пользования",
            footer: "лист 1",
            footnotes: ["Пункт 4 приказа от 12 марта."],
            comments: [(author: "Петров", text: "Уточнить срок поставки.")],
            textboxes: ["Врезка сбоку"]
        ))
        let reader = try XCTUnwrap(DocPartsReader(url: url))
        let inventory = reader.inventory()

        XCTAssertEqual(inventory.comments, 1)
        XCTAssertEqual(inventory.commentCharacters, "Уточнить срок поставки.".count + 1)
        XCTAssertEqual(inventory.footnotes, 1)
        XCTAssertEqual(inventory.footnoteCharacters, "Пункт 4 приказа от 12 марта.".count + 1)
        XCTAssertEqual(inventory.textboxCharacters, "Врезка сбоку".count + 1)
        // Колонтитулов два, и служебных историй-разделителей среди них нет.
        XCTAssertEqual(
            inventory.headerCharacters,
            "Для служебного пользования".count + 1 + "лист 1".count + 1
        )
    }

    /// Шесть служебных историй в начале того же подпотока — не колонтитул:
    /// это разделители сносок, и человек их в документе не увидит.
    func testFootnoteSeparatorsAreNotCountedAsHeaders() throws {
        let url = try write(DocFixture(paragraphs: ["Один абзац."]))
        let reader = try XCTUnwrap(DocPartsReader(url: url))
        XCTAssertEqual(reader.inventory().headerCharacters, 0)
        XCTAssertTrue(reader.inventory().isEmpty)
    }

    // MARK: - Оговорки

    /// Оговорка называет число, а не отделывается общей фразой.
    func testWarningsNameTheNumbers() throws {
        var inventory = DocPartsReader.Inventory()
        inventory.comments = 4
        inventory.commentCharacters = 660
        inventory.headerCharacters = 51
        let texts = OfficeExtractor.inventory(inventory).map(\.text)

        XCTAssertTrue(texts.contains { $0.contains("4 комментария") && $0.contains("660 знаков") }, "\(texts)")
        XCTAssertTrue(texts.contains { $0.contains("колонтитул") && $0.contains("51 знак") }, "\(texts)")
        // Про правки заголовок не говорит ничего — и молчать об этом нельзя.
        XCTAssertTrue(texts.contains { $0.contains("правки") }, "\(texts)")
    }

    /// Пустому документу приписывать нечего: остаётся одна оговорка про правки.
    func testAnEmptyInventoryWarnsOnlyAboutRevisions() throws {
        let warnings = OfficeExtractor.inventory(DocPartsReader.Inventory())
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].text.contains("правки"), warnings[0].text)
    }
}

///, ступени 2 и 3 — текст, колонтитулы, замечания и структура.
final class DocTextTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-doc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func parts(_ fixture: DocFixture, name: String = "проба.doc") throws -> WordParts.Document {
        let url = root.appendingPathComponent(name)
        try fixture.build().write(to: url)
        let reader = try XCTUnwrap(DocPartsReader(url: url))
        return try XCTUnwrap(reader.read())
    }

    private func extracted(_ fixture: DocFixture, name: String = "проба.doc") async throws -> ExtractedDocument {
        let url = root.appendingPathComponent(name)
        try fixture.build().write(to: url)
        return try await ExtractorRegistry(extractors: [OfficeExtractor()])
            .extract(from: url, options: ExtractionOptions())
    }

    // MARK: - Текст

    /// Текст собирается по таблице кусков — в том числе когда кусков много
    /// и кодировка у них разная. Так лежит большинство настоящих файлов:
    /// латинский кусок однобайтовый, русский двухбайтовый.
    func testTextIsAssembledFromPiecesOfBothEncodings() throws {
        let lines = ["Order No. 12 of 2026", "Приказ № 12 от 2026 года", "Signed: A. Petrov"]
        let single = try parts(DocFixture(paragraphs: lines), name: "один.doc")
        let many = try parts(
            DocFixture(paragraphs: lines, compressed: true, pieceLength: 7), name: "куски.doc"
        )
        XCTAssertEqual(single.paragraphs.map(\.text), lines)
        XCTAssertEqual(many.paragraphs.map(\.text), lines)
    }

    /// Колонтитулы приходят текстом, и служебные истории в них не попадают.
    func testHeadersAndFootersComeBackAsText() throws {
        let document = try parts(DocFixture(
            paragraphs: ["Текст приказа."],
            header: "Для служебного пользования", footer: "лист 1 из 3"
        ))
        XCTAssertEqual(document.headers, ["Для служебного пользования"])
        XCTAssertEqual(document.footers, ["лист 1 из 3"])
    }

    /// Сноски — по своей таблице, и пустая история в конце, которую пишет
    /// настоящий Word, сноской не считается.
    func testFootnotesComeBackNumbered() throws {
        let document = try parts(DocFixture(
            paragraphs: ["Основание — пункт 4."],
            footnotes: ["Пункт 4 приказа от 12 марта.", "Утратил силу."],
            trailingEmptyFootnoteStory: true
        ))
        XCTAssertEqual(document.footnotes, ["1": "Пункт 4 приказа от 12 марта.", "2": "Утратил силу."])
    }

    /// Замечание рецензента — с автором: по нему их и разбирают.
    func testCommentsComeBackWithTheirAuthor() throws {
        let document = try parts(DocFixture(
            paragraphs: ["Срок поставки определяется сторонами."],
            comments: [(author: "Петров", text: "Уточнить: тридцать или сорок дней?")]
        ))
        XCTAssertEqual(document.comments.count, 1)
        XCTAssertEqual(document.comments.first?.author, "Петров")
        XCTAssertEqual(document.comments.first?.text, "Уточнить: тридцать или сорок дней?")
    }

    /// Надпись — такой же текст документа, и системный импортёр не отдаёт
    /// его вовсе.
    func testTextBoxesReachTheText() async throws {
        let document = try await extracted(DocFixture(
            paragraphs: ["Схема размещения оборудования."], textboxes: ["Серверная № 2"]
        ))
        XCTAssertTrue(document.plainText.contains("Серверная № 2"), document.plainText)
    }

    // MARK: - Правки и скрытый текст

    /// Правки считаются принятыми: удалённый текст в базу не идёт, иначе
    /// документ попадёт в неё сразу в двух редакциях.
    func testDeletedTextIsNotIndexed() async throws {
        let document = try await extracted(DocFixture(
            paragraphs: ["Срок — тридцать дней.", "Срок — сорок дней."],
            deletedParagraphs: [0]
        ))
        XCTAssertFalse(document.plainText.contains("тридцать"), document.plainText)
        XCTAssertTrue(document.plainText.contains("сорок"), document.plainText)
        XCTAssertTrue(
            document.warnings.contains { $0.text.contains("правки") },
            "\(document.warnings)"
        )
    }

    /// Скрытого текста для базы не существует по той же причине, по какой
    /// его нет на бумаге, — и число пропущенных абзацев попадает в оговорки.
    func testHiddenTextIsNotIndexed() async throws {
        let document = try await extracted(DocFixture(
            paragraphs: ["Видимый пункт.", "Черновая заметка автора."],
            hiddenParagraphs: [1]
        ))
        XCTAssertFalse(document.plainText.contains("Черновая"), document.plainText)
        XCTAssertTrue(
            document.warnings.contains { $0.text.contains("скрыт") },
            "\(document.warnings)"
        )
    }

    // MARK: - Структура

    /// Стиль «Заголовок 2» даёт заголовок второго уровня — из разметки
    /// автора, а не из догадки по кеглю.
    func testHeadingsComeFromStyles() async throws {
        let fixture = DocFixture(
            paragraphs: ["Общие положения", "Настоящий приказ определяет порядок.", "Порядок учёта"],
            styles: [
                DocFixture.DocStyle(name: "heading 1", sti: 1, outlineLevel: 0),
                DocFixture.DocStyle(name: "heading 2", sti: 2, outlineLevel: 1),
            ],
            paragraphStyles: [0: 1, 2: 2]
        )
        let document = try await extracted(fixture)
        XCTAssertEqual(document.structureSource, .headings)
        XCTAssertEqual(document.structure.map(\.level), [1, 2])
        XCTAssertEqual(document.structure.map(\.title), ["Общие положения", "Порядок учёта"])
    }

    /// Начертание Word пишет значением «наоборот, чем в стиле», а не
    /// «включено». Разбор на этом уже спотыкался: документ выглядел набранным
    /// без единого выделения, и догадка по начертанию не находила ничего.
    func testBoldWrittenAsToggleIsStillBold() throws {
        let document = try parts(DocFixture(
            paragraphs: ["Общие положения", "Настоящий приказ определяет порядок."],
            boldParagraphs: [0]
        ))
        XCTAssertEqual(document.paragraphs.first?.isBold, true)
        XCTAssertEqual(document.paragraphs.last?.isBold, false)
    }
}
