import XCTest
@testable import ChromaCore

// MARK: - H4: what the three-way setting actually decides

final class OperationNoticePolicyTests: XCTestCase {
    private func clean() -> OperationNotice {
        OperationNotice(kind: .sync, subject: "docs", added: 3, updated: 1, duration: 2)
    }

    func testNeverMeansNever() {
        XCTAssertFalse(clean().shouldPost(policy: .never))
        let broken = OperationNotice.failure(kind: .sync, subject: "docs", reason: "сервер недоступен")
        XCTAssertFalse(broken.shouldPost(policy: .never), "«никогда» не делает исключений даже для сорванного прогона")
    }

    func testAlwaysIncludesTheRunThatChangedNothing() {
        let quiet = OperationNotice(kind: .sync, subject: "docs")
        XCTAssertTrue(quiet.shouldPost(policy: .always))
        XCTAssertFalse(quiet.shouldPost(policy: .problemsOnly))
    }

    /// «Требуют решения» is not a statistic but a queue: files vanished from
    /// disk and the app deletes nothing by itself. A run that leaves
    /// that queue non-empty is unfinished business, not a success.
    func testFilesAwaitingADecisionCountAsAProblem() {
        let notice = OperationNotice(kind: .sync, subject: "docs", added: 2, needsDecision: 4)
        XCTAssertTrue(notice.hasProblems)
        XCTAssertTrue(notice.shouldPost(policy: .problemsOnly))
    }

    func testAFailedRunIsAProblemEvenWithNoCounts() {
        let notice = OperationNotice.failure(kind: .reembedding, subject: "articles", reason: "нет связи")
        XCTAssertTrue(notice.shouldPost(policy: .problemsOnly))
        XCTAssertTrue(notice.title.contains("прервана"))
        XCTAssertTrue(notice.body.contains("нет связи"))
    }

    /// A run that died must not describe itself as a quiet success.
    func testAFailedRunDoesNotClaimThereWereNoChanges() {
        let notice = OperationNotice.failure(kind: .sync, subject: "docs", reason: "диск отключён")
        XCTAssertFalse(notice.body.contains("изменений нет"))
    }

    func testTheBodyStaysReadableWhenThereAreManyProblems() {
        let notice = OperationNotice(
            kind: .sync, subject: "docs", added: 1,
            problems: ["первая", "вторая", "третья", "четвёртая"]
        )
        XCTAssertTrue(notice.body.contains("первая"))
        XCTAssertTrue(notice.body.contains("вторая"))
        XCTAssertFalse(notice.body.contains("третья"), "третье и дальше сворачиваются в счётчик")
        XCTAssertTrue(notice.body.contains("2"), "но их количество названо")
    }
}

// MARK: - What each operation turns into

final class OperationNoticeConversionTests: XCTestCase {
    private func summary(
        skipped: [(file: String, reason: String)] = [],
        needsDecision: [PendingRemoval] = [],
        heterogeneous: [String] = []
    ) -> SyncSummary {
        var summary = SyncSummary(
            sourceName: "docs", added: 5, updated: 2, unchanged: 10,
            chunksWritten: 40, chunksDeleted: 0, skipped: skipped,
            needsDecision: needsDecision, markedForAttention: [],
            collections: ["docs_col"], duration: 12, embeddingModel: "m", dimension: 768
        )
        summary.heterogeneousCollections = heterogeneous
        return summary
    }

    func testACleanSyncCarriesItsCountsAndNoProblems() {
        let notice = summary().notice
        XCTAssertEqual(notice.kind, .sync)
        XCTAssertEqual(notice.subject, "docs")
        XCTAssertEqual(notice.added, 5)
        XCTAssertEqual(notice.updated, 2)
        XCTAssertFalse(notice.hasProblems)
        XCTAssertTrue(notice.body.contains("добавлено 5"))
    }

    /// G6 again: a collection whose contents are now mixed is exactly what the
    /// user has to decide about, and it must survive into the notification.
    func testHeterogeneityReachesTheNotification() {
        let notice = summary(heterogeneous: ["docs_col"]).notice
        XCTAssertTrue(notice.hasProblems)
        XCTAssertTrue(notice.body.contains("неоднородным"))
    }

    func testSkippedFilesAreCountedAsAProblem() {
        let notice = summary(skipped: [(file: "a.pdf", reason: "нет текстового слоя")]).notice
        XCTAssertTrue(notice.hasProblems)
        XCTAssertTrue(notice.body.contains("пропущено файлов: 1"))
    }

    func testImportReportsWhatItLeftOut() {
        let summary = ImportSummary(
            written: 100, skippedEmpty: 2, duration: 5, model: "m", dimension: 768,
            skippedTooLong: ["row-7"], skippedDuplicates: ["row-9", "row-11"]
        )
        let notice = summary.notice
        XCTAssertEqual(notice.kind, .importDocuments)
        XCTAssertEqual(notice.added, 100)
        XCTAssertTrue(notice.hasProblems)
    }
}

// MARK: - The notifier's own gate

@MainActor
final class OperationNotificationDeliveryTests: XCTestCase {
    private final class Delivered: @unchecked Sendable {
        private let lock = NSLock()
        private var posts: [(String, String)] = []
        func record(_ title: String, _ body: String) {
            lock.lock(); posts.append((title, body)); lock.unlock()
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return posts.count }
        var last: (String, String)? { lock.lock(); defer { lock.unlock() }; return posts.last }
    }

    private func makeNotifier(_ sink: Delivered) -> Notifier {
        Notifier(
            deliver: { title, body in sink.record(title, body) },
            requestAuthorization: { .success(true) }
        )
    }

    func testNothingIsPostedWhileTheMasterSwitchIsOff() async {
        let sink = Delivered()
        let notifier = makeNotifier(sink)
        let notice = OperationNotice.failure(kind: .sync, subject: "docs", reason: "ошибка")
        XCTAssertFalse(notifier.post(notice, policy: .always), "выключенные уведомления не обходятся политикой")
        XCTAssertEqual(sink.count, 0)
    }

    func testTheSummaryArrivesOnceTheSwitchIsOn() async {
        let sink = Delivered()
        let notifier = makeNotifier(sink)
        await notifier.enable()

        let notice = OperationNotice(kind: .sync, subject: "docs", added: 3, updated: 1)
        XCTAssertTrue(notifier.post(notice, policy: .always))
        XCTAssertEqual(sink.count, 1)
        XCTAssertEqual(sink.last?.0, notice.title)
    }

    func testAQuietRunIsSilentUnderProblemsOnly() async {
        let sink = Delivered()
        let notifier = makeNotifier(sink)
        await notifier.enable()

        XCTAssertFalse(notifier.post(
            OperationNotice(kind: .sync, subject: "docs", added: 1), policy: .problemsOnly
        ))
        XCTAssertTrue(notifier.post(
            OperationNotice(kind: .sync, subject: "docs", added: 1, needsDecision: 2), policy: .problemsOnly
        ))
        XCTAssertEqual(sink.count, 1)
    }

    /// One notification per operation — the whole point of a *summary*. Ten
    /// files must not become ten notifications.
    func testOneOperationProducesOneNotification() async {
        let sink = Delivered()
        let notifier = makeNotifier(sink)
        await notifier.enable()

        let summary = SyncSummary(
            sourceName: "docs", added: 10, updated: 0, unchanged: 0,
            chunksWritten: 90, chunksDeleted: 0, skipped: [], needsDecision: [],
            markedForAttention: [], collections: ["c"], duration: 30,
            embeddingModel: "m", dimension: 768
        )
        notifier.post(summary.notice, policy: .always)
        XCTAssertEqual(sink.count, 1)
    }

    /// The operation policy must not reach the security events: a server that
    /// died is not a background summary, and «никогда» is not a request to hide it.
    func testTheOperationPolicyDoesNotSilenceSecurityEvents() async {
        let sink = Delivered()
        let notifier = makeNotifier(sink)
        await notifier.enable()

        notifier.post(OperationNotice(kind: .sync, subject: "docs"), policy: .never)
        XCTAssertEqual(sink.count, 0)

        notifier.post(SecurityEvent.serverFailed("процесс завершился"))
        XCTAssertEqual(sink.count, 1, "события безопасности идут своим путём")
    }
}
