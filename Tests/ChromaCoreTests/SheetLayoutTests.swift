import XCTest
@testable import ChromaCore

/// a profile says what the columns mean; the file says where they are.
///
/// Profiles are matched by the *set* of headers, so a file legitimately matches
/// while laying its columns out differently. Everything here failed before: the
/// mapping's own column order and header row were used to read every file,
/// which put one field's value under another field's name — silently, and
/// visibly only as a search that stops returning what it used to.
final class SheetLayoutTests: XCTestCase {
    private let sourceID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!

    /// A profile built from a file whose columns are Артикул, Название, Цена.
    private func profile() -> TableProfile {
        TableProfile(name: "прайс", mapping: TableMapping(
            sheetName: "Каталог", mode: .dataTable, headerRow: 1,
            columns: ["Артикул", "Название", "Цена"],
            roles: ["Артикул": .metadata, "Название": .text, "Цена": .metadata],
            keyColumn: "Артикул", textTemplate: ""
        ))
    }

    /// Matches like the sync does, then plans — the whole path a real file takes.
    private func plan(_ rows: [SheetRow], profiles: [TableProfile]? = nil) -> (SheetSyncPlan, TableProfileMatch) {
        let shape = SheetModeDetector.suggest(rows: rows)
        let match = TableProfileMatcher.match(
            profiles: profiles ?? [profile()], sheetName: "Каталог", sheetIndex: 0, columns: shape.columns
        )
        guard let mapping = match.mapping else { return (SheetSyncPlan(), match) }
        return (TableSyncPlanner.plan(
            rows: rows, mapping: mapping, layout: SheetLayout(shape: shape),
            manifest: SheetManifest(sheetName: "Каталог"),
            sourceID: sourceID, sourceFile: "новый.xlsx"
        ), match)
    }

    // MARK: - Column order

    func testColumnsAreReadWhereTheFileHasThemNotWhereTheProfileHadThem() {
        let (plan, match) = plan([
            SheetRow(number: 1, cells: [0: .text("Название"), 1: .text("Артикул"), 2: .text("Цена")]),
            SheetRow(number: 2, cells: [0: .text("Болт"), 1: .text("A-1"), 2: .number(12)]),
        ])
        XCTAssertNotNil(match.profile, "тот же набор колонок в другом порядке — это тот же профиль")
        let document = plan.added.first
        XCTAssertEqual(document?.text, "Название: Болт", "в текст попало значение не той колонки")
        XCTAssertEqual(document?.metadata["артикул"], .string("A-1"))
        XCTAssertEqual(document?.metadata["цена"], .int(12))
        XCTAssertEqual(document?.rowKey, "A-1", "ключ строки взят из чужой колонки")
    }

    /// The consequence of the above, and the expensive one: the id follows the
    /// key, so reading the key from the wrong column gives the same row two
    /// different documents in two files.
    func testTheSameRowGetsTheSameIdentityWhicheverOrderTheFileUses() {
        let straight = plan([
            SheetRow(number: 1, cells: [0: .text("Артикул"), 1: .text("Название"), 2: .text("Цена")]),
            SheetRow(number: 2, cells: [0: .text("A-1"), 1: .text("Болт"), 2: .number(12)]),
        ]).0
        let shuffled = plan([
            SheetRow(number: 1, cells: [0: .text("Цена"), 1: .text("Артикул"), 2: .text("Название")]),
            SheetRow(number: 2, cells: [0: .number(12), 1: .text("A-1"), 2: .text("Болт")]),
        ]).0
        XCTAssertEqual(straight.added.first?.id, shuffled.added.first?.id)
        XCTAssertEqual(straight.added.first?.text, shuffled.added.first?.text)
    }

    // MARK: - Header row

    func testTheHeaderRowIsTheFilesOwnNotTheProfilesRowNumber() {
        // Two title rows above the table push the headers down to row 3. The
        // profile still says 1.
        let (plan, match) = plan([
            SheetRow(number: 3, cells: [0: .text("Артикул"), 1: .text("Название"), 2: .text("Цена")]),
            SheetRow(number: 4, cells: [0: .text("A-1"), 1: .text("Болт"), 2: .number(12)]),
        ])
        XCTAssertNotNil(match.profile)
        XCTAssertEqual(plan.added.count, 1, "строка заголовков стала документом")
        XCTAssertEqual(plan.added.first?.text, "Название: Болт")
        XCTAssertFalse(
            plan.added.contains { $0.text == "Название: Название" },
            "в коллекцию попал документ, текст которого — название колонки"
        )
    }

    // MARK: - Case and spacing

    func testHeadersDifferingOnlyInCaseAndSpacingAreTheSameColumns() {
        let (plan, match) = plan([
            SheetRow(number: 1, cells: [0: .text(" артикул"), 1: .text("НАЗВАНИЕ"), 2: .text("Цена ")]),
            SheetRow(number: 2, cells: [0: .text("A-1"), 1: .text("Болт"), 2: .number(12)]),
        ])
        XCTAssertNotNil(match.profile, "регистр и пробелы — не другая таблица")
        // The keys stay the profile's, so both files are filterable by one name.
        XCTAssertEqual(plan.added.first?.metadata["цена"], .int(12))
        XCTAssertEqual(plan.added.first?.text, "Название: Болт")
        XCTAssertEqual(plan.added.first?.rowKey, "A-1")
    }

    // MARK: - A different table is still refused

    func testAFileWithAnExtraColumnIsNotProcessedAnyway() {
        let (_, match) = plan([
            SheetRow(number: 1, cells: [
                0: .text("Артикул"), 1: .text("Партия"), 2: .text("Название"), 3: .text("Цена"),
            ]),
            SheetRow(number: 2, cells: [
                0: .text("A-1"), 1: .text("П-7"), 2: .text("Болт"), 3: .number(12),
            ]),
        ])
        guard case .needsDecision(let reason, _, let missing, let extra) = match else {
            return XCTFail("файл с лишней колонкой сопоставился профилю: \(match)")
        }
        XCTAssertEqual(extra, ["Партия"])
        XCTAssertTrue(missing.isEmpty)
        XCTAssertTrue(reason.contains("Партия"), "разница должна быть названа: \(reason)")
    }

    func testAFileMissingAColumnIsNotProcessedAnyway() {
        let (_, match) = plan([
            SheetRow(number: 1, cells: [0: .text("Артикул"), 1: .text("Название")]),
            SheetRow(number: 2, cells: [0: .text("A-1"), 1: .text("Болт")]),
        ])
        guard case .needsDecision(_, _, let missing, _) = match else {
            return XCTFail("файл без колонки сопоставился профилю: \(match)")
        }
        XCTAssertEqual(missing, ["Цена"])
    }

    // MARK: - The layout itself

    func testTheLayoutNamesColumnsTheFileDoesNotHave() {
        let layout = SheetLayout(headerRow: 1, columns: ["Артикул", "Название"])
        XCTAssertEqual(layout.missing(from: ["Артикул", "Название", "Цена"]), ["Цена"])
        XCTAssertTrue(layout.missing(from: ["артикул", " Название "]).isEmpty)
    }

    func testARepeatedHeaderTitleResolvesToItsFirstColumn() {
        let layout = SheetLayout(headerRow: 1, columns: ["Цена", "Цена"])
        XCTAssertEqual(layout.index(of: "Цена"), 0)
        XCTAssertEqual(layout.width, 2, "ширина — это ширина файла, а не число различимых имён")
    }
}
