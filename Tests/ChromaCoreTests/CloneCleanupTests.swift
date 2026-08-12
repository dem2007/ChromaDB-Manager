import XCTest
@testable import ChromaCore

/// что экран говорит про клон после отмены.
final class CloneCleanupTests: XCTestCase {
    /// Удалось — можно так и сказать.
    func testARemovedCloneIsReportedAsRemoved() {
        let cleanup = CloneCleanup(name: "new_new_test_llmbased", removed: true, failure: nil)
        XCTAssertTrue(cleanup.message.contains("удалён"), cleanup.message)
        XCTAssertTrue(cleanup.message.contains("new_new_test_llmbased"), cleanup.message)
    }

    /// Не удалось — и вот это раньше печаталось теми же словами, что и успех.
    /// Коллекция оставалась в базе неполной, а экран уверял, что её нет.
    func testACloneThatSurvivedIsNotReportedAsRemoved() {
        let cleanup = CloneCleanup(
            name: "new_new_test_llmbased", removed: false, failure: "сервер не ответил"
        )
        XCTAssertFalse(
            cleanup.message.contains("клон «new_new_test_llmbased» удалён"),
            "нельзя утверждать удаление, которого не было: \(cleanup.message)"
        )
        XCTAssertTrue(cleanup.message.contains("осталась в базе неполной"), cleanup.message)
        XCTAssertTrue(cleanup.message.contains("вручную"), cleanup.message)
        XCTAssertTrue(cleanup.message.contains("сервер не ответил"), cleanup.message)
    }

    /// Причина неизвестна — сообщение всё равно не должно превращаться
    /// в утверждение об успехе.
    func testAFailureWithoutAReasonStillSaysItSurvived() {
        let cleanup = CloneCleanup(name: "клон", removed: false, failure: nil)
        XCTAssertTrue(cleanup.message.contains("осталась в базе неполной"), cleanup.message)
        XCTAssertTrue(cleanup.message.contains("неизвестна"), cleanup.message)
    }

    func testTheTwoOutcomesNeverReadTheSame() {
        let removed = CloneCleanup(name: "к", removed: true, failure: nil).message
        let survived = CloneCleanup(name: "к", removed: false, failure: "x").message
        XCTAssertNotEqual(removed, survived)
    }
}
