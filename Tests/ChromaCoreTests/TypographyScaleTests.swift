import XCTest

/// Сторож шрифтов после перехода на системные компоненты (переход
/// интерфейса, его инструкции).
///
/// Прежнее правило 6 — «только `Theme.Font`, системная шкала
/// запрещена» — перевёрнуто: текст задают системные стили (`.body`,
/// `.callout`, `.caption`…), заголовки секций — сама `Form`/`List`, и числом
/// размер шрифта не пишется нигде, кроме точки состояния в `StatusLabel`.
///
/// Все экраны переведены, и `Theme` удалён — поэтому правило проверяется на
/// каждом файле `Views/` и `App/`, а не по списку.
final class TypographyScaleTests: XCTestCase {
    private var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ChromaDBManagerApp")
    }

    /// Строки кода без комментариев — с номерами.
    private func codeLines(of file: URL) throws -> [(Int, String)] {
        try String(contentsOf: file, encoding: .utf8)
            .components(separatedBy: .newlines)
            .enumerated()
            .map { ($0.offset + 1, $0.element.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.1.hasPrefix("//") }
    }

    private func swiftFiles(in folder: String) throws -> [URL] {
        let directory = sources.appendingPathComponent(folder)
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
    }

    func testEveryScreenUsesTheSystemTextStyles() throws {
        let files = try swiftFiles(in: "Views") + swiftFiles(in: "App")
        XCTAssertFalse(files.isEmpty, "экраны не найдены рядом с тестами")
        var offences: [String] = []
        for file in files {
            for (number, code) in try codeLines(of: file)
            where code.contains("Theme.") || code.contains(".font(.system(size:") {
                offences.append("\(file.lastPathComponent):\(number): \(code)")
            }
        }
        XCTAssertTrue(
            offences.isEmpty,
            "Экран задаёт шрифт или цвет сам, а не системным стилем:\n" + offences.joined(separator: "\n")
        )
    }

    func testOnlyTheStatusDotHasANumericFontSize() throws {
        let files = try swiftFiles(in: "UI")
        XCTAssertFalse(files.isEmpty, "каталог UI/ не найден рядом с тестами")
        var offences: [String] = []
        for file in files where file.lastPathComponent != "StatusLabel.swift" {
            for (number, code) in try codeLines(of: file) where code.contains(".font(.system(size:") {
                offences.append("\(file.lastPathComponent):\(number): \(code)")
            }
        }
        XCTAssertTrue(offences.isEmpty, "Размер шрифта числом — только у точки в StatusLabel:\n" + offences.joined(separator: "\n"))
    }
}
