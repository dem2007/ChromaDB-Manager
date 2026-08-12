import Foundation

/// The settings that mean the same thing on another machine.
///
/// An explicit allow-list, not «`AppConfiguration` minus a few fields». A new
/// setting added next month is then *not* carried across until someone decides
/// it should be — which is the safe default, because the dangerous entries here
/// are the ones nobody thought about.
///
/// Deliberately absent, each for its own reason:
///
/// - `proxyExposure` — a file must never be able to open the app to the
/// network. Everything about exposure fails closed, and an import is
///   not an exception.
/// - `checkUpdatesAutomatically`, `notificationsEnabled` — both are opt-ins the
///   user gave in person: one reaches the network, the other holds a macOS
///   permission. A file cannot give consent on their behalf.
/// - `mode`, `localDatabasePath`, `localDatabaseIsReadOnly`, `selectedProfileID`
///   — where this machine is connected right now. Importing them would point
///   the app at another machine's database and disconnect it from its own.
/// - `preferredPythonPath` — an absolute path to another machine's interpreter.
/// - `dataSources`, `serverProfiles`, `externalClients` — carried as their own
///   lists, because they merge by identity instead of overwriting.
/// - `automaticSyncPaused` — the state of this session, not a preference.
public struct TransferablePreferences: Codable, Equatable, Sendable {
    public var lmStudioBaseURL: String
    public var defaultEmbeddingModel: String?
    public var modelKindOverrides: [String: String]
    public var proxyPort: Int
    public var autoStartServerOnLaunch: Bool
    public var operationNotifications: OperationNotificationPolicy
    public var embeddingCacheEnabled: Bool
    public var embeddingCacheLimitBytes: Int64
    public var timeouts: TimeoutSettings
    public var logRetention: LogRetention
    public var trashEnabled: Bool
    public var trashRetentionDays: Int
    public var trashLimitBytes: Int64
    public var syncPreviewThresholdFiles: Int
    public var preferredInstallPath: EngineInstallPath

    public init(from configuration: AppConfiguration) {
        lmStudioBaseURL = configuration.lmStudioBaseURL
        defaultEmbeddingModel = configuration.defaultEmbeddingModel
        modelKindOverrides = configuration.modelKindOverrides
        proxyPort = configuration.proxyPort
        autoStartServerOnLaunch = configuration.autoStartServerOnLaunch
        operationNotifications = configuration.operationNotifications
        embeddingCacheEnabled = configuration.embeddingCacheEnabled
        embeddingCacheLimitBytes = configuration.embeddingCacheLimitBytes
        timeouts = configuration.timeouts
        logRetention = configuration.logRetention
        trashEnabled = configuration.trashEnabled
        trashRetentionDays = configuration.trashRetentionDays
        trashLimitBytes = configuration.trashLimitBytes
        syncPreviewThresholdFiles = configuration.syncPreviewThresholdFiles
        preferredInstallPath = configuration.preferredInstallPath
    }

    public func apply(to configuration: inout AppConfiguration) {
        configuration.lmStudioBaseURL = lmStudioBaseURL
        configuration.defaultEmbeddingModel = defaultEmbeddingModel
        configuration.modelKindOverrides = modelKindOverrides
        configuration.proxyPort = proxyPort
        configuration.autoStartServerOnLaunch = autoStartServerOnLaunch
        configuration.operationNotifications = operationNotifications
        configuration.embeddingCacheEnabled = embeddingCacheEnabled
        configuration.embeddingCacheLimitBytes = embeddingCacheLimitBytes
        configuration.timeouts = timeouts
        configuration.logRetention = logRetention
        configuration.trashEnabled = trashEnabled
        configuration.trashRetentionDays = trashRetentionDays
        configuration.trashLimitBytes = trashLimitBytes
        configuration.syncPreviewThresholdFiles = syncPreviewThresholdFiles
        configuration.preferredInstallPath = preferredInstallPath
    }
}

/// One file with everything except secrets.
///
/// Versioned from the first release for the same reason the manifest is:
/// parts of the app it will eventually carry — search profiles, query
/// sets — do not exist yet, and a file written today has to be readable
/// by the build that adds them.
public struct SettingsBundle: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var exportedAt: Date
    public var appVersion: String
    public var preferences: TransferablePreferences
    public var serverProfiles: [ServerProfile]
    public var sources: [DataSource]
    public var schemas: [String: MetadataSchema]
    public var savedFilters: [SavedFilter]
    /// Names and permissions only. Every one of them arrives revoked — see
    /// `SettingsTransfer.export`.
    public var clients: [ExternalClient]

    public init(
        schemaVersion: Int = SettingsBundle.currentSchemaVersion,
        exportedAt: Date = Date(),
        appVersion: String,
        preferences: TransferablePreferences,
        serverProfiles: [ServerProfile] = [],
        sources: [DataSource] = [],
        schemas: [String: MetadataSchema] = [:],
        savedFilters: [SavedFilter] = [],
        clients: [ExternalClient] = []
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.preferences = preferences
        self.serverProfiles = serverProfiles
        self.sources = sources
        self.schemas = schemas
        self.savedFilters = savedFilters
        self.clients = clients
    }
}

public enum SettingsTransferError: LocalizedError, Equatable {
    case unreadable(String)
    case newerSchema(found: Int, supported: Int)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let detail):
            return String(localized: "Файл настроек не читается: \(detail)")
        case .newerSchema(let found, let supported):
            return String(localized: "Файл записан более новой версией приложения (формат \(found.plainDigits), эта сборка понимает \(supported.plainDigits)).")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .unreadable:
            return String(localized: "Выберите файл, созданный кнопкой «Экспортировать настройки».")
        case .newerSchema:
            return String(localized: "Обновите приложение — читать файл частично оно не станет, чтобы не перенести половину настроек.")
        }
    }
}

/// What one import would change, before it changes anything (rule 2 of
/// Приложение 5: nothing happens silently).
public struct SettingsImportPlan: Sendable {
    public struct Category: Sendable, Equatable {
        public let added: Int
        public let replaced: Int
        public var total: Int { added + replaced }
        public var isEmpty: Bool { total == 0 }

        public init(added: Int, replaced: Int) {
            self.added = added
            self.replaced = replaced
        }
    }

    public let profiles: Category
    public let sources: Category
    public let schemas: Category
    public let filters: Category
    public let clients: Category

    /// Source folders named in the file that do not exist on this machine. Not
    /// an error — the disk may simply be elsewhere — but it must be visible,
    /// because a source pointing at nothing looks like a source that works
    /// until the first sync finds no files.
    public let missingFolders: [String]
    /// Profiles whose token has to be entered again: it stays in the Keychain
    /// of the machine that exported (rule 7 of Приложение 5).
    public let profilesNeedingToken: [String]
    /// Clients that arrive without a key and can authenticate nothing until a
    /// new one is issued.
    public let clientsNeedingKey: [String]

    public var isEmpty: Bool {
        profiles.isEmpty && sources.isEmpty && schemas.isEmpty
            && filters.isEmpty && clients.isEmpty
    }

    /// Anything already here that the import would overwrite.
    public var replacesAnything: Bool {
        profiles.replaced + sources.replaced + schemas.replaced
            + filters.replaced + clients.replaced > 0
    }
}

public enum SettingsTransfer {
    // MARK: - Export

    /// Secrets never leave: tokens and keys live in the Keychain and are not
    /// read here at all. What a client record does carry is `keyHash`, the
    /// value the proxy compares against — a verifier for a secret is close
    /// enough to one that putting it in a portable file is the same mistake.
    /// Clearing it also makes the record `isRevoked`, so an imported client
    /// authenticates nothing until a key is issued for it.
    public static func export(
        configuration: AppConfiguration,
        schemas: [String: MetadataSchema],
        savedFilters: [SavedFilter],
        appVersion: String,
        now: Date = Date()
    ) -> SettingsBundle {
        SettingsBundle(
            exportedAt: now,
            appVersion: appVersion,
            preferences: TransferablePreferences(from: configuration),
            serverProfiles: configuration.serverProfiles,
            sources: configuration.dataSources,
            schemas: schemas,
            savedFilters: savedFilters,
            clients: configuration.externalClients.map { client in
                var stripped = client
                // The same mechanism the emergency stop uses: the identity
                // and the permissions survive, the key does not.
                stripped.revokeKey()
                stripped.lastSeenAt = nil
                return stripped
            }
        )
    }

    public static func encode(_ bundle: SettingsBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bundle)
    }

    public static func decode(_ data: Data) throws -> SettingsBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle: SettingsBundle
        do {
            bundle = try decoder.decode(SettingsBundle.self, from: data)
        } catch {
            throw SettingsTransferError.unreadable(error.localizedDescription)
        }
        // Refuse rather than import what is understood and drop the rest: half
        // the settings of a newer build is worse than none of them, because
        // the half that arrived looks complete.
        guard bundle.schemaVersion <= SettingsBundle.currentSchemaVersion else {
            throw SettingsTransferError.newerSchema(
                found: bundle.schemaVersion,
                supported: SettingsBundle.currentSchemaVersion
            )
        }
        return bundle
    }

    // MARK: - Import

    /// Builds the plan. Nothing is written; `folderExists` is injected so the
    /// check is testable without a disk.
    public static func plan(
        for bundle: SettingsBundle,
        configuration: AppConfiguration,
        schemas: [String: MetadataSchema],
        savedFilters: [SavedFilter],
        hasToken: (ServerProfile) -> Bool = { _ in false },
        folderExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> SettingsImportPlan {
        let existingProfiles = Set(configuration.serverProfiles.map(\.id))
        let existingSources = Set(configuration.dataSources.map(\.id))
        let existingClients = Set(configuration.externalClients.map(\.id))
        let existingFilters = Set(savedFilters.map(\.id))

        func split<T>(_ items: [T], existing: Set<UUID>, id: (T) -> UUID) -> SettingsImportPlan.Category {
            let replaced = items.filter { existing.contains(id($0)) }.count
            return SettingsImportPlan.Category(added: items.count - replaced, replaced: replaced)
        }

        let schemaReplaced = bundle.schemas.keys.filter { schemas[$0] != nil }.count

        return SettingsImportPlan(
            profiles: split(bundle.serverProfiles, existing: existingProfiles, id: \.id),
            sources: split(bundle.sources, existing: existingSources, id: \.id),
            schemas: SettingsImportPlan.Category(
                added: bundle.schemas.count - schemaReplaced, replaced: schemaReplaced
            ),
            filters: split(bundle.savedFilters, existing: existingFilters, id: \.id),
            clients: split(bundle.clients, existing: existingClients, id: \.id),
            missingFolders: bundle.sources.map(\.path).filter { !folderExists($0) },
            profilesNeedingToken: bundle.serverProfiles.filter { !hasToken($0) }.map(\.name),
            clientsNeedingKey: bundle.clients
                .filter { incoming in
                    // A client that already has a key here keeps it (see
                    // `mergeClients`), so it is not waiting for anything.
                    !configuration.externalClients.contains { $0.id == incoming.id && !$0.isRevoked }
                }
                .map(\.name)
        )
    }

    /// Applies the bundle by identity: an entry with the same id is replaced,
    /// a new one is appended, and **nothing already here is removed**. An
    /// import adds another machine's setup to this one; wiping what it does not
    /// mention would be a destructive operation hiding inside an additive
    /// button (rule 1 of Приложение 5).
    public static func apply(
        _ bundle: SettingsBundle,
        to configuration: inout AppConfiguration,
        schemas: inout [String: MetadataSchema],
        savedFilters: inout [SavedFilter],
        includePreferences: Bool
    ) {
        if includePreferences {
            bundle.preferences.apply(to: &configuration)
        }
        configuration.serverProfiles = merge(configuration.serverProfiles, bundle.serverProfiles, id: \.id)
        configuration.dataSources = merge(configuration.dataSources, bundle.sources, id: \.id)
        configuration.externalClients = mergeClients(configuration.externalClients, bundle.clients)
        savedFilters = merge(savedFilters, bundle.savedFilters, id: \.id)
        for (collection, schema) in bundle.schemas {
            schemas[collection] = schema
        }
    }

    /// Clients merge like everything else, except that the key stays with the
    /// machine it was issued on.
    ///
    /// Every client in the file is keyless by construction, so a plain merge
    /// would revoke a working key the moment someone re-imported their own
    /// export onto the same machine — found by doing exactly that. The name and
    /// the permissions come from the file, because that is what an import is
    /// for; the key material does not, because it never travelled.
    private static func mergeClients(_ existing: [ExternalClient], _ incoming: [ExternalClient]) -> [ExternalClient] {
        var result = existing
        for var client in incoming {
            guard let index = result.firstIndex(where: { $0.id == client.id }) else {
                result.append(client)
                continue
            }
            let local = result[index]
            if client.isRevoked && !local.isRevoked {
                client.keyHash = local.keyHash
                client.keyPrefix = local.keyPrefix
                client.isEnabled = local.isEnabled
            }
            client.lastSeenAt = local.lastSeenAt
            result[index] = client
        }
        return result
    }

    private static func merge<T>(_ existing: [T], _ incoming: [T], id: (T) -> UUID) -> [T] {
        var result = existing
        for item in incoming {
            if let index = result.firstIndex(where: { id($0) == id(item) }) {
                result[index] = item
            } else {
                result.append(item)
            }
        }
        return result
    }
}
