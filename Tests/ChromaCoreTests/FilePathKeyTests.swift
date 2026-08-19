import XCTest
@testable import ChromaCore

/// Путь файла как ключ поиска.
///
/// Тесты сравнивают **байты**, а не строки: `==` у Swift канонический и на
/// разные формы записи отвечает «одинаково» — то есть ровно то, чего база,
/// JSON и файловая система не делают. Проверять здесь надо их правду.
final class FilePathKeyTests: XCTestCase {
    private func bytes(_ value: String) -> [UInt8] { Array(value.utf8) }

    /// «й» разложенная и «й» слитная — один и тот же файл.
    func testTheSamePathWrittenTwoWaysIsOnePath() {
        let precomposed = "Отчёты/Первый/Договор поставки.pdf"
        let decomposed = precomposed.decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(bytes(precomposed), bytes(decomposed), "иначе проверять нечего")
        XCTAssertTrue(FilePathKey.matches(precomposed, decomposed))
        XCTAssertEqual(bytes(FilePathKey.canonical(decomposed)), bytes(precomposed))
    }

    /// Разные файлы остаются разными: сопоставление не должно склеивать
    /// соседние документы одной папки.
    func testDifferentFilesStayDifferent() {
        XCTAssertFalse(FilePathKey.matches("Отчёты/1.pdf", "Отчёты/2.pdf"))
        XCTAssertFalse(FilePathKey.matches("Отчёты/Акт.pdf", "Отчеты/Акт.pdf"))
    }

    /// Форма файловой системы — не обычное разложение: типографские знаки она
    /// оставляет целыми, и путь из базы совпадал только с ней.
    func testTheFileSystemKeepsTypographicSignsWhole() {
        let path = "ЦОД/Смета ≠ 5/Первый лист.pdf"
        let ours = FilePathKey.fileSystemDecomposed(path)
        XCTAssertTrue(ours.unicodeScalars.contains("\u{2260}"), "«≠» файловая система не разлагает")
        XCTAssertFalse(
            path.decomposedStringWithCanonicalMapping.unicodeScalars.contains("\u{2260}"),
            "обычное разложение его разбирает — потому одного варианта и не хватало"
        )
        XCTAssertTrue(ours.unicodeScalars.contains("\u{0306}"), "а «й» — разлагает")
        XCTAssertNotEqual(
            bytes(ours), bytes(path.decomposedStringWithCanonicalMapping),
            "две разложенные формы должны отличаться, иначе вариант лишний"
        )
        XCTAssertTrue(FilePathKey.matches(ours, path))
    }

    /// Варианты идут от запрошенного к остальным и не повторяются: каждый
    /// лишний — это лишний запрос к базе, а каждый потерянный — промах.
    func testVariantsStartWithWhatWasAskedAndDoNotRepeat() {
        let asked = "Отчёты/Акт.pdf".decomposedStringWithCanonicalMapping
        let variants = FilePathKey.variants(asked)
        XCTAssertEqual(bytes(variants[0]), bytes(asked))
        XCTAssertEqual(Set(variants.map(bytes)).count, variants.count)
        XCTAssertTrue(variants.map(bytes).contains(bytes("Отчёты/Акт.pdf")))

        // Латиница пишется одинаково всегда — вариант ровно один.
        XCTAssertEqual(FilePathKey.variants("docs/readme.md").count, 1)
    }

    /// Путь с типографским знаком даёт три разные формы: слитную, обычную
    /// разложенную и файловую. Именно третьей и не хватало.
    func testAPathWithTypographyGivesThreeForms() {
        let variants = FilePathKey.variants("ЦОД/Смета ≠ 5/Первый лист.pdf")
        XCTAssertEqual(variants.count, 3)
    }
}
