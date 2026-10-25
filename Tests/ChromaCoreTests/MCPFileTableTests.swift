import XCTest
@testable import ChromaCore

/// `get_file` на таблицах: порядок книги, шапка на швах, колонки
/// строк в тексте.
final class MCPFileTableTests: XCTestCase {
    private func chunk(_ id: String, index: Int?, text: String = "текст") -> MCPDocumentPayload {
        var metadata: ChromaMetadata = ["source_file": .string("папка/файл.md")]
        if let index { metadata[MCPFileChunks.orderKey] = .int(index) }
        return MCPDocumentPayload(id: id, text: text, metadata: metadata)
    }

    private let key = "секретный-ключ"

    private struct Backend: MCPToolBackend {
        var chunks: [MCPDocumentPayload]
        var orderUnavailable = false
        final class Received: @unchecked Sendable {
            var documents: MCPDocumentsRequest?
        }
        let received = Received()

        func collections(allowed: [String]) async throws -> [MCPCollectionSummary] {
            [MCPCollectionSummary(name: "заметки", documentCount: chunks.count, model: "bge-m3", metric: "cosine", dimension: 8)]
        }

        func describe(collection: String) async throws -> MCPCollectionDescription {
            MCPCollectionDescription(
                summary: try await collections(allowed: [collection])[0],
                fields: [], hasSchema: false, allowsExtraFields: true
            )
        }

        func search(_ request: MCPSearchRequest) async throws -> MCPSearchAnswer {
            MCPSearchAnswer(documents: [], metric: "cosine", model: "bge-m3")
        }

        /// Ведёт себя как настоящий бэкенд: упорядочивает и режет окном.
        func documents(_ request: MCPDocumentsRequest) async throws -> MCPDocumentsAnswer {
            received.documents = request
            let ordered = request.orderedByChunkIndex ? MCPFileChunks.ordered(chunks) : chunks
            let window = MCPFileChunks.page(ordered, offset: request.offset, limit: request.limit)
            return MCPDocumentsAnswer(
                documents: window.page, hasMore: window.hasMore,
                total: request.orderedByChunkIndex ? ordered.count : nil,
                orderUnavailable: orderUnavailable
            )
        }

        func add(_ request: MCPAddRequest) async throws -> MCPAddAnswer {
            MCPAddAnswer(ids: [], model: "bge-m3")
        }

        func delete(_ request: MCPDeleteRequest) async throws -> MCPDeleteAnswer {
            MCPDeleteAnswer(deleted: [], missing: [], keptInTrash: false)
        }
    }

    private func service(
        _ backend: Backend, maxResults: Int? = nil, documentCharacters: Int? = nil
    ) async -> MCPToolService {
        let client = ExternalClient(
            name: "агент",
            keyHash: ClientKey.hash(key),
            keyPrefix: String(key.prefix(4)),
            permissions: ClientPermissions(
                collections: ["заметки"],
                requestsPerMinute: 600, burst: 600,
                maxSearchResults: maxResults,
                maxDocumentCharacters: documentCharacters
            )
        )
        let access = AccessController()
        await access.setClients([client])
        return MCPToolService(backend: backend, access: access, isReadOnlyServer: { false })
    }

    private func wholeText(_ backend: Backend) async throws -> String {
        let result = try await service(backend).call(
            name: MCPToolCatalogue.getFile.name,
            arguments: .object(["collection": .string("заметки"), "file": .string("папка/файл.md")]), key: key
        ).get()
        return result["content"]?[0]?["text"]?.stringValue ?? ""
    }

    // MARK: - Таблицы

    private func row(_ id: String, sheet: String, index: Int?, row: Int, extra: ChromaMetadata = [:]) -> MCPDocumentPayload {
        var metadata: ChromaMetadata = [
            "source_file": .string("папка/файл.md"), "sheet_name": .string(sheet),
            "row_number": .int(row), "table_mode": .string("dataTable"),
        ]
        if let index { metadata["sheet_index"] = .int(index) }
        metadata.merge(extra) { _, new in new }
        return MCPDocumentPayload(id: id, text: "Название: \(id)", metadata: metadata)
    }

    /// Строки книги — лист за листом в порядке книги и по номеру строки,
    /// а не по идентификатору; текст файла — перед ними.
    func testTableRowsComeInWorkbookOrder() {
        let documents = [
            row("zz", sheet: "Б", index: 0, row: 10),
            row("aa", sheet: "А", index: 1, row: 2),
            row("mm", sheet: "Б", index: 0, row: 2),
            chunk("text", index: 0),
        ]
        XCTAssertEqual(MCPFileChunks.ordered(documents).map(\.id), ["text", "mm", "zz", "aa"])
    }

    /// Куски двух листов-документов не перемежаются: у каждого свой счёт.
    func testDocumentSheetsDoNotInterleave() {
        func piece(_ id: String, sheet: String, sheetIndex: Int, index: Int) -> MCPDocumentPayload {
            MCPDocumentPayload(id: id, text: id, metadata: [
                "sheet_name": .string(sheet), "sheet_index": .int(sheetIndex), "chunk_index": .int(index),
            ])
        }
        let documents = [
            piece("b0", sheet: "Б", sheetIndex: 1, index: 0), piece("a1", sheet: "А", sheetIndex: 0, index: 1),
            piece("b1", sheet: "Б", sheetIndex: 1, index: 1), piece("a0", sheet: "А", sheetIndex: 0, index: 0),
        ]
        XCTAssertEqual(MCPFileChunks.ordered(documents).map(\.id), ["a0", "a1", "b0", "b1"])
    }

    /// Без `sheet_index` (прежняя сборка) — по имени листа, как их называет
    /// человек: «Лист2» перед «Лист10».
    func testSheetsWithoutAnIndexGoByName() {
        let documents = [row("x", sheet: "Лист10", index: nil, row: 2), row("y", sheet: "Лист2", index: nil, row: 2)]
        XCTAssertEqual(MCPFileChunks.ordered(documents).map(\.id), ["y", "x"])
    }

    /// Шапка, повторённая в начале куска, убирается на швах внутри ответа —
    /// у первого куска она остаётся; мера, не сошедшаяся с текстом, не
    /// срезает ничего.
    func testARepeatedTableHeaderIsDroppedAtTheSeams() async throws {
        let header = "| Показатель | Значение |\n| --- | --- |"
        func piece(_ index: Int, _ body: String, headed: Bool) -> MCPDocumentPayload {
            var metadata: ChromaMetadata = ["source_file": .string("папка/файл.md"), "chunk_index": .int(index)]
            if headed { metadata[TableChunkHeaders.lengthKey] = .int(header.count + 1) }
            return MCPDocumentPayload(id: "c\(index)", text: headed ? header + "\n" + body : body, metadata: metadata)
        }
        let backend = Backend(chunks: [
            piece(0, header + "\n| Выручка | 10 |", headed: false),
            piece(1, "| Прибыль | 3 |", headed: true),
            piece(2, "| Налог | 1 |", headed: true),
        ])
        let text = try await wholeText(backend)
        XCTAssertEqual(text.components(separatedBy: "| Показатель |").count - 1, 1, text)
        XCTAssertTrue(text.contains("| Прибыль | 3 |") && text.contains("| Налог | 1 |"), text)
        XCTAssertTrue(text.contains("table header repeated"), text)

        let wrong = MCPDocumentPayload(id: "w", text: "Обычный абзац текста документа", metadata: [TableChunkHeaders.lengthKey: .int(8)])
        XCTAssertNil(MCPToolService.repeatedHeader(of: wrong, text: wrong.text ?? ""))
    }

    /// Строка таблицы текстом несёт адрес и свои колонки из метаданных —
    /// а одинаковые у всех строк — один раз пометкой.
    func testATableRowAsTextCarriesItsAddressAndColumns() async throws {
        let backend = Backend(chunks: [
            row("Болт", sheet: "Прайс", index: 0, row: 2, extra: ["Цена": .double(12.5), "год": .int(2024)]),
            row("Гайка", sheet: "Прайс", index: 0, row: 3, extra: ["Цена": .int(8), "год": .int(2024)]),
        ])
        let text = try await wholeText(backend)
        XCTAssertTrue(text.contains("Прайс, row 2"), text)
        XCTAssertTrue(text.contains("Цена: 12.5"), text)
        XCTAssertTrue(text.contains("Цена: 8"), text)
        XCTAssertEqual(text.components(separatedBy: "год: 2024").count - 1, 1, "одинаковое у всех строк — один раз пометкой: \(text)")
        XCTAssertFalse(text.contains("row_number:"), text)
    }

    /// Чтение текстом — умолчание `get_file` — предупреждает о таблице, по
    /// которой нельзя считать, так же, как любая другая выдача, и общие
    /// колонки строк платят из бюджета: длины у них нет, и ответ на сотне
    /// длинных колонок уходил за потолок ключа.
    func testTextReadingWarnsAboutTablesAndStaysInsideTheCeiling() async throws {
        var shared: ChromaMetadata = ["sheets_indexed": .int(2), "sheets_total": .int(5), "tables_flat": .bool(true)]
        for column in 0..<120 {
            shared["Колонка с длинным названием номер \(column)"] = .string(String(repeating: "значение ", count: 4))
        }
        let rows = (0..<400).map { index in
            row("строка-\(index)-" + String(repeating: "т", count: 120), sheet: "Смета", index: 0, row: index + 2,
                extra: shared.merging(["Цена": .int(index)]) { _, new in new })
        }
        let result = try await service(Backend(chunks: rows)).call(
            name: MCPToolCatalogue.getFile.name,
            arguments: .object(["collection": .string("заметки"), "file": .string("папка/файл.md")]), key: key
        ).get()
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        let mirror = result["structuredContent"].map { $0.deliveredSize } ?? 0
        XCTAssertTrue(text.contains("the table stayed flat text"), "нет предупреждения о плоской таблице")
        XCTAssertTrue(text.contains("the workbook is not indexed whole"), "нет предупреждения о книге не целиком")
        XCTAssertTrue(text.contains("Every table row here also carries"), text.prefix(400).description)
        XCTAssertLessThanOrEqual(text.count + mirror, MCPOutputLimits.defaultResponseCharacters,
                                 "текст \(text.count), зеркало \(mirror)")
    }
}
