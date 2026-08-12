import XCTest
@testable import ChromaCore

/// the price is shown before the run, not discovered during it.
final class TableRunEstimateTests: XCTestCase {
    private let model = "text-embedding-test"

    private func plan(added: Int, reembedded: Int = 0, metadataOnly: Int = 0, from firstRow: Int = 2) -> SheetSyncPlan {
        var result = SheetSyncPlan()
        var row = firstRow
        func document(_ text: String) -> TableRowDocument {
            defer { row += 1 }
            return TableRowDocument(
                id: "id-\(row)", text: text,
                metadata: ["row_number": .int(row)], rowKey: "k-\(row)"
            )
        }
        result.added = (0..<added).map { _ in document("новая строка") }
        result.reembedded = (0..<reembedded).map { _ in (document("изменённая строка"), "old") }
        result.metadataOnly = (0..<metadataOnly).map { _ in (document("та же строка"), "old") }
        return result
    }

    private func metrics(secondsPerText: Double) -> MetricsSnapshot {
        var snapshot = MetricsSnapshot()
        snapshot.models = [.init(model: model, texts: 100, seconds: secondsPerText * 100)]
        return snapshot
    }

    // MARK: - What it costs

    func testTheEstimateCountsOnlyWhatGoesToTheModel() {
        let estimate = plan(added: 10, reembedded: 5, metadataOnly: 7)
            .estimate(embeddingModel: model, metrics: metrics(secondsPerText: 0.1))

        XCTAssertEqual(estimate.embeddings, 15)
        XCTAssertEqual(estimate.metadataWrites, 7)
        XCTAssertEqual(estimate.seconds ?? 0, 1.5, accuracy: 0.001)
    }

    /// Real work beats the benchmark: the benchmark's corpus is representative,
    /// the user's own texts are the truth.
    func testMeasuredWorkIsPreferredToTheBenchmark() {
        let benchmark = ModelBenchmark(
            model: model, measuredAt: Date(), dimension: 1024,
            firstCallSeconds: 1, batches: [.init(batchSize: 1, texts: 10, seconds: 10)]
        )
        let estimate = plan(added: 100)
            .estimate(embeddingModel: model, metrics: metrics(secondsPerText: 0.2), benchmarks: [benchmark])

        XCTAssertEqual(estimate.basis, .measuredWork)
        XCTAssertEqual(estimate.seconds ?? 0, 20, accuracy: 0.001)
    }

    /// The benchmark exists to make an estimate possible **before** the first
    /// run — the gap F3 was built to close.
    func testTheBenchmarkAnswersBeforeAnyRealWork() {
        let benchmark = ModelBenchmark(
            model: model, measuredAt: Date(), dimension: 1024,
            firstCallSeconds: 1, batches: [.init(batchSize: 1, texts: 10, seconds: 5)]
        )
        let estimate = plan(added: 100)
            .estimate(embeddingModel: model, metrics: MetricsSnapshot(), benchmarks: [benchmark])

        XCTAssertEqual(estimate.basis, .benchmark)
        XCTAssertNotNil(estimate.seconds)
    }

    /// Nothing measured means «неизвестно», never a made-up number: an invented
    /// estimate is worse than none, because it gets believed.
    func testWithoutMeasurementsThereIsNoNumber() {
        let estimate = plan(added: 100).estimate(embeddingModel: model, metrics: MetricsSnapshot())
        XCTAssertNil(estimate.seconds)
        XCTAssertNil(estimate.durationText)
        XCTAssertEqual(estimate.basis, .unknown)
        XCTAssertTrue(estimate.line.contains("не измерял"), estimate.line)
    }

    // MARK: - When the warning is compulsory

    /// Definition of Done, этап 5: above five thousand rows the estimate and the
    /// offer of a sample run are shown before anything starts.
    func testAboveFiveThousandRowsConfirmationIsRequired() {
        XCTAssertFalse(plan(added: 5_000).estimate(embeddingModel: model, metrics: MetricsSnapshot()).needsConfirmation)
        XCTAssertTrue(plan(added: 5_001).estimate(embeddingModel: model, metrics: MetricsSnapshot()).needsConfirmation)
    }

    /// Rows that only need their metadata rewritten do not occupy the model, so
    /// they must not trigger a warning about occupying it.
    func testMetadataOnlyRowsDoNotTriggerTheWarning() {
        let estimate = plan(added: 10, metadataOnly: 20_000)
            .estimate(embeddingModel: model, metrics: MetricsSnapshot())
        XCTAssertFalse(estimate.needsConfirmation)
    }

    func testTheDurationReadsInUnitsAPersonUses() {
        func text(_ seconds: Double) -> String? {
            TableRunEstimate(embeddings: 1, metadataWrites: 0, seconds: seconds, basis: .benchmark).durationText
        }
        XCTAssertEqual(text(45), "около 45 с")
        XCTAssertEqual(text(600), "около 10 мин")
        XCTAssertTrue(text(9_000)?.contains("ч") == true, text(9_000) ?? "")
    }

    // MARK: - The sample run

    /// «Первые N строк» has to mean the first of the **sheet**: the user is
    /// judging whether the template produces sensible documents, and can only do
    /// that against rows they can find in the file.
    func testASampleTakesTheFirstRowsOfTheSheet() {
        let full = plan(added: 100)
        let sample = full.limitedToFirstRows(10)

        XCTAssertEqual(sample.added.count, 10)
        let numbers = sample.added.compactMap { document -> Int? in
            if case .int(let value)? = document.metadata["row_number"] { return value }
            return nil
        }
        XCTAssertEqual(numbers, Array(2...11))
    }

    /// A sample spanning all three kinds of work still takes the first rows,
    /// not the first of each list.
    func testASampleCutsAcrossEveryKindOfWork() {
        var full = SheetSyncPlan()
        func document(_ row: Int) -> TableRowDocument {
            TableRowDocument(id: "id-\(row)", text: "строка \(row)", metadata: ["row_number": .int(row)], rowKey: nil)
        }
        full.added = [document(10), document(2)]
        full.reembedded = [(document(5), "old-5")]
        full.metadataOnly = [(document(3), "old-3")]

        let sample = full.limitedToFirstRows(3)
        XCTAssertEqual(sample.added.map(\.id), ["id-2"])
        XCTAssertEqual(sample.metadataOnly.map(\.document.id), ["id-3"])
        XCTAssertEqual(sample.reembedded.map(\.document.id), ["id-5"])
        XCTAssertEqual(sample.writes, 3)
    }

    /// A partial read of the file must not produce a decision about deleting
    /// documents: the rest of the rows were simply not looked at.
    func testASampleCarriesNoDeletionDecisions() {
        var full = plan(added: 10)
        full.disappeared = [TableRowRecord(
            documentID: "gone", rowNumber: 50, rowKey: "A-50",
            textHash: "x", metadataHash: "y"
        )]
        XCTAssertTrue(full.limitedToFirstRows(5).disappeared.isEmpty)
    }

    func testASampleOfNothingIsNothing() {
        XCTAssertEqual(plan(added: 10).limitedToFirstRows(0).writes, 0)
    }

    /// A sample larger than the sheet is simply the whole sheet.
    func testASampleLargerThanTheSheetIsTheWholeSheet() {
        XCTAssertEqual(plan(added: 4).limitedToFirstRows(100).writes, 4)
    }
}
