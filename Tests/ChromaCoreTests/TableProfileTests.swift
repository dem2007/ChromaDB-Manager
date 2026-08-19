import XCTest
@testable import ChromaCore

/// a mapping saved once and recognised again, and what happens when a
/// file does not match.
final class TableProfileTests: XCTestCase {
    private func profile(
        name: String = "Каталог",
        columns: [String] = ["Артикул", "Название", "Цена"],
        sheets: SheetSelection = .anyMatching
    ) -> TableProfile {
        TableProfile(
            name: name,
            sheets: sheets,
            mapping: TableMapping(
                sheetName: "Лист1", columns: columns,
                roles: Dictionary(uniqueKeysWithValues: columns.map { ($0, ColumnRole.metadata) }),
                keyColumn: columns.first
            )
        )
    }

    private func match(
        _ profiles: [TableProfile],
        columns: [String],
        sheetName: String = "Лист1",
        index: Int = 0
    ) -> TableProfileMatch {
        TableProfileMatcher.match(profiles: profiles, sheetName: sheetName, sheetIndex: index, columns: columns)
    }

    // MARK: - Matching

    func testAFileWithTheSameHeadersMatches() {
        let saved = profile()
        let result = match([saved], columns: ["Артикул", "Название", "Цена"])
        XCTAssertEqual(result.profile?.id, saved.id)
    }

    /// A set, not a list: columns are resolved by title, so a file that puts
    /// them in another order is the same table.
    func testColumnOrderDoesNotMatter() {
        let saved = profile()
        XCTAssertNotNil(match([saved], columns: ["Цена", "Артикул", "Название"]).profile)
    }

    /// Neither is a capital letter or a stray space — an export tool changes
    /// those between versions without changing the table.
    func testCaseAndSpacingDoNotMatter() {
        let saved = profile()
        XCTAssertNotNil(match([saved], columns: [" артикул", "НАЗВАНИЕ", "Цена "]).profile)
    }

    // MARK: - The rule this section rests on

    /// a file with a different set of columns is **not** processed «как
    /// получится». Half-mapping produces documents silently missing the column
    /// somebody filters by — a failure that surfaces as an empty search result
    /// weeks later.
    func testAnExtraColumnDoesNotSilentlyMatch() {
        let result = match([profile()], columns: ["Артикул", "Название", "Цена", "Склад"])
        guard case .needsDecision(let reason, let closest, let missing, let extra) = result else {
            return XCTFail("ожидалось «требует решения», получено \(result)")
        }
        XCTAssertEqual(closest?.name, "Каталог")
        XCTAssertTrue(missing.isEmpty)
        XCTAssertEqual(extra, ["Склад"])
        XCTAssertTrue(reason.contains("Склад"), reason)
    }

    /// The offer has to name the difference, or «не подошло» is all the user
    /// gets to work with.
    func testAMissingColumnIsNamedInTheOffer() {
        let result = match([profile()], columns: ["Артикул", "Название"])
        guard case .needsDecision(let reason, _, let missing, _) = result else {
            return XCTFail("ожидалось «требует решения»")
        }
        XCTAssertEqual(missing, ["Цена"])
        XCTAssertTrue(reason.contains("Цена"), reason)
    }

    /// The closest profile is the one sharing the most columns, so the offer
    /// points at the one worth editing.
    func testTheClosestProfileIsOffered() {
        let catalogue = profile(name: "Каталог", columns: ["Артикул", "Название", "Цена"])
        let contacts = profile(name: "Контакты", columns: ["Email", "Телефон"])
        let result = match([contacts, catalogue], columns: ["Артикул", "Название", "Цена", "Склад"])
        guard case .needsDecision(_, let closest, _, _) = result else { return XCTFail("ожидалось «требует решения»") }
        XCTAssertEqual(closest?.name, "Каталог")
    }

    func testWithoutAnyProfileTheSheetAsksForOne() {
        let result = match([], columns: ["Артикул"])
        guard case .needsDecision(let reason, let closest, _, _) = result else {
            return XCTFail("ожидалось «требует решения»")
        }
        XCTAssertNil(closest)
        XCTAssertTrue(reason.contains("ещё нет профиля"), reason)
    }

    // MARK: - Sheet selection

    func testANamedSelectionOnlyAdmitsThatSheet() {
        let saved = profile(sheets: .named(["Данные"]))
        XCTAssertNotNil(match([saved], columns: ["Артикул", "Название", "Цена"], sheetName: "Данные").profile)

        let elsewhere = match([saved], columns: ["Артикул", "Название", "Цена"], sheetName: "Другой")
        guard case .needsDecision(let reason, let closest, let missing, let extra) = elsewhere else {
            return XCTFail("лист вне выбора не должен совпадать")
        }
        // Worth distinguishing: the columns are right, only the sheet is wrong,
        // and the user should be told exactly that.
        XCTAssertEqual(closest?.name, "Каталог")
        XCTAssertTrue(missing.isEmpty)
        XCTAssertTrue(extra.isEmpty)
        XCTAssertTrue(reason.contains("не по выбору листов"), reason)
    }

    /// Export tools name the sheet after the report, so the name changes while
    /// the shape does not.
    func testAFirstSheetSelectionIgnoresTheName() {
        let saved = profile(sheets: .first)
        XCTAssertNotNil(match([saved], columns: ["Артикул", "Название", "Цена"], sheetName: "Отчёт за март", index: 0).profile)
        XCTAssertNil(match([saved], columns: ["Артикул", "Название", "Цена"], sheetName: "Отчёт за март", index: 1).profile)
    }

    /// Two profiles claiming the same sheet is not something to resolve by
    /// picking the first one.
    func testTwoMatchingProfilesAreAmbiguousRatherThanGuessed() {
        let first = profile(name: "Первый")
        let second = profile(name: "Второй")
        guard case .ambiguous(let candidates) = match([first, second], columns: ["Артикул", "Название", "Цена"]) else {
            return XCTFail("ожидалась неоднозначность")
        }
        XCTAssertEqual(Set(candidates.map(\.name)), ["Первый", "Второй"])
    }

    // MARK: - Header row

    private func rows(_ grid: [[CellValue]], from first: Int = 1) -> [SheetRow] {
        grid.enumerated().map { offset, line in
            var cells: [Int: CellValue] = [:]
            for (column, value) in line.enumerated() where !value.isEmpty { cells[column] = value }
            return SheetRow(number: first + offset, cells: cells)
        }
    }

    /// the header row is given by hand, because multi-row and merged
    /// headers cannot be worked out reliably.
    func testHeadersAreReadFromTheRowTheUserPointedAt() {
        let sheet = rows([
            [.text("Отчёт о продажах"), .empty, .empty],
            [.empty, .empty, .empty],
            [.text("Артикул"), .text("Название"), .text("Цена")],
            [.text("A-1"), .text("Болт"), .number(12)],
        ])
        guard case .headers(let titles) = TableProfileMatcher.headers(in: sheet, headerRow: 3) else {
            return XCTFail("третья строка — заголовки")
        }
        XCTAssertEqual(titles, ["Артикул", "Название", "Цена"])
    }

    /// A row that is not a header sends the sheet to «требуют решения» rather
    /// than producing columns named after whatever was in it.
    func testAWrongHeaderRowAsksRatherThanInvents() {
        let sheet = rows([
            [.text("Артикул"), .text("Название")],
            [.text("A-1"), .text("Болт")],
        ])
        guard case .needsDecision(let reason) = TableProfileMatcher.headers(in: sheet, headerRow: 9) else {
            return XCTFail("несуществующая строка должна требовать решения")
        }
        XCTAssertTrue(reason.contains("9"), reason)
    }

    /// A numeric header row is honoured, unlike in automatic detection,
    /// and the difference is the point: detection is guessing, while a row the
    /// user pointed at is an instruction. Columns headed `2023`, `2024` are an
    /// ordinary table.
    func testAManuallyChosenNumericHeaderRowIsHonoured() {
        let sheet = rows([
            [.text("Товар"), .number(2023), .number(2024)],
            [.text("Болт"), .number(10), .number(12)],
        ])
        guard case .headers(let titles) = TableProfileMatcher.headers(in: sheet, headerRow: 1) else {
            return XCTFail("на строку указали вручную — её и надо взять")
        }
        XCTAssertEqual(titles, ["Товар", "2023", "2024"])
    }

    /// A row with nothing in it, on the other hand, yields columns called «A»,
    /// «B», «C» — not a mapping anybody can use.
    func testARowWithNoNamesAtAllIsRefused() {
        let sheet = rows([
            [.text(""), .text("")],
            [.text("A-1"), .text("Болт")],
        ])
        guard case .needsDecision(let reason) = TableProfileMatcher.headers(in: sheet, headerRow: 1) else {
            return XCTFail("строка без названий заголовками не является")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    /// Повтор в шапке — не отказ, а различимые имена.
    ///
    /// Раньше такая строка не читалась вовсе: выбрать её заголовком было
    /// нельзя, при том что шапка в два этажа — обычное дело, и «Стоимость»
    /// стоит под каждым годом. Первая колонка сохраняет имя из файла:
    /// человек смотрит в свой файл рядом.
    func testDuplicateTitlesGetNumbersInsteadOfARefusal() {
        let sheet = rows([[.text("Цена"), .text("Название"), .text("Цена")]])
        guard case .headers(let titles) = TableProfileMatcher.headers(in: sheet, headerRow: 1) else {
            return XCTFail("строку с повторами человек выбрал сам — читать её надо")
        }
        XCTAssertEqual(titles, ["Цена", "Название", "Цена (2)"])
    }

    /// Имя с номером, уже занятое в самой шапке, не присваивается второй раз.
    func testANumberedNameThatIsAlreadyTakenGoesFurther() {
        XCTAssertEqual(
            TableProfileMatcher.uniqued(["Цена", "Цена (2)", "Цена"]),
            ["Цена", "Цена (2)", "Цена (3)"]
        )
    }

    /// Три одинаковых — три разных имени, и порядок сохраняется: колонка
    /// читается по своему месту в файле.
    func testThreeSameTitlesBecomeThree() {
        XCTAssertEqual(
            TableProfileMatcher.uniqued(["Год", "Год", "Год"]),
            ["Год", "Год (2)", "Год (3)"]
        )
    }

    // MARK: - Storage

    func testAProfileSurvivesTheConfigurationRoundTrip() throws {
        var source = DataSource(name: "s", path: "/tmp", collectionName: "c")
        source.tableProfiles = [profile(sheets: .named(["Данные", "Архив"]))]
        source.numbersExportEnabled = true

        let decoded = try JSONDecoder().decode(DataSource.self, from: try JSONEncoder().encode(source))
        XCTAssertEqual(decoded.tableProfiles.count, 1)
        XCTAssertEqual(decoded.tableProfiles[0].variants.count, 1)
        XCTAssertEqual(decoded.tableProfiles[0].variants[0].mapping.keyColumn, "Артикул")
        XCTAssertEqual(decoded.tableProfiles[0].variants[0].sheets, .named(["Данные", "Архив"]))
        XCTAssertTrue(decoded.numbersExportEnabled)
    }

    /// A source written before stage 5 must still load.
    func testASourceFromBeforeProfilesStillLoads() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"s","path":"/tmp","collectionName":"c",
         "fileExtensions":["md"],"recursive":true,"mapping":"folderToCollection",
         "rulePattern":"","ruleTemplate":"$1","metric":"cosine","customMetadata":{},
         "unresolvedSchemaPolicy":"block","chunking":{},"triggers":{}}
        """
        let source = try JSONDecoder().decode(DataSource.self, from: Data(json.utf8))
        XCTAssertTrue(source.tableProfiles.isEmpty)
        XCTAssertFalse(source.numbersExportEnabled)
    }

    // MARK: - Строка заголовка, указанная руками

    /// Шапка отчёта над таблицей: автоопределение берёт первую непустую
    /// строку и объявляет заголовками «Отчёт о продажах».
    private var reportWithATitleBlock: [SheetRow] {
        rows([
            [.text("Отчёт о продажах"), .empty, .empty],
            [.text("за март 2026"), .empty, .empty],
            [.empty, .empty, .empty],
            [.text("Подготовил: отдел закупок"), .empty, .empty],
            [.text("Артикул"), .text("Название"), .text("Цена")],
            [.text("A-1"), .text("Болт"), .number(12)],
            [.text("A-2"), .text("Гайка"), .number(7)],
        ])
    }

    func testTheChosenHeaderRowGivesTheColumnsAndTheModeBelowIt() throws {
        let shape = try XCTUnwrap(SheetModeDetector.shape(rows: reportWithATitleBlock, headerRow: 5))
        XCTAssertEqual(shape.columns, ["Артикул", "Название", "Цена"])
        XCTAssertEqual(shape.headerRow, 5)
        XCTAssertEqual(shape.mode, .dataTable, "под строкой 5 — однородные строки: \(shape.reason)")
    }

    /// Однородность считается по строкам **под** заголовком. Шапка отчёта —
    /// это текст в одной колонке и пустота в остальных; посчитай её данными,
    /// и таблица объявляется отчётом.
    func testRowsAboveTheChosenHeaderDoNotJudgeTheSheet() throws {
        let shape = try XCTUnwrap(SheetModeDetector.shape(rows: reportWithATitleBlock, headerRow: 5))
        XCTAssertEqual(shape.mode, .dataTable)

        // А автоопределение на этом же листе не справляется — ради чего всё
        // и заводилось.
        let automatic = SheetModeDetector.suggest(rows: reportWithATitleBlock)
        XCTAssertNotEqual(automatic.columns, ["Артикул", "Название", "Цена"])
    }

    /// «Не вышло» должно быть видно: молча съехать на автоопределение значило
    /// бы показать разбор, которого человек не просил.
    func testARowThatIsNoHeaderYieldsNoShape() {
        XCTAssertNil(SheetModeDetector.shape(rows: reportWithATitleBlock, headerRow: 3),
                     "строка 3 пуста — заголовками она не является")
        XCTAssertNil(SheetModeDetector.shape(rows: reportWithATitleBlock, headerRow: 40),
                     "строки 40 в листе нет")
    }

    /// Строки выше заголовка — не записи.
    ///
    /// Пока заголовком была первая непустая строка, выше неё ничего не было.
    /// С указанной строкой «Отчёт о продажах», «за март 2026» и «Подготовил:»
    /// иначе стали бы документами наравне со строками таблицы — тремя
    /// мусорными записями в коллекции на каждый такой файл.
    func testRowsAboveTheHeaderAreNotIndexed() {
        let mapping = TableMapping(
            sheetName: "Лист1", mode: .dataTable, headerRow: 5,
            columns: ["Артикул", "Название", "Цена"],
            roles: ["Артикул": .metadata, "Название": .text, "Цена": .metadata],
            keyColumn: "Артикул"
        )
        let plan = TableSyncPlanner.plan(
            rows: reportWithATitleBlock,
            mapping: mapping,
            layout: SheetLayout(mapping: mapping),
            manifest: SheetManifest(sheetName: "Лист1"),
            sourceID: UUID(),
            sourceFile: "отчёт.xlsx"
        )
        XCTAssertEqual(plan.added.count, 2, "документами становятся только строки 6 и 7")
        XCTAssertEqual(
            Set(plan.added.compactMap { $0.metadata["row_number"] }),
            [.int(6), .int(7)]
        )
        XCTAssertTrue(plan.empty.isEmpty, "шапка отчёта не должна попадать даже в «строки без текста»")
    }

    /// Ручная строка заголовка обязана пережить сохранение профиля.
    ///
    /// Без этого она живёт только в редакторе: профиль сохраняется, а на
    /// следующем запуске заголовок снова определяется сам, читает «Отчёт
    /// о продажах» и не совпадает ни с чем — файл уходит в «требуют решения».
    func testASavedProfileIsRecognisedByItsOwnHeaderRow() {
        let mapping = TableMapping(
            sheetName: "Лист1", mode: .dataTable, headerRow: 5,
            columns: ["Артикул", "Название", "Цена"],
            roles: ["Название": .text],
            keyColumn: "Артикул"
        )
        let saved = TableProfile(name: "Отчёты", mapping: mapping)
        let claimed = TableSyncService.claim(
            sheet: SheetInfo(name: "Лист1", isHidden: false, path: "sheet1.xml"),
            rows: reportWithATitleBlock, index: 0, profiles: [saved]
        )
        XCTAssertEqual(claimed.match.profile?.name, "Отчёты")
        XCTAssertEqual(claimed.shape.headerRow, 5)
        XCTAssertEqual(claimed.shape.columns, ["Артикул", "Название", "Цена"])
    }

    /// Автоопределение остаётся главным: файл, где таблица начинается сразу,
    /// читается ровно как раньше, а не подбором чужой строки заголовка.
    func testAutomaticDetectionStillWinsWhenItMatches() {
        let sheet = rows([
            [.text("Артикул"), .text("Название"), .text("Цена")],
            [.text("A-1"), .text("Болт"), .number(12)],
        ])
        let byRowFive = TableProfile(name: "Отчёты", mapping: TableMapping(
            sheetName: "Лист1", headerRow: 5, columns: ["Артикул", "Название", "Цена"]
        ))
        let claimed = TableSyncService.claim(
            sheet: SheetInfo(name: "Лист1", isHidden: false, path: "sheet1.xml"),
            rows: sheet, index: 0, profiles: [byRowFive]
        )
        XCTAssertEqual(claimed.shape.headerRow, 1)
    }
}

/// один профиль описывает книгу целиком: у каждого листа свой разбор.
final class TableProfileVariantTests: XCTestCase {
    private func mapping(_ sheetName: String, _ columns: [String], headerRow: Int = 1) -> TableMapping {
        TableMapping(
            sheetName: sheetName, mode: .dataTable, headerRow: headerRow, columns: columns,
            roles: Dictionary(uniqueKeysWithValues: columns.map { ($0, ColumnRole.metadata) }),
            keyColumn: columns.first
        )
    }

    /// Рабочая книга: «Товары и услуги» и «ФЭО» — разные таблицы, и оба
    /// разбираются одним профилем, каждый своим вариантом.
    private var workbookProfile: TableProfile {
        TableProfile(name: "Смета", variants: [
            TableProfile.Variant(
                sheets: .named(["Товары и услуги"]),
                mapping: mapping("Товары и услуги", ["Артикул", "Наименование", "Цена"])
            ),
            TableProfile.Variant(
                sheets: .named(["ФЭО"]),
                mapping: mapping("ФЭО", ["Статья", "Сумма", "Обоснование"])
            ),
        ])
    }

    func testEachSheetOfTheWorkbookGetsItsOwnVariant() {
        let goods = TableProfileMatcher.match(
            profiles: [workbookProfile], sheetName: "Товары и услуги", sheetIndex: 0,
            columns: ["Артикул", "Наименование", "Цена"]
        )
        guard case .matched(let profile, let variant) = goods else {
            return XCTFail("ожидалось совпадение, получено \(goods)")
        }
        XCTAssertEqual(profile.name, "Смета")
        XCTAssertEqual(variant.mapping.keyColumn, "Артикул")

        let economics = TableProfileMatcher.match(
            profiles: [workbookProfile], sheetName: "ФЭО", sheetIndex: 1,
            columns: ["Статья", "Сумма", "Обоснование"]
        )
        XCTAssertEqual(economics.mapping?.keyColumn, "Статья", "второй лист читается своим вариантом")
        XCTAssertEqual(economics.profile?.name, "Смета", "профиль тот же — книга одна")
    }

    /// Вариант «листы: ФЭО» не берёт чужой лист, даже если колонки сошлись:
    /// иначе смысл имени листа в профиле пропадает.
    func testAVariantDoesNotClaimASheetItIsNotAbout() {
        let match = TableProfileMatcher.match(
            profiles: [workbookProfile], sheetName: "Товары и услуги", sheetIndex: 0,
            columns: ["Статья", "Сумма", "Обоснование"]
        )
        XCTAssertNil(match.profile, "колонки от ФЭО на листе товаров — это «требуют решения»")
    }

    /// Профиль, спорящий сам с собой, — тоже неоднозначность, а не «возьмём
    /// первый попавшийся».
    func testTwoVariantsClaimingTheSameSheetAreAmbiguous() {
        let confused = TableProfile(name: "Спорный", variants: [
            TableProfile.Variant(sheets: .anyMatching, mapping: mapping("Лист1", ["А", "Б"])),
            TableProfile.Variant(sheets: .anyMatching, mapping: mapping("Лист1", ["А", "Б"])),
        ])
        let match = TableProfileMatcher.match(
            profiles: [confused], sheetName: "Лист1", sheetIndex: 0, columns: ["А", "Б"]
        )
        guard case .ambiguous(let candidates) = match else {
            return XCTFail("ожидалась неоднозначность, получено \(match)")
        }
        XCTAssertEqual(candidates.count, 2)
    }

    /// Строки заголовков собираются со всех вариантов: у листов книги они
    /// разные, и подбор шапки обязан пробовать каждую.
    func testHeaderRowsComeFromEveryVariant() {
        let profile = TableProfile(name: "Книга", variants: [
            TableProfile.Variant(sheets: .named(["А"]), mapping: mapping("А", ["К1"], headerRow: 3)),
            TableProfile.Variant(sheets: .named(["Б"]), mapping: mapping("Б", ["К2"], headerRow: 7)),
        ])
        XCTAssertEqual(profile.headerRows.sorted(), [3, 7])
    }

    func testTheWholeWorkbookProfileSurvivesTheConfigurationRoundTrip() throws {
        var source = DataSource(name: "s", path: "/tmp", collectionName: "c")
        source.tableProfiles = [workbookProfile]

        let decoded = try JSONDecoder().decode(DataSource.self, from: try JSONEncoder().encode(source))
        XCTAssertEqual(decoded.tableProfiles.first?.variants.count, 2)
        XCTAssertEqual(
            decoded.tableProfiles.first?.variants.map(\.title), ["Товары и услуги", "ФЭО"],
            "порядок вариантов — это порядок листов книги"
        )
    }
}

/// профиль, назначенный файлу вручную.
final class TableProfileAssignmentTests: XCTestCase {
    private let sheet = SheetInfo(name: "Лист1", isHidden: false, path: "sheet1.xml")

    private func rows(_ grid: [[CellValue]], from first: Int = 1) -> [SheetRow] {
        grid.enumerated().map { offset, line in
            var cells: [Int: CellValue] = [:]
            for (column, value) in line.enumerated() where !value.isEmpty { cells[column] = value }
            return SheetRow(number: first + offset, cells: cells)
        }
    }

    private var report: [SheetRow] {
        rows([
            [.text("Отчёт за март"), .empty, .empty],
            [.empty, .empty, .empty],
            [.text("Артикул"), .text("Название"), .text("Цена")],
            [.text("A-1"), .text("Болт"), .number(12)],
            [.text("A-2"), .text("Гайка"), .number(7)],
        ])
    }

    private func profile(name: String, headerRow: Int, columns: [String]) -> TableProfile {
        TableProfile(name: name, mapping: TableMapping(
            sheetName: "Лист1", mode: .dataTable, headerRow: headerRow, columns: columns,
            roles: Dictionary(uniqueKeysWithValues: columns.map { ($0, ColumnRole.metadata) }),
            keyColumn: columns.first
        ))
    }

    /// Назначенный профиль применяется без подбора — и шапка читается с той
    /// строки, которая записана в нём.
    func testAnAssignedProfileIsUsedWithoutMatching() {
        let assigned = profile(name: "Мартовский", headerRow: 3, columns: ["Артикул", "Название", "Цена"])
        let claimed = TableSyncService.claim(
            sheet: sheet, rows: report, index: 0, profiles: [assigned], assigned: assigned
        )
        XCTAssertEqual(claimed.match.profile?.name, "Мартовский")
        XCTAssertEqual(claimed.shape.headerRow, 3, "шапка — со строки из профиля")
    }

    /// И тогда, когда подбор сам бы не справился: в назначении весь смысл.
    ///
    /// Здесь автоопределение прочитает шапкой первую строку («Отчёт за март»)
    /// и ни с чем не совпадёт — без назначения лист ушёл бы в «требуют решения».
    func testAnAssignedProfileWinsWhereMatchingWouldFail() {
        let assigned = profile(name: "Мартовский", headerRow: 3, columns: ["Артикул", "Название", "Цена"])
        let other = profile(name: "Другой", headerRow: 1, columns: ["Совсем", "Другие", "Колонки"])

        let withoutAssignment = TableSyncService.claim(
            sheet: sheet, rows: report, index: 0, profiles: [other]
        )
        XCTAssertNil(withoutAssignment.match.profile, "подбору тут ответить нечем")

        let withAssignment = TableSyncService.claim(
            sheet: sheet, rows: report, index: 0, profiles: [other, assigned], assigned: assigned
        )
        XCTAssertEqual(withAssignment.match.profile?.name, "Мартовский")
    }

    /// Вариант выбирается по листу и здесь: назначен профиль книги, а лист
    /// у книги не один.
    func testTheAssignedProfilePicksTheVariantForThisSheet() {
        let book = TableProfile(name: "Книга", variants: [
            TableProfile.Variant(
                sheets: .named(["Другой лист"]),
                mapping: TableMapping(sheetName: "Другой лист", mode: .dataTable, headerRow: 1, columns: ["Иное"])
            ),
            TableProfile.Variant(
                sheets: .named(["Лист1"]),
                mapping: TableMapping(
                    sheetName: "Лист1", mode: .dataTable, headerRow: 3,
                    columns: ["Артикул", "Название", "Цена"], keyColumn: "Артикул"
                )
            ),
        ])
        let claimed = TableSyncService.claim(
            sheet: sheet, rows: report, index: 0, profiles: [book], assigned: book
        )
        XCTAssertEqual(claimed.shape.headerRow, 3)
        XCTAssertEqual(claimed.match.mapping?.keyColumn, "Артикул")
    }

    /// Скрытый лист не индексируется и по назначению: про это, а не
    /// про способ выбора профиля.
    func testAHiddenSheetIsNotClaimedEvenByAnAssignedProfile() {
        let assigned = profile(name: "Мартовский", headerRow: 3, columns: ["Артикул", "Название", "Цена"])
        let claimed = TableSyncService.claim(
            sheet: SheetInfo(name: "Лист1", isHidden: true, path: "sheet1.xml"),
            rows: report, index: 0, profiles: [assigned], assigned: assigned
        )
        XCTAssertNil(claimed.match.profile)
    }

    /// Назначение на удалённый профиль — это «подбором, как раньше», а не
    /// падение и не пустое сопоставление.
    func testAnAssignmentToADeletedProfileFallsBackToMatching() {
        let assigned = profile(name: "Удалённый", headerRow: 3, columns: ["Артикул"])
        let context = TableSyncService.Context(
            sourceID: UUID(), relativePath: "прайс.xlsx", collectionID: "c",
            collectionName: "c", embeddingModel: "m", dimension: 4,
            profiles: [], assignedProfileID: assigned.id
        )
        XCTAssertNil(context.assignedProfile)
    }

    /// Назначения переживают запись настроек: без этого выбор в списке
    /// файлов сбрасывался бы при следующем запуске.
    func testAssignmentsSurviveTheConfigurationRoundTrip() throws {
        var source = DataSource(name: "s", path: "/tmp", collectionName: "c")
        let assigned = profile(name: "Мартовский", headerRow: 3, columns: ["Артикул"])
        source.tableProfiles = [assigned]
        source.tableProfileAssignments = ["отчёты/март.xlsx": assigned.id]

        let decoded = try JSONDecoder().decode(DataSource.self, from: try JSONEncoder().encode(source))
        XCTAssertEqual(decoded.tableProfileAssignments["отчёты/март.xlsx"], assigned.id)
    }
}

/// 3 + — `.xls` читается тем же путём, что `.numbers`.
final class LegacyExcelFormatTests: XCTestCase {
    func testXLSGoesThroughTheApplicationExport() {
        XCTAssertEqual(TabularFormat.of(URL(fileURLWithPath: "/t/старый.xls")), .legacyExcel)
        XCTAssertEqual(TabularFormat.of(URL(fileURLWithPath: "/t/СТАРЫЙ.XLS")), .legacyExcel)
        XCTAssertTrue(NumbersReader.supportedExtensions.contains("xls"))
        XCTAssertTrue(TabularFormat.applicationExportExtensions.contains("xls"))
    }

    /// Формат, который не открывает и Numbers, остаётся отказом — и объясняет
    /// себя, а не пропадает молча.
    func testXLSBIsStillRefusedWithAReason() {
        XCTAssertEqual(TabularFormat.of(URL(fileURLWithPath: "/t/двоичный.xlsb")), .legacyBinary)
        let reason = TabularError.legacyBinaryFormat("xlsb").errorDescription ?? ""
        XCTAssertTrue(reason.contains("xlsb"), reason)
        XCTAssertTrue(reason.contains("Numbers"), "причина должна закрывать и вопрос «а через Numbers?»")
    }

    func testXLSIsOfferedToANewSource() {
        XCTAssertTrue(TabularFormat.allExtensions.contains("xls"))
        XCTAssertTrue(TextExtractor.supportedExtensions.contains("xls"))
        XCTAssertFalse(TextExtractor.supportedExtensions.contains("xlsb"))
    }

    /// Экспорт через приложение выключен — файл называет причину, по которой
    /// его не прочитали, а не исчезает из выдачи.
    func testWithoutTheSwitchTheReasonIsNamed() async {
        do {
            _ = try await NumbersReader().workbook(
                at: URL(fileURLWithPath: "/t/старый.xls"), allowApplicationExport: false
            )
            XCTFail("должно было отказать")
        } catch {
            XCTAssertTrue(
                "\(error.localizedDescription)".contains("выключен"),
                error.localizedDescription
            )
        }
    }
}
