import XCTest
@testable import ChromaCore

/// Numbers with nouns after them. A diagnostics line that reads «в 1 разделов»
/// makes the reader doubt the numbers, which is the one thing the panel cannot
/// afford.
final class RussianCountTests: XCTestCase {
    private func раздел(_ count: Int) -> String {
        RussianCount.phrase(count, "раздел", "раздела", "разделов")
    }

    func testTheThreeForms() {
        XCTAssertEqual(раздел(1), "1 раздел")
        XCTAssertEqual(раздел(2), "2 раздела")
        XCTAssertEqual(раздел(4), "4 раздела")
        XCTAssertEqual(раздел(5), "5 разделов")
        XCTAssertEqual(раздел(0), "0 разделов")
    }

    /// The teens are the exception the last digit alone gets wrong.
    func testTheTeensTakeTheManyForm() {
        for count in 11...14 {
            XCTAssertEqual(раздел(count), "\(count) разделов")
        }
        XCTAssertEqual(раздел(111), "111 разделов")
        XCTAssertEqual(раздел(112), "112 разделов")
    }

    func testTheRuleRepeatsEveryHundred() {
        XCTAssertEqual(раздел(21), "21 раздел")
        XCTAssertEqual(раздел(22), "22 раздела")
        XCTAssertEqual(раздел(25), "25 разделов")
        XCTAssertEqual(раздел(101), "101 раздел")
    }

    func testTheCollapseNoteReadsLikeRussian() {
        var hit = RetrievalHit(id: "a", document: nil, metadata: nil, distance: nil)
        hit.collapsed = 1
        XCTAssertEqual(hit.collapsedNote, "ещё 1 совпадение в этом разделе")
        hit.collapsed = 3
        XCTAssertEqual(hit.collapsedNote, "ещё 3 совпадения в этом разделе")
        hit.collapsed = 11
        XCTAssertEqual(hit.collapsedNote, "ещё 11 совпадений в этом разделе")
    }

    func testAHistoryRowWithOneResultReadsLikeRussian() {
        let entry = QueryHistoryEntry(
            text: "з", collectionName: "к", profileName: "По умолчанию",
            resultCount: 1, duration: 0.012
        )
        XCTAssertEqual(entry.line, "1 результат · 12 мс · профиль «По умолчанию»")
    }
}
