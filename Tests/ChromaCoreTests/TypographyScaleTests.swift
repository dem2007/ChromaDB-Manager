import XCTest

/// Сторож шкалы шрифтов.
///
/// Системные `.caption`, `.callout`, `.headline`, `.title`, `.footnote` дают
/// свою шкалу, не совпадающую с макетом: рядом с `Theme.Font.caption` (12,5)
/// системный `.caption` (10) читается как другой уровень текста, которого в
/// дизайн-системе нет. Отсюда и расползались кегли — на «Замерах» в одной
/// карточке жили четыре разных размера, ни один из которых не был из шкалы
///.
///
/// Тест читает исходники экранов: проверять это глазами на пятнадцати экранах
/// приходится заново после каждой правки.
final class TypographyScaleTests: XCTestCase {
    /// Где числа задавать можно: сама тема их и объявляет.
    private let allowedFiles: Set<String> = ["Theme.swift"]

    private var viewsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ChromaDBManagerApp/Views")
    }

    func testScreensUseTheApplicationScaleAndNotTheSystemOne() throws {
        let manager = FileManager.default
        let files = try manager.contentsOfDirectory(at: viewsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .filter { !allowedFiles.contains($0.lastPathComponent) }

        // `.font(.caption)` и родня: точечные вызовы, а не любое упоминание
        // слова — комментарий про системный `.caption` нарушением не является.
        let forbidden = [
            ".font(.caption)", ".font(.caption2)", ".font(.callout",
            ".font(.headline", ".font(.subheadline", ".font(.footnote",
            ".font(.title", ".font(.body)", ".font(.largeTitle",
        ]

        var offences: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.components(separatedBy: .newlines).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), !code.hasPrefix("///") else { continue }
                for pattern in forbidden where code.contains(pattern) {
                    offences.append("\(file.lastPathComponent):\(number + 1): \(code)")
                }
            }
        }

        XCTAssertTrue(
            offences.isEmpty,
            """
            Системная шкала шрифтов вместо Theme.Font — правило 6:
            \(offences.joined(separator: "\n"))
            """
        )
    }
}
