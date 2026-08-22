import XCTest
@testable import ChromaCore

/// Проекция метаданных на живой базе.
///
/// Здесь проверяется не формула, а величина: сколько бюджета ответа съедают
/// колонки строк таблиц и сколько остаётся, когда агент назвал нужные поля.
/// Считает **настоящий** `MCPDocumentRendering.render`, а не его пересказ:
/// свой пересказ алгоритма в скрипте уже однажды показал цифры, которых
/// приложение не даёт.
///
///     CHROMA_IT=1 CHROMA_LIVE_PORT=56853 CHROMA_LIVE_COLLECTION=base_adaptive_geaorge_4b \
///         swift test --filter MCPProjectionLiveTests
final class MCPProjectionLiveTests: XCTestCase {
    private var port = 0
    private var collectionName = ""

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["CHROMA_IT"] == "1", "Живая проверка включается CHROMA_IT=1")
        guard let port = environment["CHROMA_LIVE_PORT"].flatMap(Int.init),
              let name = environment["CHROMA_LIVE_COLLECTION"], !name.isEmpty
        else {
            throw XCTSkip("Нужны CHROMA_LIVE_PORT и CHROMA_LIVE_COLLECTION")
        }
        self.port = port
        self.collectionName = name
    }

    func testProjectionFreesTheAnswerBudgetOnRealTableRows() async throws {
        let client = ChromaClient(endpoint: ChromaEndpoint(host: "127.0.0.1", port: port))
        let collections = try await client.listCollections(withCounts: false)
        guard let collection = collections.first(where: { $0.name == collectionName }) else {
            throw XCTSkip("Нет коллекции «\(collectionName)»")
        }

        // Строки таблиц спрашиваются условием, а не надеждой на выборку:
        // на живых коллекциях их бывает шестая часть.
        var filter = DocumentFilter()
        filter.conditions = [
            MetadataCondition(field: "row_number", op: .greaterOrEqual, value: "0"),
        ]
        let records = try await client.getDocuments(
            collectionID: collection.id, limit: 2000, offset: 0, filter: filter
        )
        try XCTSkipIf(records.isEmpty, "В коллекции нет строк таблиц")

        let payloads = records.map {
            MCPDocumentPayload(id: $0.id, text: $0.document, metadata: $0.metadata, distance: 0.1)
        }
        // Две выборки, потому что польза от проекции у них разная. Широкие
        // строки — случай, ради которого она и сделана (у строки из формы ФЭО
        // колонок больше сотни); обычные — проверка, что на них не хуже.
        let widest = Array(payloads.sorted { weight(of: $0) > weight(of: $1) }.prefix(100))
        let step = max(1, payloads.count / 100)
        let spread = Array(stride(from: 0, to: payloads.count, by: step).map { payloads[$0] }.prefix(100))

        let limits = MCPOutputLimits()
        var results: [(String, Int, Int)] = []
        for (title, sample) in [("сто самых широких строк", widest), ("сто строк вразброс", spread)] {
            let columns = ["source_file", "row_number"]
                + fieldNames(in: sample)
                    .filter { $0.contains("стоимость") || $0.contains("цена") }
                    .prefix(2)

            let whole = MCPDocumentRendering.render(sample, limits: limits)
            let projected = MCPDocumentRendering.render(sample, limits: limits, fields: columns)
            let wholeWeight = sample.reduce(0) { $0 + weight(of: $1) }
            let projectedWeight = sample.reduce(0) { $0 + weight(of: $1, fields: columns) }

            print("""

            # Проекция метаданных, «\(collectionName)», \(title)
            поля в проекции: \(columns.joined(separator: ", "))
            метаданные выборки: \(wholeWeight) знаков, \(wholeWeight / sample.count) на строку
            то же с проекцией:  \(projectedWeight) знаков, \(projectedWeight / sample.count) на строку
            строк в ответ (бюджет \(limits.responseCharacters)): было \(whole.shown), стало \(projected.shown)

            """)

            // Проекция не может ни утяжелить ответ, ни выбросить из него строки.
            XCTAssertLessThanOrEqual(projectedWeight, wholeWeight)
            XCTAssertGreaterThanOrEqual(projected.shown, whole.shown)
            // Ответ остаётся ответом: те же строки, только без лишних колонок.
            XCTAssertEqual(projected.documents.first?["id"], whole.documents.first?["id"])
            results.append((title, whole.shown, projected.shown))
        }

        // Ради чего всё это: на широких строках выигрыш должен быть кратным.
        XCTAssertGreaterThan(results[0].2, results[0].1 * 2)
    }

    /// Текстовые куски — вторая задача агента: собрать формулировки из
    /// полусотни документов. У них метаданных не меньше, чем у строк таблиц,
    /// хотя ждёшь обратного: путь, заголовки, номер документа.
    func testProjectionHelpsTextChunksToo() async throws {
        let client = ChromaClient(endpoint: ChromaEndpoint(host: "127.0.0.1", port: port))
        let collections = try await client.listCollections(withCounts: false)
        guard let collection = collections.first(where: { $0.name == collectionName }) else {
            throw XCTSkip("Нет коллекции «\(collectionName)»")
        }

        let records = try await client.getDocuments(
            collectionID: collection.id, limit: 500, offset: 0
        )
        let chunks = records
            .filter { $0.metadata?["row_number"] == nil }
            .prefix(100)
        try XCTSkipIf(chunks.count < 10, "Текстовых кусков в выборке почти нет")

        let payloads = chunks.map {
            MCPDocumentPayload(id: $0.id, text: $0.document, metadata: $0.metadata, distance: 0.1)
        }
        // Для сравнения формулировок нужен сам текст и то, откуда он взят.
        let columns = ["source_file"]
        // Текст урезан до 800 знаков — так эту задачу и решают: нужна
        // формулировка, а не документ целиком.
        let limits = MCPOutputLimits(documentCharacters: 800)
        let whole = MCPDocumentRendering.render(payloads, limits: limits)
        let projected = MCPDocumentRendering.render(payloads, limits: limits, fields: columns)

        let wholeWeight = payloads.reduce(0) { $0 + weight(of: $1) }
        let projectedWeight = payloads.reduce(0) { $0 + weight(of: $1, fields: columns) }

        print("""

        # Проекция на текстовых кусках, «\(collectionName)», \(payloads.count) кусков
        метаданных на кусок: \(wholeWeight / payloads.count) → \(projectedWeight / payloads.count)
        кусков в ответ (бюджет \(limits.responseCharacters), текст до \(limits.documentCharacters)):\
         было \(whole.shown), стало \(projected.shown)

        """)

        XCTAssertGreaterThan(projected.shown, whole.shown)
    }

    /// Вес метаданных так, как их видит модель, — строкой «поле=значение».
    private func weight(of payload: MCPDocumentPayload, fields: [String]? = nil) -> Int {
        MCPDocumentRendering.metadataLine(
            MCPDocumentRendering.projected(payload.metadata, to: fields.map(Set.init))
        ).count
    }

    private func fieldNames(in payloads: [MCPDocumentPayload]) -> [String] {
        var names: Set<String> = []
        for payload in payloads { if let metadata = payload.metadata { names.formUnion(metadata.keys) } }
        return names.sorted()
    }
}
