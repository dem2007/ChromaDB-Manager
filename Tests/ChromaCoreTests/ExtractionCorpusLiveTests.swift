import XCTest
@testable import ChromaCore

/// Выгрузка извлечённого текста целой папки — для сравнения «до» и «после»
/// правки разбора на настоящих файлах.
///
/// Ничего не утверждает: проверять глазами разницу двух выгрузок — дело
/// человека, а утверждать на чужих документах нечего. Каждый файл ложится
/// в `CHROMA_DUMP` отдельным `.txt` с тем же относительным путём; в начале —
/// извлекатель, версия и оговорки.
///
///     CHROMA_IT=1 CHROMA_CORPUS=/папка CHROMA_DUMP=/куда swift test --filter ExtractionCorpusLiveTests
///
/// `CHROMA_ONLY=pdf,docx` — только эти расширения, `CHROMA_MATCH=КП` — только
/// файлы, в имени которых есть эта строка.
final class ExtractionCorpusLiveTests: XCTestCase {
    func testDumpCorpus() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["CHROMA_IT"] == "1", "Живая выгрузка включается CHROMA_IT=1")
        guard let corpus = environment["CHROMA_CORPUS"], let dump = environment["CHROMA_DUMP"] else {
            throw XCTSkip("Нужны CHROMA_CORPUS и CHROMA_DUMP")
        }
        let only = environment["CHROMA_ONLY"].map { Set($0.split(separator: ",").map { String($0).lowercased() }) }
        let root = URL(fileURLWithPath: corpus)
        let target = URL(fileURLWithPath: dump)
        let registry = ExtractorRegistry.standard()
        var options = ExtractionOptions()
        options.ocrEnabled = true
        options.ocrLanguages = ["ru-RU", "en-US"]

        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { !$0.lastPathComponent.hasPrefix("~$") && !$0.lastPathComponent.hasPrefix(".") && !$0.hasDirectoryPath }
            .filter { only?.contains($0.pathExtension.lowercased()) ?? true }
            .filter { file in environment["CHROMA_MATCH"].map { file.lastPathComponent.contains($0) } ?? true }
            .sorted { $0.path < $1.path } ?? []
        for file in files {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            let output = target.appendingPathComponent(relative + ".txt")
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let started = Date()
            var text: String
            do {
                let extracted = try await registry.extract(from: file, options: options)
                let warnings = extracted.warnings.map(\.text).joined(separator: "; ")
                text = "# \(extracted.extractorID) v\(extracted.extractorVersion), "
                    + String(format: "%.1f s", Date().timeIntervalSince(started))
                    + "\n# \(warnings)\n\n" + extracted.plainText
            } catch {
                text = "# ошибка: \(error)"
            }
            try text.write(to: output, atomically: true, encoding: .utf8)
        }
    }
}
