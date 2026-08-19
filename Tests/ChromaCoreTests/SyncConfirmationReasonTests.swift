import XCTest
@testable import ChromaCore

/// Почему план синхронизации ждёт человека.
///
/// Причин две и они независимы, а баннер рассказывал всегда про первую.
/// На живом плане это выглядело так: сорок два файла, порог сто, и надпись
/// «42 — больше порога 100». Число и порог в одной строке противоречили
/// друг другу, и понять, чему верить, было нельзя.
final class SyncConfirmationReasonTests: XCTestCase {

    private func plan(files: Int, tableRows: Int = 0) -> SyncPlan {
        SyncPlan(
            sourceID: UUID(), sourceName: "источник",
            items: (0..<files).map { index in
                SyncPlanItem(
                    relativePath: "файл-\(index).docx",
                    url: URL(fileURLWithPath: "/tmp/файл-\(index).docx"),
                    kind: .new,
                    collectionName: "c",
                    size: 1000,
                    modifiedAt: Date(),
                    textLength: 1000
                )
            },
            newlyMissing: [],
            pendingRemovals: [],
            tableRowsToEmbed: tableRows
        )
    }

    // MARK: - Одна причина, названная верно

    func testManyFilesIsReportedAsManyFiles() {
        let reasons = plan(files: 142).confirmationReasons(threshold: 100)
        XCTAssertEqual(reasons, [.manyFiles(files: 142, threshold: 100)])
        XCTAssertTrue(reasons[0].sentence.contains("142"), reasons[0].sentence)
    }

    /// Тот самый случай: файлов меньше порога, остановили строки таблиц.
    /// Про порог файлов не должно быть сказано ни слова.
    func testTableRowsAreNotReportedAsFilesOverTheThreshold() {
        let reasons = plan(files: 42, tableRows: 12_000).confirmationReasons(threshold: 100)
        XCTAssertEqual(reasons, [.manyTableRows(rows: 12_000, threshold: TableRunEstimate.warningThreshold)])
        let text = reasons[0].sentence
        XCTAssertTrue(text.contains("строк") || text.contains("Строк"), text)
        XCTAssertFalse(text.contains("100"), "порог файлов к этой причине отношения не имеет: \(text)")
    }

    /// Обе разом — обе и называются: умолчать о второй значит соврать наполовину.
    func testBothReasonsAreReportedTogether() {
        let reasons = plan(files: 142, tableRows: 12_000).confirmationReasons(threshold: 100)
        XCTAssertEqual(reasons.count, 2)
    }

    // MARK: - Когда спрашивать не о чем

    func testASmallPlanAsksNothing() {
        XCTAssertTrue(plan(files: 42).confirmationReasons(threshold: 100).isEmpty)
        XCTAssertFalse(plan(files: 42).needsConfirmation(threshold: 100))
    }

    /// Порог ноль означает «показывать всегда» — как написано в настройке.
    func testAZeroThresholdStopsEveryWritingRun() {
        XCTAssertTrue(plan(files: 1).needsConfirmation(threshold: 0))
        XCTAssertFalse(plan(files: 0).needsConfirmation(threshold: 0))
    }

    /// Ровно на пороге план не останавливается: настройка говорит «больше N».
    func testExactlyAtTheThresholdIsNotOverIt() {
        XCTAssertFalse(plan(files: 100).needsConfirmation(threshold: 100))
        XCTAssertTrue(plan(files: 101).needsConfirmation(threshold: 100))
    }

    /// Ворота и причина не могут разойтись: одно считается через другое.
    func testTheGateAndTheReasonAgree() {
        for files in [0, 1, 99, 100, 101] {
            for rows in [0, 5_000, 5_001] {
                let value = plan(files: files, tableRows: rows)
                XCTAssertEqual(
                    value.needsConfirmation(threshold: 100),
                    !value.confirmationReasons(threshold: 100).isEmpty,
                    "файлов \(files), строк \(rows)"
                )
            }
        }
    }
}
