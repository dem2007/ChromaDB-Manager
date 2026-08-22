import XCTest
@testable import ChromaCore

/// Правило 6: округление, дающее ноль, заменяется словами.
///
/// «за 0.0 с» — не «мгновенно», а «измерение потеряно»: быстрая запись
/// таблицы и синхронизация одного файла печатали именно его.
final class SecondsTextTests: XCTestCase {

    func testTooSmallToRoundIsSaidInWords() {
        XCTAssertEqual(SecondsText.line(0.04), "меньше 0,1 с")
        XCTAssertEqual(SecondsText.line(0), "меньше 0,1 с")
        XCTAssertEqual(SecondsText.line(0.004, decimals: 2), "меньше 0,01 с")
    }

    /// Граница принадлежит числу: 0,1 с — это «0.1 с», а не «меньше».
    func testTheThresholdItselfIsPrinted() {
        XCTAssertEqual(SecondsText.line(0.1), "0.1 с")
        XCTAssertEqual(SecondsText.line(0.01, decimals: 2), "0.01 с")
    }

    func testOrdinaryValuesKeepTheirDigits() {
        XCTAssertEqual(SecondsText.line(12.34), "12.3 с")
        // Не 1.005: в двоичной дроби оно чуть меньше половины и округляется
        // вниз — ожидание «1.01» было бы ошибкой теста, а не кода.
        XCTAssertEqual(SecondsText.line(1.006, decimals: 2), "1.01 с")
    }

    /// Экраны берут правило отсюда, а не переписывают его у себя: раньше
    /// сырой `%.1f` стоял в сводке синхронизации и в сводке записи таблицы.
    func testScreensGoThroughTheHelper() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ChromaDBManagerApp/Views")
        guard FileManager.default.fileExists(atPath: views.path) else {
            throw XCTSkip("исходники экранов не найдены рядом с тестами")
        }
        var offences: [String] = []
        for file in try FileManager.default.contentsOfDirectory(at: views, includingPropertiesForKeys: nil)
        where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.components(separatedBy: .newlines).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), !code.hasPrefix("///") else { continue }
                // Секунды, напечатанные мимо правила: формат рядом со словом
                // «с» в той же строке.
                if code.contains("String(format: \"%.1f\""), code.contains(") с") {
                    offences.append("\(file.lastPathComponent):\(number + 1): \(code)")
                }
            }
        }
        XCTAssertTrue(
            offences.isEmpty,
            """
            секунды печатаются мимо SecondsText — «0.0 с» вместо «меньше 0,1 с»:
            \(offences.joined(separator: "\n"))
            """
        )
    }
}
