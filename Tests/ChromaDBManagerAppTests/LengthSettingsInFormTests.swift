import XCTest
import ChromaCore
@testable import ChromaDBManagerApp

/// Штраф за длину и отсечка обязаны быть **настройкой в форме**, а не
/// поведением поиска.
///
/// Сторож по исходникам, как `CopyableNamesTests`: проверяется не то, что
/// код вычисляет, а то, как он написан. Переключатель, потерявший привязку
/// к профилю, компилируется и проходит все прочие тесты — а человек остаётся
/// с ранжированием, которое нельзя выключить.
final class LengthSettingsInFormTests: XCTestCase {
    private func sheetSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ChromaDBManagerApp/Views/SearchProfileSheet.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("исходники формы не найдены рядом с тестами")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Переключатель штрафа привязан к профилю — значит, его можно снять.
    func testThePenaltyHasASwitchBoundToTheProfile() throws {
        let source = try sheetSource()
        XCTAssertTrue(
            source.contains("isOn: $profile.lengthPenaltyEnabled"),
            "переключатель штрафа обязан править сам профиль"
        )
        XCTAssertTrue(source.contains("value: $profile.lengthTarget"), "цель — поле формы")
        XCTAssertTrue(source.contains("value: $profile.lengthPenaltyPower"), "степень — поле формы")
    }

    /// Отсечка доводится до нуля — «не отбрасывать по длине».
    ///
    /// Нижняя граница именно ноль: шаг, начинающийся с пятидесяти, оставил бы
    /// человека с отсечкой, которую нечем снять.
    func testTheCutoffCanBeTakenDownToZero() throws {
        let source = try sheetSource()
        XCTAssertTrue(source.contains("value: $profile.minimumCharacters, in: 0..."), "отсечка обязана доходить до нуля")
        XCTAssertTrue(source.contains("не отбрасывать по длине"), "ноль обязан читаться словами, а не цифрой")
    }

    /// И то, и другое выключено у нового профиля: настройка появляется
    /// в форме, а не в поведении по умолчанию.
    func testANewProfileHasBothOff() {
        let profile = SearchProfile(collectionName: "к")
        XCTAssertFalse(profile.lengthPenaltyEnabled)
        XCTAssertEqual(profile.minimumCharacters, 0)
    }
}
