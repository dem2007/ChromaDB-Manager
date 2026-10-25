import SwiftUI
import ChromaCore

/// «Обзор → Подключение»: куда подключено приложение и как.
///
/// Тип А — форма. Подключиться и отключиться — одна кнопка в тулбаре,
/// подпись по состоянию; состояние подключения видно в подвале
/// сайдбара, здесь оно не повторяется.
struct ConnectionView: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var processManager: ChromaProcessManager
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var model: ConnectionViewModel
    @ObservedObject var collectionsModel: CollectionsViewModel
    /// Лист «Существующий сервер» — у модели флага нет, лист чисто экранный.
    @State private var addingExternal = false
    /// Профиль сервера, который просят удалить, — ждёт подтверждения.
    @State private var profilePendingDeletion: ServerProfile?

    var body: some View {
        Form {
            messages
            modeSection
            if settings.configuration.mode == .localDatabase {
                localDatabaseSection
            } else {
                profilesSection
            }
            // «база X в тенанте Y не найдена — создать?», а не сырая ошибка,
            // которую надо расшифровывать.
            if let missing = app.missingDatabase {
                Section {
                    Text(String(localized: "База «\(missing.database)» в тенанте «\(missing.tenant)» на сервере отсутствует."))
                    HStack {
                        Spacer()
                        Button(String(localized: "Не создавать")) { app.missingDatabase = nil }
                        Button(String(localized: "Создать базу")) {
                            Task { await model.createMissingDatabase(app) }
                        }
                    }
                } header: {
                    Text("База не найдена")
                } footer: {
                    Text("Удаление тенантов и баз из приложения не предусмотрено — это делается через CLI.")
                }
            }
            // Пределы записи и таймауты настраивают раз в жизни и только на
            // медленном удалённом сервере.
            AdvancedSection(
                screen: "connection",
                footer: String(localized: "Таймауты — от 1 до 3600 секунд. Применяются при следующем подключении.")
            ) {
                timeoutRows
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { connectionButton }
        }
        .task { await model.refreshLocalDatabaseInfo(app) }
        .sheet(isPresented: $model.showServerWizard) { wizard }
        .sheet(isPresented: $addingExternal) { externalSheet }
        .sheet(isPresented: Binding(
            get: { model.tokenEditorProfileID != nil },
            set: { if !$0 { model.tokenEditorProfileID = nil } }
        )) { tokenSheet }
        // поставить «только чтение» — одно движение; снять — решение.
        .confirmationDialog(
            String(localized: "Разрешить запись в эту базу?"),
            isPresented: Binding(
                get: { model.confirmLiftingReadOnly != nil },
                set: { if !$0 { model.confirmLiftingReadOnly = nil } }
            ),
            titleVisibility: .visible,
            presenting: model.confirmLiftingReadOnly
        ) { target in
            Button(String(localized: "Разрешить запись"), role: .destructive) {
                model.liftReadOnly(target, app: app)
            }
            Button(String(localized: "Отменить"), role: .cancel) { model.confirmLiftingReadOnly = nil }
        } message: { _ in
            Text(String(localized: "Режим «только чтение» защищает базу от записи из любого места: формы, импорта, синхронизации источников. Снять его стоит, только если вы собираетесь менять содержимое. Применится при следующем подключении."))
        }
    }

    // MARK: - Подключение

    /// Одна кнопка: подключиться, когда подключения нет, и отключиться, когда
    /// оно есть. Отключиться можно и от запущенного сервера, к которому
    /// подключение не удалось.
    @ViewBuilder
    private var connectionButton: some View {
        if case .connecting = app.connection {
            ProgressView().controlSize(.small)
        } else if app.connection.isConnected || processManager.isRunning {
            Button {
                Task { await app.disconnect() }
            } label: {
                Label(String(localized: "Отключиться"), systemImage: "bolt.slash")
            }
            .help(String(localized: "Отключиться от базы"))
        } else {
            Button {
                Task {
                    await app.reconnect()
                    await collectionsModel.refresh(app)
                }
            } label: {
                Label(String(localized: "Подключиться"), systemImage: "bolt")
            }
            .help(String(localized: "Подключиться к базе"))
        }
    }

    @ViewBuilder
    private var messages: some View {
        if let error = model.errorMessage {
            Section {
                LabeledContent {
                    Button(String(localized: "Скрыть")) { model.errorMessage = nil }
                        .buttonStyle(.borderless)
                } label: {
                    Notice(.warning, error)
                }
            }
        }
        if let status = model.statusMessage {
            Section {
                LabeledContent {
                    Button(String(localized: "Скрыть")) { model.statusMessage = nil }
                        .buttonStyle(.borderless)
                } label: {
                    Notice(.info, status)
                }
            }
        }
    }

    // MARK: - Режим

    private var modeSection: some View {
        Section {
            Picker(String(localized: "Режим работы"), selection: $settings.configuration.mode) {
                ForEach(ConnectionKind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
        } footer: {
            Text(settings.configuration.mode == .localDatabase
                 ? String(localized: "Папка с базой на этом Mac. Приложение само открывает и закрывает её; настраивать порты не нужно.")
                 : String(localized: "Именованный профиль: либо сервер, который запускает приложение, либо уже работающий экземпляр ChromaDB по адресу host:port."))
        }
    }

    // MARK: - Локальная база

    private var localDatabaseSection: some View {
        let inspection = model.localDatabaseInfo
        return Section {
            LabeledContent(String(localized: "Папка")) {
                Text(app.localDatabaseURL.path)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .copyable(app.localDatabaseURL.path)
                    .help(app.localDatabaseURL.path)
                Menu {
                    Button(String(localized: "Выбрать папку…")) { model.chooseLocalDirectory(app) }
                    Button(String(localized: "По умолчанию")) { model.useDefaultLocalDirectory(app) }
                    Divider()
                    Button(String(localized: "Показать в Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([app.localDatabaseURL])
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(String(localized: "Папка базы"))
                .accessibilityLabel(String(localized: "Папка базы"))
            }
            LabeledContent(String(localized: "Каталог")) {
                Text(catalogueSummary(inspection))
            }
            Toggle(String(localized: "Открывать только для чтения"), isOn: Binding(
                get: { settings.configuration.localDatabaseIsReadOnly },
                set: { newValue in
                    // Поставить — бесплатно; снять — шаг, требующий ответа.
                    if newValue {
                        settings.configuration.localDatabaseIsReadOnly = true
                    } else {
                        model.confirmLiftingReadOnly = .localDatabase
                    }
                }
            ))
        } header: {
            Text("Папка базы")
        } footer: {
            if !app.environmentStatus.canRunServer {
                Notice(.warning, String(localized: "Движок не установлен — открыть локальную базу нельзя. Подключение к внешнему серверу при этом работает."))
            } else {
                Text("Только чтение: запись, импорт и синхронизация отклоняются. Применяется при следующем подключении.")
            }
        }
    }

    private func catalogueSummary(_ inspection: DatabaseDirectoryInfo) -> String {
        guard inspection.exists else { return String(localized: "Каталог будет создан") }
        let kind = inspection.looksLikeChroma
            ? String(localized: "Похоже на базу ChromaDB")
            : String(localized: "Пока пустой каталог")
        return "\(kind) · \(inspection.sizeText)"
    }

    // MARK: - Профили серверов

    private var profilesSection: some View {
        Section {
            if settings.configuration.serverProfiles.isEmpty {
                Text("Профилей пока нет.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(settings.configuration.serverProfiles) { profile in
                    profileRow(profile)
                        // У строки профиля, а не у секции: диалог на секции
                        // формы не открывается.
                        .confirmationDialog(
                            String(localized: "Удалить профиль «\(profile.name)»?"),
                            isPresented: Binding(
                                get: { profilePendingDeletion?.id == profile.id },
                                set: { if !$0 { profilePendingDeletion = nil } }
                            ),
                            titleVisibility: .visible
                        ) {
                            Button(String(localized: "Удалить"), role: .destructive) { model.delete(profile, app: app) }
                            Button(String(localized: "Отменить"), role: .cancel) {}
                        } message: {
                            Text("Приложение забудет адрес и настройки этого сервера. Сам сервер и его данные не трогаются.")
                        }
                }
            }
            HStack {
                Spacer()
                Menu(String(localized: "Добавить сервер")) {
                    Button(String(localized: "Новый сервер…")) { model.prepareWizard(app) }
                    Button(String(localized: "Существующий сервер…")) { addingExternal = true }
                }
                .fixedSize()
            }
        } header: {
            SectionHeader(
                String(localized: "Профили серверов"),
                help: String(localized: "Свои профили приложение запускает и останавливает само; внешние — только подключается. Выбранный профиль — тот, к которому подключается кнопка «Подключиться».")
            )
        } footer: {
            Text("Щелчок по профилю делает его текущим.")
        }
    }

    private func isRunning(_ profile: ServerProfile) -> Bool {
        // Порт — не имя: у новых профилей он по умолчанию один и тот же.
        // Там, где у профиля есть своя база, сверяется и она.
        processManager.isRunning
            && processManager.endpoint?.port == profile.port
            && (profile.databasePath.map { path in
                processManager.databasePath.map {
                    URL(fileURLWithPath: $0).standardizedFileURL.path
                        == URL(fileURLWithPath: path).standardizedFileURL.path
                } ?? false
            } ?? true)
    }

    private func profileRow(_ profile: ServerProfile) -> some View {
        let isSelected = settings.configuration.selectedProfileID == profile.id
        let running = isRunning(profile)
        return LabeledContent {
            Menu {
                Button(String(localized: "Проверить")) { Task { await model.test(profile, app: app) } }
                    .disabled(model.isTesting)
                if profile.kind == .managed {
                    if running {
                        Button(String(localized: "Остановить")) { Task { await model.stopServer(app) } }
                    } else {
                        Button(String(localized: "Запустить")) { Task { await model.startManagedServer(profile, app: app) } }
                            .disabled(!app.environmentStatus.canRunServer)
                    }
                }
                Divider()
                Button(String(localized: "Задать токен…")) { model.beginTokenEditing(profile) }
                Toggle(String(localized: "Только чтение"), isOn: Binding(
                    get: { profile.isReadOnly },
                    set: { newValue in
                        if newValue {
                            var updated = profile
                            updated.isReadOnly = true
                            settings.upsert(profile: updated)
                        } else {
                            model.confirmLiftingReadOnly = .profile(profile.id)
                        }
                    }
                ))
                if profile.kind == .managed {
                    Toggle(String(localized: "Разрешить сброс базы (allow_reset)"), isOn: Binding(
                        get: { profile.allowReset },
                        set: { newValue in
                            var updated = profile
                            updated.allowReset = newValue
                            settings.upsert(profile: updated)
                        }
                    ))
                }
                Divider()
                Button(String(localized: "Удалить профиль…"), role: .destructive) {
                    profilePendingDeletion = profile
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(String(localized: "Действия с профилем"))
            .accessibilityLabel(String(localized: "Действия с профилем"))
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .accessibilityLabel(isSelected ? String(localized: "Текущий профиль") : "")
                VStack(alignment: .leading) {
                    HStack {
                        Text(profile.name)
                        if model.hasToken(profile, app: app) {
                            Image(systemName: "key.fill")
                                .foregroundStyle(.secondary)
                                .help(String(localized: "Токен хранится в Keychain"))
                        }
                    }
                    Text("\(profile.displayAddress) · \(profile.kind == .managed ? String(localized: "свой") : String(localized: "внешний"))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if profile.tenant != ChromaEndpoint.defaultTenant || profile.database != ChromaEndpoint.defaultDatabase {
                        Text(verbatim: "tenant: \(profile.tenant) · database: \(profile.database)")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if let path = profile.databasePath {
                        Text(path)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                    }
                    if running {
                        StatusLabel(.ok, String(localized: "запущен"))
                            .font(.callout)
                    }
                    if let result = model.testResults[profile.id] {
                        Text(result)
                            .font(.callout)
                            .copyable(result)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.select(profile, app: app) }
    }

    // MARK: - Для опытных

    /// Таймауты по классам операций: умолчания верны для локального
    /// сервера, трогать их нужно только медленному удалённому.
    @ViewBuilder
    private var timeoutRows: some View {
        timeoutField(String(localized: "Проверка доступности"), keyPath: \.liveness)
        timeoutField(String(localized: "Список коллекций, счётчики"), keyPath: \.metadata)
        timeoutField(String(localized: "Страница документов"), keyPath: \.fetch)
        timeoutField(String(localized: "Поисковый запрос"), keyPath: \.query)
        timeoutField(String(localized: "Запись одной части"), keyPath: \.write)
        timeoutField(String(localized: "Эмбеддинг батча (LM Studio)"), keyPath: \.embedding)
        timeoutField(String(localized: "Ответ чат-модели"), keyPath: \.chat)
    }

    private func timeoutField(_ title: String, keyPath: WritableKeyPath<TimeoutSettings, TimeInterval>) -> some View {
        let label = String(localized: "\(title), с")
        return LabeledContent(label) {
            TextField(label, value: Binding(
                get: { settings.configuration.timeouts[keyPath: keyPath] },
                set: { newValue in
                    let range = TimeoutSettings.allowedRange
                    settings.configuration.timeouts[keyPath: keyPath] = min(max(newValue, range.lowerBound), range.upperBound)
                }
            ), format: .number)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .numberFieldWidth()
            // Стрелки рядом с полем (v3): без них поле без рамки читалось
            // как текст, который нельзя изменить.
            Stepper(label, value: Binding(
                get: { settings.configuration.timeouts[keyPath: keyPath] },
                set: { settings.configuration.timeouts[keyPath: keyPath] = $0 }
            ), in: TimeoutSettings.allowedRange, step: 1)
            .labelsHidden()
        }
    }

    // MARK: - Листы

    private var wizard: some View {
        SheetForm(
            cancel: { model.showServerWizard = false },
            confirmTitle: String(localized: "Создать профиль"),
            confirm: { model.createManagedProfile(app) }
        ) {
            Section {
                TextField(String(localized: "Имя профиля"), text: $model.draftName)
                LabeledContent(String(localized: "Каталог базы")) {
                    TextField(String(localized: "Каталог базы"), text: $model.draftPath)
                        .labelsHidden()
                    Button(String(localized: "Выбрать…")) { model.chooseDraftPath() }
                }
                TextField(String(localized: "Порт"), text: $model.draftPort)
                Toggle(String(localized: "Разрешить сброс базы (allow_reset)"), isOn: $model.draftAllowReset)
            } header: {
                SectionHeader(
                    String(localized: "Новый сервер"),
                    help: String(localized: "Сервер, который запускает это приложение, всегда слушает 127.0.0.1: доступ с других машин идёт через прокси — единственную часть, которая проверяет ключи. Приложение сгенерирует YAML-конфигурацию сервера и запустит «chroma run <config>».")
                )
            } footer: {
                Text("Без allow_reset сервер отказывает в сбросе — даже вам.")
            }
        }
    }

    private var externalSheet: some View {
        SheetForm(
            cancel: { addingExternal = false },
            confirmTitle: String(localized: "Добавить"),
            confirm: {
                model.addExternalProfile(app)
                if model.errorMessage == nil { addingExternal = false }
            }
        ) {
            Section {
                TextField(String(localized: "Имя"), text: $model.externalName)
                TextField(String(localized: "Адрес"), text: $model.externalHost, prompt: Text(verbatim: "host"))
                TextField(String(localized: "Порт"), text: $model.externalPort, prompt: Text(verbatim: "8000"))
                Toggle(String(localized: "HTTPS"), isOn: $model.externalTLS)
            } header: {
                Text("Существующий сервер")
            }
            Section {
                TextField(String(localized: "Тенант"), text: $model.externalTenant, prompt: Text(verbatim: "default_tenant"))
                LabeledContent(String(localized: "База")) {
                    TextField(String(localized: "База"), text: $model.externalDatabase, prompt: Text(verbatim: "default_database"))
                        .labelsHidden()
                    // Базы перечислить можно, тенанты — нет: сервер отвечает
                    // 405 на список тенантов, поэтому выбор есть у одного.
                    Menu(String(localized: "Обзор баз")) {
                        if model.availableDatabases.isEmpty {
                            Button(String(localized: "Запросить список")) {
                                Task { await model.browseDatabases(app) }
                            }
                            .disabled(model.isBrowsingDatabases)
                        } else {
                            ForEach(model.availableDatabases, id: \.self) { name in
                                Button(name) { model.externalDatabase = name }
                            }
                        }
                    }
                    .fixedSize()
                }
            }
            Section {
                SecureField(String(localized: "Токен"), text: $model.externalToken, prompt: Text("необязательно"))
                // Заголовок выбирается сразу: с неверным профиль создаётся
                // молча нерабочим.
                Picker(String(localized: "Заголовок токена"), selection: $model.externalTokenHeader) {
                    ForEach(ServerProfile.TokenHeader.allCases, id: \.self) { header in
                        Text(header.title).tag(header)
                    }
                }
                .disabled(model.externalToken.isEmpty)
            } footer: {
                Text("Токен сохраняется в Keychain и не попадает ни в конфигурацию, ни в логи.")
            }
        }
    }

    @ViewBuilder
    private var tokenSheet: some View {
        if let id = model.tokenEditorProfileID,
           let profile = settings.configuration.serverProfiles.first(where: { $0.id == id }) {
            SheetForm(
                cancel: { model.tokenEditorProfileID = nil },
                confirmTitle: String(localized: "Сохранить"),
                confirm: { model.saveToken(for: profile, app: app) }
            ) {
                Section {
                    SecureField(String(localized: "Токен"), text: $model.tokenDraft)
                    Picker(String(localized: "Заголовок токена"), selection: Binding(
                        get: { profile.tokenHeader },
                        set: { newValue in
                            var updated = profile
                            updated.tokenHeader = newValue
                            settings.upsert(profile: updated)
                        }
                    )) {
                        ForEach(ServerProfile.TokenHeader.allCases) { header in
                            Text(header.title).tag(header)
                        }
                    }
                } header: {
                    Text(String(localized: "Токен для «\(profile.name)»"))
                } footer: {
                    Text("Токен сохраняется в Keychain.")
                }
            }
        }
    }
}
