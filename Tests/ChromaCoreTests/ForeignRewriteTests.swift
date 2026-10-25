import XCTest
@testable import ChromaCore

/// настройки переписала другая (старая) сборка: уровни пропали
/// у всех источников, а записи остались на месте.
@MainActor
final class ForeignRewriteTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("foreign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var configURL: URL { directory.appendingPathComponent("config.json") }

    private func source(levels: [String]) -> DataSource {
        DataSource(
            name: "база", path: "/tmp/база", collectionName: "base",
            pathLevels: levels.map { PathLevel(key: $0) }
        )
    }

    func testTheStoreNoticesAForeignRewriteAndGivesTheWorkBack() throws {
        var mine = AppConfiguration()
        mine.dataSources = [source(levels: ["OGV", "GIS", "YEAR"])]
        // Своя запись — и своя копия рядом.
        let first = SettingsStore(fileURL: configURL)
        first.configuration = mine
        first.saveNow()
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.ownCopyURL.path))

        // Старая сборка: тот же источник, но полей из пути она не знает.
        var foreign = mine
        foreign.dataSources[0].pathLevels = []
        foreign.dataSources[0].excludedPaths = []
        foreign.dataSources[0].name = "база (переименована)"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(foreign).write(to: configURL, options: .atomic)

        let second = SettingsStore(fileURL: configURL)
        let rewrite = try XCTUnwrap(second.foreignRewrite)
        XCTAssertTrue(rewrite.lost.contains { $0.contains("поля из пути (3)") }, "\(rewrite.lost)")

        // Пока решения нет, своя копия не обновляется.
        second.configuration.notificationsEnabled.toggle()
        second.saveNow()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let kept = try decoder.decode(AppConfiguration.self, from: Data(contentsOf: second.ownCopyURL))
        XCTAssertEqual(kept.dataSources[0].pathLevels.map(\.key), ["OGV", "GIS", "YEAR"])

        second.restoreForeignLosses()
        XCTAssertNil(second.foreignRewrite)
        XCTAssertEqual(second.configuration.dataSources[0].pathLevels.map(\.key), ["OGV", "GIS", "YEAR"])
        XCTAssertEqual(second.configuration.dataSources[0].name, "база (переименована)", "изменённое не затирается")
    }

    /// Свой же файл — не чужая запись: молчание.
    func testItsOwnFileIsNotAForeignRewrite() {
        var mine = AppConfiguration()
        mine.dataSources = [source(levels: ["OGV"])]
        let first = SettingsStore(fileURL: configURL)
        first.configuration = mine
        first.saveNow()
        XCTAssertNil(SettingsStore(fileURL: configURL).foreignRewrite)
    }

    /// Чужая запись, ничего не унёсшая, — тоже молчание.
    func testAForeignWriteThatLostNothingIsQuiet() throws {
        let own = AppConfiguration()
        var current = own
        current.notificationsEnabled.toggle()
        XCTAssertTrue(ForeignRewrite.between(own: own, current: current).isEmpty)
    }

    /// Решение из «Диагностики», принятое по старой копии источника, меняет
    /// только своё поле: вписанное после того, как копию взяли, остаётся.
    func testAFieldUpdateDoesNotRollBackLaterEdits() {
        let store = SettingsStore(fileURL: configURL)
        let stale = source(levels: [])
        store.upsert(source: stale)
        var edited = stale
        edited.pathLevels = ["OGV", "GIS"].map { PathLevel(key: $0) }
        store.upsert(source: edited)

        XCTAssertTrue(store.updateSource(id: stale.id) { $0.ocrEnabled = true })
        let now = store.configuration.dataSources.first { $0.id == stale.id }
        XCTAssertEqual(now?.ocrEnabled, true)
        XCTAssertEqual(now?.pathLevels.map(\.key), ["OGV", "GIS"])
        XCTAssertFalse(store.updateSource(id: stale.id) { $0.ocrEnabled = true }, "ничего не изменилось")
        XCTAssertFalse(store.updateSource(id: UUID()) { $0.ocrEnabled = true }, "источника нет")
    }
}
