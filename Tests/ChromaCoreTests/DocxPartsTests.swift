import XCTest
@testable import ChromaCore

/// `.docx` читается по частям контейнера.
///
/// Фикстуры собираются здесь же, а не берутся готовым файлом: разбирается
/// формат, а не чей-то документ, и каждая ловушка должна быть выразима.
final class DocxPartsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-docx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Фикстура

    private func write(
        body: String,
        styles: String = DocxFixture.defaultStyles,
        numbering: String = DocxFixture.defaultNumbering,
        header: String? = nil,
        footer: String? = nil,
        footnotes: [String: String] = [:],
        comments: [(id: String, author: String, text: String)] = [],
        name: String = "проба.docx"
    ) throws -> URL {
        let url = root.appendingPathComponent(name)
        try DocxFixture(
            body: body, styles: styles, numbering: numbering,
            header: header, footer: footer, footnotes: footnotes, comments: comments
        ).build().write(to: url)
        return url
    }

    // MARK: - Комментарии

    /// Замечание рецензента — такой же написанный человеком текст, как сноска.
    func testCommentsAreReadWithTheirAuthor() async throws {
        let url = try write(
            body: DocxFixture.paragraph("Срок поставки определяется сторонами.")
                + "<w:p><w:r><w:commentReference w:id=\"1\"/></w:r></w:p>",
            comments: [(id: "1", author: "Петров", text: "Уточнить срок: тридцать или сорок дней?")]
        )
        let extracted = try await extract(url)
        XCTAssertTrue(
            extracted.plainText.contains("Комментарий (Петров): Уточнить срок: тридцать или сорок дней?"),
            extracted.plainText
        )
        // И оговорки «не извлекаются» больше нет — она стала бы неправдой.
        XCTAssertFalse(extracted.warnings.contains(.commentsSkipped), "\(extracted.warnings)")
    }

    /// Осиротевшее замечание, на которое в документе нет ссылки, документу
    /// не приписывается.
    func testAnUnreferencedCommentIsLeftAlone() async throws {
        let url = try write(
            body: DocxFixture.paragraph("Текст без единого замечания.")
                + "<w:p><w:r><w:commentReference w:id=\"1\"/></w:r></w:p>",
            comments: [(id: "1", author: "А", text: "по делу"), (id: "9", author: "Б", text: "осиротевшее")]
        )
        let extracted = try await extract(url)
        XCTAssertTrue(extracted.plainText.contains("по делу"))
        XCTAssertFalse(extracted.plainText.contains("осиротевшее"), extracted.plainText)
    }

    /// Правки принимаются — и об этом говорится прямо, а не общим «ничего
    /// не извлекается».
    func testRevisionsAreNamedPrecisely() async throws {
        let url = try write(body:
            "<w:p><w:r><w:t xml:space=\"preserve\">Цена </w:t></w:r>"
            + "<w:del w:id=\"1\" w:author=\"А\"><w:r><w:delText>СТО</w:delText></w:r></w:del>"
            + "<w:ins w:id=\"2\" w:author=\"Б\"><w:r><w:t>ДВЕСТИ</w:t></w:r></w:ins></w:p>"
        )
        let extracted = try await extract(url)
        XCTAssertTrue(
            extracted.warnings.contains { $0.text.contains("индексируется финальная редакция") },
            "\(extracted.warnings.map(\.text))"
        )
        XCTAssertFalse(extracted.warnings.contains(.commentsSkipped))
    }

    private func extract(_ url: URL) async throws -> ExtractedDocument {
        try await OfficeExtractor().extract(from: url, options: ExtractionOptions())
    }

    // MARK: - Структура

    /// Главное: разметка автора главнее догадки по кеглю.
    ///
    /// На настоящем документе с двенадцатью абзацами `Heading*` прежний разбор
    /// давал десять узлов, угаданных по начертанию, — часть из них не заголовки.
    func testHeadingStylesBecomeTheStructure() async throws {
        let url = try write(body:
            DocxFixture.paragraph("Договор поставки", style: "Heading1")
            + DocxFixture.paragraph("Обычный абзац, достаточно длинный, чтобы не сойти за заголовок.")
            + DocxFixture.paragraph("Предмет договора", style: "Heading2")
            + DocxFixture.paragraph("Ещё один обычный абзац такой же длины и без выделения.")
        )
        let extracted = try await extract(url)

        XCTAssertEqual(extracted.structureSource, .headings)
        XCTAssertEqual(extracted.structure.map(\.title), ["Договор поставки", "Предмет договора"])
        XCTAssertEqual(extracted.structure.map(\.level), [1, 2])
        XCTAssertFalse(extracted.warnings.contains(.structureIsHeuristic), "это не догадка")
        // Смещения указывают на сам заголовок в собранном тексте.
        for node in extracted.structure {
            let start = extracted.plainText.index(extracted.plainText.startIndex, offsetBy: node.start)
            XCTAssertTrue(extracted.plainText[start...].hasPrefix(node.title), node.title)
        }
    }

    /// Уровень берётся из `w:outlineLvl`, когда он проставлен руками.
    func testAnExplicitOutlineLevelWins() async throws {
        let url = try write(body:
            DocxFixture.paragraph("Раздел", style: "Heading1", outlineLevel: 2)
            + DocxFixture.paragraph("Текст раздела, достаточно длинный для абзаца.")
        )
        let extracted = try await extract(url)
        XCTAssertEqual(extracted.structure.first?.level, 3)
    }

    /// Документ без стилей — не редкость: из четырёх проверенных настоящих
    /// файлов стилями размечен один. Для таких остаётся догадка, и она честно
    /// называется догадкой.
    func testWithoutStylesTheGuessRemains() async throws {
        let url = try write(body:
            DocxFixture.paragraph("РАЗДЕЛ ПЕРВЫЙ", bold: true, size: 12)
            + DocxFixture.paragraph("Обычный текст первого раздела, достаточно длинный.", size: 12)
            + DocxFixture.paragraph("РАЗДЕЛ ВТОРОЙ", bold: true, size: 12)
            + DocxFixture.paragraph("Обычный текст второго раздела, тоже достаточно длинный.", size: 12)
        )
        let extracted = try await extract(url)
        XCTAssertEqual(extracted.structureSource, .heuristic)
        XCTAssertEqual(extracted.structure.map(\.title), ["РАЗДЕЛ ПЕРВЫЙ", "РАЗДЕЛ ВТОРОЙ"])
        // Плоский документ — плоская структура: второй уровень без первого
        // сбил бы и путь заголовков, и иерархическую нарезку.
        XCTAssertEqual(Set(extracted.structure.map(\.level)), [1])
        XCTAssertTrue(extracted.warnings.contains(.structureIsHeuristic))
    }

    // MARK: - Номера пунктов

    /// «По пункту 3.2» — так на них ссылаются, и без номера этот пункт не найти.
    func testListNumbersReachTheText() async throws {
        let url = try write(body:
            DocxFixture.paragraph("Поставщик обязуется", numbering: 1)
            + DocxFixture.paragraph("Покупатель обязуется", numbering: 1)
            + DocxFixture.paragraph("в срок", numbering: 1, indent: 1)
            + DocxFixture.paragraph("и в полном объёме", numbering: 1, indent: 1)
            + DocxFixture.paragraph("Стороны договорились", numbering: 1)
        )
        let text = try await extract(url).plainText
        XCTAssertTrue(text.contains("1. Поставщик обязуется"), text)
        XCTAssertTrue(text.contains("2. Покупатель обязуется"), text)
        XCTAssertTrue(text.contains("2.1. в срок"), text)
        XCTAssertTrue(text.contains("2.2. и в полном объёме"), text)
        // Вложенный уровень начинается заново под следующим пунктом верхнего.
        XCTAssertTrue(text.contains("3. Стороны договорились"), text)
    }

    func testABulletListGetsADashRatherThanANumber() async throws {
        let url = try write(
            body: DocxFixture.paragraph("первое", numbering: 2) + DocxFixture.paragraph("второе", numbering: 2),
            numbering: DocxFixture.bulletNumbering
        )
        let text = try await extract(url).plainText
        XCTAssertTrue(text.contains("— первое"), text)
        XCTAssertTrue(text.contains("— второе"), text)
    }

    // MARK: - Что документ прячет

    /// `w:vanish` — текст, который Word не показывает и не печатает. В базе
    /// ему делать нечего, но и молчать о нём нельзя.
    func testHiddenTextIsSkippedAndCounted() async throws {
        let url = try write(body:
            DocxFixture.paragraph("Видимый абзац договора, достаточно длинный.")
            + DocxFixture.paragraph("СЛУЖЕБНАЯ ПОМЕТКА НЕ ДЛЯ ПЕЧАТИ", hidden: true)
        )
        let extracted = try await extract(url)
        XCTAssertFalse(extracted.plainText.contains("СЛУЖЕБНАЯ"), extracted.plainText)
        XCTAssertTrue(extracted.warnings.contains { $0.text.contains("скрытых абзацев: 1") }, "\(extracted.warnings)")
    }

    /// Абзац, где скрыта только часть, скрытым не считается — иначе пропал бы
    /// видимый текст рядом.
    func testAPartlyHiddenParagraphKeepsItsVisibleHalf() async throws {
        let url = try write(body:
            "<w:p><w:r><w:rPr><w:vanish/></w:rPr><w:t>СКРЫТОЕ</w:t></w:r>"
            + "<w:r><w:t xml:space=\"preserve\"> видимое продолжение абзаца</w:t></w:r></w:p>"
        )
        let text = try await extract(url).plainText
        XCTAssertTrue(text.contains("видимое продолжение"), text)
    }

    /// Удалённый правкой текст в документе не виден — и в базу не идёт.
    func testDeletedTextIsNotIndexedButRevisionsAreReported() async throws {
        let url = try write(body:
            "<w:p><w:r><w:t xml:space=\"preserve\">Цена составляет </w:t></w:r>"
            + "<w:del w:id=\"1\" w:author=\"А\"><w:r><w:delText>СТО</w:delText></w:r></w:del>"
            + "<w:ins w:id=\"2\" w:author=\"Б\"><w:r><w:t>ДВЕСТИ</w:t></w:r></w:ins>"
            + "<w:r><w:t xml:space=\"preserve\"> тысяч рублей.</w:t></w:r></w:p>"
        )
        let extracted = try await extract(url)
        XCTAssertFalse(extracted.plainText.contains("СТО"), extracted.plainText)
        XCTAssertTrue(extracted.plainText.contains("ДВЕСТИ"), extracted.plainText)
        // Оговорка называет, что именно произошло, а не «ничего
        // не извлекается»: сноски и комментарии-то извлекаются.
        XCTAssertTrue(extracted.warnings.contains { $0.text.contains("финальная редакция") })
    }

    /// Надпись пишется в двух ветках сразу; без пропуска запасной её текст
    /// попал бы в базу дважды.
    func testATextBoxIsReadOnce() async throws {
        let url = try write(body:
            "<w:p><w:r><mc:AlternateContent xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\">"
            + "<mc:Choice Requires=\"wps\"><w:p><w:r><w:t>ТЕКСТ НАДПИСИ</w:t></w:r></w:p></mc:Choice>"
            + "<mc:Fallback><w:p><w:r><w:t>ТЕКСТ НАДПИСИ</w:t></w:r></w:p></mc:Fallback>"
            + "</mc:AlternateContent></w:r></w:p>"
        )
        let text = try await extract(url).plainText
        XCTAssertEqual(text.components(separatedBy: "ТЕКСТ НАДПИСИ").count - 1, 1, text)
    }

    // MARK: - Колонтитулы и сноски

    /// Гриф живёт в колонтитуле — и терялся целиком.
    func testHeadersAndFootersAreRead() async throws {
        let url = try write(
            body: DocxFixture.paragraph("Основной текст документа, достаточно длинный."),
            header: "ДСП. Экземпляр № 1", footer: "Лист 1 из 3"
        )
        let text = try await extract(url).plainText
        XCTAssertTrue(text.contains("ДСП. Экземпляр № 1"), text)
        XCTAssertTrue(text.contains("Лист 1 из 3"), text)
        // Верхний — впереди: гриф обязан попасть в первый же чанк.
        XCTAssertTrue(text.hasPrefix("Колонтитул: ДСП"), text)
    }

    /// Сноска возвращается текстом, а не считается по размеру части: файл
    /// с одной настоящей сноской весит меньше прежнего порога в 512 байт,
    /// и о ней не говорилось вовсе.
    func testAFootnoteComesBackAsText() async throws {
        let url = try write(
            body: DocxFixture.paragraph("Текст со сноской")
                + "<w:p><w:r><w:footnoteReference w:id=\"2\"/></w:r></w:p>",
            footnotes: ["2": "Срок поставки — тридцать дней."]
        )
        let text = try await extract(url).plainText
        XCTAssertTrue(text.contains("Сноска 2: Срок поставки — тридцать дней."), text)
    }

    /// Сноска встаёт **при своём абзаце**, а не в конце документа.
    ///
    /// Раньше все сноски приписывались в хвост. Замер на 250 документах:
    /// между ссылкой и текстом сноски оказывалось в среднем 46% документа —
    /// то есть оговорка и то, что она оговаривает, не попадали в один чанк
    /// никогда.
    func testAFootnoteStandsWithItsOwnParagraph() async throws {
        let url = try write(
            body: DocxFixture.paragraph("Штраф устанавливается в размере, определённом Правилами.")
                + "<w:p><w:r><w:footnoteReference w:id=\"2\"/></w:r></w:p>"
                + DocxFixture.paragraph("Оплата производится ежеквартально по факту оказания услуг."),
            footnotes: ["2": "Правила определения размера штрафа."]
        )
        let text = try await extract(url).plainText

        // Блок абзаца несёт сноску внутри себя: блоки разделяются пустой
        // строкой, и сноска, ставшая своим блоком, уехала бы при первой же
        // нарезке.
        let block = try XCTUnwrap(
            text.components(separatedBy: "\n\n").first { $0.contains("Сноска 2") },
            text
        )
        XCTAssertTrue(block.contains("Правилами."), "сноска оторвана от своего абзаца: \(block)")
        XCTAssertFalse(block.contains("Оплата"), "сноска приписана следующему абзацу: \(block)")

        // И не в конце: после неё идёт ещё текст документа.
        let note = try XCTUnwrap(text.range(of: "Сноска 2"))
        XCTAssertTrue(
            text[note.upperBound...].contains("Оплата производится"),
            "сноска всё ещё в хвосте документа"
        )
    }

    /// Сноска из ячейки — после таблицы, а не внутри неё: строкой в ячейке
    /// она сломала бы разметку Markdown, по которой таблица и читается.
    func testAFootnoteFromATableCellDoesNotBreakTheTable() async throws {
        let url = try write(
            body: "<w:tbl><w:tr>"
                + DocxFixture.cell(DocxFixture.paragraph("Услуга"), nil)
                + DocxFixture.cell(
                    DocxFixture.paragraph("Срок")
                        + "<w:p><w:r><w:footnoteReference w:id=\"3\"/></w:r></w:p>", nil
                )
                + "</w:tr><w:tr>"
                + DocxFixture.cell(DocxFixture.paragraph("Ремонт"), nil)
                + DocxFixture.cell(DocxFixture.paragraph("4 часа"), nil)
                + "</w:tr></w:tbl>",
            footnotes: ["3": "По договорённости срок может меняться."]
        )
        let text = try await extract(url).plainText

        let block = try XCTUnwrap(
            text.components(separatedBy: "\n\n").first { $0.contains("Сноска 3") }, text
        )
        XCTAssertTrue(block.contains("| Ремонт"), "сноска оторвана от своей таблицы: \(block)")
        // Строка со сноской идёт после таблицы, а не между строк.
        let lines = block.components(separatedBy: "\n")
        XCTAssertTrue(lines.last?.hasPrefix("Сноска 3") == true, "\(lines)")
    }

    /// Сноска, на которую в тексте нет ссылки, не приписывается документу:
    /// в `footnotes.xml` всегда лежат две служебные записи-разделителя.
    func testUnreferencedFootnotesAreLeftAlone() async throws {
        let url = try write(
            body: DocxFixture.paragraph("Текст без единой сноски."),
            footnotes: ["-1": "разделитель", "0": "продолжение"]
        )
        let extracted = try await extract(url)
        XCTAssertFalse(extracted.plainText.contains("разделитель"), extracted.plainText)
    }

    // MARK: - Таблицы

    /// Три беды разом: ячейка из двух абзацев вставала двумя колонками,
    /// объединённая вниз оставляла строку без значения, а строки таблицы
    /// разделялись пустой строкой и рвались нарезкой по абзацам.
    func testATableKeepsItsShape() async throws {
        let cell = DocxFixture.cell
        let url = try write(body: "<w:tbl>"
            + "<w:tr>" + cell(DocxFixture.paragraph("Крепёж"), "restart") + cell(DocxFixture.paragraph("Болт М6"), nil) + "</w:tr>"
            + "<w:tr>" + cell("<w:p/>", "continue") + cell(DocxFixture.paragraph("Гайка М6"), nil) + "</w:tr>"
            + "<w:tr>" + cell(DocxFixture.paragraph("Профиль"), nil)
            + cell(DocxFixture.paragraph("Уголок 40") + DocxFixture.paragraph("вторая строка ячейки"), nil) + "</w:tr>"
            + "</w:tbl>"
        )
        let extracted = try await extract(url)
        let rows = extracted.plainText.components(separatedBy: "\n")

        XCTAssertEqual(rows.count, 4, "строки таблицы идут подряд, а не через пустую строку: \(extracted.plainText)")
        XCTAssertEqual(rows[0], "| Крепёж | Болт М6 |")
        XCTAssertEqual(rows[1], "| --- | --- |", "разделитель шапки — по нему таблицу узнаёт нарезка")
        XCTAssertEqual(rows[2], "| Крепёж | Гайка М6 |", "объединённая вниз ячейка относится ко всем строкам диапазона")
        XCTAssertEqual(rows[3], "| Профиль | Уголок 40 / вторая строка ячейки |", "два абзаца одной ячейки — одна ячейка")
        XCTAssertEqual(extracted.hasTables, true)
        XCTAssertTrue(extracted.warnings.contains(.tablesFlattened))
    }

    // MARK: - Ссылки

    /// Адрес ссылки сохраняется — но **в ссылках документа, а не в тексте**
    ///.
    ///
    /// Раньше он дописывался к абзацу хвостом « (https://…)». Замер показал,
    /// что адреса — почти сплошь непрозрачные редиректы, в которых нет
    /// ни одного слова для поиска, а в вектор они приносят набор цифр.
    /// Место адреса — метаданные чанка.
    func testALinkTargetGoesToTheLinksNotTheText() async throws {
        let url = try write(body:
            DocxFixture.paragraph("Вводный абзац перед ссылкой.")
            + "<w:p><w:hyperlink r:id=\"rLink\"><w:r><w:t>условия договора</w:t></w:r></w:hyperlink></w:p>"
        )
        let extracted = try await extract(url)

        XCTAssertTrue(extracted.plainText.contains("условия договора"), extracted.plainText)
        XCTAssertFalse(
            extracted.plainText.contains("https://example.org/dogovor"),
            "адрес остался в тексте: \(extracted.plainText)"
        )
        XCTAssertEqual(extracted.links.map(\.url), ["https://example.org/dogovor"])

        // Ссылка стоит при своём абзаце, а не в начале документа.
        let start = try XCTUnwrap(extracted.links.first?.start)
        let paragraph = try XCTUnwrap(extracted.plainText.range(of: "условия договора"))
        XCTAssertEqual(
            start,
            extracted.plainText.distance(from: extracted.plainText.startIndex, to: paragraph.lowerBound)
        )
    }

    /// И доходит до метаданных того чанка, в котором стоит.
    func testTheLinkReachesTheChunkThatCarriesIt() async throws {
        let url = try write(body:
            DocxFixture.paragraph("Первый абзац без единой ссылки на что бы то ни было.")
            + "<w:p><w:hyperlink r:id=\"rLink\"><w:r><w:t>условия договора</w:t></w:r></w:hyperlink></w:p>"
        )
        let extracted = try await extract(url)
        let chunks = extracted.plainText.components(separatedBy: "\n\n").enumerated().map {
            TextChunk(index: $0.offset, text: $0.element)
        }
        let placements = ChunkLocator.placements(of: chunks, in: extracted)

        let carrier = try XCTUnwrap(chunks.first { $0.text.contains("условия договора") })
        XCTAssertEqual(placements[carrier.index]?.links, ["https://example.org/dogovor"])

        let other = try XCTUnwrap(chunks.first { $0.text.hasPrefix("Первый абзац") })
        XCTAssertEqual(placements[other.index]?.links ?? [], [], "чужая ссылка приписана не тому чанку")
    }

    // MARK: - Запасной путь

    /// Битый контейнер не должен уносить с собой файл: разбор частей
    /// не удался — идём прежним путём через систему.
    func testABrokenContainerFallsBackToTheSystemImporter() async throws {
        let url = root.appendingPathComponent("битый.docx")
        try Data("это не архив".utf8).write(to: url)
        do {
            _ = try await extract(url)
            XCTFail("файл не читается ни одним путём — должна быть ошибка")
        } catch let error as ExtractionError {
            guard case .corrupted = error else { return XCTFail("ожидалась причина от системы, получено \(error)") }
        }
    }
}

// MARK: - Сборщик `.docx`

/// Минимальный, но настоящий `.docx`: то же дерево частей, что пишет Word.
struct DocxFixture {
    var body: String
    var styles: String = DocxFixture.defaultStyles
    var numbering: String = DocxFixture.defaultNumbering
    var header: String?
    var footer: String?
    var footnotes: [String: String] = [:]
    var comments: [(id: String, author: String, text: String)] = []

    static let defaultStyles = """
    <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/>\
    <w:pPr><w:outlineLvl w:val="0"/></w:pPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/>\
    <w:pPr><w:outlineLvl w:val="1"/></w:pPr></w:style>
    """

    static let defaultNumbering = """
    <w:abstractNum w:abstractNumId="0">\
    <w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/></w:lvl>\
    <w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1.%2."/></w:lvl>\
    </w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
    """

    static let bulletNumbering = """
    <w:abstractNum w:abstractNumId="7">\
    <w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/><w:lvlText w:val="·"/></w:lvl>\
    </w:abstractNum><w:num w:numId="2"><w:abstractNumId w:val="7"/></w:num>
    """

    static func paragraph(
        _ text: String, style: String? = nil, outlineLevel: Int? = nil,
        numbering: Int? = nil, indent: Int = 0,
        hidden: Bool = false, bold: Bool = false, size: Int? = nil
    ) -> String {
        var properties = ""
        if let style { properties += "<w:pStyle w:val=\"\(style)\"/>" }
        if let numbering {
            properties += "<w:numPr><w:ilvl w:val=\"\(indent)\"/><w:numId w:val=\"\(numbering)\"/></w:numPr>"
        }
        if let outlineLevel { properties += "<w:outlineLvl w:val=\"\(outlineLevel)\"/>" }
        let paragraphProperties = properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>"

        var run = ""
        if hidden { run += "<w:vanish/>" }
        if bold { run += "<w:b/>" }
        if let size { run += "<w:sz w:val=\"\(size * 2)\"/>" }
        let runProperties = run.isEmpty ? "" : "<w:rPr>\(run)</w:rPr>"
        return "<w:p>\(paragraphProperties)<w:r>\(runProperties)<w:t xml:space=\"preserve\">\(text)</w:t></w:r></w:p>"
    }

    /// Ячейка таблицы; `merge` — `restart` или `continue`.
    static let cell: (String, String?) -> String = { content, merge in
        var properties = ""
        if let merge {
            properties += merge == "restart" ? "<w:vMerge w:val=\"restart\"/>" : "<w:vMerge/>"
        }
        return "<w:tc><w:tcPr>\(properties)</w:tcPr>\(content)</w:tc>"
    }

    func build() throws -> Data {
        var section = ""
        if header != nil { section += "<w:headerReference w:type=\"default\" r:id=\"rHeader\"/>" }
        if footer != nil { section += "<w:footerReference w:type=\"default\" r:id=\"rFooter\"/>" }
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <w:body>\(body)\(section.isEmpty ? "" : "<w:sectPr>\(section)</w:sectPr>")</w:body></w:document>
        """

        var entries: [(String, String)] = [
            ("[Content_Types].xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/word/document.xml" \
            ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
            """),
            ("_rels/.rels", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" \
            Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" \
            Target="word/document.xml"/></Relationships>
            """),
            ("word/document.xml", document),
            ("word/styles.xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
            <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\(styles)</w:styles>
            """),
            ("word/numbering.xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
            <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\(numbering)</w:numbering>
            """),
            ("word/_rels/document.xml.rels", relationships),
        ]
        if let header { entries.append(("word/header1.xml", part("hdr", header))) }
        if let footer { entries.append(("word/footer1.xml", part("ftr", footer))) }
        if !comments.isEmpty {
            let items = comments.map { comment in
                "<w:comment w:id=\"\(comment.id)\" w:author=\"\(comment.author)\">"
                + "<w:p><w:r><w:t>\(comment.text)</w:t></w:r></w:p></w:comment>"
            }.joined()
            entries.append(("word/comments.xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
            <w:comments xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\(items)</w:comments>
            """))
        }
        if !footnotes.isEmpty {
            let notes = footnotes.map { id, text in
                "<w:footnote w:id=\"\(id)\"><w:p><w:r><w:t>\(text)</w:t></w:r></w:p></w:footnote>"
            }.joined()
            entries.append(("word/footnotes.xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
            <w:footnotes xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\(notes)</w:footnotes>
            """))
        }

        var builder = ZIPFixtureBuilder()
        for (path, contents) in entries {
            builder.entries.append(.init(path: path, contents: Data(contents.utf8), deflated: true))
        }
        return builder.build()
    }

    private var relationships: String {
        var items = """
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>\
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footnotes" Target="footnotes.xml"/>\
        <Relationship Id="rLink" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" \
        Target="https://example.org/dogovor" TargetMode="External"/>
        """
        if header != nil {
            items += "<Relationship Id=\"rHeader\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/header\" Target=\"header1.xml\"/>"
        }
        if footer != nil {
            items += "<Relationship Id=\"rFooter\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer\" Target=\"footer1.xml\"/>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(items)</Relationships>
        """
    }

    private func part(_ tag: String, _ text: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
        <w:\(tag) xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:p><w:r><w:t>\(text)</w:t></w:r></w:p></w:\(tag)>
        """
    }
}

/// что осталось от разбора Word после.
final class LegacyOfficeLimitsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    private func write(_ name: String, type: NSAttributedString.DocumentType) throws -> URL {
        let text = NSAttributedString(
            string: "Обычный абзац документа, достаточно длинный для того, чтобы им и остаться.\n",
            attributes: [.font: NSFont.systemFont(ofSize: 12)]
        )
        let url = root.appendingPathComponent(name)
        try text.data(from: NSRange(location: 0, length: text.length),
                      documentAttributes: [.documentType: type]).write(to: url)
        return url
    }

    /// У `.rtf` заглянуть внутрь по-прежнему нечем, и это не то же самое, что
    /// «правок нет»: файл заказчика с правками в самом названии проходил
    /// без единой оговорки.
    ///
    /// У `.doc` эта оговорка снята: формат оказался контейнером — не
    /// ZIP, а OLE2, — и теперь он читается своей читалкой, а не системной.
    @MainActor
    func testANonContainerSaysWhatWasNotChecked() async throws {
        let url = try write("проба.rtf", type: .rtf)
        let extracted = try await OfficeExtractor().extract(from: url, options: ExtractionOptions())
        XCTAssertTrue(
            extracted.warnings.contains { $0.text.contains("не проверялись") },
            "\(extracted.warnings.map(\.text))"
        )

        let word = try write("проба.doc", type: .docFormat)
        let read = try await OfficeExtractor().extract(from: word, options: ExtractionOptions())
        XCTAssertFalse(
            read.warnings.contains { $0.text.contains("не проверялись") },
            "\(read.warnings.map(\.text))"
        )
        XCTAssertTrue(read.plainText.contains("Обычный абзац документа"), read.plainText)
    }

    /// А у контейнера оговорка остаётся условной: предупреждать обо всём
    /// подряд — значит научить не читать предупреждения.
    @MainActor
    func testACleanContainerStaysQuiet() async throws {
        let url = root.appendingPathComponent("чистый.docx")
        try DocxFixture(body: DocxFixture.paragraph("Обычный абзац без единой правки и сноски."))
            .build().write(to: url)
        let extracted = try await OfficeExtractor().extract(from: url, options: ExtractionOptions())
        XCTAssertFalse(extracted.warnings.contains { $0.text.contains("не проверялись") }, "\(extracted.warnings)")
        XCTAssertFalse(extracted.warnings.contains(.commentsSkipped))
    }
}
