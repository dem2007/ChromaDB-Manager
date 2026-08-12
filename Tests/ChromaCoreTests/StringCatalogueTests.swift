import XCTest
@testable import ChromaCore

/// Каталог текстов приложения — `Resources/ru.lproj/Localizable.strings`.
///
/// Он затем и заведён, чтобы надписи правил человек, а не программист. Значит
/// ошибиться в нём может человек, не знающий, чем `%@` отличается от `%lld`, —
/// и ошибка эта тихая: строка либо потеряет подставленное значение, либо
/// покажет мусор вместо числа. Ловится она только здесь.
final class StringCatalogueTests: XCTestCase {
    private static var catalogueURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/ru.lproj/Localizable.strings")
    }

    /// Пары «ключ = значение» из файла, в порядке появления.
    static func entries(in text: String) -> [(key: String, value: String)] {
        var result: [(String, String)] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), trimmed.hasSuffix(";") else { continue }
            guard let (key, rest) = readQuoted(trimmed.dropFirst()) else { continue }
            guard let equals = rest.firstIndex(of: "\"") else { continue }
            guard let (value, _) = readQuoted(rest[rest.index(after: equals)...]) else { continue }
            result.append((key, value))
        }
        return result
    }

    /// Читает строку в кавычках с учётом экранирования; возвращает её и хвост.
    private static func readQuoted(_ text: Substring) -> (String, Substring)? {
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char == "\\" {
                let next = text.index(after: index)
                guard next < text.endIndex else { return nil }
                out.append(text[next])
                index = text.index(after: next)
                continue
            }
            if char == "\"" { return (out, text[text.index(after: index)...]) }
            out.append(char)
            index = text.index(after: index)
        }
        return nil
    }

    /// Спецификаторы формата по порядку: `%@`, `%lld`, `%lf`, `%%`.
    static func specifiers(in text: String) -> [String] {
        var found: [String] = []
        var rest = Substring(text)
        while let percent = rest.firstIndex(of: "%") {
            var index = rest.index(after: percent)
            var token = "%"
            while index < rest.endIndex, "0123456789.$#+- ".contains(rest[index]) {
                token.append(rest[index])
                index = rest.index(after: index)
            }
            while index < rest.endIndex, "lh".contains(rest[index]) {
                token.append(rest[index])
                index = rest.index(after: index)
            }
            if index < rest.endIndex {
                token.append(rest[index])
                index = rest.index(after: index)
            }
            if token != "%%" { found.append(token) }
            rest = rest[index...]
        }
        return found
    }

    private func catalogue() throws -> [(key: String, value: String)] {
        let url = Self.catalogueURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("каталог текстов не найден рядом с тестами")
        }
        return Self.entries(in: try String(contentsOf: url, encoding: .utf8))
    }

    /// Главное: правка не может потерять подстановку.
    ///
    /// «Найдено %lld документов» → «Найдено документов» — и число исчезает
    /// с экрана навсегда, а заметит это только тот, кто помнит, что оно там
    /// было.
    func testEveryTranslationKeepsItsPlaceholders() throws {
        var offenders: [String] = []
        for (key, value) in try catalogue() {
            let expected = Self.specifiers(in: key)
            let actual = Self.specifiers(in: value)
            if expected != actual {
                offenders.append("«\(key)»\n  ожидалось: \(expected)\n  в тексте:  \(actual)")
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            """
            В переводе изменился набор подстановок. Слева — как строка написана \
            в коде, справа — что увидит человек; %@, %lld и %lf обязаны совпадать \
            по составу и порядку:
            \(offenders.prefix(10).joined(separator: "\n"))
            """
        )
    }

    /// Один ключ — одна строка. Два одинаковых ключа означают, что одна из
    /// правок молча не действует, и понять, какая именно, нельзя.
    func testNoKeyIsListedTwice() throws {
        var seen: Set<String> = []
        var doubled: [String] = []
        for (key, _) in try catalogue() where !seen.insert(key).inserted {
            doubled.append(key)
        }
        XCTAssertTrue(doubled.isEmpty, "ключи повторяются: \(doubled.prefix(5))")
    }

    /// Пустое значение — это исчезнувшая надпись. Если строку и правда надо
    /// убрать, её убирают из кода, а не опустошают здесь: иначе на экране
    /// остаётся пустое место без объяснения.
    func testNoTranslationIsEmpty() throws {
        let empty = try catalogue().filter { $0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertTrue(empty.isEmpty, "пустые тексты у ключей: \(empty.map(\.key).prefix(5))")
    }

    /// Сторож бесполезен, если читает пустоту.
    func testTheCatalogueIsActuallyRead() throws {
        let entries = try catalogue()
        XCTAssertGreaterThan(entries.count, 1500, "каталог подозрительно мал")
        XCTAssertTrue(entries.contains { $0.key.contains("%@") }, "в каталоге должны быть подстановки")
    }

    // MARK: - Английский каталог

    private static var englishURL: URL {
        catalogueURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("en.lproj/Localizable.strings")
    }

    private func english() throws -> [(key: String, value: String)] {
        let url = Self.englishURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("английский каталог не найден рядом с тестами")
        }
        return Self.entries(in: try String(contentsOf: url, encoding: .utf8))
    }

    /// Новая строка не может остаться без перевода незаметно.
    ///
    /// Незаметно — это ключевое слово: ключ, которого нет в `en.lproj`,
    /// не ломает ничего и не пишет в журнал, он просто показывает
    /// англоязычному человеку русскую фразу. Один раз каталог уже сверялся
    /// разовым скриптом; скрипт, запускаемый вручную, — это проверка,
    /// которую забудут.
    func testEveryRussianKeyHasAnEnglishLine() throws {
        let translated = Set(try english().map(\.key))
        let missing = try catalogue().map(\.key).filter { !translated.contains($0) }
        XCTAssertTrue(
            missing.isEmpty,
            "без перевода осталось \(missing.count): \(missing.prefix(5).map { $0.prefix(60) })"
        )
    }

    /// Та же проверка подстановок, что и для русского: перевод, потерявший
    /// `%@`, теряет подставленное значение.
    func testEveryEnglishTranslationKeepsItsPlaceholders() throws {
        var offenders: [String] = []
        for (key, value) in try english() where Self.specifiers(in: key) != Self.specifiers(in: value) {
            offenders.append("«\(key.prefix(60))»: \(Self.specifiers(in: key)) → \(Self.specifiers(in: value))")
        }
        XCTAssertTrue(offenders.isEmpty, offenders.prefix(10).joined(separator: "\n"))
    }

    /// Кириллица в английском тексте — это недоперевод.
    ///
    /// Кроме строк, где перевод **равен** ключу: имена параметров ChromaDB,
    /// примеры JSON и чистые подстановки переводить нечем, и такие пары
    /// в каталоге стоят намеренно.
    func testNoEnglishTranslationIsLeftHalfRussian() throws {
        let cyrillic = CharacterSet(charactersIn: "абвгдежзийклмнопрстуфхцчшщъыьэюяёАБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯЁ")
        let offenders = try english()
            .filter { $0.value != $0.key && $0.value.rangeOfCharacter(from: cyrillic) != nil }
        XCTAssertTrue(
            offenders.isEmpty,
            "русские слова в переводе: \(offenders.prefix(5).map { $0.value.prefix(60) })"
        )
    }

    /// И что разбор понимает экранирование, а не отбрасывает такие строки.
    func testTheParserUnderstandsEscaping() {
        let sample = #""путь \"%@\" не найден" = "не найден путь \"%@\"";"#
        let entries = Self.entries(in: sample)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.key, #"путь "%@" не найден"#)
        XCTAssertEqual(Self.specifiers(in: entries[0].value), ["%@"])
    }

    /// Разбор спецификаторов: длину и ширину отличаем, `%%` не считаем.
    func testSpecifiersAreReadPrecisely() {
        XCTAssertEqual(Self.specifiers(in: "%@ из %lld — %.1lf%%"), ["%@", "%lld", "%.1lf"])
        XCTAssertEqual(Self.specifiers(in: "без подстановок"), [])
    }
}
