import XCTest

/// Сторож подтверждений.
///
/// `.alert` на виде может быть **только один**: второй SwiftUI молча
/// выбрасывает. Состояние при этом меняется как ни в чём не бывало — кнопка
/// «нажимается», свойство ставится, alert не показывается, в журнале пусто.
/// Именно так вышло с кнопкой «Загрузить с N»: рядом уже жило подтверждение
/// замера скорости, и оно выигрывало.
///
/// Глазами это не ловится: оба alert-а выглядят правильно и стоят рядом.
/// Компилятор молчит — конструкция законная. Поэтому проверяет тест: у одного
/// вида одно подтверждение, а если поводов несколько — они сводятся в одно
/// перечисление, как в `EmbeddingsViewModel.PendingModelAction`.
final class SinglePresentationTests: XCTestCase {
    private var views: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ChromaDBManagerApp")
    }

    func testNoViewCarriesMoreThanOneAlert() throws {
        var offences: [String] = []
        for file in try swiftFiles(in: views) {
            let text = try String(contentsOf: file, encoding: .utf8)
            var current: String?
            var alerts: [String: [Int]] = [:]

            for (number, line) in text.components(separatedBy: .newlines).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                // Объявление вида: `struct Имя: View {`.
                if code.hasPrefix("struct "), code.contains(": View"), let name = code
                    .dropFirst("struct ".count)
                    .split(whereSeparator: { $0 == ":" || $0 == " " })
                    .first {
                    current = String(name)
                }
                guard !code.hasPrefix("//") else { continue }
                guard code.hasPrefix(".alert(") else { continue }
                alerts[current ?? file.lastPathComponent, default: []].append(number + 1)
            }

            for (view, lines) in alerts where lines.count > 1 {
                offences.append(
                    "\(file.lastPathComponent): \(view) — строки \(lines.map(String.init).joined(separator: ", "))"
                )
            }
        }

        XCTAssertTrue(
            offences.isEmpty,
            """
            У этих видов больше одного `.alert`. SwiftUI покажет только один,
            остальные молча не сработают — свойство ставится, на экране ничего
            . Сведите поводы в одно перечисление и разберите его внутри
            единственного `.alert`, как `PendingModelAction`:
            \(offences.joined(separator: "\n"))
            """
        )
    }

    private func swiftFiles(in directory: URL) throws -> [URL] {
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
