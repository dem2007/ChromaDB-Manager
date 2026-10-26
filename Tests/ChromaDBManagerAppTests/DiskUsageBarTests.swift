import XCTest
@testable import ChromaDBManagerApp

/// Полоса «Места на диске»: маленькие части видны, а полоса не шире себя.
final class DiskUsageBarTests: XCTestCase {
    /// Живой случай: журналы — десятая доля процента, служебные данные — один
    /// процент. С «не меньше трёх точек» поверх доли полоса выходила за край,
    /// и последний её кусок обрезался.
    func testSmallPartsAreVisibleAndTheBarKeepsItsWidth() {
        let widths = DiskUsageSection.segmentWidths([6_000, 350, 18_700, 990, 20, 240], in: 400)
        XCTAssertEqual(widths.reduce(0, +), 400, accuracy: 0.001, "\(widths)")
        XCTAssertTrue(widths.allSatisfy { $0 >= 3 }, "\(widths)")
        XCTAssertGreaterThan(widths[2], widths[0], "доли сохраняют порядок")
    }

    /// Часть чуть выше минимума после сжатия остальных под него не уходит.
    func testAPartJustAboveTheMinimumStaysAtLeastAtIt() {
        let widths = DiskUsageSection.segmentWidths([1, 1, 1, 31, 1_000], in: 100)
        XCTAssertEqual(widths.reduce(0, +), 100, accuracy: 0.001, "\(widths)")
        XCTAssertTrue(widths.allSatisfy { $0 >= 3 - 0.0001 }, "\(widths)")
    }

    func testNothingToShowGivesNoWidth() {
        XCTAssertEqual(DiskUsageSection.segmentWidths([0, 0], in: 400), [0, 0])
    }
}
