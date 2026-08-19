import XCTest
@testable import ChromaCore

/// Проверка «файлов больше нет на диске».
///
/// Нужна из-за переименования папок: путь у файла становится другим, он
/// индексируется заново, а чанки под прежним путём остаются в базе. Удаление
/// по-прежнему ручное — приложение не удаляет ничего само.
final class FilesGoneFromDiskTests: XCTestCase {
    private struct Reader: InspectionReader {
        var records: [DocumentRecord]

        func count(collectionID: String) async throws -> Int { records.count }
        func documents(collectionID: String, limit: Int, offset: Int) async throws -> [DocumentRecord] {
            Array(records.dropFirst(offset).prefix(limit))
        }
        func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord] {
            records.filter { ids.contains($0.id) }
        }
        func embeddings(collectionID: String, ids: [String]) async throws -> [String: [Double]] { [:] }
        func query(collectionID: String, embedding: [Double], nResults: Int) async throws -> [QueryHit] { [] }
    }

    private let sourceID = UUID().uuidString

    private func record(_ id: String, file: String) -> DocumentRecord {
        DocumentRecord(
            id: id,
            document: "текст документа достаточной длины, чтобы не считаться пустым",
            metadata: [
                "source_id": .string(sourceID),
                "source_file": .string(file),
                "chunk_index": .int(0),
            ]
        )
    }

    private func report(
        _ records: [DocumentRecord], onDisk: [String: Set<String>]?
    ) async throws -> InspectionReport {
        try await CollectionInspector(reader: Reader(records: records)).inspect(
            context: CollectionInspector.Context(
                collection: ChromaCollection(id: "c", name: "systems", metadata: nil),
                knownSourceIDs: [sourceID],
                filesOnDisk: onDisk
            )
        )
    }

    private func gone(_ report: InspectionReport) -> [InspectionFinding] {
        report.findings.filter { $0.category == .filesGoneFromDisk }
    }

    /// Папку переименовали: чанки старого пути остались, и о них сказано.
    func testAFileMissingFromDiskIsReported() async throws {
        let records = [
            record("a-0", file: "2025/Система 1/устав.md"),
            record("a-1", file: "2025/Система 1/устав.md"),
            record("b-0", file: "2025/Система 2/акт.md"),
        ]
        let produced = try await report(records, onDisk: [sourceID: ["2025/Система 2/акт.md"]])

        let findings = gone(produced)
        XCTAssertEqual(findings.map(\.subject), ["2025/Система 1/устав.md"])
        XCTAssertEqual(findings.first?.documentIDs, ["a-0", "a-1"], "все чанки файла — одной находкой")
    }

    /// Не спрашивали — не отвечаем. Без набора файлов проверка не делается
    /// вовсе: молчание честнее догадки.
    func testWithoutTheFileSetNothingIsChecked() async throws {
        let produced = try await report([record("a-0", file: "нет такого.md")], onDisk: nil)
        XCTAssertTrue(gone(produced).isEmpty)
    }

    /// Источник, папку которого прочитать не удалось, в набор не попадает —
    /// и его файлы не объявляются исчезнувшими.
    func testAnUnreadableSourceIsNotJudged() async throws {
        let produced = try await report([record("a-0", file: "устав.md")], onDisk: [:])
        XCTAssertTrue(gone(produced).isEmpty)
    }

    func testFilesThatAreStillThereAreSilent() async throws {
        let produced = try await report(
            [record("a-0", file: "устав.md")], onDisk: [sourceID: ["устав.md"]]
        )
        XCTAssertTrue(gone(produced).isEmpty)
    }

    /// Находка — по файлу, а не по чанку: у документа их сотни, и сотня
    /// одинаковых строк скрыла бы весь остальной отчёт.
    func testOneFindingPerFile() async throws {
        let records = (0..<50).map { record("x-\($0)", file: "старая папка/договор.md") }
        let produced = try await report(records, onDisk: [sourceID: []])
        XCTAssertEqual(gone(produced).count, 1)
        XCTAssertEqual(gone(produced).first?.documentIDs.count, 50)
    }

    /// Категория не информационная: это дефект, который человек должен увидеть
    /// в списке к решению.
    func testTheCategoryIsADefect() {
        XCTAssertFalse(InspectionCategory.filesGoneFromDisk.isInformational)
        XCTAssertFalse(InspectionCategory.filesGoneFromDisk.suggestion.isEmpty)
    }
}
