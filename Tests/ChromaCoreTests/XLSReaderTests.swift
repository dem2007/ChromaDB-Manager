import XCTest
@testable import ChromaCore

/// старая книга Excel читается своей читалкой, без Numbers.
final class XLSReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cdbm-xls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ fixture: XLSFixture, name: String = "книга.xls") throws -> URL {
        let url = root.appendingPathComponent(name)
        try fixture.build().write(to: url)
        return url
    }

    /// Главное: лист, его имя и значения всех видов.
    func testAWorkbookIsRead() throws {
        let url = try write(XLSFixture(sheets: [.init(name: "Прайс", rows: [
            [.shared("Артикул"), .shared("Наименование"), .shared("Цена")],
            [.shared("АРТ-1001"), .shared("Кабель UTP 5e"), .number(1250)],
            [.shared("АРТ-1002"), .inline("Розетка RJ-45"), .compact(340)],
        ])]))

        let reader = try XLSReader(url: url)
        XCTAssertEqual(reader.sheets.map(\.name), ["Прайс"])

        let (rows, warnings) = try reader.rows(of: try XCTUnwrap(reader.sheets.first))
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].cells[0], .text("Артикул"))
        XCTAssertEqual(rows[1].cells[1], .text("Кабель UTP 5e"))
        XCTAssertEqual(rows[1].cells[2], .number(1250))
        XCTAssertEqual(rows[2].cells[1], .text("Розетка RJ-45"), "строка прямо в ячейке тоже читается")
        XCTAssertEqual(rows[2].cells[2], .number(340), "сжатое число разворачивается")
        XCTAssertTrue(warnings.isEmpty, "\(warnings)")
    }

    /// Дата отличается от числа только форматом ячейки — как и в `.xlsx`.
    func testADateIsADateAndNotANumber() throws {
        let url = try write(XLSFixture(sheets: [.init(name: "Лист", rows: [
            [.date(45_000), .number(45_000)],
        ])]))
        let reader = try XLSReader(url: url)
        let rows = try reader.rows(of: try XCTUnwrap(reader.sheets.first)).rows

        guard case .date(let date)? = rows[0].cells[0] else {
            return XCTFail("первая ячейка должна быть датой: \(String(describing: rows[0].cells[0]))")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(calendar.component(.year, from: date), 2023)
        XCTAssertEqual(rows[0].cells[1], .number(45_000), "то же число без формата датой не становится")
    }

    /// Формулы не вычисляются: берётся значение, записанное Excel.
    func testFormulasKeepTheirCachedValue() throws {
        let url = try write(XLSFixture(sheets: [.init(name: "Лист", rows: [
            [.formula(2500), .formulaText("Итого"), .boolean(true), .blank],
        ])]))
        let reader = try XLSReader(url: url)
        let rows = try reader.rows(of: try XCTUnwrap(reader.sheets.first)).rows

        XCTAssertEqual(rows[0].cells[0], .number(2500))
        XCTAssertEqual(rows[0].cells[1], .text("Итого"))
        XCTAssertEqual(rows[0].cells[2], .boolean(true))
        XCTAssertNil(rows[0].cells[3], "пустая ячейка — это отсутствие значения, а не пустая строка")
    }

    /// Главная ловушка формата: таблица общих строк не влезает в одну запись,
    /// и строка рвётся её границей. Молчаливая ошибка — текст выходит
    /// крякозябрами, поэтому проверяется на книге с длинной таблицей.
    func testSharedStringsSurviveRecordBoundaries() throws {
        let url = try write(XLSFixture(
            sheets: [.init(name: "Лист", rows: [
                [.shared("Первая строка книги")],
                [.shared("Последняя строка книги")],
            ])],
            padStrings: 400
        ))
        let reader = try XLSReader(url: url)
        let rows = try reader.rows(of: try XCTUnwrap(reader.sheets.first)).rows
        XCTAssertEqual(rows[0].cells[0], .text("Первая строка книги"))
        XCTAssertEqual(rows[1].cells[0], .text("Последняя строка книги"))
    }

    /// Скрытый лист остаётся скрытым: решение, показывать ли его, принимает
    /// не читалка.
    func testHiddenSheetsAreMarked() throws {
        let url = try write(XLSFixture(sheets: [
            .init(name: "Видимый", rows: [[.shared("а")]]),
            .init(name: "Скрытый", isHidden: true, rows: [[.shared("б")]]),
        ]))
        let reader = try XLSReader(url: url)
        XCTAssertEqual(reader.sheets.map(\.name), ["Видимый", "Скрытый"])
        XCTAssertEqual(reader.sheets.map(\.isHidden), [false, true])

        // И читается именно второй лист, а не первый.
        let rows = try reader.rows(of: reader.sheets[1]).rows
        XCTAssertEqual(rows[0].cells[0], .text("б"))
    }

    /// Не книга — отказ с причиной, а не пустой результат.
    func testANonWorkbookIsRefusedWithAReason() throws {
        let url = root.appendingPathComponent("документ.xls")
        try DocFixture(paragraphs: ["Это документ Word, а не книга."]).build().write(to: url)
        XCTAssertThrowsError(try XLSReader(url: url)) { error in
            XCTAssertEqual(error as? XLSError, .notAWorkbook(String(localized: "в контейнере нет потока книги")))
        }
    }
}
