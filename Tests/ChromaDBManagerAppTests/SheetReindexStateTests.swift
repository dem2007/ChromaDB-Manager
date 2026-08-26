import XCTest
import ChromaCore
@testable import ChromaDBManagerApp

/// когда экран предлагает переиндексировать лист, а когда молчит
///.
@MainActor
final class SheetReindexStateTests: XCTestCase {
    private func model(
        stored: SheetManifest?, draft signature: String?
    ) -> TableMappingViewModel {
        let model = TableMappingViewModel()
        model.selectedSheet = "Лист"
        if let stored { model.setIndexedSheetsForTesting(["Лист": stored]) }
        if let signature {
            // Разметка задаётся через черновик: подпись считается по нему.
            model.drafts["Лист"] = TableMapping(
                sheetName: "Лист", columns: ["Название"], roles: ["Название": .text],
                textTemplate: signature
            )
        }
        return model
    }

    private func manifest(rows: Int, signature: String) -> SheetManifest {
        var sheet = SheetManifest(sheetName: "Лист", mappingSignature: signature)
        for number in 0..<rows {
            sheet.rows["row\u{0}\(number)"] = TableRowRecord(
                documentID: "d\(number)", rowNumber: number, rowKey: nil,
                textHash: "t", metadataHash: "m"
            )
        }
        return sheet
    }

    /// Разметка разошлась с той, которой лист записан, — операция предлагается
    /// и говорит, сколько строк лежит в коллекции.
    func testAChangedMappingOffersTheReindex() {
        let model = model(stored: manifest(rows: 3, signature: "прежняя"), draft: "{Название}")
        let state = model.reindexState()
        XCTAssertEqual(state?.rows, 3)
        XCTAssertEqual(state?.changed, true)
    }

    /// Лист записан нынешней разметкой: карточка есть, но менять нечего.
    func testAnUnchangedMappingSaysSo() {
        let model = model(stored: nil, draft: "{Название}")
        let signature = model.drafts["Лист"]!.signature
        model.setIndexedSheetsForTesting(["Лист": manifest(rows: 2, signature: signature)])
        XCTAssertEqual(model.reindexState()?.changed, false)
    }

    /// Лист, который экран ещё не прочитал, сравнивать не с чем — и предлагать
    /// операцию, последствия которой неизвестны, нельзя.
    func testASheetWithoutADraftOffersNothing() {
        let model = model(stored: manifest(rows: 5, signature: "прежняя"), draft: nil)
        XCTAssertNil(model.reindexState())
    }

    /// Лист, которого нет в манифесте, не индексировался: переиндексировать
    /// нечего, достаточно синхронизации.
    func testASheetThatWasNeverIndexedOffersNothing() {
        let model = model(stored: nil, draft: "{Название}")
        XCTAssertNil(model.reindexState())
    }
    /// После очистки строк ноль — и карточка с кнопкой пропадает. На её место
    /// встаёт «лист ждёт записи»: состояние «строк в базе нет, и это
    /// мы их убрали» должно быть видно, а не жить в сообщении, которое
    /// исчезает вместе с экраном.
    func testAClearedSheetSaysItAwaitsWrite() {
        let model = model(stored: nil, draft: "{Название}")
        model.setIndexedSheetsForTesting([:], awaitingWrite: ["Лист"])

        XCTAssertNil(model.reindexState(), "предлагать переиндексацию нечего: строк ноль")
        XCTAssertTrue(model.selectedSheetAwaitsWrite, "но ждущий лист обязан о себе говорить")
    }

    /// Ждёт другой лист — выбранный молчит: напоминание относится к своему.
    func testAnotherSheetWaitingDoesNotSpeakForThisOne() {
        let model = model(stored: nil, draft: "{Название}")
        model.setIndexedSheetsForTesting([:], awaitingWrite: ["Услуги"])
        XCTAssertFalse(model.selectedSheetAwaitsWrite)
    }

    /// Записанный лист не считается ждущим — иначе напоминание осталось бы
    /// навсегда.
    func testAWrittenSheetIsNotWaiting() {
        let model = model(stored: manifest(rows: 3, signature: "прежняя"), draft: "{Название}")
        XCTAssertFalse(model.selectedSheetAwaitsWrite)
        XCTAssertNotNil(model.reindexState())
    }

}
