import XCTest
@testable import ChromaCore

/// «Место на диске»: каждая часть — своей строкой и ровно один раз.
final class DiskUsageTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("disk-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func file(_ path: String, bytes: Int) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
    }

    private var support: URL { root.appendingPathComponent("support") }
    private var logs: URL { root.appendingPathComponent("logs") }

    /// Главное: своя база, копии, движок, корзина и кэш — своими строками,
    /// а в служебные данные попадает только остальное.
    func testEveryPartIsCountedOnce() throws {
        try file("support/chroma_data/chroma.sqlite3", bytes: 1000)
        try file("support/backups/copy-1/chroma.sqlite3", bytes: 900)
        try file("support/bin/chroma", bytes: 300)
        try file("support/venv/bin/python3", bytes: 200)
        try file("support/trash.jsonl", bytes: 50)
        try file("support/embedding-cache.sqlite3", bytes: 40)
        try file("support/embedding-cache.sqlite3-wal", bytes: 4)
        try file("support/manifests/source.json", bytes: 30)
        try file("support/config.json", bytes: 10)
        try file("logs/audit.jsonl", bytes: 20)

        let report = DiskUsage.measure(
            databaseURL: support.appendingPathComponent("chroma_data"), support: support, logs: logs
        )
        XCTAssertEqual(report.databaseBytes, 1000)
        XCTAssertEqual(report.backupsBytes, 900)
        XCTAssertEqual(report.engineBinaryBytes, 300)
        XCTAssertEqual(report.engineVenvBytes, 200)
        XCTAssertEqual(report.trashBytes, 50)
        XCTAssertEqual(report.embeddingCacheBytes, 44, "кэш — вместе с журналом SQLite")
        XCTAssertEqual(report.logsBytes, 20)
        XCTAssertEqual(report.serviceParts.map(\.name), ["manifests", "config.json"], "по убыванию, без своих строк")
        XCTAssertEqual(report.serviceBytes, 40)
        XCTAssertEqual(report.totalBytes, 1000 + 900 + 300 + 200 + 50 + 44 + 20 + 40)
    }

    /// База вне папки приложения считается своей строкой; на внешнем
    /// сервере её нет вовсе, и это не ноль.
    func testDatabaseOutsideTheAppFolderAndOnAServer() throws {
        try file("elsewhere/db/chroma.sqlite3", bytes: 500)
        try file("support/config.json", bytes: 10)
        let outside = DiskUsage.measure(
            databaseURL: root.appendingPathComponent("elsewhere/db"), support: support, logs: logs
        )
        XCTAssertEqual(outside.databaseBytes, 500)
        XCTAssertNil(outside.engineBinaryBytes, "движка нет — строки нет, а не ноль")
        XCTAssertNil(outside.databaseVolumeFreeBytes, "тот же том — второй строки свободного места нет")

        let server = DiskUsage.measure(databaseURL: nil, support: support, logs: logs)
        XCTAssertNil(server.databaseBytes)
        XCTAssertNil(server.nextBackupFits, "базы на диске нет — и сказать про копию нечего")
    }

    /// Ссылка на чужую папку — не наш объём.
    func testSymbolicLinksAreNotFollowed() throws {
        try file("foreign/big.bin", bytes: 5000)
        try file("support/manifests/a.json", bytes: 10)
        try FileManager.default.createSymbolicLink(
            at: support.appendingPathComponent("manifests/link"),
            withDestinationURL: root.appendingPathComponent("foreign")
        )
        XCTAssertEqual(DiskUsage.size(of: support.appendingPathComponent("manifests")), 10)
    }

    /// Копия «помещается» по тому же правилу, по которому её пускают:
    /// база и запас сверху (`BackupService.requiredSpace`), а не одна база.
    func testTheNextBackupFitsByTheSameRuleAsTheBackupItself() {
        func report(database: Int64?, free: Int64?, unreadable: Set<DiskUsageReport.Row> = []) -> DiskUsageReport {
            DiskUsageReport(
                measuredAt: Date(), databaseBytes: database, engineBinaryBytes: nil, engineVenvBytes: nil,
                backupsBytes: 0, trashBytes: 0, embeddingCacheBytes: 0, logsBytes: 0, serviceParts: [],
                freeBytes: free, databaseVolumeFreeBytes: nil, unreadable: unreadable
            )
        }
        let required = BackupService.requiredSpace(forDatabaseBytes: 100)
        XCTAssertEqual(required, 120)
        XCTAssertEqual(report(database: 100, free: 120).nextBackupFits, true)
        XCTAssertEqual(report(database: 100, free: 110).nextBackupFits, false, "базы хватает, запаса — нет")
        XCTAssertNil(report(database: 100, free: nil).nextBackupFits)
        XCTAssertNil(report(database: 100, free: 1000, unreadable: [.database]).nextBackupFits, "база прочитана не вся — сказать нечего")
    }

    /// Своя локальная база, когда приложение работает с другой, — своей
    /// строкой, а не служебными данными под именем папки.
    func testAnIdleLocalDatabaseIsItsOwnRow() throws {
        try file("support/chroma_data/chroma.sqlite3", bytes: 700)
        try file("elsewhere/managed/chroma.sqlite3", bytes: 300)
        let report = DiskUsage.measure(
            databaseURL: root.appendingPathComponent("elsewhere/managed"), support: support, logs: logs
        )
        XCTAssertEqual(report.databaseBytes, 300)
        XCTAssertEqual(report.idleDatabaseBytes, 700)
        XCTAssertFalse(report.serviceParts.map(\.name).contains("chroma_data"))
        XCTAssertEqual(report.totalBytes, 1000)
        let local = DiskUsage.measure(databaseURL: support.appendingPathComponent("chroma_data"), support: support, logs: logs)
        XCTAssertNil(local.idleDatabaseBytes, "та же база не считается дважды")
    }

    /// Папка без доступа — не ноль, а «прочитано не всё».
    func testAnUnreadableFolderIsCalledOut() throws {
        // Корню права на чтение не указ — под ним папку не закрыть.
        try XCTSkipIf(getuid() == 0, "под root закрытая папка всё равно читается")
        try file("support/backups/copy/chroma.sqlite3", bytes: 50)
        let locked = support.appendingPathComponent("backups/copy")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let report = DiskUsage.measure(databaseURL: nil, support: support, logs: logs)
        XCTAssertTrue(report.unreadable.contains(.backups), "\(report.unreadable)")
    }

    /// Исключается папка целиком, а не всё, что начинается с её имени.
    func testExcludingAFolderKeepsItsNamesakes() throws {
        try file("support/backups/a.bin", bytes: 10)
        try file("support/backups-old/b.bin", bytes: 20)
        let size = DiskUsage.size(of: support, excluding: [support.appendingPathComponent("backups")])
        XCTAssertEqual(size, 20)
    }
}
