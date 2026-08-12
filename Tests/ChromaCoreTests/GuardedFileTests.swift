import XCTest
@testable import ChromaCore

/// то же правило, что и для настроек, для всех остальных файлов
/// пользовательской работы: не смог прочитать — не пиши поверх.
final class GuardedFileTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-guarded-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Права возвращаются до удаления: каталог с файлом 000 иначе не убрать.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: root.appendingPathComponent(name).path
            )
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func file(_ name: String = "данные.json") -> GuardedJSONFile<[String]> {
        GuardedJSONFile(url: root.appendingPathComponent(name), category: "Тест")
    }

    private func unreadable(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    }

    // MARK: - Три исхода чтения

    func testAMissingFileIsAnOrdinaryFirstRun() {
        let file = self.file()
        guard case .fresh = file.read() else { return XCTFail("файла нет — это не авария") }
        XCTAssertNil(file.problem)
        XCTAssertTrue(file.write(["первый"]))
        XCTAssertEqual(file.value(or: []), ["первый"])
    }

    /// Главный случай: файл на месте, прочитать не вышло. Запись обязана
    /// остановиться, иначе один неудачный старт стирает работу целиком.
    func testAFileThatCannotBeReadBlocksWriting() throws {
        let file = self.file()
        XCTAssertTrue(file.write(["один", "два", "три"]))
        try unreadable(file.url)

        let reopened = self.file()
        guard case .unreadable = reopened.read() else { return XCTFail("должно быть «не прочитан»") }
        XCTAssertNotNil(reopened.problem)
        XCTAssertFalse(reopened.write([]), "запись обязана быть отклонена")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.url.path)
        XCTAssertEqual(self.file().value(or: []), ["один", "два", "три"], "файл цел")
    }

    func testAnUndecodableFileIsCopiedAsideAndAlsoBlocksWriting() throws {
        let file = self.file()
        try Data("не json".utf8).write(to: file.url)

        guard case .unreadable = file.read() else { return XCTFail("должно быть «не прочитан»") }
        XCTAssertFalse(file.write(["новое"]))
        XCTAssertEqual(try String(contentsOf: file.url, encoding: .utf8), "не json")

        let rescued = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("данные.unreadable-") }
        XCTAssertEqual(rescued.count, 1)
    }

    func testReloadingUnblocksWhenTheCauseIsGone() throws {
        let file = self.file()
        XCTAssertTrue(file.write(["один"]))
        try unreadable(file.url)

        let reopened = self.file()
        _ = reopened.read()
        XCTAssertNotNil(reopened.problem)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.url.path)
        guard case .loaded(let value) = reopened.reload() else { return XCTFail("после починки файл читается") }
        XCTAssertEqual(value, ["один"])
        XCTAssertNil(reopened.problem)
        XCTAssertTrue(reopened.write(["один", "два"]))
    }

    func testThePreviousVersionStaysBeside() {
        let file = self.file()
        file.write(["был"])
        file.write(["стал"])

        XCTAssertEqual(file.value(or: []), ["стал"])
        let previous = GuardedJSONFile<[String]>(url: file.previousURL, category: "Тест")
        XCTAssertEqual(previous.value(or: []), ["был"])
    }

    // MARK: - Хранилища, которые этим пользуются

    /// Эталон разметки — часы ручной работы. Нечитаемый файл не должен
    /// стать пустым набором, записанным поверх.
    func testGroundTruthIsNotOverwrittenWhenItsFileCannotBeRead() throws {
        let store = QuerySetStore(directory: root)
        let query = EvaluationQuery(text: "лицензия")
        let set = store.save(QuerySet(name: "приёмка", queries: [query]))
        store.mark(queryID: query.id, in: set.id, documentID: "c1", text: "Срок действия лицензии: бессрочная.", grade: .relevant)

        let url = root.appendingPathComponent("query-sets.json")
        try unreadable(url)

        let reopened = QuerySetStore(directory: root)
        XCTAssertNotNil(reopened.persistenceProblem)
        XCTAssertTrue(reopened.all().isEmpty, "прочитать не смогли — списка нет")
        reopened.save(QuerySet(name: "поверх старого"))

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let recovered = QuerySetStore(directory: root)
        XCTAssertEqual(recovered.all().map(\.name), ["приёмка"])
        XCTAssertEqual(recovered.all().first?.queries.first?.fragments.count, 1, "разметка на месте")
    }

    func testSearchProfilesSurviveAnUnreadableMoment() throws {
        let store = SearchProfileStore(directory: root)
        _ = store.save(SearchProfile(name: "точный", collectionName: "заметки", diversityEnabled: true))
        store.setPipelineEnabled(false, for: "заметки")

        let url = root.appendingPathComponent("search-profiles.json")
        try unreadable(url)

        let reopened = SearchProfileStore(directory: root)
        XCTAssertNotNil(reopened.persistenceProblem)
        _ = reopened.save(SearchProfile(name: "пустой", collectionName: "другая"))

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let recovered = SearchProfileStore(directory: root)
        XCTAssertEqual(recovered.profiles(for: "заметки").map(\.name), ["точный"])
        XCTAssertFalse(recovered.isPipelineEnabled(for: "заметки"), "выключатель тоже на месте")
    }

    /// Файл профилей, записанный сборкой до появления выключателя, — просто
    /// список. Он обязан читаться, иначе настроенный поиск молча станет другим.
    func testAProfileFileFromAnOlderBuildStillReads() throws {
        let profile = SearchProfile(name: "старый", collectionName: "к", diversityEnabled: true)
        let encoder = JSONEncoder()
        try encoder.encode([profile]).write(to: root.appendingPathComponent("search-profiles.json"))

        let store = SearchProfileStore(directory: root)
        XCTAssertEqual(store.profiles(for: "к").map(\.name), ["старый"])
        XCTAssertTrue(store.isPipelineEnabled(for: "к"))
    }

    func testSavedFiltersAndSchemasKeepTheirFormats() throws {
        let filters = SavedFilterStore(directory: root)
        _ = filters.save(
            name: "прошлый год",
            filter: DocumentFilter(conditions: [MetadataCondition(field: "year", op: .equals, value: "2025")]),
            collectionName: "к"
        )
        XCTAssertEqual(SavedFilterStore(directory: root).filters(for: "к").map(\.name), ["прошлый год"])
    }

    // MARK: - Мгновение чужой записи (найдено по журналу приложения 11 августа)

    func testAFileThatBecomesValidIsReadRatherThanCondemned() throws {
        // Разбор повторяется вместе с чтением. Раньше повторялось только
        // открытие файла, и содержимое, попавшееся в момент чужой записи,
        // выключало сохранение на всю сессию — вместе со всем, что было
        // измерено за неё.
        let url = root.appendingPathComponent("гонка.json")
        try Data("{ обрыв".utf8).write(to: url)

        // Файл становится целым между попытками — ровно так выглядит
        // атомарная замена, попавшаяся читателю в неудачный момент.
        //
        // Момент подмены задаётся не таймером, а фабрикой декодера: она
        // вызывается на каждой попытке, и первый её вызов приходится уже
        // после того, как первая попытка прочитала обрывок. Так первая
        // попытка гарантированно видит испорченное, вторая — целое, и тест
        // не зависит от того, насколько загружена машина. С таймером здесь
        // был запас в 40 мс, то есть ложное падение на верном коде.
        let attempts = Counter()
        let file = GuardedJSONFile<[String]>(url: url, category: "Тест", decoder: {
            if attempts.next() == 1 {
                try? Data(#"["восстановлено"]"#.utf8).write(to: url, options: .atomic)
            }
            return JSONDecoder()
        })

        guard case .loaded(let value) = file.read() else {
            return XCTFail("файл стал читаемым до конца повторов — его надо прочитать")
        }
        XCTAssertGreaterThan(attempts.value, 1, "повтор обязан был случиться")
        XCTAssertEqual(value, ["восстановлено"])
        XCTAssertNil(file.problem, "сохранение не должно оставаться выключенным")
        XCTAssertTrue(file.write(["дальше"]))
    }

    func testAGenuinelyBrokenFileStaysBrokenAfterTheRetries() throws {
        // Обратная сторона: повтор не должен превращать испорченный файл
        // в «наверное, обойдётся».
        let url = root.appendingPathComponent("сломан.json")
        try Data("{ это не json".utf8).write(to: url)

        let file = GuardedJSONFile<[String]>(url: url, category: "Тест")
        guard case .unreadable = file.read() else {
            return XCTFail("испорченный файл обязан остаться испорченным")
        }
        XCTAssertNotNil(file.problem)
        XCTAssertFalse(file.write(["затирание"]), "поверх нечитаемого не пишем")
        XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), "{ это не json")
    }

    func testTheRescueCopyIsNotDuplicatedOnEveryLaunch() throws {
        // Каждый запуск с испорченным файлом плодил ещё один одинаковый
        // слепок, и каталог зарастал.
        let url = root.appendingPathComponent("слепки.json")
        try Data("{ сломано".utf8).write(to: url)

        for _ in 0..<3 {
            _ = GuardedJSONFile<[String]>(url: url, category: "Тест").read()
        }
        let copies = try FileManager.default
            .contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("слепки.unreadable-") }
        XCTAssertEqual(copies.count, 1, "копий одного и того же содержимого хватит одной: \(copies)")
    }

    // MARK: - Повтор чтения

    /// Отсутствующего файла ждать незачем — и это самый частый случай.
    ///
    /// Повтор со сном заведён под файл, застигнутый на середине записи: тот
    /// через полсотни миллисекунд дочитается. Файл, которого нет, за это время
    /// не появится, а сон отрабатывал оба раза — сто миллисекунд на каждый
    /// вызов. На экране источников это складывалось в две секунды застывшего
    /// окна: двадцать источников, у каждого спрашивали манифест таблиц,
    /// которого почти ни у кого нет.
    ///
    /// Проверяется временем, потому что дефект и был во времени: подсчётом
    /// вызовов его не отличить от исправного поведения.
    func testAMissingFileIsNotWaitedFor() {
        let missing = root.appendingPathComponent("никогда-не-было.json")
        let started = Date()
        XCTAssertNil(GuardedJSONFile<[String]>.readDataWithRetry(at: missing))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(
            elapsed, 0.05,
            "отсутствующий файл читается сразу, а не через два сна по 50 мс (было \(Int(elapsed * 1000)) мс)"
        )
    }

    /// А существующий по-прежнему читается.
    func testAnExistingFileIsStillRead() throws {
        let url = root.appendingPathComponent("есть.json")
        try Data(#"["а"]"#.utf8).write(to: url)
        XCTAssertEqual(GuardedJSONFile<[String]>.readDataWithRetry(at: url), try Data(contentsOf: url))
    }

    /// И нечитаемый существующий — тот случай, ради которого повтор и есть, —
    /// по-прежнему проходит через все попытки, а не отбрасывается сразу.
    func testAnUnreadableFileStillGoesThroughTheRetries() throws {
        let url = root.appendingPathComponent("закрытый.json")
        try Data(#"["а"]"#.utf8).write(to: url)
        try unreadable(url)

        let started = Date()
        XCTAssertNil(GuardedJSONFile<[String]>.readDataWithRetry(at: url))
        XCTAssertGreaterThan(
            Date().timeIntervalSince(started), 0.09,
            "файл на месте, но не читается — вот его и стоит подождать"
        )
    }
}

/// Счётчик вызовов из замыкания, которое зовут не из потока теста.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value = 0

    /// Номер этого вызова, начиная с единицы.
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
