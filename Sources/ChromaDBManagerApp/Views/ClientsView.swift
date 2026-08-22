import SwiftUI
import ChromaCore

/// Spec: the list of external clients, their keys, rights and limits.
struct ClientsView: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var proxy: ProxyServer
    @ObservedObject var model: ClientsViewModel
    @ObservedObject var mcp: MCPService

    private var clients: [ExternalClient] { settings.configuration.externalClients }

    /// Последние обращения агентов — из общего журнала доступа.
    private var recentMCPCalls: [AuditEntry] {
        Array(app.audit.entries.filter { $0.transport == .mcp }.prefix(8))
    }

    /// Разрез экрана: «Ключи», «MCP», «Журнал».
    var tab: Int = 0

    /// Расшифровка «умного поиска» — она одна на экран: карточек ключей
    /// много, но открытых поповеров одновременно не бывает.
    @State private var showingSmartSearchHelp = false

    var body: some View {
        // Reader ради одного: «Настроить подключение агента» открывает блок
        // ниже по странице, и без прокрутки к нему кнопка выглядела так,
        // будто ничего не сделала.
        ScrollViewReader { scroll in
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                if let error = model.errorMessage {
                    MessageBanner(kind: .error, text: error) { model.errorMessage = nil }
                }
                if let status = model.statusMessage {
                    MessageBanner(kind: .success, text: status) { model.statusMessage = nil }
                }
                // Прокси и MCP — два транспорта поверх одних и тех же ключей,
                // и остановленный прокси больше не значит «ключи ни к чему
                // не дают доступа»: через MCP они работают.
                if !proxy.state.isRunning {
                    MessageBanner(
                        kind: .info,
                        text: mcp.isListening
                            ? String(localized: "Прокси не запущен — по HTTP ключи не работают. Через MCP они действуют: сервер слушает.")
                            : String(localized: "Прокси не запущен — ключи ни к чему не дают доступа. Запустить его можно на экране «Обзор» → «Сервер».")
                    )
                }

                switch tab {
                case 1:
                    mcpCard
                case 2:
                    journalCard
                default:
                    if let fresh = model.freshKey {
                        freshKeyCard(fresh)
                    }
                    newClientCard
                    if clients.isEmpty {
                        SectionCard(
                            title: String(localized: "Клиентов пока нет"),
                            subtitle: String(localized: "Пока не создан ни один ключ, прокси отклоняет все запросы: доступ по умолчанию закрыт.")
                        ) {
                            Text("Ключ создаётся без прав — только чтение и ни одной коллекции. Что именно ему разрешено, решается в его карточке.")
                                .font(Theme.Font.body).foregroundStyle(Theme.Palette.captionText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        ForEach(clients) { client in
                            clientCard(client)
                        }
                    }
                }

                howItWorks
            }
            .padding(.top, 4)
            .pageContentPadding()
        }
        .onChange(of: model.configuringClientID) { _, opened in
            guard let opened else { return }
            withAnimation { scroll.scrollTo(Self.agentAnchor(opened), anchor: .top) }
        }
        .task { await model.refresh(app) }
        }
    }

    /// Якорь блока «Подключение агента» — по клиенту, а не один на экран:
    /// карточек столько же, сколько ключей.
    private static func agentAnchor(_ id: UUID) -> String { "agent-\(id.uuidString)" }

    private var howItWorks: some View {
        HowItWorks(screen: "clients") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ключи одни на оба транспорта: HTTP через прокси и инструменты MCP. Приложение хранит только хеш ключа — показать его снова оно не может, забытый ключ перевыпускают.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Доступ по умолчанию закрыт: новый ключ не даёт ни одной коллекции и умеет только читать. Пока ключей нет, прокси отклоняет всё.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Вкладка «Журнал»: что делали агенты — из общего журнала доступа.
    private var journalCard: some View {
        SectionCard(
            title: String(localized: "Последние обращения"),
            subtitle: String(localized: "Что вызывали агенты через MCP. Полный журнал доступа, включая HTTP, — на экране «Логи»."),
            help: String(localized: "Записи те же, что и в журнале доступа: время, клиент, инструмент, коллекция и причина отказа, если он был. Параметры вызова видны по наведению.")
        ) {
            VStack(alignment: .leading, spacing: 6) {
                if recentMCPCalls.isEmpty {
                    Text("Обращений ещё не было.")
                        .font(Theme.Font.body).foregroundStyle(Theme.Palette.captionText)
                } else {
                    ForEach(recentMCPCalls) { entry in
                        journalRow(entry)
                    }
                }
            }
        }
    }

    /// Время обращения — с датой, когда оно не сегодняшнее.
    ///
    /// Одно время без даты читается как «только что»: восемь строк подряд
    /// с «15:25» и «17:32» выглядят получасом работы, а на деле это три дня.
    /// Именно из-за этого «ещё не подключался» рядом с полным журналом
    /// казалось противоречием, хотя противоречия не было.
    private func journalTime(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .standard)
            : date.formatted(date: .abbreviated, time: .shortened)
    }

    private func journalRow(_ entry: AuditEntry) -> some View {
        HStack(spacing: 8) {
            Text(journalTime(entry.date))
                .font(Theme.Font.mono).foregroundStyle(Theme.Palette.captionText)
            Text(entry.client).font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.captionText)
            Text(entry.operation).font(Theme.Font.caption)
            if let collection = entry.collection {
                Text(collection).font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.captionText)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if let note = entry.note {
                Text(note)
                    .font(Theme.Font.caption)
                    .foregroundStyle(entry.isWrite ? Theme.Palette.attention : Theme.Palette.captionText)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
        // Полный текст параметров — тот же, что в журнале доступа: D2.5
        // требует, чтобы он был доступен.
        .help(entry.parameters ?? "")
    }

    // MARK: - MCP: состояние, режим и активность

    private var mcpCard: some View {
        SectionCard(
            title: String(localized: "MCP-сервер"),
            subtitle: String(localized: "Через него агентские приложения работают с базой инструментами, а не запросами к API. Права — те же ключи, что ниже.")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    StatusDot(state: mcp.isListening ? .ok : (mcp.lastError == nil ? .unknown : .missing))
                    Text(mcp.isListening
                         ? String(localized: "Слушает")
                         : String(localized: "Не запущен"))
                        .font(Theme.Font.body)
                    if let error = mcp.lastError {
                        Text(error).font(Theme.Font.caption).foregroundStyle(Theme.Palette.danger)
                    }
                    Spacer()
                    if mcp.callCount > 0 {
                        Text(String(localized: "обращений за сеанс: \(mcp.callCount.plainDigits)"))
                            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    }
                }

                Divider()

                Toggle(String(localized: "Только чтение для всех ключей"), isOn: Binding(
                    get: { mcp.isReadOnly },
                    set: { mcp.setReadOnly($0, app: app) }
                ))
                Text(mcp.isReadOnly
                     ? String(localized: "Запись и удаление запрещены всем ключам, даже тем, кому они разрешены. Агент получит отказ с этой причиной — он сможет объяснить её вам.")
                     : String(localized: "Ключи работают по своим правам. Переключатель нужен на случай «пусть агент посмотрит, но ничего не трогает»."))
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                // Доступ по сети (HTTP-режим). Отдельно от «только
                // чтения»: тот про права, этот про то, откуда вообще можно
                // прийти.
                Toggle(String(localized: "Отдавать MCP по сети (HTTP)"), isOn: Binding(
                    get: { settings.configuration.mcpOverHTTP },
                    set: { mcp.setHTTP($0, app: app) }
                ))
                if settings.configuration.mcpOverHTTP {
                    if let address = mcp.httpAddress(app) {
                        HStack(alignment: .top, spacing: 6) {
                            Text(address).font(Theme.Font.mono).textSelection(.enabled)
                            Button {
                                model.copy(address)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help(String(localized: "Скопировать адрес"))
                        }
                        if app.proxy.tls == .plain {
                            Text(String(localized: "Трафик не шифруется: ключ агента пойдёт по сети открытым текстом. Включите TLS на экране «Безопасность»."))
                                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text(String(localized: "Адрес появится, когда заработает прокси: MCP по сети живёт на том же порту и с теми же ключами."))
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(String(localized: "Агент подключается только через вспомогательный файл на этом Маке. По сети MCP недоступен."))
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                Text(String(localized: "Подключены сейчас")).font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                if mcp.connections.isEmpty {
                    Text(String(localized: "Никто не подключён. Соединение появляется, когда агентское приложение запускает вспомогательный файл chromadb-mcp."))
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(mcp.connections) { connection in
                        HStack(spacing: 8) {
                            StatusDot(state: connection.clientName == nil ? .warning : .ok)
                            Text(connection.title).font(Theme.Font.caption)
                            Text(String(localized: "с \(connection.connectedAt.formatted(date: .omitted, time: .shortened))"))
                                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                            if let tool = connection.lastTool {
                                Text(String(localized: "последний вызов: \(tool)"))
                                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                            }
                            Spacer(minLength: 0)
                            Text(String(localized: "вызовов: \(connection.callCount.plainDigits)"))
                                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        }
                    }
                }

            }
        }
    }

    // MARK: - The key, shown once

    private func freshKeyCard(_ fresh: (clientName: String, key: String)) -> some View {
        SectionCard(
            title: String(localized: "Ключ клиента «\(fresh.clientName)»"),
            subtitle: String(localized: "Показывается один раз. Приложение хранит только его хеш и не сможет показать ключ снова — забытый ключ можно лишь перевыпустить.")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                codeBlock(String(localized: "Ключ"), fresh.key)

                codeBlock(
                    String(localized: "Пример подключения на Python"),
                    model.snippet(
                        for: fresh.key,
                        port: settings.configuration.proxyPort,
                        usesTLS: settings.configuration.proxyUsesTLS
                    )
                )

                HStack {
                    Button(String(localized: "Скопировать ключ")) { model.copyFreshKey() }
                        .buttonStyle(.chromaPrimary)
                    Button(String(localized: "Скопировать пример")) {
                        model.copySnippet(
                            port: settings.configuration.proxyPort,
                            usesTLS: settings.configuration.proxyUsesTLS
                        )
                    }
                    // Настроить подключение агента проще всего **сейчас**:
                    // потом ключ подставить будет нечем (7.4).
                    if let client = clients.first(where: { $0.name == fresh.clientName }) {
                        Button(String(localized: "Настроить подключение агента")) {
                            model.configuringClientID = client.id
                        }
                    }
                    Spacer()
                    Button(String(localized: "Я сохранил ключ")) { model.freshKey = nil }
                }
            }
        }
    }

    private var newClientCard: some View {
        SectionCard(title: String(localized: "Новый клиент")) {
            HStack {
                TextField(String(localized: "Имя — например, «скрипт отчётов»"), text: $model.draftName)
                    .textFieldStyle(.roundedBorder)
                Button(String(localized: "Создать ключ")) { model.create(app) }
                    .buttonStyle(.chromaPrimary)
                    .disabled(model.draftName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(String(localized: "Новый ключ создаётся без прав: только чтение и ни одной коллекции. Что именно ему разрешено, решается ниже."))
                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
        }
    }

    // MARK: - One client

    private func clientCard(_ client: ExternalClient) -> some View {
        SectionCard(
            title: client.name,
            subtitle: client.permissions.summary
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    StatusDot(state: client.isEnabled ? .ok : .missing)
                    Text("\(client.keyPrefix)…").font(Theme.Font.mono)
                    Text(String(localized: "создан \(client.createdAt.formatted(date: .abbreviated, time: .shortened))"))
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    Text(client.lastSeenAt.map {
                        String(localized: "последняя активность \($0.formatted(date: .abbreviated, time: .standard))")
                    } ?? String(localized: "ещё не подключался"))
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    Spacer()
                    Toggle(String(localized: "Включён"), isOn: Binding(
                        get: { client.isEnabled },
                        set: { model.setEnabled($0, for: client, app: app) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    // Не в «Ещё»: настроить подключение — это то, ради чего
                    // ключ и создавали, и прятать его за меню значило прятать
                    // главное действие карточки.
                    Button(model.configuringClientID == client.id
                           ? String(localized: "Скрыть подключение")
                           : String(localized: "Настроить подключение агента")) {
                        model.configuringClientID = model.configuringClientID == client.id ? nil : client.id
                    }
                    .buttonStyle(.chromaSecondary)
                    Menu(String(localized: "Ещё")) {
                        Button(String(localized: "Перевыпустить ключ")) { model.reissueKey(client, app: app) }
                        Divider()
                        Button(String(localized: "Удалить клиента"), role: .destructive) {
                            model.remove(client, app: app)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                if model.configuringClientID == client.id {
                    Divider()
                    connectionCard(client)
                        .id(Self.agentAnchor(client.id))
                }

                if let permissions = model.binding(for: client, app: app) {
                    Divider()
                    permissionsEditor(client, permissions)
                }
            }
        }
    }

    /// Кусок кода — не абзац текста: рубрика сверху, моноширинный шрифт,
    /// своя рамка и заливка. Без оправы конфигурация читалась как ещё одно
    /// предложение приложения, а не как то, что нужно скопировать.
    private func codeBlock(_ caption: String, _ code: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption.uppercased())
                .font(Theme.Font.tableHeader)
                .kerning(0.5)
                .foregroundStyle(Theme.Palette.caption)
            Text(code)
                .font(Theme.Font.mono)
                .textSelection(.enabled)
                .foregroundStyle(Theme.Palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Palette.logBackground)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.field))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.field)
                        .strokeBorder(Theme.Palette.border, lineWidth: 1)
                )
        }
    }

    /// Готовая конфигурация для агентского приложения и проверка её.
    @ViewBuilder
    private func connectionCard(_ client: ExternalClient) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Подключение агента (MCP)")).font(Theme.Font.body).bold()
            Text(String(localized: "Вставьте это в настройки агентского приложения — в macOS это \(MCPConnectionConfig.desktopConfigPath) — и перезапустите его."))
                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                .fixedSize(horizontal: false, vertical: true)

            codeBlock(String(localized: "JSON для конфигурации агента"), model.agentConfiguration(for: client))

            if !model.hasKeyAtHand(client) {
                // Ключ показывается один раз (7.4) — и здесь это не отговорка,
                // а причина: подставить его приложению нечем.
                Text(String(localized: "Вместо ключа — заглушка: приложение хранит только его хеш. Подставьте сохранённый ключ или перевыпустите его — тогда конфигурация соберётся целиком."))
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }

            codeBlock(String(localized: "Или одной командой в терминале"), model.agentCommandLine(for: client))

            HStack(spacing: 8) {
                Button(String(localized: "Скопировать конфигурацию")) {
                    model.copyAgentConfiguration(for: client)
                }
                Button(String(localized: "Проверить подключение")) {
                    model.checkConnection(for: client)
                }
                .disabled(model.checkingClientID == client.id)
                if model.checkingClientID == client.id {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button(String(localized: "Скрыть")) { model.configuringClientID = nil }
            }

            if let check = model.checks[client.id] {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(check.steps) { step in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            StatusDot(state: {
                                switch step.outcome {
                                case .ok: return .ok
                                case .warning: return .warning
                                case .failed: return .missing
                                }
                            }())
                            Text(step.title).font(Theme.Font.caption)
                            Text(step.detail)
                                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(check.summary)
                        .font(Theme.Font.caption)
                        .foregroundStyle(
                            check.isOK ? Color.green : (check.firstProblem == nil ? Color.orange : Color.red)
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private func permissionsEditor(_ client: ExternalClient, _ permissions: Binding<ClientPermissions>) -> some View {
        Toggle(String(localized: "Разрешить запись"), isOn: permissions.allowsWrite)
        // Удаление — поверх записи и отдельно: снести коллекцию одним
        // неудачным вызовом слишком легко, чтобы это право ехало вместе
        // с обычной записью.
        Toggle(String(localized: "Разрешить удаление документов"), isOn: permissions.allowsDelete)
            .disabled(!permissions.wrappedValue.allowsWrite)
        if permissions.wrappedValue.allowsWrite, permissions.wrappedValue.allowsDelete {
            Label(
                String(localized: "Клиент сможет удалять документы по их идентификаторам. Копии попадут в корзину, если она включена в настройках."),
                systemImage: "exclamationmark.triangle"
            )
            .font(Theme.Font.micro).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }

        Text(String(localized: "Коллекции")).font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
        if model.knownCollections.isEmpty {
            Text(String(localized: "Список коллекций пуст — приложение не подключено к базе."))
                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
        } else {
            // A whitelist: nothing is allowed until it is ticked here.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(model.knownCollections, id: \.self) { name in
                    Toggle(name, isOn: Binding(
                        get: { permissions.wrappedValue.collections.contains(name) },
                        set: { _ in model.toggleCollection(name, for: client, app: app) }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
        }

        // Сеткой, а не одной строкой: полей шесть, и в ряд они
        // не помещаются — SwiftUI в таком случае отбирает ширину у подписей,
        // и они рассыпаются по букве в строке. Сетка переносит поля целыми
        // ячейками, сколько бы ни было места.
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: 16, alignment: .leading)],
            alignment: .leading, spacing: 10
        ) {
            limitField(
                title: String(localized: "Документов в сутки"),
                value: permissions.maxDocumentsPerDay,
                defaultValue: nil,
                help: String(localized: "Сколько документов этот ключ может записать за сутки. Считаются только записи: чтение квоту не расходует и не останавливается, когда она исчерпана. Запрос, который её превысил бы, отклоняется целиком, а в ответе сказано, сколько уже записано сегодня. Пусто — предела нет.")
            )
            limitField(
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
            limitField(
                title: String(localized: "Результатов в MCP"),
                value: permissions.maxSearchResults,
                defaultValue: 10,
                help: String(localized: "Сколько результатов агент получит на один поиск. Просьба о большем не отклоняется: отдаётся потолок, и в ответе сказано, что запрос урезан, — иначе агент решит, что в коллекции больше ничего нет. Пусто — десять. Больше \(RetrievalLimits.maximumResults.plainDigits) поставить нельзя: столько отдаёт конвейер, и обещать здесь больше значило бы обещать несуществующее.")
            )
            // Символьные потолки — рядом с ним, потому что упирается агент
            // обычно в них: счётчик результатов подняли, а ответ всё
            // равно обрывается по объёму. Всё это уходит в контекст модели.
            limitField(
                title: String(localized: "Символов в документе"),
                value: permissions.maxDocumentCharacters,
                defaultValue: 4000,
                help: String(localized: "Сколько знаков текста одного найденного документа попадёт в ответ. Остальное обрезается — дочитать документ агент может вызовом get_documents по его id. Всё, что отдано, уходит в контекст модели целиком, поэтому предел здесь стоит не ради базы, а ради него. Пусто — четыре тысячи.")
            )
            limitField(
                title: String(localized: "Символов в ответе"),
                value: permissions.maxResponseCharacters,
                defaultValue: 24000,
                help: String(localized: "Общий бюджет одного ответа: тексты и метаданные всех результатов вместе. Когда бюджет исчерпан, список обрывается, и в ответе сказано, сколько результатов показано из скольких. Первый результат отдаётся всегда, даже если занимает весь бюджет: ответ без единого результата хуже. Пусто — двадцать четыре тысячи.")
            )
            // сколько коллекций агент обыскивает одним вызовом. Десять
            // коллекций — это десять поисков на один вызов, и упереться в это
            // должен ключ.
            limitField(
                title: String(localized: "Коллекций в поиске"),
                value: permissions.maxSearchCollections,
                defaultValue: 5,
                help: String(localized: "Сколько коллекций агент обыщет одним вызовом: десять коллекций — это десять поисков за раз. Лишние не отбрасываются молча — в ответе сказано, сколько из запрошенных обыскано и что остальные можно взять следующим вызовом. Пусто — пять.")
            )
            // Умный поиск решается отдельно от коллекции: человек у экрана
            // видит выдачу и правит запрос, а агент — нет.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(String(localized: "Умный поиск в MCP")).font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: true, vertical: false)
                    HelpButton(
                        text: String(localized: "Переписывать ли запрос агента и переранжировать ли выдачу перед ответом. «Как у коллекции» — по её собственной настройке. Решается отдельно от коллекции потому, что случаи разные: человек у экрана видит выдачу и правит запрос сам, а агент — нет."),
                        isPresented: $showingSmartSearchHelp
                    )
                }
                Picker("", selection: Binding(
                    get: { permissions.wrappedValue.smartSearch },
                    set: { permissions.wrappedValue.smartSearch = $0 }
                )) {
                    Text(String(localized: "как у коллекции")).tag(Bool?.none)
                    Text(String(localized: "включён")).tag(Bool?.some(true))
                    Text(String(localized: "выключен")).tag(Bool?.some(false))
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        if let used = model.usageToday[client.id], used > 0 {
            Text(String(localized: "сегодня записано: \(used.plainDigits)"))
                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
        }

        // Rate, not just volume: a loop in a client agent spends a daily quota
        // in a minute, and the daily limit does nothing about it.
        HStack(spacing: 16) {
            countField(
                String(localized: "Запросов в минуту"), permissions.requestsPerMinute,
                help: String(localized: "Сколько обращений ключ может сделать за минуту — считаются и чтения, и записи. Устроено как ведро с жетонами: жетоны копятся ровным темпом, тратятся по запросу, и когда их нет, ответом будет отказ. Нужно поверх суточной квоты: цикл в агенте съедает её за минуту, и предела в сутках против этого мало.")
            )
            countField(
                String(localized: "Всплеск"), permissions.burst,
                help: String(localized: "Размер того самого ведра: сколько запросов подряд можно сделать сверх ровного темпа. Агент, который проснулся и задал десять вопросов разом, пройдёт; тот, что стучит без остановки, упрётся в темп.")
            )
            countField(
                String(localized: "Записей в минуту"), permissions.writesPerMinute,
                help: String(localized: "Отдельный счёт для записывающих вызовов, поверх общего: записи стоят дороже чтений и меняют базу. Всплеск у них свой — половина общего.")
            )
            if let throttled = model.throttledToday[client.id], throttled > 0 {
                Text(String(localized: "отклонено по частоте: \(throttled.plainDigits)"))
                    .font(Theme.Font.micro).foregroundStyle(.orange)
            }
            Spacer()
        }

        // CORS is off until an origin is listed, and `*` asks first.
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(String(localized: "Разрешённые origin (CORS)")).font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                TextField(
                    String(localized: "пусто — из браузера нельзя"),
                    text: Binding(
                        get: { permissions.wrappedValue.allowedOrigins.joined(separator: ", ") },
                        set: { text in
                            let parts = text.split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                            if parts.contains("*"), !permissions.wrappedValue.allowsAnyOrigin {
                                // Held back until confirmed: `*` means any page
                                // the user opens can use this key.
                                model.pendingWildcardClientID = client.id
                                permissions.wrappedValue.allowedOrigins = parts.filter { $0 != "*" }
                            } else {
                                permissions.wrappedValue.allowedOrigins = parts
                            }
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            }
            if permissions.wrappedValue.allowsAnyOrigin {
                Label(
                    String(localized: "Разрешён любой origin: любая открытая вами страница сможет обращаться к базе с этим ключом."),
                    systemImage: "exclamationmark.triangle"
                )
                .font(Theme.Font.micro).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
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
            Button(String(localized: "Отмена"), role: .cancel) { model.pendingWildcardClientID = nil }
        } message: {
            Text(String(localized: "Любая веб-страница, открытая в браузере, сможет обращаться к прокси с ключом клиента «\(client.name)». Обычно нужен конкретный адрес вида https://example.com."))
        }
    }

    private func countField(_ title: String, _ value: Binding<Int>, help: String) -> some View {
        CountField(title: title, value: value, help: help)
    }

    private func limitField(
        title: String, value: Binding<Int?>, defaultValue: Int?, help: String
    ) -> some View {
        LimitField(title: title, value: value, defaultValue: defaultValue, help: help)
    }
}

/// Поле предела: подпись, знак «?» с расшифровкой и само поле.
///
/// Отдельным видом, а не функцией: поповеру нужен свой `@State`, а он бывает
/// только у вида.
///
/// Подпись стоит **над** полем: слева она занимала ширину наравне с полем
/// ввода, и когда таких пар в ряду шесть, SwiftUI сжимал подписи до предела —
/// «Документов в сутки» превращалось в столбик по букве в строке. `fixedSize`
/// держит подпись целой: строка ужимается чем угодно, только не ею.
private struct CountField: View {
    let title: String
    @Binding var value: Int
    let help: String

    @State private var showingHelp = false

    var body: some View {
        HStack(spacing: 6) {
            // Подпись не ужимается: три пары в ряд помещаются, но
            // в узком окне SwiftUI начал бы отбирать ширину у неё же.
            Text(title).font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                .fixedSize(horizontal: true, vertical: false)
            HelpButton(text: help, isPresented: $showingHelp)
            TextField("", value: $value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
        }
    }
}

private struct LimitField: View {
    let title: String
    @Binding var value: Int?
    /// Значение, которое действует при пустом поле. `nil` — предела нет.
    ///
    /// Числом, а не готовой строкой: подсказка «по умолчанию 24000»
    /// в поле шириной 120 не помещалась и обрезалась **с конца** — то есть
    /// ровно на числе, ради которого её и читают. Осталось «по умолчанию 2».
    /// Теперь подпись строит само поле, и длинную фразу туда не вписать даже
    /// по ошибке: в поле стоит само число, а «пусто — столько-то» сказано
    /// в расшифровке под знаком вопроса.
    let defaultValue: Int?
    /// Что этот предел делает на самом деле. Числа тут похожи друг на друга,
    /// а действуют по-разному: один отклоняет запись целиком, другой молча
    /// обрезает текст в ответе агенту — и по названию поля это не видно.
    let help: String

    @State private var showingHelp = false

    private var placeholder: String {
        guard let defaultValue else { return String(localized: "без лимита") }
        return defaultValue.formatted(.number.grouping(.never))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title).font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: true, vertical: false)
                HelpButton(text: help, isPresented: $showingHelp)
            }
            TextField(placeholder, value: $value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
        }
    }
}
