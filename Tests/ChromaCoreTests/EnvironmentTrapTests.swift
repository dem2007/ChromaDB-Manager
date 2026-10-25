import XCTest
@testable import ChromaCore

/// Ловушки среды, о которые приложение разбивается на настоящих данных
///.
///
/// Каждая проверка здесь — про случай, в котором приложение могло записать
/// в базу неправду или предложить человеку удалить целый источник, и все они
/// про **окружение**, а не про наш алгоритм: отключённый диск, файл из облака,
/// файл, который пишется прямо сейчас, ссылка наружу.
final class EnvironmentTrapTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-traps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Том источника

    func testAVolumeIsRecognisedByUUIDNotByName() {
        let disk = SourceVolume(uuid: "A", name: "Backup", mountPoint: "/Volumes/Backup")
        let renamed = SourceVolume(uuid: "A", name: "Архив", mountPoint: "/Volumes/Архив")
        XCTAssertTrue(disk.isSame(as: renamed), "человек переименовал том — это тот же диск")

        let другой = SourceVolume(uuid: "B", name: "Backup", mountPoint: "/Volumes/Backup")
        XCTAssertFalse(disk.isSame(as: другой), "то же имя и та же точка монтирования — но другой диск")
    }

    /// У сетевой шары UUID может не быть вовсе — тогда сверяются имя
    /// и точка монтирования.
    func testWithoutUUIDsTheNameAndMountPointDecide() {
        let share = SourceVolume(uuid: nil, name: "docs", mountPoint: "/Volumes/docs")
        XCTAssertTrue(share.isSame(as: SourceVolume(uuid: nil, name: "docs", mountPoint: "/Volumes/docs")))
        XCTAssertFalse(share.isSame(as: SourceVolume(uuid: nil, name: "docs", mountPoint: "/Volumes/docs-2")))
        // UUID появился — это уже не та же самая шара.
        XCTAssertFalse(share.isSame(as: SourceVolume(uuid: "A", name: "docs", mountPoint: "/Volumes/docs")))
    }

    func testAMissingFolderIsReportedAsMissingRatherThanEmpty() {
        let missing = directory.appendingPathComponent("нет-такой-папки")
        XCTAssertEqual(SourceVolume.check(path: missing.path, expected: nil), .missing)
    }

    func testARealFolderReportsItsVolume() {
        guard case .ready(let volume) = SourceVolume.check(path: directory.path, expected: nil) else {
            return XCTFail("папка существует — том обязан определиться")
        }
        XCTAssertNotNil(volume?.mountPoint)
    }

    /// Тот самый сценарий: путь на месте, а диск другой.
    func testADifferentVolumeAtTheSamePathIsRefused() {
        let expected = SourceVolume(uuid: "тот-самый-диск", name: "Backup")
        guard case .changed(let was, _) = SourceVolume.check(path: directory.path, expected: expected) else {
            return XCTFail("подмена тома обязана останавливать прогон")
        }
        XCTAssertEqual(was.uuid, "тот-самый-диск")
    }

    func testScanningRefusesWhenTheVolumeIsNotTheOneRemembered() async {
        let service = SourceSyncService()
        var source = DataSource(name: "внешний", path: directory.path, collectionName: "c")
        source.volume = SourceVolume(uuid: "другой-диск", name: "Backup")
        do {
            _ = try await service.scanFiles(source: source)
            XCTFail("сканирование чужого тома обязано отказать")
        } catch let error as SyncError {
            guard case .volumeChanged = error else { return XCTFail("не та ошибка: \(error)") }
        } catch {
            XCTFail("не та ошибка: \(error)")
        }
    }

    // MARK: - Массовая пропажа

    func testHalfTheSourceGoneIsTreatedAsAnUnmountedDisk() {
        XCTAssertNotNil(SourceSyncService.massDisappearance(missing: 8000, known: 8000))
        XCTAssertNotNil(SourceSyncService.massDisappearance(missing: 500, known: 1000))
    }

    /// Обычная работа человека порогом не считается: иначе предупреждение
    /// станет фоном, и его перестанут читать.
    func testOrdinaryEditsDoNotTripTheGuard() {
        XCTAssertNil(SourceSyncService.massDisappearance(missing: 2, known: 3), "два файла из трёх — это правка папки")
        XCTAssertNil(SourceSyncService.massDisappearance(missing: 9, known: 9), "девять файлов ниже абсолютного порога")
        XCTAssertNil(SourceSyncService.massDisappearance(missing: 100, known: 1000), "десятая часть — не массовая пропажа")
        XCTAssertNil(SourceSyncService.massDisappearance(missing: 0, known: 0))
    }

    func testTheDisappearanceCarriesItsNumbersForTheQuestion() {
        let disappearance = MassDisappearance(missing: 8000, known: 8000)
        XCTAssertEqual(disappearance.share, 1)
        XCTAssertTrue(disappearance.summary.contains("8000"), disappearance.summary)
    }

    // MARK: - Файл, который пишется прямо сейчас

    func testASmallFileIsNeverSuspect() {
        XCTAssertFalse(
            SourceSyncService.isBeingWritten(modifiedAt: Date(), size: 4096),
            "заметку редактор пишет во временный файл и переименовывает — она появляется целиком"
        )
    }

    func testABigFreshFileIsWorthASecondLook() {
        XCTAssertTrue(SourceSyncService.isBeingWritten(
            modifiedAt: Date(), size: SourceSyncService.stabilisationMinimumBytes
        ))
        let settled = Date().addingTimeInterval(-SourceSyncService.stabilisationSeconds - 1)
        XCTAssertFalse(SourceSyncService.isBeingWritten(
            modifiedAt: settled, size: 10_000_000
        ), "файл, дописанный минуту назад, ждать незачем")
    }

    /// Настоящая проверка: один файл дописывается между замерами, второй
    /// лежит неподвижно.
    func testOnlyTheFileThatKeepsGrowingIsHeldBack() async throws {
        let growing = directory.appendingPathComponent("растёт.bin")
        let settled = directory.appendingPathComponent("лежит.bin")
        let block = Data(repeating: 0x41, count: 2_000_000)
        try block.write(to: growing)
        try block.write(to: settled)

        let writer = Task.detached {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let handle = try? FileHandle(forWritingTo: growing) else { return }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(repeating: 0x42, count: 1_000_000))
            try? handle.close()
        }
        let held = await SourceSyncService.growingFiles([growing, settled])
        await writer.value

        XCTAssertTrue(held.contains(growing.path), "файл дописывали между замерами — читать его рано")
        XCTAssertFalse(held.contains(settled.path), "неподвижный файл ждать незачем")
    }

    /// Файл, который пишется, не индексируется — но и пропавшим не считается:
    /// иначе он попал бы в «требуют решения» на ровном месте.
    func testAFileBeingWrittenIsSkippedButNotConsideredMissing() async throws {
        let service = SourceSyncService(
            manifests: ManifestStore(directory: directory.appendingPathComponent("m"))
        )
        let file = directory.appendingPathComponent("большой.md")
        try Data(repeating: 0x41, count: 2_000_000).write(to: file)

        let writer = Task.detached {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(repeating: 0x42, count: 500_000))
            try? handle.close()
        }
        let source = DataSource(
            name: "папка", path: directory.path, fileExtensions: ["md"], collectionName: "c"
        )
        let plan = try await service.plan(source: source, embeddingModel: "модель")
        await writer.value

        guard let item = plan.items.first(where: { $0.relativePath == "большой.md" }) else {
            return XCTFail("файл обязан быть в плане")
        }
        guard case .skipped(let reason, let remedy) = item.kind else {
            return XCTFail("файл, который дописывают, читать рано: \(item.kind)")
        }
        XCTAssertEqual(remedy, .retry, "это не поломка файла — просто ещё рано")
        XCTAssertTrue(reason.contains("пишется"), reason)
        XCTAssertTrue(plan.newlyMissing.isEmpty)
    }

    // MARK: - Ссылки

    /// Ссылка не индексируется, даже если названа как пакет: иначе источник
    /// прочитал бы файл из-за своего корня.
    func testASymbolicLinkIsNotAnIndexableEntry() throws {
        let target = directory.appendingPathComponent("настоящий.md")
        try "текст".write(to: target, atomically: true, encoding: .utf8)
        let link = directory.appendingPathComponent("ссылка.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let packageLink = directory.appendingPathComponent("наружу.pages")
        try FileManager.default.createSymbolicLink(at: packageLink, withDestinationURL: target)

        XCTAssertTrue(SourceSyncService.isIndexableEntry(target))
        XCTAssertFalse(SourceSyncService.isIndexableEntry(link))
        XCTAssertFalse(
            SourceSyncService.isIndexableEntry(packageLink),
            "пакет опознаётся по расширению — ссылка с таким именем увела бы за корень источника"
        )
    }

    /// Петля из ссылок не вешает обход: проверено и на живой файловой системе,
    /// и здесь — обход в ссылки не заходит вовсе.
    func testASymlinkLoopDoesNotHangTheScan() async throws {
        let nested = directory.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "текст".write(
            to: nested.appendingPathComponent("файл.md"), atomically: true, encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: nested.appendingPathComponent("петля"), withDestinationURL: directory
        )

        let service = SourceSyncService()
        let source = DataSource(
            name: "папка", path: directory.path, fileExtensions: ["md"], collectionName: "c"
        )
        let files = try await service.scanFiles(source: source)
        XCTAssertEqual(files.count, 1, "обход обязан найти один файл и не уйти в петлю: \(files)")
    }

    // MARK: - Файлы из облака

    /// У обычного файла облачных признаков нет — и проверка обязана быть
    /// на нём бесплатной и молчаливой.
    func testAnOrdinaryFileIsNotTreatedAsACloudPlaceholder() throws {
        let file = directory.appendingPathComponent("местный.md")
        try "текст".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertFalse(SourceSyncService.needsDownloadFromCloud(file))
    }
}

/// Редактор источника и отметки прогона.
final class RunStampTests: XCTestCase {
    private let diskA = SourceVolume(uuid: "A", name: "Backup", mountPoint: "/Volumes/Backup", isRemovable: true)

    private func source(path: String, volume: SourceVolume? = nil, synced: Date? = nil) -> DataSource {
        var source = DataSource(name: "Документы", path: path, collectionName: "docs")
        source.volume = volume
        source.lastSyncedAt = synced
        return source
    }

    /// Прогон, закончившийся, пока редактор был открыт, оставляет свои
    /// отметки: черновик их не знает.
    func testARunFinishedDuringEditingKeepsItsStamps() {
        let synced = Date(timeIntervalSince1970: 1_000)
        let current = source(path: "/Volumes/Backup/Документы", volume: diskA, synced: synced)
        var draft = source(path: "/Volumes/Backup/Документы")
        draft.takeRunStamps(from: current)
        XCTAssertEqual(draft.lastSyncedAt, synced)
        XCTAssertEqual(draft.volume, diskA)
    }

    /// Тот же путь, записанный иначе, — та же папка.
    func testTheSameFolderSpelledDifferentlyKeepsTheVolume() {
        let current = source(path: "/Volumes/Backup/Документы", volume: diskA)
        var draft = source(path: "/Volumes/Backup/Документы/")
        draft.takeRunStamps(from: current)
        XCTAssertEqual(draft.volume, diskA)
    }

    /// Папка переехала — прежний том не переносится: иначе сверка томов
    /// не пустила бы сканирование по новому пути никогда, а совет у ошибки
    /// обещает, что том запомнится заново.
    func testAMovedFolderForgetsTheOldVolume() {
        let synced = Date(timeIntervalSince1970: 1_000)
        let current = source(path: "/Volumes/Backup/Документы", volume: diskA, synced: synced)
        var draft = source(path: "/Users/USER/Документы", volume: diskA)
        draft.takeRunStamps(from: current)
        XCTAssertNil(draft.volume)
        XCTAssertEqual(draft.lastSyncedAt, synced, "дата прошлого прогона — история, она остаётся")
        if case .changed = SourceVolume.check(path: NSTemporaryDirectory(), expected: diskA) {} else {
            XCTFail("прежний том у нового пути и правда не пускает сканирование")
        }
        if case .ready = SourceVolume.check(path: NSTemporaryDirectory(), expected: draft.volume) {} else {
            XCTFail("без запомненного тома новый путь сканируется")
        }
    }
}

/// Сохранение редактора — поверх того, что сейчас в настройках.
final class EditorMergeTests: XCTestCase {
    private func source() -> DataSource {
        DataSource(name: "Документы", path: "/Volumes/Backup/Документы", collectionName: "docs")
    }

    /// Поменянное в окне записывается, записанное другими за это время —
    /// остаётся: и отметки прогона, и правки из окна «Настройки».
    func testOnlyWhatWasEditedIsWritten() {
        let base = source()
        var edited = base
        edited.name = "Документы отдела"
        var current = base
        current.lastSyncedAt = Date(timeIntervalSince1970: 1_234.5)
        current.ocrEnabled = true
        current.excludedPaths = ["черновик.docx"]

        let saved = DataSource.savingEdits(edited, madeOn: base, onto: current)
        XCTAssertEqual(saved.name, "Документы отдела", "правка окна")
        XCTAssertTrue(saved.ocrEnabled, "записанное другими остаётся")
        XCTAssertEqual(saved.excludedPaths, ["черновик.docx"])
        XCTAssertEqual(saved.lastSyncedAt, current.lastSyncedAt, "дата прогона — с долями секунды")
    }

    /// То же поле поменяли и в окне, и снаружи — побеждает окно: это то, что
    /// человек нажал «Сохранить».
    func testTheWindowWinsOnTheSameField() {
        let base = source()
        var edited = base
        edited.pathLevels = [PathLevel(key: "OGV")]
        var current = base
        current.pathLevels = [PathLevel(key: "GIS")]
        XCTAssertEqual(DataSource.savingEdits(edited, madeOn: base, onto: current).pathLevels.map(\.key), ["OGV"])
    }

    /// Поле, очищенное в окне, очищается и в настройках.
    func testAFieldClearedInTheWindowIsCleared() {
        var base = source()
        base.embeddingModel = "bge-m3"
        var edited = base
        edited.embeddingModel = nil
        XCTAssertNil(DataSource.savingEdits(edited, madeOn: base, onto: base).embeddingModel)
    }

    /// Ничего не поменяли — сохраняется ровно то, что в настройках.
    func testAnUntouchedDraftChangesNothing() {
        let base = source()
        var current = base
        current.tableProfileAssignments = ["смета.xlsx": UUID()]
        XCTAssertEqual(DataSource.savingEdits(base, madeOn: base, onto: current), current)
    }

    /// Папку перенесли в окне — том забывается и здесь.
    func testMovingTheFolderStillForgetsTheVolume() {
        var base = source()
        base.volume = SourceVolume(uuid: "A", name: "Backup")
        var edited = base
        edited.path = "/Users/USER/Документы"
        XCTAssertNil(DataSource.savingEdits(edited, madeOn: base, onto: base).volume)
    }
}

/// Склейка правки редактора не теряет вложенных настроек: разбор
/// источника терпимый, и поле, не пережившее круг «закодировать —
/// склеить — раскодировать», молча стало бы умолчанием.
final class EditorMergeRoundTripTests: XCTestCase {
    private func richSource() -> DataSource {
        var source = DataSource(
            name: "Сметы", path: "/Volumes/Backup/Сметы", fileExtensions: ["xlsx", "md"], recursive: false,
            mapping: .folderToCollection, collectionName: "smety",
            pathLevels: [PathLevel(key: "OGV"), PathLevel(), PathLevel(key: "YEAR", type: .integer, fallbackValue: "0")]
        )
        source.embeddingModel = "bge-m3"
        source.customMetadata = ["отдел": "закупки"]
        source.chunking.strategy = .adaptive
        source.chunking.chunkSize = 777
        source.chunking.overlapPercent = 12.5
        source.chunking.sensitivity = 0.3
        source.ocrEnabled = true
        source.ocrLanguages = ["ru-RU", "en-US"]
        source.excludedPaths = ["черновик.xlsx"]
        source.volume = SourceVolume(uuid: "A", name: "Backup", mountPoint: "/Volumes/Backup", isRemovable: true)
        source.lastSyncedAt = Date(timeIntervalSinceReferenceDate: 812_345_678.123_456)
        let mapping = TableMapping(sheetName: "Лист1", mode: .dataTable, headerRow: 2, columns: ["Позиция", "Цена"],
                                   roles: [:], keyColumn: "Позиция", textTemplate: "{Позиция}: {Цена}", titles: ["Цена": "Цена, ₽"])
        let profile = TableProfile(name: "Смета", sheets: .named(["Лист1"]), mapping: mapping)
        source.tableProfiles = [profile]
        source.tableProfileAssignments = ["смета.xlsx": profile.id]
        source.unmatchedSheetsAsText = false
        source.triggers.debounceSeconds = 9
        source.git = GitSourceSettings(indexesWorkingCopy: false, includesCommitInfo: true, excludedGlobs: ["*.lock"])
        return source
    }

    func testAnUntouchedRichSourceComesBackUnchanged() {
        let source = richSource()
        XCTAssertEqual(DataSource.savingEdits(source, madeOn: source, onto: source), source)
    }

    func testEditingOneFieldKeepsEveryNestedSetting() {
        let base = richSource()
        var edited = base
        edited.name = "Сметы отдела"
        var expected = base
        expected.name = edited.name
        XCTAssertEqual(DataSource.savingEdits(edited, madeOn: base, onto: base), expected)
    }

    func testAWebSourceComesBackUnchanged() {
        var web = DataSource(name: "Сайт", path: "https://example.com/docs", collectionName: "site")
        web.web = WebSourceSettings()
        web.web?.delaySeconds = 2.5
        XCTAssertEqual(DataSource.savingEdits(web, madeOn: web, onto: web), web)
    }
}

/// Новый диск принимают вместе источники с тем же прежним диском.
final class SourcesMovingTests: XCTestCase {
    private let old = SourceVolume(uuid: "A", name: "Backup")
    private let new = SourceVolume(uuid: "B", name: "Backup")
    private let other = SourceVolume(uuid: "C", name: "Archive")

    private func source(_ path: String, remembered: SourceVolume?) -> DataSource {
        var source = DataSource(name: path, path: path, collectionName: "c")
        source.volume = remembered
        return source
    }

    func testOnlySourcesWithTheSameOldAndNewDiskMove() {
        let first = source("/Volumes/Backup/a", remembered: old)
        let second = source("/Volumes/Backup/b", remembered: old)
        let elsewhere = source("/Volumes/Archive/c", remembered: other)
        let unplugged = source("/Volumes/Old/d", remembered: old)
        let volumes = ["/Volumes/Backup/a": new, "/Volumes/Backup/b": new, "/Volumes/Archive/c": new]
        let moving = SourceVolume.sourcesMoving(
            from: old, to: new, among: [first, second, elsewhere, unplugged],
            volumeAt: { volumes[$0.path] }
        )
        XCTAssertEqual(Set(moving), [first.id, second.id],
                       "другой прежний диск и источник, чей путь сейчас не на новом диске, не трогаются")
    }
}
