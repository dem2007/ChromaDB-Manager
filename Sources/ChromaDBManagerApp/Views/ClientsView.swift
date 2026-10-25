import SwiftUI
import ChromaCore

/// Spec: the list of external clients, their keys, rights and limits.
///
/// «Ключи» — раздел со своим списком: `SectionSplit`, слева ключи, справа
/// форма выбранного. «MCP» — форма. Журнал обращений — только в «Логи →
/// Доступ»; у ключа — «Показать в журнале».
struct ClientsView: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var proxy: ProxyServer
    @ObservedObject var model: ClientsViewModel
    @ObservedObject var mcp: MCPService

    /// Разрез экрана: «Ключи», «MCP».
    var tab: Int = 0
    /// «Новый ключ клиента…» из строки меню.
    @Binding var newClientRequested: Bool
    /// Перейти в журнал доступа к записям этого клиента.
    var showInJournal: (ExternalClient) -> Void = { _ in }

    @State private var selection: UUID?
    @State private var showsNewClient = false
    /// Ключ из листа ушёл в форму — настраивать агента (7.4): лист закрыт,
    /// а ключ остаётся под рукой, пока открыто подключение агента.
    @State private var freshKeyHandedOver = false
    /// «Скопировано» — в самом листе: сообщение экрана скрыто под ним.
    @State private var copiedInSheet: CopiedItem?

    /// Что из листа ключа скопировано — ответ «Скопировано» у этой кнопки.
    private enum CopiedItem { case key, snippet }
    @State private var collectionFilter = ""
    /// Клиент, ждущий подтверждения удаления или перевыпуска ключа.
    @State private var clientPendingRemoval: ExternalClient?
    @State private var clientPendingReissue: ExternalClient?

    private var clients: [ExternalClient] { settings.configuration.externalClients }

    private var selectedClient: ExternalClient? {
        guard let selection else { return nil }
        return clients.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            messages
            switch tab {
            case 1:
                mcpForm
            default:
                keysTab
            }
        }
        // Список коллекций для доступа — заново, когда синхронизация завела
        // новую или сервер подключился позже экрана: иначе свежая
        // коллекция появлялась здесь только после повторного захода.
        .task(id: CollectionsTick(revision: app.collectionsRevision, connected: app.connection.isConnected)) {
            await model.refresh(app)
        }
        .onAppear {
            if selection == nil { selection = clients.first?.id }
            takeNewClientRequest()
        }
        .onChange(of: newClientRequested) { _, _ in takeNewClientRequest() }
        .onChange(of: clients.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = ids.first }
        }
        // Лист нового ключа — в два шага: имя, затем ключ один раз.
        .sheet(isPresented: Binding(
            get: { showsNewClient || (model.freshKey != nil && !freshKeyHandedOver) },
            set: { shown in
                if !shown {
                    showsNewClient = false
                    if !freshKeyHandedOver { model.freshKey = nil }
                    copiedInSheet = nil
                }
            }
        )) {
            if let fresh = model.freshKey, !freshKeyHandedOver {
                freshKeySheet(fresh)
            } else {
                newClientSheet
            }
        }
        // Новый ключ — снова в лист; отданный в форму живёт, пока открыто
        // подключение агента этого ключа.
        .onChange(of: model.freshKey?.key) { _, _ in
            freshKeyHandedOver = false
            copiedInSheet = nil
        }
        .onChange(of: model.configuringClientID) { _, opened in
            if freshKeyHandedOver, opened != model.freshKey?.clientID { model.freshKey = nil }
        }
        // Подтверждение висит на **корне экрана**: на кнопках, которых
        // может не быть, SwiftUI его не показывает.
        .alert(
            model.pendingAgentAction?.question ?? "",
            isPresented: Binding(
                get: { model.pendingAgentAction != nil },
                set: { shown in if !shown { model.pendingAgentAction = nil } }
            ),
            presenting: model.pendingAgentAction
        ) { action in
            Button(String(localized: "Записать")) { model.confirmAgentAction(action) }
            Button(String(localized: "Отменить"), role: .cancel) {
                model.pendingAgentAction = nil
            }
        } message: { action in
            Text(action.explanation)
        }
        .confirmationDialog(
            clientPendingRemoval.map { String(localized: "Удалить клиента «\($0.name)»?") } ?? "",
            isPresented: Binding(
                get: { clientPendingRemoval != nil },
                set: { if !$0 { clientPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Удалить клиента"), role: .destructive) {
                if let client = clientPendingRemoval { model.remove(client, app: app) }
                clientPendingRemoval = nil
            }
            Button(String(localized: "Отменить"), role: .cancel) { clientPendingRemoval = nil }
        } message: {
            Text("Его ключ перестанет действовать сразу — и по HTTP, и через MCP. Права и лимиты клиента удалятся вместе с ним.")
        }
        .confirmationDialog(
            clientPendingReissue.map { String(localized: "Перевыпустить ключ «\($0.name)»?") } ?? "",
            isPresented: Binding(
                get: { clientPendingReissue != nil },
                set: { if !$0 { clientPendingReissue = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Перевыпустить"), role: .destructive) {
                // Флаг «ключ отдан в форму» снимет сам новый ключ (`onChange`
                // по `freshKey`): не вышло перевыпустить — прежний лист не
                // всплывёт.
                if let client = clientPendingReissue { model.reissueKey(client, app: app) }
                clientPendingReissue = nil
            }
            Button(String(localized: "Отменить"), role: .cancel) { clientPendingReissue = nil }
        } message: {
            Text("Прежний ключ перестанет действовать сразу: скрипты и агенты с ним получат отказ, пока им не дадут новый. Права и лимиты останутся.")
        }
    }

    private func takeNewClientRequest() {
        guard newClientRequested else { return }
        newClientRequested = false
        showsNewClient = true
    }

    @ViewBuilder
    private var messages: some View {
        if model.errorMessage != nil || model.statusMessage != nil {
            VStack(alignment: .leading) {
                if let error = model.errorMessage {
                    HStack {
                        Notice(.warning, error)
                        Spacer()
                        Button(String(localized: "Скрыть")) { model.errorMessage = nil }
                            .buttonStyle(.borderless)
                    }
                }
                if let status = model.statusMessage {
                    HStack {
                        Notice(.info, status)
                        Spacer()
                        Button(String(localized: "Скрыть")) { model.statusMessage = nil }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .padding()
            Divider()
        }
    }

    // MARK: - Ключи

    private var keysTab: some View {
        SectionSplit {
            keyList
        } detail: {
            Group {
                if let client = selectedClient {
                    ClientForm(
                        client: client, model: model,
                        collectionFilter: $collectionFilter,
                        proxyNote: proxyNote
                    )
                    .id(client.id)
                } else {
                    ContentUnavailableView {
                        Label(String(localized: "Выберите ключ"), systemImage: "key")
                    } description: {
                        Text("Права, коллекции и лимиты — у каждого ключа свои.")
                    }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if tab == 0 {
                    Button {
                        showsNewClient = true
                    } label: {
                        Label(String(localized: "Новый ключ…"), systemImage: "plus")
                    }
                    .help(String(localized: "Создать ключ для нового клиента"))
                    Menu {
                        if let client = selectedClient {
                            clientMenu(client)
                        }
                    } label: {
                        Label(String(localized: "Ещё"), systemImage: "ellipsis.circle")
                    }
                    .disabled(selectedClient == nil)
                }
            }
        }
    }

    /// Прокси и MCP — два транспорта поверх одних и тех же ключей, и
    /// остановленный прокси больше не значит «ключи ни к чему не дают
    /// доступа»: через MCP они работают (: только на вкладке «Ключи»).
    private var proxyNote: String? {
        guard !proxy.state.isRunning else { return nil }
        return mcp.isListening
            ? String(localized: "Прокси не запущен — по HTTP ключи не работают. Через MCP они действуют: сервер слушает.")
            : String(localized: "Прокси не запущен — ключи ни к чему не дают доступа. Запустить его можно на экране «Безопасность» → «Доступ по сети».")
    }

    @ViewBuilder
    private var keyList: some View {
        if clients.isEmpty {
            ContentUnavailableView {
                Label(String(localized: "Ключей пока нет"), systemImage: "key")
            } description: {
                Text("Пока не создан ни один ключ, прокси отклоняет все запросы: доступ по умолчанию закрыт.")
            } actions: {
                Button(String(localized: "Новый ключ…")) { showsNewClient = true }
            }
        } else {
            List(selection: $selection) {
                ForEach(clients) { client in
                    // Как строки «Источников» (v4 B): состояние — точкой,
                    // подпись — «когда» относительно сейчас; точная дата — в
                    // подсказке, в форме ключа.
                    VStack(alignment: .leading) {
                        HStack {
                            Text(client.name).lineLimit(1)
                            Spacer()
                            StatusLabel(
                                client.isEnabled ? .ok : .off,
                                client.isEnabled ? String(localized: "активен") : String(localized: "отозван")
                            )
                            .dotOnly()
                        }
                        Group {
                            if let seen = client.lastSeenAt {
                                Text("активность: \(seen, format: .relative(presentation: .named))")
                                    .help(seen.formatted(date: .abbreviated, time: .shortened))
                            } else {
                                Text("ещё не подключался")
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    .tag(client.id)
                }
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first, let client = clients.first(where: { $0.id == id }) {
                    clientMenu(client)
                }
            }
            .onDeleteCommand {
                if let client = selectedClient { clientPendingRemoval = client }
            }
        }
    }

    @ViewBuilder
    private func clientMenu(_ client: ExternalClient) -> some View {
        Button(String(localized: "Настроить подключение агента")) {
            selection = client.id
            model.configuringClientID = client.id
        }
        Button(String(localized: "Показать в журнале")) { showInJournal(client) }
        Divider()
        Button(String(localized: "Перевыпустить ключ…")) { clientPendingReissue = client }
        Divider()
        Button(String(localized: "Удалить клиента…"), role: .destructive) { clientPendingRemoval = client }
    }

    private var newClientSheet: some View {
        SheetForm(
            cancel: { showsNewClient = false; model.draftName = "" },
            confirmTitle: String(localized: "Создать ключ"),
            confirmDisabled: model.draftName.trimmingCharacters(in: .whitespaces).isEmpty,
            confirm: {
                // Лист не должен мигнуть: новый ключ показывается в нём же.
                freshKeyHandedOver = false
                model.create(app)
                showsNewClient = false
                if let fresh = model.freshKey { selection = fresh.clientID }
            }
        ) {
            Section {
                TextField(String(localized: "Имя"), text: $model.draftName, prompt: Text("например, «скрипт отчётов»"))
            } header: {
                Text("Новый клиент")
            } footer: {
                Text("Новый ключ создаётся без прав: только чтение и ни одной коллекции. Что именно ему разрешено, решается в его форме.")
            }
        }
    }

    /// Ключ показывается один раз, в листе: приложение хранит только
    /// его хеш и не сможет показать ключ снова.
    private func freshKeySheet(_ fresh: (clientID: UUID, clientName: String, key: String)) -> some View {
        SheetFrame(width: .wide) {
            Section {
                Text(fresh.key)
                    .font(.body.monospaced())
                    .copyable(fresh.key)
                HStack {
                    Spacer()
                    if copiedInSheet == .key {
                        Text("Скопировано").foregroundStyle(.secondary)
                    }
                    Button(String(localized: "Скопировать ключ")) {
                        model.copyFreshKey()
                        copiedInSheet = .key
                    }
                }
            } header: {
                Text("Ключ клиента «\(fresh.clientName)»")
            } footer: {
                Notice(.warning, String(localized: "Показывается один раз. Приложение хранит только его хеш и не сможет показать ключ снова — забытый ключ можно лишь перевыпустить."))
            }
            Section {
                Text(model.snippet(
                    for: fresh.key,
                    port: settings.configuration.proxyPort,
                    usesTLS: settings.configuration.proxyUsesTLS
                ))
                .font(.body.monospaced())
                .copyable(model.snippet(for: fresh.key, port: settings.configuration.proxyPort, usesTLS: settings.configuration.proxyUsesTLS))
                HStack {
                    Spacer()
                    if copiedInSheet == .snippet {
                        Text("Скопировано").foregroundStyle(.secondary)
                    }
                    Button(String(localized: "Скопировать пример")) {
                        model.copySnippet(
                            port: settings.configuration.proxyPort,
                            usesTLS: settings.configuration.proxyUsesTLS
                        )
                        copiedInSheet = .snippet
                    }
                }
            } header: {
                Text("Пример подключения на Python")
            }
        } actions: {
            // Настроить подключение агента проще всего **сейчас**: потом ключ
            // подставить будет нечем (7.4). По идентификатору: имена клиентов
            // повторяются.
            if clients.contains(where: { $0.id == fresh.clientID }) {
                Button(String(localized: "Настроить подключение агента")) {
                    // Ключ не стирается: форма подставит его в конфигурацию.
                    freshKeyHandedOver = true
                    selection = fresh.clientID
                    model.configuringClientID = fresh.clientID
                }
            }
            Spacer()
            Button(String(localized: "Я сохранил ключ")) {
                model.freshKey = nil
                copiedInSheet = nil
            }
                .primaryButtonStyle()
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - MCP: состояние, режим и активность

    private var mcpForm: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Сервер")) {
                    if mcp.isListening {
                        StatusLabel(.ok, String(localized: "слушает"))
                    } else if let error = mcp.lastError {
                        StatusLabel(.error, error)
                    } else {
                        StatusLabel(.off, String(localized: "не запущен"))
                    }
                }
                if mcp.callCount > 0 {
                    LabeledContent(String(localized: "Обращений за сеанс"), value: mcp.callCount.plainDigits)
                }
                Toggle(String(localized: "Только чтение для всех ключей"), isOn: Binding(
                    get: { mcp.isReadOnly },
                    set: { mcp.setReadOnly($0, app: app) }
                ))
                .help(String(localized: "Нужно на случай «пусть агент посмотрит, но ничего не трогает». Агент получит отказ с этой причиной — он сможет объяснить её вам."))
                // Доступ по сети (HTTP-режим). Отдельно от «только
                // чтения»: тот про права, этот про то, откуда можно прийти.
                Toggle(String(localized: "Отдавать MCP по сети (HTTP)"), isOn: Binding(
                    get: { settings.configuration.mcpOverHTTP },
                    set: { mcp.setHTTP($0, app: app) }
                ))
                if settings.configuration.mcpOverHTTP, let address = mcp.httpAddress(app) {
                    LabeledContent(String(localized: "Адрес")) {
                        Text(address)
                            .font(.body.monospaced())
                            .copyable(address)
                    }
                    .contextMenu {
                        Button(String(localized: "Скопировать адрес")) { model.copy(address) }
                    }
                }
            } header: {
                SectionHeader(
                    String(localized: "MCP-сервер"),
                    help: String(localized: "Через него агентские приложения работают с базой инструментами, а не запросами к API. Права — те же ключи, что на вкладке «Ключи».")
                )
            } footer: {
                VStack(alignment: .leading) {
                    if mcp.isReadOnly {
                        Notice(.info, String(localized: "Запись и удаление запрещены всем ключам, даже тем, кому они разрешены."))
                    }
                    if settings.configuration.mcpOverHTTP {
                        if mcp.httpAddress(app) == nil {
                            Text("Адрес появится, когда заработает прокси: MCP по сети живёт на том же порту и с теми же ключами.")
                        } else if app.proxy.tls == .plain {
                            Notice(.warning, String(localized: "Трафик не шифруется: ключ агента пойдёт по сети открытым текстом. Включите TLS на экране «Безопасность»."))
                        }
                    } else {
                        Text("Агент подключается только через вспомогательный файл на этом Mac. По сети MCP недоступен.")
                    }
                }
            }

            Section {
                if mcp.connections.isEmpty {
                    Text("Никто не подключён. Соединение появляется, когда агентское приложение запускает вспомогательный файл chromadb-mcp.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(mcp.connections) { connection in
                        LabeledContent {
                            Text(String(localized: "вызовов: \(connection.callCount.plainDigits)"))
                        } label: {
                            StatusLabel(connection.clientName == nil ? .warning : .ok, connection.title)
                            Text(connection.lastTool.map {
                                String(localized: "с \(connection.connectedAt.formatted(date: .omitted, time: .shortened)) · последний вызов: \($0)")
                            } ?? String(localized: "с \(connection.connectedAt.formatted(date: .omitted, time: .shortened))"))
                        }
                    }
                }
            } header: {
                Text("Подключены сейчас")
            }

            Section {
                HowItWorks(screen: "clients", String(localized: "Ключи одни на оба транспорта: HTTP через прокси и инструменты MCP. Приложение хранит только хеш ключа — показать его снова оно не может, забытый ключ перевыпускают. Доступ по умолчанию закрыт: новый ключ не даёт ни одной коллекции и умеет только читать. Пока ключей нет, прокси отклоняет всё."))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Форма ключа

/// Права, коллекции, лимиты и подключение агента одного ключа.
private struct ClientForm: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    let client: ExternalClient
    @ObservedObject var model: ClientsViewModel
    @Binding var collectionFilter: String
    let proxyNote: String?
    /// Выбор коллекций — листом (v3): тридцать флажков внутри формы
    /// делали её бесконечной.
    @State private var choosingCollections = false
    /// Раскрыт ли блок агента — своё состояние формы, чтобы раскрытие шло
    /// своей анимацией и было известно, когда она кончится.
    @State private var agentExpanded = false
    /// Прокрутить к блоку агента. Блок — в самом низу длинной формы, и без
    /// прокрутки раскрытие уходит за край: кажется, что ничего не произошло
    ///.
    @State private var scrollRequest = 0
    private static let agentAnchor = "agent"

    var body: some View {
        ScrollViewReader { scroll in
            form
                .onChange(of: scrollRequest) { _, _ in
                    withAnimation { scroll.scrollTo(Self.agentAnchor, anchor: .top) }
                }
        }
        // Блок агента раскрывается из одного места — и щелчком по заголовку,
        // и из меню ключа, и из листа нового ключа (через модель).
        .onChange(of: model.configuringClientID) { _, opened in
            setAgentExpanded(opened == client.id)
        }
        .onAppear {
            // Форма заводится заново при смене ключа, а подключение агента
            // могли открыть вместе с ней (лист нового ключа).
            if model.configuringClientID == client.id { setAgentExpanded(true) }
        }
    }

    /// Прокрутка — после анимации раскрытия: до её конца строк блока ещё нет
    /// в раскладке, и `scrollTo` ничего не делает (проверено в окне).
    private func setAgentExpanded(_ open: Bool) {
        guard agentExpanded != open else { return }
        withAnimation {
            agentExpanded = open
        } completion: {
            if open { scrollRequest += 1 }
        }
    }

    private var form: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Ключ"), value: "\(client.keyPrefix)…")
                LabeledContent(String(localized: "Создан"), value: client.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent(
                    String(localized: "Последняя активность"),
                    value: client.lastSeenAt.map { $0.formatted(date: .abbreviated, time: .standard) }
                        ?? String(localized: "ещё не подключался")
                )
            } header: {
                // Активен или отозван — переключателем в заголовке формы.
                HStack {
                    Text(client.name).font(.headline)
                    Spacer()
                    Toggle(String(localized: "Активен"), isOn: Binding(
                        get: { client.isEnabled },
                        set: { model.setEnabled($0, for: client, app: app) }
                    ))
                    .toggleStyle(.switch)
                }
            } footer: {
                if let proxyNote {
                    Notice(.info, proxyNote)
                }
            }

            if let permissions = model.binding(for: client, app: app) {
                rightsSection(permissions)
                collectionsSection(permissions)
                limitsSection(permissions)
            }

            connectionSection
            agentSection
        }
        .formStyle(.grouped)
        // Лист — у формы, а не у секции: `.sheet` на секции формы не
        // открывается (проверено в окне).
        .sheet(isPresented: $choosingCollections) {
            if let permissions = model.binding(for: client, app: app) {
                collectionsSheet(permissions)
            }
        }
    }

    private func rightsSection(_ permissions: Binding<ClientPermissions>) -> some View {
        Section {
            Toggle(String(localized: "Разрешить запись"), isOn: permissions.allowsWrite)
            // Удаление — поверх записи и отдельно: снести коллекцию одним
            // неудачным вызовом слишком легко.
            Toggle(String(localized: "Разрешить удаление документов"), isOn: permissions.allowsDelete)
                .disabled(!permissions.wrappedValue.allowsWrite)
        } header: {
            Text("Права")
        } footer: {
            if permissions.wrappedValue.allowsWrite, permissions.wrappedValue.allowsDelete {
                Notice(.warning, String(localized: "Клиент сможет удалять документы по их идентификаторам. Копии попадут в корзину, если она включена в настройках."))
            }
        }
    }

    /// Белый список: ничего не разрешено, пока не отмечено здесь. В форме —
    /// сколько отмечено; сам выбор — в листе.
    private func collectionsSection(_ permissions: Binding<ClientPermissions>) -> some View {
        Section {
            LabeledContent(String(localized: "Коллекции")) {
                if model.knownCollections.isEmpty {
                    Text("список пуст — нет подключения к базе")
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(permissions.wrappedValue.collections.count.plainDigits) из \(model.knownCollections.count.plainDigits)")
                        .monospacedDigit()
                }
                Button(String(localized: "Выбрать…")) { choosingCollections = true }
                    .disabled(model.knownCollections.isEmpty)
            }
        } footer: {
            Text("Новый ключ не видит ни одной коллекции, пока её не отметят.")
        }
    }

    /// Выбор коллекций ключа: поиск и флажки. Отметка действует сразу, как
    /// и остальные права в форме.
    private func collectionsSheet(_ permissions: Binding<ClientPermissions>) -> some View {
        let names = model.knownCollections.filter {
            collectionFilter.isEmpty || $0.localizedCaseInsensitiveContains(collectionFilter)
        }
        return SheetFrame(height: .tall) {
            Section {
                TextField(String(localized: "Найти коллекцию"), text: $collectionFilter, prompt: Text("Найти коллекцию"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            } header: {
                Text("Коллекции «\(client.name)»")
            }
            Section {
                ForEach(names, id: \.self) { name in
                    Toggle(name, isOn: Binding(
                        get: { permissions.wrappedValue.collections.contains(name) },
                        set: { _ in model.toggleCollection(name, for: client, app: app) }
                    ))
                    .toggleStyle(.checkbox)
                }
            } footer: {
                Text("Отмечено \(permissions.wrappedValue.collections.count.plainDigits) из \(model.knownCollections.count.plainDigits).")
            }
        } actions: {
            Spacer()
            Button(String(localized: "Готово")) { choosingCollections = false }
                .keyboardShortcut(.defaultAction)
        }
    }

    /// Лимиты — в «Для опытных», с одним «?» на весь блок; у каждого
    /// поля своя подсказка: числа похожи, а действуют по-разному.
    private func limitsSection(_ permissions: Binding<ClientPermissions>) -> some View {
        AdvancedSection(
            screen: "clients.limits",
            title: String(localized: "Лимиты"),
            help: String(localized: "Пределы защищают базу и контекст агента. Суточная квота и размер документа отклоняют запись целиком; символьные пределы обрезают ответ агенту и говорят об этом в самом ответе; частота запросов — ведро с жетонами поверх суточной квоты. Пустое поле — значение по умолчанию, оно видно в самом поле. Подробности — в подсказке у каждого поля.")
        ) {
            LimitField(
                title: String(localized: "Документов в сутки"),
                value: permissions.maxDocumentsPerDay,
                defaultValue: nil,
                help: String(localized: "Сколько документов этот ключ может записать за сутки. Считаются только записи: чтение квоту не расходует и не останавливается, когда она исчерпана. Запрос, который её превысил бы, отклоняется целиком, а в ответе сказано, сколько уже записано сегодня. Пусто — предела нет.")
            )
            LimitField(
                title: String(localized: "Размер документа, КБ"),
                value: Binding(
                    get: { permissions.wrappedValue.maxDocumentBytes.map { $0 / 1024 } },
                    set: { permissions.wrappedValue.maxDocumentBytes = $0.map { $0 * 1024 } }
                ),
                defaultValue: nil,
                help: String(localized: "Предел на **один** записываемый документ. Если в запросе окажется документ крупнее, отклоняется весь запрос, а в ответе названы фактический и разрешённый размеры. Пусто — предела нет.")
            )
            // Потолок выдачи агенту: всё, что вернул MCP, попадает
            // в контекст модели целиком.
            LimitField(
                title: String(localized: "Результатов в MCP"),
                value: permissions.maxSearchResults,
                defaultValue: 10,
                help: String(localized: "Сколько результатов агент получит на один поиск. Просьба о большем не отклоняется: отдаётся потолок, и в ответе сказано, что запрос урезан, — иначе агент решит, что в коллекции больше ничего нет. Пусто — десять. Больше \(RetrievalLimits.maximumResults.plainDigits) поставить нельзя: столько отдаёт конвейер, и обещать здесь больше значило бы обещать несуществующее.")
            )
            // Символьные потолки — рядом: упирается агент обычно в них.
            LimitField(
                title: String(localized: "Символов в документе"),
                value: permissions.maxDocumentCharacters,
                defaultValue: 4000,
                help: String(localized: "Сколько знаков текста одного найденного документа попадёт в ответ. Остальное обрезается — дочитать документ агент может вызовом get_documents по его id. Всё, что отдано, уходит в контекст модели целиком, поэтому предел здесь стоит не ради базы, а ради него. Пусто — четыре тысячи.")
            )
            LimitField(
                title: String(localized: "Символов в ответе"),
                value: permissions.maxResponseCharacters,
                defaultValue: 24000,
                help: String(localized: "Общий бюджет одного ответа: тексты и метаданные всех результатов вместе. Когда бюджет исчерпан, список обрывается, и в ответе сказано, сколько результатов показано из скольких. Первый результат отдаётся всегда, даже если занимает весь бюджет: ответ без единого результата хуже. Пусто — двадцать четыре тысячи.")
            )
            // десять коллекций — это десять поисков на один вызов.
            LimitField(
                title: String(localized: "Коллекций в поиске"),
                value: permissions.maxSearchCollections,
                defaultValue: 5,
                help: String(localized: "Сколько коллекций агент обыщет одним вызовом: десять коллекций — это десять поисков за раз. Лишние не отбрасываются молча — в ответе сказано, сколько из запрошенных обыскано и что остальные можно взять следующим вызовом. Пусто — пять.")
            )
            // Умный поиск решается отдельно от коллекции: человек у экрана
            // видит выдачу и правит запрос, а агент — нет.
            Picker(String(localized: "Умный поиск в MCP"), selection: Binding(
                get: { permissions.wrappedValue.smartSearch },
                set: { permissions.wrappedValue.smartSearch = $0 }
            )) {
                Text(String(localized: "как у коллекции")).tag(Bool?.none)
                Text(String(localized: "включён")).tag(Bool?.some(true))
                Text(String(localized: "выключен")).tag(Bool?.some(false))
            }
            .help(String(localized: "Переписывать ли запрос агента и переранжировать ли выдачу перед ответом. «Как у коллекции» — по её собственной настройке. Решается отдельно от коллекции потому, что случаи разные: человек у экрана видит выдачу и правит запрос сам, а агент — нет."))
            if let used = model.usageToday[client.id], used > 0 {
                LabeledContent(String(localized: "Сегодня записано"), value: used.plainDigits)
            }

            // Rate, not just volume: a loop in a client agent spends a daily
            // quota in a minute, and the daily limit does nothing about it.
            CountField(
                title: String(localized: "Запросов в минуту"), value: permissions.requestsPerMinute,
                help: String(localized: "Сколько обращений ключ может сделать за минуту — считаются и чтения, и записи. Устроено как ведро с жетонами: жетоны копятся ровным темпом, тратятся по запросу, и когда их нет, ответом будет отказ. Нужно поверх суточной квоты: цикл в агенте съедает её за минуту, и предела в сутках против этого мало.")
            )
            CountField(
                title: String(localized: "Всплеск"), value: permissions.burst,
                help: String(localized: "Размер того самого ведра: сколько запросов подряд можно сделать сверх ровного темпа. Агент, который проснулся и задал десять вопросов разом, пройдёт; тот, что стучит без остановки, упрётся в темп.")
            )
            CountField(
                title: String(localized: "Записей в минуту"), value: permissions.writesPerMinute,
                help: String(localized: "Отдельный счёт для записывающих вызовов, поверх общего: записи стоят дороже чтений и меняют базу. Всплеск у них свой — половина общего.")
            )
            if let throttled = model.throttledToday[client.id], throttled > 0 {
                LabeledContent(String(localized: "Отклонено по частоте сегодня")) {
                    StatusLabel(.warning, throttled.plainDigits)
                }
            }

            // CORS is off until an origin is listed, and `*` asks first.
            // С рамкой, как числа над ним; шире их — адресов
            // бывает несколько.
            LabeledContent(String(localized: "Разрешённые origin (CORS)")) {
                originsField(permissions)
            }
            .help(String(localized: "Пусто — из браузера нельзя."))
            // Вопрос — на поле, а не на секции «Лимиты»: на секции формы
            // диалог не открывается.
            .confirmationDialog(
                String(localized: "Разрешить любой origin?"),
                isPresented: Binding(
                    get: { model.pendingWildcardClientID == client.id },
                    set: { if !$0 { model.pendingWildcardClientID = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(String(localized: "Разрешить «*»"), role: .destructive) {
                    permissions.wrappedValue.allowedOrigins = ["*"]
                    model.pendingWildcardClientID = nil
                }
                Button(String(localized: "Отменить"), role: .cancel) { model.pendingWildcardClientID = nil }
            } message: {
                Text(String(localized: "Любая веб-страница, открытая в браузере, сможет обращаться к прокси с ключом клиента «\(client.name)». Обычно нужен конкретный адрес вида https://example.com."))
            }
            if permissions.wrappedValue.allowsAnyOrigin {
                Notice(.warning, String(localized: "Разрешён любой origin: любая открытая вами страница сможет обращаться к базе с этим ключом."))
            }
        }
    }

    private func originsField(_ permissions: Binding<ClientPermissions>) -> some View {
        // Пустое поле говорит, что значит пустота, как и пределы над ним:
        // «Пустое поле — значение по умолчанию, оно видно в самом поле».
        CommaListField(
            String(localized: "Разрешённые origin (CORS)"),
            items: permissions.wrappedValue.allowedOrigins,
            prompt: String(localized: "из браузера нельзя")
        ) { parts in
            if parts.contains("*"), !permissions.wrappedValue.allowsAnyOrigin {
                // Held back until confirmed: `*` means any page the user
                // opens can use this key.
                model.pendingWildcardClientID = client.id
                permissions.wrappedValue.allowedOrigins = parts.filter { $0 != "*" }
            } else {
                permissions.wrappedValue.allowedOrigins = parts
            }
        }
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 320)
    }

    /// Как подключается клиент — у ключа, где этот ключ и есть: раньше
    /// пример жил на «Безопасности», в отрыве от ключа, который в него
    /// подставляют.
    private var connectionSection: some View {
        let example = SecurityViewModel.connectionExample(configuration: settings.configuration)
        return Section {
            HStack(alignment: .top) {
                Text(example)
                    .font(.caption.monospaced())
                    .copyable(example)
                Spacer()
                // Иконка «копировать» допустима у команд.
                Button {
                    model.copy(example)
                } label: {
                    Label(String(localized: "Скопировать команду"), systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Скопировать команду"))
            }
        } header: {
            Text("Как подключается клиент")
        } footer: {
            Text("Вместо «КЛЮЧ» — ключ этого клиента. Файл chromadb-manager.pem сохраняется в «Безопасность» → «Доступ по сети», если трафик шифруется.")
        }
    }

    // MARK: Подключение агента

    /// Раскрывается так же, как «Лимиты» (v5): одна раскрывающаяся секция,
    /// а не строка-`DisclosureGroup` внутри карточки. Подвала у такой секции
    /// нет — пояснение последней строкой.
    private var agentSection: some View {
        let expanded = Binding(
            get: { agentExpanded },
            set: { model.configuringClientID = $0 ? client.id : nil }
        )
        return Section(isExpanded: expanded) {
            agentContent
            Text("Готовая конфигурация для агентского приложения и проверка её.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } header: {
            Text("Подключение агента (MCP)")
                .togglesDisclosure(expanded)
        }
    }

    @ViewBuilder
    private var agentContent: some View {
        Text("Вставьте это в настройки агентского приложения и перезапустите его. Файл у каждого свой: \(MCPConnectionConfig.configPaths.joined(separator: "; ")).")
            .foregroundStyle(.secondary)
            .id(Self.agentAnchor)

        LabeledContent(String(localized: "JSON для конфигурации агента")) {
            Text(model.agentConfiguration(for: client))
                .font(.caption.monospaced())
                .copyable(model.agentConfiguration(for: client))
        }
        if !model.hasKeyAtHand(client) {
            // Ключ показывается один раз (7.4) — подставить его нечем.
            Notice(.warning, String(localized: "Вместо ключа — заглушка: приложение хранит только его хеш. Подставьте сохранённый ключ или перевыпустите его — тогда конфигурация соберётся целиком."))
        }
        LabeledContent(String(localized: "Или одной командой в терминале")) {
            HStack(alignment: .top) {
                Text(model.agentCommandLine(for: client))
                    .font(.caption.monospaced())
                    .copyable(model.agentCommandLine(for: client))
                // Иконка «копировать» допустима только у команд.
                Button {
                    model.copy(model.agentCommandLine(for: client))
                } label: {
                    Label(String(localized: "Скопировать команду"), systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Скопировать команду"))
            }
        }

        agentButtons

        HStack {
            Button(String(localized: "Скопировать конфигурацию")) {
                model.copyAgentConfiguration(for: client)
            }
            Spacer()
            if model.checkingClientID == client.id {
                ProgressView().controlSize(.small)
            }
            Button(String(localized: "Проверить подключение")) {
                model.checkConnection(for: client)
            }
            .disabled(model.checkingClientID == client.id)
        }

        if let check = model.checks[client.id] {
            ForEach(check.steps) { step in
                LabeledContent {
                    Text(step.detail).foregroundStyle(.secondary)
                } label: {
                    StatusLabel(stepState(step.outcome), step.title)
                }
            }
            StatusLabel(
                check.isOK ? .ok : (check.firstProblem == nil ? .warning : .error),
                check.summary
            )
        }
    }

    private func stepState(_ outcome: MCPConnectionCheck.Outcome) -> StatusLabel.State {
        switch outcome {
        case .ok: return .ok
        case .warning: return .warning
        case .failed: return .error
        }
    }

    /// Настроить агента, найденного на этой машине, — вместо переписывания
    /// путей и ключа руками.
    @ViewBuilder
    private var agentButtons: some View {
        let agents = model.installedAgents
        if !agents.isEmpty {
            LabeledContent(String(localized: "Прописать сервер в агента")) {
                HStack {
                    ForEach(agents, id: \.self) { agent in
                        Button(agent.title) { model.installServer(agent, for: client) }
                            .disabled(!model.hasKeyAtHand(client))
                    }
                }
            }
            .help(model.hasKeyAtHand(client)
                  ? ""
                  : String(localized: "Кнопки ждут ключ: он есть на руках только сразу после выпуска. Перевыпустите — и настройка запишется вместе с ним."))
            LabeledContent(String(localized: "Положить агенту SKILL.md")) {
                HStack {
                    ForEach(agents, id: \.self) { agent in
                        Button(agent.title) { model.installSkill(agent) }
                    }
                }
            }
            LabeledContent(String(localized: "Положить скилл из папки")) {
                HStack {
                    ForEach(agents, id: \.self) { agent in
                        Button(agent.title) { model.installSkillFromFolder(agent) }
                    }
                }
            }
            .help(String(localized: "Первая кнопка ставит английский скилл приложения — на этом языке отвечает и сам сервер. Русский вариант лежит рядом, Contents/Resources/Skills/chromadb-manager/SKILL.ru.md. Вторая берёт любой скилл из его папки и кладёт её агенту целиком, вместе с references и scripts: имя берётся из шапки SKILL.md, служебное (.git, .DS_Store) не едет. Прежние файлы агента сохраняются снимком."))
        }
    }
}

/// Поле частоты — строкой формы: подпись, подсказка и число.
private struct CountField: View {
    let title: String
    @Binding var value: Int
    let help: String

    var body: some View {
        // Тем же видом, что `LimitField` над ним: подпись слева, поле
        // с рамкой справа. Поле без рамки в той же секции читалось как
        // значение, которое нельзя изменить, и строки шли вразнобой.
        LabeledContent(title) {
            TextField(title, value: $value, format: .number)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .limitFieldWidth()
        }
        .help(help)
    }
}

/// Поле предела: подпись, подсказка и само поле.
///
/// Значение по умолчанию приходит **числом**: в пустом поле стоит
/// само число, а «пусто — столько-то» сказано в подсказке.
private struct LimitField: View {
    let title: String
    @Binding var value: Int?
    /// Значение, которое действует при пустом поле. `nil` — предела нет.
    let defaultValue: Int?
    /// Что этот предел делает на самом деле: один отклоняет запись целиком,
    /// другой молча обрезает текст в ответе агенту.
    let help: String

    private var placeholder: String {
        guard let defaultValue else { return String(localized: "без лимита") }
        return defaultValue.formatted()
    }

    var body: some View {
        // Подпись слева, поле с рамкой справа (v4 A5): поле без рамки
        // читалось как текст, который нельзя изменить. Числа — с разрядами,
        // как везде в приложении (v4 A3).
        LabeledContent(title) {
            TextField(title, value: $value, format: .number, prompt: Text(placeholder))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .limitFieldWidth()
        }
        .help(help)
    }
}

/// Когда перечитывать список коллекций экрана клиентов.
private struct CollectionsTick: Equatable {
    let revision: Int
    let connected: Bool
}
