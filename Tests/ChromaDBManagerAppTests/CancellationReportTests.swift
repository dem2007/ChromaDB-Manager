import XCTest
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
    }
}
