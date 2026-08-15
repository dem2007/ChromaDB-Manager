import XCTest
import Network
@testable import ChromaCore

/// «Экстренная остановка» revokes keys rather than deleting clients, so the
/// question these tests answer is whether a revoked key is genuinely dead.
final class KeyRevocationTests: XCTestCase {
    func testRevokingLeavesNoKeyButKeepsTheRights() {
        var (client, key) = ExternalClient.issue(
            name: "бот",
            permissions: ClientPermissions(collections: ["public"], allowsWrite: true)
        )
        XCTAssertFalse(client.isRevoked)

        client.revokeKey()

        XCTAssertTrue(client.isRevoked)
        XCTAssertFalse(client.isEnabled)
        XCTAssertEqual(client.keyHash, "")
        XCTAssertEqual(client.keyPrefix, "")
        XCTAssertEqual(client.permissions.collections, ["public"], "права переживают отзыв ключа")
        XCTAssertTrue(client.permissions.allowsWrite)
        XCTAssertNotEqual(ClientKey.hash(key), client.keyHash)
    }

    func testARevokedKeyStopsWorkingAndTheNeighbourKeepsWorking() async {
        var (revoked, revokedKey) = ExternalClient.issue(
            name: "отозванный", permissions: ClientPermissions(collections: ["public"])
        )
        let (kept, keptKey) = ExternalClient.issue(
            name: "оставленный", permissions: ClientPermissions(collections: ["public"])
        )
        revoked.revokeKey()

        let controller = AccessController()
        await controller.setClients([revoked, kept])
        await controller.setCatalog([CollectionSnapshot(id: "id-1", name: "public", dimension: 4)])

        let route = ChromaRoute.parse(
            method: "POST",
            path: "/api/v2/tenants/default_tenant/databases/default_database/collections/id-1/get"
        )
        let refused = await controller.decide(key: revokedKey, route: route, body: Data())
        let allowed = await controller.decide(key: keptKey, route: route, body: Data())

        guard case .reject(let status, _, let name, _) = refused else {
            return XCTFail("отозванный ключ пропустили: \(refused)")
        }
        // 401, and without naming a client: as far as the proxy is concerned
        // this key belongs to nobody.
        XCTAssertEqual(status, 401)
        XCTAssertNil(name)
        guard case .allow = allowed else { return XCTFail("чужой отзыв не должен ломать соседа") }
    }

    /// The empty hash left behind by a revocation must not be matchable — an
    /// empty key, a whitespace key, nothing.
    func testAnEmptyKeyNeverMatchesARevokedClient() async {
        var (client, _) = ExternalClient.issue(name: "бот", permissions: ClientPermissions(collections: ["public"]))
        client.revokeKey()

        let controller = AccessController()
        await controller.setClients([client])
        await controller.setCatalog([CollectionSnapshot(id: "id-1", name: "public", dimension: 4)])
        let route = ChromaRoute.parse(method: "GET", path: "/api/v2/heartbeat")

        for candidate in ["", " ", ClientKey.hash("")] {
            let decision = await controller.decide(key: candidate, route: route, body: Data())
            guard case .reject = decision else {
                return XCTFail("ключ «\(candidate)» не должен подходить к отозванному клиенту")
            }
        }
    }
}

/// The «отзывает все ключи» half of the emergency stop, on the same code the
/// app runs, and against a real config file — the revocation has to survive a
/// restart, or the emergency lasted exactly one launch.
final class EmergencyRevocationTests: XCTestCase {
    func testEveryLiveKeyDiesAndTheAlreadyDeadAreNotCountedTwice() {
        var configuration = AppConfiguration()
        let (reader, readerKey) = ExternalClient.issue(
            name: "читатель", permissions: ClientPermissions(collections: ["public"])
        )
        var stale = ExternalClient.issue(name: "старый").client
        stale.revokeKey()
        configuration.externalClients = [
            reader,
            ExternalClient.issue(name: "писатель", permissions: ClientPermissions(collections: ["a"], allowsWrite: true)).client,
            stale,
        ]

        let revoked = configuration.revokeAllKeys()

        XCTAssertEqual(revoked, 2, "уже отозванный ключ не отзывается второй раз")
        XCTAssertTrue(configuration.externalClients.allSatisfy(\.isRevoked))
        XCTAssertTrue(configuration.externalClients.allSatisfy { !$0.isEnabled })
        XCTAssertEqual(configuration.externalClients[0].permissions.collections, ["public"], "права остаются")
        XCTAssertTrue(configuration.externalClients[1].permissions.allowsWrite)
        XCTAssertEqual(configuration.revokeAllKeys(), 0)
        XCTAssertFalse(configuration.externalClients.contains { $0.keyHash == ClientKey.hash(readerKey) })
    }

    @MainActor
    func testRevocationSurvivesARestart() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-revoke-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        var configuration = AppConfiguration()
        let (client, key) = ExternalClient.issue(name: "бот", permissions: ClientPermissions(collections: ["public"]))
        configuration.externalClients = [client]
        configuration.proxyExposure = .allInterfaces
        _ = configuration.revokeAllKeys()
        configuration.proxyExposure = .loopback

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(configuration).write(to: file)

        let reloaded = try XCTUnwrap(SettingsStore.load(from: file))
        XCTAssertEqual(reloaded.externalClients.count, 1)
        XCTAssertTrue(reloaded.externalClients[0].isRevoked)
        XCTAssertNotEqual(reloaded.externalClients[0].keyHash, ClientKey.hash(key))
        XCTAssertEqual(reloaded.proxyExposure, .loopback, "доступ по сети не должен воскреснуть после перезапуска")
    }
}

/// «Ни один секрет не попадает в git, логи или отчёты» (ТЗ — as a
/// property of the code, not of anybody's discipline.
final class SecretsStayOutOfSightTests: XCTestCase {
    func testAWholeClientKeyIsMaskedButThePrefixSurvives() {
        let key = ClientKey.generate()
        let prefix = ClientKey.prefix(of: key)

        let masked = SecretRegistry.shared.mask("Создан клиент «бот» (\(prefix)…), ключ \(key)")

        XCTAssertFalse(masked.contains(key), "целый ключ не должен попадать в лог: \(masked)")
        XCTAssertTrue(masked.contains(prefix), "префикс — это опознавательный знак, он остаётся")
        XCTAssertTrue(masked.contains("cdbm_•••"))
    }

    func testAKeyInAHeaderIsMaskedToo() {
        let key = ClientKey.generate()
        for line in ["X-Chroma-Token: \(key)", "Authorization: Bearer \(key)"] {
            XCTAssertFalse(SecretRegistry.shared.mask(line).contains(key), line)
        }
    }

    /// The config file has nowhere to put a token: profiles keep theirs in the
    /// Keychain, clients keep only a hash. Encoding is the cheapest way to pin
    /// that down against a field added later without thinking.
    func testTheConfigFileCarriesNeitherTokensNorKeys() throws {
        let token = "super-secret-token-value"
        let (client, key) = ExternalClient.issue(name: "бот")
        var configuration = AppConfiguration()
        configuration.serverProfiles = [ServerProfile(name: "prod", kind: .external, host: "example.local", port: 8000)]
        configuration.externalClients = [client]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try XCTUnwrap(String(data: try encoder.encode(configuration), encoding: .utf8))

        XCTAssertFalse(json.contains(token))
        XCTAssertFalse(json.contains(key), "в конфиге лежит только хеш ключа")
        XCTAssertTrue(json.contains(client.keyHash))
    }
}

/// Regression: the client list is addressed by id, because a position stops
/// meaning anything the moment a client is deleted.
final class ClientLookupByIDTests: XCTestCase {
    private func configuration() -> (AppConfiguration, ExternalClient, ExternalClient) {
        var configuration = AppConfiguration()
        let first = ExternalClient.issue(name: "первый", permissions: ClientPermissions(collections: ["a"])).client
        let second = ExternalClient.issue(name: "второй", permissions: ClientPermissions(collections: ["b"])).client
        configuration.externalClients = [first, second]
        return (configuration, first, second)
    }

    /// The exact shape of the crash: the row is gone, something reads it once
    /// more. Reading and writing a client that no longer exists must be a
    /// no-op, not a trap.
    func testReadingAndWritingADeletedClientIsHarmless() {
        var (configuration, first, second) = self.configuration()
        configuration.externalClients.removeAll { $0.id == first.id }

        XCTAssertNil(configuration.client(id: first.id))
        configuration.updateClient(id: first.id) { $0.permissions.allowsWrite = true }
        configuration.toggleCollection("c", forClientID: first.id)

        XCTAssertEqual(configuration.externalClients.count, 1)
        XCTAssertEqual(configuration.client(id: second.id)?.name, "второй")
        XCTAssertEqual(configuration.client(id: second.id)?.permissions.collections, ["b"])
    }

    /// …and the client that stayed is still the one that gets edited, even
    /// though its position changed.
    func testEditsFollowTheClientNotThePosition() {
        var (configuration, first, second) = self.configuration()
        configuration.externalClients.removeAll { $0.id == first.id }

        configuration.updateClient(id: second.id) { $0.permissions.allowsWrite = true }
        configuration.toggleCollection("c", forClientID: second.id)
        configuration.toggleCollection("b", forClientID: second.id)

        let edited = try? XCTUnwrap(configuration.client(id: second.id))
        XCTAssertEqual(edited?.permissions.collections, ["c"], "«b» снят, «c» добавлен")
        XCTAssertEqual(edited?.permissions.allowsWrite, true)
    }
}

final class NetworkExposureTests: XCTestCase {
    func testBindHosts() {
        XCTAssertEqual(NetworkExposure.loopback.bindHost, "127.0.0.1")
        XCTAssertEqual(NetworkExposure.allInterfaces.bindHost, "0.0.0.0")
        XCTAssertFalse(NetworkExposure.loopback.isExposed)
        XCTAssertTrue(NetworkExposure.allInterfaces.isExposed)
    }

    func testLoopbackRecognition() {
        for host in ["127.0.0.1", "localhost", "LOCALHOST", "::1"] {
            XCTAssertTrue(SecurityAssessment.isLoopback(host), host)
        }
        for host in ["0.0.0.0", "192.168.0.10", "chroma.local"] {
            XCTAssertFalse(SecurityAssessment.isLoopback(host), host)
        }
    }

    /// Both new settings fail closed: a config written by an older build, or a
    /// value nobody recognises, must not come back open to the network.
    func testConfigurationDefaultsToClosed() throws {
        let older = Data("""
        {"mode":"localDatabase","serverProfiles":[],"preferredInstallPath":"standalone",
         "checkUpdatesAutomatically":false,"lmStudioBaseURL":"http://localhost:1234",
         "modelKindOverrides":{},"dataSources":[]}
        """.utf8)
        let nonsense = Data("""
        {"mode":"localDatabase","serverProfiles":[],"preferredInstallPath":"standalone",
         "checkUpdatesAutomatically":false,"lmStudioBaseURL":"http://localhost:1234",
         "modelKindOverrides":{},"dataSources":[],
         "proxyExposure":"everywhere","notificationsEnabled":true}
        """.utf8)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = try decoder.decode(AppConfiguration.self, from: older)
        let broken = try decoder.decode(AppConfiguration.self, from: nonsense)

        XCTAssertEqual(old.proxyExposure, .loopback)
        XCTAssertFalse(old.notificationsEnabled)
        XCTAssertEqual(broken.proxyExposure, .loopback, "неизвестное значение — это закрытый доступ")
    }
}

/// The other half of «реальный порт ChromaDB недоступен извне»: the app never
/// launches the server anywhere but loopback in the first place.
@MainActor
final class ManagedServerBindingTests: XCTestCase {
    private func launch(host: String) -> ServerLaunchConfiguration {
        ServerLaunchConfiguration(
            label: "тест",
            databasePath: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cdbm-bind"),
            host: host,
            port: PortUtility.freePort()
        )
    }

    func testAServerIsNeverStartedOnANetworkAddress() async {
        for host in ["0.0.0.0", "192.168.0.10"] {
            let manager = ChromaProcessManager()
            do {
                _ = try await manager.start(launch(host: host))
                XCTFail("сервер не должен запускаться на \(host)")
            } catch ChromaProcessManager.ServerError.exposedHost(let refused) {
                XCTAssertEqual(refused, host)
                // Refused before anything was spawned or even located.
                XCTAssertNil(manager.state.pid)
            } catch {
                XCTFail("ожидался отказ по адресу, получено: \(error)")
            }
        }
    }
}

final class SecurityAssessmentTests: XCTestCase {
    private func client(
        name: String,
        collections: [String] = ["public"],
        write: Bool = false,
        perDay: Int? = nil,
        enabled: Bool = true
    ) -> ExternalClient {
        var client = ExternalClient.issue(
            name: name,
            permissions: ClientPermissions(collections: collections, allowsWrite: write, maxDocumentsPerDay: perDay)
        ).client
        client.isEnabled = enabled
        return client
    }

    private func ids(_ assessment: SecurityAssessment) -> [String] {
        assessment.warnings.map(\.id)
    }

    func testAServerOnTheNetworkIsTheLoudestWarning() {
        let assessment = SecurityAssessment(
            exposure: .loopback, proxyIsRunning: false, proxyPort: 8900,
            serverIsRunning: true, serverHost: "0.0.0.0", serverPort: 8000
        )
        XCTAssertTrue(assessment.serverIsExposed)
        XCTAssertEqual(assessment.warnings.first?.id, "server-exposed")
        XCTAssertEqual(assessment.warnings.first?.severity, .critical)
    }

    func testALoopbackServerIsNotExposed() {
        let assessment = SecurityAssessment(
            exposure: .loopback, proxyIsRunning: true, proxyPort: 8900,
            serverIsRunning: true, serverHost: "127.0.0.1", serverPort: 8000,
            clients: [client(name: "бот")]
        )
        XCTAssertFalse(assessment.serverIsExposed)
        XCTAssertFalse(ids(assessment).contains("server-exposed"))
        XCTAssertFalse(ids(assessment).contains("proxy-exposed"))
    }

    func testAnOpenProxyWithAnUnlimitedWriterIsFlagged() {
        let assessment = SecurityAssessment(
            exposure: .allInterfaces, proxyIsRunning: true, proxyPort: 8900,
            serverIsRunning: true, serverHost: "127.0.0.1", serverPort: 8000,
            clients: [client(name: "писатель", write: true)]
        )
        XCTAssertEqual(ids(assessment).prefix(2).sorted(), ["proxy-exposed", "write-without-limit"])
        XCTAssertFalse(ids(assessment).contains("nothing-permitted"))
    }

    func testADailyLimitSilencesTheWriterWarning() {
        let assessment = SecurityAssessment(
            exposure: .allInterfaces, proxyIsRunning: true, proxyPort: 8900,
            serverIsRunning: true, serverHost: "127.0.0.1", serverPort: 8000,
            clients: [client(name: "писатель", write: true, perDay: 100)]
        )
        XCTAssertFalse(ids(assessment).contains("write-without-limit"))
    }

    func testAnOpenProxyWithNothingPermittedSaysSo() {
        let assessment = SecurityAssessment(
            exposure: .allInterfaces, proxyIsRunning: true, proxyPort: 8900,
            serverIsRunning: true, serverHost: "127.0.0.1", serverPort: 8000,
            clients: [client(name: "новичок", collections: [])]
        )
        XCTAssertTrue(ids(assessment).contains("nothing-permitted"))
    }

    func testKeysWithoutARunningProxyAndKeysThatWereRevoked() {
        var revoked = client(name: "отозванный")
        revoked.revokeKey()
        let assessment = SecurityAssessment(
            exposure: .loopback, proxyIsRunning: false, proxyPort: 8900,
            serverIsRunning: false,
            clients: [client(name: "живой"), revoked]
        )
        XCTAssertEqual(assessment.activeClients.count, 1)
        XCTAssertEqual(assessment.revokedClients.count, 1)
        XCTAssertTrue(ids(assessment).contains("proxy-stopped"))
        XCTAssertTrue(ids(assessment).contains("revoked-keys"))
    }

    func testADisabledClientIsNotAnActiveOne() {
        let assessment = SecurityAssessment(
            exposure: .loopback, proxyIsRunning: true, proxyPort: 8900,
            serverIsRunning: true, serverHost: "127.0.0.1", serverPort: 8000,
            clients: [client(name: "выключенный", enabled: false)]
        )
        XCTAssertTrue(assessment.activeClients.isEmpty)
        // The one line that is always there while a server runs: local
        // processes bypass the proxy entirely. Nothing else fires.
        XCTAssertEqual(assessment.warnings.map(\.id), ["local-access"])
    }

    // MARK: - Шифрование

    private func certificate(
        daysLeft: Double = 300,
        hosts: [String] = ["localhost", "127.0.0.1"]
    ) -> TLSCertificateInfo {
        TLSCertificateInfo(
            commonName: "ChromaDB Manager Proxy",
            notBefore: Date().addingTimeInterval(-86400),
            notAfter: Date().addingTimeInterval(daysLeft * 86400),
            fingerprint: "AA:BB",
            hosts: hosts
        )
    }

    func testOpenToTheNetworkWithoutEncryptionIsTheLoudestThingOnTheScreen() {
        let assessment = SecurityAssessment(
            exposure: .allInterfaces, proxyIsRunning: true, proxyPort: 8900,
            serverIsRunning: false,
            usesTLS: false
        )
        XCTAssertEqual(assessment.warnings.first?.id, "exposed-without-tls")
        XCTAssertEqual(assessment.warnings.first?.severity, .critical)
    }

    func testLoopbackWithoutEncryptionSaysNothing() {
        // Прямо оговорено в пункте: по петле открытый трафик за пределы Мака
        // не выходит, и предупреждать не о чем.
        let assessment = SecurityAssessment(
            exposure: .loopback, proxyIsRunning: true, proxyPort: 8900,
            serverIsRunning: false,
            usesTLS: false
        )
        XCTAssertFalse(ids(assessment).contains("exposed-without-tls"))
        XCTAssertTrue(assessment.warnings.isEmpty)
    }

    func testExpiredCertificateIsCriticalAndSoonToExpireIsNot() {
        let expired = SecurityAssessment(
            exposure: .loopback, proxyIsRunning: true, proxyPort: 8900,
            serverIsRunning: false,
            certificate: certificate(daysLeft: -1)
        )
        XCTAssertEqual(expired.warnings.first?.id, "certificate-expired")
        XCTAssertEqual(expired.warnings.first?.severity, .critical)

        let soon = SecurityAssessment(
            exposure: .loopback, proxyIsRunning: true, proxyPort: 8900,
            serverIsRunning: false,
            certificate: certificate(daysLeft: 10)
        )
        XCTAssertEqual(soon.warnings.first?.id, "certificate-expires-soon")
        XCTAssertEqual(soon.warnings.first?.severity, .caution)
        // Одно предупреждение о сроке, а не два сразу.
        XCTAssertFalse(ids(soon).contains("certificate-expired"))
    }

    func testAHealthyCertificateIsNotWorthAWord() {
        let assessment = SecurityAssessment(
            exposure: .loopback, proxyIsRunning: true, proxyPort: 8900,
            serverIsRunning: false,
            certificate: certificate()
        )
        XCTAssertTrue(assessment.warnings.isEmpty)
    }

    func testAddressTheCertificateDoesNotCoverIsFlaggedOnlyWhenExposed() {
        let exposed = SecurityAssessment(
            exposure: .allInterfaces, proxyIsRunning: true, proxyPort: 8900,
            serverIsRunning: false,
            certificate: certificate(),
            localAddresses: ["192.168.1.42"]
        )
        XCTAssertTrue(ids(exposed).contains("certificate-address-mismatch"))

        // На петле адрес в сети никого не касается: по нему никто не придёт.
        let local = SecurityAssessment(
            exposure: .loopback, proxyIsRunning: true, proxyPort: 8900,
            serverIsRunning: false,
            certificate: certificate(),
            localAddresses: ["192.168.1.42"]
        )
        XCTAssertFalse(ids(local).contains("certificate-address-mismatch"))
    }

    func testACoveredAddressIsNotFlagged() {
        let assessment = SecurityAssessment(
            exposure: .allInterfaces, proxyIsRunning: true, proxyPort: 8900,
            serverIsRunning: false,
            certificate: certificate(hosts: ["localhost", "127.0.0.1", "192.168.1.42"]),
            localAddresses: ["192.168.1.42"]
        )
        XCTAssertFalse(ids(assessment).contains("certificate-address-mismatch"))
    }

    func testSettingChangedButTheProxyStillRunsTheOldWay() {
        // Включили шифрование, а прокси работает по-старому: клиент придёт
        // по https и не получит ничего, а экран показывал бы «зашифровано».
        let turnedOn = SecurityAssessment(
            exposure: .allInterfaces, proxyIsRunning: true, proxyPort: 8900,
            serverIsRunning: false,
            usesTLS: true, certificate: certificate(), runningWithTLS: false
        )
        XCTAssertTrue(ids(turnedOn).contains("tls-restart-needed"))
        XCTAssertEqual(
            turnedOn.warnings.first(where: { $0.id == "tls-restart-needed" })?.severity,
            .critical,
            "порт открыт наружу и не шифрует прямо сейчас — намерение это не отменяет"
        )
        // И тут же честно сказано, что происходит: настройка настройкой,
        // а трафик идёт открытым.
        XCTAssertTrue(ids(turnedOn).contains("exposed-without-tls"))
        XCTAssertFalse(turnedOn.effectiveTLS)

        // На петле та же рассинхронизация не опасна: наружу ничего не идёт.
        let local = SecurityAssessment(
            exposure: .loopback, proxyIsRunning: true, proxyPort: 8900,
            serverIsRunning: false,
            usesTLS: true, certificate: certificate(), runningWithTLS: false
        )
        XCTAssertEqual(local.warnings.first?.id, "tls-restart-needed")
        XCTAssertEqual(local.warnings.first?.severity, .caution)

        // Обратный случай мягче: работающий прокси всё ещё шифрует, то есть
        // ничего не утекает — просто настройка ещё не применилась.
        let turnedOff = SecurityAssessment(
            exposure: .loopback, proxyIsRunning: true, proxyPort: 8900,
            serverIsRunning: false,
            usesTLS: false, runningWithTLS: true
        )
        XCTAssertEqual(turnedOff.warnings.first?.id, "tls-restart-needed")
        XCTAssertEqual(turnedOff.warnings.first?.severity, .caution)
    }

    func testNoRestartWarningWhenTheProxyMatchesTheSetting() {
        let assessment = SecurityAssessment(
            exposure: .loopback, proxyIsRunning: true, proxyPort: 8900,
            serverIsRunning: false,
            usesTLS: true, certificate: certificate(), runningWithTLS: true
        )
        XCTAssertTrue(assessment.warnings.isEmpty)
    }

    func testCertificateWarningsStaySilentWhenEncryptionIsOff() {
        // Выключенный TLS уже назван своим предупреждением; добавлять к нему
        // «а ещё сертификат просрочен» — шум: он ни на что не влияет.
        let assessment = SecurityAssessment(
            exposure: .loopback, proxyIsRunning: true, proxyPort: 8900,
            serverIsRunning: false,
            usesTLS: false,
            certificate: certificate(daysLeft: -5)
        )
        XCTAssertTrue(assessment.warnings.isEmpty)
    }
}

@MainActor
final class NotifierTests: XCTestCase {
    /// Collects what would have been posted, so no test ever touches the real
    /// Notification Center.
    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(String, String)] = []

        func add(_ title: String, _ body: String) {
            lock.lock(); storage.append((title, body)); lock.unlock()
        }

        var all: [(title: String, body: String)] {
            lock.lock(); defer { lock.unlock() }
            return storage.map { (title: $0.0, body: $0.1) }
        }
    }

    private func makeNotifier(
        inbox: Inbox,
        collapseWindow: TimeInterval = 60,
        granted: Bool = true
    ) -> Notifier {
        Notifier(
            collapseWindow: collapseWindow,
            deliver: { title, body in inbox.add(title, body) },
            requestAuthorization: { .success(granted) }
        )
    }

    func testNothingIsPostedUntilTheUserTurnsItOn() async {
        let inbox = Inbox()
        let notifier = makeNotifier(inbox: inbox)
        notifier.post(.serverFailed("упал"))
        XCTAssertTrue(inbox.all.isEmpty)

        let granted = await notifier.enable()
        XCTAssertTrue(granted)
        notifier.post(.serverFailed("упал"))
        XCTAssertEqual(inbox.all.count, 1)
    }

    func testARefusedPermissionLeavesTheSwitchOff() async {
        let inbox = Inbox()
        let notifier = makeNotifier(inbox: inbox, granted: false)
        let granted = await notifier.enable()

        XCTAssertFalse(granted)
        XCTAssertFalse(notifier.isEnabled)
        XCTAssertEqual(notifier.availability, .denied)
        notifier.post(.emergencyStop(revokedKeys: 1))
        XCTAssertTrue(inbox.all.isEmpty)
    }

    /// A misconfigured client retries in a loop; one notification per burst is
    /// the point of collapsing.
    func testRefusalsAreCollapsedAndTheirCountIsCarriedOver() async {
        let inbox = Inbox()
        let notifier = makeNotifier(inbox: inbox, collapseWindow: 0.4)
        await notifier.enable()

        for index in 0..<5 {
            notifier.post(.accessDenied(client: "бот", reason: "отказ \(index)"))
        }
        XCTAssertEqual(inbox.all.count, 1, "пять отказов подряд — одно уведомление")
        XCTAssertEqual(notifier.pendingCollapsedCount, 4)

        try? await Task.sleep(nanoseconds: 500_000_000)
        notifier.post(.accessDenied(client: "бот", reason: "ещё один"))
        XCTAssertEqual(inbox.all.count, 2)
        XCTAssertTrue(inbox.all[1].body.contains("4"), "пропущенные отказы должны быть посчитаны: \(inbox.all[1].body)")
        XCTAssertEqual(notifier.pendingCollapsedCount, 0)
    }

    func testTheOtherEventsAreNeverCollapsed() async {
        let inbox = Inbox()
        let notifier = makeNotifier(inbox: inbox, collapseWindow: 60)
        await notifier.enable()

        notifier.post(.serverFailed("паника"))
        notifier.post(.serverFailed("паника"))
        notifier.post(.emergencyStop(revokedKeys: 2))

        XCTAssertEqual(inbox.all.count, 3)
        XCTAssertTrue(inbox.all[2].body.contains("2"))
    }
}

/// What the definition of done asks to prove: the ChromaDB port is unreachable
/// from the network, and only the proxy port is not.
///
/// These use real sockets — a listener that is «bound to loopback» in the code
/// and reachable from the network in reality is exactly the defect worth
/// catching, and no amount of unit testing of an enum would catch it.
@MainActor
final class ProxyExposureTests: XCTestCase {
    private func makeProxy() -> ProxyServer {
        ProxyServer(audit: AuditLog(fileURL: URL(fileURLWithPath: "/dev/null")))
    }

    /// This machine's own network address, or `nil` when it has none.
    private var networkAddress: String? { LocalNetwork.addresses().first }

    func testALoopbackProxyIsNotReachableFromTheNetwork() throws {
        guard let address = networkAddress else {
            throw XCTSkip("у машины нет сетевого адреса — проверять нечего")
        }
        let proxy = makeProxy()
        let port = PortUtility.freePort()
        try proxy.start(upstreamHost: "127.0.0.1", upstreamPort: 9, listenPort: port, exposure: .loopback)
        defer { proxy.stop() }

        XCTAssertTrue(waitForListener(proxy))
        XCTAssertEqual(proxy.exposure, .loopback)
        XCTAssertTrue(canConnect(host: "127.0.0.1", port: port), "на своей машине прокси должен отвечать")
        XCTAssertFalse(
            canConnect(host: address, port: port),
            "порт, привязанный к 127.0.0.1, не должен быть виден по адресу \(address)"
        )
    }

    func testAnOpenedProxyIsReachableFromTheNetwork() throws {
        guard let address = networkAddress else {
            throw XCTSkip("у машины нет сетевого адреса — проверять нечего")
        }
        let proxy = makeProxy()
        let port = PortUtility.freePort()
        try proxy.start(upstreamHost: "127.0.0.1", upstreamPort: 9, listenPort: port, exposure: .allInterfaces)
        defer { proxy.stop() }

        XCTAssertTrue(waitForListener(proxy))
        XCTAssertEqual(proxy.exposure, .allInterfaces)
        if case .running(let boundAddress, let boundPort) = proxy.state {
            XCTAssertEqual(boundAddress, "0.0.0.0")
            XCTAssertEqual(boundPort, port)
        } else {
            XCTFail("прокси должен быть запущен: \(proxy.state)")
        }
        XCTAssertTrue(canConnect(host: address, port: port), "открытый наружу прокси должен отвечать на \(address)")
    }

    /// The switch is not allowed to put a bare ChromaDB on the network by way
    /// of a proxy that forwards to it.
    func testTheProxyRefusesToBeOpenedInFrontOfANonLoopbackServer() {
        let proxy = makeProxy()
        let port = PortUtility.freePort()
        XCTAssertThrowsError(
            try proxy.start(upstreamHost: "192.168.0.10", upstreamPort: 8000, listenPort: port, exposure: .allInterfaces)
        ) { error in
            guard case ProxyServer.ProxyError.upstreamNotLoopback = error else {
                return XCTFail("ожидалась ошибка про адрес сервера, получено: \(error)")
            }
        }
        XCTAssertFalse(proxy.state.isRunning)
    }

    /// The same server is fine while the proxy stays local: nothing is exposed.
    func testTheSameServerIsAcceptedWhileTheProxyStaysLocal() throws {
        let proxy = makeProxy()
        let port = PortUtility.freePort()
        try proxy.start(upstreamHost: "192.168.0.10", upstreamPort: 8000, listenPort: port, exposure: .loopback)
        defer { proxy.stop() }
        XCTAssertTrue(waitForListener(proxy))
    }

    // MARK: - Helpers

    private func waitForListener(_ proxy: ProxyServer, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if proxy.state.isRunning { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    /// A TCP connect with a deadline. A refused connection answers at once; a
    /// filtered one (macOS stealth mode drops silently) runs out the clock,
    /// and both mean «not reachable».
    private func canConnect(host: String, port: Int, timeout: TimeInterval = 2) -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        let outcome = Outcome()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: outcome.finish(true)
            // `.waiting` is how Network reports «refused» before it retries.
            case .failed, .cancelled, .waiting: outcome.finish(false)
            default: break
            }
        }
        connection.start(queue: DispatchQueue(label: "probe.\(port)"))
        defer { connection.cancel() }
        return outcome.wait(timeout)
    }

    private final class Outcome: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var value = false
        private var isFinished = false

        func finish(_ result: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard !isFinished else { return }
            isFinished = true
            value = result
            semaphore.signal()
        }

        func wait(_ timeout: TimeInterval) -> Bool {
            _ = semaphore.wait(timeout: .now() + timeout)
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }
}
