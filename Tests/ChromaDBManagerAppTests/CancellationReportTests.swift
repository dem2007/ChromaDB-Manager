import XCTest
import ChromaCore
@testable import ChromaDBManagerApp

/// Отмена — не сбой.
///
/// В журнале за день таких «ошибок» набралось две подряд прямо при запуске:
/// задачи отменялись сами собой, а человек видел красное.
final class CancellationReportTests: XCTestCase {
    func testOurOwnCancellationIsNotAnError() {
        XCTAssertTrue(AppEnvironment.isCancellation(CancellationError()))
    }

    /// Сетевой запрос, снятый вместе с задачей: та же отмена, просто пришла
    /// от системы.
    func testACancelledRequestIsTheSameCancellation() {
        XCTAssertTrue(AppEnvironment.isCancellation(URLError(.cancelled)))
        XCTAssertTrue(AppEnvironment.isCancellation(
            NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        ))
    }

    /// А настоящая ошибка остаётся ошибкой — иначе фильтр съел бы то, ради
    /// чего журнал и заведён.
    func testARealFailureStaysAFailure() {
        XCTAssertFalse(AppEnvironment.isCancellation(URLError(.timedOut)))
        XCTAssertFalse(AppEnvironment.isCancellation(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        ))
        struct Broken: Error {}
        XCTAssertFalse(AppEnvironment.isCancellation(Broken()))
        XCTAssertFalse(AppEnvironment.isCancellation(SyncError.noEmbeddingModel))
    }

    /// Отмены ядра своими именами: «Остановить» у синхронизации, снятая
    /// заявка очереди, прерванный перерасчёт. Прежде они шли красной
    /// плашкой, уведомлением о сбое и ERROR в журнале.
    func testTheCoresOwnCancellationsAreCancellations() {
        XCTAssertTrue(AppEnvironment.isCancellation(SyncError.cancelled))
        XCTAssertTrue(AppEnvironment.isCancellation(QueueError.cancelled("Синхронизация")))
        XCTAssertTrue(AppEnvironment.isCancellation(ReembeddingError.cancelled))
        XCTAssertTrue(AppEnvironment.isCancellation(ShellError.cancelled(command: "chroma")))
    }
}

/// Восстановление берёт только копию этой же базы.
@MainActor
final class RestoreTargetTests: XCTestCase {
    private func record(from source: String?) -> BackupRecord {
        BackupRecord(
            url: URL(fileURLWithPath: "/tmp/backups/chroma_20260925"),
            createdAt: Date(), sizeBytes: 1, sourcePath: source
        )
    }

    func testACopyOfAnotherDatabaseIsNotRestoredHere() {
        let local = URL(fileURLWithPath: "/Users/x/Library/Application Support/ChromaDBManager/database")
        XCTAssertTrue(EnvironmentViewModel.backup(record(from: local.path), belongsTo: local))
        XCTAssertTrue(EnvironmentViewModel.backup(record(from: local.path + "/"), belongsTo: local))
        XCTAssertFalse(EnvironmentViewModel.backup(record(from: "/Volumes/data/managed"), belongsTo: local))
        // Копия без записанного пути — старого формата: судить не по чему.
        XCTAssertTrue(EnvironmentViewModel.backup(record(from: nil), belongsTo: local))
    }
}
