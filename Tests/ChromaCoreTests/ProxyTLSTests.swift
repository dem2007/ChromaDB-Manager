import XCTest
import Network
@testable import ChromaCore

/// TLS проверяется только вживую. Модульный тест здесь ничего не доказывает:
/// вопрос не «вызвали ли мы `sec_protocol_options_set_local_identity`»,
/// а «отвергнет ли настоящий клиент соединение, которому не должен доверять».
/// Поэтому в тесте настоящий слушатель, настоящий upstream и настоящий `curl`.
final class ProxyTLSTests: XCTestCase {
    private var service: TLSCertificateService?
    private var directory: URL?
    private var upstream: StubUpstream?
    private var core: ProxyCore?

    override func tearDown() {
        core?.stop()
        upstream?.stop()
        service?.remove()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        core = nil
        upstream = nil
        service = nil
        directory = nil
        super.tearDown()
    }

    // MARK: - Обвязка

    private func makeService() throws -> TLSCertificateService {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("proxy-tls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let service = TLSCertificateService(
            tag: "io.github.chromadbmanager.tests.\(UUID().uuidString)",
            label: "ChromaDB Manager (тест)",
            file: directory.appendingPathComponent("certificate.der")
        )
        self.service = service
        return service
    }

    private func curl(_ arguments: [String]) -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "curl не запустился: \(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Отпечаток, который получает клиент, подключившийся к порту. Считается
    /// сторонним инструментом, а не нашим кодом: сверять свой ответ со своим же
    /// расчётом — значит не проверить ничего.
    private func fingerprintSeenByClient(port: Int) throws -> String {
        let script = """
        /usr/bin/openssl s_client -connect 127.0.0.1:\(port) -servername localhost </dev/null 2>/dev/null \
        | /usr/bin/openssl x509 -noout -fingerprint -sha256
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        // «sha256 Fingerprint=AB:CD:…» — берём то, что после знака равенства.
        guard let value = output.split(separator: "=").last else {
            throw XCTSkip("openssl не отдал отпечаток: \(output)")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ключ, которому прокси разрешит пройти: иначе ответом будет 401 и
    /// проверять шифрование станет нечего.
    private func allowingController(key: String) async -> AccessController {
        let controller = AccessController()
        await controller.setClients([
            ExternalClient(
                name: "тест",
                keyHash: ClientKey.hash(key),
                keyPrefix: ClientKey.prefix(of: key),
                permissions: ClientPermissions(collections: ["public"], allowsWrite: false)
            ),
        ])
        return controller
    }

    // MARK: - Проверки

    func testTrustingClientGetsThroughAndUntrustingOneDoesNot() async throws {
        let service = try makeService()
        let certificate: TLSCertificateInfo
        do {
            certificate = try service.issue(hosts: ["localhost", "127.0.0.1"])
        } catch {
            throw XCTSkip("Keychain недоступен: \(error.localizedDescription)")
        }

        let upstream = try StubUpstream(body: "{\"ok\":true}")
        self.upstream = upstream

        let key = "tls-test-key"
        let file = directory!.appendingPathComponent("audit.jsonl")
        let audit = await MainActor.run { AuditLog(fileURL: file) }
        let core = ProxyCore(audit: audit, access: await allowingController(key: key))
        self.core = core
        let port = PortUtility.freePort()
        try core.start(
            upstreamHost: "127.0.0.1",
            upstreamPort: upstream.port,
            listenPort: port,
            bindHost: "127.0.0.1",
            identity: try service.identity()
        )
        try await Task.sleep(nanoseconds: 300_000_000)

        let pem = directory!.appendingPathComponent("certificate.pem")
        try service.export(to: pem)
        let path = "https://localhost:\(port)/api/v2/heartbeat"

        // 1. Клиент, доверяющий сертификату, работает.
        let trusted = curl(["-s", "--cacert", pem.path, "-H", "X-Chroma-Token: \(key)", path])
        XCTAssertEqual(trusted.code, 0, "клиент с сертификатом должен пройти, а вывод был: \(trusted.output)")
        XCTAssertTrue(trusted.output.contains("ok"), "ответ upstream должен дойти целиком: \(trusted.output)")

        // 2. Клиент без сертификата не проходит — и именно из-за TLS,
        //    а не потому, что «что-то пошло не так».
        let untrusted = curl(["-s", "-H", "X-Chroma-Token: \(key)", path])
        XCTAssertNotEqual(untrusted.code, 0, "соединение без доверия обязано отвергаться, а не проходить молча")
        XCTAssertEqual(untrusted.code, 60, "код 60 у curl — это отказ проверки сертификата: \(untrusted.output)")

        // 3. Отпечаток, который приложение показывает человеку, — тот самый,
        //    который видит клиент. Иначе сверять его глазами бессмысленно:
        //    именно на этой сверке держится доверие к самоподписанному
        //    сертификату. Спрашиваем не себя, а `openssl` — так же, как это
        //    сделал бы недоверчивый пользователь.
        let seen = try fingerprintSeenByClient(port: port)
        XCTAssertEqual(seen, certificate.fingerprint, "клиент видит не тот сертификат, что показан в приложении")
    }

    func testWithoutTLSTheSameProxyAnswersOverPlainHTTP() async throws {
        // Режим без шифрования остаётся рабочим — он нужен для отладки и для
        // клиентов, не умеющих доверять самоподписанному сертификату.
        let upstream = try StubUpstream(body: "{\"ok\":true}")
        self.upstream = upstream

        let key = "plain-test-key"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString).jsonl")
        let audit = await MainActor.run { AuditLog(fileURL: file) }
        let core = ProxyCore(audit: audit, access: await allowingController(key: key))
        self.core = core
        let port = PortUtility.freePort()
        try core.start(
            upstreamHost: "127.0.0.1",
            upstreamPort: upstream.port,
            listenPort: port,
            bindHost: "127.0.0.1",
            identity: nil
        )
        try await Task.sleep(nanoseconds: 300_000_000)

        let plain = curl(["-s", "-H", "X-Chroma-Token: \(key)", "http://127.0.0.1:\(port)/api/v2/heartbeat"])
        XCTAssertEqual(plain.code, 0, plain.output)
        XCTAssertTrue(plain.output.contains("ok"))

        // А https на том же порту не отвечает: подмены протокола не происходит.
        let https = curl(["-s", "-k", "--max-time", "5", "https://127.0.0.1:\(port)/api/v2/heartbeat"])
        XCTAssertNotEqual(https.code, 0, "открытый порт не должен притворяться шифрованным")
    }

    func testSchemeFollowsTheMode() {
        XCTAssertEqual(ProxyServer.TLSMode.tls.scheme, "https")
        XCTAssertEqual(ProxyServer.TLSMode.plain.scheme, "http")
    }
}

/// Минимальный HTTP-сервер вместо ChromaDB: прокси должен получить ответ,
/// который можно узнать, а поднимать ради этого настоящий движок незачем.
final class StubUpstream: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "stub-upstream")
    let port: Int

    init(body: String) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        var assigned = 0

        listener.stateUpdateHandler = { [listener] state in
            if case .ready = state {
                assigned = Int(listener.port?.rawValue ?? 0)
                ready.signal()
            }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: DispatchQueue(label: "stub-connection"))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard assigned > 0 else { throw XCTSkip("заглушка upstream не поднялась") }
        port = assigned
    }

    func stop() { listener.cancel() }
}
