import XCTest
import UniformTypeIdentifiers
@testable import ChromaCore

/// Books are assembled here, entry by entry, with the ZIP writer of the
/// 4.5 tests — forbids putting someone else's book in the repository, and
/// the cases that matter (spine out of alphabetical order, DRM, EPUB 2 vs 3) are
/// not things a real book would helpfully provide anyway.
final class EPUBExtractionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-epub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Building books

    private func chapter(_ title: String, _ body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(title)</title></head>
        <body><h1>\(title)</h1><p>\(body)</p></body></html>
        """
    }

    private let container = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
    <rootfiles><rootfile full-path="OEBPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles>
    </container>
    """

    /// EPUB 3, with a `nav.xhtml`. The spine is deliberately **not** in
    /// alphabetical order of the file names.
    private func epub3(_ name: String, extraEntries: [(String, String)] = []) throws -> URL {
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>Книга для проверки</dc:title><dc:creator>Автор Проверкин</dc:creator>
        <dc:language>ru</dc:language><dc:identifier id="bookid">urn:uuid:cdbm-test</dc:identifier>
        </metadata>
        <manifest>
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="zeta" href="zeta.xhtml" media-type="application/xhtml+xml"/>
        <item id="alpha" href="alpha.xhtml" media-type="application/xhtml+xml"/>
        <item id="mu" href="mu.xhtml" media-type="application/xhtml+xml"/>
        </manifest>
        <spine><itemref idref="zeta"/><itemref idref="alpha"/><itemref idref="mu"/></spine>
        </package>
        """
        let nav = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
        <nav epub:type="toc"><ol>
        <li><a href="zeta.xhtml">Глава первая</a><ol><li><a href="zeta.xhtml#s1">Подраздел первой</a></li></ol></li>
        <li><a href="alpha.xhtml">Глава вторая</a></li>
        <li><a href="mu.xhtml">Глава третья</a></li>
        </ol></nav></body></html>
        """
        var entries: [(String, String)] = [
            ("META-INF/container.xml", container),
            ("OEBPS/book.opf", opf),
            ("OEBPS/nav.xhtml", nav),
            ("OEBPS/zeta.xhtml", chapter("Глава первая", "Первая по порядку чтения, но последняя по алфавиту.")),
            ("OEBPS/alpha.xhtml", chapter("Глава вторая", "Вторая по порядку чтения, но первая по алфавиту.")),
            ("OEBPS/mu.xhtml", chapter("Глава третья", "Третья и по чтению, и по алфавиту где-то посередине.")),
        ]
        entries += extraEntries
        return try write(name, entries)
    }

    /// EPUB 2, with `toc.ncx` and no nav document.
    private func epub2(_ name: String) throws -> URL {
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Старая книга</dc:title></metadata>
        <manifest>
        <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
        <item id="zeta" href="zeta.xhtml" media-type="application/xhtml+xml"/>
        <item id="alpha" href="alpha.xhtml" media-type="application/xhtml+xml"/>
        </manifest>
        <spine toc="ncx"><itemref idref="zeta"/><itemref idref="alpha"/></spine>
        </package>
        """
        let ncx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>
        <navPoint id="n1" playOrder="1"><navLabel><text>Первая глава</text></navLabel><content src="zeta.xhtml"/>
        <navPoint id="n1a" playOrder="2"><navLabel><text>Её подраздел</text></navLabel><content src="zeta.xhtml#s1"/></navPoint>
        </navPoint>
        <navPoint id="n2" playOrder="3"><navLabel><text>Вторая глава</text></navLabel><content src="alpha.xhtml"/></navPoint>
        </navMap></ncx>
        """
        return try write(name, [
            ("META-INF/container.xml", container),
            ("OEBPS/book.opf", opf),
            ("OEBPS/toc.ncx", ncx),
            ("OEBPS/zeta.xhtml", chapter("Первая глава", "Текст первой главы старой книги.")),
            ("OEBPS/alpha.xhtml", chapter("Вторая глава", "Текст второй главы старой книги.")),
        ])
    }

    private func write(_ name: String, _ parts: [(String, String)]) throws -> URL {
        let entries = parts.map {
            ZIPFixtureBuilder.Entry(path: $0.0, contents: Data($0.1.utf8), deflated: $0.0 != "mimetype")
        }
        let url = root.appendingPathComponent(name)
        try ZIPFixtureBuilder(entries: entries).build().write(to: url)
        return url
    }

    // MARK: - The mandatory test: spine order

    /// 12 asks for this one by name: a book whose alphabetical order does
    /// not match its spine must come out in spine order.
    @MainActor
    func testChaptersFollowTheSpineAndNotTheAlphabet() async throws {
        let url = try epub3("order.epub")
        let extracted = try await EPUBExtractor().extract(from: url, options: ExtractionOptions())

        let first = try XCTUnwrap(extracted.plainText.range(of: "Первая по порядку чтения"))
        let second = try XCTUnwrap(extracted.plainText.range(of: "Вторая по порядку чтения"))
        let third = try XCTUnwrap(extracted.plainText.range(of: "Третья и по чтению"))
        XCTAssertLessThan(first.lowerBound, second.lowerBound, "книга собрана не по spine")
        XCTAssertLessThan(second.lowerBound, third.lowerBound)

        // And the parts carry the spine order, not the archive's.
        XCTAssertEqual(extracted.parts.map(\.id), ["zeta", "alpha", "mu"])
        XCTAssertEqual(extracted.parts.map(\.index), [0, 1, 2])
    }

    // MARK: - Both table-of-contents formats

    @MainActor
    func testEPUB3ReadsTheNavigationDocument() async throws {
        let url = try epub3("nav.epub")
        let extracted = try await EPUBExtractor().extract(from: url, options: ExtractionOptions())

        XCTAssertEqual(extracted.structureSource, .outline)
        XCTAssertTrue(extracted.structure.map(\.title).contains("Глава первая"))
        XCTAssertTrue(extracted.structure.map(\.title).contains("Глава третья"))
        XCTAssertFalse(extracted.warnings.contains(.noStructure))
    }

    @MainActor
    func testEPUB2ReadsTheNCX() async throws {
        let url = try epub2("ncx.epub")
        let extracted = try await EPUBExtractor().extract(from: url, options: ExtractionOptions())

        XCTAssertEqual(extracted.structureSource, .outline)
        XCTAssertEqual(
            extracted.structure.filter { $0.level == 1 }.map(\.title),
            ["Первая глава", "Вторая глава"]
        )
        // The nested navPoint became a deeper level, not a sibling.
        XCTAssertTrue(extracted.structure.contains { $0.title == "Её подраздел" && $0.level == 2 })
    }

    /// The structure is what the chunkers cut along — that is the point of the
    /// whole stage.
    @MainActor
    func testTheHeadingPathNamesTheChapter() async throws {
        let url = try epub3("path.epub")
        let extracted = try await EPUBExtractor().extract(from: url, options: ExtractionOptions())

        let third = try XCTUnwrap(extracted.parts.last)
        XCTAssertEqual(extracted.headingPath(forCharacter: third.start), "Глава третья")
    }

    // MARK: - Parts

    @MainActor
    func testEveryChapterIsFoundByOffset() async throws {
        let url = try epub3("parts.epub")
        let extracted = try await EPUBExtractor().extract(from: url, options: ExtractionOptions())

        for part in extracted.parts {
            XCTAssertEqual(extracted.part(forCharacter: part.start)?.id, part.id)
            XCTAssertEqual(extracted.part(forCharacter: part.start)?.kind, .spine)
        }
        // Text before the first chapter cannot exist — the first part starts at 0.
        XCTAssertEqual(extracted.parts.first?.start, 0)
    }

    @MainActor
    func testChunkMetadataCarriesTheChapter() async throws {
        let url = try epub3("chunks.epub")
        let extracted = try await EPUBExtractor().extract(from: url, options: ExtractionOptions())
        let chunks = try await ChunkingPipeline(
            configuration: ChunkingConfiguration(strategy: .documentBased, sizeUnit: .characters, maxSectionSize: 4000)
        ).chunks(from: extracted.plainText, fileExtension: "epub", structure: extracted.structure)

        let placements = ChunkLocator.placements(of: chunks, in: extracted)
        XCTAssertFalse(placements.isEmpty)
        let spineIndices = Set(placements.values.compactMap { $0.part?.index })
        XCTAssertEqual(spineIndices, [0, 1, 2], "каждая глава должна быть представлена")
        XCTAssertEqual(placements[0]?.part?.id, "zeta")
    }

    // MARK: - Metadata

    @MainActor
    func testBookMetadataIsOptional() async throws {
        let url = try epub3("meta.epub")
        let without = try await EPUBExtractor().extract(from: url, options: ExtractionOptions())
        XCTAssertTrue(without.documentMetadata.isEmpty)

        let with = try await EPUBExtractor().extract(
            from: url, options: ExtractionOptions(includeDocumentMetadata: true)
        )
        XCTAssertEqual(with.documentMetadata["document_title"], "Книга для проверки")
        XCTAssertEqual(with.documentMetadata["document_author"], "Автор Проверкин")
        XCTAssertEqual(with.documentMetadata["document_language"], "ru")
    }

    // MARK: - DRM

    /// a protected book is not a broken one, and the reason must say so.
    @MainActor
    func testADRMProtectedBookIsNamedNotCalledCorrupted() async throws {
        let url = try epub3("drm.epub", extraEntries: [
            ("META-INF/encryption.xml", "<encryption xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"/>"),
        ])
        await XCTAssertThrowsErrorAsync(
            try await EPUBExtractor().extract(from: url, options: ExtractionOptions())
        ) { error in
            XCTAssertEqual(error as? ExtractionError, .drmProtected)
        }
    }

    @MainActor
    func testARightsFileAlsoCountsAsDRM() async throws {
        let url = try epub3("rights.epub", extraEntries: [("META-INF/rights.xml", "<rights/>")])
        await XCTAssertThrowsErrorAsync(
            try await EPUBExtractor().extract(from: url, options: ExtractionOptions())
        ) { error in
            XCTAssertEqual(error as? ExtractionError, .drmProtected)
        }
    }

    /// And the fallback chain must not turn DRM into something vaguer — only a
    /// missing text layer chains onward (4.1).
    @MainActor
    func testTheRegistryKeepsTheDRMReason() async throws {
        let url = try epub3("drm-registry.epub", extraEntries: [("META-INF/encryption.xml", "<encryption/>")])
        await XCTAssertThrowsErrorAsync(
            try await ExtractorRegistry.standard().extract(from: url, options: ExtractionOptions())
        ) { error in
            XCTAssertEqual(error as? ExtractionError, .drmProtected)
        }
    }

    // MARK: - Broken books

    @MainActor
    func testABookWithoutAContainerSaysWhatIsMissing() async throws {
        let url = try write("nocontainer.epub", [("OEBPS/book.opf", "<package/>")])
        await XCTAssertThrowsErrorAsync(
            try await EPUBExtractor().extract(from: url, options: ExtractionOptions())
        ) { error in
            guard case .corrupted(let detail) = error as? ExtractionError else {
                return XCTFail("ожидалась причина, получено \(error)")
            }
            XCTAssertTrue(detail.contains("container.xml"), detail)
        }
    }

    @MainActor
    func testABookWithAnEmptySpineIsRefusedWithAReason() async throws {
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
        <metadata/><manifest/><spine/></package>
        """
        let url = try write("empty.epub", [("META-INF/container.xml", container), ("OEBPS/book.opf", opf)])
        await XCTAssertThrowsErrorAsync(
            try await EPUBExtractor().extract(from: url, options: ExtractionOptions())
        ) { error in
            guard case .corrupted = error as? ExtractionError else {
                return XCTFail("ожидалась причина, получено \(error)")
            }
        }
    }

    // MARK: - Routing

    func testTheRegistryRoutesEPUBToItsOwnExtractor() throws {
        let url = root.appendingPathComponent("book.epub")
        XCTAssertEqual(SourceSyncService.stamp(of: url, registry: .standard()).id, "epub")
    }
}
