import XCTest
@testable import ChromaCore

/// Ручные пометки на документах: хранение в метаданных, влияние на
/// порядок выдачи и сохранность при пересинхронизации.
final class DocumentMarksTests: XCTestCase {

    // MARK: - Хранение

    func testMarksRoundTripThroughMetadata() {
        let marks = DocumentMarks(
            mark: .pinned, tags: ["важное", "договор"], note: "проверено юристом"
        )
        let metadata = marks.applied(to: ["source_file": .string("a.docx")])

        XCTAssertEqual(metadata[DocumentMarks.markKey], .string("pinned"))
        XCTAssertEqual(metadata[DocumentMarks.tagsKey], .string("важное, договор"))
        XCTAssertEqual(metadata["source_file"], .string("a.docx"), "чужие поля не тронуты")

        let read = DocumentMarks(metadata: metadata)
        XCTAssertEqual(read.mark, .pinned)
        XCTAssertEqual(read.tags, ["важное", "договор"])
        XCTAssertEqual(read.note, "проверено юристом")
    }

    /// Снятая пометка **исчезает** из документа, а не остаётся пустой строкой:
    /// иначе фильтр «есть пометка» находил бы снятые.
    func testClearedMarksAreRemovedRatherThanEmptied() {
        let before = DocumentMarks(mark: .stale, tags: ["x"], note: "n")
            .applied(to: [:])
        let after = DocumentMarks().applied(to: before)

        XCTAssertNil(after[DocumentMarks.markKey])
        XCTAssertNil(after[DocumentMarks.tagsKey])
        XCTAssertNil(after[DocumentMarks.noteKey])
    }

    func testTagsAreTrimmedAndDeduplicated() {
        let tags = DocumentMarks.parse(tags: " важное ,, договор,  ВАЖНОЕ ")
        XCTAssertEqual(tags, ["важное", "договор"], "повторы и пустые отбрасываются")
    }

    // MARK: - Влияние на порядок

    private func hit(_ id: String, mark: DocumentMark?, position: Int) -> RetrievalHit {
        var metadata: ChromaMetadata = ["source_file": .string("\(id).md")]
        if let mark { metadata = DocumentMarks(mark: mark).applied(to: metadata) }
        return RetrievalHit(
            QueryHit(id: id, document: id, metadata: metadata, distance: Double(position) / 10),
            position: position
        )
    }

    func testPinnedRiseDemotedAndStaleSinkKeepingOrderInside() {
        let hits = [
            hit("a", mark: nil, position: 1),
            hit("b", mark: .demoted, position: 2),
            hit("c", mark: .pinned, position: 3),
            hit("d", mark: .stale, position: 4),
            hit("e", mark: nil, position: 5),
            hit("f", mark: .pinned, position: 6),
        ]

        let result = RetrievalPipeline.applyingMarks(hits)

        XCTAssertEqual(result.hits.map(\.id), ["c", "f", "a", "e", "b", "d"])
        XCTAssertTrue(result.note.contains("закреплённых 2"), result.note)
        XCTAssertTrue(result.note.contains("устаревших 1"), result.note)
    }

    /// Без единой пометки стадия обязана оставить список ровно как был:
    /// «включено, но нечего двигать» не должно менять выдачу ни на строку.
    func testUnmarkedListIsLeftExactlyAsItWas() {
        let hits = (1...5).map { hit("d\($0)", mark: nil, position: $0) }
        let result = RetrievalPipeline.applyingMarks(hits)
        XCTAssertEqual(result.hits.map(\.id), hits.map(\.id))
        XCTAssertTrue(result.note.contains("помеченных документов в выдаче нет"), result.note)
    }

    /// Выключенный умный поиск обязан давать ровно то же, что поиск этапа 2
    /// — значит и пометки в нём не двигают список.
    func testPlainProfileDoesNotAskForMarks() {
        let plain = SearchProfile.plain(collectionName: "docs", name: "без умного поиска")
        XCTAssertFalse(plain.marksEnabled)
        XCTAssertFalse(plain.requestedStages.contains(.marks))
    }

    /// Стадия стоит **до** обрезки: закреплённое человеком обязано попасть
    /// в выдачу, а не быть срезанным вместе с хвостом.
    func testMarksRunBeforeTruncation() {
        XCTAssertLessThan(RetrievalStage.marks.order, RetrievalStage.truncate.order)
        XCTAssertGreaterThan(RetrievalStage.marks.order, RetrievalStage.rerank.order)
    }

    /// Профиль, записанный до появления пометок, читается и ведёт себя как
    /// новый: настройка, о которой файл не знает, не должна выключать функцию.
    func testProfileWrittenBeforeMarksStillEnablesThem() throws {
        let json = #"{"collectionName":"docs","name":"старый"}"#
        let profile = try JSONDecoder().decode(SearchProfile.self, from: Data(json.utf8))
        XCTAssertTrue(profile.marksEnabled)
    }

    // MARK: - Сохранность при пересинхронизации

    func testResyncCarriesMarksOverToTheRewrittenChunk() async throws {
        let database = MarkedDatabase()
        database.stored = [
            "a.md#0": DocumentMarks(mark: .pinned, tags: ["важное"], note: "не терять")
                .applied(to: ["source_file": .string("a.md")]),
        ]
        let fresh = [
            EmbeddedRecord(
                id: "a.md#0", document: "новый текст", embedding: [0.1],
                metadata: ["source_file": .string("a.md"), "content_hash": .string("новый")]
            ),
            EmbeddedRecord(
                id: "a.md#1", document: "второй чанк", embedding: [0.2],
                metadata: ["source_file": .string("a.md")]
            ),
        ]

        let kept = try await SourceSyncService.keepingMarks(
            of: fresh, in: "id", chroma: database
        )

        let first = DocumentMarks(metadata: kept[0].metadata)
        XCTAssertEqual(first.mark, .pinned)
        XCTAssertEqual(first.tags, ["важное"])
        XCTAssertEqual(first.note, "не терять")
        XCTAssertEqual(
            kept[0].metadata["content_hash"], .string("новый"),
            "новые метаданные остаются новыми — переносится только разметка"
        )
        XCTAssertTrue(DocumentMarks(metadata: kept[1].metadata).isEmpty)
    }

    /// Коллекция без пометок не должна платить за них ничем, кроме одного
    /// чтения: переписывать записи незачем.
    func testNothingIsRewrittenWhenNoMarksExist() async throws {
        let database = MarkedDatabase()
        database.stored = ["a.md#0": ["source_file": .string("a.md")]]
        let fresh = [EmbeddedRecord(
            id: "a.md#0", document: "текст", embedding: [0.1], metadata: [:]
        )]

        let kept = try await SourceSyncService.keepingMarks(of: fresh, in: "id", chroma: database)
        XCTAssertTrue(kept[0].metadata.isEmpty)
        XCTAssertEqual(database.reads, 1)
    }
}

/// База, которая помнит метаданные и считает чтения.
private final class MarkedDatabase: SyncDatabase, @unchecked Sendable {
    var stored: [String: ChromaMetadata] = [:]
    private(set) var reads = 0

    func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord] {
        reads += 1
        return ids.compactMap { id in
            guard let metadata = stored[id] else { return nil }
            return DocumentRecord(id: id, document: nil, metadata: metadata)
        }
    }

    func createCollection(
        name: String, metadata: ChromaMetadata?, configuration: CollectionConfiguration?,
        getOrCreate: Bool
    ) async throws -> ChromaCollection {
        ChromaCollection(id: "id", name: name, metadata: metadata)
    }
    func resolveID(of name: String) async throws -> String { "id" }
    func updateCollection(id: String, newName: String?, metadata: ChromaMetadata?) async throws {}
    func upsert(collectionID: String, records: [EmbeddedRecord]) async throws {}
    func updateDocuments(collectionID: String, updates: [DocumentUpdate]) async throws {}
    func embeddings(collectionID: String, ids: [String]) async throws -> [String: [Double]] { [:] }
    func deleteDocuments(collectionID: String, ids: [String]) async throws {}
    func deleteDocuments(collectionID: String, filter: DocumentFilter) async throws -> Int { 0 }
}

/// Снятие пометки должно доходить до базы.
final class MetadataRemovalTests: XCTestCase {
    /// То, чего не стало, уходит на удаление; то, что было и осталось, — нет.
    func testDisappearedKeysAreListedForRemoval() {
        let update = DocumentUpdate.replacingMetadata(
            id: "d1",
            metadata: ["keep": .string("да"), "new": .int(1)],
            previous: ["keep": .string("да"), "_cdbm_mark": .string("pinned"), "_cdbm_tags": .string("важное")]
        )
        XCTAssertEqual(update.removedMetadataKeys, ["_cdbm_mark", "_cdbm_tags"])
        XCTAssertEqual(update.metadata?["new"], .int(1))
    }

    /// Ничего не исчезло — удалять нечего, и лишнего `null` в запросе не будет.
    func testNothingToRemoveWhenNothingDisappeared() {
        let update = DocumentUpdate.replacingMetadata(
            id: "d1", metadata: ["a": .int(1), "b": .int(2)], previous: ["a": .int(1)]
        )
        XCTAssertTrue(update.removedMetadataKeys.isEmpty)
    }

    /// У документа без метаданных удалять тоже нечего.
    func testNoPreviousMetadataMeansNoRemovals() {
        let update = DocumentUpdate.replacingMetadata(
            id: "d1", metadata: ["a": .int(1)], previous: nil
        )
        XCTAssertTrue(update.removedMetadataKeys.isEmpty)
    }

    /// Сквозная проверка того самого случая из отчёта: повторное нажатие
    /// «Закрепить» снимает пометку, и ключ уходит на удаление.
    func testUnpinningAsksToRemoveTheKey() {
        let existing: ChromaMetadata = ["_cdbm_mark": .string("pinned"), "page_number": .int(3)]
        var marks = DocumentMarks(metadata: existing)
        XCTAssertEqual(marks.mark, .pinned)

        // Переключатель: та же пометка снимает её.
        marks.mark = marks.mark == .pinned ? nil : .pinned
        XCTAssertNil(marks.mark)

        let update = DocumentUpdate.replacingMetadata(
            id: "d1", metadata: marks.applied(to: existing), previous: existing
        )
        XCTAssertEqual(update.removedMetadataKeys, ["_cdbm_mark"])
        XCTAssertEqual(update.metadata?["page_number"], .int(3), "соседние поля не трогаем")
    }
}
