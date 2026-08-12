import XCTest
@testable import ChromaCore

final class MetadataFieldTypeTests: XCTestCase {
    func testParsingUserInput() {
        XCTAssertEqual(MetadataFieldType.string.parse(" привет "), .string("привет"))
        XCTAssertEqual(MetadataFieldType.integer.parse("42"), .int(42))
        XCTAssertEqual(MetadataFieldType.number.parse("3.14"), .double(3.14))
        XCTAssertEqual(MetadataFieldType.boolean.parse("да"), .bool(true))
        XCTAssertEqual(MetadataFieldType.boolean.parse("FALSE"), .bool(false))
    }

    /// "3" typed into a float field must be stored as a double, otherwise the
    /// column would hold ints in some rows and doubles in others.
    func testWholeNumberInAFloatFieldStaysADouble() {
        XCTAssertEqual(MetadataFieldType.number.parse("3"), .double(3))
    }

    func testRejectsValuesThatDoNotFit() {
        XCTAssertNil(MetadataFieldType.integer.parse("3.5"))
        XCTAssertNil(MetadataFieldType.integer.parse("сорок два"))
        XCTAssertNil(MetadataFieldType.boolean.parse("возможно"))
        XCTAssertNil(MetadataFieldType.date.parse("вчера"))
        XCTAssertNil(MetadataFieldType.string.parse("   "))
    }

    func testDateAcceptsTheThreeShapesThatTurnUpInData() {
        XCTAssertNotNil(MetadataFieldType.parseDate("2026-07-29"))
        XCTAssertNotNil(MetadataFieldType.parseDate("2026-07-29T10:15:00Z"))
        XCTAssertNotNil(MetadataFieldType.parseDate("2026-07-29T10:15:00.123Z"))
        XCTAssertNil(MetadataFieldType.parseDate("29.07.2026"))
    }

    func testDateIsNormalisedToISO8601OnParse() {
        guard case .string(let stored)? = MetadataFieldType.date.parse("2026-07-29") else {
            return XCTFail("expected a stored ISO string")
        }
        XCTAssertNotNil(MetadataFieldType.iso8601.date(from: stored))
    }

    func testAcceptsChecksStoredValues() {
        XCTAssertTrue(MetadataFieldType.integer.accepts(.int(1)))
        XCTAssertFalse(MetadataFieldType.integer.accepts(.double(1.5)))
        // An int is a valid float value; the reverse is not true.
        XCTAssertTrue(MetadataFieldType.number.accepts(.int(1)))
        XCTAssertTrue(MetadataFieldType.date.accepts(.string("2026-07-29T10:15:00Z")))
        XCTAssertFalse(MetadataFieldType.date.accepts(.string("не дата")))
        XCTAssertFalse(MetadataFieldType.string.accepts(.int(1)))
    }

    func testTypeInferenceFromExistingValues() {
        XCTAssertEqual(MetadataFieldType.inferred(from: .int(1)), .integer)
        XCTAssertEqual(MetadataFieldType.inferred(from: .double(1.5)), .number)
        XCTAssertEqual(MetadataFieldType.inferred(from: .bool(true)), .boolean)
        XCTAssertEqual(MetadataFieldType.inferred(from: .string("2026-07-29T10:15:00Z")), .date)
        XCTAssertEqual(MetadataFieldType.inferred(from: .string("просто текст")), .string)
    }
}

final class MetadataSchemaValidationTests: XCTestCase {
    private let validator = MetadataSchemaValidator()

    private func schema(_ fields: [MetadataField], allowsExtra: Bool = true) -> MetadataSchema {
        MetadataSchema(collectionName: "demo", fields: fields, allowsExtraFields: allowsExtra)
    }

    func testValidDocumentPasses() {
        let rules = schema([
            MetadataField(key: "source", type: .string, isRequired: true),
            MetadataField(key: "pages", type: .integer),
        ])
        let result = validator.validate(["source": .string("manual"), "pages": .int(12)], against: rules)
        XCTAssertTrue(result.isValid)
    }

    /// The Definition of Done for this stage: a missing required field blocks
    /// the save.
    func testMissingRequiredFieldIsReported() {
        let rules = schema([MetadataField(key: "source", type: .string, isRequired: true)])
        let result = validator.validate(["other": .string("x")], against: rules)

        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.violations.count, 1)
        XCTAssertEqual(result.violations.first?.kind, .missingRequired)
        XCTAssertEqual(result.violations.first?.field, "source")
        XCTAssertTrue(result.violations.first?.message.contains("source") == true)
    }

    func testWrongTypeIsReported() {
        let rules = schema([MetadataField(key: "pages", type: .integer)])
        let result = validator.validate(["pages": .string("двенадцать")], against: rules)

        XCTAssertEqual(result.violations.first?.kind, .wrongType)
        XCTAssertTrue(result.violations.first?.message.contains("целое") == true)
    }

    func testOptionalFieldMayBeAbsent() {
        let rules = schema([MetadataField(key: "note", type: .string, isRequired: false)])
        XCTAssertTrue(validator.validate([:], against: rules).isValid)
    }

    func testExtraFieldsAreAllowedUnlessForbidden() {
        let permissive = schema([MetadataField(key: "a", type: .string)])
        XCTAssertTrue(validator.validate(["a": .string("x"), "b": .int(1)], against: permissive).isValid)

        let strict = schema([MetadataField(key: "a", type: .string)], allowsExtra: false)
        let result = validator.validate(["a": .string("x"), "b": .int(1)], against: strict)
        XCTAssertEqual(result.violations.first?.kind, .unexpectedField)
        XCTAssertEqual(result.violations.first?.field, "b")
    }

    /// _cdbm_* fields belong to the app and must never be reported as stray.
    func testReservedFieldsAreIgnoredByAStrictSchema() {
        let strict = schema([MetadataField(key: "a", type: .string)], allowsExtra: false)
        let metadata: ChromaMetadata = ["a": .string("x"), "_cdbm_model": .string("m"), "_cdbm_dimension": .int(768)]
        XCTAssertTrue(validator.validate(metadata, against: strict).isValid)
    }

    func testDefaultsFillMissingValuesBeforeValidation() {
        let rules = schema([
            MetadataField(key: "source", type: .string, isRequired: true, defaultValue: "manual"),
            MetadataField(key: "pages", type: .integer, defaultValue: "0"),
        ])
        let normalised = validator.normalised([:], schema: rules)

        XCTAssertEqual(normalised["source"], .string("manual"))
        XCTAssertEqual(normalised["pages"], .int(0))
        XCTAssertTrue(validator.validate(normalised, against: rules).isValid)
    }

    func testExistingValuesWinOverDefaults() {
        let rules = schema([MetadataField(key: "source", type: .string, defaultValue: "manual")])
        let normalised = validator.normalised(["source": .string("imported")], schema: rules)
        XCTAssertEqual(normalised["source"], .string("imported"))
    }

    /// ChromaDB cannot compare ISO strings with $gt, so a date field can mirror
    /// itself into a numeric companion for range filters.
    func testDateFieldCanMirrorAUnixTimestamp() {
        let rules = schema([MetadataField(key: "published", type: .date, storesTimestamp: true)])
        let normalised = validator.normalised(["published": .string("2026-07-29T00:00:00Z")], schema: rules)

        guard case .int(let seconds)? = normalised["published_ts"] else {
            return XCTFail("expected published_ts")
        }
        XCTAssertEqual(seconds, Int(MetadataFieldType.iso8601.date(from: "2026-07-29T00:00:00Z")!.timeIntervalSince1970))

        // …and the companion field is not then reported as an unexpected extra.
        let strict = schema([MetadataField(key: "published", type: .date, storesTimestamp: true)], allowsExtra: false)
        XCTAssertTrue(validator.validate(normalised, against: strict).isValid)
    }

    func testValidationCarriesTheDocumentID() {
        let rules = schema([MetadataField(key: "source", type: .string, isRequired: true)])
        let result = validator.validate([:], against: rules, documentID: "doc-7")
        XCTAssertEqual(result.violations.first?.documentID, "doc-7")
    }
}

final class SchemaSelfValidationTests: XCTestCase {
    private let validator = MetadataSchemaValidator()

    func testDuplicateKeysAreReported() {
        let schema = MetadataSchema(collectionName: "demo", fields: [
            MetadataField(key: "a", type: .string),
            MetadataField(key: "a", type: .integer),
        ])
        XCTAssertTrue(validator.validateSchema(schema).contains { $0.message.contains("дважды") })
    }

    func testReservedPrefixIsRejected() {
        let schema = MetadataSchema(collectionName: "demo", fields: [
            MetadataField(key: "_cdbm_model", type: .string)
        ])
        XCTAssertFalse(validator.validateSchema(schema).isEmpty)
    }

    /// A default that does not parse would silently write nothing.
    func testBrokenDefaultIsReported() {
        let schema = MetadataSchema(collectionName: "demo", fields: [
            MetadataField(key: "pages", type: .integer, defaultValue: "много")
        ])
        let violations = validator.validateSchema(schema)
        XCTAssertEqual(violations.first?.kind, .brokenDefault)
    }

    func testCleanSchemaHasNoComplaints() {
        let schema = MetadataSchema(collectionName: "demo", fields: [
            MetadataField(key: "source", type: .string, isRequired: true, defaultValue: "manual"),
            MetadataField(key: "published", type: .date, storesTimestamp: true),
        ])
        XCTAssertTrue(validator.validateSchema(schema).isEmpty)
    }
}

final class SchemaInferenceTests: XCTestCase {
    private func document(_ id: String, _ metadata: ChromaMetadata) -> DocumentRecord {
        DocumentRecord(id: id, document: "текст", metadata: metadata)
    }

    func testInfersTypesFromDocuments() {
        let schema = MetadataSchema.inferred(collectionName: "demo", from: [
            document("1", ["source": .string("manual"), "pages": .int(3), "ratio": .double(0.5), "ok": .bool(true)]),
            document("2", ["source": .string("auto"), "pages": .int(9), "ratio": .double(1.5), "ok": .bool(false)]),
        ])

        XCTAssertEqual(schema.field(for: "source")?.type, .string)
        XCTAssertEqual(schema.field(for: "pages")?.type, .integer)
        XCTAssertEqual(schema.field(for: "ratio")?.type, .number)
        XCTAssertEqual(schema.field(for: "ok")?.type, .boolean)
    }

    func testFieldPresentEverywhereIsSuggestedAsRequired() {
        let schema = MetadataSchema.inferred(collectionName: "demo", from: [
            document("1", ["always": .string("a"), "sometimes": .string("x")]),
            document("2", ["always": .string("b")]),
        ])
        XCTAssertEqual(schema.field(for: "always")?.isRequired, true)
        XCTAssertEqual(schema.field(for: "sometimes")?.isRequired, false)
    }

    func testMixedTypesCollapseToString() {
        let schema = MetadataSchema.inferred(collectionName: "demo", from: [
            document("1", ["mixed": .int(1)]),
            document("2", ["mixed": .string("текст")]),
        ])
        XCTAssertEqual(schema.field(for: "mixed")?.type, .string)
    }

    func testAppFieldsAreNotPartOfTheDraft() {
        let schema = MetadataSchema.inferred(collectionName: "demo", from: [
            document("1", ["_cdbm_model": .string("m"), "real": .string("x")])
        ])
        XCTAssertNil(schema.field(for: "_cdbm_model"))
        XCTAssertNotNil(schema.field(for: "real"))
    }
}

final class SchemaStoreTests: XCTestCase {
    @MainActor
    private func makeStore() -> (SchemaStore, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("schemas-\(UUID().uuidString).json")
        return (SchemaStore(fileURL: url), url)
    }

    @MainActor
    func testSaveAndLookup() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertFalse(store.hasSchema(for: "demo"))
        store.save(MetadataSchema(collectionName: "demo", fields: [MetadataField(key: "source", type: .string)]))

        XCTAssertTrue(store.hasSchema(for: "demo"))
        XCTAssertEqual(store.schema(for: "demo")?.fields.count, 1)
    }

    @MainActor
    func testEmptyFieldRowsAreDroppedOnSave() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        store.save(MetadataSchema(collectionName: "demo", fields: [
            MetadataField(key: "source", type: .string),
            MetadataField(key: "   ", type: .string),
        ]))
        XCTAssertEqual(store.schema(for: "demo")?.fields.count, 1)
    }

    @MainActor
    func testPruneRemovesSchemasOfDeletedCollections() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        store.save(MetadataSchema(collectionName: "alive", fields: [MetadataField(key: "a")]))
        store.save(MetadataSchema(collectionName: "gone", fields: [MetadataField(key: "a")]))
        store.prune(keeping: ["alive"])

        XCTAssertTrue(store.hasSchema(for: "alive"))
        XCTAssertFalse(store.hasSchema(for: "gone"))
    }

    /// Export/import is how a schema travels between machines; the target
    /// collection name wins over whatever the file carried.
    @MainActor
    func testExportImportRoundTripRetargetsTheCollection() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let original = MetadataSchema(collectionName: "on-my-mac", fields: [
            MetadataField(key: "source", type: .string, isRequired: true, defaultValue: "manual"),
            MetadataField(key: "published", type: .date, storesTimestamp: true),
        ], allowsExtraFields: false)

        let data = try store.exportJSON(original)
        let imported = try store.importJSON(data, collectionName: "on-your-mac")

        XCTAssertEqual(imported.collectionName, "on-your-mac")
        XCTAssertEqual(imported.fields.map(\.key), original.fields.map(\.key))
        XCTAssertEqual(imported.fields.map(\.type), original.fields.map(\.type))
        XCTAssertEqual(imported.fields.first?.isRequired, true)
        XCTAssertEqual(imported.fields.first?.defaultValue, "manual")
        XCTAssertEqual(imported.allowsExtraFields, false)
        XCTAssertNotEqual(imported.fields.first?.id, original.fields.first?.id, "field identity must not be shared")
    }

    @MainActor
    func testImportRejectsGarbage() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try store.importJSON(Data("не json".utf8), collectionName: "demo"))
    }
}
