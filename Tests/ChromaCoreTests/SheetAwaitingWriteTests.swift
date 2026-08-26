import XCTest
@testable import ChromaCore

/// Очищенный лист напоминает о себе, пока не записан.
///
/// Из разбора предыдущей правки: после нажатия кнопки лист исчезал из
/// манифеста целиком, карточка с кнопкой пропадала вместе с ним — она живёт,
/// пока строк больше нуля, — и единственным следом оставалось сообщение на
/// экране. Закрыли экран, и состояние «пятисот строк в базе нет, и это мы их
/// убрали» не хранилось нигде.
final class SheetAwaitingWriteTests: XCTestCase {
    private func manifest(withRows rows: Int) -> TableFileManifest {
        var sheet = SheetManifest(sheetName: "Трудозатраты")
        for number in 1...rows {
            sheet.rows["строка-\(number)"] = TableRowRecord(
                documentID: "id-\(number)", rowNumber: number, rowKey: "строка-\(number)",
                textHash: "текст", metadataHash: "поля"
            )
        }
        sheet.mappingSignature = "подпись"
        return TableFileManifest(
            relativePath: "смета.xlsx", collectionName: "база",
            sheets: ["Трудозатраты": sheet], profilesSignature: "профили"
        )
    }

    /// Признак ставится там же, где лист забывают.
    func testForgettingASheetMarksItAsAwaitingWrite() {
        var file = manifest(withRows: 3)
        XCTAssertTrue(file.sheetsAwaitingWrite.isEmpty)

        let forgotten = file.forgetSheet("Трудозатраты")

        XCTAssertEqual(forgotten.count, 3, "идентификаторы строк нужны вызывающему — их кладут в корзину")
        XCTAssertEqual(file.sheetsAwaitingWrite, ["Трудозатраты"])
        XCTAssertNil(file.sheets["Трудозатраты"], "сам лист манифест больше не помнит")
        XCTAssertEqual(file.rowCount, 0)
    }

    /// Лист, которого в манифесте не было, ждать записи не начинает: нечего
    /// было очищать — нечего и обещать.
    func testAnUnknownSheetIsNotMarked() {
        var file = manifest(withRows: 2)
        XCTAssertTrue(file.forgetSheet("Другой").isEmpty)
        XCTAssertTrue(file.sheetsAwaitingWrite.isEmpty)
    }

    /// Признак снимается записью.
    func testWritingTheSheetClearsTheFlag() {
        var file = manifest(withRows: 2)
        _ = file.forgetSheet("Трудозатраты")
        XCTAssertFalse(file.sheetsAwaitingWrite.isEmpty)

        file.noteSheetWritten("Трудозатраты")
        XCTAssertTrue(file.sheetsAwaitingWrite.isEmpty, "лист записан — ждать больше нечего")
    }

    /// Ожидание переживает перезапуск: оно лежит в манифесте, а не в экране.
    func testTheFlagSurvivesASaveAndLoad() throws {
        var file = manifest(withRows: 4)
        _ = file.forgetSheet("Трудозатраты")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let read = try decoder.decode(TableFileManifest.self, from: try encoder.encode(file))

        XCTAssertEqual(read.sheetsAwaitingWrite, ["Трудозатраты"])
    }

    /// Манифест, записанный до появления признака, читается как «ничего
    /// не ждёт» — а не падает на отсутствующем поле.
    func testAnOlderManifestReadsAsNothingAwaiting() throws {
        let json = """
        {
          "relativePath": "смета.xlsx",
          "collectionName": "база",
          "sheets": {},
          "modifiedAt": "2026-08-01T10:00:00Z",
          "size": 1024,
          "profilesSignature": "профили",
          "pendingRemovals": {}
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let read = try decoder.decode(TableFileManifest.self, from: Data(json.utf8))

        XCTAssertTrue(read.sheetsAwaitingWrite.isEmpty)
        XCTAssertEqual(read.relativePath, "смета.xlsx")
    }

    /// Хранилище отдаёт ждущие листы тем же способом, что и строки на решение:
    /// экранам нужен готовый список, а не словарь манифестов.
    func testTheStoreListsAwaitingSheetsForTheScreens() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cdbm-awaiting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = TableManifestStore(directory: directory)
        let sourceID = UUID()
        var file = manifest(withRows: 2)
        _ = file.forgetSheet("Трудозатраты")
        store.save([file.relativePath: file], sourceID: sourceID)

        let awaiting = store.sheetsAwaitingWrite(sourceID: sourceID)
        XCTAssertEqual(awaiting.count, 1)
        XCTAssertEqual(awaiting.first?.sheetName, "Трудозатраты")
        XCTAssertEqual(awaiting.first?.collectionName, "база")
        XCTAssertEqual(awaiting.first?.title, "смета.xlsx → Трудозатраты", "так лист называют человеку")
    }
}
