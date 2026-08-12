import XCTest
@testable import ChromaCore

/// every document the app writes says where it came from, and nothing is
/// back-filled into documents it did not write.
final class DocumentOriginTests: XCTestCase {
    func testStampingRecordsTheOrigin() {
        var metadata: ChromaMetadata = ["topic": .string("тема")]
        metadata.stamp(origin: .manual)
        XCTAssertEqual(metadata[DocumentOrigin.metadataKey], .string("manual"))
        XCTAssertEqual(DocumentOrigin.of(metadata), .manual)
        XCTAssertEqual(metadata["topic"], .string("тема"), "остальные поля не трогаются")
    }

    func testTheImportValueIsSpelledImport() {
        // The Swift case is `imported` only because `import` is a keyword; what
        // lands in the database is the word from the spec.
        XCTAssertEqual(DocumentOrigin.imported.rawValue, "import")
        XCTAssertEqual(DocumentOrigin.of(["origin": .string("import")]), .imported)
    }

    func testARewriteKeepsTheOriginItFound() {
        var metadata: ChromaMetadata = ["origin": .string("source"), "source_file": .string("a.md")]
        metadata.carryOrigin(from: ["origin": .string("source")])
        XCTAssertEqual(DocumentOrigin.of(metadata), .source)
    }

    /// The one moment `external` may be written: we are rewriting the document
    /// anyway, so recording what we found costs nothing extra.
    func testWritingADocumentWeDidNotCreateRecordsItAsExternal() {
        var metadata: ChromaMetadata = ["title": .string("чужой документ")]
        metadata.carryOrigin(from: ["title": .string("чужой документ")])
        XCTAssertEqual(DocumentOrigin.of(metadata), .external)
    }

    func testAnUnknownValueCountsAsExternalRatherThanBeingKept() {
        var metadata: ChromaMetadata = [:]
        metadata.carryOrigin(from: ["origin": .string("откуда-то")])
        XCTAssertEqual(DocumentOrigin.of(metadata), .external)
    }

    func testAbsenceIsNotReportedAsAnOrigin() {
        // Reading is deliberately not the same as writing: a document without
        // the field is not *claimed* to be external until we write to it.
        XCTAssertNil(DocumentOrigin.of(nil))
        XCTAssertNil(DocumentOrigin.of(["topic": .string("тема")]))
    }

    // MARK: - Import

    func testAnImportedRowIsStamped() throws {
        let table = try ImportService.parseDelimited("text,topic\nпервый,один\nвторой,два\n")
        let (documents, _) = try ImportService.prepare(
            table,
            mapping: ImportMapping(documentColumn: "text", metadataColumns: ["topic"])
        )
        XCTAssertEqual(documents.count, 2)
        XCTAssertEqual(documents.map { DocumentOrigin.of($0.metadata) }, [.imported, .imported])
    }

    /// A column of that name in the file does not get to state provenance.
    func testAColumnCalledOriginDoesNotWin() throws {
        let table = try ImportService.parseDelimited("text,origin\nпервый,из головы\n")
        let (documents, _) = try ImportService.prepare(
            table,
            mapping: ImportMapping(documentColumn: "text", metadataColumns: ["origin"])
        )
        XCTAssertEqual(DocumentOrigin.of(documents.first?.metadata), .imported)
    }

    // MARK: - Schemas

    func testTheFieldIsTechnicalSoAStrictSchemaToleratesIt() {
        let schema = MetadataSchema(
            collectionName: "заметки",
            fields: [MetadataField(key: "topic", type: .string, isRequired: true)],
            allowsExtraFields: false
        )
        var metadata: ChromaMetadata = ["topic": .string("тема")]
        metadata.stamp(origin: .manual)
        let result = MetadataSchemaValidator().validate(metadata, against: schema, documentID: "d1")
        XCTAssertTrue(result.isValid, result.violations.map(\.message).joined(separator: "; "))
    }

    func testAUserCannotDeclareAFieldCalledOrigin() {
        let schema = MetadataSchema(
            collectionName: "заметки",
            fields: [MetadataField(key: "origin", type: .string)],
            allowsExtraFields: true
        )
        let problems = MetadataSchemaValidator().validateSchema(schema)
        XCTAssertTrue(problems.contains { $0.field == "origin" }, "поле должно быть отклонено как автополе")
    }

    func testInferringASchemaIgnoresIt() {
        var metadata: ChromaMetadata = ["topic": .string("тема")]
        metadata.stamp(origin: .source)
        let schema = MetadataSchema.inferred(
            collectionName: "заметки",
            from: [DocumentRecord(id: "d1", document: "текст", metadata: metadata)]
        )
        XCTAssertEqual(schema.fields.map(\.key), ["topic"])
    }

    // MARK: - Sync

    func testSyncCountsItAmongTheAutoFields() {
        XCTAssertTrue(SourceSyncService.autoMetadataKeys.contains(DocumentOrigin.metadataKey))
    }
}
