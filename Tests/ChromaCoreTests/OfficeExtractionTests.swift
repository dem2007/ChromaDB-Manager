import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import ChromaCore

/// Fixtures are built here rather than committed: wants documents
/// made for the test, and `NSAttributedString` writes all four formats itself.
final class OfficeExtractionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-office-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    @MainActor
    private func document(withTable: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        func paragraph(_ text: String, size: CGFloat, bold: Bool) {
            let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
            result.append(NSAttributedString(string: text + "\n", attributes: [.font: font]))
        }
        paragraph("Глава первая", size: 24, bold: true)
        paragraph("Обычный текст первой главы, достаточно длинный, чтобы считаться абзацем, а не заголовком.", size: 12, bold: false)
        paragraph("Раздел 1.1", size: 18, bold: true)
        paragraph("Текст раздела, тоже вполне обычный и достаточно длинный для абзаца.", size: 12, bold: false)
        paragraph("Глава вторая", size: 24, bold: true)
        paragraph("Текст второй главы, который ничем не выделяется среди прочего текста.", size: 12, bold: false)

        guard withTable else { return result }
        let table = NSTextTable()
        table.numberOfColumns = 2
        for (row, pair) in [("Ключ", "Значение"), ("альфа", "1")].enumerated() {
            for (column, text) in [pair.0, pair.1].enumerated() {
                let style = NSMutableParagraphStyle()
                style.textBlocks = [NSTextTableBlock(
                    table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1
                )]
                result.append(NSAttributedString(
                    string: text + "\n",
                    attributes: [.paragraphStyle: style, .font: NSFont.systemFont(ofSize: 12)]
                ))
            }
        }
        return result
    }

    @MainActor
    @discardableResult
    private func write(_ name: String, type: NSAttributedString.DocumentType, withTable: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(name)
        let data = try document(withTable: withTable).data(
            from: NSRange(location: 0, length: document(withTable: withTable).length),
            documentAttributes: [.documentType: type]
        )
        try data.write(to: url)
        return url
    }

    // MARK: - Every format the section names

    @MainActor
    func testAllFourFormatsAreRead() async throws {
        let cases: [(String, NSAttributedString.DocumentType)] = [
            ("doc.docx", .officeOpenXML),
            ("doc.rtf", .rtf),
            ("doc.odt", .openDocument),
            ("doc.doc", .docFormat),
        ]
        for (name, type) in cases {
            let url = try write(name, type: type)
            let extracted = try await OfficeExtractor().extract(from: url, options: ExtractionOptions())

            XCTAssertTrue(extracted.plainText.contains("Глава первая"), "\(name): текста нет")
            XCTAssertTrue(extracted.plainText.contains("Текст второй главы"), "\(name): хвост потерян")
            XCTAssertEqual(extracted.extractorID, "office")
        }
    }

    /// Headings come out of size and weight, and say so: the structure is a
    /// guess, and a chunk cut along it deserves to carry that label.
    @MainActor
    func testHeadingsBecomeStructureMarkedAsAGuess() async throws {
        let url = try write("headings.rtf", type: .rtf)
        let extracted = try await OfficeExtractor().extract(from: url, options: ExtractionOptions())

        XCTAssertEqual(extracted.structureSource, .heuristic)
        XCTAssertTrue(extracted.warnings.contains(.structureIsHeuristic))
        XCTAssertEqual(extracted.structure.map(\.title), ["Глава первая", "Раздел 1.1", "Глава вторая"])
        // 24 pt above 18 pt: chapters at level 1, the section under them.
        XCTAssertEqual(extracted.structure.map(\.level), [1, 2, 1])
    }

    /// And the structure is usable — the whole point of
    @MainActor
    func testTheHeadingPathFollowsTheGuessedStructure() async throws {
        let url = try write("path.rtf", type: .rtf)
        let extracted = try await OfficeExtractor().extract(from: url, options: ExtractionOptions())

        let sectionStart = try XCTUnwrap(extracted.structure.first { $0.title == "Раздел 1.1" }?.start)
        XCTAssertEqual(extracted.headingPath(forCharacter: sectionStart), "Глава первая > Раздел 1.1")
    }

    /// A long bold paragraph is a bold paragraph. Without the length rule a
    /// document that emphasises whole sentences would come out as a table of
    /// contents of itself.
    @MainActor
    func testALongBoldParagraphIsNotAHeading() async throws {
        let long = String(repeating: "очень длинный полужирный текст, ", count: 8)
        let content = NSMutableAttributedString()
        content.append(NSAttributedString(string: "Заголовок\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 20)]))
        content.append(NSAttributedString(string: long + "\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]))
        content.append(NSAttributedString(string: "Обычный текст документа, ничем не выделенный.\n", attributes: [.font: NSFont.systemFont(ofSize: 12)]))

        let url = root.appendingPathComponent("bold.rtf")
        try content.data(from: NSRange(location: 0, length: content.length),
                         documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: url)

        let extracted = try await OfficeExtractor().extract(from: url, options: ExtractionOptions())
        XCTAssertEqual(extracted.structure.map(\.title), ["Заголовок"])
    }

    // MARK: - Tables

    /// Таблица оформляется разметкой Markdown — тем же видом, что у книги
    /// Excel и у Word: у одной и той же таблицы обязан быть один текст,
    /// в чём бы её ни сохранили.
    @MainActor
    func testATableBecomesAMarkdownTable() async throws {
        let url = try write("table.rtf", type: .rtf, withTable: true)
        let extracted = try await OfficeExtractor().extract(from: url, options: ExtractionOptions())

        XCTAssertEqual(extracted.hasTables, true)
        XCTAssertTrue(extracted.warnings.contains(.tablesFlattened))
        XCTAssertTrue(extracted.plainText.contains("| Ключ | Значение |"), extracted.plainText)
        XCTAssertTrue(extracted.plainText.contains("| --- | --- |"), "шапка обязана быть опознаваемой")
        XCTAssertTrue(extracted.plainText.contains("| альфа | 1 |"), extracted.plainText)
    }

    /// A document with no table says so — this extractor did look.
    @MainActor
    func testADocumentWithoutTablesSaysSoRatherThanStayingSilent() async throws {
        let url = try write("plain.rtf", type: .rtf)
        let extracted = try await OfficeExtractor().extract(from: url, options: ExtractionOptions())
        XCTAssertEqual(extracted.hasTables, false)
    }

    /// ~~PDF и обычный текст таблиц не искали~~ — теперь ищут все:
    /// признак ставил один Word, и фильтр «документы с таблицами» молча
    /// не видел ни PDF, ни книг, ни веб-страниц. «Не смотрели» по-прежнему
    /// нельзя записывать в метаданные как «их нет»: там, где посмотреть
    /// нечем, поле остаётся пустым.
    func testEveryExtractorEitherLooksOrLeavesTheFieldEmpty() async throws {
        let url = root.appendingPathComponent("note.txt")
        try "просто текст".write(to: url, atomically: true, encoding: .utf8)
        let extracted = try await PlainTextExtractor().extract(from: url, options: ExtractionOptions())
        XCTAssertEqual(extracted.hasTables, false, "текст посмотрели — таблиц в нём нет")
    }

    // MARK: - Failures are named, never silent

    @MainActor
    func testABrokenFileGivesAReasonInsteadOfEmptyText() async throws {
        let url = root.appendingPathComponent("broken.docx")
        try Data([0x50, 0x4B, 0x03, 0x04] + Array(repeating: UInt8(0), count: 200)).write(to: url)

        await XCTAssertThrowsErrorAsync(
            try await OfficeExtractor().extract(from: url, options: ExtractionOptions())
        ) { error in
            guard case .corrupted = error as? ExtractionError else {
                return XCTFail("ожидалась понятная причина, получено \(error)")
            }
        }
    }

    // MARK: - Registry

    func testTheRegistryRoutesOfficeFormatsToTheOfficeExtractor() throws {
        let registry = ExtractorRegistry.standard()
        for (name, expected) in [("a.docx", "office"), ("a.rtf", "office"), ("a.odt", "office"),
                                 ("a.doc", "office"), ("a.md", "plaintext"), ("a.pdf", "pdfkit")] {
            let url = root.appendingPathComponent(name)
            let stamp = SourceSyncService.stamp(of: url, registry: registry)
            XCTAssertEqual(stamp.id, expected, "\(name) достался не тому экстрактору")
        }
    }

    /// Rich text used to be claimed by the plain-text extractor, which would
    /// have indexed the markup.
    func testRichTextIsNoLongerReadAsPlainText() throws {
        let type = try XCTUnwrap(UTType(filenameExtension: "rtf"))
        XCTAssertFalse(PlainTextExtractor().canHandle(type))
        XCTAssertTrue(OfficeExtractor().canHandle(type))
    }

    // MARK: -: one file does not hold up the folder

    func testASlowExtractorHitsTheTimeoutAndNamesIt() async throws {
        struct Sleepy: DocumentTextExtractor {
            let id = "sleepy"
            let version = 1
            func canHandle(_ type: UTType) -> Bool { true }
            func extract(from url: URL, options: ExtractionOptions) async throws -> ExtractedDocument {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return ExtractedDocument(plainText: "поздно", containerFormat: "txt", extractorID: id, extractorVersion: 1)
            }
        }
        let url = root.appendingPathComponent("slow.txt")
        try "текст".write(to: url, atomically: true, encoding: .utf8)

        let registry = ExtractorRegistry(extractors: [Sleepy()])
        await XCTAssertThrowsErrorAsync(
            try await registry.extract(from: url, options: ExtractionOptions(perFileTimeout: 0.2))
        ) { error in
            XCTAssertEqual(error as? ExtractionError, .timedOut(seconds: 0.2))
        }
    }

    func testAFastExtractorIsNotAffectedByTheTimeout() async throws {
        let url = root.appendingPathComponent("fast.txt")
        try "текст на месте".write(to: url, atomically: true, encoding: .utf8)
        let extracted = try await ExtractorRegistry.standard().extract(
            from: url, options: ExtractionOptions(perFileTimeout: 5)
        )
        XCTAssertEqual(extracted.plainText, "текст на месте")
    }
}

// MARK: -: what the importer never shows (through the container of 4.5)

final class OfficeHiddenContentTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-hidden-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func container(_ name: String, _ parts: [(String, String)]) throws -> URL {
        let entries = parts.map {
            ZIPFixtureBuilder.Entry(path: $0.0, contents: Data($0.1.utf8), deflated: true)
        }
        let url = root.appendingPathComponent(name)
        try ZIPFixtureBuilder(entries: entries).build().write(to: url)
        return url
    }

    func testAWordCommentsPartIsNoticed() throws {
        let url = try container("commented.docx", [
            ("word/document.xml", "<w:document><w:body><w:p>текст</w:p></w:body></w:document>"),
            ("word/comments.xml", "<w:comments>" + String(repeating: "<w:comment>замечание</w:comment>", count: 40) + "</w:comments>"),
        ])
        XCTAssertTrue(OfficeExtractor.containsCommentsOrRevisions(at: url))
    }

    /// Some producers write the part and leave it empty. An empty part is not a
    /// comment, and warning about it would be noise.
    func testAnEmptyCommentsPartIsNotAComment() throws {
        let url = try container("empty-comments.docx", [
            ("word/document.xml", "<w:document><w:body><w:p>текст</w:p></w:body></w:document>"),
            ("word/comments.xml", "<w:comments/>"),
        ])
        XCTAssertFalse(OfficeExtractor.containsCommentsOrRevisions(at: url))
    }

    func testTrackedChangesInsideTheDocumentAreNoticed() throws {
        let url = try container("revised.docx", [
            ("word/document.xml", "<w:document><w:body><w:ins w:author=\"кто-то\"><w:r><w:t>вставка</w:t></w:r></w:ins></w:body></w:document>"),
        ])
        XCTAssertTrue(OfficeExtractor.containsCommentsOrRevisions(at: url))
    }

    func testOpenDocumentAnnotationsAreNoticed() throws {
        let url = try container("annotated.odt", [
            ("content.xml", "<office:document-content><office:body><office:annotation>замечание</office:annotation></office:body></office:document-content>"),
        ])
        XCTAssertTrue(OfficeExtractor.containsCommentsOrRevisions(at: url))
    }

    func testACleanDocumentGetsNoWarning() throws {
        let url = try container("clean.docx", [
            ("word/document.xml", "<w:document><w:body><w:p><w:r><w:t>просто текст</w:t></w:r></w:p></w:body></w:document>"),
        ])
        XCTAssertFalse(OfficeExtractor.containsCommentsOrRevisions(at: url))
    }

    /// A file that is not an archive at all — `.rtf`, `.doc` — must not turn into
    /// an error on the way to a warning nobody asked for.
    func testANonContainerIsSimplyNotInspected() throws {
        let url = root.appendingPathComponent("notes.rtf")
        try Data("{\\rtf1 текст}".utf8).write(to: url)
        XCTAssertFalse(OfficeExtractor.containsCommentsOrRevisions(at: url))
    }
}
