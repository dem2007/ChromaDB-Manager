import XCTest
@testable import ChromaCore

/// §D3 — инспектор здоровья коллекции.
///
/// Каждая проверка проверяется на коллекции с **внесённым** дефектом: тест,
/// который не видел дефекта, ничего не гарантирует.
final class CollectionInspectorTests: XCTestCase {
    /// База, которая только отвечает. Считает каждое обращение — этим
    /// закрывается пункт DoD «инспектор не изменяет данные ни при каком
    /// сценарии»: методов записи здесь нет вовсе, а вызовы эмбеддинга видны
    /// по счётчику.
    private final class Reader: InspectionReader, @unchecked Sendable {
        var records: [DocumentRecord] = []
        var vectors: [String: [Double]] = [:]
        private(set) var queries = 0
        private(set) var embeddingReads = 0

        func count(collectionID: String) async throws -> Int { records.count }

        func documents(collectionID: String, limit: Int, offset: Int) async throws -> [DocumentRecord] {
            guard offset < records.count else { return [] }
            return Array(records[offset..<min(offset + limit, records.count)])
        }

        func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord] {
            let wanted = Set(ids)
            return records.filter { wanted.contains($0.id) }
        }

        func embeddings(collectionID: String, ids: [String]) async throws -> [String: [Double]] {
            embeddingReads += 1
            return ids.reduce(into: [:]) { result, id in result[id] = vectors[id] }
        }

        func query(collectionID: String, embedding: [Double], nResults: Int) async throws -> [QueryHit] {
            queries += 1
            // Настоящая близость: расстояние — единица минус косинус.
            return vectors
                .map { id, vector in (id, Self.cosineDistance(embedding, vector)) }
                .sorted { $0.1 < $1.1 }
                .prefix(nResults)
                .map { id, distance in
                    QueryHit(id: id, document: nil, metadata: nil, distance: distance)
                }
        }

        static func cosineDistance(_ left: [Double], _ right: [Double]) -> Double {
            let dot = zip(left, right).reduce(0) { $0 + $1.0 * $1.1 }
            let leftNorm = sqrt(left.reduce(0) { $0 + $1 * $1 })
            let rightNorm = sqrt(right.reduce(0) { $0 + $1 * $1 })
            guard leftNorm > 0, rightNorm > 0 else { return 1 }
            return 1 - dot / (leftNorm * rightNorm)
        }
    }

    private let sourceID = "11111111-1111-1111-1111-111111111111"

    private func collection(metadata: ChromaMetadata? = nil) -> ChromaCollection {
        ChromaCollection(
            id: "id", name: "проба",
            metadata: metadata ?? [
                CollectionBindingKeys.model: .string("e5"),
                CollectionBindingKeys.dimension: .int(3),
                CollectionBindingKeys.space: .string("cosine"),
            ]
        )
    }

    private func record(
        _ id: String, text: String = "Достаточно длинный текст документа для проверки.",
        metadata: ChromaMetadata? = nil
    ) -> DocumentRecord {
        DocumentRecord(
            id: id, document: text,
            metadata: metadata ?? ["source_id": .string(sourceID), "source_file": .string("a.md"), "chunk_index": .int(0)]
        )
    }

    private func inspect(
        _ reader: Reader,
        context: CollectionInspector.Context? = nil,
        options: InspectionOptions = InspectionOptions()
    ) async throws -> InspectionReport {
        try await CollectionInspector(reader: reader).inspect(
            context: context ?? CollectionInspector.Context(
                collection: collection(), knownSourceIDs: [sourceID]
            ),
            options: options
        )
    }

    // MARK: - Дешёвые проверки

    func testShortDocumentsAreFound() async throws {
        let reader = Reader()
        reader.records = [record("a"), record("b", text: "ага")]

        let report = try await inspect(reader)
        XCTAssertEqual(report.count(of: .emptyDocuments), 1)
        XCTAssertEqual(report.findings(in: .emptyDocuments).first?.documentIDs, ["b"])
    }

    /// Служебные поля метаданными не считаются: документ, у которого есть
    /// только `origin`, по-прежнему нечем отфильтровать.
    func testDocumentsWithoutMeaningfulMetadataAreFound() async throws {
        let reader = Reader()
        reader.records = [
            record("a"),
            record("b", metadata: [:]),
            record("c", metadata: [DocumentOrigin.metadataKey: DocumentOrigin.manual.value]),
        ]

        let report = try await inspect(reader)
        XCTAssertEqual(Set(report.findings(in: .withoutMetadata).flatMap(\.documentIDs)), ["b", "c"])
    }

    func testSchemaViolationsAreReported() async throws {
        let reader = Reader()
        reader.records = [record("a", metadata: ["автор": .string("Иванов")]), record("b", metadata: ["автор": .int(7)])]
        let schema = MetadataSchema(
            collectionName: "проба",
            fields: [MetadataField(key: "автор", type: .string, isRequired: true)]
        )

        let report = try await inspect(reader, context: CollectionInspector.Context(
            collection: collection(), knownSourceIDs: [sourceID], schema: schema
        ))
        XCTAssertEqual(report.count(of: .schemaViolations), 1)
        XCTAssertEqual(report.findings(in: .schemaViolations).first?.documentIDs, ["b"])
    }

    /// Сирота — это документ, у которого источник **записан**, но такого
    /// источника в приложении нет.
    func testOrphanChunksAreDistinguishedFromHandWrittenDocuments() async throws {
        let reader = Reader()
        reader.records = [
            record("свой"),
            record("сирота", metadata: ["source_id": .string("22222222-2222-2222-2222-222222222222")]),
            record("вручную", metadata: ["автор": .string("Иванов")]),
        ]

        let report = try await inspect(reader)
        XCTAssertEqual(report.findings(in: .orphanChunks).flatMap(\.documentIDs), ["сирота"])
        XCTAssertEqual(report.findings(in: .outsideSources).flatMap(\.documentIDs), ["вручную"])
        // Ложное срабатывание на каждой ручной записи — то, ради чего эти две
        // категории вообще разделены.
        XCTAssertTrue(InspectionCategory.outsideSources.isInformational)
        XCTAssertEqual(report.problemCount, report.findings.count - 1, "информационная категория не считается бедой")
    }

    /// След прерванной синхронизации.
    func testGapsInChunkNumberingAreFound() async throws {
        let reader = Reader()
        reader.records = [
            record("a0", metadata: ["source_file": .string("книга.md"), "chunk_index": .int(0), "source_id": .string(sourceID)]),
            record("a1", metadata: ["source_file": .string("книга.md"), "chunk_index": .int(1), "source_id": .string(sourceID)]),
            record("a3", metadata: ["source_file": .string("книга.md"), "chunk_index": .int(3), "source_id": .string(sourceID)]),
        ]

        let report = try await inspect(reader)
        let gap = try XCTUnwrap(report.findings(in: .chunkGaps).first)
        XCTAssertEqual(gap.subject, "книга.md")
        XCTAssertTrue(gap.detail?.contains("2") ?? false, gap.detail ?? "")
    }

    func testMissingCollectionBindingIsReported() async throws {
        let reader = Reader()
        reader.records = [record("a")]

        let report = try await inspect(reader, context: CollectionInspector.Context(
            collection: collection(metadata: [:]), knownSourceIDs: [sourceID]
        ))
        let finding = try XCTUnwrap(report.findings(in: .collectionBindingMissing).first)
        for expected in ["модель", "размерность", "метрика"] {
            XCTAssertTrue(finding.detail?.contains(expected) ?? false, finding.detail ?? "")
        }
    }

    func testADimensionMismatchIsCaught() async throws {
        let reader = Reader()
        reader.records = [record("a"), record("b")]
        reader.vectors = ["a": [1, 0, 0], "b": [1, 0]]

        let report = try await inspect(reader)
        XCTAssertEqual(report.findings(in: .dimensionMismatch).flatMap(\.documentIDs), ["b"])
    }

    /// Дубли ищутся по тексту самого документа.
    ///
    /// И **не** по `content_hash`: он в этом приложении описывает файл целиком
    /// и одинаков у всех его чанков. На живой коллекции проверка по нему дала
    /// 241 ложную находку — по одной на каждый многочанковый файл.
    func testDuplicatesAreFoundByTheDocumentTextAndNotByTheFileHash() async throws {
        let reader = Reader()
        reader.records = [
            record("a", text: "Один и тот же текст в двух документах."),
            record("b", text: "Один и тот же текст в двух документах."),
            record("c", text: "Совсем другой текст, ни на что не похожий."),
            // Два разных куска одного файла: `content_hash` у них общий.
            record("кусок1", text: "Первый кусок статьи про корриду.", metadata: ["content_hash": .string("файл"), "chunk_index": .int(0)]),
            record("кусок2", text: "Второй кусок той же статьи, совсем про другое.", metadata: ["content_hash": .string("файл"), "chunk_index": .int(1)]),
        ]

        let report = try await inspect(reader)
        let groups = report.findings(in: .duplicates).map { Set($0.documentIDs) }
        XCTAssertEqual(groups, [["a", "b"]])
        XCTAssertFalse(
            groups.contains(["кусок1", "кусок2"]),
            "разные куски одного файла — не дубли, хоть у них и общий content_hash"
        )
    }

    /// Находка дублей называется тем, что повторилось. Список из одних
    /// идентификаторов не отвечал на вопрос «а что там внутри».
    func testADuplicateFindingSaysWhatTextRepeatedAndWhere() async throws {
        let reader = Reader()
        reader.records = [
            record("a", text: "  Раздел 1.\nОбщие положения настоящего регламента.  ",
                   metadata: ["source_file": .string("регламент.docx")]),
            record("b", text: "  Раздел 1.\nОбщие положения настоящего регламента.  ",
                   metadata: ["source_file": .string("регламент.pdf")]),
        ]

        let report = try await inspect(reader)
        let finding = try XCTUnwrap(report.findings(in: .duplicates).first)
        XCTAssertEqual(finding.subject, "Раздел 1. Общие положения настоящего регламента.")
        let detail = try XCTUnwrap(finding.detail)
        XCTAssertTrue(detail.contains("документов 2"), detail)
        XCTAssertTrue(detail.contains("регламент.docx"), detail)
        XCTAssertTrue(detail.contains("регламент.pdf"), detail)
        XCTAssertTrue(detail.contains("a"), detail)
    }

    // MARK: - Похожие документы

    /// Главное в этой проверке — цена. Векторы берутся из базы; ни одного
    /// вызова эмбеддинга не делается, иначе проверка стала бы дороже
    /// переиндексации.
    func testNearDuplicatesUseStoredVectorsAndNeverEmbedAnything() async throws {
        let reader = Reader()
        reader.records = (0..<4).map { record("d\($0)", text: "Текст номер \($0), достаточно длинный для проверки.") }
        reader.vectors = [
            "d0": [1, 0, 0],
            "d1": [0.999, 0.01, 0],  // почти то же самое
            "d2": [0, 1, 0],
            "d3": [0, 0, 1],
        ]

        let report = try await inspect(reader, options: InspectionOptions(checksNearDuplicates: true))
        XCTAssertTrue(report.nearDuplicatesChecked)
        let pairs = report.findings(in: .nearDuplicates).map(\.subject)
        XCTAssertEqual(pairs, [CollectionInspector.pairKey("d0", "d1")])
        // Пара «A и B» и пара «B и A» — одна находка, а не две.
        XCTAssertEqual(report.count(of: .nearDuplicates), 1)
        XCTAssertEqual(reader.queries, 4, "по одному запросу на документ выборки")
    }

    /// «Это не дубли» — и пара больше не всплывает.
    func testAnAcknowledgedPairDoesNotComeBack() async throws {
        let reader = Reader()
        reader.records = [record("d0"), record("d1")]
        reader.vectors = ["d0": [1, 0, 0], "d1": [0.999, 0.01, 0]]

        let report = try await inspect(
            reader,
            context: CollectionInspector.Context(
                collection: collection(), knownSourceIDs: [sourceID],
                acknowledgedPairs: [CollectionInspector.pairKey("d0", "d1")]
            ),
            options: InspectionOptions(checksNearDuplicates: true)
        )
        XCTAssertEqual(report.count(of: .nearDuplicates), 0)
        XCTAssertEqual(report.acknowledged, 1, "пропущенное считается и показывается")
    }

    /// Дорогая проверка не запускается сама.
    func testNearDuplicatesAreNotRunUnlessAsked() async throws {
        let reader = Reader()
        reader.records = [record("d0"), record("d1")]
        reader.vectors = ["d0": [1, 0, 0], "d1": [0.999, 0.01, 0]]

        let report = try await inspect(reader)
        XCTAssertFalse(report.nearDuplicatesChecked)
        XCTAssertEqual(reader.queries, 0)
    }

    // MARK: - Выборка и отчёт

    func testTheSampleSizeIsHonouredAndSaidOutLoud() async throws {
        let reader = Reader()
        reader.records = (0..<120).map { record("d\($0)") }

        let report = try await inspect(reader, options: InspectionOptions(sampleSize: 50))
        XCTAssertEqual(report.examined, 50)
        XCTAssertEqual(report.total, 120)
        XCTAssertTrue(report.isSample)
    }

    func testTheReportComparesItselfWithThePreviousRun() throws {
        let before = InspectionReport(
            collectionName: "проба",
            startedAt: Date(timeIntervalSince1970: 1000),
            findings: [
                InspectionFinding(category: .emptyDocuments, documentIDs: ["a"], subject: "a"),
                InspectionFinding(category: .emptyDocuments, documentIDs: ["b"], subject: "b"),
            ]
        )
        let now = InspectionReport(
            collectionName: "проба",
            findings: [InspectionFinding(category: .emptyDocuments, documentIDs: ["a"], subject: "a")]
        )

        let comparison = try XCTUnwrap(InspectionComparison.between(now, and: before))
        XCTAssertTrue(comparison.improved)
        XCTAssertFalse(comparison.worsened)
        XCTAssertTrue(comparison.changes.first?.line.contains("стало меньше") ?? false)
        // Первый прогон — это не «стало лучше»: сравнивать не с чем.
        XCTAssertNil(InspectionComparison.between(now, and: nil))
    }

    func testTheReportExportsToMarkdownAndJSON() throws {
        let report = InspectionReport(
            collectionName: "проба", examined: 100, total: 500,
            findings: [
                InspectionFinding(category: .emptyDocuments, documentIDs: ["a"], subject: "a", detail: "знаков: 3"),
                InspectionFinding(category: .outsideSources, documentIDs: ["b"], subject: "b"),
            ]
        )
        let markdown = InspectionExport.markdown(report)
        XCTAssertTrue(markdown.contains("# Инспекция коллекции «проба»"))
        XCTAssertTrue(markdown.contains("это выборка, а не вся коллекция"), markdown)
        XCTAssertTrue(markdown.contains("Что можно сделать"))

        let data = try InspectionExport.json(report)
        let decoded = try InspectionExport.decode(data)
        XCTAssertEqual(decoded.findings.count, 2)
    }
    // MARK: - Вытесненные куски перенарезки

    private func piece(_ id: String, parent: String, run: String) -> DocumentRecord {
        record(id, metadata: [
            "source_id": .string(sourceID),
            "source_file": .string("a.md"),
            CollectionBindingKeys.rechunkedFrom: .string(parent),
            CollectionBindingKeys.rechunkRun: .string(run),
        ])
    }

    /// Тот самый сюжет: первый прогон нарезал документ на три куска, второй —
    /// на два. Третий остался в коллекции с вектором прежней модели, и
    /// удалить его приложение не имеет права — но показать обязано.
    func testPiecesLeftOverFromAnEarlierRechunkAreReported() async throws {
        let reader = Reader()
        reader.records = [
            piece("d1", parent: "d1", run: "прогон-2"),      // первый кусок держит исходный id
            piece("d1#1", parent: "d1", run: "прогон-2"),
            piece("d1#2", parent: "d1", run: "прогон-1"),    // вытеснен
        ]

        let report = try await inspect(reader)
        XCTAssertEqual(report.count(of: .supersededPieces), 1)
        let finding = try XCTUnwrap(report.findings(in: .supersededPieces).first)
        XCTAssertEqual(finding.documentIDs, ["d1#2"])
        XCTAssertEqual(finding.subject, "d1")
    }

    /// Куски одного прогона — не находка: иначе инспектор ругался бы на
    /// каждую нормальную перенарезку.
    func testPiecesFromOneRunAreNotAFinding() async throws {
        let reader = Reader()
        reader.records = [
            piece("d1", parent: "d1", run: "прогон-1"),
            piece("d1#1", parent: "d1", run: "прогон-1"),
            piece("d1#2", parent: "d1", run: "прогон-1"),
        ]

        let report = try await inspect(reader)
        XCTAssertEqual(report.count(of: .supersededPieces), 0)
    }

    /// Родителя в выборке нет — судить не по чему. Инспектор смотрит выборку,
    /// и «не видели» здесь не то же самое, что «вытеснено».
    func testWithoutTheParentNothingIsGuessed() async throws {
        let reader = Reader()
        reader.records = [
            piece("d1#1", parent: "d1", run: "прогон-1"),
            piece("d1#2", parent: "d1", run: "прогон-2"),
        ]

        let report = try await inspect(reader)
        XCTAssertEqual(report.count(of: .supersededPieces), 0, "без родителя метка текущего прогона неизвестна")
    }

    /// Категория не информационная: это настоящий дефект выдачи — вытесненный
    /// кусок конкурирует с текущими, имея вектор другой модели.
    func testTheCategoryIsNotInformationalAndSuggestsAManualDecision() {
        XCTAssertFalse(InspectionCategory.supersededPieces.isInformational)
        XCTAssertTrue(
            InspectionCategory.supersededPieces.suggestion.contains("автоматических удалений"),
            "предложение должно объяснять, почему приложение не убирает их само"
        )
    }

}

/// 0 в виде сторожа по исходникам: «инспектор только читает и сообщает».
///
/// Протокол `InspectionReader` уже не даёт записать ничего — методов записи
/// в нём нет. Этот тест закрывает вторую половину: что инспектор не обошёл
/// протокол, дотянувшись до клиента напрямую, и что он никогда не считает
/// эмбеддинги (пункт DoD про выборку в 1000 документов).
final class InspectorIsReadOnlyTests: XCTestCase {
    private let forbidden = [
        ".upsert(", ".add(", ".updateDocuments(", ".deleteDocuments(",
        ".createCollection(", ".updateCollection(", ".deleteCollection(",
        ".embed(", "embeddings.embed",
    ]

    private var inspectionSources: [URL] {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/ChromaCore/Inspection")
            let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            return files.filter { $0.pathExtension == "swift" }
        }
    }

    func testTheInspectorNeverCallsAnythingThatWrites() throws {
        var offenders: [String] = []
        for file in try inspectionSources {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                // Комментарий — не вызов: строка с «///» рассказывает про запись,
                // а не выполняет её.
                let code = line.components(separatedBy: "//").first ?? line
                for call in forbidden where code.contains(call) {
                    offenders.append("\(file.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            """
            Инспектор обязан только читать и сообщать. Найдены вызовы, \
            которые пишут или считают эмбеддинги:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    /// Сторож бесполезен, если он читает пустоту.
    func testTheGuardActuallyReadsTheInspector() throws {
        let files = try inspectionSources
        XCTAssertGreaterThanOrEqual(files.count, 3)
        let text = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(text.contains("InspectionReader"))
        XCTAssertTrue(text.contains("func inspect("))
    }
}
