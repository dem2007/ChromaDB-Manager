import Foundation
import SwiftUI
import AppKit
import ChromaCore

/// The registry of external clients: who may connect through the
/// proxy, to which collections, and with what limits.
@MainActor
final class ClientsViewModel: ObservableObject {
    /// Ключ, выпущенный **сейчас**, и чей он.
    ///
    /// Показывается один раз и пропадает навсегда: приложение хранит только
    /// хеш.
    ///
    /// По идентификатору, а не по имени: имена клиентов не уникальны —
    /// создание требует лишь непустого. Двум клиентам с именем «агент» ключ
    /// первого показывался на карточке второго, а с появлением кнопок ушёл
    /// бы в конфигурацию агента как рабочий.
    @Published var freshKey: (clientID: UUID, clientName: String, key: String)?
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
        freshKey = (client.id, client.name, key)
        app.log.record(.info, "Доступ", "Создан клиент «\(client.name)» (\(client.keyPrefix)…)")
    }

    func reissueKey(_ client: ExternalClient, app: AppEnvironment) {
        var key: String?
        app.settings.configuration.updateClient(id: client.id) { key = $0.reissue() }
        guard let key else { return }
        app.refreshAccessRules()
        freshKey = (client.id, client.name, key)
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
            key: freshKey?.clientID == client.id ? freshKey?.key : nil
        )
    }

    func agentCommandLine(for client: ExternalClient) -> String {
        MCPConnectionConfig.commandLine(
            helperPath: MCPConnectionTester.helperPath,
            key: freshKey?.clientID == client.id ? freshKey?.key : nil
        )
    }

    func hasKeyAtHand(_ client: ExternalClient) -> Bool {
        freshKey?.clientID == client.id
    }

    func copyAgentConfiguration(for client: ExternalClient) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(agentConfiguration(for: client), forType: .string)
        statusMessage = hasKeyAtHand(client)
            ? String(localized: "Конфигурация с ключом скопирована — вставьте её в настройки агента.")
            : String(localized: "Конфигурация скопирована. Ключ подставьте сами: приложение его не хранит.")
    }

    // MARK: - Настроить агента одной кнопкой

    /// Агенты, найденные на этой машине. Кнопки для ненайденного не рисуются:
    /// предложить настроить то, чего нет, — это отказ, поданный как действие.
    /// Считается один раз: агентов не ставят и не сносят при открытом окне,
    /// а свойство читается из тела экрана — то есть на каждой перерисовке.
    private(set) lazy var installedAgents: [AgentKind] = AgentKind.allCases.filter(\.isInstalled)

    /// Файл скилла внутри бандла. Он же лежит в
    /// `Contents/Resources/Skills/chromadb-manager/` — для тех, кому кнопка
    /// не подошла и кто ставит руками.
    static var bundledSkill: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("Skills/\(AgentIntegration.skillName)/SKILL.md")
    }

    /// Прописать сервер в конфигурацию агента — вместе с ключом.
    ///
    /// Ключ подставляется, только когда он **сейчас** на руках: приложение
    /// хранит хеш, и достать ключ из него нельзя (7.4). Без ключа кнопка не
    /// нажимается вовсе — конфигурация с заглушкой не «почти работает»,
    /// она не работает, а выглядит настроенной.
    func installServer(_ kind: AgentKind, for client: ExternalClient) {
        guard let key = freshKey?.clientID == client.id ? freshKey?.key : nil else {
            statusMessage = String(localized: "Ключа нет на руках: перевыпустите его — и кнопка впишет настройку вместе с ним.")
            return
        }
        // Спрашиваем прежде, чем править чужой файл. Правило 4 приложения 5
        // требует показать план и дождаться согласия у массовой записи; здесь
        // запись одна, но в **чужом** документе, который человек ведёт руками
        // и в котором лежат его ключи к другим сервисам.
        pendingAgentAction = AgentAction(
            kind: kind, target: .server(clientID: client.id, key: key),
            path: kind.configuration.path
        )
    }

    /// Что подтверждает человек и над чем.
    struct AgentAction: Identifiable {
        enum Target {
            case server(clientID: UUID, key: String)
            /// Откуда берётся скилл: файл в бандле или папка, выбранная
            /// человеком. Источник едет **вместе с намерением**: между
            /// вопросом и согласием он не должен меняться.
            case skill(source: URL)
        }
        let id = UUID()
        let kind: AgentKind
        let target: Target
        let path: String

        var question: String {
            switch target {
            case .server: return String(localized: "Прописать сервер в \(kind.title)?")
            case .skill: return String(localized: "Положить скилл в \(kind.title)?")
            }
        }
        var explanation: String {
            switch target {
            case .server:
                return String(localized: "Будет изменён файл \(path). Прежний сохранится рядом снимком.")
            case .skill(let source):
                return String(localized: "Из \(source.path) будет собрана папка \(path). Прежняя сохранится снимком.")
            }
        }
    }

    @Published var pendingAgentAction: AgentAction?

    /// Согласие принимает **само намерение**, а не читает его из состояния.
    ///
    /// Окно закрывается той же связкой `isPresented`, что обнуляет
    /// `pendingAgentAction`. Пока SwiftUI успевает выполнить действие кнопки
    /// до закрытия, чтение из состояния работает — но это порядок, которого
    /// нам никто не обещал: случись он обратным, `guard` молча проглотил бы
    /// всю работу, и кнопка снова не делала бы ничего.
    func confirmAgentAction(_ action: AgentAction) {
        pendingAgentAction = nil
        switch action.target {
        case .server(_, let key): performInstallServer(action.kind, key: key)
        case .skill(let source): performInstallSkill(action.kind, from: source)
        }
    }

    private func performInstallServer(_ kind: AgentKind, key: String) {
        let helper = MCPConnectionTester.helperPath
        // Запись уходит с главного потока: четыре обращения к файловой
        // системе на сетевой домашней папке — это застывшее окно.
        Task {
            let result = await Task.detached {
                Result { try AgentIntegration.installServer(kind, key: key, helperPath: helper) }
            }.value
            self.reportServer(kind, result)
        }
    }

    private func reportServer(_ kind: AgentKind, _ result: Result<AgentInstallOutcome, Error>) {
        switch result {
        case .failure(let error):
            statusMessage = error.localizedDescription
        case .success(let outcome):
            var text = outcome.changedNothing
                ? String(localized: "\(kind.title): настройка уже была такой — файл \(outcome.path) не тронут.")
                : (outcome.replacedExisting
                    ? String(localized: "\(kind.title): настройка сервера обновлена в \(outcome.path).")
                    : String(localized: "\(kind.title): сервер добавлен в \(outcome.path)."))
            if outcome.rewroteFromTemplate {
                text += " " + String(localized: "Блок собран заново: если вы правили его руками, сверьтесь со снимком.")
            }
            if let backup = outcome.backup {
                text += " " + String(localized: "Прежний файл сохранён: \(backup).")
            }
            text += " " + String(localized: "Перезапустите агента.")
            statusMessage = text
        }
    }

    /// Положить `SKILL.md` туда, где агент его читает.
    func installSkill(_ kind: AgentKind) {
        guard let source = Self.bundledSkill else {
            statusMessage = AgentIntegrationError.skillMissing.localizedDescription
            return
        }
        pendingAgentAction = AgentAction(
            kind: kind, target: .skill(source: source),
            path: kind.skillFolder(named: AgentIntegration.skillName)
                .appendingPathComponent("SKILL.md").path
        )
    }

    /// Положить агенту скилл из его папки — целиком, со вложенными.
    ///
    /// Скилл живёт в своём хранилище и правится там; кнопка, умеющая только
    /// файл из бандла, к нему не дотягивается вовсе, а копия, собранная
    /// руками, отстаёт молча — и агент читает вчерашние правила, считая их
    /// сегодняшними.
    func installSkillFromFolder(_ kind: AgentKind) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        // Файлы тоже: человек, зашедший в папку скилла, видит там SKILL.md
        // и выбирает его — папкой будет та, в которой он лежит.
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Выберите папку скилла — ту, в которой лежит SKILL.md")
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        let isDirectory = (try? chosen.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let folder = isDirectory ? chosen : chosen.deletingLastPathComponent()
        let manifest = folder.appendingPathComponent("SKILL.md")
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            statusMessage = AgentIntegrationError.notASkillFolder(folder.path).localizedDescription
            return
        }
        // Имя — из шапки: по нему скилл опознаёт агент, и по нему же
        // находится папка, если скилл у агента уже есть. Правило то же, что
        // у службы: иначе в вопросе окажется один путь, а записан будет
        // другой.
        guard let name = AgentIntegration.skillName(forFolderAt: folder) else {
            statusMessage = AgentIntegrationError.badSkillName(
                AgentIntegration.declaredSkillName(in: manifest) ?? folder.lastPathComponent
            ).localizedDescription
            return
        }
        pendingAgentAction = AgentAction(
            kind: kind, target: .skill(source: folder),
            path: kind.skillFolder(named: name).path
        )
    }

    private func performInstallSkill(_ kind: AgentKind, from source: URL) {
        Task {
            let result = await Task.detached {
                Result { try AgentIntegration.installSkill(kind, from: source) }
            }.value
            self.reportSkill(kind, result)
        }
    }

    private func reportSkill(_ kind: AgentKind, _ result: Result<AgentInstallOutcome, Error>) {
        switch result {
        case .failure(let error):
            statusMessage = error.localizedDescription
        case .success(let outcome):
            var text = outcome.changedNothing
                ? String(localized: "\(kind.title): скилл уже был таким — файл \(outcome.path) не тронут.")
                : (outcome.replacedExisting
                    ? String(localized: "\(kind.title): скилл обновлён в \(outcome.path).")
                    : String(localized: "\(kind.title): скилл добавлен в \(outcome.path)."))
            // Сколько файлов доехало — не украшение: скилл ставится папкой,
            // и «обновлён» без числа не отличает целую копию от одного
            // переписанного файла.
            if let written = outcome.filesWritten, written > 0 {
                text += " " + String(localized: "Файлов записано: \(written).")
            }
            if let backup = outcome.backup {
                text += " " + String(localized: "Прежний файл сохранён: \(backup).")
            }
            statusMessage = text
        }
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
