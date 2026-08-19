import XCTest
@testable import ChromaCore

/// Уборка путей в уже наполненных коллекциях.
///
/// Коллекции прежних сборок хранят путь так, как его отдала файловая
/// система, и не несут отпечатка `file_id`. Текст при этом не меняется —
/// значит и векторы пересчитывать не за чем.
final class FilePathRepairTests: XCTestCase {
    private func record(_ id: String, path: String, fileID: String? = nil, name: String? = nil) -> DocumentRecord {
        var metadata: ChromaMetadata = ["source_file": .string(path)]
        if let fileID { metadata["file_id"] = .string(fileID) }
        if let name { metadata["file_name"] = .string(name) }
        return DocumentRecord(id: id, document: "текст", metadata: metadata)
    }

    /// Путь в старой форме — уборка нужна.
    func testAPathInTheOldFormNeedsRepair() {
        let old = "Отчёты/Договор.pdf".decomposedStringWithCanonicalMapping
        XCTAssertTrue(FilePathRepair.needsRepair(["source_file": .string(old)]))
    }

    /// Путь уже в единой форме, но отпечатка нет — тоже нужна: без него
    /// агент не может попросить файл целиком.
    func testAPathWithoutAFingerprintNeedsRepairToo() {
        XCTAssertTrue(FilePathRepair.needsRepair(["source_file": .string("docs/readme.md")]))
    }

    /// Всё на месте — трогать нечего: обновление, ничего не меняющее, это
    /// цена запроса, уплаченная зря.
    func testAHealthyChunkIsLeftAlone() {
        let path = "docs/readme.md"
        XCTAssertFalse(FilePathRepair.needsRepair([
            "source_file": .string(path),
            "file_id": .string(SourceSyncService.fileFingerprint(path)),
        ]))
    }

    /// Документ без пути вовсе — не наш случай: его записали вручную или
    /// через MCP, и выдумывать ему путь нельзя.
    func testADocumentWithoutAPathIsNotTouched() {
        XCTAssertFalse(FilePathRepair.needsRepair(["title": .string("заметка")]))
        XCTAssertFalse(FilePathRepair.needsRepair(nil))
    }

    /// Отпечаток, посчитанный от старой формы, тоже переписывается: иначе
    /// он не совпал бы с тем, что напишет следующая синхронизация.
    func testAFingerprintFromTheOldFormIsRewritten() {
        let old = "Отчёты/Договор.pdf".decomposedStringWithCanonicalMapping
        let stale = "0123456789abcdef"
        let updates = FilePathRepair.updates(for: [record("1", path: old, fileID: stale)])
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(
            updates[0].metadata?["file_id"],
            .string(SourceSyncService.fileFingerprint("Отчёты/Договор.pdf"))
        )
    }

    /// Что именно переписывается: путь, отпечаток и имя файла — в одной
    /// форме, той же, в какой их пишет синхронизация.
    func testTheRepairRewritesPathFingerprintAndName() {
        let old = "Отчёты/Первый/Договор.pdf".decomposedStringWithCanonicalMapping
        let oldName = "Договор.pdf".decomposedStringWithCanonicalMapping
        let updates = FilePathRepair.updates(for: [record("1", path: old, name: oldName)])

        XCTAssertEqual(updates.count, 1)
        let fields = try? XCTUnwrap(updates[0].metadata)
        XCTAssertEqual(
            (fields?["source_file"]).map { value -> [UInt8] in
                if case .string(let text) = value { return Array(text.utf8) }
                return []
            },
            Array("Отчёты/Первый/Договор.pdf".utf8)
        )
        XCTAssertEqual(
            (fields?["file_name"]).map { value -> [UInt8] in
                if case .string(let text) = value { return Array(text.utf8) }
                return []
            },
            Array("Договор.pdf".utf8)
        )
        XCTAssertEqual(
            fields?["file_id"],
            .string(SourceSyncService.fileFingerprint("Отчёты/Первый/Договор.pdf"))
        )
        XCTAssertTrue(updates[0].removedMetadataKeys.isEmpty, "уборка ничего не удаляет — только переписывает")
    }

    /// Здоровые чанки в список обновлений не попадают.
    func testOnlyTheChunksThatNeedItAreUpdated() {
        let path = "docs/readme.md"
        let healthy = record("1", path: path, fileID: SourceSyncService.fileFingerprint(path))
        let broken = record("2", path: "Отчёты/Договор.pdf".decomposedStringWithCanonicalMapping)
        let updates = FilePathRepair.updates(for: [healthy, broken])
        XCTAssertEqual(updates.map(\.id), ["2"])
    }

    /// В отчёте человеку нужны файлы, а не чанки: «двенадцать чанков»
    /// ничего не говорит, «три файла» говорит.
    func testFilesAreCountedByPathNotByChunk() {
        let path = "Отчёты/Договор.pdf"
        let records = [
            record("1", path: path.decomposedStringWithCanonicalMapping),
            record("2", path: path),
            record("3", path: "Отчёты/Акт.pdf"),
        ]
        XCTAssertEqual(FilePathRepair.fileCount(of: records), 2, "две формы одного пути — один файл")
    }
}
