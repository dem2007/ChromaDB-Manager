import XCTest
@testable import ChromaCore

/// План ходит на диск по разу на файл.
///
/// Сторож на самую тихую поломку из возможных: лишний `attributesOfItem`
/// в цикле плана ничего не ломает и ничем не проявляется — просто папка
/// на восемь тысяч файлов планируется вдвое дольше. Один раз это уже
/// случилось ( добавил проверку «файл растёт прямо сейчас», и она
/// спрашивала у диска ровно то, что цикл плана уже знал), поэтому счётчик
/// стоит именно на живом прогоне, а не на одной функции.
final class PlanFileScanTests: XCTestCase {
    /// Считает обращения к атрибутам. Всё остальное — как у настоящей.
    private final class CountingFileManager: FileManager, @unchecked Sendable {
        let counter = Counter()

        override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
            counter.bump(path)
            return try super.attributesOfItem(atPath: path)
        }

        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var calls: [String: Int] = [:]

            func bump(_ path: String) {
                lock.lock(); defer { lock.unlock() }
                calls[path, default: 0] += 1
            }
            var total: Int {
                lock.lock(); defer { lock.unlock() }
                return calls.values.reduce(0, +)
            }
            func count(forSuffix suffix: String) -> Int {
                lock.lock(); defer { lock.unlock() }
                return calls.filter { $0.key.hasSuffix(suffix) }.values.reduce(0, +)
            }
        }
    }

    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-plan-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func source() -> DataSource {
        DataSource(
            name: "проверка",
            path: folder.path,
            fileExtensions: ["txt"],
            recursive: true,
            mapping: .folderToCollection,
            collectionName: "test",
            embeddingModel: "model"
        )
    }

    /// Сколько файлов — столько и обращений к атрибутам. Не вдвое больше.
    func testThePlanAsksTheDiskOncePerFile() async throws {
        for index in 0..<12 {
            try write("файл-\(index).txt", String(repeating: "текст ", count: 40))
        }

        let fileManager = CountingFileManager()
        let service = SourceSyncService(
            manifests: ManifestStore(directory: folder.appendingPathComponent("manifests")),
            tableManifests: TableManifestStore(directory: folder.appendingPathComponent("tables")),
            fileManager: fileManager
        )

        let plan = try await service.plan(source: source(), embeddingModel: "model")
        XCTAssertEqual(plan.items.count, 12)

        // Ровно по одному на файл. Проверяется по каждому имени отдельно:
        // общая сумма скрыла бы «по два у половины и ни одного у другой».
        for index in 0..<12 {
            XCTAssertEqual(
                fileManager.counter.count(forSuffix: "файл-\(index).txt"), 1,
                "файл-\(index).txt: атрибуты снимались больше одного раза"
            )
        }
        XCTAssertEqual(fileManager.counter.total, 12)
    }

    /// Свежий большой файл — единственный, у кого замер повторяется: по нему
    /// и решается, растёт он или уже дописан.
    func testOnlyASuspiciousFileIsSampledTwice() async throws {
        let big = String(repeating: "б", count: Int(SourceSyncService.stabilisationMinimumBytes) + 16)
        try write("большой.txt", big)
        try write("маленький.txt", "коротко")

        let fileManager = CountingFileManager()
        let files = [
            folder.appendingPathComponent("большой.txt"),
            folder.appendingPathComponent("маленький.txt"),
        ]
        let scan = await SourceSyncService.scan(files, fileManager: fileManager)

        XCTAssertEqual(fileManager.counter.count(forSuffix: "маленький.txt"), 1)
        XCTAssertEqual(fileManager.counter.count(forSuffix: "большой.txt"), 2)
        // Файл записан и больше не менялся — значит не растёт.
        XCTAssertTrue(scan.growing.isEmpty)
        // И снимки есть у обоих: план возьмёт размеры отсюда.
        XCTAssertEqual(scan.snapshots.count, 2)
        XCTAssertEqual(
            scan.snapshots[files[0].path]?.size,
            Int64(big.utf8.count)
        )
    }

    /// Файл, исчезнувший между обходом папки и замером, снимка не получает —
    /// и план обязан это пережить, а не подставить чужой размер.
    func testAVanishedFileHasNoSnapshot() async throws {
        let missing = folder.appendingPathComponent("нет-такого.txt")
        let scan = await SourceSyncService.scan([missing])
        XCTAssertNil(scan.snapshots[missing.path])
        XCTAssertTrue(scan.growing.isEmpty)
    }
}
