import XCTest
@testable import ChromaCore

/// «Скопировать источник»: настройки — с собой, прогоны — нет.
final class SourceCopyTests: XCTestCase {
    private func original() -> DataSource {
        var source = DataSource(
            name: "Договоры",
            path: "/Users/test/Договоры",
            fileExtensions: ["pdf", "docx"],
            recursive: true,
            mapping: .subfoldersToCollections,
            collectionName: "dogovory",
            embeddingModel: "qwen3-embedding-4b",
            chunking: ChunkingConfiguration(strategy: .adaptive, chunkSize: 800)
        )
        source.customMetadata = ["отдел": "закупки"]
        source.excludedPaths = ["битый.pdf"]
        source.ocrEnabled = true
        source.lastSyncedAt = Date(timeIntervalSince1970: 1_000)
        source.volume = SourceVolume(uuid: "VOL", name: "Backup")
        source.transliteratesCollectionNames = false
        return source
    }

    func testACopyKeepsTheSettingsAndDropsTheRuns() {
        let source = original()
        let copy = source.copied()
        XCTAssertNotEqual(copy.id, source.id, "по id живут манифесты — у копии свои")
        XCTAssertEqual(copy.name, "Договоры — копия")
        XCTAssertNil(copy.lastSyncedAt)
        XCTAssertNil(copy.volume)
        XCTAssertTrue(copy.transliteratesCollectionNames, "у копии нет файлов под прежними именами")
        XCTAssertEqual(copy.path, source.path)
        XCTAssertEqual(copy.fileExtensions, source.fileExtensions)
        XCTAssertEqual(copy.mapping, source.mapping)
        XCTAssertEqual(copy.collectionName, source.collectionName)
        XCTAssertEqual(copy.chunking, source.chunking)
        XCTAssertEqual(copy.embeddingModel, source.embeddingModel)
        XCTAssertEqual(copy.customMetadata, source.customMetadata)
        XCTAssertEqual(copy.excludedPaths, source.excludedPaths)
        XCTAssertEqual(copy.ocrEnabled, source.ocrEnabled)
    }

    func testACopyWithTheSameFolderAndCollectionWritesTheSameDocuments() {
        let source = original()
        var copy = source.copied()
        XCTAssertTrue(copy.writesSameDocuments(as: source))
        copy.chunking.chunkSize = 400
        XCTAssertTrue(copy.writesSameDocuments(as: source), "нарезка не меняет, куда ложатся файлы")
        copy.collectionName = "dogovory_400"
        XCTAssertFalse(copy.writesSameDocuments(as: source))
        copy.collectionName = source.collectionName
        copy.path = "/Users/test/Акты"
        XCTAssertFalse(copy.writesSameDocuments(as: source), "другая папка в ту же коллекцию — обычное дело")
    }

    /// У веб-источника в окне правят адрес, а `path` переписывается из него
    /// только при сохранении: сравнение — по адресу.
    func testAWebCopyWithAnotherAddressDoesNotWriteTheSameDocuments() {
        var source = DataSource(
            name: "Сайт", path: "https://example.org/a", mapping: .folderToCollection, collectionName: "web"
        )
        var web = WebSourceSettings()
        web.startURL = "https://example.org/a"
        source.web = web
        var copy = source.copied()
        XCTAssertTrue(copy.writesSameDocuments(as: source))
        copy.web?.startURL = "https://example.org/b"
        XCTAssertFalse(copy.writesSameDocuments(as: source), "path ещё прежний, но адрес уже другой")
    }
}

