import XCTest
import ChromaCore
@testable import ChromaDBManagerApp

/// «Заполнить названия из файла» — кнопка, которая переносит заголовки
/// в поля «Своё название».
@MainActor
final class ColumnTitleFillTests: XCTestCase {
    private func model(
        columns: [String], titles: [String: String] = [:]
    ) -> TableMappingViewModel {
        let model = TableMappingViewModel()
        model.drafts["Лист"] = TableMapping(
            sheetName: "Лист", columns: columns,
            roles: columns.reduce(into: [:]) { $0[$1] = .metadata },
            titles: titles
        )
        return model
    }

    /// Главное: имя из файла оказывается в поле, откуда его можно править.
    /// Пустое поле значит «как в файле», но правят имя ровно тогда, когда оно
    /// почти годится, — и набирать его заново незачем.
    func testTitlesAreCopiedFromTheFile() {
        let model = model(columns: ["Продолжи-тельность (мес)", "Результаты этапа"])
        model.fillTitlesFromFile(for: "Лист")

        let mapping = model.drafts["Лист"]
        XCTAssertEqual(mapping?.titles["Продолжи-тельность (мес)"], "Продолжи-тельность (мес)")
        XCTAssertEqual(mapping?.titles["Результаты этапа"], "Результаты этапа")
        XCTAssertEqual(model.infoMessage?.contains("2") , true, "сказано, сколько названий перенесено")
    }

    /// Уже заданное название не трогается: человек его правил, и наше
    /// удобство этого не отменяет.
    func testAnEditedTitleIsLeftAlone() {
        let model = model(columns: ["Цена", "Срок"], titles: ["Цена": "Цена без НДС"])
        model.fillTitlesFromFile(for: "Лист")

        XCTAssertEqual(model.drafts["Лист"]?.titles["Цена"], "Цена без НДС")
        XCTAssertEqual(model.drafts["Лист"]?.titles["Срок"], "Срок")
    }

    /// Лист размечен по буквам колонок: заголовков в файле нет, и «A»
    /// в качестве имени не лучше пустого поля.
    func testColumnLettersAreNotCopied() {
        let model = model(columns: ["A", "B", "C"])
        model.fillTitlesFromFile(for: "Лист")

        XCTAssertTrue(model.drafts["Лист"]?.titles.isEmpty == true)
        XCTAssertEqual(model.infoMessage?.contains("нечего"), true, "человеку сказано, почему ничего не изменилось")
    }

    /// Буква — это адрес колонки, а не её смысл: пропускается только та,
    /// что стоит на своём месте. Колонка, которую в файле **назвали** «B»,
    /// а стоит она третьей, — это название.
    func testALetterOnAnotherPositionIsATitle() {
        let model = model(columns: ["Год", "Сумма", "B"])
        model.fillTitlesFromFile(for: "Лист")

        XCTAssertEqual(model.drafts["Лист"]?.titles["B"], "B")
    }

    /// Кнопка на листе, которого нет, ничего не портит.
    func testAnUnknownSheetIsIgnored() {
        let model = model(columns: ["Год"])
        model.fillTitlesFromFile(for: "Другой")
        XCTAssertTrue(model.drafts["Лист"]?.titles.isEmpty == true)
    }
}
