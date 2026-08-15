import XCTest
@testable import ChromaCore

/// Definition of Done пункта C1 целиком, на живой системе.
///
/// Модульные и сквозные тесты рядом проверяют шифрование против заглушки —
/// этого достаточно, чтобы поймать поломку. Здесь проверяется другое: работает
/// ли **тот самый пример**, который приложение выдаёт человеку вместе с ключом.
/// Настоящий движок, настоящий прокси, настоящий клиент `chromadb` на Python.
/// Заглушка такого не покажет: клиент делает рукопожатие с сервером, которого
/// у заглушки нет.
///
///     CHROMA_IT=1 swift test --filter TLSIntegrationTests
final class TLSIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CHROMA_IT"] == "1",
            "живая проверка включается CHROMA_IT=1"
        )
        try XCTSkipIf(ToolLocator().locate("chroma") == nil, "движок ChromaDB не установлен")
    }

    private static let logsDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cdbm-tls-it-\(UUID().uuidString)")

    override class func tearDown() {
        try? FileManager.default.removeItem(at: logsDirectory)
        super.tearDown()
    }

    /// Python из окружения приложения — там установлен клиент `chromadb`.
    private func pythonWithChromaDB() throws -> URL {
        let candidates = [AppPaths.venvPython, URL(fileURLWithPath: "/usr/bin/python3")]
        for python in candidates where FileManager.default.isExecutableFile(atPath: python.path) {
            let check = run(python, ["-c", "import chromadb"])
            if check.code == 0 { return python }
        }
        throw XCTSkip("клиент chromadb на Python не установлен — проверять пример нечем")
    }

    @discardableResult
    private func run(_ executable: URL, _ arguments: [String]) -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    @MainActor
    func testTheExampleWeHandOutActuallyWorks() async throws {
        let python = try pythonWithChromaDB()

        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-tls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        // 1. Настоящий движок на петле — как в жизни: наружу его не выпускают.
        let manager = ChromaProcessManager(serverLog: ServerLogStore(directory: Self.logsDirectory, keepRuns: 50))
        let endpoint = try await manager.start(
            ServerLaunchConfiguration(
                label: "tls-integration",
                databasePath: workspace.appendingPathComponent("db"),
                host: "127.0.0.1",
                port: PortUtility.freePort(),
                allowReset: false
            )
        )
        defer { if let pid = manager.state.pid { kill(pid, SIGTERM) } }

        // 2. Сертификат и прокси перед ним.
        let certificates = TLSCertificateService(
            tag: "io.github.chromadbmanager.tests.\(UUID().uuidString)",
            label: "ChromaDB Manager (живая проверка)",
            file: workspace.appendingPathComponent("certificate.der")
        )
        defer { certificates.remove() }
        let issued: TLSCertificateInfo
        do {
            issued = try certificates.issue(hosts: ["localhost", "127.0.0.1"])
        } catch {
            throw XCTSkip("Keychain недоступен: \(error.localizedDescription)")
        }

        // Коллекция заводится напрямую в движке, а каталог отдаётся прокси:
        // права он проверяет по именам, а в запросе приходит идентификатор,
        // и без каталога любой запрос к данным — отказ.
        let direct = ChromaClient(endpoint: endpoint)
        _ = try await direct.connect()
        let collection = try await direct.createCollection(
            name: "tls_demo",
            metadata: [CollectionBindingKeys.model: .string("test-model"), CollectionBindingKeys.dimension: .int(4)],
            getOrCreate: true
        )

        let key = "live-check-\(UUID().uuidString.prefix(8))"
        let access = AccessController()
        await access.setCatalog([CollectionSnapshot(id: collection.id, name: "tls_demo", dimension: 4)])
        await access.setClients([
            ExternalClient(
                name: "живая проверка",
                keyHash: ClientKey.hash(key),
                keyPrefix: ClientKey.prefix(of: key),
                permissions: ClientPermissions(collections: ["tls_demo"], allowsWrite: true)
            ),
        ])

        let audit = AuditLog(fileURL: workspace.appendingPathComponent("audit.jsonl"))
        let core = ProxyCore(audit: audit, access: access)
        defer { core.stop() }
        let proxyPort = PortUtility.freePort()
        try core.start(
            upstreamHost: endpoint.host,
            upstreamPort: endpoint.port,
            listenPort: proxyPort,
            bindHost: "127.0.0.1",
            identity: try certificates.identity()
        )
        try await Task.sleep(nanoseconds: 500_000_000)

        let pem = workspace.appendingPathComponent("chromadb-manager.pem")
        try certificates.export(to: pem)

        // 3. Тот самый пример из карточки клиента — слово в слово по смыслу.
        let script = workspace.appendingPathComponent("client.py")
        try """
        import httpx
        import chromadb
        from chromadb.config import Settings

        # Сначала — сам канал: доверяет ли ему httpx с нашим файлом. Если нет,
        # виноват сертификат; если да, а клиент всё равно не идёт — виноват
        # способ передать файл клиенту.
        raw = httpx.get(
            "https://127.0.0.1:\(proxyPort)/api/v2/heartbeat",
            headers={"X-Chroma-Token": "\(key)"},
            verify="\(pem.path)",
        )
        print("КАНАЛ", raw.status_code)

        client = chromadb.HttpClient(
            host="127.0.0.1", port=\(proxyPort), ssl=True,
            headers={"X-Chroma-Token": "\(key)"},
            settings=Settings(chroma_server_ssl_verify="\(pem.path)"),
        )
        collection = client.get_collection("tls_demo")
        collection.upsert(ids=["a"], documents=["зашифровано"], embeddings=[[0.1, 0.2, 0.3, 0.4]])
        print("ЕСТЬ", collection.count())
        """.write(to: script, atomically: true, encoding: .utf8)

        let trusting = run(python, [script.path])
        XCTAssertEqual(trusting.code, 0, "клиент с сертификатом обязан работать, а вывод был:\n\(trusting.output)")
        // Две проверки, а не одна: первая отвечает «сертификат в порядке»,
        // вторая — «клиент настроен верно». Разделение не теоретическое:
        // именно оно показало, что дело было в самом сертификате, а не
        // в способе передать его клиенту.
        XCTAssertTrue(trusting.output.contains("КАНАЛ 200"), "канал не доверенный:\n\(trusting.output)")
        XCTAssertTrue(trusting.output.contains("ЕСТЬ 1"), trusting.output)

        // 4. Тот же клиент без сертификата: должен получить ошибку TLS,
        //    а не пройти молча. Это и есть вторая половина DoD.
        let blind = workspace.appendingPathComponent("blind.py")
        try """
        import chromadb
        # Клиент проверяет соединение уже в конструкторе, поэтому под защитой
        # обязано быть и создание — иначе «отказ» вылетит мимо ловушки
        # и будет выглядеть падением проверки, а не её результатом.
        try:
            client = chromadb.HttpClient(
                host="127.0.0.1", port=\(proxyPort), ssl=True,
                headers={"X-Chroma-Token": "\(key)"},
            )
            client.heartbeat()
            print("ПРОШЁЛ")
        except Exception as error:
            print("ОТКАЗ", type(error).__name__, str(error)[:160])
        """.write(to: blind, atomically: true, encoding: .utf8)

        let untrusting = run(python, [blind.path])
        XCTAssertFalse(untrusting.output.contains("ПРОШЁЛ"), "недоверяющий клиент прошёл — это провал пункта")
        XCTAssertTrue(untrusting.output.contains("ОТКАЗ"), untrusting.output)

        // 5. Отпечаток в приложении = отпечаток, который видит клиент.
        let seen = run(URL(fileURLWithPath: "/bin/sh"), ["-c", """
        /usr/bin/openssl s_client -connect 127.0.0.1:\(proxyPort) -servername localhost </dev/null 2>/dev/null \
        | /usr/bin/openssl x509 -noout -fingerprint -sha256
        """])
        let fingerprint = seen.output.split(separator: "=").last?.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(fingerprint, issued.fingerprint)
    }
}
