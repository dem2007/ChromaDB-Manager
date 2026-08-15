import XCTest
@testable import ChromaCore

/// Профили сопоставления, общие для всех источников.
///
/// Вопрос, из которого это выросло: профили хранились у источника, и та же
/// самая книга в другой папке размечалась заново, слово в слово. Область
/// теперь выбирается при сохранении — и выбор обязан доезжать до прогона,
/// а не только до экрана.
final class SharedTableProfileTests: XCTestCase {
    private func profile(_ name: String, id: UUID = UUID(), column: String = "Название") -> TableProfile {
        TableProfile(
            id: id, name: name,
            mapping: TableMapping(
                sheetName: "Лист1", mode: .dataTable, headerRow: 1,
                columns: ["Артикул", column], roles: [column: .text, "Артикул": .metadata],
                keyColumn: "Артикул"
            )
        )
    }

    // MARK: - Что видит источник

    func testASourceSeesItsOwnProfilesAndTheSharedOnes() {
        let own = profile("свой")
        let shared = profile("общий")
        let resolved = TableProfile.resolved(own: [own], shared: [shared])
        XCTAssertEqual(resolved.map(\.name), ["свой", "общий"], "свои впереди — они точнее")
    }

    /// Одноимённый общий отбрасывается, а не добавляется вторым.
    ///
    /// Иначе на лист претендовали бы два профиля — это `.ambiguous`, при
    /// котором лист не индексируется вовсе. Правка общего профиля не должна
    /// ломать источник, у которого есть своя версия той же разметки.
    func testAnOwnProfileWinsOverASharedOneOfTheSameName() {
        let own = profile("отчёт ФЭО", column: "Наименование")
        let shared = profile("отчёт ФЭО", column: "Название")
        let resolved = TableProfile.resolved(own: [own], shared: [shared])
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.variants.first?.mapping.columns, ["Артикул", "Наименование"])
    }

    /// Тот же профиль, переехавший из источника в общие, не должен
    /// удвоиться: `id` при смене области сохраняется, чтобы уцелели
    /// назначения файлов.
    func testTheSameProfileByIDIsNotCountedTwice() {
        let id = UUID()
        let resolved = TableProfile.resolved(
            own: [profile("а", id: id)], shared: [profile("б", id: id)]
        )
        XCTAssertEqual(resolved.count, 1)
    }

    func testNamesAreComparedWithoutCaseAndSpacing() {
        let resolved = TableProfile.resolved(
            own: [profile("Отчёт ФЭО")], shared: [profile("  отчёт фэо ")]
        )
        XCTAssertEqual(resolved.count, 1, "«Отчёт ФЭО» и «отчёт фэо» — один и тот же профиль для человека")
    }

    // MARK: - Дорога до прогона

    /// Служба синхронизации обязана читать источник общими профилями тоже:
    /// иначе выбор «у всего приложения» остаётся украшением экрана.
    func testTheSyncServiceReadsASourceWithSharedProfiles() async {
        let service = SourceSyncService()
        let source = DataSource(name: "Папка", path: "/tmp", collectionName: "c")
        var seen = await service.tableProfiles(of: source)
        XCTAssertTrue(seen.isEmpty)

        await service.adopt(sharedTableProfiles: [profile("общий")])
        seen = await service.tableProfiles(of: source)
        XCTAssertEqual(seen.map(\.name), ["общий"])
    }

    /// Изменение общего профиля меняет подпись профилей источника — а значит
    /// файлы, разобранные прежней разметкой, попадут на пересмотр.
    func testChangingASharedProfileChangesTheSignature() async {
        let service = SourceSyncService()
        let source = DataSource(name: "Папка", path: "/tmp", collectionName: "c")

        await service.adopt(sharedTableProfiles: [profile("общий", column: "Название")])
        let before = TableSyncService.profilesSignature(await service.tableProfiles(of: source))
        await service.adopt(sharedTableProfiles: [profile("общий", column: "Наименование")])
        let after = TableSyncService.profilesSignature(await service.tableProfiles(of: source))

        XCTAssertNotEqual(before, after, "иначе файл останется прочитанным по-старому и никто об этом не скажет")
    }

    // MARK: - Хранение

    func testSharedProfilesSurviveASaveAndLoad() throws {
        var configuration = AppConfiguration()
        configuration.sharedTableProfiles = [profile("общий")]
        let data = try JSONEncoder().encode(configuration)
        let restored = try JSONDecoder().decode(AppConfiguration.self, from: data)
        XCTAssertEqual(restored.sharedTableProfiles.map(\.name), ["общий"])
    }

    /// Конфигурация, записанная до, ключа не содержит — и это пустой
    /// список, а не отказ прочитать настройки целиком.
    func testAConfigurationWrittenBeforeThisFeatureStillReads() throws {
        let json = #"{"mode":"localDatabase","proxyPort":8900}"#.data(using: .utf8)!
        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: json)
        XCTAssertTrue(configuration.sharedTableProfiles.isEmpty)
    }

    /// Один нечитаемый общий профиль не уносит остальные.
    func testOneUnreadableSharedProfileDoesNotTakeTheOthers() throws {
        let good = try JSONEncoder().encode(profile("живой"))
        let json = "{\"sharedTableProfiles\":[{\"nonsense\":1},\(String(data: good, encoding: .utf8)!)]}"
        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(configuration.sharedTableProfiles.map(\.name), ["живой"])
    }

    /// Пропажа общих профилей — такая же потеря, как пропажа источника:
    /// это ручная работа человека, и молча она исчезать не должна.
    func testLosingSharedProfilesIsCountedAsALoss() {
        var old = AppConfiguration()
        old.sharedTableProfiles = [profile("а"), profile("б")]
        let loss = ConfigurationLoss.between(old, AppConfiguration())
        XCTAssertEqual(loss.tableProfiles, 2)
        XCTAssertTrue(loss.isAlarming)
        XCTAssertTrue(loss.summary.contains("общих профилей таблиц"), loss.summary)
    }

    // MARK: - Перенос настроек

    func testTransferCarriesSharedProfiles() throws {
        var configuration = AppConfiguration()
        configuration.sharedTableProfiles = [profile("общий")]
        let bundle = SettingsTransfer.export(
            configuration: configuration, schemas: [:], savedFilters: [], appVersion: "test"
        )
        let decoded = try SettingsTransfer.decode(try SettingsTransfer.encode(bundle))

        var target = AppConfiguration()
        var schemas: [String: MetadataSchema] = [:]
        var filters: [SavedFilter] = []
        let plan = SettingsTransfer.plan(
            for: decoded, configuration: target, schemas: schemas, savedFilters: filters
        )
        XCTAssertEqual(plan.tableProfiles.added, 1, "человек обязан увидеть их в плане импорта до импорта")

        SettingsTransfer.apply(decoded, to: &target, schemas: &schemas, savedFilters: &filters, includePreferences: false)
        XCTAssertEqual(target.sharedTableProfiles.map(\.name), ["общий"])
    }

    /// Файл настроек, записанный до, читается по-прежнему: отсутствие
    /// ключа — это пустой список, а не «файл не читается».
    func testASettingsFileWithoutTheFieldStillImports() throws {
        var configuration = AppConfiguration()
        configuration.sharedTableProfiles = [profile("общий")]
        let bundle = SettingsTransfer.export(
            configuration: configuration, schemas: [:], savedFilters: [], appVersion: "test"
        )
        var object = try JSONSerialization.jsonObject(
            with: try SettingsTransfer.encode(bundle)
        ) as! [String: Any]
        object.removeValue(forKey: "sharedTableProfiles")

        let decoded = try SettingsTransfer.decode(try JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.sharedTableProfiles)

        var target = AppConfiguration()
        target.sharedTableProfiles = [profile("здешний")]
        var schemas: [String: MetadataSchema] = [:]
        var filters: [SavedFilter] = []
        SettingsTransfer.apply(decoded, to: &target, schemas: &schemas, savedFilters: &filters, includePreferences: false)
        XCTAssertEqual(target.sharedTableProfiles.map(\.name), ["здешний"], "импорт ничего не удаляет")
    }
}
