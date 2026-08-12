import XCTest
@testable import ChromaCore

/// «результат поиска → файл на диске и место в нём».
final class DocumentLocatorTests: XCTestCase {

    private let sourceID = UUID()

    private func source(path: String = "/Users/USER/Документы/контракт") -> DataSource {
        DataSource(id: sourceID, name: "контракт", path: path, collectionName: "контракт")
    }

    private func metadata(
        file: String? = "приложения/4.1.Приложение_1.txt",
        extra: ChromaMetadata = [:]
    ) -> ChromaMetadata {
        var made: ChromaMetadata = [
            "source_id": .string(sourceID.uuidString),
            "_cdbm_source_name": .string("контракт"),
            "file_name": .string("4.1.Приложение_1.txt"),
        ]
        if let file { made["source_file"] = .string(file) }
        for (key, value) in extra { made[key] = value }
        return made
    }

    // MARK: - Путь к файлу

    /// `source_file` — путь **относительно папки источника**, несмотря на имя
    /// ключа. Склейка с путём источника и даёт файл.
    func testTheFileIsFoundByTheSourceFolderAndTheRelativePath() {
        let resolution = DocumentLocator.resolve(
            metadata: metadata(), sources: [source()], fileExists: { _ in true }
        )
        guard case .found(let url, let kind, _) = resolution else {
            return XCTFail("ожидалось found, получено \(resolution)")
        }
        XCTAssertEqual(url.path, "/Users/USER/Документы/контракт/приложения/4.1.Приложение_1.txt")
        XCTAssertEqual(kind, .plainText)
    }

    /// `file_name` пишут не все стратегии: у строк таблицы его нет, и панель
    /// подписывалась именем коллекции вместо имени файла.
    func testTheFileNameFallsBackToTheEndOfTheRelativePath() {
        var withoutName = metadata()
        withoutName["file_name"] = nil
        XCTAssertEqual(
            DocumentLocator.reference(metadata: withoutName).fileName,
            "4.1.Приложение_1.txt"
        )
    }

    func testWithoutAPathThereIsNoFileNameToInvent() {
        var manual = metadata(file: nil)
        manual["file_name"] = nil
        XCTAssertNil(DocumentLocator.reference(metadata: manual).fileName)
    }

    /// Источник ищется по идентификатору, а не по имени: имя переименовывают,
    /// идентификатор — нет.
    func testARenamedSourceIsStillFoundByItsIdentifier() {
        var renamed = source()
        renamed.name = "контракт (старый)"
        let resolution = DocumentLocator.resolve(
            metadata: metadata(), sources: [renamed], fileExists: { _ in true }
        )
        XCTAssertNotNil(resolution.url)
    }

    /// файл переместили или удалили — сообщение обязано показать
    /// сохранённый путь, а не пустое окно.
    func testAMissingFileNamesTheSavedPath() {
        let resolution = DocumentLocator.resolve(
            metadata: metadata(), sources: [source()], fileExists: { _ in false }
        )
        guard case .fileMissing(let expected, let reference) = resolution else {
            return XCTFail("ожидалось fileMissing, получено \(resolution)")
        }
        XCTAssertTrue(expected.path.hasSuffix("4.1.Приложение_1.txt"))
        XCTAssertEqual(reference.savedPath, "приложения/4.1.Приложение_1.txt")
        XCTAssertTrue(resolution.problem?.contains("приложения/4.1.Приложение_1.txt") == true)
    }

    /// Источник удалён из настроек — папку никто не знает, и угадывать её
    /// нельзя. Это отдельное сообщение, а не «файл не найден»: чинится оно
    /// иначе.
    func testAnUnregisteredSourceIsItsOwnAnswer() {
        let resolution = DocumentLocator.resolve(
            metadata: metadata(), sources: [], fileExists: { _ in true }
        )
        guard case .sourceUnknown = resolution else {
            return XCTFail("ожидалось sourceUnknown, получено \(resolution)")
        }
        XCTAssertTrue(resolution.problem?.contains("контракт") == true)
    }

    /// Документ, добавленный руками, отличается от пришедшего из файла
    /// происхождением, а не отсутствием пути — и говорить надо именно это.
    func testAHandAddedDocumentIsNotAMissingFile() {
        let resolution = DocumentLocator.resolve(
            metadata: ["text_length": .int(120)], sources: [source()], fileExists: { _ in true }
        )
        XCTAssertEqual(resolution, .notFromFile)
        XCTAssertTrue(resolution.problem?.contains("вручную") == true)
    }

    // MARK: - Куда внутри документа

    func testThePageWinsOverEverythingElse() {
        let target = DocumentLocator.target(metadata: [
            "page_number": .int(41),
            "heading_path": .string("Раздел 1 > Пункт 1.2"),
        ])
        XCTAssertEqual(target, .page(41))
    }

    func testChapterSlideRowAndHeadingAreRecognised() {
        XCTAssertEqual(
            DocumentLocator.target(metadata: ["chapter_id": .string("ch07"), "spine_index": .int(6)]),
            .chapter(id: "ch07", spineIndex: 6)
        )
        XCTAssertEqual(DocumentLocator.target(metadata: ["slide_number": .int(3)]), .slide(3))
        XCTAssertEqual(
            DocumentLocator.target(metadata: ["sheet_name": .string("Закупки"), "row_number": .int(42)]),
            .tableRow(sheet: "Закупки", row: 42)
        )
        XCTAssertEqual(
            DocumentLocator.target(metadata: ["heading_path": .string("Глава 2 > 2.1")]),
            .heading("Глава 2 > 2.1")
        )
    }

    /// Ничего не известно — открыть с начала. Это исход, а не ошибка.
    func testNothingKnownMeansTheWholeDocument() {
        XCTAssertEqual(DocumentLocator.target(metadata: [:]), .wholeDocument)
        XCTAssertNil(ViewerTarget.wholeDocument.line)
    }

    /// Число, приехавшее строкой, — обычное дело для чужой коллекции, и
    /// терять из-за этого переход на страницу незачем.
    func testANumberStoredAsAStringStillWorks() {
        XCTAssertEqual(DocumentLocator.target(metadata: ["page_number": .string("41")]), .page(41))
        XCTAssertEqual(DocumentLocator.target(metadata: ["page_number": .double(41)]), .page(41))
        XCTAssertEqual(DocumentLocator.target(metadata: ["page_number": .string("страница")]), .wholeDocument)
    }

    // MARK: - Чем открывать

    func testTheViewerKindFollowsTheFileType() {
        func kind(_ name: String) -> ViewerKind {
            DocumentLocator.kind(of: URL(fileURLWithPath: "/x/\(name)"))
        }
        XCTAssertEqual(kind("договор.pdf"), .pdf)
        XCTAssertEqual(kind("заметки.md"), .plainText)
        XCTAssertEqual(kind("данные.csv"), .plainText)
        XCTAssertEqual(kind("код.swift"), .plainText)
        XCTAssertEqual(kind("письмо.rtf"), .richText)
        XCTAssertEqual(kind("отчёт.docx"), .richText)
        XCTAssertEqual(kind("книга.epub"), .epub)
        XCTAssertEqual(kind("закупки.xlsx"), .table)
        // Keynote внутри не показывается — только системе.
        XCTAssertEqual(kind("презентация.key"), .externalOnly)
        XCTAssertEqual(kind("архив.zip"), .externalOnly)
        XCTAssertEqual(kind("файл-без-расширения"), .externalOnly)
    }

    /// Просмотрщик обязан соглашаться с извлечением: тип берётся из `UTType`,
    /// а не из строки расширения.
    func testTheKindIsDecidedByTypeNotBySpelling() {
        XCTAssertEqual(
            DocumentLocator.kind(of: URL(fileURLWithPath: "/x/ДОГОВОР.PDF")),
            .pdf
        )
    }
}
