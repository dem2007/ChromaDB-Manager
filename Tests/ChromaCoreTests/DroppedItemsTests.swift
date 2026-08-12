import XCTest
@testable import ChromaCore

/// что приложение предлагает сделать с перетащенным.
final class DroppedItemsTests: XCTestCase {

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    private func classify(
        _ paths: [String], folders: Set<String> = [], readable: Set<String> = []
    ) -> DroppedItems {
        DroppedItems.classify(
            paths.map(url),
            canExtract: { readable.contains($0.lastPathComponent) },
            isDirectory: { folders.contains($0.lastPathComponent) }
        )
    }

    func testAFolderIsOfferedAsASourceAndAFileAsADocument() {
        let items = classify(
            ["/tmp/контракты", "/tmp/акт.pdf"],
            folders: ["контракты"], readable: ["акт.pdf"]
        )
        XCTAssertEqual(items.folders.map(\.lastPathComponent), ["контракты"])
        XCTAssertEqual(items.files.map(\.lastPathComponent), ["акт.pdf"])
        XCTAssertTrue(items.unsupported.isEmpty)
        XCTAssertTrue(items.hasSomethingToDo)
    }

    /// Файл, который извлечение не берёт, называется вслух, а не пропадает
    /// молча: человек перетащил его намеренно и вправе знать, почему ничего
    /// не произошло.
    func testAnUnreadableFileIsNamedRatherThanDroppedSilently() {
        let items = classify(["/tmp/архив.zip"], readable: [])
        XCTAssertEqual(items.unsupported.map(\.lastPathComponent), ["архив.zip"])
        XCTAssertFalse(items.hasSomethingToDo, "предлагать выбор тут нечего")
        XCTAssertFalse(items.isEmpty, "но и молчать нельзя — что-то бросили")
    }

    func testOrderIsKeptTheWayTheUserDroppedThem() {
        let items = classify(
            ["/tmp/б.pdf", "/tmp/а.pdf", "/tmp/в.pdf"],
            readable: ["а.pdf", "б.pdf", "в.pdf"]
        )
        XCTAssertEqual(items.files.map(\.lastPathComponent), ["б.pdf", "а.pdf", "в.pdf"])
    }

    func testNothingDroppedIsNotSomethingToDo() {
        let items = classify([])
        XCTAssertTrue(items.isEmpty)
        XCTAssertFalse(items.hasSomethingToDo)
        XCTAssertEqual(items.summary, "ничего")
    }

    func testTheSummaryCountsEachKindWithRussianAgreement() {
        let items = classify(
            ["/tmp/п1", "/tmp/п2", "/tmp/а.pdf", "/tmp/архив.zip"],
            folders: ["п1", "п2"], readable: ["а.pdf"]
        )
        XCTAssertEqual(items.summary, "2 папки, 1 файл, не читается: 1 файл")
    }

    func testFiveFoldersAgreeCorrectly() {
        let names = (1...5).map { "/tmp/п\($0)" }
        let items = classify(names, folders: Set(names.map { ($0 as NSString).lastPathComponent }))
        XCTAssertEqual(items.summary, "5 папок")
    }

    /// Настоящий реестр извлечения, а не выдуманный список расширений:
    /// приложение не должно обещать взять файл, который потом пропустит.
    func testTheRealRegistryDecidesWhatIsReadable() {
        let readable = DroppedItems.classify(
            [url("/tmp/договор.docx"), url("/tmp/данные.xlsx"), url("/tmp/архив.zip")],
            isDirectory: { _ in false }
        )
        XCTAssertEqual(
            readable.files.map(\.lastPathComponent).sorted(),
            ["данные.xlsx", "договор.docx"]
        )
        XCTAssertEqual(readable.unsupported.map(\.lastPathComponent), ["архив.zip"])
    }
}
