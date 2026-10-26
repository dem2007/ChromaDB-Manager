import XCTest
@testable import ChromaCore

/// Файлы коллекции: каждый файл — одной строкой, со своим ID для get_file.
final class CollectionFilesTests: XCTestCase {
    private func chunk(
        _ path: String?, id: String? = nil, name: String? = nil, count: Int? = nil,
        size: Int? = nil, modified: String? = nil, source: String? = nil
    ) -> ChromaMetadata {
        var metadata: ChromaMetadata = [:]
        if let path { metadata["source_file"] = .string(path) }
        if let id { metadata["file_id"] = .string(id) }
        if let name { metadata["file_name"] = .string(name) }
        if let count { metadata["chunk_count"] = .int(count) }
        if let size { metadata["file_size"] = .int(size) }
        if let modified { metadata["file_mtime"] = .string(modified) }
        if let source { metadata["_cdbm_source_name"] = .string(source) }
        return metadata
    }

    private func list(_ chunks: [ChromaMetadata?]) -> CollectionFileList {
        var grouping = CollectionFiles.Grouping()
        chunks.forEach { grouping.take($0) }
        return grouping.list(documentCount: chunks.count, builtAt: Date())
    }

    /// Главное: куски одного файла — один файл, с ID, числом кусков и
    /// полями файла; записи без исходника считаются отдельно.
    func testChunksOfOneFileBecomeOneFile() {
        let result = list([
            chunk("Договоры/2030/Договор.pdf", id: "a1", name: "Договор.pdf", count: 2, size: 1200, modified: "2030-03-01T10:00:00Z"),
            chunk("Договоры/2030/Договор.pdf", id: "a1", name: "Договор.pdf", count: 2),
            chunk("Заметки.md", id: "b2"),
            nil,
            chunk(nil),
        ])
        XCTAssertEqual(result.files.map(\.path), ["Договоры/2030/Договор.pdf", "Заметки.md"])
        let contract = result.files[0]
        XCTAssertEqual(contract.fileID, "a1")
        XCTAssertEqual(contract.chunks, 2)
        XCTAssertEqual(contract.sizeBytes, 1200)
        XCTAssertEqual(contract.folder, "Договоры/2030")
        XCTAssertNotNil(contract.modifiedDate)
        XCTAssertFalse(contract.isIncomplete)
        XCTAssertEqual(result.files[1].name, "Заметки.md", "без file_name имя — конец пути")
        XCTAssertEqual(result.records, 5)
        XCTAssertEqual(result.recordsWithoutFile, 2)
        XCTAssertEqual(result.filesWithoutID, 0)
    }

    /// Один путь в двух источниках — два файла: у каждого свой отпечаток,
    /// и get_file по одному из них не вернёт кусков другого.
    func testTheSamePathInTwoSourcesStaysTwoFiles() {
        let result = list([
            chunk("README.md", id: "x", source: "Первый"),
            chunk("README.md", id: "y", source: "Второй"),
        ])
        XCTAssertEqual(result.files.count, 2)
        XCTAssertEqual(Set(result.files.compactMap(\.fileID)), ["x", "y"])
    }

    /// Ранняя сборка ID не писала: файл узнаётся по пути, и выбираются его
    /// куски тоже по пути.
    func testAFileWithoutIDIsFoundByPath() {
        let result = list([chunk("Старое/Отчёт.docx"), chunk("Старое/Отчёт.docx")])
        let file = result.files[0]
        XCTAssertNil(file.fileID)
        XCTAssertEqual(file.chunks, 2)
        XCTAssertEqual(file.condition.field, "source_file")
        XCTAssertEqual(file.condition.value, "Старое/Отчёт.docx")
        XCTAssertEqual(result.filesWithoutID, 1)
        XCTAssertEqual(list([chunk("a.txt", id: "z")]).files[0].condition.field, "file_id")
    }

    /// Кусков меньше, чем синхронизация записала, — запись оборвалась.
    func testFewerChunksThanRecordedIsIncomplete() {
        let result = list([chunk("a.pdf", id: "a", count: 3), chunk("a.pdf", id: "a", count: 3)])
        XCTAssertTrue(result.files[0].isIncomplete)
        XCTAssertEqual(result.files[0].expectedChunks, 3)
    }

    /// Поиск — по имени и пути, без учёта регистра, «ё» как «е».
    func testSearchMatchesNameAndPathIgnoringCaseAndYo() {
        let file = list([chunk("Отчёты/Итоги года.xlsx", id: "a")]).files[0]
        XCTAssertTrue(CollectionFiles.matches(file, query: "отчеты"))
        XCTAssertTrue(CollectionFiles.matches(file, query: "ИТОГИ"))
        XCTAssertTrue(CollectionFiles.matches(file, query: "  "))
        XCTAssertFalse(CollectionFiles.matches(file, query: "смета"))
    }

    /// Выгрузка: поле с запятой или кавычкой — в кавычках.
    func testCSVQuotesFieldsThatNeedIt() {
        let csv = CollectionFiles.csv(list([chunk("Папка/Акт, итог \"А\".pdf", id: "q1", count: 1)]))
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.first, "name,path,file_id,source,chunks,expected_chunks,bytes,modified,format,pages")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].hasPrefix("\"Акт, итог \"\"А\"\".pdf\",\"Папка/Акт, итог \"\"А\"\".pdf\",q1,,1,1,"), String(lines[1]))
    }

    /// Сервер вправе отдать меньше, чем просили: короткая страница — конец
    /// только тогда, когда прочитано всё.
    func testAServerThatCapsPagesIsReadToTheEnd() async throws {
        actor CappedReader: CollectionFileReader {
            let records: [DocumentRecord]
            init(_ records: [DocumentRecord]) { self.records = records }
            func count(collectionID: String) async throws -> Int { records.count }
            func metadataPage(collectionID: String, filter: DocumentFilter?, limit: Int, offset: Int) async throws -> [DocumentRecord] {
                Array(records.dropFirst(offset).prefix(min(limit, 2)))
            }
        }
        let records = (0..<5).map { index in
            DocumentRecord(id: "c\(index)", document: nil, metadata: [
                "source_file": .string("f\(index).txt"), "file_id": .string("id\(index)"),
            ])
        }
        let built = try await CollectionFiles.build(reader: CappedReader(records), collectionID: "col", pageSize: 4)
        XCTAssertEqual(built.files.count, 5, "все пять файлов, а не первая страница")
    }

    /// Начало «=», «+», «-», «@» таблица прочла бы как формулу.
    func testCSVDefusesFormulas() {
        XCTAssertEqual(CSVText.field("=HYPERLINK(\"x\")"), "\"'=HYPERLINK(\"\"x\"\")\"")
        XCTAssertEqual(CSVText.field("+1"), "'+1")
        XCTAssertEqual(CSVText.field("обычное имя.pdf"), "обычное имя.pdf")
    }

    /// Обход — страницами до конца, со сведениями о ходе.
    func testBuildPagesThroughTheWholeCollection() async throws {
        actor Reader: CollectionFileReader {
            let records: [DocumentRecord]
            var asked: [Int] = []
            init(_ records: [DocumentRecord]) { self.records = records }
            func count(collectionID: String) async throws -> Int { records.count }
            func metadataPage(collectionID: String, filter: DocumentFilter?, limit: Int, offset: Int) async throws -> [DocumentRecord] {
                asked.append(offset)
                return Array(records.dropFirst(offset).prefix(limit))
            }
        }
        let records = (0..<5).map { index in
            DocumentRecord(id: "c\(index)", document: nil, metadata: [
                "source_file": .string(index < 3 ? "a.txt" : "b.txt"),
                "file_id": .string(index < 3 ? "a" : "b"),
            ])
        }
        let reader = Reader(records)
        let built = try await CollectionFiles.build(reader: reader, collectionID: "col", pageSize: 2)
        XCTAssertEqual(built.files.map(\.chunks), [3, 2])
        XCTAssertEqual(built.documentCount, 5)
        let asked = await reader.asked
        XCTAssertEqual(asked, [0, 2, 4], "последняя неполная страница — конец обхода")
    }
}
