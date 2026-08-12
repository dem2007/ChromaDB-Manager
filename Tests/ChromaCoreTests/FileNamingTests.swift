import XCTest
@testable import ChromaCore

/// Имя, предлагаемое в диалоге сохранения.
final class FileNamingTests: XCTestCase {

    /// Главное, ради чего тип и появился: правила ChromaDB выкидывали из имени
    /// файла всю кириллицу, и «Прогон 4 Aug 2026 at 20:25» превращался в
    /// «4_Aug_2026_at_20_25». Найдено на живом экспорте отчёта.
    func testTheRussianWordsSurvive() {
        let name = FileNaming.suggested(
            "Прогон 4 Aug 2026 at 20:25", suffix: "-report", extension: "md"
        )
        XCTAssertTrue(name.hasPrefix("Прогон"), name)
        XCTAssertTrue(name.hasSuffix("-report.md"), name)
    }

    /// Двоеточие и слэш — единственные знаки, которые файловой системе мешают.
    func testSlashAndColonAreReplaced() {
        let name = FileNaming.suggested("отчёт 12:30 за 01/02", extension: "json")
        XCTAssertFalse(name.contains(":"))
        XCTAssertFalse(name.contains("/"))
        XCTAssertEqual(name, "отчёт 12-30 за 01-02.json")
    }

    /// Файл с ведущей точкой Finder прячет — а сохранить просили видимый файл.
    func testALeadingDotIsRemoved() {
        XCTAssertEqual(FileNaming.suggested("...тихий", extension: "md"), "тихий.md")
    }

    /// Пустое имя даёт понятную замену, а не расширение без имени.
    func testAnEmptyNameGetsAPlaceholder() {
        let name = FileNaming.suggested("   ", extension: "md")
        XCTAssertFalse(name.hasPrefix("."), name)
        XCTAssertTrue(name.hasSuffix(".md"), name)
    }

    /// Длина считается в байтах: кириллица в UTF-8 занимает два на букву, и
    /// счёт по символам дал бы имя, которого файловая система не примет.
    func testLongNamesAreCutByBytesAndNotMidCharacter() {
        let long = String(repeating: "я", count: 300)
        let name = FileNaming.suggested(long, extension: "md")
        XCTAssertLessThanOrEqual(name.utf8.count, FileNaming.maximumBytes + 3)
        XCTAssertTrue(name.hasSuffix(".md"))
        // Обрезано по границе символа — строка осталась читаемой.
        XCTAssertTrue(name.dropLast(3).allSatisfy { $0 == "я" })
    }
}
