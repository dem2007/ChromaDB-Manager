import XCTest
@testable import ChromaCore

// MARK: - C3: rate

final class TokenBucketTests: XCTestCase {
    /// Burst first, then the steady rate: a client that legitimately fires ten
    /// requests at once must not be throttled, and one that never stops must.
    func testTheBurstIsSpentThenTheRateApplies() {
        var bucket = TokenBucket(perMinute: 60, burst: 5, now: Date(timeIntervalSince1970: 0))
        let start = Date(timeIntervalSince1970: 0)

        for index in 0..<5 {
            XCTAssertTrue(bucket.take(now: start).allowed, "всплеск \(index + 1) из 5")
        }
        let refused = bucket.take(now: start)
        XCTAssertFalse(refused.allowed, "шестой запрос в ту же миллисекунду — сверх всплеска")
        XCTAssertGreaterThanOrEqual(refused.retryAfterSeconds, 1)
    }

    func testTokensComeBackWithTime() {
        var bucket = TokenBucket(perMinute: 60, burst: 2, now: Date(timeIntervalSince1970: 0))
        let start = Date(timeIntervalSince1970: 0)
        _ = bucket.take(now: start)
        _ = bucket.take(now: start)
        XCTAssertFalse(bucket.take(now: start).allowed)

        // 60 per minute is one per second.
        XCTAssertTrue(bucket.take(now: start.addingTimeInterval(1.1)).allowed)
    }

    func testTheBucketNeverFillsPastItsCapacity() {
        var bucket = TokenBucket(perMinute: 600, burst: 3, now: Date(timeIntervalSince1970: 0))
        let later = Date(timeIntervalSince1970: 3600)
        for _ in 0..<3 {
            XCTAssertTrue(bucket.take(now: later).allowed)
        }
        XCTAssertFalse(bucket.take(now: later).allowed, "час простоя не даёт бесконечный запас")
    }

    func testRetryAfterIsNeverZeroWhenRefused() {
        var bucket = TokenBucket(perMinute: 1, burst: 1, now: Date(timeIntervalSince1970: 0))
        let start = Date(timeIntervalSince1970: 0)
        _ = bucket.take(now: start)
        let refused = bucket.take(now: start)
        XCTAssertFalse(refused.allowed)
        XCTAssertGreaterThan(refused.retryAfterSeconds, 0, "клиенту надо сказать, когда возвращаться")
    }
}

final class AccessRateLimitTests: XCTestCase {
    private func makeController(_ permissions: ClientPermissions) async -> (AccessController, String, UUID) {
        let (client, key) = ExternalClient.issue(name: "тест", permissions: permissions)
        let controller = AccessController()
        await controller.setClients([client])
        await controller.setCatalog([CollectionSnapshot(id: "id-1", name: "notes", dimension: 4)])
        return (controller, key, client.id)
    }

    private let readRoute = ChromaRoute.parse(
        method: "POST",
        path: "/api/v2/tenants/default_tenant/databases/default_database/collections/id-1/get"
    )
    private let writeRoute = ChromaRoute.parse(
        method: "POST",
        path: "/api/v2/tenants/default_tenant/databases/default_database/collections/id-1/upsert"
    )

    /// The failure C3 exists for: a loop that spends a daily quota in a minute.
    func testARunawayClientIsThrottledWithRetryAfter() async {
        let (controller, key, clientID) = await makeController(
            ClientPermissions(collections: ["notes"], requestsPerMinute: 60, burst: 3)
        )

        for index in 0..<3 {
            let decision = await controller.decide(key: key, route: readRoute, body: Data())
            guard case .allow = decision else {
                return XCTFail("запрос \(index + 1) должен пройти: \(decision)")
            }
        }
        let refused = await controller.decide(key: key, route: readRoute, body: Data())
        guard case .reject(let status, let message, let name, let retryAfter) = refused else {
            return XCTFail("четвёртый запрос должен быть отклонён")
        }
        XCTAssertEqual(status, 429)
        XCTAssertEqual(name, "тест")
        XCTAssertNotNil(retryAfter)
        XCTAssertTrue(message.contains("60"), message)

        let throttled = await controller.throttledCount(for: clientID)
        XCTAssertEqual(throttled, 1, "счётчик отказов виден в карточке клиента")
    }

    /// Writes get their own, stricter bucket.
    func testWritesAreLimitedSeparately() async {
        let (controller, key, _) = await makeController(
            ClientPermissions(collections: ["notes"], allowsWrite: true,
                              requestsPerMinute: 600, burst: 100, writesPerMinute: 60)
        )
        let body = Data(#"{"ids":["a"],"documents":["текст"]}"#.utf8)

        var allowed = 0
        for _ in 0..<60 {
            if case .allow = await controller.decide(key: key, route: writeRoute, body: body) { allowed += 1 }
        }
        XCTAssertLessThan(allowed, 60, "запись упирается в свой лимит раньше общего")
        XCTAssertGreaterThan(allowed, 0)
    }

    /// A client that stays inside its limits is never touched.
    func testAWellBehavedClientIsNotThrottled() async {
        let (controller, key, _) = await makeController(
            ClientPermissions(collections: ["notes"], requestsPerMinute: 120, burst: 20)
        )
        for index in 0..<20 {
            let decision = await controller.decide(key: key, route: readRoute, body: Data())
            guard case .allow = decision else {
                return XCTFail("запрос \(index + 1) в пределах всплеска: \(decision)")
            }
        }
    }
}

// MARK: - C4: CORS

final class CORSPermissionTests: XCTestCase {
    func testCORSIsOffUntilAnOriginIsListed() {
        let permissions = ClientPermissions()
        XCTAssertTrue(permissions.allowedOrigins.isEmpty)
        XCTAssertFalse(permissions.allowsOrigin("https://example.com"))
        XCTAssertFalse(permissions.allowsAnyOrigin)
    }

    func testOnlyListedOriginsPass() {
        let permissions = ClientPermissions(allowedOrigins: ["https://example.com"])
        XCTAssertTrue(permissions.allowsOrigin("https://example.com"))
        XCTAssertFalse(permissions.allowsOrigin("https://evil.example.com"))
        XCTAssertFalse(permissions.allowsOrigin("http://example.com"), "схема — часть origin")
    }

    func testTheWildcardIsUnderstoodButRecognisable() {
        let permissions = ClientPermissions(allowedOrigins: ["*"])
        XCTAssertTrue(permissions.allowsOrigin("https://anything.example"))
        XCTAssertTrue(permissions.allowsAnyOrigin, "интерфейс должен уметь это подсветить")
    }

    /// A preflight carries no key, so the proxy answers it from the union of
    /// what any enabled client allows.
    func testAPreflightIsCheckedAgainstEveryEnabledClient() async {
        let (allowed, _) = ExternalClient.issue(
            name: "браузер",
            permissions: ClientPermissions(allowedOrigins: ["https://app.example"])
        )
        var (disabled, _) = ExternalClient.issue(
            name: "выключенный",
            permissions: ClientPermissions(allowedOrigins: ["https://old.example"])
        )
        disabled.isEnabled = false

        let controller = AccessController()
        await controller.setClients([allowed, disabled])

        var fromAllowed = false
        var fromDisabled = false
        var fromUnknown = false
        fromAllowed = await controller.originIsAllowedByAnyClient("https://app.example")
        fromDisabled = await controller.originIsAllowedByAnyClient("https://old.example")
        fromUnknown = await controller.originIsAllowedByAnyClient("https://other.example")

        XCTAssertTrue(fromAllowed)
        XCTAssertFalse(fromDisabled, "выключенный клиент никого не пускает")
        XCTAssertFalse(fromUnknown)
    }

    func testOlderConfigurationsGetTheDefaultLimits() throws {
        // A config written before C3 existed has none of these keys.
        let json = #"{"collections":["notes"],"allowsWrite":true}"#
        let decoded = try JSONDecoder().decode(ClientPermissions.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.requestsPerMinute, 120)
        XCTAssertEqual(decoded.burst, 20)
        XCTAssertEqual(decoded.writesPerMinute, 30)
        XCTAssertTrue(decoded.allowedOrigins.isEmpty, "CORS не включается сам собой при обновлении")
        XCTAssertEqual(decoded.collections, ["notes"])
        XCTAssertTrue(decoded.allowsWrite)
    }
}

// MARK: - C2/C5: what the security screen says

final class LocalAccessAndFirewallTests: XCTestCase {
    private func assessment(
        exposure: NetworkExposure = .loopback,
        proxyRunning: Bool = true,
        serverRunning: Bool = true,
        uptime: TimeInterval? = nil,
        sawExternal: Bool = false
    ) -> SecurityAssessment {
        SecurityAssessment(
            exposure: exposure,
            proxyIsRunning: proxyRunning,
            proxyPort: 8900,
            serverIsRunning: serverRunning,
            serverHost: "127.0.0.1",
            serverPort: 8000,
            clients: [],
            proxyUptime: uptime,
            sawExternalRequest: sawExternal
        )
    }

    /// this is stated whenever a server runs — it is a property of the
    /// engine, not a misconfiguration.
    func testLocalAccessIsAlwaysStated() {
        let warning = assessment().warnings.first { $0.id == "local-access" }
        XCTAssertNotNil(warning)
        XCTAssertEqual(warning?.severity, .info)
        XCTAssertTrue(warning?.text.contains("127.0.0.1") == true)
    }

    func testNothingIsSaidWhenNoServerRuns() {
        let ids = assessment(serverRunning: false).warnings.map(\.id)
        XCTAssertFalse(ids.contains("local-access"))
    }

    /// an open port with no traffic is ambiguous — after a while, say so.
    func testAnOpenPortWithNoTrafficSuggestsTheFirewall() {
        let quiet = assessment(exposure: .allInterfaces, uptime: 600, sawExternal: false)
        let warning = quiet.warnings.first { $0.id == "no-external-traffic" }
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.suggestion?.contains("брандмауэр") == true)
    }

    func testTrafficThatArrivedSilencesTheFirewallHint() {
        let busy = assessment(exposure: .allInterfaces, uptime: 600, sawExternal: true)
        XCTAssertFalse(busy.warnings.contains { $0.id == "no-external-traffic" })
    }

    /// Right after opening the port silence means nothing yet.
    func testTheHintWaitsBeforeItAppears() {
        let fresh = assessment(exposure: .allInterfaces, uptime: 10, sawExternal: false)
        XCTAssertFalse(fresh.warnings.contains { $0.id == "no-external-traffic" })
    }

    func testALoopbackProxyIsNeverSuspectedOfFirewallTrouble() {
        let local = assessment(exposure: .loopback, uptime: 6000, sawExternal: false)
        XCTAssertFalse(local.warnings.contains { $0.id == "no-external-traffic" })
    }
}
