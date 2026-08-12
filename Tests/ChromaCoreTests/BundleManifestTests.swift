import XCTest
@testable import ChromaCore

/// Сведения о приложении задаются в двух файлах, и разойтись им нельзя.
///
/// `Package.swift` решает, подо что собирается код; `Info.plist` — кого
/// система пустит запускаться. Пока эти числа сверял человек, они и
/// разошлись: в плисте стояло 13.0 при сборке под 14, и macOS позволяла
/// запустить приложение там, где оно заведомо неработоспособно.
final class BundleManifestTests: XCTestCase {

    private enum PlistError: Error { case keyMissing(String) }

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func text(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Значение строкового ключа в плисте: `<key>имя</key>` и следом `<string>`.
    ///
    /// Отсутствие ключа — это провал, а не повод пропустить проверку.
    /// Пропуск оставлял бы набор зелёным ровно в том случае, ради которого
    /// эти тесты и написаны: удалённый `LSMinimumSystemVersion` означает
    /// приложение без объявленного минимума, которое macOS пустит куда угодно.
    private func plistString(
        _ key: String, in plist: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let lines = plist.components(separatedBy: .newlines)
        guard let keyLine = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "<key>\(key)</key>"
        }) else {
            XCTFail("в Info.plist нет ключа \(key)", file: file, line: line)
            throw PlistError.keyMissing(key)
        }
        // Значение — ближайшая следующая строка со значением: между ключом
        // и значением может стоять только перенос, комментарии плист
        // допускает лишь до ключа.
        let value = lines[(keyLine + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespaces)
        return trimmed
            .replacingOccurrences(of: "<string>", with: "")
            .replacingOccurrences(of: "</string>", with: "")
    }

    func testTheDeclaredMinimumSystemMatchesWhatTheCodeIsBuiltFor() throws {
        let manifest = try text("Package.swift")
        let plist = try text("Resources/Info.plist")

        // `.macOS(.v14)` → «14»
        guard let range = manifest.range(of: #"\.macOS\(\.v(\d+)\)"#, options: .regularExpression) else {
            return XCTFail("в Package.swift не найдена платформа macOS")
        }
        let major = manifest[range].filter(\.isNumber)

        let declared = try plistString("LSMinimumSystemVersion", in: plist)
        XCTAssertEqual(
            declared.split(separator: ".").first.map(String.init), major,
            "Package.swift собирает под macOS \(major), а Info.plist обещает \(declared): "
                + "система пустит приложение туда, где оно не работает"
        )
    }

    func testTheMarketingVersionIsAPlainThreePartNumber() throws {
        // Номер версии читают и человек, и `mark-stable.sh`, и перенос
        // настроек, который записывает его в выгрузку. Строка вида
        // «0.1.1-beta» сломала бы сравнение выгрузок молча.
        let version = try plistString("CFBundleShortVersionString", in: try text("Resources/Info.plist"))
        let parts = version.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "версия «\(version)» — не «главная.средняя.младшая»")
        XCTAssertTrue(parts.allSatisfy { $0.allSatisfy(\.isNumber) }, "в версии «\(version)» есть не цифры")
    }

    func testTheBuildNumberIsAWholeNumber() throws {
        // CFBundleVersion — счётчик сборок, и macOS сравнивает его как число.
        let build = try plistString("CFBundleVersion", in: try text("Resources/Info.plist"))
        XCTAssertNotNil(Int(build), "номер сборки «\(build)» не целое число")
    }

    /// Языки объявляются папками `*.lproj`, и только ими.
    ///
    /// `CFBundleLocalizations` рядом с ними список не дополняет, а задваивает:
    /// с этим ключом бандл сообщал `["ru","en","en","ru"]` вместо `["en","ru"]`.
    /// Ключ легко вписать обратно «для порядка» — этот тест напоминает, что
    /// порядок как раз обратный.
    func testLanguagesAreDeclaredByFoldersOnly() throws {
        let plist = try text("Resources/Info.plist")
        XCTAssertFalse(
            plist.contains("<key>CFBundleLocalizations</key>"),
            "языки берутся из папок Resources/*.lproj; этот ключ их задваивает"
        )

        let resources = root.appendingPathComponent("Resources")
        let folders = try FileManager.default.contentsOfDirectory(atPath: resources.path)
            .filter { $0.hasSuffix(".lproj") }
            .sorted()
        XCTAssertEqual(folders, ["en.lproj", "ru.lproj"], "языки бандла — эти папки")
    }
}
