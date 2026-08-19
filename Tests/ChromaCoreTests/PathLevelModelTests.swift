import XCTest
@testable import ChromaCore

/// Уровни вложенности как поля метаданных — модель и подписи.
final class PathLevelModelTests: XCTestCase {
    // MARK: - Ключ

    /// Ключ — латиницей: по нему фильтруют, а не читают. Значение при этом
    /// остаётся тем, что написано на папке.
    func testTheKeyIsLatinAndTheValueIsWhatever() {
        XCTAssertNil(PathLevel.keyProblem("year"))
        XCTAssertNil(PathLevel.keyProblem("system_name"))
        XCTAssertNil(PathLevel.keyProblem(""), "пустой ключ — это «уровень не назван», а не ошибка")
        XCTAssertNotNil(PathLevel.keyProblem("год"))
        XCTAssertNotNil(PathLevel.keyProblem("2025"))
        XCTAssertNotNil(PathLevel.keyProblem("название системы"))

        let level = PathLevel(key: "system", type: .string)
        XCTAssertEqual(level.value(for: "Система 1"), .string("Система 1"))
    }

    /// Занять служебное поле нельзя: `source_file` и `relative_path` — то, на
    /// чём держится инкрементальная синхронизация.
    func testTechnicalKeysAreRefused() {
        for key in ["source_file", "relative_path", "chunk_index", "row_key"] {
            XCTAssertNotNil(PathLevel.keyProblem(key), key)
        }
    }

    /// Поля, которые конвейер пишет **после** метаданных маршрута: уровень
    /// с таким ключом молча перезаписался бы языком чанка, и человек увидел
    /// бы в базе не то, что показал предпросмотр.
    func testKeysTheExtractionWritesLaterAreRefused() {
        for key in ["language", "keywords", "document_language", "extractor_id"] {
            XCTAssertNotNil(PathLevel.keyProblem(key), key)
        }
    }

    // MARK: - Тип уровня

    /// Год разумно объявить числом — и тогда папка «архив» значения не даёт.
    /// Записать в числовое поле строку значило бы поссорить чанк со схемой
    /// коллекции на ровном месте.
    func testAValueThatDoesNotFitTheTypeIsNotWritten() {
        let year = PathLevel(key: "year", type: .integer)
        XCTAssertEqual(year.value(for: "2025"), .int(2025))
        XCTAssertNil(year.value(for: "архив"))
    }

    func testTheFallbackIsParsedByTheSameType() {
        let year = PathLevel(key: "year", type: .integer, fallbackValue: "0")
        XCTAssertEqual(year.parsedFallback, .int(0))
        XCTAssertNil(PathLevel(key: "year", type: .integer).parsedFallback,
                     "пустое значение — поле не пишется вовсе")
    }

    // MARK: - Подпись метаданных

    private func source(levels: [PathLevel] = [], custom: [String: String] = [:]) -> DataSource {
        DataSource(
            name: "тест", path: "/tmp", mapping: .folderToCollection,
            collectionName: "docs", pathLevels: levels, customMetadata: custom
        )
    }

    /// Пустой список уровней — поведение ровно прежнее, и подпись это говорит.
    func testASourceWithoutLevelsHasAStableSignature() {
        XCTAssertEqual(source().metadataSignature, source().metadataSignature)
        XCTAssertNotEqual(
            source().metadataSignature,
            source(levels: [PathLevel(key: "year")]).metadataSignature
        )
    }

    /// Подпись меняется от всего, что попадает в метаданные чанка помимо
    /// текста: имя ключа, тип, значение по умолчанию, ручные поля.
    func testEverythingThatReachesTheChunkChangesTheSignature() {
        let base = source(levels: [PathLevel(key: "year", type: .string)])
        XCTAssertNotEqual(base.metadataSignature, source(levels: [PathLevel(key: "god", type: .string)]).metadataSignature)
        XCTAssertNotEqual(base.metadataSignature, source(levels: [PathLevel(key: "year", type: .integer)]).metadataSignature)
        XCTAssertNotEqual(
            base.metadataSignature,
            source(levels: [PathLevel(key: "year", type: .string, fallbackValue: "нет")]).metadataSignature
        )
        XCTAssertNotEqual(base.metadataSignature, source(levels: [PathLevel(key: "year")], custom: ["owner": "закупки"]).metadataSignature)
    }

    /// Порядок уровней — это номера уровней, и перестановка меняет смысл.
    func testTheOrderOfLevelsMatters() {
        let direct = source(levels: [PathLevel(key: "year"), PathLevel(key: "system")])
        let reversed = source(levels: [PathLevel(key: "system"), PathLevel(key: "year")])
        XCTAssertNotEqual(direct.metadataSignature, reversed.metadataSignature)
    }

    /// А порядок ручных полей — нет: это словарь, и его перебор непредсказуем.
    func testTheOrderOfCustomFieldsDoesNot() {
        var first = source(custom: ["a": "1", "b": "2"])
        let second = source(custom: ["b": "2", "a": "1"])
        XCTAssertEqual(first.metadataSignature, second.metadataSignature)
        first.customMetadata["c"] = "3"
        XCTAssertNotEqual(first.metadataSignature, second.metadataSignature)
    }

    /// Неназванный уровень в подпись не входит: он ничего не пишет, и менять
    /// из-за него метаданные всей базы было бы работой на ровном месте.
    func testAnUnnamedLevelIsNotPartOfTheSignature() {
        XCTAssertEqual(
            source(levels: [PathLevel(key: "year"), PathLevel(key: "")]).metadataSignature,
            source(levels: [PathLevel(key: "year")]).metadataSignature
        )
    }

    // MARK: - Хранение

    /// Источник прежней сборки уровней не знает — и это «их нет», а не отказ
    /// прочитать настройки: в одном файле лежат все источники и все серверы.
    func testAnOlderSourceDecodesWithoutLevels() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"старый","path":"/tmp","collectionName":"docs"}
        """
        let source = try JSONDecoder().decode(DataSource.self, from: Data(json.utf8))
        XCTAssertTrue(source.pathLevels.isEmpty)
        XCTAssertEqual(source.mapping, .folderToCollection)
    }

    func testLevelsSurviveARoundTrip() throws {
        let original = source(levels: [
            PathLevel(key: "year", type: .integer, fallbackValue: "0"),
            PathLevel(key: "system", type: .string),
        ])
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(DataSource.self, from: data)
        XCTAssertEqual(restored.pathLevels, original.pathLevels)
        XCTAssertEqual(restored.metadataSignature, original.metadataSignature)
    }

    /// Запись манифеста прежней сборки: подписи нет — значит «неизвестно».
    /// Объявлять её расхождением значило бы предложить переписать метаданные
    /// всей базы после первого же обновления.
    func testAnOlderManifestEntryHasNoMetadataSignature() throws {
        let json = """
        {"relativePath":"a.md","contentHash":"h","modifiedAt":0,"size":1,
         "chunkIDs":["x"],"collectionName":"docs"}
        """
        let entry = try JSONDecoder().decode(ManifestEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.metadataSignature, "")
    }

    /// Подпись доезжает до манифеста через журнал: прогон, доигранный после
    /// сбоя, обязан записать то же, что записал бы прерванный.
    func testTheJournalCarriesTheSignatureIntoTheManifest() {
        let record = SyncJournalEntry(
            relativePath: "a.md", collectionName: "docs", oldIDs: [], newIDs: ["x-0"],
            contentHash: "h", metadataSignature: "map:folderToCollection/levels:[1=year:string:]/custom:[]",
            modifiedAt: Date(), size: 1, chunkingSignature: "sig", embeddingModel: "model"
        )
        XCTAssertEqual(record.manifestEntry().metadataSignature, record.metadataSignature)
    }
}
