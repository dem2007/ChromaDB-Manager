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
