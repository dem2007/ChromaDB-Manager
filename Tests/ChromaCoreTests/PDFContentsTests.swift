import XCTest
@testable import ChromaCore

/// оглавление PDF не индексируется.
final class PDFContentsTests: XCTestCase {
    func testAContentsBlockIsRemovedWithItsWrappedEntriesAndTitle() {
        let lines = [
            "Техническое задание",
            "Содержание",
            "1.1 Назначение документа............................ 18",
            "1.2 Сведения о сторонах ............................. 18",
            "Приложение Р Образец акта приёмки выполненных работ по",
            "этапу внедрения .................................... 460",
            "Приложение Т Форма Акта ..... Ошибка! Закладка не определена.",
            "Определения, обозначения и сокращения",
        ]
        let result = PDFContents.removing(lines, continuing: false)
        XCTAssertEqual(result.lines, ["Техническое задание", "Определения, обозначения и сокращения"])
        XCTAssertEqual(result.removed, 6)
        XCTAssertFalse(result.endsInContents)
    }

    /// Одна строка с отточием в бланке — не оглавление.
    func testASingleLeaderLineStays() {
        let lines = ["Итого к оплате ........ 5", "Подпись"]
        XCTAssertEqual(PDFContents.removing(lines, continuing: false).lines, lines)
    }

    /// Страница, продолжающая оглавление предыдущей, убирается и с одной записью.
    func testAContinuationPageNeedsOneEntry() {
        let first = (1...4).map { "\($0) Раздел номер \($0) ............ \($0 + 2)" } + ["2"]
        let page = PDFContents.removing(first, continuing: false)
        XCTAssertTrue(page.endsInContents)
        let next = PDFContents.removing(["5 Последний раздел ......... 9", "", "1 Общие положения", "Текст."], continuing: true)
        XCTAssertEqual(next.lines, ["", "1 Общие положения", "Текст."])
    }

    /// Записи, перенесённые на несколько строк, с номером страницы строкой
    /// ниже отточия и без отточия вовсе; текст после оглавления остаётся.
    func testWrappedEntriesAndTheirTailsGoTextAfterStays() {
        let lines = [
            "2",
            "1.17 Порядок взаимодействия сторон при выполнении работ и передаче результатов по",
            "этапам 51",
            "9.7.3 Требования к подсистеме учёта и хранения электронных",
            "документов и сведений о ходе их согласования участниками",
            "процесса обмена с внешними системами по расписанию",
            "и по запросу .........................................................",
            "9.7.4 Требования к отчётам ........................................... 70",
            "9.7.5 Требования к журналу ........................................... 71",
            "событий 72",
            "",
            "1 Общие положения",
            "Настоящее техническое задание определяет требования к услугам.",
        ]
        let result = PDFContents.removing(lines, continuing: false)
        XCTAssertEqual(result.lines, ["", "1 Общие положения", "Настоящее техническое задание определяет требования к услугам."])
    }
}
