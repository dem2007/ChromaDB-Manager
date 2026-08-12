import XCTest
@testable import ChromaCore

final class SemanticVersionTests: XCTestCase {
    func testOrdering() {
        XCTAssertTrue(SemanticVersion("0.6.3")! < SemanticVersion("1.0.0")!)
        XCTAssertTrue(SemanticVersion("1.4.4")! < SemanticVersion("1.5.9")!)
        XCTAssertTrue(SemanticVersion("1.5")! < SemanticVersion("1.5.1")!)
        XCTAssertFalse(SemanticVersion("1.5.9")! < SemanticVersion("1.5.9")!)
    }

    func testPreReleaseIsOlderThanRelease() {
        XCTAssertTrue(SemanticVersion("1.0.0rc1")! < SemanticVersion("1.0.0")!)
    }

    func testEquality() {
        XCTAssertEqual(SemanticVersion("1.5.0")!, SemanticVersion("1.5")!)
    }

    func testRejectsGarbage() {
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("не версия"))
    }
}

final class CLIVersionParsingTests: XCTestCase {
    func testPlainOutput() {
        XCTAssertEqual(EnvironmentInspector.parseCLIVersionOutput("chroma 1.4.4"), "chroma 1.4.4")
    }

    /// A venv install prints Python warnings around the version — they must not
    /// reach the UI, and above all must not poison the version comparison.
    func testIgnoresPythonWarnings() {
        let noisy = """
        /Users/USER/Library/Application Support/ChromaDBManager/venv/lib/python3.9/site-packages/urllib3/__init__.py:35: NotOpenSSLWarning: urllib3 v2 only supports OpenSSL 1.1.1+, currently the 'ssl' module is compiled with 'LibreSSL 2.8.3'.
        See: https://github.com/urllib3/urllib3/issues/3020
          warnings.warn(
        chroma 1.4.4
        """
        let parsed = EnvironmentInspector.parseCLIVersionOutput(noisy)
        XCTAssertEqual(parsed, "chroma 1.4.4")
        XCTAssertEqual(EnvironmentStatus.numericVersion(from: parsed ?? ""), "1.4.4")
    }

    func testReturnsNilWhenThereIsNoVersion() {
        XCTAssertNil(EnvironmentInspector.parseCLIVersionOutput("command not found"))
    }
}

final class EnvironmentStatusTests: XCTestCase {
    /// `chroma --version` prints "chroma 1.4.4".
    func testVersionIsExtractedFromCLIOutput() {
        XCTAssertEqual(EnvironmentStatus.numericVersion(from: "chroma 1.4.4"), "1.4.4")
        XCTAssertEqual(EnvironmentStatus.numericVersion(from: "1.5.9"), "1.5.9")
        XCTAssertEqual(EnvironmentStatus.numericVersion(from: "Python 3.9.6"), "3.9.6")
    }

    /// Regression: splitting on spaces used to pick the last token, so a
    /// warning tail turned into the "installed version".
    func testStrayTextDoesNotBecomeTheVersion() {
        XCTAssertEqual(EnvironmentStatus.numericVersion(from: "chroma 1.4.4 (see issues/3020)"), "1.4.4")
    }

    func testUpdateAvailableUsesGitHubForStandalone() {
        var status = EnvironmentStatus()
        status.chromaCLIPath = "/somewhere/chroma"
        status.chromaCLIVersion = "chroma 1.4.3"
        status.engineFlavor = .standalone
        status.latestCLIVersion = "1.4.4"
        status.updateChecked = true

        XCTAssertEqual(status.installedVersion, "1.4.3")
        XCTAssertEqual(status.latestVersion, "1.4.4")
        XCTAssertTrue(status.updateAvailable)
    }

    func testUpdateAvailableUsesPyPIForVenvInstall() {
        var status = EnvironmentStatus()
        status.chromaCLIPath = "/venv/bin/chroma"
        status.chromaCLIVersion = "chroma 1.4.4"
        status.engineFlavor = .venv
        status.latestCLIVersion = "1.4.4"
        status.latestPyPIVersion = "1.5.9"
        status.updateChecked = true

        XCTAssertEqual(status.latestVersion, "1.5.9")
        XCTAssertTrue(status.updateAvailable)
    }

    func testNoUpdateWhenVersionsMatch() {
        var status = EnvironmentStatus()
        status.chromaCLIVersion = "chroma 1.4.4"
        status.latestCLIVersion = "1.4.4"
        status.updateChecked = true
        XCTAssertFalse(status.updateAvailable)
    }

    func testEngineMissingIsReported() {
        var status = EnvironmentStatus()
        status.checkedAt = Date()
        XCTAssertFalse(status.isEngineInstalled)
        XCTAssertFalse(status.canRunServer)
        XCTAssertEqual(status.items.first { $0.id == "engine" }?.state, .missing)
        XCTAssertEqual(status.items.first { $0.id == "updates" }?.state, .unknown)
    }

    /// The screen must not reflow when the first probe finishes: same rows,
    /// same order, before and after.
    func testRowsAreStableAcrossProbing() {
        let pending = EnvironmentStatus()
        XCTAssertFalse(pending.hasBeenProbed)
        XCTAssertEqual(pending.items.count, 5)
        XCTAssertTrue(pending.items.allSatisfy { $0.state == .checking })

        var probed = EnvironmentStatus()
        probed.chromaCLIPath = "/somewhere/chroma"
        probed.chromaCLIVersion = "chroma 1.4.4"
        probed.engineFlavor = .standalone
        probed.activeInterpreter = PythonInterpreter(path: "/usr/bin/python3", version: "3.12.0")
        probed.pipVersion = "pip 24.0"
        probed.checkedAt = Date()

        XCTAssertEqual(probed.items.count, 5)
        XCTAssertEqual(probed.items.map(\.id), pending.items.map(\.id))

        // The same holds for a machine with no Python at all.
        var bare = EnvironmentStatus()
        bare.checkedAt = Date()
        XCTAssertEqual(bare.items.map(\.id), pending.items.map(\.id))
    }

    /// Before the first probe nothing may be reported as missing.
    func testNothingIsClaimedMissingBeforeProbing() {
        let status = EnvironmentStatus()
        XCTAssertFalse(status.items.contains { $0.state == .missing || $0.state == .ok })
    }

    /// Python is not a requirement when the standalone CLI is installed — it
    /// must not be shown as a blocking failure.
    func testPythonIsOnlyAWarningWhenEngineIsPresent() {
        var status = EnvironmentStatus()
        status.chromaCLIPath = "/somewhere/chroma"
        status.chromaCLIVersion = "chroma 1.4.4"
        status.engineFlavor = .standalone
        status.checkedAt = Date()

        XCTAssertTrue(status.canRunServer)
        XCTAssertEqual(status.items.first { $0.id == "engine" }?.state, .ok)
        XCTAssertEqual(status.items.first { $0.id == "python" }?.state, .warning)
    }
}

final class InstallationDiagnosticsTests: XCTestCase {
    func testDetectsExternallyManagedEnvironment() {
        let output = "error: externally-managed-environment\n× This environment is externally managed"
        XCTAssertNotNil(InstallationService.diagnose(output))
        XCTAssertTrue(InstallationService.diagnose(output)!.contains("venv"))
    }

    func testDetectsNetworkFailure() {
        let output = "WARNING: Retrying (Retry(total=4, connect=None...)) after connection broken"
        XCTAssertTrue(InstallationService.diagnose(output)!.lowercased().contains("интернет"))
    }

    func testDetectsPermissionProblem() {
        XCTAssertNotNil(InstallationService.diagnose("ERROR: Could not install packages. Permission denied"))
    }

    func testDetectsMissingVenvModule() {
        XCTAssertNotNil(InstallationService.diagnose("/usr/bin/python3: No module named venv"))
    }

    func testReturnsNilForSuccessfulOutput() {
        XCTAssertNil(InstallationService.diagnose("Successfully installed chromadb-1.5.9"))
    }
}

final class PipOutputParsingTests: XCTestCase {
    func testParsesVersionFromPipShow() {
        let output = """
        Name: chromadb
        Version: 1.5.9
        Summary: Chroma.
        Location: /tmp/venv/lib/python3.12/site-packages
        """
        XCTAssertEqual(EnvironmentInspector.parsePipShowVersion(output), "1.5.9")
    }

    func testReturnsNilWhenPackageIsMissing() {
        XCTAssertNil(EnvironmentInspector.parsePipShowVersion("WARNING: Package(s) not found: chromadb"))
    }
}

final class MetadataValueTests: XCTestCase {
    func testInferenceFromUserInput() {
        XCTAssertEqual(MetadataValue.inferred(from: "42"), .int(42))
        XCTAssertEqual(MetadataValue.inferred(from: "3.5"), .double(3.5))
        XCTAssertEqual(MetadataValue.inferred(from: "true"), .bool(true))
        XCTAssertEqual(MetadataValue.inferred(from: " legal "), .string("legal"))
    }

    func testDecodingMixedJSON() throws {
        let json = #"{"a":"text","b":7,"c":1.5,"d":true,"e":null}"#.data(using: .utf8)!
        let metadata = try JSONDecoder().decode(ChromaMetadata.self, from: json)
        XCTAssertEqual(metadata["a"], .string("text"))
        XCTAssertEqual(metadata["b"], .int(7))
        XCTAssertEqual(metadata["c"], .double(1.5))
        XCTAssertEqual(metadata["d"], .bool(true))
        XCTAssertEqual(metadata["e"], .null)
    }

    func testRoundTripEncoding() throws {
        let original: ChromaMetadata = ["source_file": .string("a.md"), "chunk_index": .int(3)]
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(ChromaMetadata.self, from: data), original)
    }
}

final class CollectionNamingTests: XCTestCase {
    /// The server enforces ASCII only — verified against chroma 1.4.4.
    func testSanitizesFolderNames() {
        XCTAssertEqual(CollectionNaming.sanitize("Мои заметки 2024"), "2024")
        XCTAssertEqual(CollectionNaming.sanitize("docs"), "docs")
        XCTAssertEqual(CollectionNaming.sanitize("my docs!"), "my_docs")
        XCTAssertTrue(CollectionNaming.isValid(CollectionNaming.sanitize("a")))
        XCTAssertTrue(CollectionNaming.isValid(CollectionNaming.sanitize("!!!")))
    }

    func testValidation() {
        XCTAssertTrue(CollectionNaming.isValid("valid_name-1.0"))
        XCTAssertFalse(CollectionNaming.isValid("ab"))
        XCTAssertFalse(CollectionNaming.isValid("_leading"))
        XCTAssertFalse(CollectionNaming.isValid("has space"))
        XCTAssertFalse(CollectionNaming.isValid("Мои_заметки"))
    }
}

final class SourceIdentityTests: XCTestCase {
    func testDocumentIDIsStableAndUnique() {
        let first = SourceSyncService.documentID(relativePath: "notes/a.md", chunkIndex: 0)
        XCTAssertEqual(first, SourceSyncService.documentID(relativePath: "notes/a.md", chunkIndex: 0))
        XCTAssertNotEqual(first, SourceSyncService.documentID(relativePath: "notes/a.md", chunkIndex: 1))
        XCTAssertNotEqual(first, SourceSyncService.documentID(relativePath: "notes/b.md", chunkIndex: 0))
    }

    func testDocumentIDFollowsTheFixedScheme() {
        // <first 16 hex of sha256(relative_path)>-<chunk_index>
        let id = SourceSyncService.documentID(relativePath: "a.md", chunkIndex: 7)
        let parts = id.split(separator: "-")
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].count, 16)
        XCTAssertEqual(parts[1], "7")
    }

    func testContentHashIsStable() {
        XCTAssertEqual(SourceSyncService.contentHash(of: "abc"), SourceSyncService.contentHash(of: "abc"))
        XCTAssertNotEqual(SourceSyncService.contentHash(of: "abc"), SourceSyncService.contentHash(of: "abd"))
        XCTAssertEqual(SourceSyncService.contentHash(of: "abc").count, 64)
    }

    func testRelativePath() {
        let root = URL(fileURLWithPath: "/tmp/docs")
        XCTAssertEqual(SourceSyncService.relative(URL(fileURLWithPath: "/tmp/docs/sub/a.md"), to: root), "sub/a.md")
        XCTAssertEqual(SourceSyncService.relative(URL(fileURLWithPath: "/other/a.md"), to: root), "a.md")
    }

    func testScanFiltersByExtensionAndRecursion() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-tests-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "top".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "skip".write(to: root.appendingPathComponent("b.png"), atomically: true, encoding: .utf8)
        try "deep".write(to: nested.appendingPathComponent("c.md"), atomically: true, encoding: .utf8)

        let service = SourceSyncService()
        var source = DataSource(name: "t", path: root.path, fileExtensions: ["md"], recursive: true, collectionName: "t_col")
        var found = try await service.scanFiles(source: source)
        XCTAssertEqual(found.count, 2)

        source.recursive = false
        found = try await service.scanFiles(source: source)
        XCTAssertEqual(found.count, 1)

        source.fileExtensions = ["png"]
        found = try await service.scanFiles(source: source)
        XCTAssertEqual(found.count, 1)
    }
}

final class ConfigurationPersistenceTests: XCTestCase {
    func testConfigurationRoundTrip() throws {
        var configuration = AppConfiguration()
        configuration.mode = .server
        configuration.serverProfiles = [
            ServerProfile(name: "local", kind: .managed, host: "localhost", port: 8123, databasePath: "/tmp/db", allowReset: true)
        ]
        configuration.dataSources = [DataSource(name: "docs", path: "/tmp/docs", collectionName: "docs_col")]
        configuration.defaultEmbeddingModel = "text-embedding-nomic"
        configuration.preferredInstallPath = .managedVenv

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(AppConfiguration.self, from: encoder.encode(configuration))
        XCTAssertEqual(restored.mode, .server)
        XCTAssertEqual(restored.serverProfiles.first?.port, 8123)
        XCTAssertEqual(restored.serverProfiles.first?.allowReset, true)
        XCTAssertEqual(restored.preferredInstallPath, .managedVenv)
        XCTAssertEqual(restored.defaultEmbeddingModel, "text-embedding-nomic")
    }

    /// A config written by an older build must not wipe the user's profiles.
    func testDecodingToleratesUnknownAndMissingKeys() throws {
        let legacy = """
        {"mode":"embedded","embeddedDatabasePath":"/tmp/old","serverProfiles":[],"someRemovedFlag":true}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let configuration = try decoder.decode(AppConfiguration.self, from: legacy)

        XCTAssertEqual(configuration.mode, .localDatabase, "an unknown mode falls back to the default")
        XCTAssertEqual(configuration.lmStudioBaseURL, "http://localhost:1234")
        XCTAssertFalse(configuration.checkUpdatesAutomatically)
    }

    func testUpdateChecksAreOffByDefault() {
        // Version checks reach the network, so they must be opt-in.
        XCTAssertFalse(AppConfiguration().checkUpdatesAutomatically)
        XCTAssertEqual(AppConfiguration().preferredInstallPath, .standalone)
        XCTAssertEqual(AppConfiguration().mode, .localDatabase)
    }
}

final class RunningServerRecordTests: XCTestCase {
    func testCurrentProcessIsDetectedAsAlive() {
        let record = RunningServerRecord(
            pid: ProcessInfo.processInfo.processIdentifier,
            port: 8000,
            host: "127.0.0.1",
            path: "/tmp/db",
            label: "test",
            startedAt: Date()
        )
        XCTAssertTrue(record.isAlive)
    }

    func testImplausiblePIDIsNotAlive() {
        let record = RunningServerRecord(
            pid: 999_999,
            port: 8000,
            host: "127.0.0.1",
            path: "/tmp/db",
            label: "test",
            startedAt: Date()
        )
        XCTAssertFalse(record.isAlive)
    }
}

final class PortUtilityTests: XCTestCase {
    func testFreePortIsInUsableRange() {
        let port = PortUtility.freePort()
        XCTAssertTrue((1024...65535).contains(port), "got \(port)")
    }
}

final class BindingErrorTests: XCTestCase {
    func testEveryCaseExplainsItselfAndWhatToDo() {
        let errors: [BindingError] = [
            .notBound(collection: "demo"),
            .modelUnavailable(model: "m"),
            .dimensionConflict(collection: "demo", stored: 768, model: 384),
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertNotNil(error.recoverySuggestion)
        }
    }
}

final class DocumentFilterTests: XCTestCase {
    private func condition(_ field: String, _ op: FilterOperator, _ value: String) -> MetadataCondition {
        MetadataCondition(field: field, op: op, value: value)
    }

    func testEmptyFilterProducesNoClause() throws {
        XCTAssertTrue(DocumentFilter().isEmpty)
        XCTAssertNil(try DocumentFilter().whereClause())
        // A half-filled row is ignored rather than sent as a broken clause.
        let partial = DocumentFilter(conditions: [condition("src", .equals, "")])
        XCTAssertNil(try partial.whereClause())
    }

    func testSingleConditionIsNotWrappedInAnd() {
        let filter = DocumentFilter(conditions: [condition("src", .equals, "manual")])
        XCTAssertEqual(filter.whereJSONString(), #"{"src":{"$eq":"manual"}}"#)
    }

    func testSeveralConditionsAreCombinedWithAnd() {
        let filter = DocumentFilter(conditions: [
            condition("src", .equals, "manual"),
            condition("n", .greaterOrEqual, "3"),
        ])
        XCTAssertEqual(filter.whereJSONString(), #"{"$and":[{"src":{"$eq":"manual"}},{"n":{"$gte":3}}]}"#)
    }

    /// ChromaDB compares typed values: a quoted 3 would never match a numeric 3.
    func testValuesKeepTheirType() {
        XCTAssertEqual(DocumentFilter(conditions: [condition("n", .equals, "42")]).whereJSONString(),
                       #"{"n":{"$eq":42}}"#)
        XCTAssertEqual(DocumentFilter(conditions: [condition("ratio", .less, "1.5")]).whereJSONString(),
                       #"{"ratio":{"$lt":1.5}}"#)
        XCTAssertEqual(DocumentFilter(conditions: [condition("ok", .equals, "true")]).whereJSONString(),
                       #"{"ok":{"$eq":true}}"#)
        XCTAssertEqual(DocumentFilter(conditions: [condition("src", .equals, "42a")]).whereJSONString(),
                       #"{"src":{"$eq":"42a"}}"#)
    }

    func testListOperatorsSplitOnCommas() {
        let filter = DocumentFilter(conditions: [condition("src", .inList, "a, b ,c")])
        XCTAssertEqual(filter.whereJSONString(), #"{"src":{"$in":["a","b","c"]}}"#)
    }

    func testDocumentContainsIsASeparateClause() {
        let filter = DocumentFilter(documentContains: " кошек ")
        XCTAssertNil(try filter.whereClause())
        XCTAssertEqual(filter.whereDocumentJSONString(), #"{"$contains":"кошек"}"#)
        XCTAssertFalse(filter.isEmpty)
    }

    func testRawJSONOverridesTheBuilder() throws {
        let filter = DocumentFilter(
            conditions: [condition("src", .equals, "ignored")],
            rawWhereJSON: #"{"n": {"$gt": 10}}"#
        )
        XCTAssertTrue(filter.usesRawJSON)
        XCTAssertEqual(filter.whereJSONString(), #"{"n":{"$gt":10}}"#)
    }

    func testBrokenRawJSONIsReported() {
        let filter = DocumentFilter(rawWhereJSON: "{not json")
        XCTAssertThrowsError(try filter.whereClause()) { error in
            XCTAssertTrue(error is FilterError)
            XCTAssertNotNil((error as? FilterError)?.errorDescription)
        }
    }
}

final class ImportServiceTests: XCTestCase {
    func testCSVWithQuotedFieldsCommasAndNewlines() throws {
        // Extended delimiters: the row with doubled quotes ends in three quote
        // characters, which would close a plain """ literal early.
        let csv = #"""
        id,text,source
        1,"строка, с запятой",manual
        2,"строка
        с переносом",auto
        3,"кавычка ""внутри""",manual
        """#
        let table = try ImportService.parseDelimited(csv)
        XCTAssertEqual(table.columns, ["id", "text", "source"])
        XCTAssertEqual(table.rowCount, 3)
        XCTAssertEqual(table.rows[0]["text"], "строка, с запятой")
        XCTAssertEqual(table.rows[1]["text"], "строка\nс переносом")
        XCTAssertEqual(table.rows[2]["text"], #"кавычка "внутри""#)
        XCTAssertEqual(table.rows[1]["source"], "auto")
    }

    func testCSVHandlesCRLFAndTrailingNewline() throws {
        let table = try ImportService.parseDelimited("a,b\r\n1,2\r\n")
        XCTAssertEqual(table.rowCount, 1)
        XCTAssertEqual(table.rows[0]["b"], "2")
    }

    func testCSVWithOnlyHeaderIsRejected() {
        XCTAssertThrowsError(try ImportService.parseDelimited("a,b\n"))
    }

    func testJSONArrayOfObjects() throws {
        let json = """
        [{"text":"первый","n":1,"ok":true},
         {"text":"второй","n":2,"ok":false,"extra":null}]
        """
        let table = try ImportService.parseJSON(json)
        XCTAssertEqual(table.rowCount, 2)
        XCTAssertTrue(table.columns.contains("text"))
        XCTAssertEqual(table.rows[0]["n"], "1")
        XCTAssertEqual(table.rows[0]["ok"], "true", "booleans must not become 1/0")
        XCTAssertEqual(table.rows[1]["extra"], "")
    }

    func testJSONWrappedInAnObject() throws {
        let table = try ImportService.parseJSON(#"{"documents":[{"text":"а"},{"text":"б"}]}"#)
        XCTAssertEqual(table.rowCount, 2)
    }

    func testJSONThatIsNotAListIsRejected() {
        XCTAssertThrowsError(try ImportService.parseJSON(#"{"text":"один объект"}"#))
    }

    func testSuggestedMappingPicksTextAndId() throws {
        let table = try ImportService.parseDelimited("id,text,source\n1,привет,manual\n")
        let mapping = ImportMapping.suggested(for: table)
        XCTAssertEqual(mapping.documentColumn, "text")
        XCTAssertEqual(mapping.idColumn, "id")
        XCTAssertEqual(mapping.metadataColumns, ["source"])
    }

    func testPrepareSkipsRowsWithoutText() throws {
        let table = try ImportService.parseDelimited("id,text,n\n1,есть текст,5\n2,,7\n")
        let mapping = ImportMapping(documentColumn: "text", idColumn: "id", metadataColumns: ["n"])
        let result = try ImportService.prepare(table, mapping: mapping)

        XCTAssertEqual(result.documents.count, 1)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.documents[0].id, "1")
        XCTAssertEqual(result.documents[0].metadata["n"], .int(5), "numbers stay numbers in metadata")
    }

    func testPrepareRequiresADocumentColumn() throws {
        let table = try ImportService.parseDelimited("a,b\n1,2\n")
        XCTAssertThrowsError(try ImportService.prepare(table, mapping: ImportMapping()))
    }
}
