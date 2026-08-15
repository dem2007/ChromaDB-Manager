import Foundation
import SwiftUI
import AppKit
import ChromaCore

/// The registry of external clients: who may connect through the
/// proxy, to which collections, and with what limits.
@MainActor
final class ClientsViewModel: ObservableObject {
    /// The key of a client that has just been created or reissued. Shown once
    /// and then gone for good — the app stores only its hash.
    @Published var freshKey: (clientName: String, key: String)?
    @Published var draftName = ""
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    /// Collections offered as checkboxes, refreshed from the server.
    @Published private(set) var knownCollections: [String] = []
    @Published var usageToday: [UUID: Int] = [:]
    /// Requests the proxy refused for rate, per client.
    @Published var throttledToday: [UUID: Int] = [:]
    /// Set while «разрешить любой origin» is waiting for confirmation.
    @Published var pendingWildcardClientID: UUID?

    func refresh(_ app: AppEnvironment) async {
        guard let client = app.client else {
            knownCollections = []
            return
        }
        knownCollections = ((try? await client.listCollections()) ?? []).map(\.name).sorted()
        var usage: [UUID: Int] = [:]
        var throttled: [UUID: Int] = [:]
        for registered in app.settings.configuration.externalClients {
            usage[registered.id] = await app.proxy.access.usageToday(for: registered.id)
            throttled[registered.id] = await app.proxy.access.throttledCount(for: registered.id)
        }
        usageToday = usage
        throttledToday = throttled
    }

    // MARK: - Creating

    func create(_ app: AppEnvironment) {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            errorMessage = String(localized: "У клиента должно быть имя — по нему он виден в журнале доступа.")
            return
        }
        // Read-only and no collections: a new key can do nothing until someone
        // decides what it may do.
        let (client, key) = ExternalClient.issue(name: name)
        app.settings.configuration.externalClients.append(client)
        app.refreshAccessRules()
        draftName = ""
        freshKey = (client.name, key)
        app.log.record(.info, "Доступ", "Создан клиент «\(client.name)» (\(client.keyPrefix)…)")
    }

    func reissueKey(_ client: ExternalClient, app: AppEnvironment) {
        var key: String?
        app.settings.configuration.updateClient(id: client.id) { key = $0.reissue() }
        guard let key else { return }
        app.refreshAccessRules()
        freshKey = (client.name, key)
        app.log.record(.warning, "Доступ", "Ключ клиента «\(client.name)» перевыпущен — прежний больше не действует")
    }

    func remove(_ client: ExternalClient, app: AppEnvironment) {
        app.settings.configuration.externalClients.removeAll { $0.id == client.id }
        app.refreshAccessRules()
        statusMessage = String(localized: "Клиент «\(client.name)» удалён, его ключ больше не действует.")
        app.log.record(.warning, "Доступ", "Клиент «\(client.name)» удалён")
    }

    func setEnabled(_ isEnabled: Bool, for client: ExternalClient, app: AppEnvironment) {
        app.settings.configuration.updateClient(id: client.id) { $0.isEnabled = isEnabled }
        app.refreshAccessRules()
    }

    // MARK: - Permissions

    /// Bound by **id**, never by position.
    ///
    /// SwiftUI reads a row's binding once more while the row is being removed.
    /// A binding that captured the array index therefore read past the end of a
    /// list that had just shrunk, and deleting a client crashed the app
    ///. Looking the client up by id turns that read into a harmless
    /// «this client is gone».
    func binding(for client: ExternalClient, app: AppEnvironment) -> Binding<ClientPermissions>? {
        guard app.settings.configuration.client(id: client.id) != nil else { return nil }
        return Binding(
            get: { app.settings.configuration.client(id: client.id)?.permissions ?? client.permissions },
            set: { newValue in
                app.settings.configuration.updateClient(id: client.id) { $0.permissions = newValue }
                app.refreshAccessRules()
            }
        )
    }

    func toggleCollection(_ name: String, for client: ExternalClient, app: AppEnvironment) {
        app.settings.configuration.toggleCollection(name, forClientID: client.id)
        app.refreshAccessRules()
    }

    // MARK: - The key

    func copyFreshKey() {
        guard let freshKey else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(freshKey.key, forType: .string)
        statusMessage = String(localized: "Ключ скопирован. Сохраните его — приложение его не хранит.")
    }

    /// Пример подключения — с той схемой, которая на самом деле включена.
    ///
    /// `chroma_server_ssl_verify` принимает путь к файлу сертификата и уходит
    /// прямо в `httpx.Client(verify=…)` — проверено по исходникам установленной
    /// библиотеки, а не по памяти. Совет про `REQUESTS_CA_BUNDLE`, который
    /// напрашивался, был бы неверным: клиент ChromaDB давно ходит через httpx,
    /// а не через requests.
    func snippet(for key: String, port: Int, usesTLS: Bool = false) -> String {
        guard usesTLS else {
            return """
            import chromadb
            client = chromadb.HttpClient(
                host="127.0.0.1", port=\(port.plainDigits),
                headers={"X-Chroma-Token": "\(key)"},
            )
            """
        }
        return """
        import chromadb
        from chromadb.config import Settings

        client = chromadb.HttpClient(
            host="127.0.0.1", port=\(port.plainDigits), ssl=True,
            headers={"X-Chroma-Token": "\(key)"},
            # Файл сертификата: «Безопасность» → «Сохранить сертификат…»
            settings=Settings(chroma_server_ssl_verify="chromadb-manager.pem"),
        )
        """
    }

    /// Кладёт строку в буфер и говорит об этом. Адрес MCP по сети берут
    /// глазами и вставляют в чужую конфигурацию — набирать его руками негде.
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = String(localized: "Скопировано: \(text)")
    }

    func copySnippet(port: Int, usesTLS: Bool = false) {
        guard let freshKey else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet(for: freshKey.key, port: port, usesTLS: usesTLS), forType: .string)
        statusMessage = String(localized: "Пример подключения скопирован.")
    }

    // MARK: - Подключение агента

    /// Чья карточка подключения сейчас раскрыта. Одна на экран: две
    /// конфигурации рядом читаются как одна, и ключ уедет не тому клиенту.
    @Published var configuringClientID: UUID?
    /// Результат последней проверки, по клиенту.
    @Published var checks: [UUID: MCPConnectionCheck] = [:]
    @Published var checkingClientID: UUID?

    /// Конфигурация для агента. Ключ подставляется, только если он **сейчас**
    /// на экране: приложение хранит хеш и показать его снова не может (7.4).
    func agentConfiguration(for client: ExternalClient) -> String {
        MCPConnectionConfig.json(
            helperPath: MCPConnectionTester.helperPath,
            key: freshKey?.clientName == client.name ? freshKey?.key : nil
        )
    }

    func agentCommandLine(for client: ExternalClient) -> String {
        MCPConnectionConfig.commandLine(
            helperPath: MCPConnectionTester.helperPath,
            key: freshKey?.clientName == client.name ? freshKey?.key : nil
        )
    }

    func hasKeyAtHand(_ client: ExternalClient) -> Bool {
        freshKey?.clientName == client.name
    }

    func copyAgentConfiguration(for client: ExternalClient) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(agentConfiguration(for: client), forType: .string)
        statusMessage = hasKeyAtHand(client)
            ? String(localized: "Конфигурация с ключом скопирована — вставьте её в настройки агента.")
            : String(localized: "Конфигурация скопирована. Ключ подставьте сами: приложение его не хранит.")
    }

    /// Тестовый вызов через тот же транспорт, которым пойдёт агент.
    func checkConnection(for client: ExternalClient) {
        checkingClientID = client.id
        let key = hasKeyAtHand(client) ? freshKey?.key : nil
        Task { @MainActor in
            let result = await MCPConnectionTester.run(key: key)
            checks[client.id] = result
            checkingClientID = nil
        }
    }
}
