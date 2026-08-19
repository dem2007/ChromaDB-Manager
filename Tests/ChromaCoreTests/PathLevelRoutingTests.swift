import XCTest
@testable import ChromaCore

/// Поля из пути — поверх любого режима маппинга.
final class PathLevelRoutingTests: XCTestCase {
    private let router = CollectionRouter()

    private func source(
        mapping: SourceMapping = .folderToCollection,
        levels: [PathLevel] = [
            PathLevel(key: "year", type: .integer),
            PathLevel(key: "system", type: .string),
        ]
    ) -> DataSource {
        DataSource(
            name: "Системы", path: "/tmp/Системы", mapping: mapping,
            collectionName: "systems", pathLevels: levels
        )
    }

    private func metadata(_ path: String, _ source: DataSource) -> ChromaMetadata {
        router.route(relativePath: path, source: source).route?.extraMetadata ?? [:]
    }

    // MARK: - Основной случай

    /// Пример из постановки: `Системы/2025/Система 1/устав.docx` — год берётся
    /// с первого уровня, название системы со второго.
    func testEachLevelBecomesItsField() {
        let fields = metadata("2025/Система 1/устав.docx", source())
        XCTAssertEqual(fields["year"], .int(2025))
        XCTAssertEqual(fields["system"], .string("Система 1"))
    }

    /// Значение — то, что написано на папке, включая кириллицу и пробелы:
    /// латиница нужна ключу, по которому фильтруют, а не содержимому.
    func testTheValueIsTheFolderNameAsWritten() {
        let fields = metadata("2025/Система учёта № 2/акт.pdf", source())
        XCTAssertEqual(fields["system"], .string("Система учёта № 2"))
    }

    /// Имя файла уровнем не является: иначе у каждого документа появилось бы
    /// поле «система», равное имени этого же документа.
    func testTheFileNameIsNotALevel() {
        let fields = metadata("2025/устав.docx", source())
        XCTAssertEqual(fields["year"], .int(2025))
        XCTAssertNil(fields["system"], "второго уровня у этого файла нет")
    }

    // MARK: - Чего нет

    /// Уровень, до которого путь не достаёт, без значения по умолчанию
    /// не пишется: выдуманное значение хуже отсутствующего.
    func testAMissingLevelWritesNothingByDefault() {
        XCTAssertNil(metadata("устав.docx", source())["year"])
    }

    func testAMissingLevelTakesTheFallbackWhenThereIsOne() {
        let levels = [
            PathLevel(key: "year", type: .integer, fallbackValue: "0"),
            PathLevel(key: "system", type: .string, fallbackValue: "не указана"),
        ]
        let fields = metadata("устав.docx", source(levels: levels))
        XCTAssertEqual(fields["year"], .int(0))
        XCTAssertEqual(fields["system"], .string("не указана"))
    }

    /// Уровень объявлен числом, а папка называется «архив»: поле не пишется,
    /// потому что строка в числовом поле поссорила бы чанк со схемой.
    func testAFolderThatDoesNotFitTheTypeIsSkipped() {
        XCTAssertNil(metadata("архив/Система 1/устав.docx", source())["year"])
        XCTAssertEqual(metadata("архив/Система 1/устав.docx", source())["system"], .string("Система 1"))
    }

    /// …а со значением по умолчанию — берёт его: «не разобралось» и «этого
    /// уровня нет» для человека одно и то же.
    func testAnUnparsableFolderFallsBackToo() {
        let levels = [PathLevel(key: "year", type: .integer, fallbackValue: "0")]
        XCTAssertEqual(metadata("архив/устав.docx", source(levels: levels))["year"], .int(0))
    }

    func testAnUnnamedLevelWritesNothing() {
        let levels = [PathLevel(key: ""), PathLevel(key: "system", type: .string)]
        let fields = metadata("2025/Система 1/устав.docx", source(levels: levels))
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields["system"], .string("Система 1"))
    }

    /// Уровней глубже восьмого не бывает: каждое поле пишется в метаданные
    /// каждого чанка, и предел здесь дешевле разросшегося документа.
    func testLevelsBeyondTheLimitAreIgnored() {
        let levels = (1...12).map { PathLevel(key: "level_\($0)", type: .string) }
        let path = (1...12).map { "f\($0)" }.joined(separator: "/") + "/файл.md"
        let fields = metadata(path, source(levels: levels))
        XCTAssertEqual(fields.count, PathLevel.maximumLevels)
        XCTAssertNotNil(fields["level_\(PathLevel.maximumLevels)"])
        XCTAssertNil(fields["level_\(PathLevel.maximumLevels + 1)"])
    }

    // MARK: - Поверх режимов, а не вместо

    /// Источник без уровней ведёт себя ровно как прежде.
    func testASourceWithoutLevelsIsUnchanged() {
        XCTAssertTrue(metadata("2025/Система 1/устав.docx", source(levels: [])).isEmpty)
    }

    /// «Подпапки → коллекции»: первый уровень стал именем коллекции, и это
    /// не мешает ему же стать полем — решает человек, а не режим.
    func testLevelsWorkAlongsideSubfolderCollections() {
        let outcome = router.route(
            relativePath: "2025/Система 1/устав.docx",
            source: source(mapping: .subfoldersToCollections)
        )
        XCTAssertEqual(outcome.route?.collectionName, "2025")
        XCTAssertEqual(outcome.route?.extraMetadata["year"], .int(2025))
    }

    /// Файл в корне при этом режиме уходит в коллекцию источника — и поля
    /// из пути у него считаются по тем же правилам.
    func testAFileInTheRootOfSubfolderModeKeepsItsFields() {
        let levels = [PathLevel(key: "year", type: .integer, fallbackValue: "0")]
        let outcome = router.route(
            relativePath: "устав.docx",
            source: source(mapping: .subfoldersToCollections, levels: levels)
        )
        XCTAssertEqual(outcome.route?.collectionName, "systems")
        XCTAssertEqual(outcome.route?.extraMetadata["year"], .int(0))
    }

    /// Файл, который никуда не попал, полей не получает: его не будет в базе.
    func testAnUnroutableFileGetsNoFields() {
        var unroutable = source(mapping: .manualRule)
        unroutable.rulePattern = "^нет/(.+)$"
        let outcome = router.route(relativePath: "2025/Система 1/устав.docx", source: unroutable)
        XCTAssertNil(outcome.route)
    }

    /// Поля из пути ничего не заменяют: откуда взялся чанк, по-прежнему
    /// видно — из `source_file`, который пишет синхронизация. Второго поля
    /// с тем же содержимым маршрутизатор больше не добавляет.
    func testLevelsAreTheOnlyFieldsTheRouterAdds() {
        let fields = metadata("2025/Система 1/устав.docx", source(mapping: .singleCollectionWithRelativePath))
        XCTAssertEqual(fields["system"], .string("Система 1"))
        XCTAssertNil(fields["relative_path"])
    }
}
