import XCTest
@testable import ChromaCore

/// Разбор отложенных находок прошлых ревью.
final class DeferredReviewTests: XCTestCase {
    /// Замер предела модели: известные контексты сравниваются, а запись,
    /// свежесть которой подтвердить нечем, живёт неделю, а не вечно.
    func testAMeasuredLimitWithoutAContextExpires() {
        let now = Date()
        let known = MeasuredInputLimit(model: "m", characters: 21_400, measuredAt: now, loadedContext: 2048)
        XCTAssertTrue(known.isFresh(loadedContext: 2048, now: now))
        XCTAssertFalse(known.isFresh(loadedContext: 4096, now: now))

        let silent = MeasuredInputLimit(model: "m", characters: 21_400, measuredAt: now, loadedContext: nil)
        XCTAssertTrue(silent.isFresh(loadedContext: nil, now: now.addingTimeInterval(3600)))
        XCTAssertFalse(
            silent.isFresh(loadedContext: nil, now: now.addingTimeInterval(MeasuredInputLimit.unverifiedLifetime + 1)),
            "nil == nil объявлял запись свежей навсегда"
        )
    }

    /// Имена ZIP без флага UTF-8: русское — CP866, западное — CP437.
    func testZipNamesPickTheirDOSEncoding() {
        let russian = Data([0x8E, 0xE2, 0xE7, 0xF1, 0xE2, 0x2E, 0x74, 0x78, 0x74])  // «Отчёт.txt» в CP866
        XCTAssertEqual(ZIPContainerReader.entryName(russian, declaresUTF8: false), "Отчёт.txt")
        let western = Data([0x4D, 0x81, 0x6C, 0x6C, 0x65, 0x72, 0x2E, 0x74, 0x78, 0x74])  // «Müller.txt» в CP437
        XCTAssertEqual(ZIPContainerReader.entryName(western, declaresUTF8: false), "Müller.txt")
    }

    /// Профиль из файла с незнакомым ключом равен такому же из кода:
    /// незнакомые ключи — сведение о файле, а не настройка поиска.
    func testUnknownSettingsDoNotMakeProfilesUnequal() throws {
        let built = SearchProfile(name: "p", collectionName: "c")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(built)) as? [String: Any])
        json["futureSetting"] = 1
        let read = try JSONDecoder().decode(SearchProfile.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(read.unknownSettings, ["futureSetting"])
        XCTAssertEqual(read, built)
        XCTAssertEqual(read.hashValue, built.hashValue)
    }

    /// Секунды в сообщении: дробь не теряется, целые — без «.0».
    func testSecondsKeepTheirFraction() {
        XCTAssertEqual(TimeInterval(0.5).secondsText, "0.5")
        XCTAssertEqual(TimeInterval(1.5).secondsText, "1.5")
        XCTAssertEqual(TimeInterval(30).secondsText, "30")
        XCTAssertEqual(TimeInterval(12.7).secondsText, "13")
        XCTAssertEqual(TimeInterval(9.96).secondsText, "10")
    }
}
