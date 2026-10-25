import XCTest
import AppKit
@testable import ChromaCore

/// границы кусков: склейка, перекрытие, предложения, таблицы.
final class ChunkBoundaryTests: XCTestCase {
    private let separators = ["\n\n", "\n", ". ", " "]

    private func table(_ rows: Int, header: String = "| № | Позиция |", from first: Int = 1) -> String {
        header + "\n| --- | --- |\n" + (first..<(first + rows)).map { "| \($0) | строка таблицы номер \($0) |" }.joined(separator: "\n")
    }

    // MARK: - Склейка и перекрытие

    /// Главное: разделитель на конце блока не теряется, и строка таблицы
    /// не приклеивается к шапке следующей.
    func testBlocksAreNotGluedTogether() {
        let text = table(6) + "\n\n" + table(1, header: "| Код | Название |")
        let chunks = RecursiveChunker(size: 120, overlap: 20, separators: separators).chunks(from: text)
        for chunk in chunks {
            XCTAssertFalse(chunk.text.contains("||"), chunk.text)
        }
        XCTAssertTrue(chunks.contains { $0.text.contains("| 6 | строка таблицы номер 6 |\n\n| Код") || $0.text.hasPrefix("| Код") })
    }

    /// Перекрытие — с начала предложения, а не с середины слова.
    func testOverlapStartsAtASentence() {
        let text = (1...12).map { "Предложение номер \($0) о поставке оборудования." }.joined(separator: " ")
        let chunks = RecursiveChunker(size: 200, overlap: 60, separators: separators).chunks(from: text)
        XCTAssertGreaterThan(chunks.count, 2)
        for chunk in chunks {
            XCTAssertTrue(chunk.text.hasPrefix("Предложение"), chunk.text)
            XCTAssertLessThanOrEqual(chunk.text.count, 200)
        }
        // Перекрытие есть: начало второго куска — конец первого.
        XCTAssertTrue(chunks[0].text.hasSuffix(chunks[1].text.components(separatedBy: ".")[0] + "."))
    }

    /// Внутри таблицы перекрытия нет, и строки не режутся.
    func testTablesHaveNoOverlapAndWholeRows() {
        let text = table(20)
        let chunks = RecursiveChunker(size: 200, overlap: 60, separators: separators).chunks(from: text)
        var seen: [String] = []
        for chunk in chunks {
            for line in chunk.text.components(separatedBy: "\n") {
                XCTAssertTrue(TableText.isRow(line), "обрывок строки: \(line)")
                if !TableText.isSeparator(line), !line.hasPrefix("| №") { seen.append(line) }
            }
        }
        XCTAssertEqual(seen.count, 20, "каждая строка — ровно один раз")
    }

    // MARK: - Предложения

    func testSentencesRespectNumbersAndAbbreviations() {
        let sentences = SentenceSplitter.sentences(in: "Цена 1 234 567.00 руб. за ед. см. п. 1.2 договора. Срок — 10 дней.\n1. Предмет договора\nА. С. Пушкин писал. Конец")
        XCTAssertEqual(sentences, [
            "Цена 1 234 567.00 руб. за ед. см. п. 1.2 договора.",
            "Срок — 10 дней.",
            "1. Предмет договора",
            "А. С. Пушкин писал.",
            "Конец",
        ])
        XCTAssertEqual(SentenceSplitter.sentences(in: "| 1 | Процессор 2.4 ГГц. Новый | 10,00 |"), ["| 1 | Процессор 2.4 ГГц. Новый | 10,00 |"])
        XCTAssertEqual(
            SentenceSplitter.sentences(in: "Расходы, в т.ч. НДС, и т.д. Всё."),
            ["Расходы, в т.ч. НДС, и т.д. Всё."]
        )
    }

    /// Семантический кусок — вырезка из текста: переводы строк на месте.
    func testSemanticChunksKeepLineBreaks() async throws {
        struct Flat: EmbeddingProvider {
            func embed(texts: [String], model: String) async throws -> [[Double]] { texts.map { _ in [1, 0] } }
        }
        let text = "Перечень:\n| 1 | Сервер | 10 |\n| 2 | Стойка | 20 |\nИтог подведён."
        let configuration = ChunkingConfiguration(
            strategy: .semantic, sizeUnit: .characters, thresholdMode: .absolute, thresholdValue: 0.5,
            sentenceBuffer: 1, minChunkSize: 32, maxChunkSize: 4096
        )
        let chunks = try await SemanticChunker(configuration: configuration, embeddings: Flat(), model: "m").chunks(from: text)
        XCTAssertEqual(chunks.map(\.text), [text])
    }

    // MARK: - Таблица в своём размере

    /// Шапка входит в размер: кусок таблицы делится по строкам, у каждой
    /// части — шапка.
    func testATableChunkFitsWithItsHeader() {
        let text = table(12)
        let chunks = TableChunks.fitted([TextChunk(index: 0, text: text)], in: text) { _ in 180 }
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertTrue(chunk.text.hasPrefix("| № | Позиция |\n| --- | --- |"), chunk.text)
            XCTAssertLessThanOrEqual(chunk.text.count, 180)
        }
        XCTAssertEqual(chunks.map(\.index), Array(chunks.indices))
    }

    /// Строка длиннее куска — строками-продолжениями с номером и названием.
    func testALongRowContinuesWithItsNumberAndName() {
        let components = (1...12).map { "Компонент \($0) с подробной характеристикой (Кол-во, шт.: \($0))" }.joined(separator: "; ")
        let row = "| 3 | Сервер Тип 3 в составе: \(components) | 1 | 10 000,00 |"
        let text = "| № | Позиция | Кол-во | Цена |\n| --- | --- | --- | --- |\n" + row
        let chunks = TableChunks.fitted([TextChunk(index: 0, text: text)], in: text) { _ in 400 }
        XCTAssertGreaterThan(chunks.count, 2)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.text.count, 400, chunk.text)
            let lines = chunk.text.components(separatedBy: "\n")
            XCTAssertTrue(TableText.isSeparator(lines[1]))
            XCTAssertTrue(lines[2].hasPrefix("| 3 | Сервер Тип 3 в составе:"), lines[2])
        }
        XCTAssertTrue(chunks.last?.text.contains("10 000,00") == true)
        // Ни одно слово не потеряно.
        let joined = chunks.map(\.text).joined(separator: " ")
        for index in 1...12 { XCTAssertTrue(joined.contains("Компонент \(index) с подробной")) }
    }

    /// Дорезка под модель: таблица — по строкам с шапкой, а не одной строкой.
    func testOversizeSplittingKeepsTableRows() {
        let text = (1...30).map { "| \($0) | Сервер тип \($0), процессор 2.4 ГГц | \($0 * 10),00 |" }
        let full = "| № | Позиция | Цена |\n| --- | --- | --- |\n" + text.joined(separator: "\n")
        let fitted = OversizeChunks.fitted([TextChunk(index: 0, text: full)], contextLength: nil, characterLimit: 700)
        XCTAssertGreaterThan(fitted.split, 0)
        for chunk in fitted.chunks {
            XCTAssertTrue(chunk.text.hasPrefix("| № | Позиция | Цена |\n| --- |"), chunk.text)
            XCTAssertTrue(chunk.text.contains("2.4 ГГц"))
            XCTAssertLessThanOrEqual(chunk.text.count, 700)
        }
    }

    /// Дорезка прозы — вырезкой: переводы строк остаются.
    func testOversizeSplittingKeepsLineBreaks() {
        let text = (1...40).map { "Пункт \($0) обязывает поставщика." }.joined(separator: "\n")
        let fitted = OversizeChunks.fitted([TextChunk(index: 0, text: text)], contextLength: nil, characterLimit: 300)
        for chunk in fitted.chunks {
            XCTAssertTrue(chunk.text.contains("\n"))
            XCTAssertFalse(chunk.text.contains(". Пункт"), "строки склеены пробелом")
        }
    }

    // MARK: - Раздел куска

    /// Раздел — по большей части куска, а не по первому знаку.
    func testTheChunkSectionIsWhereMostOfItIs() {
        let document = ExtractedDocument(
            plainText: String(repeating: "x", count: 400),
            structure: [
                DocumentNode(level: 1, title: "Глава 1", start: 0),
                DocumentNode(level: 2, title: "Раздел 1.1", start: 50),
                DocumentNode(level: 2, title: "Раздел 1.2", start: 120),
                DocumentNode(level: 1, title: "Глава 2", start: 200),
                DocumentNode(level: 1, title: "Глава 3", start: 300),
            ],
            containerFormat: "test", extractorID: "test", extractorVersion: 1
        )
        let boundaries = document.structure.map(\.start)
        func path(_ start: Int, _ end: Int) -> String? {
            ChunkLocator.dominantPath(from: start, to: end, boundaries: boundaries, in: document)
        }
        XCTAssertEqual(path(190, 290), "Глава 2", "хвост главы 1 в перекрытии")
        XCTAssertEqual(path(0, 199), "Глава 1", "глава с подразделами — сама глава")
        XCTAssertEqual(path(110, 199), "Глава 1 > Раздел 1.2")
        XCTAssertEqual(path(150, 350), "Глава 2", "ни одна не больше половины — наибольшая")
        XCTAssertEqual(path(210, 260), "Глава 2", "внутри одного раздела")
    }

    // MARK: - Заголовки PDF

    func testPDFHeadingCandidates() {
        XCTAssertEqual(PDFHeadings.kind(of: "2.1 Требования к системе")?.level, 2)
        XCTAssertEqual(PDFHeadings.kind(of: "5. ОТВЕТСТВЕННОСТЬ СТОРОН")?.level, 1)
        XCTAssertEqual(PDFHeadings.kind(of: "Приложение 1")?.level, 1)
        XCTAssertEqual(PDFHeadings.kind(of: "ТЕХНИЧЕСКОЕ ЗАДАНИЕ")?.numbered, false)
        XCTAssertNil(PDFHeadings.kind(of: "1. Общие положения ........ 3"), "оглавление")
        XCTAssertNil(PDFHeadings.kind(of: "2.1 Требования к системе 15"), "строка оглавления с номером страницы")
        XCTAssertNil(PDFHeadings.kind(of: "1.1. Поставщик обязуется поставить товар в сроки, указанные в спецификации к настоящему договору."), "пункт-предложение")
        XCTAssertNil(PDFHeadings.kind(of: "| 1 | Сервер |"))
        XCTAssertNil(PDFHeadings.kind(of: "3 года;"))
        XCTAssertTrue(PDFHeadings.isContinuation("КОНТРАКТА"))
        XCTAssertTrue(PDFHeadings.isContinuation("предоставлении услуг"))
        XCTAssertFalse(PDFHeadings.isContinuation("Исполнитель обязан обеспечить."))
        XCTAssertFalse(PDFHeadings.isContinuation("6. ОТВЕТСТВЕННОСТЬ СТОРОН"))
    }

    // MARK: - Схема, а не таблица

    func testADiagramGridIsNotATable() {
        let blob = String(repeating: "МБД Exadata (69) интеграция ", count: 20)
        XCTAssertTrue(TableGeometry.isDiagram([[blob, "", "РЦОД"], ["a", "b", "c"]]))
        XCTAssertFalse(TableGeometry.isDiagram([["№", "Наименование", "Цена"], ["1", blob, "10"]]),
                       "длинная ячейка в данных — обычная таблица")
    }

    // MARK: - Лист в режиме документа

    private func sheet(_ grid: [[String]]) -> [SheetRow] {
        grid.enumerated().map { offset, line in
            var cells: [Int: CellValue] = [:]
            for (column, value) in line.enumerated() where !value.isEmpty {
                cells[column] = Double(value).map { .number($0) } ?? .text(value)
            }
            return SheetRow(number: offset + 1, cells: cells)
        }
    }

    /// Шапка в две строки, название, подсказка и ряд граф — как у документа.
    func testASheetRendersLikeADocumentTable() {
        let rows = sheet([
            ["Перечень услуг", "", "", ""],
            ["", "", "2026", "2026"],
            ["№", "Наименование", "2026", ""],
            ["", "", "Стоимость", "Объём"],
            ["1", "2", "3", "4"],
            ["1", "Процессор", "10", "2"],
            ["2", "Память", "20", "4"],
        ])
        let merges = ["A1:D1", "A3:A4", "B3:B4", "C3:D3"].compactMap(XLSXReader.MergedRange.init(reference:))
        let rendered = SheetRenderer.render(rows: rows, headerRow: nil, merges: merges)
        XCTAssertEqual(rendered.text, """
        Перечень услуг
        | № | Наименование | 2026 / Стоимость | 2026 / Объём |
        | --- | --- | --- | --- |
        | 1 | Процессор | 10 | 2 |
        | 2 | Память | 20 | 4 |
        """)
        XCTAssertEqual(rendered.header, "| № | Наименование | 2026 / Стоимость | 2026 / Объём |\n| --- | --- | --- | --- |")
        // Первый кусок с названием второй шапки не получает.
        let chunks = SheetRenderer.repeatingHeader(rendered.header, in: [TextChunk(index: 0, text: rendered.text)])
        XCTAssertEqual(chunks[0].text, rendered.text)
    }

    /// Хвост блока приклеивается к соседу тем, что стояло между ними:
    /// строки таблицы остаются строками.
    func testAnAdaptiveTailKeepsItsLineBreak() {
        let block = "| 1 | Сервер | 10 |\n| 2 | Стойка | 20 |"
        let merged = AdaptiveChunker.honouringMinimum(
            [["| 1 | Сервер | 10 |", "| 2 | Стойка | 20 |"]], minimum: 100, maximum: 1000, sources: [block]
        )
        XCTAssertEqual(merged, [block])
    }

    /// Шапка таблицы не остаётся в конце куска без своих строк, а
    /// разделитель `| --- |` — в начале следующего без шапки.
    func testAHeaderStaysWithItsRows() {
        let prose = String(repeating: "Текст раздела о закупке. ", count: 6)
        let text = prose + "\n\n" + table(4)
        for size in stride(from: 150, through: 260, by: 10) {
            for chunk in RecursiveChunker(size: size, overlap: 20, separators: separators).chunks(from: text) {
                let lines = chunk.text.components(separatedBy: "\n")
                XCTAssertFalse(TableText.isSeparator(lines[0]), "разделитель без шапки при \(size): \(chunk.text)")
                XCTAssertFalse(lines.last.map { $0.hasPrefix("| №") } ?? false, "шапка в конце при \(size): \(chunk.text)")
            }
        }
    }

    // MARK: - Ревью

    /// Кусок с дописанной шапкой встаёт на свою первую строку, а не на
    /// разделитель в начале таблицы; и все куски находятся.
    func testAHeaderedTableChunkIsLocatedByItsRows() {
        let header = "| № | Позиция | Цена |\n| --- | --- | --- |"
        let rows = (1...40).map { "| \($0) | Сервер номер \($0) с длинным названием позиции | \($0 * 100),00 |" }
        let text = "Вступление к таблице.\n\n" + header + "\n" + rows.joined(separator: "\n") + "\n\nКонец."
        let chunks = TableChunkHeaders.applied(
            to: RecursiveChunker(size: 900, overlap: 0, separators: separators).chunks(from: text), in: text)
        XCTAssertGreaterThan(chunks.count, 2)
        let offsets = ChunkLocator.offsets(of: chunks, in: text)
        for chunk in chunks.dropFirst() {
            let lines = chunk.text.components(separatedBy: "\n")
            guard let firstRow = lines.first(where: { $0.hasPrefix("| ") && !$0.hasPrefix("| №") && !TableText.isSeparator($0) }),
                  let truth = text.range(of: firstRow) else { continue }
            XCTAssertEqual(offsets[chunk.index], text.distance(from: text.startIndex, to: truth.lowerBound), chunk.text)
        }
    }

    /// Шапка, с которой начался кусок, не выходит отдельным куском.
    func testALoneHeaderIsNotAChunk() {
        let header = "| № | Позиция |\n| --- | --- |"
        let long = "| 1 | " + String(repeating: "Компонент с характеристиками; ", count: 20) + " |"
        let text = String(repeating: "Абзац перед таблицей о закупке оборудования. ", count: 4) + "\n\n"
            + header + "\n" + long + "\n| 2 | Стойка |"
        for chunk in RecursiveChunker(size: 200, overlap: 0, separators: separators).chunks(from: text) {
            XCTAssertFalse(RecursiveChunker.isTableHeader(chunk.text), "кусок из одной шапки: \(chunk.text)")
        }
    }

    /// Не таблица, хоть и с «|», — `TableChunks` её не трогает.
    func testCodeWithPipesIsNotSplitAsATable() {
        let code = (1...60).map { "if a || b { call\($0)() }" }.joined(separator: "\n")
        XCTAssertEqual(TableChunks.fitted([TextChunk(index: 0, text: code)], in: code) { _ in 500 }.count, 1)
    }

    /// Куски, которые делить нельзя: раздел «оставить как есть» и родитель.
    func testSomeChunksHaveNoTableLimit() {
        var structural = ChunkingConfiguration(strategy: .documentBased)
        structural.oversizedFallback = .keep
        XCTAssertNil(structural.characterLimit(of: TextChunk(index: 0, text: "")))
        structural.oversizedFallback = .recursive
        XCTAssertNotNil(structural.characterLimit(of: TextChunk(index: 0, text: "")))
        let hierarchical = ChunkingConfiguration(strategy: .hierarchical)
        XCTAssertNil(hierarchical.characterLimit(of: TextChunk(index: 0, text: "", level: 1)))
        XCTAssertNotNil(hierarchical.characterLimit(of: TextChunk(index: 1, text: "", level: 0, parentIndex: 0)))
    }

    /// Перевод строки Windows — тоже граница.
    func testWindowsLineBreaksSplitSentences() {
        XCTAssertEqual(SentenceSplitter.sentences(in: "Заголовок\r\nТекст абзаца\r\nЕщё строка"),
                       ["Заголовок", "Текст абзаца", "Ещё строка"])
    }

    /// Окно LLM-нарезки — предел: строка таблицы длиннее него режется.
    func testAWindowCutsAnOversizedRow() {
        let row = "| 1 | " + String(repeating: "очень длинное описание позиции ", count: 30) + " |"
        let windows = RecursiveChunker(size: 300, overlap: 0, separators: separators, keepsTableRowsWhole: false)
            .chunks(from: row)
        XCTAssertGreaterThan(windows.count, 1)
        XCTAssertTrue(windows.allSatisfy { $0.text.count <= 300 })
    }

    /// Кусок, начавшийся с разделителя, получает строку подписей.
    func testAChunkStartingWithASeparatorGetsItsLabels() {
        let text = table(4)
        let lines = text.components(separatedBy: "\n")
        let chunks = [
            TextChunk(index: 0, text: lines[0]),
            TextChunk(index: 1, text: lines[1...].joined(separator: "\n")),
        ]
        let result = TableChunkHeaders.applied(to: chunks, in: text)
        XCTAssertTrue(result[1].text.hasPrefix("| № | Позиция |\n| --- | --- |\n| 1 |"), result[1].text)
    }

    // MARK: - Место куска по большей части, а не по первому знаку

    /// Кусок, начатый хвостом слайда 1, но почти весь со слайда 2, — слайд 2.
    func testAChunkBelongsToTheSlideThatFillsMostOfIt() {
        let first = "Хвост первого слайда."
        let second = "Второй слайд: длинный текст про архитектуру решения и её узлы."
        let text = first + "\n\n" + second
        let document = ExtractedDocument(
            plainText: text,
            parts: [
                DocumentPart(kind: .slide, index: 0, id: "slide-1", start: 0),
                DocumentPart(kind: .slide, index: 1, id: "slide-2", start: first.count + 2),
            ],
            containerFormat: "key", extractorID: "test", extractorVersion: 1
        )
        let placements = ChunkLocator.placements(of: [TextChunk(index: 0, text: text)], in: document)
        XCTAssertEqual(placements[0]?.part?.id, "slide-2")
    }

    /// Кусок, начатый концом абзаца перед списком, а дальше весь из пунктов,
    /// получает вводную фразу списка.
    func testAChunkMostlyOfListItemsGetsTheLeadIn() {
        let leadIn = "Исполнитель обязан обеспечить:"
        let items = (1...4).map { "● пункт номер \($0) с достаточно длинным текстом обязанности" }
        let text = "Вступление к разделу.\n\n" + leadIn + "\n\n" + items.joined(separator: "\n\n")
        let document = ExtractedDocument(
            plainText: text, containerFormat: "txt", extractorID: "test", extractorVersion: 1
        )
        // Кусок — с последних слов фразы, вся она в него не попала.
        let tail = "обеспечить:\n\n" + items.joined(separator: "\n\n")
        let placements = ChunkLocator.placements(of: [TextChunk(index: 0, text: tail)], in: document)
        XCTAssertEqual(placements[0]?.listLeadIn, leadIn)
        // Кусок, где фраза стоит сама, её не повторяет.
        let whole = ChunkLocator.placements(of: [TextChunk(index: 0, text: text)], in: document)
        XCTAssertNil(whole[0]?.listLeadIn)
    }

    // MARK: - Раздел из одного заголовка

    /// «Раздел 2» и сразу «2.1» — заголовок уходит в начало подраздела.
    func testABareHeadingJoinsTheNextSectionByOutline() {
        let text = "Раздел 1 Общее\nТекст первого раздела.\n\nРаздел 2 Требования\n\n2.1 Сроки\nТекст про сроки."
        func offset(_ needle: String) -> Int { text.distance(from: text.startIndex, to: text.range(of: needle)!.lowerBound) }
        let structure = [
            DocumentNode(level: 1, title: "Раздел 1 Общее", start: 0),
            DocumentNode(level: 1, title: "Раздел 2 Требования", start: offset("Раздел 2")),
            DocumentNode(level: 1, title: "2.1 Сроки", start: offset("2.1 Сроки")),
        ]
        let sections = DocumentStructureSections.sections(in: text, structure: structure, splitLevel: 1)
        XCTAssertEqual(sections, [
            "Раздел 1 Общее\nТекст первого раздела.",
            "Раздел 2 Требования\n\n2.1 Сроки\nТекст про сроки.",
        ])
        let hierarchical = HierarchicalChunker(configuration: ChunkingConfiguration(), structure: structure)
            .chunks(from: text).filter { $0.level == 1 }.map(\.text)
        XCTAssertEqual(hierarchical, sections)
    }

    /// То же в Markdown.
    func testABareMarkdownHeadingJoinsTheNextSection() {
        var configuration = ChunkingConfiguration()
        configuration.splitHeaderLevel = 2
        let text = "# Глава 1\n\n## 1.1 Начало\nТекст.\n\n## 1.2 Конец\nЕщё текст."
        let sections = DocumentBasedChunker(configuration: configuration, fileExtension: "md").sections(of: text)
        XCTAssertEqual(sections, ["# Глава 1\n\n## 1.1 Начало\nТекст.\n", "## 1.2 Конец\nЕщё текст."])
    }

    // MARK: - Место продолжения длинной строки

    /// Продолжение длинной строки таблицы в файле дословно не стоит — оно
    /// находится по куску ячейки после «…», а не по пустым ячейкам.
    func testAContinuationOfALongRowIsFoundByItsCellText() {
        let tail = "вторая половина длинного описания позиции, которая ушла в продолжение"
        let text = """
        Вступление.

        |  |  | Прочее |
        | --- | --- | --- |
        |  |  | пусто |

        | № | Позиция |
        | --- | --- |
        | 1 | Сервер стоечный: первая половина описания; \(tail) |
        """
        let chunk = "| № | Позиция |\n| --- | --- |\n| 1 | Сервер стоечный: … \(tail) |"
        let offsets = ChunkLocator.offsets(of: [TextChunk(index: 0, text: chunk)], in: text)
        let expected = text.distance(from: text.startIndex, to: text.range(of: tail)!.lowerBound)
        XCTAssertEqual(offsets[0], expected)
    }

    /// Шрифт заголовка — у его собственного вхождения, а не у ссылки на него
    /// ниже, даже когда выше в тексте страницы таблица с разметкой, которой
    /// в шрифтах PDF нет.
    func testHeadingFontComesFromItsOwnOccurrenceDespiteTableMarkup() {
        let regular = NSFont.systemFont(ofSize: 11)
        let bold = NSFont.boldSystemFont(ofSize: 14)
        let attributed = NSMutableAttributedString(string: "А Б В Г\n1 2 3 4\n", attributes: [.font: regular])
        attributed.append(NSAttributedString(string: "ОБЩИЕ ПОЛОЖЕНИЯ\n", attributes: [.font: bold]))
        attributed.append(NSAttributedString(string: "см. ОБЩИЕ ПОЛОЖЕНИЯ\n", attributes: [.font: regular]))
        let page = "| А | Б | В | Г |\n| --- | --- | --- | --- |\n| 1 | 2 | 3 | 4 |\n\nОБЩИЕ ПОЛОЖЕНИЯ\nсм. ОБЩИЕ ПОЛОЖЕНИЯ"
        let before = String(page[..<page.range(of: "ОБЩИЕ ПОЛОЖЕНИЯ")!.lowerBound])
        let near = before.filter(PDFHeadings.FontMap.isCounted).count
        let font = PDFHeadings.FontMap(attributed).font(of: "ОБЩИЕ ПОЛОЖЕНИЯ", near: near)
        XCTAssertEqual(font?.pointSize, 14)
    }

    /// Кусок ячейки с `|` ищется в том виде, в каком ячейка записана в тексте.
    func testCellFragmentsKeepTheirPipeEscaped() {
        let fragments = ChunkLocator.cellFragments(of: ["| 1 | Начало … длинный хвост A \\| B ячейки таблицы |"])
        XCTAssertEqual(fragments.first, "длинный хвост A \\| B ячейки таблицы")
    }
}
