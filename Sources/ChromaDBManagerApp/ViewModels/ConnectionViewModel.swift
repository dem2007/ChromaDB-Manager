import Foundation
import AppKit
import ChromaCore

/// «Подключение»: the local database folder, server profiles the app runs
/// itself, and connections to somebody else's ChromaDB.
@MainActor
final class ConnectionViewModel: ObservableObject {
    // Managed server wizard
    @Published var showServerWizard = false
    @Published var draftName = ""
    @Published var draftPath = ""
    @Published var draftPort = "8000"
    @Published var draftAllowReset = false

    // External server form
    @Published var externalName = ""
    @Published var externalHost = "localhost"
    @Published var externalPort = "8000"
    @Published var externalTLS = false
    @Published var externalTenant = ChromaEndpoint.defaultTenant
    /// Databases found on the server for the tenant typed above.
    @Published var availableDatabases: [String] = []
    @Published var isBrowsingDatabases = false
    @Published var externalDatabase = ChromaEndpoint.defaultDatabase
    @Published var externalToken = ""
    @Published var externalTokenHeader: ServerProfile.TokenHeader = .authorizationBearer

    /// Which connection is being taken out of read-only mode. Set when the
    /// user unticks the flag; cleared by answering the confirmation.
    @Published var confirmLiftingReadOnly: ReadOnlyTarget?

    enum ReadOnlyTarget: Identifiable, Equatable {
        case localDatabase
        case profile(UUID)

        var id: String {
            switch self {
            case .localDatabase: return "local"
            case .profile(let id): return id.uuidString
            }
        }
    }

    // Token editing for an existing profile
    @Published var tokenEditorProfileID: UUID?
    @Published var tokenDraft = ""

    /// Filled in off the main thread: adding up the size of a database folder
    /// is far too slow to do while the view is being laid out.
    @Published var localDatabaseInfo = DatabaseDirectoryInfo(exists: false, looksLikeChroma: false, sizeBytes: 0)

    @Published var isTesting = false
    @Published var testResults: [UUID: String] = [:]
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    // MARK: - Local database

    func refreshLocalDatabaseInfo(_ app: AppEnvironment) async {
        localDatabaseInfo = await app.inspector.databaseDirectoryInfo(app.localDatabaseURL)
    }

    func chooseLocalDirectory(_ app: AppEnvironment) {
        guard let url = Self.chooseDirectory(
            title: String(localized: "Выберите папку с базой ChromaDB"),
            message: String(localized: "Здесь будут храниться файлы базы (chroma.sqlite3 и индексы).")
        ) else { return }
        app.settings.configuration.localDatabasePath = url.path
        statusMessage = String(localized: "Каталог базы: \(url.path)")
        app.log.record(.info, "Подключение", "Каталог локальной базы: \(url.path)")
        Task { await refreshLocalDatabaseInfo(app) }
    }

    func useDefaultLocalDirectory(_ app: AppEnvironment) {
        app.settings.configuration.localDatabasePath = AppPaths.defaultEmbeddedDatabase.path
        statusMessage = String(localized: "Каталог базы: \(AppPaths.defaultEmbeddedDatabase.path)")
        Task { await refreshLocalDatabaseInfo(app) }
    }

    // MARK: - Read-only mode

    /// Taking the flag off is the only direction that asks. The client is
    /// immutable, so the change takes effect on the next connection — said
    /// plainly rather than left for the user to discover.
    func liftReadOnly(_ target: ReadOnlyTarget, app: AppEnvironment) {
        switch target {
        case .localDatabase:
            app.settings.configuration.localDatabaseIsReadOnly = false
            app.log.record(.warning, "Подключение", "С локальной базы снят режим «только чтение»")
        case .profile(let id):
            guard var profile = app.settings.configuration.serverProfiles.first(where: { $0.id == id }) else { return }
            profile.isReadOnly = false
            app.settings.upsert(profile: profile)
            app.log.record(.warning, "Подключение", "С профиля «\(profile.name)» снят режим «только чтение»")
        }
        confirmLiftingReadOnly = nil
        statusMessage = app.connection.isReadOnly
            ? String(localized: "Режим снят. Текущее подключение остаётся только для чтения — переподключитесь, чтобы разрешить запись.")
            : String(localized: "Режим «только чтение» снят.")
    }

    // MARK: - Managed profiles

    func prepareWizard(_ app: AppEnvironment) {
        draftName = String(localized: "Локальный сервер")
        draftPath = app.settings.configuration.localDatabasePath ?? AppPaths.defaultEmbeddedDatabase.path
        draftPort = "8000"
        draftAllowReset = false
        showServerWizard = true
    }

    func chooseDraftPath() {
        guard let url = Self.chooseDirectory(
            title: String(localized: "Где хранить базу этого сервера"),
            message: String(localized: "Каталог будет записан в конфигурацию сервера как persist_path.")
        ) else { return }
        draftPath = url.path
    }

    func createManagedProfile(_ app: AppEnvironment) {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            errorMessage = String(localized: "Введите имя профиля.")
            return
        }
        guard let port = Int(draftPort), (1...65535).contains(port) else {
            errorMessage = String(localized: "Порт должен быть числом от 1 до 65535.")
            return
        }
        guard !draftPath.isEmpty else {
            errorMessage = String(localized: "Выберите каталог для базы.")
            return
        }

        let profile = ServerProfile(
            name: name,
            kind: .managed,
            // Fixed, not typed in: a managed server never leaves loopback.
            host: "127.0.0.1",
            port: port,
            databasePath: draftPath,
            allowReset: draftAllowReset
        )
        app.settings.upsert(profile: profile)
        app.settings.configuration.selectedProfileID = profile.id
        app.settings.configuration.mode = .server
        showServerWizard = false
        statusMessage = String(localized: "Профиль «\(name)» создан.")
        app.log.record(.success, "Подключение", "Создан профиль сервера «\(name)» (\(profile.displayAddress))")
    }

    func addExternalProfile(_ app: AppEnvironment) {
        guard let port = Int(externalPort), (1...65535).contains(port) else {
            errorMessage = String(localized: "Порт должен быть числом от 1 до 65535.")
            return
        }
        let host = externalHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            errorMessage = String(localized: "Введите host.")
            return
        }

        let name = externalName.trimmingCharacters(in: .whitespaces)
        let profile = ServerProfile(
            name: name.isEmpty ? "\(host):\(port)" : name,
            kind: .external,
            host: host,
            port: port,
            databasePath: nil,
            useTLS: externalTLS,
            tenant: externalTenant.trimmingCharacters(in: .whitespaces),
            database: externalDatabase.trimmingCharacters(in: .whitespaces),
            tokenHeader: externalTokenHeader
        )
        app.settings.upsert(profile: profile)
        app.settings.configuration.selectedProfileID = profile.id
        app.settings.configuration.mode = .server

        if !externalToken.isEmpty {
            app.setToken(externalToken, for: profile)
            externalToken = ""
        }
        externalName = ""
        statusMessage = String(localized: "Профиль «\(profile.name)» добавлен.")
    }

    /// Lists the databases of the tenant typed in the form.
    ///
    /// Uses a throwaway client at the address in the form: the profile does not
    /// exist yet, and the app may well be connected somewhere else.
    func browseDatabases(_ app: AppEnvironment) async {
        guard let port = Int(externalPort), (1...65535).contains(port) else {
            errorMessage = String(localized: "Порт должен быть числом от 1 до 65535.")
            return
        }
        isBrowsingDatabases = true
        defer { isBrowsingDatabases = false }
        let endpoint = ChromaEndpoint(
            host: externalHost.trimmingCharacters(in: .whitespaces),
            port: port,
            useTLS: externalTLS,
            tenant: externalTenant.trimmingCharacters(in: .whitespaces),
            database: externalDatabase.trimmingCharacters(in: .whitespaces)
        )
        let probe = ChromaClient(endpoint: endpoint, timeouts: app.settings.configuration.timeouts)
        do {
            availableDatabases = try await probe.listDatabases()
            if availableDatabases.isEmpty {
                statusMessage = String(localized: "В тенанте «\(endpoint.tenant)» баз не найдено.")
            }
        } catch {
            availableDatabases = []
            errorMessage = app.describe(error)
        }
    }

    /// Creates the database the connection asked for, after the user agrees.
    func createMissingDatabase(_ app: AppEnvironment) async {
        guard let missing = app.missingDatabase, let endpoint = app.pendingEndpoint else { return }
        let probe = ChromaClient(endpoint: endpoint, log: app.logHandler, timeouts: app.settings.configuration.timeouts)
        do {
            try await probe.createDatabase(name: missing.database, tenant: missing.tenant)
            app.missingDatabase = nil
            statusMessage = String(localized: "База «\(missing.database)» создана.")
            await app.reconnect()
        } catch {
            errorMessage = app.describe(error)
        }
    }

    func select(_ profile: ServerProfile, app: AppEnvironment) {
        app.settings.configuration.selectedProfileID = profile.id
        app.settings.configuration.mode = .server
    }

    func delete(_ profile: ServerProfile, app: AppEnvironment) {
        app.settings.removeProfile(id: profile.id)
        testResults[profile.id] = nil
    }

    func hasToken(_ profile: ServerProfile, app: AppEnvironment) -> Bool {
        app.keychain.hasToken(for: profile.keychainAccount)
    }

    func beginTokenEditing(_ profile: ServerProfile) {
        tokenEditorProfileID = profile.id
        tokenDraft = ""
    }

    func saveToken(for profile: ServerProfile, app: AppEnvironment) {
        app.setToken(tokenDraft, for: profile)
        statusMessage = tokenDraft.isEmpty
            ? String(localized: "Токен профиля «\(profile.name)» удалён.")
            : String(localized: "Токен профиля «\(profile.name)» сохранён в Keychain.")
        tokenDraft = ""
        tokenEditorProfileID = nil
    }

    /// "Проверить соединение" — `GET /api/v2/healthcheck`, nothing is changed.
    func test(_ profile: ServerProfile, app: AppEnvironment) async {
        isTesting = true
        defer { isTesting = false }

        let client = ChromaClient(
            endpoint: profile.endpoint(with: app.token(for: profile)),
            log: app.logHandler,
            timeouts: app.settings.configuration.timeouts
        )
        do {
            let info = try await client.connect()
            let collections = (try? await client.listCollections(withCounts: false).count) ?? 0
            testResults[profile.id] = String(localized: "🟢 Доступен · ChromaDB \(info.version) · коллекций: \(collections)")
        } catch {
            testResults[profile.id] = "🔴 \(app.describe(error))"
        }
    }

    func startManagedServer(_ profile: ServerProfile, app: AppEnvironment) async {
        guard let configuration = profile.launchConfiguration() else { return }
        do {
            _ = try await app.processManager.start(configuration)
            statusMessage = String(localized: "Сервер «\(profile.name)» запущен.")
        } catch {
            errorMessage = app.describe(error)
            app.report(error, category: "Сервер")
        }
    }

    func stopServer(_ app: AppEnvironment) async {
        await app.processManager.stop()
        statusMessage = String(localized: "Сервер остановлен.")
    }

    // MARK: - Panels

    static func chooseDirectory(title: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFile(title: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
