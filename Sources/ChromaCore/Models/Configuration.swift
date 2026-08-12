import Foundation

/// How the app talks to ChromaDB right now.
///
/// Per spec there are exactly two user-facing modes; both go through the
/// same HTTP client, they differ only in who owns the server process.
public enum ConnectionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A directory on disk. The app runs a private loopback server for it and
    /// never says the word "server" to the user in this mode.
    case localDatabase
    /// A named profile: either started by the app or someone else's instance.
    case server

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .localDatabase: return String(localized: "Локальная база")
        case .server: return String(localized: "Сервер")
        }
    }
}

/// Where the engine is installed from.
public enum EngineInstallPath: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Standalone Chroma CLI binary — no Python at all. Default.
    case standalone
    /// `pip install chromadb` into the app-managed virtual environment.
    case managedVenv

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standalone: return String(localized: "Автономный CLI (без Python)")
        case .managedVenv: return String(localized: "Python-пакет в venv приложения")
        }
    }
}

public struct ServerProfile: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Created in the app; we own the process.
        case managed
        /// Someone else's server; we only connect.
        case external
    }

    /// Which header carries the token — ChromaDB accepts either, depending on
    /// how the server was configured.
    public enum TokenHeader: String, Codable, CaseIterable, Identifiable, Sendable {
        case authorizationBearer
        case xChromaToken

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .authorizationBearer: return "Authorization: Bearer"
            case .xChromaToken: return "X-Chroma-Token"
            }
        }
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var host: String
    public var port: Int
    /// Persistence directory — only meaningful for `.managed` profiles.
    public var databasePath: String?
    public var useTLS: Bool
    public var tenant: String
    public var database: String
    /// Written into the generated server config; `/reset` fails without it.
    public var allowReset: Bool
    /// the connection refuses every write, at the client, not in the UI.
    public var isReadOnly: Bool
    public var tokenHeader: TokenHeader
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        kind: Kind,
        host: String = "localhost",
        port: Int = 8000,
        databasePath: String? = nil,
        useTLS: Bool = false,
        tenant: String = ChromaEndpoint.defaultTenant,
        database: String = ChromaEndpoint.defaultDatabase,
        allowReset: Bool = false,
        isReadOnly: Bool = false,
        tokenHeader: TokenHeader = .authorizationBearer,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port
        self.databasePath = databasePath
        self.useTLS = useTLS
        self.tenant = tenant
        self.database = database
        self.allowReset = allowReset
        self.isReadOnly = isReadOnly
        self.tokenHeader = tokenHeader
        self.createdAt = createdAt
    }

    public var endpoint: ChromaEndpoint {
        ChromaEndpoint(host: host, port: port, useTLS: useTLS, tenant: tenant, database: database)
    }

    public var displayAddress: String { endpoint.baseURLString }

    public func launchConfiguration() -> ServerLaunchConfiguration? {
        guard kind == .managed, let databasePath else { return nil }
        return ServerLaunchConfiguration(
            label: name,
            databasePath: URL(fileURLWithPath: databasePath),
            host: host,
            port: port,
            allowReset: allowReset,
            tenant: tenant,
            database: database,
            profileID: id
        )
    }
}

/// What to do when the target collection's schema requires fields the source
/// cannot supply.
public enum UnresolvedSchemaPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Refuse to start — nothing is written until the mismatch is dealt with.
    case block
    /// Index anyway and mark those documents so they can be found later.
    case markAttention

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .block: return String(localized: "Не запускать синхронизацию")
        case .markAttention: return String(localized: "Индексировать и помечать «требуют внимания»")
        }
    }
}

/// A folder registered on the «Эмбеддинги» tab as a source of documents.
public struct DataSource: Identifiable, Codable, Hashable, Sendable {
    /// Столько же, сколько по умолчанию берёт сама подсистема извлечения
    /// (`ExtractionOptions.defaultMaxFileSize`): у синхронизации нет причин
    /// быть строже того, что приложение умеет прочитать.
    public static let defaultMaxFileSizeMB = 50

    /// Kept as a nested name so older code and stored configs keep working;
    /// the cases live in `SourceMapping`.
    public typealias Mapping = SourceMapping

    public var id: UUID
    public var name: String
    public var path: String
    public var fileExtensions: [String]
    public var recursive: Bool
    public var mapping: SourceMapping
    /// Base collection: the target in single-collection modes, and the fallback
    /// for files the mapping cannot place.
    public var collectionName: String
    /// Manual rule: regular expression over the relative path…
    public var rulePattern: String
    /// …and the collection-name template it expands into (`$1`, `$2`, …).
    public var ruleTemplate: String
    /// Whether unmatched files fall back to `collectionName` instead of being skipped.
    public var ruleUsesFallbackCollection: Bool
    public var embeddingModel: String?
    /// Metric for collections this source creates. Immutable once a collection
    /// exists, so changing it here only affects collections made afterwards.
    public var metric: DistanceMetric
    public var chunking: ChunkingConfiguration
    public var customMetadata: [String: String]
    public var unresolvedSchemaPolicy: UnresolvedSchemaPolicy
    /// When this source syncs on its own (substage 2D).
    public var triggers: SyncTriggers
    /// Title, author and dates of the document into every chunk's metadata
    ///. Off by default: it is the user's data model, not ours,
    /// and a field that appears without being asked for is a surprise.
    public var includeDocumentMetadata: Bool
    /// Предел размера файла, мегабайты.
    ///
    /// Был жёсткой константой в 5 МБ с обоснованием «файлы крупнее почти
    /// никогда не проза, которую стоит вкладывать целиком». Обоснование
    /// написано до этапа 4: подсистема извлечения строилась с пределом
    /// в 50 МБ, а синхронизация продолжала передавать ей старое число.
    /// Обычный `.docx` с положением о закупках — 5,2 МБ, и он выпадал
    /// молча-но-в-списке, то есть человек видел «пропущено», а изменить
    /// не мог ничего.
    ///
    /// Настройкой, а не поднятой константой: у кого-то в папке лежат
    /// стомегабайтные сканы, которые незачем читать, а у кого-то —
    /// нормальные документы по 40 МБ.
    public var maxFileSizeMB: Int
    /// Recognise scanned documents. Off by default and only ever turned
    /// on deliberately: OCR is an order of magnitude slower than reading a text
    /// layer, and that is something to learn before a thousand files, not after.
    public var ocrEnabled: Bool
    /// Recognition languages, from what this system actually supports. Empty
    /// means «let Vision decide», which is what it does well for Latin text.
    public var ocrLanguages: [String]
    /// Read `.pages`/`.key` by asking Pages or Keynote to export them.
    /// Off by default: it raises a GUI application and needs an automation
    /// permission the user has to grant.
    public var iWorkExportEnabled: Bool
    /// …and whether that is allowed during **automatic** runs. Separate on
    /// purpose: nobody wants Pages windows opening while they work, which is
    /// exactly what a scheduled run would otherwise do.
    public var iWorkExportInAutomaticRuns: Bool
    /// Files the user told the app to stop trying to read, by path
    /// relative to the source root.
    ///
    /// Not a deletion: a file that was indexed before it was excluded turns up
    /// as «требует решения», the same as a file that vanished from disk, and its
    /// chunks wait for the user's decision (rule 1 of Приложение 5).
    public var excludedPaths: [String]
    /// Saved column mappings for table sources.
    ///
    /// On the source rather than asked per file: a folder that indexes itself on
    /// a timer has nobody to ask which column is the key.
    public var tableProfiles: [TableProfile]
    /// Профиль, назначенный файлу вручную: путь относительно папки источника →
    /// `id` профиля.
    ///
    /// Подбор по набору колонок остаётся и работает сам; назначение — ответ на
    /// случаи, где подбор ответить не может: два профиля с одинаковым набором
    /// колонок и разным смыслом, файл, у которого колонки совпали случайно, или
    /// просто «этот файл читать вот так, и не гадай». Пути тут нет — берётся
    /// подбор, как раньше.
    ///
    /// **Назначение не отменяет проверок.** Если в файле нет колонок, которых
    /// требует профиль, лист по-прежнему уходит в «требуют решения»: правило
    /// файл с другим набором колонок не индексируется наполовину —
    /// действует и для назначенного профиля, потому что оно про молча
    /// пропавшие метаданные, а не про способ выбора профиля.
    public var tableProfileAssignments: [String: UUID]
    /// Whether `.numbers` may be converted by Numbers itself — the same
    /// two switches as Pages and Keynote, and for the same reason: the export
    /// raises a window.
    public var numbersExportEnabled: Bool
    /// Настройки веб-источника. `nil` — это папка на диске, каким
    /// источник и был до этапа 12.
    public var web: WebSourceSettings?
    /// Настройки git-репозитория. Путь остаётся путём к рабочей копии:
    /// репозиторий — это папка, просто про неё есть кому рассказать больше.
    public var git: GitSourceSettings?
    public var lastSyncedAt: Date?

    /// Источник берёт документы из сети, а не с диска.
    public var isWeb: Bool { web != nil }
    /// Источник — рабочая копия git-репозитория.
    public var isGit: Bool { git != nil }

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        fileExtensions: [String] = ["md", "txt"],
        recursive: Bool = true,
        mapping: SourceMapping = .folderToCollection,
        collectionName: String,
        rulePattern: String = "",
        ruleTemplate: String = "$1",
        ruleUsesFallbackCollection: Bool = false,
        embeddingModel: String? = nil,
        metric: DistanceMetric = .cosine,
        chunking: ChunkingConfiguration = ChunkingConfiguration(),
        customMetadata: [String: String] = [:],
        unresolvedSchemaPolicy: UnresolvedSchemaPolicy = .block,
        triggers: SyncTriggers = SyncTriggers(),
        includeDocumentMetadata: Bool = false,
        maxFileSizeMB: Int = DataSource.defaultMaxFileSizeMB,
        ocrEnabled: Bool = false,
        ocrLanguages: [String] = [],
        iWorkExportEnabled: Bool = false,
        iWorkExportInAutomaticRuns: Bool = false,
        excludedPaths: [String] = [],
        tableProfiles: [TableProfile] = [],
        tableProfileAssignments: [String: UUID] = [:],
        numbersExportEnabled: Bool = false,
        web: WebSourceSettings? = nil,
        git: GitSourceSettings? = nil,
        lastSyncedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.fileExtensions = fileExtensions
        self.recursive = recursive
        self.mapping = mapping
        self.collectionName = collectionName
        self.rulePattern = rulePattern
        self.ruleTemplate = ruleTemplate
        self.ruleUsesFallbackCollection = ruleUsesFallbackCollection
        self.embeddingModel = embeddingModel
        self.metric = metric
        self.chunking = chunking
        self.customMetadata = customMetadata
        self.unresolvedSchemaPolicy = unresolvedSchemaPolicy
        self.triggers = triggers
        self.includeDocumentMetadata = includeDocumentMetadata
        self.maxFileSizeMB = maxFileSizeMB
        self.ocrEnabled = ocrEnabled
        self.ocrLanguages = ocrLanguages
        self.iWorkExportEnabled = iWorkExportEnabled
        self.iWorkExportInAutomaticRuns = iWorkExportInAutomaticRuns
        self.excludedPaths = excludedPaths
        self.tableProfiles = tableProfiles
        self.tableProfileAssignments = tableProfileAssignments
        self.numbersExportEnabled = numbersExportEnabled
        self.web = web
        self.git = git
        self.lastSyncedAt = lastSyncedAt
    }

    /// What about *extraction* shapes the stored chunks, as opposed to what
    /// shapes their boundaries.
    ///
    /// Kept apart from `ChunkingConfiguration.signature` on purpose: that one
    /// also feeds the collection-level hash of G6, and a collection does not
    /// become heterogeneous because one source writes an author into its
    /// metadata. This one lives in the manifest, per file, and answers a
    /// narrower question — «would this file be written differently now?»
    public var extractionSignature: String {
        "meta:\(includeDocumentMetadata ? 1 : 0)/ocr:\(ocrEnabled ? 1 : 0)"
            + (ocrEnabled && !ocrLanguages.isEmpty ? "(\(ocrLanguages.sorted().joined(separator: ",")))" : "")
            + "/iwork:\(iWorkExportEnabled ? 1 : 0)"
    }

    /// Tolerant decoding: a source registered by an earlier build has none of
    /// the 2C fields, and must not disappear because of that.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        fileExtensions = try container.decodeIfPresent([String].self, forKey: .fileExtensions) ?? ["md", "txt"]
        recursive = try container.decodeIfPresent(Bool.self, forKey: .recursive) ?? true
        // У источников, записанных до появления настройки, поля нет — и
        // подставляется не старая пятёрка, а нынешний предел: прежнее число
        // было не выбором пользователя, а константой, которую он не мог
        // изменить.
        maxFileSizeMB = max(1, try container.decodeIfPresent(Int.self, forKey: .maxFileSizeMB) ?? DataSource.defaultMaxFileSizeMB)
        mapping = ((try? container.decodeIfPresent(SourceMapping.self, forKey: .mapping)) ?? nil) ?? .folderToCollection
        collectionName = try container.decode(String.self, forKey: .collectionName)
        rulePattern = try container.decodeIfPresent(String.self, forKey: .rulePattern) ?? ""
        ruleTemplate = try container.decodeIfPresent(String.self, forKey: .ruleTemplate) ?? "$1"
        ruleUsesFallbackCollection = try container.decodeIfPresent(Bool.self, forKey: .ruleUsesFallbackCollection) ?? false
        embeddingModel = try container.decodeIfPresent(String.self, forKey: .embeddingModel)
        metric = ((try? container.decodeIfPresent(DistanceMetric.self, forKey: .metric)) ?? nil) ?? .cosine
        chunking = ((try? container.decodeIfPresent(ChunkingConfiguration.self, forKey: .chunking)) ?? nil) ?? ChunkingConfiguration()
        customMetadata = try container.decodeIfPresent([String: String].self, forKey: .customMetadata) ?? [:]
        unresolvedSchemaPolicy = ((try? container.decodeIfPresent(UnresolvedSchemaPolicy.self, forKey: .unresolvedSchemaPolicy)) ?? nil) ?? .block
        triggers = ((try? container.decodeIfPresent(SyncTriggers.self, forKey: .triggers)) ?? nil) ?? SyncTriggers()
        includeDocumentMetadata = try container.decodeIfPresent(Bool.self, forKey: .includeDocumentMetadata) ?? false
        ocrEnabled = try container.decodeIfPresent(Bool.self, forKey: .ocrEnabled) ?? false
        ocrLanguages = try container.decodeIfPresent([String].self, forKey: .ocrLanguages) ?? []
        iWorkExportEnabled = try container.decodeIfPresent(Bool.self, forKey: .iWorkExportEnabled) ?? false
        iWorkExportInAutomaticRuns = try container.decodeIfPresent(Bool.self, forKey: .iWorkExportInAutomaticRuns) ?? false
        excludedPaths = try container.decodeIfPresent([String].self, forKey: .excludedPaths) ?? []
        // `try?`, а не `try`: профили, записанные до (одно сопоставление
        // на профиль вместо вариантов), больше не читаются — так решено, а не
        // забыто. Строгий разбор уронил бы **весь** файл настроек из-за одного
        // устаревшего профиля: источники, серверы, расписания — всё. Профили
        // при этом придётся собрать заново, и об этом сказано в README.
        tableProfiles = (try? container.decodeIfPresent([TableProfile].self, forKey: .tableProfiles)) ?? []
        tableProfileAssignments = try container.decodeIfPresent([String: UUID].self, forKey: .tableProfileAssignments) ?? [:]
        numbersExportEnabled = try container.decodeIfPresent(Bool.self, forKey: .numbersExportEnabled) ?? false
        web = (try? container.decodeIfPresent(WebSourceSettings.self, forKey: .web)) ?? nil
        git = (try? container.decodeIfPresent(GitSourceSettings.self, forKey: .git)) ?? nil
        lastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
    }

    /// Для папки — сама папка; для веб-источника — его стартовый адрес.
    /// Обращаться к нему как к файлу в этом случае нельзя, и `isWeb` —
    /// единственный правильный способ это узнать.
    public var url: URL {
        if let web, let start = web.start { return start }
        return URL(fileURLWithPath: path)
    }
}

/// Everything persisted between launches, except secrets (Keychain).
/// Stored as JSON in `~/Library/Application Support/ChromaDBManager/config.json`.
public struct AppConfiguration: Codable, Sendable {
    public var mode: ConnectionKind
    public var localDatabasePath: String?
    /// J1 for the local database, where there is no profile to carry the flag.
    public var localDatabaseIsReadOnly: Bool
    public var selectedProfileID: UUID?
    public var serverProfiles: [ServerProfile]
    /// Base interpreter used to build the managed venv (path B only).
    public var preferredPythonPath: String?
    public var preferredInstallPath: EngineInstallPath
    /// Update checks hit the network, so they are opt-in.
    public var checkUpdatesAutomatically: Bool
    public var lmStudioBaseURL: String
    public var defaultEmbeddingModel: String?
    /// Manual `embedding` / `chat` tags for LM Studio models, keyed by model id.
    public var modelKindOverrides: [String: String]
    /// Порядок списка коллекций — настройка человека, а не экрана: он
    /// обязан пережить перезапуск.
    public var collectionListOrder: CollectionListOrder
    /// строка меню, быстрый поиск и глобальная горячая клавиша.
    public var menuBar: MenuBarPreferences
    /// Значения k, по которым считаются метрики стенда (D1.3 — «настраивается»).
    /// Хранится как список: «5 и 10 одновременно» — умолчание, а не предел.
    public var evaluationKs: [Int]
    /// оценка выдачи чат-моделью. **Выключено по умолчанию**, как
    /// требует ТЗ: это вызов модели на каждый результат каждого варианта.
    public var modelJudgeEnabled: Bool
    /// Модель, которой оценивать. `nil` — не выбрана, режим не запускается.
    public var modelJudgeModel: String?
    /// Промпт оценки — редактируемый; схема ответа при этом фиксирована.
    public var modelJudgePrompt: JudgePrompt
    public var dataSources: [DataSource]
    /// Global off switch for every automatic sync — for when LM Studio is busy
    /// with something else.
    public var automaticSyncPaused: Bool
    /// Registered external clients. Keys are not here — only their hashes
    /// (see `ExternalClient`).
    public var externalClients: [ExternalClient]
    /// Port the proxy listens on. The real server keeps its own private port
    /// and is never the thing clients talk to.
    public var proxyPort: Int
    /// Whether the app connects (and, for a local database, starts the server)
    /// as soon as it launches. On by default — that is how it behaved before
    /// the switch existed.
    public var autoStartServerOnLaunch: Bool
    /// Which interfaces the proxy is bound to. Loopback unless the
    /// user deliberately opened it, and put back to loopback by the emergency
    /// stop.
    public var proxyExposure: NetworkExposure
    /// Режим «только чтение» на весь MCP-сервер — независимо от прав
    /// отдельных ключей. На случай «пусть агент посмотрит, но ничего
    /// не трогает».
    public var mcpReadOnly: Bool
    /// Notification Center is off until the user turns it on — permission is
    /// asked at that moment, not at launch.
    public var notificationsEnabled: Bool
    /// how much of a finished background operation is worth a
    /// notification. Default «only when there are problems» — automatic
    /// syncing runs on a timer, and a notification per timer tick is how a
    /// user learns to ignore notifications.
    public var operationNotifications: OperationNotificationPolicy
    /// How long each class of call may take.
    /// the cache is on by default; the switch exists because "выключение
    /// не меняет результатов, только скорость" has to be checkable.
    public var embeddingCacheEnabled: Bool
    /// Bytes. Default 2 GB.
    public var embeddingCacheLimitBytes: Int64
    public var timeouts: TimeoutSettings
    /// How much log is kept, on screen and on disk.
    public var logRetention: LogRetention
    /// manual deletions from the UI go through the trash first. On by
    /// default — turning it off is an explicit choice to delete for real.
    public var trashEnabled: Bool
    /// Days a trashed document is kept before the automatic sweep drops it.
    public var trashRetentionDays: Int
    /// Bytes. Oldest entries are evicted first once the trash grows past this.
    public var trashLimitBytes: Int64
    /// a manual sync touching more files than this shows the plan and
    /// waits for confirmation instead of running immediately.
    public var syncPreviewThresholdFiles: Int

    public init(
        mode: ConnectionKind = .localDatabase,
        localDatabasePath: String? = nil,
        localDatabaseIsReadOnly: Bool = false,
        selectedProfileID: UUID? = nil,
        serverProfiles: [ServerProfile] = [],
        preferredPythonPath: String? = nil,
        preferredInstallPath: EngineInstallPath = .standalone,
        checkUpdatesAutomatically: Bool = false,
        lmStudioBaseURL: String = "http://localhost:1234",
        defaultEmbeddingModel: String? = nil,
        modelKindOverrides: [String: String] = [:],
        collectionListOrder: CollectionListOrder = .default,
        menuBar: MenuBarPreferences = MenuBarPreferences(),
        evaluationKs: [Int] = EvaluationMetrics.defaultKs,
        modelJudgeEnabled: Bool = false,
        modelJudgeModel: String? = nil,
        modelJudgePrompt: JudgePrompt = JudgePrompt(),
        dataSources: [DataSource] = [],
        automaticSyncPaused: Bool = false,
        autoStartServerOnLaunch: Bool = true,
        proxyPort: Int = 8900,
        proxyExposure: NetworkExposure = .loopback,
        mcpReadOnly: Bool = false,
        notificationsEnabled: Bool = false,
        operationNotifications: OperationNotificationPolicy = .problemsOnly,
        externalClients: [ExternalClient] = [],
        embeddingCacheEnabled: Bool = true,
        embeddingCacheLimitBytes: Int64 = EmbeddingCache.defaultLimitBytes,
        timeouts: TimeoutSettings = TimeoutSettings(),
        logRetention: LogRetention = LogRetention(),
        trashEnabled: Bool = true,
        trashRetentionDays: Int = TrashService.defaultRetentionDays,
        trashLimitBytes: Int64 = TrashService.defaultLimitBytes,
        syncPreviewThresholdFiles: Int = SourceSyncService.defaultPreviewThresholdFiles
    ) {
        self.mode = mode
        self.localDatabasePath = localDatabasePath
        self.localDatabaseIsReadOnly = localDatabaseIsReadOnly
        self.selectedProfileID = selectedProfileID
        self.serverProfiles = serverProfiles
        self.preferredPythonPath = preferredPythonPath
        self.preferredInstallPath = preferredInstallPath
        self.checkUpdatesAutomatically = checkUpdatesAutomatically
        self.lmStudioBaseURL = lmStudioBaseURL
        self.defaultEmbeddingModel = defaultEmbeddingModel
        self.modelKindOverrides = modelKindOverrides
        self.collectionListOrder = collectionListOrder
        self.menuBar = menuBar
        self.evaluationKs = evaluationKs
        self.modelJudgeEnabled = modelJudgeEnabled
        self.modelJudgeModel = modelJudgeModel
        self.modelJudgePrompt = modelJudgePrompt
        self.dataSources = dataSources
        self.automaticSyncPaused = automaticSyncPaused
        self.autoStartServerOnLaunch = autoStartServerOnLaunch
        self.proxyPort = proxyPort
        self.proxyExposure = proxyExposure
        self.mcpReadOnly = mcpReadOnly
        self.notificationsEnabled = notificationsEnabled
        self.operationNotifications = operationNotifications
        self.externalClients = externalClients
        self.embeddingCacheEnabled = embeddingCacheEnabled
        self.embeddingCacheLimitBytes = embeddingCacheLimitBytes
        self.timeouts = timeouts
        self.logRetention = logRetention
        self.trashEnabled = trashEnabled
        self.trashRetentionDays = trashRetentionDays
        self.trashLimitBytes = trashLimitBytes
        self.syncPreviewThresholdFiles = syncPreviewThresholdFiles
    }

    /// Keeps every element that decodes and drops only the ones that do not.
    ///
    /// The array form of `decodeIfPresent` fails as a unit, which for a list of
    /// the user's own records is the worst possible behaviour: one unreadable
    /// entry and the whole list is gone.
    static func decodeLeniently<T: Decodable, Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) -> [T] {
        if let all = try? container.decodeIfPresent([T].self, forKey: key) { return all }
        guard var unkeyed = try? container.nestedUnkeyedContainer(forKey: key) else { return [] }
        var result: [T] = []
        while !unkeyed.isAtEnd {
            if let element = try? unkeyed.decode(T.self) {
                result.append(element)
            } else {
                // Skip exactly one element and carry on. Without consuming it the
                // loop would never advance.
                _ = try? unkeyed.decode(AnyDecodableSkip.self)
            }
        }
        return result
    }

    /// Tolerant decoding: a config written by an older build must not wipe the
    /// user's profiles just because a key was renamed.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = ((try? container.decodeIfPresent(ConnectionKind.self, forKey: .mode)) ?? nil) ?? .localDatabase
        localDatabasePath = try container.decodeIfPresent(String.self, forKey: .localDatabasePath)
        localDatabaseIsReadOnly = try container.decodeIfPresent(Bool.self, forKey: .localDatabaseIsReadOnly) ?? false
        embeddingCacheEnabled = try container.decodeIfPresent(Bool.self, forKey: .embeddingCacheEnabled) ?? true
        embeddingCacheLimitBytes = try container.decodeIfPresent(Int64.self, forKey: .embeddingCacheLimitBytes) ?? EmbeddingCache.defaultLimitBytes
        selectedProfileID = try container.decodeIfPresent(UUID.self, forKey: .selectedProfileID)
        serverProfiles = AppConfiguration.decodeLeniently(container, forKey: .serverProfiles)
        preferredPythonPath = try container.decodeIfPresent(String.self, forKey: .preferredPythonPath)
        preferredInstallPath = ((try? container.decodeIfPresent(EngineInstallPath.self, forKey: .preferredInstallPath)) ?? nil) ?? .standalone
        checkUpdatesAutomatically = try container.decodeIfPresent(Bool.self, forKey: .checkUpdatesAutomatically) ?? false
        lmStudioBaseURL = try container.decodeIfPresent(String.self, forKey: .lmStudioBaseURL) ?? "http://localhost:1234"
        defaultEmbeddingModel = try container.decodeIfPresent(String.self, forKey: .defaultEmbeddingModel)
        modelKindOverrides = try container.decodeIfPresent([String: String].self, forKey: .modelKindOverrides) ?? [:]
        // Element by element, deliberately. `[DataSource].self` in one call is
        // all-or-nothing: one source the decoder chokes on takes **every** other
        // source with it, and the store then saves the empty list back over the
        // file. That is not a tolerant decoder, whatever the comment above says.
        dataSources = AppConfiguration.decodeLeniently(container, forKey: .dataSources)
        automaticSyncPaused = try container.decodeIfPresent(Bool.self, forKey: .automaticSyncPaused) ?? false
        autoStartServerOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .autoStartServerOnLaunch) ?? true
        proxyPort = try container.decodeIfPresent(Int.self, forKey: .proxyPort) ?? 8900
        // A config that cannot be read must not silently come back open to the
        // network: both of these fail closed.
        proxyExposure = ((try? container.decodeIfPresent(NetworkExposure.self, forKey: .proxyExposure)) ?? nil) ?? .loopback
        // Выключен по умолчанию: это ограничение, а не защита, и включаться
        // само оно не должно — иначе запись у агента однажды пропадёт молча.
        mcpReadOnly = ((try? container.decodeIfPresent(Bool.self, forKey: .mcpReadOnly)) ?? nil) ?? false
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? false
        operationNotifications = ((try? container.decodeIfPresent(OperationNotificationPolicy.self, forKey: .operationNotifications)) ?? nil) ?? .problemsOnly
        externalClients = ((try? container.decodeIfPresent([ExternalClient].self, forKey: .externalClients)) ?? nil) ?? []
        timeouts = ((try? container.decodeIfPresent(TimeoutSettings.self, forKey: .timeouts)) ?? nil) ?? TimeoutSettings()
        logRetention = ((try? container.decodeIfPresent(LogRetention.self, forKey: .logRetention)) ?? nil) ?? LogRetention()
        trashEnabled = try container.decodeIfPresent(Bool.self, forKey: .trashEnabled) ?? true
        trashRetentionDays = try container.decodeIfPresent(Int.self, forKey: .trashRetentionDays) ?? TrashService.defaultRetentionDays
        trashLimitBytes = try container.decodeIfPresent(Int64.self, forKey: .trashLimitBytes) ?? TrashService.defaultLimitBytes
        syncPreviewThresholdFiles = try container.decodeIfPresent(Int.self, forKey: .syncPreviewThresholdFiles) ?? SourceSyncService.defaultPreviewThresholdFiles
        // 5 отсутствует в конфигурациях, записанных раньше, — и это
        // «выключено», а не «не знаем».
        collectionListOrder = ((try? container.decodeIfPresent(
            CollectionListOrder.self, forKey: .collectionListOrder
        )) ?? nil) ?? .default
        // H2 отсутствует в конфигурациях, записанных раньше: значок в строке
        // меню показывается, горячая клавиша молчит — как у нового человека.
        menuBar = ((try? container.decodeIfPresent(
            MenuBarPreferences.self, forKey: .menuBar
        )) ?? nil) ?? MenuBarPreferences()
        evaluationKs = EvaluationMetrics.sanitisedKs(
            (try? container.decodeIfPresent([Int].self, forKey: .evaluationKs)) ?? EvaluationMetrics.defaultKs
        )
        modelJudgeEnabled = try container.decodeIfPresent(Bool.self, forKey: .modelJudgeEnabled) ?? false
        modelJudgeModel = try container.decodeIfPresent(String.self, forKey: .modelJudgeModel)
        modelJudgePrompt = ((try? container.decodeIfPresent(JudgePrompt.self, forKey: .modelJudgePrompt)) ?? nil) ?? JudgePrompt()
    }
}

extension AppConfiguration {
    /// Clients are addressed by id, never by position.
    ///
    /// A SwiftUI `Binding` built around an array index keeps that index alive
    /// after the row is gone: deleting a client made the list read
    /// `externalClients[index]` one more time and the app died with «Index out
    /// of range». These accessors are the whole cure — an id that no
    /// longer exists is simply nothing, not a crash.
    public func client(id: UUID) -> ExternalClient? {
        externalClients.first { $0.id == id }
    }

    public mutating func updateClient(id: UUID, _ change: (inout ExternalClient) -> Void) {
        guard let index = externalClients.firstIndex(where: { $0.id == id }) else { return }
        change(&externalClients[index])
    }

    /// Adds or removes a collection from a client's whitelist.
    public mutating func toggleCollection(_ name: String, forClientID id: UUID) {
        updateClient(id: id) { client in
            if let position = client.permissions.collections.firstIndex(of: name) {
                client.permissions.collections.remove(at: position)
            } else {
                client.permissions.collections.append(name)
            }
        }
    }

    /// Kills every key still in the registry and reports how many died — the
    /// «отзывает все ключи» half of the emergency stop.
    ///
    /// Clients themselves stay, with their whitelists and limits: after an
    /// emergency the way back should be «выпустить новый ключ», not «настроить
    /// всё заново».
    public mutating func revokeAllKeys() -> Int {
        var revoked = 0
        for index in externalClients.indices where !externalClients[index].isRevoked {
            externalClients[index].revokeKey()
            revoked += 1
        }
        return revoked
    }
}

/// What reading `config.json` produced.
///
/// Three outcomes and not two, because «файла нет» and «файл есть, но прочитать
/// его не вышло» must lead to opposite behaviour: the first is an ordinary first
/// launch and saving is right, the second means the user's settings are on disk
/// and saving over them would destroy the very thing that could not be read.
public enum ConfigurationRead: Sendable {
    /// No file yet — a first launch.
    case fresh
    case loaded(AppConfiguration)
    /// Файла настроек не оказалось, и они подняты из копии «как было».
    ///
    /// Отдельно от `loaded` затем, что человеку об этом надо сказать: он
    /// смотрит не на свой файл, а на его вчерашнюю тень, и последняя правка
    /// могла в неё не попасть.
    case recovered(AppConfiguration)
    /// The file exists and could not be turned into a configuration.
    case unreadable(reason: String)
}

/// Сколько записей убирает запись настроек по сравнению с тем, что на диске.
///
/// Считается по идентификаторам, а не по числу: переименование источника —
/// не потеря, а замена одиннадцати источников двумя другими — потеря
/// одиннадцати, сколько бы ни было в новом списке.
public struct ConfigurationLoss: Sendable, Hashable {
    public var sources: Int
    public var profiles: Int
    public var clients: Int

    public var total: Int { sources + profiles + clients }

    /// Что именно исчезает — словами, для журнала и для экрана.
    public var summary: String {
        var parts: [String] = []
        if sources > 0 { parts.append(String(localized: "источников: \(sources)")) }
        if profiles > 0 { parts.append(String(localized: "профилей: \(profiles)")) }
        if clients > 0 { parts.append(String(localized: "клиентов: \(clients)")) }
        return parts.joined(separator: ", ")
    }

    public init(sources: Int = 0, profiles: Int = 0, clients: Int = 0) {
        self.sources = sources
        self.profiles = profiles
        self.clients = clients
    }

    /// Что теряется при переходе от одной конфигурации к другой.
    public static func between(_ old: AppConfiguration, _ new: AppConfiguration) -> ConfigurationLoss {
        func missing<T>(_ old: [T], _ new: [T], id: (T) -> UUID) -> Int {
            let kept = Set(new.map(id))
            return old.filter { !kept.contains(id($0)) }.count
        }
        return ConfigurationLoss(
            sources: missing(old.dataSources, new.dataSources, id: \.id),
            profiles: missing(old.serverProfiles, new.serverProfiles, id: \.id),
            clients: missing(old.externalClients, new.externalClients, id: \.id)
        )
    }

    /// Порог, за которым потеря перестаёт быть обычной работой.
    ///
    /// Одна запись — это человек, удаливший источник: он сам нажал, увидел
    /// список и подтвердил, и говорить ему об этом ещё раз значит приучать
    /// не читать предупреждения. Две и больше разом через интерфейс не
    /// удаляются вовсе — значит это либо чужая рука (второй экземпляр
    /// приложения, восстановление, перенос настроек), либо наша ошибка.
    public var isAlarming: Bool { total >= 2 }
}

/// Запись, которая унесла из настроек сразу несколько записей, — и снимок
/// того, что было до неё.
public struct ConfigurationLossNotice: Sendable, Hashable {
    public let loss: ConfigurationLoss
    /// Файл со старыми настройками целиком. Не перезаписывается следующей
    /// записью — в отличие от `config.previous.json`, которого хватает ровно
    /// на один шаг назад и который вторая такая запись затирает.
    ///
    /// `nil` — снимок сделать не удалось. Отдельный случай, а не мелочь:
    /// сообщение, обещающее файл, которого нет, человек прочитает и
    /// успокоится, а восстанавливать будет неоткуда.
    public let snapshot: URL?
    public let date: Date

    public init(loss: ConfigurationLoss, snapshot: URL?, date: Date = Date()) {
        self.loss = loss
        self.snapshot = snapshot
        self.date = date
    }

    public var message: String {
        guard let snapshot else {
            return String(localized: "Из настроек исчезло разом — \(loss.summary). Снимок прежних настроек сохранить не удалось: рядом с config.json остаётся только config.previous.json, и он живёт до следующей записи. Если это не ваше действие, скопируйте его прямо сейчас.")
        }
        return String(localized: "Из настроек исчезло разом — \(loss.summary). Прежние настройки целиком сохранены в \(snapshot.lastPathComponent); если это не ваше действие, восстановите их оттуда.")
    }
}

/// Loads and saves `AppConfiguration`. Writes are atomic and debounced.
@MainActor
public final class SettingsStore: ObservableObject {
    @Published public var configuration: AppConfiguration {
        didSet { scheduleSave() }
    }

    /// Why nothing is being saved right now, when that is the case.
    ///
    /// Not a detail: while this is set the app works normally but writes
    /// nothing, so the settings on disk survive until the user decides what to
    /// do. The screens show it (правило 2 — молча ничего не происходит).
    @Published public private(set) var persistenceProblem: String?

    /// Последняя запись, которая **убрала** из настроек сразу несколько
    /// записей, — и снимок того, что было до неё.
    ///
    /// Правило 2: молча ничего не происходит. Пропажа одиннадцати источников
    /// прошла бесследно не потому, что копии не было, а потому, что никто
    /// не сказал вслух: «сейчас записывается настройка, в которой на
    /// одиннадцать источников меньше».
    @Published public private(set) var loss: ConfigurationLossNotice?

    /// Настройки подняты не из своего файла, а из копии «как было».
    ///
    /// Тоже событие, о котором человек обязан узнать: файл на месте не был,
    /// и то, что он сейчас видит, может отставать от последней правки.
    @Published public private(set) var recoveredFromPreviousCopy: Bool = false

    private let fileURL: URL
    private let log: LogHandler
    private var saveTask: Task<Void, Never>?

    /// The copy of the last configuration that was on disk before the current
    /// one — the file that makes a loss recoverable at all.
    public var previousFileURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("config.previous.json")
    }

    public init(fileURL: URL = AppPaths.configFile, log: @escaping LogHandler = noopLogHandler) {
        self.fileURL = fileURL
        self.log = log
        switch SettingsStore.read(from: fileURL, log: log) {
        case .loaded(let configuration):
            self.configuration = configuration
        case .recovered(let configuration):
            self.configuration = configuration
            self.recoveredFromPreviousCopy = true
        case .fresh:
            self.configuration = AppConfiguration()
        case .unreadable(let reason):
            self.configuration = AppConfiguration()
            self.persistenceProblem = String(localized: "Настройки не прочитаны: \(Self.tidy(reason)) Приложение работает с настройками по умолчанию и ничего не сохраняет, чтобы не затереть файл. Нажмите «Перечитать настройки», когда причина устранена.")
        }
    }

    /// Reads the configuration, and **never** lets an unreadable one be
    /// overwritten in silence.
    ///
    /// The store saves whatever it holds a few hundred milliseconds after the
    /// first change. That made «не смог прочитать» mean «настройки пользователя
    /// стёрты» — no message, no copy, nothing to restore from. Two failures are
    /// treated apart, because they need opposite answers:
    ///
    /// * the file **does not decode** — it is copied aside and the app starts on
    /// defaults;
    /// * the file **does not read at all** while existing — the app also starts
    ///   on defaults, but then refuses to save. A read can fail for reasons that
    ///   have nothing to do with the contents: the split second during which an
    ///   atomic replace has unlinked the old file (two copies of the app, one
    ///   saving while the other starts), a permission that changed, a disk that
    ///   answered late. Treating that as «настроек нет» and writing defaults
    ///   over the file destroys sources, clients and profiles that were never
    ///   damaged in the first place.
    public static func read(from url: URL, log: LogHandler = noopLogHandler) -> ConfigurationRead {
        // «Файла нет» — вывод, а не наблюдение, и делать его с одного взгляда
        // нельзя. Атомарная запись на мгновение убирает старый файл, и второй
        // экземпляр приложения, стартующий ровно в этот миг, увидит пустоту.
        // Дальше он объявит это первым запуском, начнёт с настроек по
        // умолчанию и через полсекунды **сохранит их поверх** — с источниками,
        // клиентами и профилями, которых у него никогда не было.
        //
        // Так и произошло 9 августа 2026 года: четыре запуска приложения за
        // двадцать пять секунд, и одиннадцать источников данных исчезли без
        // единой ошибки в журнале — файл читался прекрасно, просто в одну
        // миллисекунду его не было.
        if !FileManager.default.fileExists(atPath: url.path) {
            // Та же тройная попытка, что и у чтения: окно замены — доли
            // миллисекунды.
            var appeared = false
            for _ in 0..<2 {
                Thread.sleep(forTimeInterval: 0.05)
                if FileManager.default.fileExists(atPath: url.path) { appeared = true; break }
            }
            if !appeared {
                // Копии «как было» не существует только у настоящего первого
                // запуска. Если она есть, файл был — и его отсутствие сейчас
                // означает беду, а не чистую машину.
                let previous = url.deletingLastPathComponent()
                    .appendingPathComponent("config.previous.json")
                if let data = try? Data(contentsOf: previous) {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    if let recovered = try? decoder.decode(AppConfiguration.self, from: data) {
                        log(.warning, "Настройки",
                            "Файла настроек нет, но есть копия «как было» — значит это не первый запуск. "
                            + "Настройки взяты из config.previous.json; проверьте, всё ли на месте.")
                        return .recovered(recovered)
                    }
                }
                return .fresh
            }
        }

        // The atomic-replace window is fractions of a millisecond wide, so a
        // couple of retries turn the whole class of failure into nothing at all.
        var data: Data?
        var readError: Error?
        for attempt in 0..<3 {
            do {
                data = try Data(contentsOf: url)
                break
            } catch {
                readError = error
                if attempt < 2 { Thread.sleep(forTimeInterval: 0.05) }
            }
        }

        guard let data else {
            // Vanished between the check and the read, or refused to open.
            let stillThere = FileManager.default.fileExists(atPath: url.path)
            let reason = readError?.localizedDescription ?? String(localized: "файл недоступен")
            if !stillThere {
                log(.error, "Настройки", "Файл настроек исчез во время чтения (\(reason)). Ничего не сохраняем: возможно, его переписывает второй экземпляр приложения.")
                return .unreadable(reason: String(localized: "файл исчез во время чтения"))
            }
            log(.error, "Настройки", "Файл настроек существует, но не читается (\(reason)). Приложение ничего не сохраняет, чтобы не затереть его.")
            return .unreadable(reason: reason)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return .loaded(try decoder.decode(AppConfiguration.self, from: data))
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let rescued = url.deletingLastPathComponent()
                .appendingPathComponent("config.unreadable-\(stamp).json")
            try? data.write(to: rescued, options: .atomic)
            log(.error, "Настройки",
                "Конфигурация не читается (\(error.localizedDescription)). Файл сохранён как \(rescued.lastPathComponent), приложение стартует с настройками по умолчанию — ничего не потеряно безвозвратно.")
            return .unreadable(reason: error.localizedDescription)
        }
    }

    /// Kept for callers that only need the values and have nothing to lose.
    public static func load(from url: URL, log: LogHandler = noopLogHandler) -> AppConfiguration? {
        switch read(from: url, log: log) {
        case .loaded(let configuration), .recovered(let configuration): return configuration
        case .fresh, .unreadable: return nil
        }
    }

    /// Человек увидел предупреждение о потере — убираем его с экрана.
    ///
    /// Снимок при этом остаётся на диске: закрыть сообщение и удалить
    /// единственную копию — разные вещи, и второе приложение за человека
    /// не делает (правило 1).
    public func acknowledgeLoss() { loss = nil }

    /// Человек увидел, что настройки подняты из копии.
    public func acknowledgeRecovery() { recoveredFromPreviousCopy = false }

    /// Системные описания ошибок заканчиваются точкой, наши строки ставят свою
    /// — и получается «…view it.. Приложение».
    static func tidy(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(".") ? trimmed : trimmed + "."
    }

    /// Tries again after the user has dealt with whatever blocked saving.
    ///
    /// Succeeds → the file wins over what is in memory: it is the record that
    /// survived, and the defaults the app started on are not worth keeping.
    @discardableResult
    public func reload() -> Bool {
        switch SettingsStore.read(from: fileURL, log: log) {
        case .loaded(let loaded):
            persistenceProblem = nil
            recoveredFromPreviousCopy = false
            configuration = loaded
            log(.info, "Настройки", "Файл настроек прочитан заново, сохранение снова разрешено")
            return true
        case .recovered(let loaded):
            persistenceProblem = nil
            recoveredFromPreviousCopy = true
            configuration = loaded
            log(.warning, "Настройки", "Файла настроек нет — взята копия «как было»")
            return true
        case .fresh:
            persistenceProblem = nil
            log(.info, "Настройки", "Файла настроек нет — сохранение разрешено")
            return true
        case .unreadable(let reason):
            persistenceProblem = String(localized: "Настройки по-прежнему не читаются: \(Self.tidy(reason)) Сохранение остаётся выключенным.")
            return false
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [configuration] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self.write(configuration)
        }
    }

    public func saveNow() { write(configuration) }

    private func write(_ configuration: AppConfiguration) {
        // The one rule that matters here: a configuration nobody could read is
        // not a configuration to save over.
        if let persistenceProblem {
            log(.warning, "Настройки", "Изменение не сохранено: \(persistenceProblem)")
            return
        }
        do {
            try AppPaths.ensureDirectory(fileURL.deletingLastPathComponent())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(configuration)
            announceLoss(before: configuration)
            keepPreviousVersion(before: data)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log(.error, "Настройки", "Не удалось сохранить конфигурацию: \(error.localizedDescription)")
        }
    }

    /// Copies what is on disk to `config.previous.json` before replacing it.
    ///
    /// One file and one generation deep, on purpose: the point is not a version
    /// history but the ability to answer «верни, как было минуту назад» when
    /// something — a bug here, a second copy of the app, a mis-click — writes a
    /// configuration poorer than the one before it.
    private func keepPreviousVersion(before data: Data) {
        guard let current = try? Data(contentsOf: fileURL), current != data else { return }
        try? current.write(to: previousFileURL, options: .atomic)
    }

    /// Запись, уносящая сразу несколько записей, объявляется вслух и оставляет
    /// снимок, который не затрёт следующая такая же (правило 2).
    ///
    /// Почему `config.previous.json` для этого не годится: он хранит ровно один
    /// шаг назад. Девятого августа приложение записало обеднённые настройки
    /// четырежды подряд — и к третьему разу копия «как было» сама стала
    /// обеднённой. Снимок здесь помечен временем и не перезаписывается вовсе;
    /// делается он редко ровно потому, что порог выбран по событию, которого
    /// в обычной работе не бывает.
    ///
    /// Запись при этом не запрещается: человек вправе удалить хоть всё, и
    /// приложение, отказавшееся сохранить его решение, было бы хуже
    /// приложения, которое о нём говорит.
    private func announceLoss(before configuration: AppConfiguration) {
        guard let current = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let old = try? decoder.decode(AppConfiguration.self, from: current) else { return }

        let loss = ConfigurationLoss.between(old, configuration)
        guard loss.isAlarming else { return }

        let stamp = Self.snapshotStamp.string(from: Date())
        let snapshot = fileURL.deletingLastPathComponent()
            .appendingPathComponent("config.before-loss-\(stamp).json")
        do {
            try current.write(to: snapshot, options: .atomic)
        } catch {
            // Сообщение, обещающее файл, которого нет, — хуже отсутствия
            // сообщения: человек прочитает его и успокоится. Говорим то, что
            // есть на самом деле.
            log(.error, "Настройки",
                "Записываются настройки, в которых стало меньше: \(loss.summary). "
                + "Снимок прежних сохранить НЕ удалось (\(error.localizedDescription)) — "
                + "рядом остаётся только config.previous.json, и он живёт до следующей записи.")
            self.loss = ConfigurationLossNotice(loss: loss, snapshot: nil)
            return
        }

        log(.warning, "Настройки",
            "Записываются настройки, в которых стало меньше: \(loss.summary). "
            + "Прежние сохранены целиком в \(snapshot.lastPathComponent).")
        self.loss = ConfigurationLossNotice(loss: loss, snapshot: snapshot)
    }

    /// Отметка времени в имени снимка — читаемая, без двоеточий и часового
    /// пояса: файл ищут глазами в папке, а не разбирают программой.
    private static let snapshotStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // MARK: - Convenience

    public var activeProfile: ServerProfile? {
        guard let id = configuration.selectedProfileID else { return nil }
        return configuration.serverProfiles.first { $0.id == id }
    }

    public func upsert(profile: ServerProfile) {
        if let index = configuration.serverProfiles.firstIndex(where: { $0.id == profile.id }) {
            configuration.serverProfiles[index] = profile
        } else {
            configuration.serverProfiles.append(profile)
        }
    }

    public func removeProfile(id: UUID) {
        configuration.serverProfiles.removeAll { $0.id == id }
        if configuration.selectedProfileID == id { configuration.selectedProfileID = nil }
        try? KeychainStore().remove(account: "server-profile-\(id.uuidString)")
    }

    public func upsert(source: DataSource) {
        if let index = configuration.dataSources.firstIndex(where: { $0.id == source.id }) {
            configuration.dataSources[index] = source
        } else {
            configuration.dataSources.append(source)
        }
    }

    public func removeSource(id: UUID) {
        configuration.dataSources.removeAll { $0.id == id }
    }
}


/// Consumes one element of an unkeyed container without caring what it is.
private struct AnyDecodableSkip: Decodable {
    init(from decoder: Decoder) throws {
        _ = try? decoder.singleValueContainer()
    }
}

public extension DataSource {
    /// Предел размера файла в байтах.
    var maxFileSizeBytes: Int64 { Int64(max(1, maxFileSizeMB)) * 1024 * 1024 }
}
