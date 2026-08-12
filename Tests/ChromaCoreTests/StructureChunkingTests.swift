import XCTest
import PDFKit
import AppKit
@testable import ChromaCore

// MARK: -: cutting on the extracted structure

final class DocumentStructureSectionsTests: XCTestCase {
    /// Three chapters of 100 characters each, with a subsection inside the second.
    private func text() -> String {
        (0..<3).map { chapter in
            "Глава \(chapter + 1). " + String(repeating: "\(chapter)", count: 100 - "Глава 1. ".count)
        }.joined()
    }

    private func structure() -> [DocumentNode] {
        [
            DocumentNode(level: 1, title: "Глава 1", start: 0),
            DocumentNode(level: 1, title: "Глава 2", start: 100),
            DocumentNode(level: 2, title: "Раздел 2.1", start: 150),
            DocumentNode(level: 1, title: "Глава 3", start: 200),
        ]
    }

    func testSectionsAreCutAtHeadingsOfTheChosenLevel() {
        let ranges = DocumentStructureSections.ranges(in: text(), structure: structure(), splitLevel: 1)
        XCTAssertEqual(ranges, [0..<100, 100..<200, 200..<300])
    }

    /// Splitting on level 2 opens the subsection; splitting on level 1 keeps it
    /// inside its chapter — the same rule the Markdown path already follows.
    func testADeeperHeadingOnlySplitsWhenAskedFor() {
        let deep = DocumentStructureSections.ranges(in: text(), structure: structure(), splitLevel: 2)
        XCTAssertEqual(deep, [0..<100, 100..<150, 150..<200, 200..<300])
    }

    /// A title page before the first heading is content, not padding.
    func testTextBeforeTheFirstHeadingBecomesItsOwnSection() {
        let ranges = DocumentStructureSections.ranges(
            in: String(repeating: "y", count: 300),
            structure: [DocumentNode(level: 1, title: "Глава 1", start: 40)],
            splitLevel: 1
        )
        XCTAssertEqual(ranges, [0..<40, 40..<300])
    }

    /// Two headings on one PDF page arrive with the same offset. Both are
    /// real, but there is only one place to cut.
    func testHeadingsSharingAnOffsetProduceOneBoundary() {
        let ranges = DocumentStructureSections.ranges(
            in: String(repeating: "y", count: 100),
            structure: [
                DocumentNode(level: 1, title: "Первый", start: 50),
                DocumentNode(level: 1, title: "Второй", start: 50),
            ],
            splitLevel: 1
        )
        XCTAssertEqual(ranges, [0..<50, 50..<100])
    }

    func testAStructurePointingPastTheEndDoesNotProduceAnEmptySection() {
        let ranges = DocumentStructureSections.ranges(
            in: String(repeating: "y", count: 50),
            structure: [DocumentNode(level: 1, title: "Хвост", start: 900)],
            splitLevel: 1
        )
        XCTAssertEqual(ranges, [0..<50])
    }

    /// Sections are trimmed at the edges only, so each one is still a verbatim
    /// substring — that is what lets `ChunkLocator` find it again.
    func testASectionStaysASubstringOfTheDocument() {
        let source = "Заголовок\n\nТекст первой главы.\n\nЗаголовок 2\n\nТекст второй."
        let sections = DocumentStructureSections.sections(
            in: source,
            structure: [
                DocumentNode(level: 1, title: "Заголовок", start: 0),
                DocumentNode(level: 1, title: "Заголовок 2", start: 31),
            ],
            splitLevel: 1
        )
        XCTAssertEqual(sections.count, 2)
        for section in sections {
            XCTAssertTrue(source.contains(section), "секция «\(section)» перестала быть подстрокой документа")
        }
    }

    func testTopLevelIsTheShallowestOneActuallyUsed() {
        XCTAssertEqual(DocumentStructureSections.topLevel(of: structure()), 1)
        XCTAssertEqual(
            DocumentStructureSections.topLevel(of: [DocumentNode(level: 3, title: "Глубоко", start: 0)]),
            3
        )
    }
}

// MARK: - Document-based on a real outline

final class DocumentBasedStructureTests: XCTestCase {
    private let text = "Введение здесь.\n\nГлава первая и её содержимое.\n\nГлава вторая и её содержимое."

    private var structure: [DocumentNode] {
        [
            DocumentNode(level: 1, title: "Глава первая", start: 17),
            DocumentNode(level: 1, title: "Глава вторая", start: 48),
        ]
    }

    func testStructureCutsTheDocumentWhereTheOutlineSaysSo() {
        let chunks = DocumentBasedChunker(
            configuration: ChunkingConfiguration(strategy: .documentBased, sizeUnit: .characters, maxSectionSize: 4000),
            fileExtension: "pdf",
            structure: structure
        ).chunks(from: text)

        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].text, "Введение здесь.")
        XCTAssertTrue(chunks[1].text.hasPrefix("Глава первая"))
        XCTAssertTrue(chunks[2].text.hasPrefix("Глава вторая"))
    }

    /// The outline wins over the format heuristics: a PDF whose text happens to
    /// contain a `#` is not Markdown.
    func testTheOutlineWinsOverTheMarkdownHeuristic() {
        let hashed = "# Не заголовок\n\nтекст\n\n# Тоже не заголовок\n\nещё текст"
        let withStructure = DocumentBasedChunker(
            configuration: ChunkingConfiguration(strategy: .documentBased, sizeUnit: .characters, maxSectionSize: 4000),
            fileExtension: "pdf",
            structure: [DocumentNode(level: 1, title: "Единственный раздел", start: 0)]
        ).chunks(from: hashed)
        XCTAssertEqual(withStructure.count, 1)

        // Without structure the old behaviour is untouched.
        let without = DocumentBasedChunker(
            configuration: ChunkingConfiguration(strategy: .documentBased, sizeUnit: .characters, maxSectionSize: 4000),
            fileExtension: "md"
        ).chunks(from: hashed)
        XCTAssertEqual(without.count, 2)
    }

    /// A chapter longer than the section limit still goes through the oversized
    /// fallback — structure decides the boundaries, not whether limits apply.
    func testAnOversizedSectionIsStillSplitByTheFallback() {
        let long = String(repeating: "а", count: 500) + String(repeating: "б", count: 500)
        let chunks = DocumentBasedChunker(
            configuration: ChunkingConfiguration(
                strategy: .documentBased, sizeUnit: .characters, overlapPercent: 0,
                maxSectionSize: 200, oversizedFallback: .fixed
            ),
            fileExtension: "pdf",
            structure: [
                DocumentNode(level: 1, title: "Первая", start: 0),
                DocumentNode(level: 1, title: "Вторая", start: 500),
            ]
        ).chunks(from: long)

        XCTAssertGreaterThan(chunks.count, 2)
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= 200 })
        // Nothing crossed the chapter boundary: no chunk holds both letters.
        XCTAssertFalse(chunks.contains { $0.text.contains("а") && $0.text.contains("б") })
    }

    func testNoStructureLeavesTheMarkdownPathAlone() {
        let markdown = "# Первый\n\nтекст\n\n# Второй\n\nтекст"
        let chunks = DocumentBasedChunker(
            configuration: ChunkingConfiguration(strategy: .documentBased, sizeUnit: .characters, maxSectionSize: 4000),
            fileExtension: "md"
        ).chunks(from: markdown)
        XCTAssertEqual(chunks.count, 2)
    }
}

// MARK: - Hierarchical parents from the same source

final class HierarchicalStructureTests: XCTestCase {
    func testParentsAreTheTopLevelSections() {
        let text = String(repeating: "а", count: 300) + String(repeating: "б", count: 300)
        let chunks = HierarchicalChunker(
            configuration: ChunkingConfiguration(
                strategy: .hierarchical, sizeUnit: .characters, levels: 2,
                parentChunkSize: 2000, childChunkSize: 100,
                parentOverlapPercent: 0, childOverlapPercent: 0
            ),
            structure: [
                DocumentNode(level: 1, title: "Первая", start: 0),
                DocumentNode(level: 2, title: "Подраздел", start: 150),
                DocumentNode(level: 1, title: "Вторая", start: 300),
            ]
        ).chunks(from: text)

        let parents = chunks.filter { $0.level == 1 }
        // Two chapters, not three: the level-2 subsection is inside its chapter.
        XCTAssertEqual(parents.count, 2)
        XCTAssertEqual(parents[0].text, String(repeating: "а", count: 300))
        XCTAssertEqual(parents[1].text, String(repeating: "б", count: 300))

        let children = chunks.filter { $0.level == 0 }
        XCTAssertFalse(children.isEmpty)
        XCTAssertTrue(children.allSatisfy { $0.parentIndex != nil })
        // Every child belongs to the chapter it is made of.
        for child in children {
            let parent = try? XCTUnwrap(chunks.first { $0.index == child.parentIndex })
            XCTAssertTrue(parent?.text.contains(child.text) == true)
        }
    }

    /// A parent chunk is embedded like any other, so a chapter longer than the
    /// parent size is split — inside its own boundaries.
    func testAChapterLongerThanTheParentSizeIsSplitWithinItself() {
        let text = String(repeating: "а", count: 600) + String(repeating: "б", count: 100)
        let chunks = HierarchicalChunker(
            configuration: ChunkingConfiguration(
                strategy: .hierarchical, sizeUnit: .characters, levels: 1,
                parentChunkSize: 200, childChunkSize: 100,
                parentOverlapPercent: 0, childOverlapPercent: 0
            ),
            structure: [
                DocumentNode(level: 1, title: "Длинная", start: 0),
                DocumentNode(level: 1, title: "Короткая", start: 600),
            ]
        ).chunks(from: text)

        XCTAssertGreaterThan(chunks.count, 2)
        XCTAssertFalse(chunks.contains { $0.text.contains("а") && $0.text.contains("б") })
    }

    func testWithoutStructureTheSizeBasedParentsAreUnchanged() {
        let text = String(repeating: "слово ", count: 300)
        let configuration = ChunkingConfiguration(
            strategy: .hierarchical, sizeUnit: .characters, levels: 2,
            parentChunkSize: 400, childChunkSize: 100
        )
        let plain = HierarchicalChunker(configuration: configuration).chunks(from: text)
        XCTAssertGreaterThan(plain.filter { $0.level == 1 }.count, 1)
    }
}

// MARK: - Finding a chunk back in its document

final class ChunkLocatorTests: XCTestCase {
    private func document(_ text: String, structure: [DocumentNode] = [], pageStarts: [Int] = []) -> ExtractedDocument {
        ExtractedDocument(
            plainText: text,
            structure: structure,
            pageCount: pageStarts.isEmpty ? nil : pageStarts.count,
            pageStarts: pageStarts,
            containerFormat: "test",
            extractorID: "test",
            extractorVersion: 1
        )
    }

    func testOverlappingChunksAreStillFoundInOrder() {
        let text = String(repeating: "абвгдеёжзи", count: 20)
        let chunks = FixedSizeChunker(size: 40, overlap: 10).chunks(from: text)
        let offsets = ChunkLocator.offsets(of: chunks, in: text)

        XCTAssertEqual(offsets.count, chunks.count)
        let ordered = chunks.compactMap { offsets[$0.index] }
        XCTAssertEqual(ordered, ordered.sorted())
        for chunk in chunks {
            let start = try? XCTUnwrap(offsets[chunk.index])
            guard let start else { continue }
            let from = text.index(text.startIndex, offsetBy: start)
            XCTAssertTrue(text[from...].hasPrefix(chunk.text))
        }
    }

    /// A repeated paragraph must not send a later chunk back to the first copy.
    func testARepeatedPassageDoesNotPullTheOffsetBackwards() {
        let paragraph = "Один и тот же абзац. "
        let text = paragraph + "Разделитель. " + paragraph
        let chunks = [
            TextChunk(index: 0, text: "Один и тот же абзац."),
            TextChunk(index: 1, text: "Разделитель."),
            TextChunk(index: 2, text: "Один и тот же абзац."),
        ]
        let offsets = ChunkLocator.offsets(of: chunks, in: text)
        XCTAssertEqual(offsets[0], 0)
        XCTAssertEqual(offsets[2], paragraph.count + "Разделитель. ".count)
    }

    /// The LLM strategy is allowed to hand back text it rewrote. There is no
    /// honest offset for that, so nothing is claimed.
    func testAChunkThatIsNotInTheTextGetsNoPlacement() {
        let doc = document("Настоящий текст документа.", pageStarts: [0])
        let placements = ChunkLocator.placements(
            of: [TextChunk(index: 0, text: "Пересказанный моделью текст.")],
            in: doc
        )
        XCTAssertTrue(placements.isEmpty)
    }

    /// Hierarchical: a child is searched inside its own parent, so parent overlap
    /// cannot push a later parent past a boundary it still needs.
    func testChildrenAreLocatedInsideTheirParent() {
        let text = String(repeating: "а", count: 200) + String(repeating: "б", count: 200)
        let chunks = HierarchicalChunker(
            configuration: ChunkingConfiguration(
                strategy: .hierarchical, sizeUnit: .characters, levels: 2,
                parentChunkSize: 200, childChunkSize: 50,
                parentOverlapPercent: 40, childOverlapPercent: 0
            )
        ).chunks(from: text)

        let offsets = ChunkLocator.offsets(of: chunks, in: text)
        for child in chunks where child.parentIndex != nil {
            guard let parentIndex = child.parentIndex,
                  let parentStart = offsets[parentIndex],
                  let parent = chunks.first(where: { $0.index == parentIndex }),
                  let start = offsets[child.index] else {
                continue
            }
            XCTAssertGreaterThanOrEqual(start, parentStart)
            XCTAssertLessThanOrEqual(start, parentStart + parent.text.count)
        }
    }

    func testPlacementCarriesPageAndHeadingPath() {
        let text = String(repeating: "а", count: 100) + String(repeating: "б", count: 100)
        let doc = document(
            text,
            structure: [
                DocumentNode(level: 1, title: "Глава 1", start: 0),
                DocumentNode(level: 1, title: "Глава 2", start: 100),
                DocumentNode(level: 2, title: "Раздел 2.1", start: 150),
            ],
            pageStarts: [0, 100]
        )
        let chunks = [
            TextChunk(index: 0, text: String(repeating: "а", count: 100)),
            TextChunk(index: 1, text: String(repeating: "б", count: 100)),
        ]
        let placements = ChunkLocator.placements(of: chunks, in: doc)

        XCTAssertEqual(placements[0]?.pageNumber, 1)
        XCTAssertEqual(placements[0]?.headingPath, "Глава 1")
        XCTAssertEqual(placements[1]?.pageNumber, 2)
        XCTAssertEqual(placements[1]?.headingPath, "Глава 2")
    }

    /// A format without pages says nothing about pages rather than saying «1».
    func testAFormatWithoutPagesWritesNoPageNumber() {
        let doc = document(
            "Только текст.",
            structure: [DocumentNode(level: 1, title: "Заголовок", start: 0)]
        )
        let placements = ChunkLocator.placements(of: [TextChunk(index: 0, text: "Только текст.")], in: doc)
        XCTAssertNil(placements[0]?.pageNumber)
        XCTAssertEqual(placements[0]?.headingPath, "Заголовок")
    }
}

// MARK: - End to end: a PDF cut along its own table of contents

final class PDFDocumentBasedChunkingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cdbm-chunk-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The Definition of Done of stage 4: «PDF с оглавлением режется Document-based
    /// стратегией по разделам, `heading_path` заполнен».
    @MainActor
    func testAnOutlinedPDFIsCutByChapterWithPagesAndHeadings() async throws {
        let url = root.appendingPathComponent("book.pdf")
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var mediaBox = bounds
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        // No letter «к» anywhere in the fixture on purpose: drawing the system
        // font into a `CGPDF` context encodes it as U+0138 «ĸ», and the text
        // read back would differ from the text written — an artifact of building
        // the PDF here, not of extracting it.
        for body in ["Глава первая\n\nПервый раздел о смысле.", "Глава вторая\n\nВторой раздел о форме."] {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (body as NSString).draw(
                in: bounds.insetBy(dx: 60, dy: 60),
                withAttributes: [.font: NSFont.systemFont(ofSize: 18)]
            )
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()

        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        let outlineRoot = PDFOutline()
        for (index, title) in ["Глава первая", "Глава вторая"].enumerated() {
            let child = PDFOutline()
            child.label = title
            child.destination = PDFDestination(page: try XCTUnwrap(document.page(at: index)), at: CGPoint(x: 0, y: bounds.height))
            outlineRoot.insertChild(child, at: index)
        }
        document.outlineRoot = outlineRoot
        XCTAssertTrue(document.write(to: url))

        let extracted = try await PDFExtractor().extract(from: url, options: ExtractionOptions())
        let chunks = try await ChunkingPipeline(
            configuration: ChunkingConfiguration(strategy: .documentBased, sizeUnit: .characters, maxSectionSize: 4000)
        ).chunks(from: extracted.plainText, fileExtension: "pdf", structure: extracted.structure)

        XCTAssertEqual(chunks.count, 2, "оглавление из двух глав должно дать две секции")
        XCTAssertTrue(chunks[0].text.contains("о смысле"))
        XCTAssertTrue(chunks[1].text.contains("о форме"))

        let placements = ChunkLocator.placements(of: chunks, in: extracted)
        XCTAssertEqual(placements[0]?.pageNumber, 1)
        XCTAssertEqual(placements[0]?.headingPath, "Глава первая")
        XCTAssertEqual(placements[1]?.pageNumber, 2)
        XCTAssertEqual(placements[1]?.headingPath, "Глава вторая")
    }
}
