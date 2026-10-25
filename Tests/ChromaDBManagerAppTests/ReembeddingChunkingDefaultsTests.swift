import XCTest
@testable import ChromaDBManagerApp
@testable import ChromaCore

/// окно пересчёта начинает с нарезки источника коллекции.
@MainActor
final class ReembeddingChunkingDefaultsTests: XCTestCase {
    func testTheCloneStartsFromTheSourcesChunking() {
        var chunking = ChunkingConfiguration()
        chunking.strategy = .adaptive
        chunking.baseChunkSize = 1024
        chunking.minChunkSize = 256
        chunking.maxChunkSize = 2048
        var configuration = AppConfiguration()
        configuration.dataSources = [DataSource(name: "база", path: "/tmp", collectionName: "base2_docs_4b", chunking: chunking)]

        let byName = ChromaCollection(id: "1", name: "base2_docs_4b", metadata: nil, dimension: nil, tenant: nil, database: nil)
        XCTAssertEqual(ReembeddingViewModel.sourceChunking(for: byName, in: configuration)?.maxChunkSize, 2048)

        let byMetadata = ChromaCollection(id: "2", name: "другая", metadata: ["_cdbm_source_name": .string("база")], dimension: nil, tenant: nil, database: nil)
        XCTAssertEqual(ReembeddingViewModel.sourceChunking(for: byMetadata, in: configuration)?.strategy, .adaptive)

        let foreign = ChromaCollection(id: "3", name: "чужая", metadata: nil, dimension: nil, tenant: nil, database: nil)
        XCTAssertNil(ReembeddingViewModel.sourceChunking(for: foreign, in: configuration))
    }
}
