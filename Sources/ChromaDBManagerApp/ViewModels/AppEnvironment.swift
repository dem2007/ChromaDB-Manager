import Foundation
import Combine
import SwiftUI
import ChromaCore

/// Root object of the app: owns the service layer, the current ChromaDB
/// connection and the shared state every screen reads.
@MainActor
final class AppEnvironment: ObservableObject {
    // Services
    let log: LogStore
    let settings: SettingsStore
    let schemaStore: SchemaStore
    let inspector: EnvironmentInspector
    let installer: InstallationService
    let backupService: BackupService
    let syncService: SourceSyncService
    /// Обход и загрузка веб-источников. Отдельно от синхронизации: она
    /// одна и та же для файлов и для страниц, а вот берутся они по-разному.
    let webSync: WebSyncService
    /// Разговор с git о репозиториях-источниках.
    let gitSync: GitSyncService
    let reembeddingService: ReembeddingService
    let metrics: MetricsStore
    /// Measured model speeds: what makes a time estimate possible
    /// before a model has ever done real work.
    let benchmarks: BenchmarkStore
    let importService: DocumentImportService
    let savedFilters: SavedFilterStore
    /// Pipeline settings per collection. Not data: changing one costs
    /// nothing and requires no re-embedding.
    let searchProfiles: SearchProfileStore
    /// Every query that was run. Local, never written into the database:
    /// what somebody searched for is about the person, not the collection.
    let queryHistory: QueryHistoryStore
    /// Наборы запросов стенда оценки. Живут отдельно от коллекций:
    /// один набор прогоняется по нескольким вариантам.
    let querySets: QuerySetStore
    /// Прогоны стенда оценки — по файлу на прогон: в прогоне лежит вся
    /// выдача всех вариантов.
    let evaluationRuns: EvaluationRunStore
    /// оценки чат-модели, отдельно от прогонов и от эталона.
    let modelJudgements: JudgementStore
    /// Whether a collection has two levels of chunks. Asked once per
    /// collection and kept, so the two point queries do not repeat on every
    /// search.
    let collectionShapes: CollectionShapeCache
    let maintenance: MaintenanceService
    let dataWipe: DataWipeService
    let processManager: ChromaProcessManager
    let bindingService: ModelBindingService
    /// Измеренные пределы чтения моделей: переживают перезапуск,
    /// потому что проба стоит вызовов модели.
    let embeddingLimits = EmbeddingLimitStore()
    let audit: AuditLog
    /// documents and collections deleted from the UI, kept as a local
    /// backup so a manual delete is reversible.
    let trash: TrashService
    let proxy: ProxyServer
    /// Сертификат, которым прокси закрывает трафик. Отдельная служба,
    /// а не поле прокси: сертификат живёт дольше запуска, его показывают
    /// и экспортируют при остановленном прокси.
    let tlsCertificates = TLSCertificateService()

    /// Снимок того, что нужно экрану «Безопасность»: сертификат и адреса
    /// машины в сети.
    ///
    /// Именно снимок, а не чтение по требованию. `securityAssessment` —
    /// вычисляемое свойство, и экран обращается к нему по десятку раз за
    /// отрисовку; читать ради каждого обращения файл с диска, разбирать DER
    /// и обходить сетевые интерфейсы на главном потоке — это ровно та беда,
    /// которую разбирали и.
    @Published private(set) var certificateSnapshot: TLSCertificateInfo?
    @Published private(set) var localAddressesSnapshot: [String] = []
    let notifier: Notifier
    let keychain = KeychainStore()
    /// Passwords for individual protected documents — its own Keychain
    /// service, so wiping server tokens does not take document passwords with it.
    let documentPasswords = DocumentPasswordStore()
    /// Row-level manifests for table sources — kept apart from the file
    /// manifests, which answer a different question.
    let tableManifests = TableManifestStore()
    /// Vectors already computed, so the local model is not asked twice.
    /// измеренное «символов на токен» по моделям, общее на приложение.
    let tokenRatios = TokenRatioStore()
    let embeddingCache: EmbeddingCache
    /// The single owner of long work. Everything that takes minutes goes
    /// through it; nothing starts around it.
    let queue: TaskQueue

    /// Handler handed to every service so they can log without importing SwiftUI.
    let logHandler: LogHandler

    // Shared state
    /// Просмотрщик исходника для отдельного окна, которое открывает
    /// быстрый поиск из строки меню. Экраны коллекций и оценки держат
    /// свои — там просмотр показывается листом поверх экрана.
    let documentViewer = DocumentViewerViewModel()

    /// Сводка последней синхронизации — её показывает значок в строке меню
    ///. Здесь, а не в модели экрана источников: строка меню живёт и
    /// тогда, когда этот экран не открывали ни разу.
    @Published var lastSyncSummary: String?

    /// Отметка «состав коллекций мог измениться».
    ///
    /// Синхронизация источника создаёт коллекции и меняет числа документов
    /// в них, а экран коллекций держит свой список и сам об этом не узнаёт.
    /// Раньше рядом со сводкой на экране источников стояла кнопка «Обновить
    /// список коллекций» — она обновляла список **другого экрана**, поэтому
    /// нажатие выглядело так, будто ничего не произошло.
    ///
    /// Счётчик, а не ссылка на модель экрана: экран коллекций может быть
    /// не открыт вовсе, и знать о нём синхронизации незачем.
    @Published private(set) var collectionsRevision = 0

    /// Сказать экранам, что список коллекций устарел.
    func collectionsMayHaveChanged() { collectionsRevision += 1 }

    /// Что показать в главном окне по требованию извне: из строки меню,
    /// из «Служб» или из интента. Окно разбирает это и обнуляет.
    @Published var pendingRequest: ExternalRequest?

    @Published var environmentStatus = EnvironmentStatus()
    @Published var connection: ConnectionState = .disconnected
    /// What the server said about how much fits in one write request, asked
    /// once at connection time and shown on the connection card.
    @Published var writeLimits: WriteLimits?
    /// The address of a connection that failed on a missing tenant/database —
    /// what «создать?» would create it against.
    @Published var pendingEndpoint: ChromaEndpoint?
    /// Set when a connection failed only because the database is missing.
    @Published var missingDatabase: (tenant: String, database: String)?
    @Published private(set) var client: ChromaClient?
    /// Where the current connection points. The proxy forwards here, and for a
    /// local database this port changes on every start.
    @Published private(set) var endpoint: ChromaEndpoint?
    @Published var lastError: String?
    /// What the queue is doing right now — the one place the screens read from
    ///. Progress and cancellation live here, not in the view models.
    ///
    /// **Обычным `let`, а не `@Published`.** Очередь сообщает о прогрессе
    /// четыре раза в секунду, а `AppEnvironment` наблюдают все двадцать
    /// экранов: публикуй он очередь у себя — и каждая длительная операция
    /// перестраивала бы весь открытый экран четырежды в секунду. Подробности
    /// и родословная этого дефекта — в `QueueMirror`.
    let queueMirror = QueueMirror()
    /// Identifies the current connection so its tasks can be dropped with it.
    @Published private(set) var connectionID: UUID?

    /// Подписка, которой общие профили таблиц доезжают до службы
    /// синхронизации. Держится здесь, потому что живёт столько же,
    /// сколько само окружение.
    private var sharedTableProfilesWatch: AnyCancellable?

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected(address: String, serverVersion: String, isLocalDatabase: Bool, isReadOnly: Bool)
        case failed(String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }

        /// shown permanently next to the connection, not hidden in a profile.
        var isReadOnly: Bool {
            if case .connected(_, _, _, let readOnly) = self { return readOnly }
            return false
        }

        var title: String {
            switch self {
            case .disconnected: return String(localized: "Нет подключения")
            case .connecting: return String(localized: "Подключение…")
            case .connected(let address, let version, let isLocal, _):
                return isLocal
                    // `/api/v2/version` returns the API version (1.0.0 on a
                    // 1.4.4 server), so it must not be labelled as the engine's.
                    ? String(localized: "Локальная база · API ChromaDB \(version)")
                    : "\(address) · API ChromaDB \(version)"
            case .failed(let message): return String(localized: "Ошибка: \(message)")
            }
        }

        var symbol: String {
            switch self {
            case .disconnected: return "⚪️"
            case .connecting: return "⏳"
            case .connected: return "🟢"
            case .failed: return "🔴"
            }
        }
    }

    init() {
        // Retention has to be known before the first line is written, so the
        // configuration is read here rather than injected later.
        let retention = (SettingsStore.load(from: AppPaths.configFile) ?? AppConfiguration()).logRetention
        let store = LogStore(retention: retention)
        let handler: LogHandler = { level, category, message in
            store.record(level, category, message)
        }
        self.log = store
        self.logHandler = handler
        self.settings = SettingsStore(log: handler)
        self.schemaStore = SchemaStore(log: handler)
        self.inspector = EnvironmentInspector(log: handler)
        self.installer = InstallationService(log: handler)
        self.backupService = BackupService(log: handler)
        let metricsStore = MetricsStore(log: handler)
        self.metrics = metricsStore
        self.benchmarks = BenchmarkStore(log: handler)
        self.syncService = SourceSyncService(metrics: metricsStore, log: handler)
        self.gitSync = GitSyncService(registry: .standard(log: handler), log: handler)
        self.webSync = WebSyncService(
            registry: .standard(log: handler),
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            log: handler
        )
        self.reembeddingService = ReembeddingService(metrics: metricsStore, log: handler)
        self.importService = DocumentImportService(log: handler)
        self.savedFilters = SavedFilterStore(log: handler)
        self.searchProfiles = SearchProfileStore(log: handler)
        self.collectionShapes = CollectionShapeCache(log: handler)
        self.queryHistory = QueryHistoryStore(log: handler)
        self.querySets = QuerySetStore(log: handler)
        self.evaluationRuns = EvaluationRunStore(log: handler)
        self.modelJudgements = JudgementStore(log: handler)
        self.maintenance = MaintenanceService(log: handler)
        self.dataWipe = DataWipeService(log: handler)
        self.processManager = ChromaProcessManager(log: handler)
        self.bindingService = ModelBindingService(log: handler, limits: embeddingLimits)
        let auditLog = AuditLog(maximumFileBytes: retention.bytesPerFile, log: handler)
        self.audit = auditLog
        self.proxy = ProxyServer(audit: auditLog, log: handler)
        self.notifier = Notifier(log: handler)
        let configuration = SettingsStore.load(from: AppPaths.configFile) ?? AppConfiguration()
        self.trash = TrashService(
            retentionDays: configuration.trashRetentionDays,
            limitBytes: configuration.trashLimitBytes,
            log: handler
        )
        let cache = EmbeddingCache(limitBytes: configuration.embeddingCacheLimitBytes, log: handler)
        self.embeddingCache = cache
        let queue = TaskQueue(log: handler)
        self.queue = queue
        Task { await cache.open() }
        // The switch is remembered, but permission is not: macOS may have been
        // revoked since, and `post` checks availability before it posts.
        notifier.isEnabled = settings.configuration.notificationsEnabled

        // Общие профили сопоставления таблиц живут в настройках, а нужны
        // фоновой службе синхронизации. Подпиской, а не вызовом
        // из экрана: настройки меняются многими путями — правка на экране
        // «Таблицы», перенос настроек H6, откат к прежней копии, — и один
        // забытый вызов означал бы источник, который молча читается
        // вчерашней разметкой. Первое значение приходит сразу при подписке.
        let sync = syncService
        sharedTableProfilesWatch = settings.$configuration
            .map(\.sharedTableProfiles)
            .removeDuplicates()
            .sink { profiles in
                Task { await sync.adopt(sharedTableProfiles: profiles) }
            }

        // The proxy checks permissions against collection names and vector
        // sizes, and only the app has a ChromaDB client to ask for them.
        let access = proxy.access
        Task {
            await access.setCatalogLoader { [weak self] in
                await self?.collectionSnapshots() ?? []
            }
        }
        proxy.onClientSeen = { [weak self] id in
            Task { @MainActor [weak self] in self?.noteClientSeen(id) }
        }
        proxy.onRejection = { [weak self] client, reason in
            Task { @MainActor [weak self] in
                self?.notifier.post(.accessDenied(client: client, reason: reason))
            }
        }
        Task { [weak self] in
            // Обработчик очередь хранит у себя надолго, поэтому ссылка в нём
            // слабая — но берётся она от неизменяемой связки, а не от
            // захваченной переменной: чтение чужой переменной из параллельно
            // исполняемого кода — это гонка.
            let owner = self
            await queue.setChangeHandler { snapshot in
                Task { @MainActor [weak owner] in owner?.queueMirror.update(tasks: snapshot) }
            }
            await queue.loadResumable()
            let pending = await queue.resumable
            await MainActor.run { [weak self] in self?.queueMirror.update(resumable: pending) }
        }
        processManager.onUnexpectedExit = { [weak self] failure, status in
            self?.notifier.post(.serverFailed(
                failure?.message ?? String(localized: "Процесс chroma завершился с кодом \(status.plainDigits).")
            ))
        }
    }

    // MARK: - Access rules

    /// Hands the current registry to the proxy. Called after every change to
    /// the list, so a revoked key stops working immediately rather than after
    /// a restart.
    func refreshAccessRules() {
        let clients = settings.configuration.externalClients
        Task { await proxy.access.setClients(clients) }
    }

    // MARK: - Proxy

    /// Starts the proxy in front of the current connection. Lives here rather
    /// than on a screen because two screens ask for it — «Сервер» starts it,
    /// «Безопасность» restarts it after the exposure switch — and two copies
    /// would eventually disagree about which port and which address.
    func startProxy() throws {
        guard let endpoint else { throw ProxyServer.ProxyError.notConnected }
        // Сертификат выпускается по факту запуска, а не заранее: до первого
        // запуска прокси он никому не нужен, а ключ в Keychain, созданный
        // «на всякий случай», — лишняя запись в чужой связке.
        var identity: SecIdentity?
        if settings.configuration.proxyUsesTLS {
            do {
                try tlsCertificates.ensure()
                identity = try tlsCertificates.identity()
            } catch {
                logHandler(.error, "Прокси", "TLS не включился: \(describe(error))")
                throw ProxyServer.ProxyError.tlsUnavailable
            }
        }
        try proxy.start(
            upstreamHost: endpoint.host,
            upstreamPort: endpoint.port,
            listenPort: settings.configuration.proxyPort,
            exposure: settings.configuration.proxyExposure,
            identity: identity
        )
        // Сертификат мог только что появиться, а адрес машины — смениться
        // с прошлого запуска.
        refreshSecuritySnapshot()
    }

    // MARK: - Security

    /// What the «Безопасность» screen shows. Only servers this app started are
    /// judged: someone else's instance is not ours to bind, and the proxy
    /// refuses to be opened in front of one anyway.
    /// Обновляет снимок. Дёшево и явно: вызывается там, где эти сведения
    /// действительно могли измениться, — при запуске прокси, при выпуске
    /// сертификата и при открытии экрана.
    func refreshSecuritySnapshot() {
        certificateSnapshot = tlsCertificates.current()
        localAddressesSnapshot = LocalNetwork.addresses()
    }

    var securityAssessment: SecurityAssessment {
        SecurityAssessment(
            exposure: settings.configuration.proxyExposure,
            proxyIsRunning: proxy.state.isRunning,
            proxyPort: settings.configuration.proxyPort,
            serverIsRunning: processManager.isRunning,
            serverHost: processManager.isRunning ? processManager.endpoint?.host : nil,
            serverPort: processManager.isRunning ? processManager.endpoint?.port : nil,
            clients: settings.configuration.externalClients,
            proxyUptime: proxy.startedAt.map { Date().timeIntervalSince($0) },
            sawExternalRequest: proxy.sawExternalRequest,
            usesTLS: settings.configuration.proxyUsesTLS,
            certificate: certificateSnapshot,
            localAddresses: localAddressesSnapshot,
            runningWithTLS: proxy.state.isRunning ? proxy.tls == .tls : nil
        )
    }

    /// Everything off, every key dead, in one action.
    ///
    /// Order is the point. The listener goes first, so nothing new gets in
    /// while the rest happens; the keys are revoked and written to disk before
    /// the server is stopped, because a crash halfway through must not leave
    /// working keys behind; the exposure setting goes back to loopback, so the
    /// next start is not open to the network by accident.
    @discardableResult
    func emergencyStop() async -> Int {
        proxy.stop()

        let revoked = settings.configuration.revokeAllKeys()
        settings.configuration.proxyExposure = .loopback
        settings.saveNow()
        // Awaited, not fire-and-forget: after this line no key in the registry
        // matches anything.
        await proxy.access.setClients(settings.configuration.externalClients)

        await disconnect()

        log.record(.warning, "Безопасность", "Экстренная остановка: сервер и прокси остановлены, отозвано ключей: \(revoked.plainDigits)")
        notifier.post(.emergencyStop(revokedKeys: revoked))
        return revoked
    }

    func collectionSnapshots() async -> [CollectionSnapshot] {
        guard let client else { return [] }
        guard let collections = try? await client.listCollections() else { return [] }
        return collections.map {
            CollectionSnapshot(id: $0.id, name: $0.name, dimension: $0.effectiveDimension)
        }
    }

    /// «Последняя активность» in the client list.
    ///
    /// Не `private`: отмечает не только прокси, но и MCP-сервер —
    /// ключ, которым агент только что искал, обязан перестать выглядеть
    /// «ещё не подключался».
    func noteClientSeen(_ id: UUID) {
        guard let client = settings.configuration.client(id: id) else { return }
        // Writing on every request would rewrite the config file constantly.
        guard Date().timeIntervalSince(client.lastSeenAt ?? .distantPast) > 30 else { return }
        settings.configuration.updateClient(id: id) { $0.lastSeenAt = Date() }
    }

    // MARK: - Environment

    func refreshEnvironment(checkUpdates: Bool? = nil) async {
        let shouldCheck = checkUpdates ?? settings.configuration.checkUpdatesAutomatically
        environmentStatus = await inspector.probe(
            preferredPython: settings.configuration.preferredPythonPath,
            checkUpdates: shouldCheck
        )
    }

    // MARK: - Connection

    var localDatabaseURL: URL {
        if let path = settings.configuration.localDatabasePath, !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return AppPaths.defaultEmbeddedDatabase
    }

    /// Servers left running by a previous session (usually after a crash).
    func refreshOrphans() {
        processManager.refreshOrphans()
    }

    func connect() async {
        connection = .connecting
        lastError = nil

        do {
            let endpoint: ChromaEndpoint
            let isLocal: Bool
            let readOnly: Bool
            switch settings.configuration.mode {
            case .localDatabase:
                endpoint = try await startLocalDatabase()
                isLocal = true
                readOnly = settings.configuration.localDatabaseIsReadOnly
            case .server:
                guard let profile = settings.activeProfile else { throw ChromaError.notConfigured }
                endpoint = try await connectToProfile(profile)
                isLocal = false
                readOnly = profile.isReadOnly
            }

            // the flag belongs to the client and cannot change afterwards —
            // taking it off means connecting again (A10).
            let client = ChromaClient(
                endpoint: endpoint,
                log: logHandler,
                timeouts: settings.configuration.timeouts,
                isReadOnly: readOnly
            )
            let info = try await client.connect()
            // A tenant or database that is not there answers «200 []» to a
            // collection listing, so a typo would look like an empty database
            //. Asked explicitly, and only for non-default names — the
            // defaults always exist.
            if endpoint.tenant != ChromaEndpoint.defaultTenant || endpoint.database != ChromaEndpoint.defaultDatabase {
                pendingEndpoint = endpoint
                try await client.verifyTenantAndDatabase()
            }
            pendingEndpoint = nil
            self.client = client
            self.endpoint = endpoint
            self.connectionID = UUID()
            // A different connection may be a different database entirely, and
            // an id that means one thing there means another here.
            Task { await collectionShapes.reset() }
            refreshAccessRules()
            Task { await proxy.access.refreshCatalog() }
            connection = .connected(
                address: endpoint.baseURLString,
                serverVersion: info.version.isEmpty ? "?" : info.version,
                isLocalDatabase: isLocal,
                isReadOnly: readOnly
            )
            if readOnly {
                log.record(.warning, "Подключение", "Подключение открыто только для чтения — любая запись будет отклонена")
            }
            writeLimits = await client.writeLimits()
        } catch {
            client = nil
            endpoint = nil
            writeLimits = nil
            if case ChromaError.databaseNotFound(let database, let tenant) = error {
                // Not a dead end: the screen offers to create it.
                missingDatabase = (tenant: tenant, database: database)
            }
            connection = .failed(error.localizedDescription)
            lastError = describe(error)
            log.record(.error, "Подключение", describe(error))
        }
    }

    func disconnect() async {
        // the tasks of this connection hold a client that is about to be
        // released — they go before it does.
        if let connectionID {
            await queue.cancelTasks(connectionID: connectionID)
        }
        connectionID = nil
        client = nil
        endpoint = nil
        writeLimits = nil
        // The proxy forwards to a port that is about to disappear — a local
        // database gets a new one on every start.
        proxy.stop()
        if processManager.isRunning {
            await processManager.stop()
        }
        connection = .disconnected
        log.record(.info, "Подключение", "Отключено")
    }

    func reconnect() async {
        await disconnect()
        await connect()
    }

    /// A local database is a directory; the private loopback server that backs
    /// it is an implementation detail the user never configures.
    private func startLocalDatabase() async throws -> ChromaEndpoint {
        let path = localDatabaseURL
        try AppPaths.ensureDirectory(path)

        // Reuse a server left over from a previous session for the same folder
        // instead of fighting it for the SQLite file.
        if let orphan = processManager.orphans.first(where: { $0.path == path.path }),
           let adopted = processManager.adoptOrphan(orphan) {
            return adopted
        }

        let port = PortUtility.freePort()
        log.record(.info, "Подключение", "Локальная база \(path.path): приватный сервер на 127.0.0.1:\(port)")
        return try await processManager.start(
            ServerLaunchConfiguration(
                label: "Локальная база",
                databasePath: path,
                host: "127.0.0.1",
                port: port,
                allowReset: true
            )
        )
    }

    private func connectToProfile(_ profile: ServerProfile) async throws -> ChromaEndpoint {
        let endpoint = profile.endpoint(with: token(for: profile))

        let probe = ChromaClient(endpoint: endpoint, log: { _, _, _ in }, timeouts: settings.configuration.timeouts)
        if (try? await probe.healthcheck()) != nil {
            log.record(.info, "Подключение", "Сервер \(profile.displayAddress) уже запущен")
            return endpoint
        }

        guard profile.kind == .managed, let configuration = profile.launchConfiguration() else {
            throw ChromaError.unreachable(
                endpoint: profile.displayAddress,
                reason: String(localized: "сервер не отвечает")
            )
        }

        log.record(.info, "Подключение", "Сервер \(profile.displayAddress) не отвечает — запускаем его")
        _ = try await processManager.start(configuration)
        return endpoint
    }

    // MARK: - Secrets

    func token(for profile: ServerProfile) -> String? {
        let value = try? keychain.token(for: profile.keychainAccount)
        SecretRegistry.shared.register(value ?? nil)
        return value ?? nil
    }

    func setToken(_ token: String, for profile: ServerProfile) {
        do {
            try keychain.set(token, for: profile.keychainAccount)
            SecretRegistry.shared.register(token)
            log.record(.info, "Подключение", "Токен профиля «\(profile.name)» сохранён в Keychain")
        } catch {
            report(error, category: "Подключение")
        }
    }

    // MARK: - LM Studio

    /// Every client gets the same cache instance: it is keyed by model and text,
    /// so sharing it is the entire point.
    func makeLMStudioClient() throws -> LMStudioClient {
        try LMStudioClient(
            baseURLString: settings.configuration.lmStudioBaseURL,
            log: logHandler,
            timeouts: settings.configuration.timeouts,
            cache: settings.configuration.embeddingCacheEnabled ? embeddingCache : nil,
            // Одно на приложение: клиент создаётся заново на каждую операцию,
            // и измерение, положенное в него, не пережило бы ни одного
            // запроса.
            ratios: tokenRatios
        )
    }

    // MARK: - Long operations

    struct LongOperation: Identifiable, Equatable {
        let id: UUID
        let title: String
    }

    /// What must not be killed by simply quitting. Read from the queue:
    /// it knows what is running and how to stop it properly, so «выйти» can
    /// cancel instead of pulling the process out from under a half-written
    /// collection.
    var longOperations: [LongOperation] {
        queueMirror.tasks.filter { $0.state == .running }.map { LongOperation(id: $0.id, title: $0.title) }
    }

    func cancelLongOperations() {
        let running = longOperations
        guard !running.isEmpty else { return }
        log.record(.warning, "Приложение", "Долгие операции прерваны по запросу выхода: \(running.map(\.title).joined(separator: ", "))")
        Task { [queue] in
            for operation in running { await queue.cancel(id: operation.id) }
        }
    }

    // MARK: - Queue

    func cancelTask(_ id: UUID) {
        Task { [queue] in await queue.cancel(id: id) }
    }

    func setQueuePaused(_ paused: Bool) {
        Task { [queue] in await queue.setPaused(paused) }
    }

    func forgetResumable(_ request: ResumableRequest) {
        queueMirror.update(resumable: queueMirror.resumableRequests.filter { $0 != request })
        Task { [queue] in await queue.forgetResumable(request) }
    }

    // MARK: - Errors

    /// Includes the recovery suggestion, which is where the useful half of a
    /// typed error usually lives.
    func describe(_ error: Error) -> String {
        let localized = (error as? LocalizedError)
        let message = localized?.errorDescription ?? error.localizedDescription
        if let suggestion = localized?.recoverySuggestion {
            return "\(message)\n\(suggestion)"
        }
        return message
    }

    func report(_ error: Error, category: String) {
        let text = describe(error)
        lastError = text
        log.record(.error, category, text)
    }

    /// the outcome of a background operation, offered to Notification
    /// Center. The policy lives in the settings and is consulted here so no
    /// call site has to remember it — a screen that forgot would be a screen
    /// that notifies against the user's choice.
    func notify(_ notice: OperationNotice) {
        notifier.post(notice, policy: settings.configuration.operationNotifications)
    }
}

/// Объекты окружения приложения — одним списком на все окна.
///
/// Сцен у приложения четыре: главное окно, окно просмотра документа, меню в
/// строке меню и панель быстрого поиска по горячей клавише. Каждая из них
/// перечисляла нужные ей объекты сама, и это ровно тот случай, когда
/// «перечислить нужное» невозможно проверить глазами: `@EnvironmentObject`,
/// которого нет, — это не пустое значение, а **падение** при первом обращении
/// к нему, причём только в той сцене, где его забыли.
///
/// Так и вышло: очередь переехала в собственный `QueueMirror`, меню строки
/// меню начало её читать, а окружение сцены осталось прежним — и клик по
/// значку ронял приложение три дня.
///
/// Поэтому список один и общий: вьюха, попавшая в любую сцену, получает всё.
/// За полнотой списка следит `EnvironmentInjectionTests`.
extension View {
    func chromaEnvironment(_ app: AppEnvironment) -> some View {
        self
            .environmentObject(app)
            // Вложенные наблюдаемые объекты подставляются отдельно: вьюха,
            // подписанная только на `AppEnvironment`, не перерисуется, когда
            // изменится настройка, процесс сервера или журнал доступа.
            .environmentObject(app.settings)
            .environmentObject(app.processManager)
            .environmentObject(app.schemaStore)
            .environmentObject(app.audit)
            .environmentObject(app.trash)
            .environmentObject(app.proxy)
            .environmentObject(app.notifier)
            // Очередь — своим объектом: её тики не должны перестраивать
            // экраны, которым до неё дела нет (см. `QueueMirror`).
            .environmentObject(app.queueMirror)
    }
}
