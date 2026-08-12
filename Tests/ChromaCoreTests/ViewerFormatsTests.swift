import XCTest
@testable import ChromaCore

/// оставшиеся форматы просмотрщика и совместимость сохранённых прогонов.
final class ViewerFormatsTests: XCTestCase {

    // MARK: - Прогон, записанный до появления метаданных

    /// Урок с `metrics.json`: поле, добавленное в тип, который лежит на диске,
    /// обязано читаться терпимо. Иначе все сохранённые прогоны стали бы
    /// нечитаемыми — а это часы работы модели.
    func testARunSavedBeforeMetadataStillReads() throws {
        let json = """
        {
          "id": "8B1F2C3E5F-4A6B-8C9E1F2A3B4C5D",
          "text": "Доступность рассчитывается как отношение времени.",
          "distance": 0.21,
          "position": 1
        }
        """
        let hit = try JSONDecoder().decode(EvaluationHit.self, from: Data(json.utf8))
        XCTAssertEqual(hit.position, 1)
        XCTAssertEqual(hit.distance, 0.21)
        // Отсутствие метаданных — «исходник по этому прогону не открыть»,
        // а не «файл испорчен».
        XCTAssertNil(hit.metadata)
    }

    func testAHitWithMetadataSurvivesARoundTrip() throws {
        let hit = EvaluationHit(
            id: "d1", text: "текст", distance: 0.5, position: 2,
            metadata: ["source_file": .string("папка/файл.txt"), "page_number": .int(7)]
        )
        let data = try JSONEncoder().encode(hit)
        let back = try JSONDecoder().decode(EvaluationHit.self, from: data)
        XCTAssertEqual(back, hit)
        XCTAssertEqual(DocumentLocator.target(metadata: back.metadata), .page(7))
    }

    // MARK: - Таблицы

    /// Читается окно вокруг строки, а не весь лист: у таблиц, которые
    /// индексируют, десятки тысяч строк.
    func testTheTableWindowIsBoundedAroundTheRow() {
        XCTAssertEqual(TableRowLoader.contextRows, 12)
    }

    func testANonXLSXTableIsRefusedWithAnHonestReason() {
        let url = URL(fileURLWithPath: "/x/данные.numbers")
        XCTAssertThrowsError(try TableRowLoader.window(at: url, sheetName: nil, row: 1)) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("внешнем"),
                error.localizedDescription
            )
        }
    }

    /// Строка окна, которую видит человек, называет лист и номер строки.
    func testTheWindowLineNamesTheSheetAndRow() {
        let window = TableRowLoader.Window(
            sheetName: "Закупки",
            header: ["Наименование", "Цена"],
            rows: [TableRowLoader.Row(number: 42, values: ["ALD Pro", "100"], isTarget: true)],
            targetRow: 42,
            totalRowsScanned: 60
        )
        XCTAssertTrue(window.line.contains("Закупки"))
        XCTAssertTrue(window.line.contains("42"))
    }

    // MARK: - EPUB

    func testAChapterLineNamesItsNumberAndTotal() {
        let chapter = EPUBChapterLoader.Chapter(
            text: NSAttributedString(string: "текст главы"),
            title: "Глава седьмая", number: 7, totalChapters: 24
        )
        XCTAssertTrue(chapter.line.contains("7"))
        XCTAssertTrue(chapter.line.contains("24"))
        XCTAssertTrue(chapter.line.contains("Глава седьмая"))
    }

    /// Оглавления может не быть вовсе — это не повод не показывать главу.
    func testAChapterWithoutATitleStillHasALine() {
        let chapter = EPUBChapterLoader.Chapter(
            text: NSAttributedString(string: "текст"), title: nil, number: 3, totalChapters: 9
        )
        XCTAssertTrue(chapter.line.contains("без названия"), chapter.line)
    }

    func testANonEPUBIsRefused() {
        let url = URL(fileURLWithPath: "/x/не-книга.txt")
        XCTAssertThrowsError(
            try MainActor.assumeIsolated {
                try EPUBChapterLoader.chapter(at: url, chapterID: nil, spineIndex: 0)
            }
        )
    }
}
