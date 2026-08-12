import XCTest
@testable import ChromaCore

/// Fixtures are real responses recorded from a running chroma 1.4.4 server,
/// so these tests never need ChromaDB (or the network) to run.
enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: "json") else {
            throw XCTSkip("fixture \(name).json not found in the test bundle")
        }
        return try Data(contentsOf: url)
    }
}

final class ChromaEndpointTests: XCTestCase {
    func testBaseURLString() {
        XCTAssertEqual(ChromaEndpoint(host: "localhost", port: 8000).baseURLString, "http://localhost:8000")
        XCTAssertEqual(ChromaEndpoint(host: "example.com", port: 443, useTLS: true).baseURLString, "https://example.com:443")
    }

    func testCollectionsPathIncludesTenantAndDatabase() {
        let endpoint = ChromaEndpoint(host: "h", port: 1)
        XCTAssertEqual(
            endpoint.collectionsPath,
            "/api/v2/tenants/default_tenant/databases/default_database/collections"
        )
    }

    func testCustomTenantAndDatabase() {
        let endpoint = ChromaEndpoint(host: "h", port: 1, tenant: "acme", database: "prod")
        XCTAssertEqual(endpoint.collectionsPath, "/api/v2/tenants/acme/databases/prod/collections")
    }

    func testAPIPrefixIsV2Only() {
        XCTAssertEqual(ChromaEndpoint.apiPrefix, "/api/v2")
    }
}

final class ChromaErrorMappingTests: XCTestCase {
    private func map(_ fixture: String, status: Int) throws -> ChromaError {
        ChromaClient.mapError(status: status, data: try Fixture.data(fixture), endpoint: "http://localhost:8000")
    }

    /// ChromaDB 1.x answers 410 on every /api/v1 path — the user must be told
    /// the server is too old, not shown a raw payload.
    func testDeprecatedV1BecomesServerTooOld() throws {
        guard case .serverTooOld = try map("error_v1_deprecated", status: 410) else {
            return XCTFail("expected .serverTooOld")
        }
    }

    /// The other half of «проверить соединение»: a server that is not there at
    /// all has to come back as an address the app can name, not as a raw
    /// networking error.
    func testASilentServerIsReportedAsUnreachableWithItsAddress() async throws {
        // A port nobody is listening on: the connection is refused at once.
        let port = PortUtility.freePort()
        let client = ChromaClient(
            endpoint: ChromaEndpoint(host: "127.0.0.1", port: port),
            retries: .never
        )
        do {
            _ = try await client.connect()
            XCTFail("подключение к закрытому порту не должно удаваться")
        } catch ChromaError.unreachable(let endpoint, let reason) {
            XCTAssertTrue(endpoint.contains(String(port)), endpoint)
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func testV1MessageIsRecognisedEvenWithAnotherStatus() throws {
        guard case .serverTooOld = try map("error_v1_deprecated", status: 400) else {
            return XCTFail("expected .serverTooOld")
        }
    }

    func testDimensionMismatchIsParsedFromMessage() throws {
        guard case .dimensionMismatch(let expected, let got) = try map("error_dimension", status: 400) else {
            return XCTFail("expected .dimensionMismatch")
        }
        XCTAssertEqual(expected, 4)
        XCTAssertEqual(got, 2)
    }

    func testResetDisabledBecomesTypedError() throws {
        guard case .resetForbidden = try map("error_reset_disabled", status: 403) else {
            return XCTFail("expected .resetForbidden")
        }
    }

    func testUnauthorised() {
        let data = Data(#"{"error":"AuthError","message":"missing auth"}"#.utf8)
        guard case .unauthorized = ChromaClient.mapError(status: 401, data: data, endpoint: "e") else {
            return XCTFail("expected .unauthorized")
        }
    }

    func testUnknownFailureKeepsStatusAndMessage() {
        let data = Data(#"{"error":"Whatever","message":"boom"}"#.utf8)
        guard case .api(let status, let code, let message) = ChromaClient.mapError(status: 500, data: data, endpoint: "e") else {
            return XCTFail("expected .api")
        }
        XCTAssertEqual(status, 500)
        XCTAssertEqual(code, "Whatever")
        XCTAssertEqual(message, "boom")
    }

    func testErrorsCarryUserFacingText() {
        XCTAssertNotNil(ChromaError.resetForbidden.errorDescription)
        XCTAssertNotNil(ChromaError.resetForbidden.recoverySuggestion)
        XCTAssertNotNil(ChromaError.serverTooOld(endpoint: "e").recoverySuggestion)
    }
}

final class ChromaResponseDecodingTests: XCTestCase {
    func testCollectionListDecodesBindingAndDimension() throws {
        let collections = try JSONDecoder().decode([ChromaCollection].self, from: Fixture.data("collections_list"))
        XCTAssertEqual(collections.count, 2)

        let bound = collections[0]
        XCTAssertEqual(bound.name, "demo")
        XCTAssertEqual(bound.boundModel, "text-embedding-nomic")
        XCTAssertEqual(bound.effectiveDimension, 768)
        XCTAssertTrue(bound.isBound)

        // A collection created by another tool has no _cdbm_* metadata; that is
        // a normal situation, not an error.
        let foreign = collections[1]
        XCTAssertNil(foreign.boundModel)
        XCTAssertFalse(foreign.isBound)
        XCTAssertEqual(foreign.effectiveDimension, 384, "server-reported dimension is used when metadata is missing")
    }

    func testMetadataBindingMergesInsteadOfReplacing() throws {
        let collections = try JSONDecoder().decode([ChromaCollection].self, from: Fixture.data("collections_list"))
        var extra = collections[0].metadata ?? [:]
        extra["team"] = .string("legal")
        let collection = ChromaCollection(id: "x", name: "demo", metadata: extra)

        let merged = collection.metadataBinding(model: "other-model", dimension: 512)
        XCTAssertEqual(merged["team"], .string("legal"), "unrelated metadata must survive a rebind")
        XCTAssertEqual(merged[CollectionBindingKeys.model], .string("other-model"))
        XCTAssertEqual(merged[CollectionBindingKeys.dimension], .int(512))
    }

    func testGetResponseMapsParallelArrays() throws {
        struct GetResponse: Decodable {
            let ids: [String]
            let documents: [String?]?
            let metadatas: [ChromaMetadata?]?
        }
        let payload = try JSONDecoder().decode(GetResponse.self, from: Fixture.data("get_documents"))
        XCTAssertEqual(payload.ids, ["a1", "a2"])
        XCTAssertEqual(payload.documents?.first ?? nil, "кошка сидит на окне")
        XCTAssertEqual(payload.metadatas?.first??["source_file"], .string("a.md"))
    }

    func testQueryResponseIsNested() throws {
        struct QueryResponse: Decodable {
            let ids: [[String]]
            let distances: [[Double]]?
        }
        let payload = try JSONDecoder().decode(QueryResponse.self, from: Fixture.data("query"))
        XCTAssertEqual(payload.ids.first?.count, 2)
        XCTAssertEqual(payload.distances?.first?.first ?? 0, 0.0001, accuracy: 0.0001)
    }

    func testEmbeddingsComeBackAsArrays() throws {
        struct GetResponse: Decodable { let embeddings: [[Double]?]? }
        let payload = try JSONDecoder().decode(GetResponse.self, from: Fixture.data("get_with_embeddings"))
        let first = try XCTUnwrap(payload.embeddings?.first ?? nil)
        XCTAssertEqual(first.count, 4)
    }
}

final class ServerLaunchConfigurationTests: XCTestCase {
    /// The CLI takes a config file as a positional argument; these keys were
    /// verified against chroma 1.4.4.
    func testGeneratedYAMLCarriesTheSettingsThatMatter() {
        let configuration = ServerLaunchConfiguration(
            label: "test",
            databasePath: URL(fileURLWithPath: "/tmp/db"),
            host: "127.0.0.1",
            port: 8123,
            allowReset: true
        )
        let yaml = configuration.yamlConfiguration()
        XCTAssertTrue(yaml.contains("port: 8123"))
        XCTAssertTrue(yaml.contains("listen_address: \"127.0.0.1\""))
        XCTAssertTrue(yaml.contains("persist_path: \"/tmp/db\""))
        XCTAssertTrue(yaml.contains("allow_reset: true"))
    }

    func testProfileProducesLaunchConfigurationOnlyWhenManaged() {
        let managed = ServerProfile(name: "m", kind: .managed, port: 8000, databasePath: "/tmp/db", allowReset: true)
        XCTAssertNotNil(managed.launchConfiguration())
        XCTAssertEqual(managed.launchConfiguration()?.allowReset, true)

        let external = ServerProfile(name: "e", kind: .external, host: "example.com", port: 8000)
        XCTAssertNil(external.launchConfiguration(), "the app does not launch somebody else's server")
    }

    func testTokenGoesIntoTheChosenHeader() {
        var profile = ServerProfile(name: "e", kind: .external, host: "h", port: 1)
        XCTAssertEqual(profile.endpoint(with: "secret").headers["Authorization"], "Bearer secret")

        profile.tokenHeader = .xChromaToken
        XCTAssertEqual(profile.endpoint(with: "secret").headers["X-Chroma-Token"], "secret")
        XCTAssertTrue(profile.endpoint(with: nil).headers.isEmpty)
    }
}

final class GitHubReleaseTests: XCTestCase {
    private func releases() throws -> [GitHubReleaseClient.Release] {
        try JSONDecoder().decode([GitHubReleaseClient.Release].self, from: Fixture.data("github_releases"))
    }

    /// CLI releases share the feed with engine releases and a "latest" tag.
    func testPicksNewestCLIReleaseOnly() throws {
        let release = GitHubReleaseClient.newestCLIRelease(in: try releases())
        XCTAssertEqual(release?.tag_name, "cli-1.4.4")
    }

    func testVersionStripsTagPrefix() {
        XCTAssertEqual(GitHubReleaseClient.version(fromTag: "cli-1.4.4"), "1.4.4")
        XCTAssertEqual(GitHubReleaseClient.version(fromTag: "1.5.9"), "1.5.9")
    }

    func testAssetForThisMacIsPresent() throws {
        let release = try XCTUnwrap(GitHubReleaseClient.newestCLIRelease(in: try releases()))
        let asset = release.assets.first { $0.name == GitHubReleaseClient.assetNameForCurrentMac }
        XCTAssertNotNil(asset, "the installer must find a macOS asset")
        XCTAssertGreaterThan(asset?.size ?? 0, 0)
    }
}

final class SecretMaskingTests: XCTestCase {
    func testRegisteredSecretIsMasked() {
        let secret = "tok_\(UUID().uuidString)"
        SecretRegistry.shared.register(secret)
        defer { SecretRegistry.shared.forget(secret) }

        let masked = SecretRegistry.shared.mask("Authorization: Bearer \(secret)")
        XCTAssertFalse(masked.contains(secret))
        XCTAssertTrue(masked.contains("•••"))
    }

    /// Tokens the app has never seen — e.g. echoed back by a server — are
    /// masked by shape.
    func testUnknownBearerTokenIsMasked() {
        let masked = SecretRegistry.shared.mask("sending Bearer abcdef123456 to server")
        XCTAssertFalse(masked.contains("abcdef123456"))
    }

    func testOrdinaryTextIsUntouched() {
        XCTAssertEqual(SecretRegistry.shared.mask("коллекция demo создана"), "коллекция demo создана")
    }
}

final class KeychainStoreTests: XCTestCase {
    func testRoundTrip() throws {
        let store = KeychainStore(service: "io.github.chromadbmanager.tests")
        let account = "unit-test-\(UUID().uuidString)"

        do {
            try store.set("secret-value", for: account)
        } catch {
            throw XCTSkip("Keychain is not writable in this environment: \(error.localizedDescription)")
        }
        defer { try? store.remove(account: account) }

        XCTAssertEqual(try store.token(for: account), "secret-value")
        XCTAssertTrue(store.hasToken(for: account))

        try store.set("updated", for: account)
        XCTAssertEqual(try store.token(for: account), "updated")

        // An empty value means "forget it".
        try store.set("", for: account)
        XCTAssertNil(try store.token(for: account))
    }

    func testMissingAccountReturnsNil() throws {
        let store = KeychainStore(service: "io.github.chromadbmanager.tests")
        XCTAssertNil(try store.token(for: "does-not-exist-\(UUID().uuidString)"))
    }
}

final class ToolLocatorTests: XCTestCase {
    func testFindsAToolThatCertainlyExists() {
        XCTAssertEqual(ToolLocator().locate("/bin/ls"), "/bin/ls")
        XCTAssertNotNil(ToolLocator().locate("ls"))
    }

    func testMissingToolIsNil() {
        XCTAssertNil(ToolLocator().locate("definitely-not-a-real-tool-\(UUID().uuidString)"))
    }

    func testAbsolutePathThatDoesNotExistIsRejected() {
        XCTAssertNil(ToolLocator().locate("/nope/not/here"))
    }

    /// The app's own bin directory must win over system copies, otherwise an
    /// old system-wide CLI would shadow the one the app installed.
    func testManagedDirectoryComesFirst() {
        XCTAssertEqual(ToolLocator.candidateDirectories.first, ToolLocator.managedBinDirectory.path)
        XCTAssertTrue(ToolLocator.candidateDirectories.contains("/opt/homebrew/bin"))
        XCTAssertTrue(ToolLocator.candidateDirectories.contains(NSHomeDirectory() + "/.local/bin"))
    }

    func testChildProcessPathHasNoDuplicates() {
        let entries = ToolLocator().childProcessPath().split(separator: ":").map(String.init)
        XCTAssertEqual(entries.count, Set(entries).count)
    }
}

/// Asking the login shell means spawning a process and waiting for it. Doing
/// that on the main thread inside a view update segfaulted the app, so the
/// rule is enforced here.
final class ToolLocatorThreadingTests: XCTestCase {
    @MainActor
    func testMainThreadLookupNeverSpawnsALoginShell() {
        let locator = ToolLocator()
        let missing = "definitely-not-installed-\(UUID().uuidString)"

        XCTAssertNil(locator.locate(missing))
        XCTAssertEqual(locator.loginShellProbeCount, 0, "a view update must never wait on a subprocess")
    }

    @MainActor
    func testMainThreadStillResolvesToolsFromTheCandidateDirectories() {
        let locator = ToolLocator()
        XCTAssertEqual(locator.locate("ls"), "/bin/ls")
        XCTAssertEqual(locator.loginShellProbeCount, 0)
    }

    func testBackgroundLookupProbesOnceAndRemembersTheMiss() async {
        let locator = ToolLocator()
        let missing = "definitely-not-installed-\(UUID().uuidString)"

        _ = await locator.locateAsync(missing)
        XCTAssertEqual(locator.loginShellProbeCount, 1)

        // A second lookup must not spawn another shell for the same miss.
        _ = await locator.locateAsync(missing)
        XCTAssertEqual(locator.loginShellProbeCount, 1)

        // …until the cache is dropped, e.g. after an install.
        locator.forget()
        _ = await locator.locateAsync(missing)
        XCTAssertEqual(locator.loginShellProbeCount, 2)
    }
}
