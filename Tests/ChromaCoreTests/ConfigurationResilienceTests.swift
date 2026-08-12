import XCTest
@testable import ChromaCore

/// A configuration file is the user's own record of their work. Losing it to a
/// decoding problem is worse than any feature this app has.
@MainActor
final class ConfigurationResilienceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The case that actually happened: one source the decoder cannot read used
    /// to take every other source with it, because the array was decoded as a
    /// unit and the failure was swallowed.
    func testOneUnreadableSourceDoesNotTakeTheOthersWithIt() throws {
        let json = """
        {
          "mode": "localDatabase",
          "dataSources": [
            {"id": "AAAAAAAA-0000-0000-0000-000000000001", "name": "первый",
             "path": "/tmp/a", "collectionName": "a"},
            {"name": "сломанный, без id", "path": "/tmp/b", "collectionName": "b"},
            {"id": "AAAAAAAA-0000-0000-0000-000000000003", "name": "третий",
             "path": "/tmp/c", "collectionName": "c"}
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let configuration = try decoder.decode(AppConfiguration.self, from: Data(json.utf8))

        XCTAssertEqual(configuration.dataSources.map(\.name), ["первый", "третий"])
    }

    func testAWholeUnreadableConfigIsKeptAsideInsteadOfBeingLost() throws {
        let url = root.appendingPathComponent("config.json")
        try Data("{ это не json".utf8).write(to: url)

        var logged: [String] = []
        let loaded = SettingsStore.load(from: url) { _, _, message in logged.append(message) }

        XCTAssertNil(loaded, "нечитаемый файл не притворяется прочитанным")
        let rescued = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("config.unreadable-") }
        XCTAssertEqual(rescued.count, 1, "копия должна остаться на диске")
        XCTAssertTrue(logged.contains { $0.contains("не читается") }, "и об этом должно быть сказано")
    }

    func testAMissingConfigIsSimplyAbsent() throws {
        var logged: [String] = []
        let loaded = SettingsStore.load(from: root.appendingPathComponent("nothing.json")) { _, _, message in
            logged.append(message)
        }
        XCTAssertNil(loaded)
        XCTAssertTrue(logged.isEmpty, "отсутствие файла — не авария")
    }

    // MARK: - Файл есть, но прочитать его не удалось

    private func write(_ configuration: AppConfiguration, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(configuration).write(to: url)
    }

    private func threeSources() -> AppConfiguration {
        var configuration = AppConfiguration()
        configuration.dataSources = [
            DataSource(name: "untitled folder", path: "/tmp/a", collectionName: "a"),
            DataSource(name: "test", path: "/tmp/b", collectionName: "b"),
            DataSource(name: "new test", path: "/tmp/c", collectionName: "c"),
        ]
        return configuration
    }

    /// **Тот самый случай.** Файл на месте, прочитать его в этот миг не вышло —
    /// и приложение стартовало с настройками по умолчанию, а через триста
    /// миллисекунд записало их поверх. Три источника исчезли без единой строчки
    /// в логе. Теперь такой старт не сохраняет ничего.
    func testAConfigThatCouldNotBeReadIsNotOverwrittenByDefaults() async throws {
        let url = root.appendingPathComponent("config.json")
        try write(threeSources(), to: url)
        // Права, при которых файл существует, но не открывается на чтение, —
        // самый простой способ воспроизвести то же условие, что и гонка с
        // атомарной заменой файла.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        let store = SettingsStore(fileURL: url) { _, _, _ in }
        XCTAssertNotNil(store.persistenceProblem, "нечитаемый файл обязан выключить сохранение")

        store.configuration.dataSources.append(
            DataSource(name: "new new test", path: "/tmp/d", collectionName: "d")
        )
        store.saveNow()
        try await Task.sleep(nanoseconds: 500_000_000)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let onDisk = try XCTUnwrap(SettingsStore.load(from: url))
        XCTAssertEqual(
            onDisk.dataSources.map(\.name),
            ["untitled folder", "test", "new test"],
            "файл на диске обязан остаться нетронутым"
        )
    }

    /// А когда причина устранена — файл перечитывается, и сохранение снова
    /// работает. Настройки с диска побеждают умолчания, на которых стартовали.
    func testReloadingAfterTheProblemIsFixedBringsTheSettingsBack() throws {
        let url = root.appendingPathComponent("config.json")
        try write(threeSources(), to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        let store = SettingsStore(fileURL: url) { _, _, _ in }
        XCTAssertTrue(store.configuration.dataSources.isEmpty)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertTrue(store.reload())
        XCTAssertNil(store.persistenceProblem)
        XCTAssertEqual(store.configuration.dataSources.count, 3)
    }

    /// Нечитаемый **по содержимому** файл тоже перестаёт быть поводом писать
    /// поверх него: копия рядом была, а сам файл всё равно затирался.
    func testAnUndecodableConfigAlsoStopsSaving() throws {
        let url = root.appendingPathComponent("config.json")
        try Data("{ это не json".utf8).write(to: url)

        let store = SettingsStore(fileURL: url) { _, _, _ in }
        XCTAssertNotNil(store.persistenceProblem)

        store.configuration.notificationsEnabled = true
        store.saveNow()

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{ это не json")
    }

    /// Отсутствие файла — не авария: первый запуск обязан сохраняться.
    func testAFirstLaunchSavesNormally() throws {
        let url = root.appendingPathComponent("config.json")
        let store = SettingsStore(fileURL: url) { _, _, _ in }
        XCTAssertNil(store.persistenceProblem)

        store.configuration.dataSources = [DataSource(name: "первый", path: "/tmp/a", collectionName: "a")]
        store.saveNow()

        XCTAssertEqual(SettingsStore.load(from: url)?.dataSources.map(\.name), ["первый"])
    }

    /// Предыдущая версия файла остаётся рядом — чтобы «верни, как было минуту
    /// назад» имело ответ, что бы ни случилось.
    func testThePreviousVersionIsKeptBesideTheCurrentOne() throws {
        let url = root.appendingPathComponent("config.json")
        let store = SettingsStore(fileURL: url) { _, _, _ in }
        store.configuration = threeSources()
        store.saveNow()

        store.configuration.dataSources.removeAll()
        store.saveNow()

        XCTAssertTrue(SettingsStore.load(from: url)?.dataSources.isEmpty ?? false)
        let previous = try XCTUnwrap(SettingsStore.load(from: store.previousFileURL))
        XCTAssertEqual(previous.dataSources.count, 3, "прошлая версия обязана пережить запись")
    }

    /// The everyday case must keep working exactly as before.
    func testAnOrdinaryConfigRoundTrips() throws {
        var configuration = AppConfiguration()
        configuration.dataSources = [
            DataSource(name: "книги", path: "/tmp/books", collectionName: "books", includeDocumentMetadata: true),
        ]
        let url = root.appendingPathComponent("config.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(configuration).write(to: url)

        let loaded = try XCTUnwrap(SettingsStore.load(from: url))
        XCTAssertEqual(loaded.dataSources.map(\.name), ["книги"])
        XCTAssertEqual(loaded.dataSources.first?.includeDocumentMetadata, true)
    }
}

/// §D2.5 — переключатель «весь MCP-сервер только на чтение».
final class MCPReadOnlySettingTests: XCTestCase {
    /// Конфигурация, написанная до появления поля, не должна включать режим
    /// сама: иначе у агента однажды молча пропадёт запись.
    func testAnOlderConfigLeavesTheSwitchOff() throws {
        let json = Data(#"{"mode":"local","proxyPort":8900}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let configuration = try decoder.decode(AppConfiguration.self, from: json)
        XCTAssertFalse(configuration.mcpReadOnly)
    }

    func testTheSwitchSurvivesTheRoundTrip() throws {
        var configuration = AppConfiguration()
        configuration.mcpReadOnly = true

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(AppConfiguration.self, from: try encoder.encode(configuration))

        XCTAssertTrue(restored.mcpReadOnly)
    }
}
