import XCTest
@testable import ChromaCore

/// что карточка источника говорит про синхронизацию.
final class SourceSyncStatusTests: XCTestCase {
    /// Главный случай: манифест ещё не прочитан. «Нечего сказать» — это
    /// не «не синхронизирован», и именно эта подмена показывала
    /// «ещё не синхронизирован» на источнике со 124 записанными чанками.
    func testNothingReadYetIsNotAClaimOfNeverSynced() {
        let status = SourceSyncStatus.of(info: nil, tableRows: 0, tableFiles: 0)
        XCTAssertEqual(status, .unknown)
        XCTAssertFalse(status.claimsNeverSynced)
        XCTAssertFalse(status.line.contains("ещё не синхронизирован"), status.line)
    }

    /// Прочитали и там пусто — вот тогда можно.
    func testAnEmptyManifestThatWasActuallyReadSaysSo() {
        let status = SourceSyncStatus.of(info: (files: 0, chunks: 0, updatedAt: nil), tableRows: 0, tableFiles: 0)
        XCTAssertEqual(status, .neverSynced)
        XCTAssertTrue(status.claimsNeverSynced)
        XCTAssertEqual(status.line, "ещё не синхронизирован")
    }

    /// Тот самый источник пользователя: один файл, 124 чанка.
    func testAManifestWithFilesReportsThem() {
        let when = Date(timeIntervalSince1970: 1_785_000_000)
        let status = SourceSyncStatus.of(info: (files: 1, chunks: 124, updatedAt: when), tableRows: 0, tableFiles: 0)
        XCTAssertFalse(status.claimsNeverSynced)
        XCTAssertTrue(status.line.contains("1 файл → 124 записи"), status.line)
        XCTAssertFalse(status.line.contains("("), "при одном виде содержимого разбивка не нужна: \(status.line)")
        XCTAssertTrue(status.line.contains("обновлён"), status.line)
    }

    /// строки таблиц лежат в отдельном манифесте, и источник из одних
    /// таблиц не должен объявляться несинхронизированным.
    func testTableRowsAloneCountAsSynced() {
        let status = SourceSyncStatus.of(info: (files: 0, chunks: 0, updatedAt: nil), tableRows: 3_400, tableFiles: 2)
        XCTAssertFalse(status.claimsNeverSynced)
        // Разряды разделяются по локали, поэтому сравниваем по частям, а не
        // по строке с пробелом неизвестного вида.
        XCTAssertTrue(status.line.contains("2 файла →"), status.line)
        XCTAssertTrue(status.line.hasSuffix("записей"), status.line)
        XCTAssertEqual(status.records, 3_400)
    }

    /// Два манифеста — два чтения, и файловый может опоздать. Пока его нет,
    /// но строки уже известны, утверждать «не синхронизирован» нельзя.
    func testTableRowsKnownBeforeTheFileManifestIsStillNotNeverSynced() {
        let status = SourceSyncStatus.of(info: nil, tableRows: 12, tableFiles: 1)
        XCTAssertFalse(status.claimsNeverSynced)
        XCTAssertTrue(status.line.contains("1 файл → 12 записей"), status.line)
    }

    func testFilesAndRowsAreBothListed() {
        let status = SourceSyncStatus.of(info: (files: 2, chunks: 40, updatedAt: nil), tableRows: 7, tableFiles: 1)
        // Файлы считаются вместе с таблицами: два текстовых плюс одна книга.
        XCTAssertTrue(status.line.contains("3 файла → 47 записей"), status.line)
        XCTAssertTrue(status.line.contains("(чанков 40, строк из таблиц 7)"), status.line)
        XCTAssertEqual(status.records, 47)
    }
}

/// согласование числительных.
///
/// Правило жило в `RussianCount` ещё до этой задачи; первая редакция
/// завела рядом второй такой же тип, не проверив. Дубликат убран, тесты
/// оставлены здесь — они проверяют именно те числа, ради которых всё делалось.
final class RussianCountForReportTests: XCTestCase {
    func testTheThreeForms() {
        let word = { RussianCount.word($0, "файл", "файла", "файлов") }
        XCTAssertEqual(word(1), "файл")
        XCTAssertEqual(word(2), "файла")
        XCTAssertEqual(word(4), "файла")
        XCTAssertEqual(word(5), "файлов")
        XCTAssertEqual(word(0), "файлов")
    }

    /// 11–14 — исключение, из-за которого наивное «n % 10» даёт «11 файл».
    func testTheTeensAreTheException() {
        let word = { RussianCount.word($0, "запись", "записи", "записей") }
        for n in 11...14 { XCTAssertEqual(word(n), "записей", "\(n)") }
        XCTAssertEqual(word(21), "запись")
        XCTAssertEqual(word(124), "записи")
        XCTAssertEqual(word(141), "запись")
    }

    /// Числа пользователя из жалобы — те, ради которых всё и делалось.
    func testTheNumbersFromTheReport() {
        XCTAssertEqual(RussianCount.grouped(141, "запись", "записи", "записей"), "141 запись")
        XCTAssertEqual(RussianCount.grouped(50, "запись", "записи", "записей"), "50 записей")
        XCTAssertEqual(RussianCount.grouped(2, "файл", "файла", "файлов"), "2 файла")
        XCTAssertTrue(RussianCount.grouped(3_400, "запись", "записи", "записей").hasSuffix(" записей"))
    }
}
