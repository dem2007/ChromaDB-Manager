import XCTest
@testable import ChromaCore

/// Поля из пути и договор коллекции о метаданных.
final class PathLevelSchemaTests: XCTestCase {
    private var root: URL!
    private var service: SourceSyncService!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cdbm-levelschema-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = SourceSyncService(
            manifests: ManifestStore(directory: root.appendingPathComponent("manifests")),
            journal: SyncJournal(directory: root.appendingPathComponent("journals"))
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func source(_ levels: [PathLevel]) -> DataSource {
        DataSource(
            name: "Системы", path: root.path, mapping: .folderToCollection,
            collectionName: "systems", pathLevels: levels
        )
    }

    private func schema(_ fields: [MetadataField]) -> MetadataSchema {
        MetadataSchema(collectionName: "systems", fields: fields)
    }

    // MARK: - Что источник обещает

    /// Уровень со значением по умолчанию есть у каждого файла — значит
    /// обязательное поле схемы он закрывает.
    func testALevelWithAFallbackCoversARequiredField() async {
        let coverage = await service.coverage(
            source: source([PathLevel(key: "year", type: .integer, fallbackValue: "0")]),
            schema: schema([MetadataField(key: "year", type: .integer, isRequired: true)])
        )
        XCTAssertTrue(coverage.isSatisfied)
        XCTAssertTrue(coverage.providedKeys.contains("year"))
    }

    /// А без значения по умолчанию и без посчитанного дерева обещать нечего:
    /// файл в корне поля не получит, и «закрыто» было бы неправдой.
    func testALevelWithoutAFallbackPromisesNothingByItself() async {
        let coverage = await service.coverage(
            source: source([PathLevel(key: "year", type: .integer)]),
            schema: schema([MetadataField(key: "year", type: .integer, isRequired: true)])
        )
        XCTAssertEqual(coverage.uncoveredRequiredFields, ["year"])
    }

    /// Дерево посчитано, выше уровня файлов нет, все папки к типу приводятся —
    /// поле будет у каждого чанка, и это уже обещание.
    func testAMeasuredTreeMakesTheLevelGuaranteed() async {
        let levels = FolderLevels.of(paths: ["2025/устав.md", "2026/акт.md"])
        let coverage = await service.coverage(
            source: source([PathLevel(key: "year", type: .integer)]),
            schema: schema([MetadataField(key: "year", type: .integer, isRequired: true)]),
            levels: levels
        )
        XCTAssertTrue(coverage.isSatisfied)
    }

    /// Один файл в корне — и обещания больше нет.
    func testOneFileAboveTheLevelBreaksThePromise() async {
        let levels = FolderLevels.of(paths: ["2025/устав.md", "в корне.md"])
        let coverage = await service.coverage(
            source: source([PathLevel(key: "year", type: .integer)]),
            schema: schema([MetadataField(key: "year", type: .integer, isRequired: true)]),
            levels: levels
        )
        XCTAssertEqual(coverage.uncoveredRequiredFields, ["year"])
    }

    /// И папка, не приводящаяся к типу, — тоже дырка в том же обещании.
    func testAFolderThatDoesNotParseBreaksThePromise() async {
        let levels = FolderLevels.of(paths: ["2025/устав.md", "архив/акт.md"])
        let coverage = await service.coverage(
            source: source([PathLevel(key: "year", type: .integer)]),
            schema: schema([MetadataField(key: "year", type: .integer, isRequired: true)]),
            levels: levels
        )
        XCTAssertEqual(coverage.uncoveredRequiredFields, ["year"])
    }

    // MARK: - Типы

    /// Уровень объявлен строкой, схема ждёт число: это расходится на каждом
    /// файле, и сказать надо в редакторе, а не на сотом документе.
    func testATypeDisagreementIsReported() async {
        let coverage = await service.coverage(
            source: source([PathLevel(key: "year", type: .string, fallbackValue: "нет")]),
            schema: schema([MetadataField(key: "year", type: .integer, isRequired: true)])
        )
        XCTAssertFalse(coverage.isSatisfied)
        XCTAssertEqual(coverage.typeProblems.map(\.field), ["year"])
    }

    func testMatchingTypesAreSilent() async {
        let coverage = await service.coverage(
            source: source([PathLevel(key: "year", type: .integer, fallbackValue: "0")]),
            schema: schema([MetadataField(key: "year", type: .integer, isRequired: true)])
        )
        XCTAssertTrue(coverage.typeProblems.isEmpty)
    }

    /// Уровень, которого в схеме нет, ничему не противоречит: схема
    /// по умолчанию терпит лишние поля.
    func testALevelOutsideTheSchemaIsFine() async {
        let coverage = await service.coverage(
            source: source([PathLevel(key: "system", type: .string)]),
            schema: schema([MetadataField(key: "year", type: .integer, isRequired: false)])
        )
        XCTAssertTrue(coverage.isSatisfied)
    }

    // MARK: - Черновик схемы

    /// Ключ, заданный и ручным полем, и уровнем, не должен дать в схеме два
    /// поля с одним именем: `field(for:)` вернул бы первое, а дубль человеку
    /// пришлось бы убирать руками. Сравнение — по подрезанному ключу: пробел
    /// по краям приезжает с перенесённых настроек.
    func testADuplicateKeyYieldsOneField() {
        var source = self.source([PathLevel(key: "year", type: .integer, fallbackValue: "0")])
        source.customMetadata = [" year ": "2020"]

        let schema = MetadataSchema.drafted(collectionName: "systems", from: source)
        XCTAssertEqual(schema.fields.filter { $0.trimmedKey == "year" }.count, 1)
    }

    /// Черновик схемы для новой коллекции знает про поля из пути: иначе
    /// человек, настроивший уровни, получил бы схему без них.
    func testTheDraftedSchemaIncludesLevels() {
        var source = self.source([
            PathLevel(key: "year", type: .integer, fallbackValue: "0"),
            PathLevel(key: "system", type: .string),
            PathLevel(key: ""),
        ])
        source.customMetadata = ["owner": "закупки"]

        let schema = MetadataSchema.drafted(collectionName: "systems", from: source)
        XCTAssertEqual(schema.fields.map(\.key).sorted(), ["owner", "system", "year"])
        XCTAssertEqual(schema.field(for: "year")?.type, .integer)
        XCTAssertEqual(schema.field(for: "year")?.isRequired, true, "у него есть значение по умолчанию")
        XCTAssertEqual(
            schema.field(for: "system")?.isRequired, false,
            "поле бывает не у всех файлов — требовать его значит заранее записать часть папки в нарушители"
        )
    }
}
