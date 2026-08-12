import XCTest
@testable import ChromaCore

/// §K1 — фасетный обзор коллекции.
final class CollectionFacetTests: XCTestCase {
    private final class Reader: InspectionReader, @unchecked Sendable {
        var records: [DocumentRecord] = []
        private(set) var pages = 0

        func count(collectionID: String) async throws -> Int { records.count }

        func documents(collectionID: String, limit: Int, offset: Int) async throws -> [DocumentRecord] {
            pages += 1
            guard offset < records.count else { return [] }
            return Array(records[offset..<min(offset + limit, records.count)])
        }

        func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord] {
            let wanted = Set(ids)
            return records.filter { wanted.contains($0.id) }
        }

        func embeddings(collectionID: String, ids: [String]) async throws -> [String: [Double]] {
            XCTFail("обзору векторы не нужны — он про состав коллекции, а не про векторное пространство")
            return [:]
        }

        func query(collectionID: String, embedding: [Double], nResults: Int) async throws -> [QueryHit] {
            XCTFail("обзор ничего не ищет")
            return []
        }
    }

    private let collection = ChromaCollection(id: "id", name: "проба", metadata: nil)

    private func record(_ id: String, text: String, metadata: ChromaMetadata) -> DocumentRecord {
        DocumentRecord(id: id, document: text, metadata: metadata)
    }

    func testDistributionsAreCountedAndSortedByFrequency() async throws {
        let reader = Reader()
        reader.records = [
            record("1", text: "текст", metadata: ["file_ext": .string("md"), "extractor_id": .string("plaintext")]),
            record("2", text: "текст", metadata: ["file_ext": .string("md"), "extractor_id": .string("plaintext")]),
            record("3", text: "текст", metadata: ["file_ext": .string("pdf"), "extractor_id": .string("pdf")]),
            record("4", text: "текст", metadata: [:]),
        ]

        let overview = try await CollectionFacetBuilder(reader: reader).overview(collection: collection)
        let extensions = try XCTUnwrap(overview.facets.first { $0.field == "file_ext" })
        XCTAssertEqual(extensions.values.map(\.text), ["md", "pdf"])
        XCTAssertEqual(extensions.values.map(\.count), [2, 1])
        XCTAssertEqual(extensions.missing, 1, "документ без поля тоже надо посчитать")
        XCTAssertEqual(extensions.title, "Расширение")
    }

    /// Клик по значению фасета ведёт в список с готовым фильтром, поэтому
    /// значение обязано быть пригодным для фильтра.
    func testAFacetValueCarriesTheFilterItLeadsTo() async throws {
        let reader = Reader()
        reader.records = [record("1", text: "текст", metadata: ["file_ext": .string("md")])]

        let overview = try await CollectionFacetBuilder(reader: reader).overview(collection: collection)
        let value = try XCTUnwrap(overview.facets.first { $0.field == "file_ext" }?.values.first)
        XCTAssertEqual(value.filterValue, .string("md"))
    }

    /// Даты показываются помесячно: тысяча отметок времени — это тысяча
    /// столбиков и ноль смысла.
    func testDatesAreGroupedByMonth() async throws {
        let reader = Reader()
        reader.records = [
            record("1", text: "т", metadata: ["file_mtime": .string("2026-08-01T10:00:00Z")]),
            record("2", text: "т", metadata: ["file_mtime": .string("2026-08-28T23:59:00Z")]),
            record("3", text: "т", metadata: ["file_mtime": .string("2026-07-15T10:00:00Z")]),
        ]

        let overview = try await CollectionFacetBuilder(reader: reader).overview(collection: collection)
        let dates = try XCTUnwrap(overview.facets.first { $0.field == "file_mtime" })
        XCTAssertEqual(dates.values.map(\.text), ["2026-08", "2026-07"])
        XCTAssertEqual(dates.values.map(\.count), [2, 1])
        // Фильтра по месяцу быть не может: в базе лежит полная отметка времени,
        // и равенство по «2026-08» не найдёт ничего.
        XCTAssertNil(dates.values.first?.filterValue)
    }

    /// Гистограмма длин — быстрый способ увидеть, что чанкинг настроен неудачно.
    func testTheLengthHistogramShowsTheShapeOfTheChunking() async throws {
        let reader = Reader()
        reader.records = [
            record("1", text: String(repeating: "а", count: 5), metadata: [:]),
            record("2", text: String(repeating: "а", count: 150), metadata: [:]),
            record("3", text: String(repeating: "а", count: 1500), metadata: [:]),
            record("4", text: String(repeating: "а", count: 9000), metadata: [:]),
        ]

        let overview = try await CollectionFacetBuilder(reader: reader).overview(collection: collection)
        let histogram = try XCTUnwrap(overview.lengths)
        XCTAssertEqual(histogram.shortest, 5)
        XCTAssertEqual(histogram.longest, 9000)
        XCTAssertEqual(histogram.buckets.reduce(0) { $0 + $1.count }, 4, "каждый документ попал ровно в одну корзину")
        XCTAssertEqual(histogram.buckets.last?.count, 1, "самый длинный — в открытой корзине справа")
        XCTAssertEqual(histogram.buckets.first?.count, 1)
    }

    /// Считается по выборке — и об этом сказано в заголовке, а не мелким
    /// шрифтом в документации.
    func testTheSampleIsAdmittedInTheCaption() async throws {
        let reader = Reader()
        reader.records = (0..<100).map { record("\($0)", text: "текст", metadata: ["file_ext": .string("md")]) }

        let overview = try await CollectionFacetBuilder(reader: reader).overview(collection: collection, sampleSize: 30)
        XCTAssertEqual(overview.examined, 30)
        XCTAssertEqual(overview.total, 100)
        XCTAssertTrue(overview.isSample)
        XCTAssertTrue(overview.caption.contains("Оценка по выборке"), overview.caption)
        XCTAssertTrue(overview.caption.contains("30"), overview.caption)
    }

    func testAWholeSmallCollectionSaysSoInstead() async throws {
        let reader = Reader()
        reader.records = [record("1", text: "текст", metadata: ["file_ext": .string("md")])]

        let overview = try await CollectionFacetBuilder(reader: reader).overview(collection: collection)
        XCTAssertFalse(overview.isSample)
        XCTAssertTrue(overview.caption.contains("По всей коллекции"), overview.caption)
    }

    func testFieldsFromTheSchemaCanBeAddedToTheOverview() async throws {
        let reader = Reader()
        reader.records = [
            record("1", text: "т", metadata: ["отдел": .string("склад")]),
            record("2", text: "т", metadata: ["отдел": .string("склад")]),
        ]

        let overview = try await CollectionFacetBuilder(reader: reader)
            .overview(collection: collection, extraFields: ["отдел"])
        let facet = try XCTUnwrap(overview.facets.first { $0.field == "отдел" })
        XCTAssertEqual(facet.values.first?.count, 2)
    }
}
