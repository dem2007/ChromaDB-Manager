import XCTest
import ChromaCore
@testable import ChromaDBManagerApp

/// Массовый выбор находок в «Обзоре коллекции».
///
/// Живой случай: 310 находок, из них 213 «дубли по тексту» и 93 «похожие
/// документы». Решение о них одно на весь разряд, а отмечать приходилось
/// по одному флажку — то есть не отмечать вовсе.
@MainActor
final class InsightsBulkSelectionTests: XCTestCase {
    private func finding(
        _ category: InspectionCategory, _ subject: String, documents: [String]
    ) -> InspectionFinding {
        InspectionFinding(category: category, documentIDs: documents, subject: subject)
    }

    private func model(with findings: [InspectionFinding]) -> InspectorViewModel {
        let model = InspectorViewModel()
        model.report = InspectionReport(
            collectionName: "коллекция", examined: 100, total: 100, findings: findings
        )
        return model
    }

    func testAWholeCategoryIsChosenAtOnce() {
        let model = model(with: [
            finding(.duplicates, "первый", documents: ["a1", "a2"]),
            finding(.duplicates, "второй", documents: ["b1"]),
            finding(.emptyDocuments, "третий", documents: ["c1"]),
        ])

        XCTAssertTrue(model.toggleSelection(in: .duplicates), "разряд выбран")
        XCTAssertEqual(model.selectedFindings.count, 2)
        XCTAssertTrue(model.isEverythingSelected(in: .duplicates))
        XCTAssertFalse(model.isEverythingSelected(), "соседний разряд не трогали")
        XCTAssertEqual(model.selectedDocumentIDs(), ["a1", "a2", "b1"])
    }

    /// Второе нажатие снимает — кнопка переключает, а не только добавляет.
    func testTheSameButtonClearsTheCategory() {
        let model = model(with: [
            finding(.duplicates, "первый", documents: ["a1"]),
            finding(.duplicates, "второй", documents: ["b1"]),
        ])
        model.toggleSelection(in: .duplicates)
        XCTAssertFalse(model.toggleSelection(in: .duplicates), "разряд снят")
        XCTAssertTrue(model.selectedFindings.isEmpty)
    }

    /// «Выбрать все замечания» берёт весь отчёт.
    func testEverythingAtOnce() {
        let model = model(with: [
            finding(.duplicates, "первый", documents: ["a1"]),
            finding(.emptyDocuments, "второй", documents: ["b1"]),
            finding(.nearDuplicates, "третий", documents: ["c1", "c2"]),
        ])
        XCTAssertTrue(model.toggleSelection())
        XCTAssertEqual(model.selectedFindings.count, 3)
        XCTAssertTrue(model.isEverythingSelected())
        XCTAssertEqual(model.selectedDocumentIDs().count, 4)
    }

    /// Находка без документов не выбирается: удалять и помечать в ней нечего,
    /// и флажка у неё в списке нет. Кнопка обязана считать так же — иначе она
    /// обещает то, чего не сделает.
    func testFindingsWithoutDocumentsAreNotCounted() {
        let model = model(with: [
            finding(.duplicates, "с документами", documents: ["a1"]),
            finding(.substitutedChunking, "без документов", documents: []),
        ])
        XCTAssertEqual(model.selectable().count, 1)
        model.toggleSelection()
        XCTAssertEqual(model.selectedFindings, ["duplicates|с документами|a1"])
        XCTAssertTrue(model.isEverythingSelected(), "выбрано всё, что вообще выбирается")
    }

    /// Выбор разряда не отменяет уже отмеченного руками в соседнем.
    func testChoosingACategoryKeepsWhatWasPickedByHand() {
        let single = finding(.emptyDocuments, "руками", documents: ["z1"])
        let model = model(with: [
            single,
            finding(.duplicates, "первый", documents: ["a1"]),
        ])
        model.toggleSelection(single)
        model.toggleSelection(in: .duplicates)
        XCTAssertEqual(model.selectedFindings.count, 2)
    }

    /// Отчёта нет — нажимать нечего, и падать тоже.
    func testNothingToChooseWithoutAReport() {
        let model = InspectorViewModel()
        XCTAssertTrue(model.selectable().isEmpty)
        XCTAssertFalse(model.toggleSelection())
        XCTAssertFalse(model.isEverythingSelected())
    }
}
