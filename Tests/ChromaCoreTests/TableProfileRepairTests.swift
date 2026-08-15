import XCTest
@testable import ChromaCore

/// Разбор отчёта по загрузке таблиц 13 августа 2026.
///
/// Каждая проверка здесь — про конкретный дефект из отчёта, и падение любой
/// означает возврат к поведению, которое портило уже записанные данные.
final class TableProfileRepairTests: XCTestCase {
    private func rows(_ lines: [[String]], from first: Int = 1) -> [SheetRow] {
        lines.enumerated().map { offset, values in
            var cells: [Int: CellValue] = [:]
            for (column, value) in values.enumerated() where !value.isEmpty {
                cells[column] = Double(value).map(CellValue.number) ?? .text(value)
            }
            return SheetRow(number: first + offset, cells: cells)
        }
    }

    private func mapping(
        sheet: String,
        columns: [String],
        text: String,
        key: String? = nil,
        headerRow: Int = 1,
        mode: SheetMode = .dataTable
    ) -> TableMapping {
        var roles: [String: ColumnRole] = [:]
        for column in columns { roles[column] = column == text ? .text : .metadata }
        return TableMapping(
            sheetName: sheet, mode: mode, headerRow: headerRow,
            columns: columns, roles: roles, keyColumn: key
        )
    }

    private func sheet(_ name: String, hidden: Bool = false) -> SheetInfo {
        SheetInfo(name: name, isHidden: hidden, path: "xl/worksheets/\(name).xml")
    }

    // MARK: - Чужой вариант больше не подставляется

    /// Профиль назначен файлу, но про этот лист в нём ничего нет.
    ///
    /// Раньше здесь брался `admitting.first` — первый попавшийся вариант, —
    /// и лист читался разметкой соседнего листа. С выбором «любой подходящий
    /// лист» это означало, что один разбор перехватывал всю книгу.
    func testAnAssignedProfileNoLongerLendsAForeignVariant() {
        let profile = TableProfile(
            name: "книга",
            variants: [
                TableProfile.Variant(
                    sheets: .anyMatching,
                    mapping: mapping(sheet: "Товары", columns: ["Артикул", "Название"], text: "Название", key: "Артикул")
                ),
            ]
        )
        let data = rows([["Год", "Сумма"], ["2025", "10"], ["2026", "20"]])

        let (_, match) = TableSyncService.claim(
            sheet: sheet("ФЭО"), rows: data, index: 1,
            profiles: [profile], assigned: profile
        )
        guard case .needsDecision(let reason, _, _, _) = match else {
            return XCTFail("лист без своего варианта обязан уйти в «требуют решения», а не читаться чужим: \(match)")
        }
        XCTAssertTrue(reason.contains("книга"), reason)
    }

    /// Лист, помеченный «не индексировать», не должен попасть в индекс
    /// под чужим вариантом.
    func testASkippedSheetStaysSkippedEvenWithAnyMatchingNeighbour() {
        let profile = TableProfile(
            name: "книга",
            variants: [
                TableProfile.Variant(
                    sheets: .anyMatching,
                    mapping: mapping(sheet: "Товары", columns: ["Артикул", "Название"], text: "Название", key: "Артикул")
                ),
                TableProfile.Variant(
                    sheets: .named(["Служебный"]),
                    mapping: TableMapping(sheetName: "Служебный", mode: .skip, headerRow: nil, columns: [])
                ),
            ]
        )
        let data = rows([["что-то", "и ещё"], ["1", "2"]])

        let (_, match) = TableSyncService.claim(
            sheet: sheet("Служебный"), rows: data, index: 2,
            profiles: [profile], assigned: profile
        )
        guard case .matched(_, let variant) = match else {
            return XCTFail("вариант «не индексировать» обязан взять свой лист: \(match)")
        }
        XCTAssertEqual(variant.mapping.mode, .skip, "иначе лист прочитается разметкой соседа")
    }

    // MARK: - Недостающие колонки метаданных

    /// Колонки называются годами, а годы у документов разные.
    ///
    /// Точное совпадение набора означало, что отчёт за 2026–2027 не совпадёт
    /// с профилем, снятым с отчёта за 2025–2030, — и файл целиком уходил
    /// в «требуют решения». От недостающей суммы за 2030 год теряется один
    /// фильтр, а не смысл строки.
    func testAssignedProfileToleratesMissingMetadataColumns() {
        let variant = TableProfile.Variant(
            sheets: .named(["ФЭО"]),
            mapping: mapping(
                sheet: "ФЭО",
                columns: ["№", "Наименование", "2025", "2026", "2027", "2028"],
                text: "Наименование", key: "№"
            )
        )
        let acceptance = variant.accepts(columns: ["№", "Наименование", "2026", "2027"], strict: false)
        XCTAssertTrue(acceptance.matches, "недостающие годы не должны отменять разбор")
        XCTAssertFalse(acceptance.exact, "и при этом совпадение обязано считаться неточным")
        XCTAssertEqual(acceptance.missing, ["2025", "2028"], "о недостающих колонках надо сказать поимённо")
    }

    /// А вот без колонки с текстом разбирать нечего.
    func testAMissingTextColumnStillRefuses() {
        let variant = TableProfile.Variant(
            sheets: .named(["ФЭО"]),
            mapping: mapping(
                sheet: "ФЭО", columns: ["№", "Наименование", "2025"],
                text: "Наименование", key: "№"
            )
        )
        XCTAssertFalse(
            variant.accepts(columns: ["№", "2025", "2026"], strict: false).matches,
            "строка без текста — это документ без содержимого"
        )
    }

    /// Подбор остаётся строгим: он **угадывает**, чем читать лист, и ошибка
    /// в догадке пишет в базу документы с чужой разметкой.
    func testAutomaticMatchingStaysStrict() {
        let variant = TableProfile.Variant(
            sheets: .anyMatching,
            mapping: mapping(sheet: "Лист1", columns: ["№", "Наименование", "2025"], text: "Наименование", key: "№")
        )
        XCTAssertFalse(variant.accepts(columns: ["№", "Наименование"]).matches)
        XCTAssertTrue(variant.accepts(columns: ["№", "Наименование", "2025"]).matches)
    }

    // MARK: - Разметка по буквам колонок

    func testLetteredShapeNamesColumnsAsTheSpreadsheetDoes() {
        let data = rows([["Товар", "10", "шт"], ["Ещё", "20", "кг"]])
        let shape = SheetModeDetector.lettered(rows: data, headerRow: 0)
        XCTAssertEqual(shape.columns, ["A", "B", "C"])
        XCTAssertEqual(shape.headerRow, 0)
        XCTAssertEqual(shape.mode, .dataTable)
    }

    /// Данные начинаются под указанной строкой — и при разметке по буквам тоже.
    func testDataStartsBelowTheDeclaredHeaderRow() {
        let data = rows([["шапка", ""], ["Товар", "10"], ["Ещё", "20"]])
        let shape = SheetModeDetector.lettered(rows: data, headerRow: 1)
        let plan = TableSyncPlanner.plan(
            rows: data,
            mapping: TableMapping(
                sheetName: "Лист1", mode: .dataTable, headerRow: 1,
                columns: shape.columns, roles: ["A": .text, "B": .metadata]
            ),
            layout: SheetLayout(shape: shape),
            manifest: SheetManifest(sheetName: "Лист1"),
            sourceID: UUID(), sourceFile: "файл.xlsx"
        )
        XCTAssertEqual(plan.added.count, 2, "строка 1 объявлена служебной и записью быть не должна")
    }

    /// Разметку по буквам надо узнать при следующем прогоне: автоопределение
    /// её не воспроизведёт — заголовков в той строке нет.
    func testALetteredMappingIsRecognisedOnTheNextRun() {
        let data = rows([["Товар", "10"], ["Ещё", "20"]])
        let profile = TableProfile(
            name: "без шапки",
            variants: [
                TableProfile.Variant(
                    sheets: .named(["Лист1"]),
                    mapping: TableMapping(
                        sheetName: "Лист1", mode: .dataTable, headerRow: 0,
                        columns: ["A", "B"], roles: ["A": .text, "B": .metadata]
                    )
                ),
            ]
        )
        let (shape, match) = TableSyncService.claim(
            sheet: sheet("Лист1"), rows: data, index: 0,
            profiles: [profile], assigned: profile
        )
        XCTAssertEqual(shape.columns, ["A", "B"])
        guard case .matched = match else {
            return XCTFail("профиль по буквам обязан узнаваться, иначе он живёт только в редакторе: \(match)")
        }
    }

    func testLetterColumnsAreRecognisableFromTheMappingItself() {
        let lettered = TableMapping(sheetName: "Л", columns: ["A", "B", "C"])
        XCTAssertTrue(lettered.usesColumnLetters)
        // Достаточно одного настоящего названия, чтобы это была обычная шапка.
        let named = TableMapping(sheetName: "Л", columns: ["A", "Название", "C"])
        XCTAssertFalse(named.usesColumnLetters)
        XCTAssertFalse(TableMapping(sheetName: "Л", columns: []).usesColumnLetters)
    }

    // MARK: - Пересчёт разметки на колонки файла

    /// Профиль говорит, что колонки значат; файл — какие они и где.
    ///
    /// Подставленная целиком разметка профиля показывала колонки профиля:
    /// колонок, которые есть в файле и которых профиль не знает, в редакторе
    /// не было вовсе, и добавить их было нечем.
    func testRebasingKeepsRolesAndPicksUpTheFilesOwnColumns() {
        let saved = mapping(
            sheet: "ФЭО", columns: ["№", "Наименование", "2025"],
            text: "Наименование", key: "№"
        )
        let shape = SheetShape(
            mode: .dataTable, headerRow: 4,
            columns: ["№", "Наименование", "2026", "Примечание"], reason: ""
        )
        let rebased = saved.rebased(on: shape)

        XCTAssertEqual(rebased.columns, ["№", "Наименование", "2026", "Примечание"])
        XCTAssertEqual(rebased.role(of: "Наименование"), .text, "роль обязана уцелеть")
        XCTAssertEqual(rebased.keyColumn, "№")
        XCTAssertEqual(rebased.headerRow, 4, "строка заголовка берётся у файла")
        XCTAssertNotEqual(rebased.role(of: "Примечание"), .ignore, "новая колонка получает предположение, а не пустоту")
        XCTAssertNil(rebased.roles["2025"], "колонки, которой в файле нет, в разметке быть не должно")
    }

    /// Ключ, потерявшийся вместе с колонкой, заменяется предположением,
    /// а не остаётся ссылкой в никуда.
    func testARebasedMappingDoesNotKeepAKeyThatIsGone() {
        let saved = mapping(sheet: "Л", columns: ["Артикул", "Название"], text: "Название", key: "Артикул")
        let shape = SheetShape(mode: .dataTable, headerRow: 1, columns: ["Код", "Название"], reason: "")
        let rebased = saved.rebased(on: shape)
        XCTAssertNotEqual(rebased.keyColumn, "Артикул")
    }
}
