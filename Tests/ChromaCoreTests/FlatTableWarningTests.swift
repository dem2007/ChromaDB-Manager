import XCTest
@testable import ChromaCore

/// Плоская таблица во фрагменте — предупреждение агенту.
///
/// Из живого разбора: страница со сметой ушла в базу сеткой чисел без
/// названий колонок, и агент посчитал по ней смету — выдал одну позицию
/// двумя, каждую с полной ценой. Ни одного признака, что фрагменту нельзя
/// верить, в ответе не было.
final class FlatTableWarningTests: XCTestCase {
    private func payload(_ id: String, flat: Bool) -> MCPDocumentPayload {
        var metadata: ChromaMetadata = ["source_file": .string("смета.pdf")]
        if flat { metadata["tables_flat"] = .bool(true) }
        return MCPDocumentPayload(id: id, text: "10.1 1 31 585 738,00", metadata: metadata)
    }

    func testAFlatTableIsCalledOutInTheAnswer() {
        let output = MCPDocumentRendering.render(
            [payload("1", flat: true), payload("2", flat: false)],
            limits: MCPOutputLimits()
        )
        XCTAssertTrue(
            output.notes.contains { $0.contains("колонки в ней не разделены") },
            "\(output.notes)"
        )
    }

    /// Там, где таблицы собрались, лишних предупреждений быть не должно:
    /// оговорка на каждом ответе перестаёт читаться.
    func testAnAssembledTableIsNotWarnedAbout() {
        let output = MCPDocumentRendering.render(
            [payload("1", flat: false)], limits: MCPOutputLimits()
        )
        XCTAssertFalse(output.notes.contains { $0.contains("колонки") }, "\(output.notes)")
    }

    /// Признак ставится по разбору, а не по разбору русской фразы: у оговорки
    /// про несобранную таблицу свой случай перечисления.
    func testTheWarningKnowsItsOwnCase() {
        let assembled = ExtractionWarning.tablesFlattened
        let notAssembled = ExtractionWarning.tablesNotAssembled(pages: 3)
        XCTAssertNotEqual(assembled, notAssembled)
        XCTAssertTrue(notAssembled.text.contains("3"), notAssembled.text)
        XCTAssertTrue(notAssembled.text.contains("колонки"), notAssembled.text)
    }
}
