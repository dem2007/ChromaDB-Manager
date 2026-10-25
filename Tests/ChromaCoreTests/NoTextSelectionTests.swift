import XCTest

/// `.textSelection(.enabled)` роняет приложение — исключение AppKit
/// из `SelectionOverlay`, когда шрифт поля меняется внутри прохода вёрстки.
/// Решение было «убрать из приложения полностью», а копирование — пунктом
/// «Скопировать» в контекстном меню (`copyable`). Редизайн вернул его
/// в тридцать с лишним мест; сторож держит правило, раз обзор кода его
/// не удержал.
final class NoTextSelectionTests: XCTestCase {
    func testTheAppHasNoSelectableText() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ChromaDBManagerApp")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw XCTSkip("исходники приложения не найдены рядом с тестами")
        }
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated()
            where line.contains(".textSelection(.enabled)") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                offenders.append("\(url.lastPathComponent):\(index + 1)")
            }
        }
        XCTAssertEqual(offenders, [], "`.textSelection(.enabled)` запрещён — используйте `.copyable(_:)`")
    }
}
