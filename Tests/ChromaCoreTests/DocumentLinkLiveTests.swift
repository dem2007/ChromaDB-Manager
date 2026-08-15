import XCTest
import PDFKit
@testable import ChromaCore

/// Адреса ссылок на настоящих документах.
///
/// Главное, что здесь проверяется, — **точность привязки**: место ссылки
/// в PDF известно в исходном тексте страницы, а в документ уходит сшитый
///, и перевод между ними считается по счёту букв. Если он врёт,
/// адрес достанется чужому чанку, и заметить это по одному лишь наличию
/// метаданного нельзя.
///
///     CHROMA_IT=1 CHROMA_PDFS=/путь swift test --filter DocumentLinkLiveTests
final class DocumentLinkLiveTests: XCTestCase {
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

    private func pdfs(limit: Int = 400) throws -> [URL] {
        let files = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension.lowercased() == "pdf" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .prefix(limit)
        guard !files.isEmpty else { throw XCTSkip("PDF не найдены") }
        return Array(files)
    }

    /// Адрес обязан стоять там, где на странице стоит его подпись.
    ///
    /// Проверка независимая: подпись ссылки берётся у самой аннотации
    /// (`page.selection(for:)`), а место — из готового `ExtractedDocument`.
    /// Если перевод смещений врёт, подписи рядом с адресом не окажется.
    func testALinkLandsWhereItsAnchorTextIs() async throws {
        var checked = 0
        var accurate = 0
        var files = 0

        for url in try pdfs() {
            guard let document = PDFDocument(url: url), !document.isLocked else { continue }
            var anchors: [(url: String, text: String)] = []
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                for annotation in page.annotations {
                    guard let action = annotation.action as? PDFActionURL,
                          let target = action.url,
                          let anchor = page.selection(for: annotation.bounds)?.string,
                          anchor.trimmingCharacters(in: .whitespacesAndNewlines).count >= 6
                    else { continue }
                    anchors.append((target.absoluteString, anchor))
                }
            }
            guard !anchors.isEmpty else { continue }
            guard let extracted = try? await PDFExtractor().extract(
                from: url, options: ExtractionOptions()
            ) else { continue }
            files += 1

            // Знаки массивом: `String.index(offsetBy:)` — это обход строки,
            // и в двойном цикле по подписям и адресам он делает проверку
            // квадратичной. На настоящем корпусе она от этого не кончалась.
            let characters = Array(extracted.plainText)
            // По адресу, а не по первой ссылке с этим адресом: один и тот же
            // адрес стоит в документе десятки раз, и сравнивать подпись
            // с первым его вхождением значит проверять не то.
            let byURL = Dictionary(grouping: extracted.links, by: \.url)

            for anchor in anchors {
                guard let candidates = byURL[anchor.url] else { continue }
                checked += 1
                let needle = anchor.text
                    .components(separatedBy: .whitespacesAndNewlines)
                    .first { $0.count >= 5 }
                guard let needle else { continue }

                // Подпись обязана найтись рядом хотя бы с одним местом этого
                // адреса. Окно с запасом назад: прямоугольник ссылки шире
                // подписи и задевает хвост предыдущего знака, поэтому
                // найденный знак бывает на десяток раньше самой подписи.
                let found = candidates.contains { link in
                    let from = max(0, link.start - 60)
                    let to = min(characters.count, link.start + 300)
                    guard from < to else { return false }
                    return String(characters[from..<to]).contains(needle)
                }
                if found { accurate += 1 }
            }
        }

        try XCTSkipIf(checked < 20, "ссылок с подписью нашлось \(checked) — мало для вывода")
        let share = Double(accurate) / Double(checked)
        print("""
        === \(files) файлов со ссылками ===
        проверено привязок: \(checked), подпись рядом с адресом: \(accurate) \
        (\(String(format: "%.0f%%", 100 * share)))
        """)
        // Замер на корпусе пользователя: 97%. Порог ниже с запасом на файлы,
        // где подпись ссылки — картинка или где текстовый слой сам по себе
        // не в порядке; ниже 0.9 — это уже не «редкий файл», а сломанный
        // перевод смещений (первая редакция давала 17%).
        XCTAssertGreaterThan(
            share, 0.9,
            "перевод смещений через сшивку врёт: адрес достаётся чужому месту"
        )
    }

    /// Адреса доходят до метаданных чанков — и не до всех подряд.
    func testLinksReachChunkMetadataWithoutSpreading() async throws {
        let configuration = ChunkingConfiguration()
        var withLinks = 0, chunksTotal = 0, chunksWithLinks = 0

        for url in try pdfs(limit: 200) {
            guard let extracted = try? await PDFExtractor().extract(
                from: url, options: ExtractionOptions()
            ), !extracted.links.isEmpty else { continue }
            withLinks += 1

            let chunks = RecursiveChunker(
                size: configuration.chunkSizeInCharacters,
                overlap: configuration.overlapInCharacters,
                separators: configuration.separators
            ).chunks(from: extracted.plainText)
            let placements = ChunkLocator.placements(of: chunks, in: extracted)
            chunksTotal += chunks.count
            chunksWithLinks += placements.values.filter { !$0.links.isEmpty }.count
        }

        try XCTSkipIf(withLinks < 3, "файлов со ссылками нашлось \(withLinks)")
        let share = Double(chunksWithLinks) / Double(max(1, chunksTotal))
        print("""
        файлов со ссылками: \(withLinks)
        чанков с адресом: \(chunksWithLinks) из \(chunksTotal) \
        (\(String(format: "%.1f%%", 100 * share)))
        """)
        XCTAssertGreaterThan(chunksWithLinks, 0, "адреса не дошли до метаданных вовсе")
        XCTAssertLessThan(share, 0.5, "адрес достался половине чанков — привязка размазалась")
    }
}
