import XCTest
@testable import ChromaCore

/// Умолчания нарезки — по одному набору на стратегию.
///
/// Заводится папка за папкой, и каждый раз одни и те же числа выставляются
/// заново. Умолчание есть всегда — вопрос лишь в том, чьё оно.
final class ChunkingDefaultsTests: XCTestCase {
    private func configuration(size: Int, strategy: ChunkStrategy) -> ChunkingConfiguration {
        var chunking = ChunkingConfiguration()
        chunking.strategy = strategy
        chunking.chunkSize = size
        return chunking
    }

    func testWithoutOwnDefaultsTheFactoryValuesAreOffered() {
        let settings = AppConfiguration()
        XCTAssertFalse(settings.hasOwnChunkingDefault(for: .semantic))
        let offered = settings.chunkingDefault(for: .semantic)
        XCTAssertEqual(offered.strategy, .semantic)
        XCTAssertEqual(offered.chunkSize, ChunkingConfiguration().chunkSize)
    }

    /// Каждая стратегия помнит своё: переключение туда-обратно не должно
    /// возвращать заводские 512 токенов тому, кто уже настроил стратегию
    /// под свои документы.
    func testEachStrategyKeepsItsOwnNumbers() {
        var settings = AppConfiguration()
        settings.setChunkingDefault(configuration(size: 1024, strategy: .documentBased))
        settings.setChunkingDefault(configuration(size: 256, strategy: .semantic))

        XCTAssertEqual(settings.chunkingDefault(for: .documentBased).chunkSize, 1024)
        XCTAssertEqual(settings.chunkingDefault(for: .semantic).chunkSize, 256)
        XCTAssertEqual(settings.chunkingDefault(for: .fixed).chunkSize, ChunkingConfiguration().chunkSize)
    }

    /// «Сделать умолчанием» означает и «заводить новые источники так».
    func testMakingADefaultAlsoChoosesTheStrategyForNewSources() {
        var settings = AppConfiguration()
        settings.setChunkingDefault(configuration(size: 900, strategy: .hierarchical))

        let forNew = settings.chunkingDefaultForNewSources
        XCTAssertEqual(forNew.strategy, .hierarchical)
        XCTAssertEqual(forNew.chunkSize, 900)
    }

    /// «Забыть умолчание» возвращает заводские числа, но не переключает
    /// стратегию новых источников: убрать свои значения и остаться на этой
    /// стратегии — обычное желание.
    func testForgettingADefaultKeepsTheStrategyForNewSources() {
        var settings = AppConfiguration()
        settings.setChunkingDefault(configuration(size: 900, strategy: .adaptive))
        settings.clearChunkingDefault(for: .adaptive)

        XCTAssertFalse(settings.hasOwnChunkingDefault(for: .adaptive))
        XCTAssertEqual(settings.defaultChunkingStrategy, .adaptive)
        XCTAssertEqual(settings.chunkingDefaultForNewSources.chunkSize, ChunkingConfiguration().chunkSize)
    }

    /// Запись под ключом «semantic», внутри которой стоит другая стратегия,
    /// читается как параметры semantic — а не переключает стратегию молча.
    func testTheKeyDecidesTheStrategyNotTheStoredField() {
        var settings = AppConfiguration()
        settings.chunkingDefaults["semantic"] = configuration(size: 300, strategy: .fixed)
        let offered = settings.chunkingDefault(for: .semantic)
        XCTAssertEqual(offered.strategy, .semantic)
        XCTAssertEqual(offered.chunkSize, 300)
    }

    // MARK: - Хранение

    func testDefaultsSurviveASaveAndLoad() throws {
        var settings = AppConfiguration()
        settings.setChunkingDefault(configuration(size: 777, strategy: .recursive))
        let restored = try JSONDecoder().decode(
            AppConfiguration.self, from: try JSONEncoder().encode(settings)
        )
        XCTAssertEqual(restored.chunkingDefault(for: .recursive).chunkSize, 777)
        XCTAssertEqual(restored.defaultChunkingStrategy, .recursive)
    }

    func testAConfigurationWrittenBeforeThisFeatureStillReads() throws {
        let json = #"{"mode":"localDatabase"}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppConfiguration.self, from: json)
        XCTAssertTrue(settings.chunkingDefaults.isEmpty)
        XCTAssertNil(settings.defaultChunkingStrategy)
        XCTAssertEqual(settings.chunkingDefaultForNewSources.strategy, ChunkingConfiguration().strategy)
    }

    /// Один испорченный набор не уносит умолчания остальных стратегий.
    func testOneUnreadableEntryDoesNotTakeTheOthers() throws {
        let good = String(
            data: try JSONEncoder().encode(configuration(size: 640, strategy: .fixed)),
            encoding: .utf8
        )!
        let json = "{\"chunkingDefaults\":{\"fixed\":\(good),\"semantic\":42}}"
        let settings = try JSONDecoder().decode(AppConfiguration.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(settings.chunkingDefault(for: .fixed).chunkSize, 640)
        XCTAssertFalse(settings.hasOwnChunkingDefault(for: .semantic))
    }

    // MARK: - Перенос настроек

    func testTransferCarriesTheDefaults() throws {
        var settings = AppConfiguration()
        settings.setChunkingDefault(configuration(size: 333, strategy: .documentBased))
        let bundle = SettingsTransfer.export(
            configuration: settings, schemas: [:], savedFilters: [], appVersion: "test"
        )
        let decoded = try SettingsTransfer.decode(try SettingsTransfer.encode(bundle))

        var target = AppConfiguration()
        var schemas: [String: MetadataSchema] = [:]
        var filters: [SavedFilter] = []
        SettingsTransfer.apply(decoded, to: &target, schemas: &schemas, savedFilters: &filters, includePreferences: true)
        XCTAssertEqual(target.chunkingDefault(for: .documentBased).chunkSize, 333)
        XCTAssertEqual(target.defaultChunkingStrategy, .documentBased)
    }

    /// Файл, записанный старой сборкой, не стирает здешние умолчания:
    /// «поля нет» — это не «умолчаний нет».
    func testAnOlderSettingsFileDoesNotWipeTheDefaults() throws {
        var here = AppConfiguration()
        here.setChunkingDefault(configuration(size: 128, strategy: .fixed))

        let bundle = SettingsTransfer.export(
            configuration: AppConfiguration(), schemas: [:], savedFilters: [], appVersion: "test"
        )
        var object = try JSONSerialization.jsonObject(with: try SettingsTransfer.encode(bundle)) as! [String: Any]
        var preferences = object["preferences"] as! [String: Any]
        preferences.removeValue(forKey: "chunkingDefaults")
        preferences.removeValue(forKey: "defaultChunkingStrategy")
        object["preferences"] = preferences

        let decoded = try SettingsTransfer.decode(try JSONSerialization.data(withJSONObject: object))
        var schemas: [String: MetadataSchema] = [:]
        var filters: [SavedFilter] = []
        SettingsTransfer.apply(decoded, to: &here, schemas: &schemas, savedFilters: &filters, includePreferences: true)
        XCTAssertEqual(here.chunkingDefault(for: .fixed).chunkSize, 128)
    }
}
