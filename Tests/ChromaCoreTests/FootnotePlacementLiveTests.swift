import XCTest
@testable import ChromaCore

/// Сноски на настоящих документах Word.
///
/// Замер до правки: между ссылкой на сноску и её текстом лежало в среднем
/// 46% документа — все сноски приписывались в хвост. Здесь проверяется, что
/// это перестало быть так, и что ни одна сноска при этом не потерялась.
///
///     CHROMA_IT=1 CHROMA_WORD=/путь swift test --filter FootnotePlacementLiveTests
final class FootnotePlacementLiveTests: XCTestCase {
    private var folder = URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CHROMA_IT"] == "1",
            "Живая проверка включается CHROMA_IT=1"
        )
        if let path = ProcessInfo.processInfo.environment["CHROMA_WORD"] {
            folder = URL(fileURLWithPath: path)
        }
    }

    func testFootnotesStandWithTheirParagraphs() async throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        )
        .filter { ["docx", "doc"].contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .prefix(400)

        var read = 0, withNotes = 0, placed = 0, orphaned = 0
        var positions: [Double] = []

        for url in files {
            guard let extracted = try? await OfficeExtractor().extract(
                from: url, options: ExtractionOptions()
            ) else { continue }
            read += 1
            let text = extracted.plainText
            let blocks = text.components(separatedBy: "\n\n")
            let noted = blocks.filter { $0.contains("Сноска ") }
            guard !noted.isEmpty else { continue }
            withNotes += 1

            for block in noted {
                // Блок, состоящий из одной сноски, — та, чью ссылку не нашли:
                // такая уходит в хвост, как уходили раньше все.
                if block.hasPrefix("Сноска "), !block.contains("\n") {
                    orphaned += 1
                } else {
                    placed += 1
                }
                if let range = text.range(of: block) {
                    positions.append(
                        Double(text.distance(from: text.startIndex, to: range.lowerBound))
                            / Double(max(1, text.count))
                    )
                }
            }
        }

        try XCTSkipIf(withNotes < 3, "документов со сносками найдено \(withNotes)")
        let average = positions.reduce(0, +) / Double(max(1, positions.count))
        print("""
        === \(read) документов, со сносками \(withNotes) ===
        сносок при своём абзаце: \(placed), осталось в хвосте: \(orphaned)
        среднее положение сноски в документе: \(String(format: "%.0f%%", 100 * average))
        """)

        XCTAssertGreaterThan(placed, orphaned * 4, "сноски обязаны вставать при абзацах, а не в хвосте")
        XCTAssertLessThan(average, 0.9, "если среднее у единицы — сноски по-прежнему все в конце")
    }

    /// Сноска не должна теряться: сколько их в частях документа, столько
    /// и в тексте.
    func testNoFootnoteIsLostOnTheWay() async throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension.lowercased() == "docx" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .prefix(300)

        var checked = 0
        for url in files {
            guard let reader = DocxPartsReader(url: url), let parts = reader.read(),
                  !parts.footnotes.isEmpty else { continue }
            guard let extracted = try? await OfficeExtractor().extract(
                from: url, options: ExtractionOptions()
            ) else { continue }
            checked += 1
            for (id, note) in parts.footnotes {
                XCTAssertTrue(
                    extracted.plainText.contains("Сноска \(id): \(note)"),
                    "сноска \(id) потерялась в \(url.lastPathComponent)"
                )
            }
        }
        try XCTSkipIf(checked == 0, "документов со сносками не нашлось")
        print("проверено документов со сносками: \(checked)")
    }
}
