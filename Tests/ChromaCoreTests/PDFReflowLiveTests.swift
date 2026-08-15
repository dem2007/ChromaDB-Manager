import XCTest
import PDFKit
@testable import ChromaCore

/// Сшивка строк PDF на настоящих файлах, а не на выдуманных.
///
/// Проверяет то, ради чего всё затевалось: **где проходит граница чанка**.
/// До сшивки разделитель `\n` срабатывал раньше `. `, и граница всегда падала
/// на конец визуальной строки — то есть на середину предложения.
///
///     CHROMA_IT=1 CHROMA_PDFS=/путь/к/папке swift test --filter PDFReflowLiveTests
final class PDFReflowLiveTests: XCTestCase {
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

    private func samplePDFs(limit: Int = 120) throws -> [URL] {
        let files = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension.lowercased() == "pdf" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .prefix(limit)
        guard !files.isEmpty else { throw XCTSkip("PDF в \(folder.path) не найдены") }
        return Array(files)
    }

    private func pages(of url: URL) -> [String]? {
        guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0
        else { return nil }
        let texts = (0..<document.pageCount).map {
            (document.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return texts.count >= 2 ? texts : nil
    }

    private func endsAtSentence(_ chunk: String) -> Bool {
        guard let last = chunk.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return ".!?…»".contains(last)
    }

    /// Главный замер: доля чанков, кончающихся на границе предложения.
    func testChunkBoundariesLandOnSentencesMoreOften() throws {
        let chunker = RecursiveChunker(size: 1200, overlap: 150, separators: ["\n\n", "\n", ". ", " "])
        var beforeTotal = 0, beforeGood = 0
        var afterTotal = 0, afterGood = 0
        var files = 0

        for url in try samplePDFs() {
            guard let texts = pages(of: url) else { continue }
            files += 1
            let vocabulary = PDFTextReflow.vocabulary(ofPages: texts)

            let before = chunker.chunks(from: texts.joined(separator: "\n\n")).map(\.text)
            let after = chunker.chunks(
                from: texts.map { PDFTextReflow.page($0, vocabulary: vocabulary) }
                    .joined(separator: "\n\n")
            ).map(\.text)

            beforeTotal += before.count; beforeGood += before.filter(endsAtSentence).count
            afterTotal += after.count; afterGood += after.filter(endsAtSentence).count
        }

        try XCTSkipIf(files < 10, "нужно хотя бы десять читаемых PDF, найдено \(files)")
        let beforeShare = Double(beforeGood) / Double(max(1, beforeTotal))
        let afterShare = Double(afterGood) / Double(max(1, afterTotal))
        print("""
        === \(files) файлов ===
        границ на предложении: было \(String(format: "%.1f%%", 100 * beforeShare)) \
        → стало \(String(format: "%.1f%%", 100 * afterShare))
        чанков: было \(beforeTotal) → стало \(afterTotal)
        """)

        XCTAssertGreaterThan(
            afterShare, beforeShare * 1.5,
            "сшивка обязана заметно улучшить границы, а не сдвинуть их на процент"
        )
    }

    /// Ни один знак не потерян: сшивка трогает пробелы, переводы строк
    /// и дефисы переноса — и больше ничего.
    func testReflowLosesNoLetters() throws {
        var checked = 0
        for url in try samplePDFs(limit: 60) {
            guard let texts = pages(of: url) else { continue }
            let vocabulary = PDFTextReflow.vocabulary(ofPages: texts)
            for page in texts {
                let reflowed = PDFTextReflow.page(page, vocabulary: vocabulary)
                let source = page.filter { $0.isLetter || $0.isNumber }
                let result = reflowed.filter { $0.isLetter || $0.isNumber }
                XCTAssertEqual(
                    String(source), String(result),
                    "сшивка потеряла или переставила знаки в \(url.lastPathComponent)"
                )
                checked += 1
            }
        }
        try XCTSkipIf(checked == 0, "читаемых страниц не нашлось")
        print("проверено страниц: \(checked)")
    }

    /// Сборка текста не должна расти квадратично от числа страниц: на
    /// 451-страничном файле пересчёт `text.count` стоил 1.52 с против 0.007 с
    /// со счётчиком.
    func testALongDocumentIsExtractedQuickly() async throws {
        let candidates = try samplePDFs(limit: 400)
        var biggest: (url: URL, pages: Int)?
        for url in candidates {
            guard let document = PDFDocument(url: url), !document.isLocked else { continue }
            if document.pageCount > (biggest?.pages ?? 0) {
                biggest = (url, document.pageCount)
            }
        }
        guard let biggest, biggest.pages >= 100 else {
            throw XCTSkip("файла хотя бы на сто страниц не нашлось")
        }

        let started = Date()
        _ = try await PDFExtractor().extract(from: biggest.url, options: ExtractionOptions())
        let elapsed = Date().timeIntervalSince(started)
        print("\(biggest.url.lastPathComponent): \(biggest.pages) стр за \(String(format: "%.2f", elapsed)) с")
        XCTAssertLessThan(elapsed, 20, "извлечение \(biggest.pages) страниц не должно тянуться")
    }
}
