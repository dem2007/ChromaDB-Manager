import XCTest
@testable import ChromaCore

/// Как настройки потерялись целиком и почему это не могло быть замечено.
///
/// Приложение объявляло «первый запуск» по одному взгляду на файловую систему.
/// Атомарная запись на доли миллисекунды убирает старый файл; второй экземпляр
/// приложения, стартующий ровно в этот миг, видел пустоту, начинал с настроек
/// по умолчанию и через полсекунды сохранял их поверх. Ни ошибки, ни копии,
/// ни следа в журнале: файл читался прекрасно — просто в одну миллисекунду его
/// не было.
///
/// Проверено на живой машине: четыре запуска за двадцать пять секунд, и
/// одиннадцать источников данных исчезли.
@MainActor
final class ConfigurationLossTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-loss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var configURL: URL { directory.appendingPathComponent("config.json") }
    private var previousURL: URL { directory.appendingPathComponent("config.previous.json") }

    private func configuration(sources: Int) -> AppConfiguration {
        var configuration = AppConfiguration()
        configuration.dataSources = (0..<sources).map {
            DataSource(
                name: "источник \($0)", path: "/tmp/\($0)", fileExtensions: ["md"],
                recursive: true, mapping: .folderToCollection,
                collectionName: "c\($0)", embeddingModel: "e5"
            )
        }
        return configuration
    }

    private func write(_ configuration: AppConfiguration, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(configuration).write(to: url, options: .atomic)
    }

    /// Настоящий первый запуск: ни файла, ни копии. Здесь пустые настройки —
    /// правильный ответ.
    func testARealFirstLaunchStartsEmpty() {
        guard case .fresh = SettingsStore.read(from: configURL) else {
            return XCTFail("без файла и без копии это первый запуск")
        }
    }

    /// А вот это — не первый запуск, что бы ни говорила файловая система.
    ///
    /// Копия «как было» существует, значит файл был. Его отсутствие сейчас —
    /// беда, а не чистая машина, и объявлять его отсутствие первым запуском
    /// значит разрешить себе затереть чужие настройки.
    func testAMissingFileWithABackupIsNotAFirstLaunch() throws {
        try write(configuration(sources: 11), to: previousURL)

        // Отдельный случай, а не `loaded`: человеку надо сказать, что он
        // смотрит не на свой файл, а на его копию.
        guard case .recovered(let recovered) = SettingsStore.read(from: configURL) else {
            return XCTFail("настройки обязаны подняться из копии, а не начаться с нуля")
        }
        XCTAssertEqual(recovered.dataSources.count, 11, "источники обязаны вернуться все")
    }

    /// И хранилище обязано об этом сказать, а не поднять настройки молча.
    func testTheStoreSaysOutLoudThatItReadACopy() throws {
        try write(configuration(sources: 11), to: previousURL)

        let store = SettingsStore(fileURL: configURL)
        XCTAssertTrue(store.recoveredFromPreviousCopy, "подъём из копии — событие, а не деталь")

        store.acknowledgeRecovery()
        XCTAssertFalse(store.recoveredFromPreviousCopy)
    }

    /// Обычное чтение своего файла никого не тревожит.
    func testAnOrdinaryReadRaisesNothing() throws {
        try write(configuration(sources: 3), to: configURL)
        let store = SettingsStore(fileURL: configURL)
        XCTAssertFalse(store.recoveredFromPreviousCopy)
        XCTAssertNil(store.loss)
    }

    /// И главное: хранилище, стартовавшее в такой миг, не должно записать
    /// пустоту поверх.
    func testTheStoreDoesNotOverwriteWithDefaultsAfterAMomentaryDisappearance() throws {
        try write(configuration(sources: 11), to: previousURL)

        let store = SettingsStore(fileURL: configURL)
        XCTAssertEqual(store.configuration.dataSources.count, 11)

        // Любое изменение приводит к записи — и записаться должно то, что
        // подняли, а не умолчания.
        store.configuration.notificationsEnabled.toggle()
        store.saveNow()

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let written = try decoder.decode(AppConfiguration.self, from: Data(contentsOf: configURL))
        XCTAssertEqual(written.dataSources.count, 11, "сохранение не смеет обеднять настройки")
    }

    // MARK: - Запись, уносящая записи, объявляется вслух

    /// Главное: запись, после которой источников стало меньше, не проходит
    /// молча. Она разрешена — человек вправе удалить всё, — но оставляет
    /// снимок и говорит об этом.
    func testAWriteThatLosesSeveralEntriesAnnouncesItselfAndKeepsASnapshot() throws {
        try write(configuration(sources: 11), to: configURL)
        let store = SettingsStore(fileURL: configURL)

        store.configuration.dataSources.removeFirst(9)
        store.saveNow()

        let notice = try XCTUnwrap(store.loss, "потеря девяти источников обязана быть замечена")
        XCTAssertEqual(notice.loss.sources, 9)
        XCTAssertTrue(notice.message.contains("источников: 9"), notice.message)

        // Снимок — это прежние настройки целиком, а не то, что записали.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try XCTUnwrap(notice.snapshot, "снимок обязан быть сделан")
        let saved = try decoder.decode(AppConfiguration.self, from: Data(contentsOf: snapshot))
        XCTAssertEqual(saved.dataSources.count, 11, "в снимке лежит то, что теряется")

        // И запись всё-таки состоялась: приложение говорит, а не запрещает.
        let written = try decoder.decode(AppConfiguration.self, from: Data(contentsOf: configURL))
        XCTAssertEqual(written.dataSources.count, 2)
    }

    /// Снимок не затирается следующей такой же записью — в отличие от
    /// `config.previous.json`, которого хватает на один шаг назад. Девятого
    /// августа приложение записало обеднённые настройки четыре раза подряд,
    /// и копия «как было» к третьему разу сама стала обеднённой.
    func testASecondLosingWriteDoesNotOverwriteTheFirstSnapshot() throws {
        try write(configuration(sources: 11), to: configURL)
        let store = SettingsStore(fileURL: configURL)

        store.configuration.dataSources.removeFirst(9)
        store.saveNow()
        let first = try XCTUnwrap(XCTUnwrap(store.loss).snapshot)

        // Секунда — разрешение отметки времени в имени снимка.
        Thread.sleep(forTimeInterval: 1.1)
        store.configuration.dataSources.removeAll()
        store.saveNow()
        let second = try XCTUnwrap(XCTUnwrap(store.loss).snapshot)

        XCTAssertNotEqual(first, second, "второй снимок обязан лечь рядом, а не поверх")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let earliest = try decoder.decode(AppConfiguration.self, from: Data(contentsOf: first))
        XCTAssertEqual(earliest.dataSources.count, 11, "первый снимок остался нетронутым")
    }

    /// Сообщение не обещает файла, которого нет.
    ///
    /// Снимок пишется на диск, и диск умеет отказывать. Сообщение «прежние
    /// настройки сохранены в …», после которого файла не оказалось, хуже
    /// отсутствия сообщения: человек прочитает его и успокоится, а
    /// восстанавливать будет неоткуда.
    func testTheMessageDoesNotPromiseASnapshotThatWasNotWritten() {
        let notice = ConfigurationLossNotice(
            loss: ConfigurationLoss(sources: 9), snapshot: nil
        )
        XCTAssertTrue(notice.message.contains("сохранить не удалось"), notice.message)
        XCTAssertTrue(notice.message.contains("config.previous.json"), notice.message)
    }

    /// Одно удаление — обычная работа: человек нажал, увидел список,
    /// подтвердил. Тревожить его второй раз значит приучать не читать
    /// предупреждения.
    func testRemovingASingleSourceIsNotAnAlarm() throws {
        try write(configuration(sources: 11), to: configURL)
        let store = SettingsStore(fileURL: configURL)

        store.configuration.dataSources.removeFirst()
        store.saveNow()

        XCTAssertNil(store.loss, "одиночное удаление — не событие")
    }

    /// Считается по идентификаторам: переименование источника ничего не теряет.
    func testRenamingIsNotALoss() throws {
        try write(configuration(sources: 4), to: configURL)
        let store = SettingsStore(fileURL: configURL)

        for index in store.configuration.dataSources.indices {
            store.configuration.dataSources[index].name = "переименован \(index)"
        }
        store.saveNow()

        XCTAssertNil(store.loss)
    }

    /// Профили и клиенты считаются наравне с источниками: ключ агента потерять
    /// не менее болезненно, чем папку.
    func testProfilesAndClientsCountToo() {
        var old = AppConfiguration()
        old.serverProfiles = [
            ServerProfile(name: "первый", kind: .external, host: "127.0.0.1", port: 8000),
            ServerProfile(name: "второй", kind: .external, host: "127.0.0.1", port: 8001),
        ]
        let loss = ConfigurationLoss.between(old, AppConfiguration())
        XCTAssertEqual(loss.profiles, 2)
        XCTAssertTrue(loss.isAlarming)
        XCTAssertTrue(loss.summary.contains("профилей: 2"), loss.summary)
    }

    /// Существующий файл читается как раньше — починка не должна ничего
    /// сломать в обычном случае.
    func testAnExistingFileIsStillReadDirectly() throws {
        try write(configuration(sources: 3), to: configURL)
        try write(configuration(sources: 11), to: previousURL)

        guard case .loaded(let loaded) = SettingsStore.read(from: configURL) else {
            return XCTFail("файл на месте — читаем его")
        }
        XCTAssertEqual(loaded.dataSources.count, 3, "копия не должна подменять настоящий файл")
    }
}
