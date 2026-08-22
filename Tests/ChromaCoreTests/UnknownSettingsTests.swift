import XCTest
@testable import ChromaCore

/// Настройка из будущего: файл её несёт, сборка её не знает.
///
/// Живой случай, ради которого сделано: прогон стенда поставили с порогом
/// `textSearchMaxWords`, а приложение было собрано до появления порога.
/// Незнакомый ключ разобрался молча, поиск шёл по-старому, и все четыре
/// варианта дали числа опорного до третьего знака. Найти причину удалось
/// только сравнив дату сборки с датой правки.
final class UnknownSettingsTests: XCTestCase {

    private func json(_ extra: String) -> Data {
        Data("""
        {"id":"\(UUID().uuidString)","name":"профиль","collectionName":"к"\(extra)}
        """.utf8)
    }

    func testAnUnknownKeyIsNamedRatherThanSwallowed() throws {
        let profile = try JSONDecoder().decode(
            SearchProfile.self, from: json(",\"textSearchMaxWords\":5,\"пришелец\":true")
        )
        XCTAssertEqual(profile.unknownSettings, ["пришелец"], "незнакомый ключ обязан назваться")
    }

    /// Главное: знакомые ключи в предупреждение не попадают, иначе оно
    /// зажужжит на каждом профиле и его перестанут читать.
    func testKnownKeysAreNotReported() throws {
        let profile = try JSONDecoder().decode(
            SearchProfile.self,
            from: json(",\"textSearchEnabled\":true,\"textSearchMaxWords\":5,\"diversityLambda\":0.7")
        )
        XCTAssertEqual(profile.textSearchMaxWords, 5)
        XCTAssertTrue(profile.unknownSettings.isEmpty, "своя же настройка объявлена чужой")
    }

    /// Разбор остаётся терпимым: незнакомый ключ не роняет ни профиль, ни
    /// файл целиком — иначе одна чужая настройка стоила бы всех остальных.
    func testTheProfileStillDecodesAroundTheUnknownKey() throws {
        let profile = try JSONDecoder().decode(
            SearchProfile.self, from: json(",\"textSearchEnabled\":true,\"настройка_из_будущего\":{\"a\":1}")
        )
        XCTAssertEqual(profile.name, "профиль")
        XCTAssertTrue(profile.textSearchEnabled)
        XCTAssertEqual(profile.unknownSettings, ["настройка_из_будущего"])
    }

    /// В файл предупреждение не просачивается: иначе оно записалось бы как
    /// настоящая настройка и стало бы незнакомым ключом для следующей сборки.
    func testTheWarningIsNotWrittenBack() throws {
        let profile = try JSONDecoder().decode(SearchProfile.self, from: json(",\"чужое\":1"))
        let written = try JSONEncoder().encode(profile)
        let text = String(decoding: written, as: UTF8.self)
        XCTAssertFalse(text.contains("unknownSettings"))
        XCTAssertFalse(text.contains("чужое"), "чужой ключ не сохраняется — о чём и предупреждаем")
    }

    /// Профиль, собранный в коде, чист: предупреждать не о чем.
    func testAProfileMadeInCodeHasNothingUnknown() {
        XCTAssertTrue(SearchProfile(name: "новый", collectionName: "к").unknownSettings.isEmpty)
    }
}
