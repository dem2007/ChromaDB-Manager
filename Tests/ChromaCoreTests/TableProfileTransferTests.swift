import XCTest
@testable import ChromaCore

/// профили сопоставления переносятся файлом.
///
/// Профиль — это разметка чужого формата, сделанная руками. Кто-то один
/// разобрался, какая колонка что значит в выгрузке из учётной системы, и это
/// знание должно доезжать до остальных, а не восстанавливаться каждым заново.
final class TableProfileTransferTests: XCTestCase {
    private func profile(_ name: String, columns: [String], key: String? = nil) -> TableProfile {
        TableProfile(name: name, mapping: TableMapping(
            sheetName: "Лист1", mode: .dataTable, headerRow: 1, columns: columns,
            roles: Dictionary(uniqueKeysWithValues: columns.map { ($0, ColumnRole.metadata) }),
            keyColumn: key ?? columns.first
        ))
    }

    private var workbook: TableProfile {
        TableProfile(name: "Смета", variants: [
            TableProfile.Variant(
                sheets: .named(["Товары и услуги"]),
                mapping: TableMapping(sheetName: "Товары и услуги", mode: .dataTable, headerRow: 4,
                                      columns: ["Артикул", "Наименование"], keyColumn: "Артикул")
            ),
            TableProfile.Variant(
                sheets: .named(["ФЭО"]),
                mapping: TableMapping(sheetName: "ФЭО", mode: .dataTable, headerRow: 2,
                                      columns: ["Статья", "Сумма"], keyColumn: "Статья")
            ),
        ])
    }

    // MARK: - Файл

    /// Всё, ради чего профиль сохраняют, обязано доехать: варианты, строки
    /// заголовков, роли, ключ, свои названия колонок.
    func testEverythingThatMattersSurvivesTheRoundTrip() throws {
        var named = workbook
        named.variants[0].mapping.titles = ["Артикул": "Код товара"]
        named.variants[0].mapping.textTemplate = "{Наименование} ({Код товара})"

        let package = TableProfilePackage(sourceName: "Сметы", profiles: [named, profile("Прайс", columns: ["A", "B"])])
        let decoded = try TableProfileTransfer.decode(try TableProfileTransfer.encode(package))

        XCTAssertEqual(decoded.profiles.count, 2)
        XCTAssertEqual(decoded.sourceName, "Сметы")
        let smeta = try XCTUnwrap(decoded.profiles.first { $0.name == "Смета" })
        XCTAssertEqual(smeta.variants.count, 2)
        XCTAssertEqual(smeta.variants[0].mapping.headerRow, 4)
        XCTAssertEqual(smeta.variants[1].mapping.headerRow, 2)
        XCTAssertEqual(smeta.variants[0].mapping.titles["Артикул"], "Код товара")
        XCTAssertEqual(smeta.variants[0].mapping.textTemplate, "{Наименование} ({Код товара})")
        XCTAssertEqual(smeta.variants[1].sheets, .named(["ФЭО"]))
    }

    /// Чужой JSON — это не «пустой список профилей», а отказ с объяснением.
    func testAForeignFileIsRefused() {
        let alien = Data(#"{"что-то": "совсем другое"}"#.utf8)
        XCTAssertThrowsError(try TableProfileTransfer.decode(alien)) { error in
            XCTAssertEqual(error as? TableProfileTransfer.TransferError, .notAProfileFile)
            XCTAssertNotNil((error as? LocalizedError)?.recoverySuggestion)
        }
    }

    /// Файл от будущей версии не разбирается «как получится»: пропущенное
    /// поле — это молча потерянная разметка.
    func testAFileFromANewerVersionIsRefused() throws {
        var package = TableProfilePackage(profiles: [profile("П", columns: ["A"])])
        package.version = TableProfilePackage.currentVersion + 5
        let data = try TableProfileTransfer.encode(package)

        XCTAssertThrowsError(try TableProfileTransfer.decode(data)) { error in
            XCTAssertEqual(
                error as? TableProfileTransfer.TransferError,
                .tooNew(version: TableProfilePackage.currentVersion + 5)
            )
        }
    }

    func testAnEmptyFileIsRefused() throws {
        let data = try TableProfileTransfer.encode(TableProfilePackage(profiles: []))
        XCTAssertThrowsError(try TableProfileTransfer.decode(data)) { error in
            XCTAssertEqual(error as? TableProfileTransfer.TransferError, .empty)
        }
    }

    // MARK: - Слияние

    func testNewProfilesAreAddedAndExistingOnesAreListed() {
        let existing = [profile("Прайс", columns: ["A"])]
        let merged = TableProfileTransfer.merge([profile("Смета", columns: ["B"])], into: existing)

        XCTAssertEqual(merged.profiles.count, 2)
        XCTAssertEqual(merged.added, ["Смета"])
        XCTAssertTrue(merged.replaced.isEmpty)
    }

    /// Замена по имени сохраняет прежний `id` — иначе назначения файлам
    /// начали бы указывать в пустоту, а на экране это выглядело бы
    /// как «настройки слетели».
    func testReplacingByNameKeepsTheIdentifierTheAssignmentsPointAt() {
        let existing = profile("Прайс", columns: ["A"], key: "A")
        let incoming = profile("Прайс", columns: ["A", "B"], key: "B")
        XCTAssertNotEqual(existing.id, incoming.id, "у файла с другой машины id свой")

        let merged = TableProfileTransfer.merge([incoming], into: [existing])
        XCTAssertEqual(merged.profiles.count, 1)
        XCTAssertEqual(merged.profiles[0].id, existing.id, "id прежний — на него ссылаются назначения")
        XCTAssertEqual(merged.profiles[0].variants[0].mapping.keyColumn, "B", "содержимое — новое")
        XCTAssertEqual(merged.replaced, ["Прайс"])
    }

    /// Профиль без имени не сливается: выбирать его в списке файлов было бы
    /// нечем.
    func testAnUnnamedProfileIsSkipped() {
        let merged = TableProfileTransfer.merge(
            [profile("   ", columns: ["A"])], into: [profile("Прайс", columns: ["A"])]
        )
        XCTAssertTrue(merged.isEmpty)
        XCTAssertEqual(merged.profiles.count, 1)
    }

    /// Дважды подряд один и тот же файл ничего не наращивает.
    func testImportingTheSameFileTwiceChangesNothingTheSecondTime() {
        let incoming = [workbook, profile("Прайс", columns: ["A"])]
        let once = TableProfileTransfer.merge(incoming, into: [])
        let twice = TableProfileTransfer.merge(incoming, into: once.profiles)

        XCTAssertEqual(once.profiles.count, 2)
        XCTAssertEqual(twice.profiles.count, 2)
        XCTAssertEqual(twice.added, [])
        XCTAssertEqual(twice.replaced.sorted(), ["Прайс", "Смета"])
        XCTAssertEqual(twice.profiles.map(\.id), once.profiles.map(\.id))
    }
}
