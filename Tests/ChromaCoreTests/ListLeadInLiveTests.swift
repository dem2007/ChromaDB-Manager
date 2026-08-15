import XCTest
import PDFKit
@testable import ChromaCore

/// Вводные фразы списков на настоящих документах.
///
/// Проверяет не «работает ли механизм», а **не приписывает ли он лишнего**:
/// правило заведено узким намеренно, и его узость — то, что надо стеречь.
///
///     CHROMA_IT=1 CHROMA_PDFS=/путь swift test --filter ListLeadInLiveTests
final class ListLeadInLiveTests: XCTestCase {
    private var folder = URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CHROMA_IT"] == "1",
            "Живая проверка включается CHROMA_IT=1"
        )
        if let path = ProcessInfo.processInfo.environment["CHROMA_PDFS"] {
            folder = URL(fileURLWithPath: path)
        }
    }

    private func documents(limit: Int = 150) throws -> [String] {
        let files = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension.lowercased() == "pdf" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .prefix(limit)

        var result: [String] = []
        for url in files {
            guard let document = PDFDocument(url: url), !document.isLocked,
                  document.pageCount >= 2 else { continue }
            let pages = (0..<document.pageCount).map {
                (document.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            guard pages.count >= 2 else { continue }
            let vocabulary = PDFTextReflow.vocabulary(ofPages: pages)
            result.append(
                pages.map { PDFTextReflow.page($0, vocabulary: vocabulary) }.joined(separator: "\n\n")
            )
        }
        guard result.count >= 10 else { throw XCTSkip("нужно хотя бы десять читаемых PDF") }
        return result
    }

    /// Каждая найденная фраза кончается двоеточием, влезает в предел
    /// и стоит перед настоящими пунктами. Ни одного исключения.
    func testEveryLeadInIsAGenuineOne() throws {
        var total = 0
        var lists = 0
        for text in try documents() {
            let leadIns = ListLeadIns.leadIns(in: text)
            lists += leadIns.count
            for leadIn in leadIns {
                total += 1
                XCTAssertTrue(leadIn.text.hasSuffix(":"), "«\(leadIn.text)» не кончается двоеточием")
                XCTAssertLessThanOrEqual(leadIn.text.count, ListLeadIns.maximumLength)
                XCTAssertFalse(leadIn.range.isEmpty, "участок списка пуст")

                // Участок начинается пунктом — иначе фраза приписана не списку.
                let start = text.index(text.startIndex, offsetBy: min(leadIn.range.lowerBound, text.count))
                let head = String(text[start...].prefix(40))
                XCTAssertTrue(
                    ListLeadIns.isListItem(head.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "участок «\(head)» начинается не с пункта"
                )
            }
        }
        print("вводных фраз найдено: \(total) в \(lists) списках")
        XCTAssertGreaterThan(total, 0, "на полутора сотнях документов список с вводной фразой обязан найтись")
    }

    /// Нумерованные пункты постановлений не усыновляют друг друга — то самое
    /// ограничение, ради которого правило сделано узким.
    func testNumberedClausesNeverAdoptEachOther() throws {
        for text in try documents() {
            for leadIn in ListLeadIns.leadIns(in: text) {
                XCTAssertFalse(
                    ListLeadIns.isListItem(leadIn.text),
                    "пункт «\(leadIn.text)» объявлен вводной фразой для соседних пунктов"
                )
            }
        }
    }

    /// Сколько чанков это на деле трогает — число для отчёта, а не порог.
    func testHowManyChunksGainALeadIn() throws {
        let configuration = ChunkingConfiguration()
        var adaptiveTotal = 0, adaptiveGained = 0
        var recursiveTotal = 0, recursiveGained = 0

        for text in try documents() {
            let document = ExtractedDocument(
                plainText: text, containerFormat: "pdf", extractorID: "test", extractorVersion: 1
            )
            for (name, chunks) in [
                ("adaptive", AdaptiveChunker(configuration: configuration).chunks(from: text)),
                ("recursive", RecursiveChunker(
                    size: configuration.chunkSizeInCharacters,
                    overlap: configuration.overlapInCharacters,
                    separators: configuration.separators
                ).chunks(from: text)),
            ] {
                let placements = ChunkLocator.placements(of: chunks, in: document)
                let gained = placements.values.filter { $0.listLeadIn != nil }.count
                if name == "adaptive" {
                    adaptiveTotal += chunks.count; adaptiveGained += gained
                } else {
                    recursiveTotal += chunks.count; recursiveGained += gained
                }
            }
        }

        print("""
        чанков получили вводную фразу:
          adaptive:  \(adaptiveGained) из \(adaptiveTotal) \
        (\(String(format: "%.1f%%", 100 * Double(adaptiveGained) / Double(max(1, adaptiveTotal)))))
          recursive: \(recursiveGained) из \(recursiveTotal) \
        (\(String(format: "%.1f%%", 100 * Double(recursiveGained) / Double(max(1, recursiveTotal)))))
        """)
    }
}
