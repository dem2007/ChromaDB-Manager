import XCTest
@testable import ChromaCore

/// §E0.2 — profiles are stored locally, per collection, and are portable.
final class SearchProfileStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("search-profiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> SearchProfileStore { SearchProfileStore(directory: directory) }

    func testACollectionNobodyTunedGetsTheDefaultsOfTheSpecification() {
        let profile = store().defaultProfile(for: "заметки")
        // The hierarchy settings are on because that is what the strategy is
        // for; on a one-level collection the pipeline drops them and they cost
        // nothing, including no larger pool.
        XCTAssertEqual(profile.searchLevel, .children)
        XCTAssertEqual(profile.promotion, .parent)
        XCTAssertTrue(profile.collapseByParent)
        XCTAssertEqual(profile.poolSize(nResults: 7, stages: []), 7)
    }

    func testAnUntouchedDefaultIsNotWrittenToDisk() {
        _ = store().defaultProfile(for: "заметки")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("search-profiles.json").path),
            "файл из одних умолчаний сделал бы вопрос «этой коллекции что-то настраивали» неотвечаемым"
        )
    }

    // MARK: - «Умный поиск» — the master switch

    func testTheSwitchIsOnUntilSomebodyTurnsItOff() {
        XCTAssertTrue(store().isPipelineEnabled(for: "заметки"))
    }

    func testTurningItOffSurvivesReopening() {
        store().setPipelineEnabled(false, for: "заметки")
        XCTAssertFalse(store().isPipelineEnabled(for: "заметки"))
        XCTAssertTrue(store().isPipelineEnabled(for: "книги"), "выключатель у каждой коллекции свой")
    }

    /// With the switch off the search must be the search of stage 2 exactly —
    /// not «почти то же»: every optional stage off, and therefore no larger
    /// candidate pool either.
    func testWithTheSwitchOffEveryOptionalStageIsOff() {
        let store = store()
        var tuned = SearchProfile(name: "настроенный", collectionName: "заметки")
        tuned.diversityEnabled = true
        tuned.textSearchEnabled = true
        tuned.contextWindow = 3
        store.save(tuned)
        store.setPipelineEnabled(false, for: "заметки")

        let effective = store.effectiveProfile(for: "заметки")
        XCTAssertTrue(effective.requestedStages.isEmpty)
        XCTAssertEqual(effective.poolSize(nResults: 5, stages: effective.requestedStages), 5)
        // The name is kept: a panel claiming the search ran under «По умолчанию»
        // when the user's profile is «настроенный» would be a second lie on top
        // of the first.
        XCTAssertEqual(effective.name, "настроенный")
    }

    func testTurningItBackOnRestoresTheProfileUntouched() {
        let store = store()
        var tuned = SearchProfile(name: "настроенный", collectionName: "заметки")
        tuned.diversityEnabled = true
        store.save(tuned)

        store.setPipelineEnabled(false, for: "заметки")
        store.setPipelineEnabled(true, for: "заметки")

        XCTAssertTrue(store.effectiveProfile(for: "заметки").diversityEnabled, "выключатель ничего не стирает")
    }

    /// A collection recreated under the same name is a new collection.
    func testForgettingACollectionForgetsItsSwitch() {
        let first = store()
        first.setPipelineEnabled(false, for: "заметки")
        first.removeAll(forCollection: "заметки")
        XCTAssertTrue(store().isPipelineEnabled(for: "заметки"))
    }

    /// The file gained a shape in 10.9. A build that cannot read what 10.8 wrote
    /// would answer «профилей нет» and silently untune every search.
    func testAFileFromTheBuildBeforeTheSwitchStillLoads() throws {
        let bare = """
        [{ "collectionName": "заметки", "name": "старый", "candidateMultiplier": 9 }]
        """
        try Data(bare.utf8).write(to: directory.appendingPathComponent("search-profiles.json"))

        let store = store()
        XCTAssertEqual(store.defaultProfile(for: "заметки").name, "старый")
        XCTAssertEqual(store.defaultProfile(for: "заметки").candidateMultiplier, 9)
        XCTAssertTrue(store.isPipelineEnabled(for: "заметки"))
    }

    func testAProfileSurvivesReopening() {
        var profile = SearchProfile(name: "точный", collectionName: "заметки")
        profile.candidateMultiplier = 9
        store().save(profile)

        let reopened = store().defaultProfile(for: "заметки")
        XCTAssertEqual(reopened.name, "точный")
        XCTAssertEqual(reopened.candidateMultiplier, 9)
    }

    func testOnlyOneProfilePerCollectionIsTheDefault() {
        let store = store()
        store.save(SearchProfile(name: "первый", collectionName: "заметки", isDefault: true))
        store.save(SearchProfile(name: "второй", collectionName: "заметки", isDefault: true))

        let defaults = store.profiles(for: "заметки").filter(\.isDefault)
        XCTAssertEqual(defaults.count, 1)
        XCTAssertEqual(defaults.first?.name, "второй")
    }

    func testProfilesOfOtherCollectionsAreUntouched() {
        let store = store()
        store.save(SearchProfile(name: "а", collectionName: "заметки", isDefault: true))
        store.save(SearchProfile(name: "б", collectionName: "книги", isDefault: true))

        XCTAssertEqual(store.profiles(for: "заметки").map(\.name), ["а"])
        XCTAssertEqual(store.profiles(for: "книги").map(\.name), ["б"])
    }

    func testRemovingTheDefaultLeavesTheCollectionWithOne() {
        let store = store()
        let first = store.save(SearchProfile(name: "первый", collectionName: "заметки", isDefault: true))
        store.save(SearchProfile(name: "второй", collectionName: "заметки", isDefault: false))

        store.remove(id: first.id)

        let remaining = store.profiles(for: "заметки")
        XCTAssertEqual(remaining.count, 1)
        XCTAssertTrue(remaining[0].isDefault, "поиск не должен молча вернуться к ненастроенному профилю")
    }

    func testProfilesOfADeletedCollectionGoWithIt() {
        let store = store()
        store.save(SearchProfile(name: "а", collectionName: "заметки"))
        store.save(SearchProfile(name: "б", collectionName: "книги"))

        store.removeAll(forCollection: "заметки")

        XCTAssertTrue(store.profiles(for: "заметки").isEmpty)
        XCTAssertEqual(store.profiles(for: "книги").count, 1)
    }

    // MARK: - Export and import

    func testAnImportAddsRatherThanOverwrites() throws {
        let store = store()
        let original = store.save(SearchProfile(name: "точный", collectionName: "заметки", isDefault: true))
        let data = try store.exportData([original])

        let imported = try store.importing(data, into: "книги")

        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported[0].name, "точный")
        XCTAssertEqual(imported[0].collectionName, "книги", "профиль переносится на ту коллекцию, куда его импортируют")
        XCTAssertNotEqual(imported[0].id, original.id, "тот же id перезаписал бы существующий профиль")
        XCTAssertFalse(imported[0].isDefault, "импорт не должен молча менять, чем коллекция ищет")
    }

    func testSettingsSurviveTheRoundTrip() throws {
        let store = store()
        var profile = SearchProfile(name: "пул побольше", collectionName: "заметки")
        profile.candidateMultiplier = 8
        profile.minimumCandidates = 40

        let restored = try store.importing(store.exportData([profile]), into: "заметки")

        XCTAssertEqual(restored[0].candidateMultiplier, 8)
        XCTAssertEqual(restored[0].minimumCandidates, 40)
    }

    func testAFileFromANewerBuildIsAnEmptyListRatherThanACrash() throws {
        try Data("{ не json }".utf8)
            .write(to: directory.appendingPathComponent("search-profiles.json"))
        XCTAssertTrue(store().all().isEmpty)
    }
}

/// файл профиля, записанный прошлой сборкой, должен читаться.
final class SearchProfileCompatibilityTests: XCTestCase {
    private func decode(_ json: String) throws -> SearchProfile {
        try JSONDecoder().decode(SearchProfile.self, from: Data(json.utf8))
    }

    /// Exactly what 10.1 wrote: no hierarchy, no diversity, no hybrid.
    func testAProfileFromTheFirstBuildStillLoads() throws {
        let profile = try decode("""
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "name": "старый",
          "collectionName": "заметки",
          "isDefault": true,
          "candidateMultiplier": 7,
          "minimumCandidates": 30
        }
        """)
        XCTAssertEqual(profile.name, "старый")
        XCTAssertEqual(profile.candidateMultiplier, 7)
        // Everything a later stage added takes the value a new profile has.
        XCTAssertEqual(profile.promotion, .parent)
        XCTAssertFalse(profile.diversityEnabled)
        XCTAssertFalse(profile.textSearchEnabled)
        XCTAssertNil(profile.contextWindow)
    }

    /// The failure this test exists for: a tuned profile that stops decoding
    /// turns the search back into the default one without a word.
    func testOnlyTheCollectionIsRequired() throws {
        let profile = try decode(#"{ "collectionName": "заметки" }"#)
        XCTAssertEqual(profile.collectionName, "заметки")
        XCTAssertEqual(profile.candidateMultiplier, 5)
    }

    func testWhatIsWrittenIsReadBackUnchanged() throws {
        var original = SearchProfile(name: "всё включено", collectionName: "к")
        original.textSearchEnabled = true
        original.vectorWeight = 2.5
        original.fusionK = 12
        original.splitQueryIntoWords = true
        original.diversityEnabled = true
        original.diversityLambda = 0.42
        original.contextWindow = 3
        original.promotion = .both
        original.searchLevel = .all
        original.collapseByParent = false

        let encoder = JSONEncoder()
        let restored = try JSONDecoder().decode(SearchProfile.self, from: encoder.encode(original))
        XCTAssertEqual(restored, original)
    }
}
