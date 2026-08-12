import XCTest
import Compression
@testable import ChromaCore

/// Builds ZIP archives for the tests, byte by byte.
///
/// 5 asks for fixtures assembled by a script rather than committed, and a
/// writer is the only way to produce the cases that matter: an entry whose local
/// header lies about its size, a name that is not ASCII, a method nobody
/// supports. None of this is product code — the app only ever reads.
struct ZIPFixtureBuilder {
    struct Entry {
        var path: String
        var contents: Data
        var deflated: Bool = false
        /// Written as if by a streaming writer: zeroes in the local header, the
        /// real sizes only in the central directory (the main trap).
        var dataDescriptor: Bool = false
        var utf8Flag: Bool = true
        /// Overrides the method written into the headers, to forge an archive
        /// this reader must refuse.
        var methodOverride: UInt16?
    }

    var entries: [Entry] = []

    func build() -> Data {
        var output = Data()
        var directory = Data()
        var count = 0

        for entry in entries {
            let name = Data(entry.path.utf8)
            let payload = entry.deflated ? Self.deflate(entry.contents) : entry.contents
            let method = entry.methodOverride ?? (entry.deflated ? 8 : 0)
            let flags: UInt16 = (entry.utf8Flag ? 0x800 : 0) | (entry.dataDescriptor ? 0x08 : 0)
            let offset = UInt32(output.count)

            var local = Data()
            local.append(uint32: 0x0403_4b50)
            local.append(uint16: 20)
            local.append(uint16: flags)
            local.append(uint16: method)
            local.append(uint16: 0)                       // time
            local.append(uint16: 0)                       // date
            local.append(uint32: entry.dataDescriptor ? 0 : Self.crc32(entry.contents))
            local.append(uint32: entry.dataDescriptor ? 0 : UInt32(payload.count))
            local.append(uint32: entry.dataDescriptor ? 0 : UInt32(entry.contents.count))
            local.append(uint16: UInt16(name.count))
            local.append(uint16: 0)                       // extra length
            local.append(name)
            output.append(local)
            output.append(payload)
            if entry.dataDescriptor {
                output.append(uint32: 0x0807_4b50)
                output.append(uint32: Self.crc32(entry.contents))
                output.append(uint32: UInt32(payload.count))
                output.append(uint32: UInt32(entry.contents.count))
            }

            directory.append(uint32: 0x0201_4b50)
            directory.append(uint16: 20)                  // version made by
            directory.append(uint16: 20)                  // version needed
            directory.append(uint16: flags)
            directory.append(uint16: method)
            directory.append(uint16: 0)
            directory.append(uint16: 0)
            directory.append(uint32: Self.crc32(entry.contents))
            directory.append(uint32: UInt32(payload.count))
            directory.append(uint32: UInt32(entry.contents.count))
            directory.append(uint16: UInt16(name.count))
            directory.append(uint16: 0)                   // extra
            directory.append(uint16: 0)                   // comment
            directory.append(uint16: 0)                   // disk
            directory.append(uint16: 0)                   // internal attrs
            directory.append(uint32: 0)                   // external attrs
            directory.append(uint32: offset)
            directory.append(name)
            count += 1
        }

        let directoryOffset = UInt32(output.count)
        output.append(directory)
        output.append(uint32: 0x0605_4b50)
        output.append(uint16: 0)
        output.append(uint16: 0)
        output.append(uint16: UInt16(count))
        output.append(uint16: UInt16(count))
        output.append(uint32: UInt32(directory.count))
        output.append(uint32: directoryOffset)
        output.append(uint16: 0)                          // comment length
        return output
    }

    /// Raw deflate, the same framework call the reader inflates with.
    static func deflate(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        var destination = Data(count: data.count * 2 + 128)
        let written = destination.withUnsafeMutableBytes { output -> Int in
            guard let outputBase = output.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return data.withUnsafeBytes { input -> Int in
                guard let inputBase = input.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(outputBase, output.count, inputBase, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return destination.prefix(written)
    }

    /// The reader does not check CRCs, but writing a real one keeps the fixture
    /// a genuine archive rather than something only this reader would accept.
    static func crc32(_ data: Data) -> UInt32 {
        var table: [UInt32] = (0..<256).map { index in
            var value = UInt32(index)
            for _ in 0..<8 { value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1 }
            return value
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)] }
        table.removeAll()
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    mutating func append(uint32 value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
        ])
    }
}

// MARK: - Tests

final class ZIPContainerReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func archive(_ name: String, _ entries: [ZIPFixtureBuilder.Entry], truncateTo: Int? = nil) throws -> URL {
        var data = ZIPFixtureBuilder(entries: entries).build()
        if let truncateTo { data = data.prefix(truncateTo) }
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func entry(_ path: String, _ text: String, deflated: Bool = false, dataDescriptor: Bool = false) -> ZIPFixtureBuilder.Entry {
        ZIPFixtureBuilder.Entry(path: path, contents: Data(text.utf8), deflated: deflated, dataDescriptor: dataDescriptor)
    }

    // MARK: Both storage methods

    func testStoredAndDeflatedEntriesBothComeBack() throws {
        let long = String(repeating: "Текст, который прекрасно сжимается. ", count: 50)
        let url = try archive("both.zip", [
            entry("mimetype", "application/epub+zip"),
            entry("OEBPS/chapter.xhtml", long, deflated: true),
        ])
        let reader = try ZIPContainerReader(url: url)

        XCTAssertEqual(reader.entries.map(\.path), ["mimetype", "OEBPS/chapter.xhtml"])
        XCTAssertEqual(String(data: try reader.read("mimetype"), encoding: .utf8), "application/epub+zip")
        XCTAssertEqual(String(data: try reader.read("OEBPS/chapter.xhtml"), encoding: .utf8), long)
        // The deflated entry really was compressed, not stored under a label.
        let chapter = try XCTUnwrap(reader.entry(at: "OEBPS/chapter.xhtml"))
        XCTAssertTrue(chapter.isDeflated)
        XCTAssertLessThan(chapter.compressedSize, chapter.uncompressedSize)
    }

    /// The trap spends a paragraph on: a streaming writer leaves zeroes in
    /// the local header and the real sizes in the central directory. A reader
    /// that believes the local header returns empty chapters.
    func testAnEntryWrittenWithADataDescriptorIsReadFromTheDirectory() throws {
        let text = String(repeating: "Глава, записанная потоково. ", count: 40)
        let url = try archive("descriptor.zip", [
            entry("OEBPS/one.xhtml", text, deflated: true, dataDescriptor: true),
            entry("OEBPS/two.xhtml", "Вторая глава, чтобы смещения не совпали случайно."),
        ])
        let reader = try ZIPContainerReader(url: url)

        XCTAssertEqual(String(data: try reader.read("OEBPS/one.xhtml"), encoding: .utf8), text)
        XCTAssertEqual(String(data: try reader.read("OEBPS/two.xhtml"), encoding: .utf8),
                       "Вторая глава, чтобы смещения не совпали случайно.")
    }

    func testANonASCIINameIsReadable() throws {
        let url = try archive("names.zip", [entry("OEBPS/Глава 1.xhtml", "текст")])
        let reader = try ZIPContainerReader(url: url)
        XCTAssertEqual(reader.entries.map(\.path), ["OEBPS/Глава 1.xhtml"])
        XCTAssertEqual(String(data: try reader.read("OEBPS/Глава 1.xhtml"), encoding: .utf8), "текст")
    }

    func testAnEmptyEntryIsEmptyAndNotAnError() throws {
        let url = try archive("empty.zip", [entry("OEBPS/blank.xhtml", "")])
        let reader = try ZIPContainerReader(url: url)
        XCTAssertEqual(try reader.read("OEBPS/blank.xhtml"), Data())
    }

    func testADirectoryEntryIsMarkedAsOne() throws {
        let url = try archive("dirs.zip", [entry("OEBPS/", ""), entry("OEBPS/a.xhtml", "текст")])
        let reader = try ZIPContainerReader(url: url)
        XCTAssertEqual(reader.entry(at: "OEBPS/")?.isDirectory, true)
        XCTAssertEqual(reader.entry(at: "OEBPS/a.xhtml")?.isDirectory, false)
    }

    // MARK: Refusals

    func testATruncatedArchiveIsAnErrorNotACrash() throws {
        let full = ZIPFixtureBuilder(entries: [entry("a.txt", "текст")]).build()
        let url = try archive("cut.zip", [entry("a.txt", "текст")], truncateTo: full.count / 2)
        XCTAssertThrowsError(try ZIPContainerReader(url: url)) { error in
            XCTAssertTrue(
                [.notAnArchive, .truncated].contains(error as? ZIPError),
                "ожидался типизированный отказ, получено \(error)"
            )
        }
    }

    func testAFileThatIsNotAnArchiveIsRefused() throws {
        let url = root.appendingPathComponent("note.txt")
        try Data("это просто текст, а не архив".utf8).write(to: url)
        XCTAssertThrowsError(try ZIPContainerReader(url: url)) { error in
            XCTAssertEqual(error as? ZIPError, .notAnArchive)
        }
    }

    func testAnUnsupportedCompressionMethodIsNamed() throws {
        var bomb = ZIPFixtureBuilder.Entry(path: "a.txt", contents: Data("текст".utf8))
        bomb.methodOverride = 12   // bzip2 — legal in ZIP, not supported here
        let url = try archive("method.zip", [bomb])
        let reader = try ZIPContainerReader(url: url)
        XCTAssertThrowsError(try reader.read("a.txt")) { error in
            XCTAssertEqual(error as? ZIPError, .unsupportedMethod(12))
        }
    }

    func testAMissingEntryIsNamed() throws {
        let url = try archive("small.zip", [entry("a.txt", "текст")])
        let reader = try ZIPContainerReader(url: url)
        XCTAssertThrowsError(try reader.read("META-INF/container.xml")) { error in
            XCTAssertEqual(error as? ZIPError, .entryNotFound("META-INF/container.xml"))
        }
    }

    /// Zip-slip. The path never reaches the disk here, but it is matched against
    /// references from the OPF, so a `../` that survived would point outside the
    /// book.
    func testPathsAreNormalisedAndEscapesRefused() throws {
        XCTAssertEqual(try ZIPContainerReader.normalise("OEBPS/./text/../chapter.xhtml"), "OEBPS/chapter.xhtml")
        XCTAssertEqual(try ZIPContainerReader.normalise("OEBPS/sub/../../book.opf"), "book.opf")
        XCTAssertThrowsError(try ZIPContainerReader.normalise("../../etc/passwd"))
        XCTAssertThrowsError(try ZIPContainerReader.normalise("/etc/passwd"))
        XCTAssertThrowsError(try ZIPContainerReader.normalise("OEBPS/../../secret"))
    }

    func testAnArchiveWithAnEscapingPathIsRefusedAtOpen() throws {
        let url = try archive("slip.zip", [entry("../../etc/passwd", "уходим за корень")])
        XCTAssertThrowsError(try ZIPContainerReader(url: url)) { error in
            guard case .pathEscapesRoot = error as? ZIPError else {
                return XCTFail("ожидался отказ по пути, получено \(error)")
            }
        }
    }

    // MARK: Zip bombs

    func testAnEntryOverTheLimitIsRefusedInsteadOfBeingRead() throws {
        let url = try archive("big.zip", [entry("a.txt", String(repeating: "а", count: 5_000))])
        let reader = try ZIPContainerReader(url: url, limits: .init(maxEntrySize: 100, maxTotalSize: 1 << 30))
        XCTAssertThrowsError(try reader.read("a.txt")) { error in
            guard case .entryTooLarge = error as? ZIPError else {
                return XCTFail("ожидался отказ по размеру записи, получено \(error)")
            }
        }
    }

    func testAnArchiveOverTheTotalLimitIsRefusedAtOpen() throws {
        let url = try archive("total.zip", [
            entry("a.txt", String(repeating: "а", count: 2_000)),
            entry("b.txt", String(repeating: "б", count: 2_000)),
        ])
        XCTAssertThrowsError(try ZIPContainerReader(url: url, limits: .init(maxEntrySize: 1 << 20, maxTotalSize: 1_000))) { error in
            guard case .archiveTooLarge = error as? ZIPError else {
                return XCTFail("ожидался отказ по суммарному размеру, получено \(error)")
            }
        }
    }

    // MARK: ZIP64

    /// Recognised and refused with a reason, as asks — not half-read.
    func testAZIP64ArchiveIsRecognisedAndRefused() throws {
        var data = ZIPFixtureBuilder(entries: [entry("a.txt", "текст")]).build()
        // The classic EOCD of a ZIP64 archive carries 0xFFFF/0xFFFFFFFF markers.
        let eocd = data.count - 22
        data.replaceSubrange((eocd + 16)..<(eocd + 20), with: [0xFF, 0xFF, 0xFF, 0xFF])
        let url = root.appendingPathComponent("zip64.zip")
        try data.write(to: url)

        XCTAssertThrowsError(try ZIPContainerReader(url: url)) { error in
            XCTAssertEqual(error as? ZIPError, .zip64Unsupported)
        }
    }

    // MARK: The comment trap

    /// The EOCD is looked for from the end, because a comment after it can
    /// contain anything — including bytes that look like a signature.
    func testACommentContainingASignatureDoesNotConfuseTheReader() throws {
        var data = ZIPFixtureBuilder(entries: [entry("a.txt", "текст")]).build()
        let comment = Data([0x50, 0x4B, 0x05, 0x06]) + Data(repeating: 0, count: 30)
        data.replaceSubrange((data.count - 2)..<data.count, with: [UInt8(comment.count & 0xFF), UInt8(comment.count >> 8)])
        data.append(comment)
        let url = root.appendingPathComponent("comment.zip")
        try data.write(to: url)

        let reader = try ZIPContainerReader(url: url)
        XCTAssertEqual(String(data: try reader.read("a.txt"), encoding: .utf8), "текст")
    }

    // MARK: Nothing is held in memory that was not asked for

    func testOnlyTheRequestedEntryIsRead() throws {
        let big = String(repeating: "много текста ", count: 5_000)
        let url = try archive("selective.zip", [
            entry("small.txt", "мало"),
            entry("big.txt", big, deflated: true),
        ])
        let reader = try ZIPContainerReader(url: url)
        // Opening parsed the directory only; the payload is read on demand.
        XCTAssertEqual(reader.entries.count, 2)
        XCTAssertEqual(String(data: try reader.read("small.txt"), encoding: .utf8), "мало")
    }
}
