import XCTest
@testable import ChromaCore

/// Addendum A1: the metric is chosen by the app, never left to the server, and
/// a distance is never shown without saying what produced it.
final class CollectionConfigurationTests: XCTestCase {
    private func hnsw(_ configuration: CollectionConfiguration) -> [String: Any] {
        configuration.requestBody()["hnsw"] as? [String: Any] ?? [:]
    }

    func testTheMetricIsAlwaysInTheRequest() {
        let body = hnsw(CollectionConfiguration())
        XCTAssertEqual(body["space"] as? String, "cosine", "по умолчанию — cosine, а не серверный l2")

        for metric in DistanceMetric.allCases {
            let body = hnsw(CollectionConfiguration(metric: metric))
            XCTAssertEqual(body["space"] as? String, metric.rawValue)
        }
    }

    /// an empty field means «server decides», not «send our idea of the
    /// default». The server rejects unknown keys outright, so the set of keys
    /// matters as much as the values.
    func testUntouchedIndexParametersAreNotSentAtAll() {
        let body = hnsw(CollectionConfiguration())
        XCTAssertEqual(Array(body.keys), ["space"])

        let tuned = hnsw(CollectionConfiguration(
            metric: .l2,
            hnsw: HNSWParameters(efConstruction: 200, efSearch: 50, maxNeighbors: 32)
        ))
        XCTAssertEqual(tuned["ef_construction"] as? Int, 200)
        XCTAssertEqual(tuned["ef_search"] as? Int, 50)
        XCTAssertEqual(tuned["max_neighbors"] as? Int, 32)
        XCTAssertEqual(tuned["space"] as? String, "l2")
    }

    func testPartiallyFilledParametersSendOnlyWhatWasFilled() {
        let body = hnsw(CollectionConfiguration(hnsw: HNSWParameters(efSearch: 77)))
        XCTAssertEqual(Set(body.keys), ["space", "ef_search"])
        XCTAssertEqual(body["ef_search"] as? Int, 77)
    }

    /// The names are the ones the server listed in its own 422; anything else
    /// fails the whole create request, so this is worth pinning down.
    func testKeyNamesAreTheOnesTheServerAccepts() {
        let body = hnsw(CollectionConfiguration(
            hnsw: HNSWParameters(efConstruction: 1, efSearch: 2, maxNeighbors: 3)
        ))
        XCTAssertTrue(body.keys.allSatisfy {
            ["space", "ef_construction", "ef_search", "max_neighbors"].contains($0)
        }, "\(body.keys)")
        XCTAssertNil(body["M"], "имени M у этой версии нет")
        XCTAssertNil(body["construction_ef"])
        XCTAssertNil(body["search_ef"])
    }

    func testTheLegacySpellingGoesOutToo() {
        let metadata = CollectionConfiguration(metric: .ip).legacyMetadata
        XCTAssertEqual(metadata["hnsw:space"], .string("ip"))
    }
}

final class DistanceMetricReadingTests: XCTestCase {
    private func collection(_ json: String) throws -> ChromaCollection {
        try JSONDecoder().decode(ChromaCollection.self, from: Data(json.utf8))
    }

    /// Shape taken from a live 1.4.4 response.
    func testMetricAndParametersAreReadFromTheServersConfiguration() throws {
        let parsed = try collection("""
        {"id":"1","name":"c","configuration_json":{"hnsw":{"space":"cosine","ef_construction":100,
        "ef_search":100,"max_neighbors":16,"resize_factor":1.2,"sync_threshold":1000},
        "spann":null,"embedding_function":null}}
        """)
        XCTAssertEqual(parsed.space, .cosine)
        XCTAssertEqual(parsed.hnsw?.efConstruction, 100)
        XCTAssertEqual(parsed.hnsw?.efSearch, 100)
        XCTAssertEqual(parsed.hnsw?.maxNeighbors, 16)
    }

    func testTheServersDefaultIsReadAsL2AndNotGuessedAsCosine() throws {
        let parsed = try collection("""
        {"id":"1","name":"c","configuration_json":{"hnsw":{"space":"l2"}}}
        """)
        XCTAssertEqual(parsed.space, .l2, "серверный дефолт показывается как есть")
    }

    /// a collection whose metric cannot be determined stays «unknown».
    /// Substituting cosine would make the interface show percentages computed
    /// from a scale that may not be cosine at all.
    func testACollectionWithoutAMetricStaysUnknown() throws {
        let parsed = try collection(#"{"id":"1","name":"c"}"#)
        XCTAssertNil(parsed.space)

        let unknownValue = try collection("""
        {"id":"1","name":"c","configuration_json":{"hnsw":{"space":"something_new"}}}
        """)
        XCTAssertNil(unknownValue.space, "незнакомое значение — это «неизвестно», а не подстановка")
    }

    /// A collection made by an older tool carries the metric in its metadata.
    func testTheMetadataSpellingIsUnderstoodWhenTheServerSaysNothing() throws {
        let parsed = try collection("""
        {"id":"1","name":"c","metadata":{"hnsw:space":"ip"}}
        """)
        XCTAssertEqual(parsed.space, .ip)
    }

    func testTheServerWinsOverTheMetadataKey() throws {
        let parsed = try collection("""
        {"id":"1","name":"c","metadata":{"_cdbm_space":"l2"},
        "configuration_json":{"hnsw":{"space":"cosine"}}}
        """)
        XCTAssertEqual(parsed.space, .cosine, "истина — то, что говорит сервер, а не то, что мы записали")
    }
}

final class DistanceInterpretationTests: XCTestCase {
    func testCosineTurnsIntoSimilarityIncludingTheEnds() {
        XCTAssertEqual(DistanceMetric.cosine.similarity(forDistance: 0), 1)
        XCTAssertEqual(DistanceMetric.cosine.similarity(forDistance: 1), 0)
        XCTAssertEqual(DistanceMetric.cosine.similarity(forDistance: 2), 0, "дальше нуля схожесть не уходит")
        XCTAssertEqual(try XCTUnwrap(DistanceMetric.cosine.similarity(forDistance: 0.25)), 0.75, accuracy: 0.0001)
    }

    /// The other two have no bounded scale, so there is no honest percentage.
    func testUnboundedMetricsGetNoPercentage() {
        XCTAssertNil(DistanceMetric.l2.similarity(forDistance: 0.5))
        XCTAssertNil(DistanceMetric.ip.similarity(forDistance: -3))
    }

    func testTheTextAlwaysSaysWhichScaleItIs() {
        XCTAssertTrue(DistanceMetric.cosine.describe(distance: 0.2).contains("80%"))
        XCTAssertTrue(DistanceMetric.l2.describe(distance: 12.5).contains("евклидово"))
        XCTAssertTrue(DistanceMetric.ip.describe(distance: -0.4).contains("произведение"))
    }

    func testAHitWithoutAKnownMetricIsShownRaw() {
        let hit = QueryHit(id: "a", document: nil, metadata: nil, distance: 0.2)
        XCTAssertEqual(hit.distanceText(metric: nil), "0.2000")
        XCTAssertTrue(hit.distanceText(metric: .cosine).contains("80%"))
        XCTAssertEqual(QueryHit(id: "a", document: nil, metadata: nil, distance: nil).distanceText(metric: .cosine), "—")
    }
}
