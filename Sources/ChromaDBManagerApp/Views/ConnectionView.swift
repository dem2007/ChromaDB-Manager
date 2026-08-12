import SwiftUI
import ChromaCore

struct ConnectionView: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var processManager: ChromaProcessManager
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var model: ConnectionViewModel
    @ObservedObject var collectionsModel: CollectionsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                if let error = model.errorMessage {
                    MessageBanner(kind: .error, text: error) { model.errorMessage = nil }
                }
                if let status = model.statusMessage {
                    MessageBanner(kind: .success, text: status) { model.statusMessage = nil }
                }
                // Карточка подключения вернулась на экран: `header` был
                // объявлен, но нигде не вызывался — единственные кнопки
                // «Подключиться» и «Отключиться» в приложении были недоступны
                // ниоткуда, кроме значка в статусной строке.
                header
                modeCard
                if settings.configuration.mode == .localDatabase {
                    localDatabaseCard
                } else {
                    profilesCard
                }
                // «база X в тенанте Y не найдена — создать?» rather than a raw
                // error the user has to decode.
                if let missing = app.missingDatabase {
                    SectionCard(title: String(localized: "База не найдена")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(localized: "База «\(missing.database)» в тенанте «\(missing.tenant)» на сервере отсутствует."))
                                .font(Theme.Font.body)
                            HStack {
                                Button(String(localized: "Создать базу")) {
                                    Task { await model.createMissingDatabase(app) }
                                }
                                .buttonStyle(.borderedProminent)
                                Button(String(localized: "Не создавать")) { app.missingDatabase = nil }
                                Spacer()
                            }
                            Text(String(localized: "Удаление тенантов и баз из приложения не предусмотрено — это делается через CLI."))
                                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        }
                    }
                }
                // Таймауты и пределы записи настраивают раз в жизни и только
                // на медленном удалённом сервере — им место под свёрнутым
                // «Для опытных», а не первым экраном подключения.
                AdvancedSection(place: "connection") {
                    limitsCard
                    timeoutsCard
                }
            }
            .padding(.top, 8)
            .pageContentPadding()
        }
        .task { await model.refreshLocalDatabaseInfo(app) }
        .sheet(isPresented: $model.showServerWizard) { wizard }
        // putting the flag on is one click; taking it off is a decision.
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
            Button(String(localized: "Отмена"), role: .cancel) { model.confirmLiftingReadOnly = nil }
        } message: { _ in
            Text(String(localized: "Режим «только чтение» защищает базу от записи из любого места: формы, импорта, синхронизации источников. Снять его стоит, только если вы собираетесь менять содержимое. Применится при следующем подключении."))
        }
    }

    /// Состояние подключения и две кнопки к нему — карточкой, а не строкой
    /// над экраном: строка читалась как подпись раздела, которая уже есть
    /// в шапке окна.
    private var header: some View {
        SectionCard(
            title: String(localized: "Подключение"),
            subtitle: app.connection.title
        ) {
            HStack(spacing: 8) {
                Button(String(localized: "Подключиться")) {
                    Task {
                        await app.reconnect()
                        await collectionsModel.refresh(app)
                    }
                }
                .buttonStyle(.chromaPrimary)

                Button(String(localized: "Отключиться")) {
                    Task { await app.disconnect() }
                }
                .buttonStyle(.chromaNormal)
                .disabled(!app.connection.isConnected && !processManager.isRunning)
                Spacer()
            }
        }
    }

    /// What the server allows in one write request. Shown because the fallback
    /// is a guess: if it turns out to be higher than the server's real limit,
    /// the failure appears much later, in the middle of an import.
    @ViewBuilder
    private var limitsCard: some View {
        if let limits = app.writeLimits {
            SectionCard(title: String(localized: "Пределы записи")) {
                VStack(alignment: .leading, spacing: 6) {
                    if limits.isReportedByServer {
                        Label(
                            String(localized: "Записей в одном запросе: \(limits.maxRecords.plainDigits) (по данным сервера)"),
                            systemImage: "checkmark.circle"
                        ).font(Theme.Font.caption)
                    } else {
                        Label(
                            String(localized: "Лимит батча не определён, используется безопасное значение \(limits.maxRecords.plainDigits)"),
                            systemImage: "exclamationmark.triangle"
                        ).font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                    }
                    Text(String(localized: "Размер одного запроса — не больше \(ByteCountFormatter.string(fromByteCount: Int64(limits.maxBodyBytes), countStyle: .binary)); операции крупнее отправляются частями."))
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                }
            }
        }
    }

    /// Per-class deadlines. Collapsed, because the defaults are right
    /// for a local server and only a slow remote one needs them touched.
    private var timeoutsCard: some View {
        SectionCard(title: String(localized: "Таймауты")) {
            DisclosureGroup(String(localized: "Значения по классам операций")) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        timeoutField(String(localized: "Проверка доступности"), keyPath: \.liveness)
                        timeoutField(String(localized: "Список коллекций, счётчики"), keyPath: \.metadata)
                        timeoutField(String(localized: "Страница документов"), keyPath: \.fetch)
                        timeoutField(String(localized: "Поисковый запрос"), keyPath: \.query)
                        timeoutField(String(localized: "Запись одной части"), keyPath: \.write)
                        timeoutField(String(localized: "Эмбеддинг батча (LM Studio)"), keyPath: \.embedding)
                        timeoutField(String(localized: "Ответ чат-модели"), keyPath: \.chat)
                        Text(String(localized: "Секунды, от 1 до 3600. Новые значения применяются при следующем подключении."))
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    }
                    // Otherwise the value ends up a screen width from its label.
                    .frame(maxWidth: 460)
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
            }
        }
    }

    private func timeoutField(_ title: String, keyPath: WritableKeyPath<TimeoutSettings, TimeInterval>) -> some View {
        HStack {
            Text(title).font(Theme.Font.caption)
            Spacer()
            TextField("", value: Binding(
                get: { settings.configuration.timeouts[keyPath: keyPath] },
                set: { newValue in
                    let clamped = min(max(newValue, TimeoutSettings.allowedRange.lowerBound), TimeoutSettings.allowedRange.upperBound)
                    settings.configuration.timeouts[keyPath: keyPath] = clamped
                }
            ), format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
            Text(String(localized: "с")).font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
        }
    }

    private var modeCard: some View {
        SectionCard(title: String(localized: "Режим работы")) {
            SegmentedSelector(
                options: ConnectionKind.allCases.map { (value: $0, title: $0.title) },
                selection: Binding(
                    get: { settings.configuration.mode },
                    set: { settings.configuration.mode = $0 }
                )
            )

            Text(settings.configuration.mode == .localDatabase
                 ? String(localized: "Папка с базой на этом Mac. Приложение само открывает и закрывает её; настраивать порты не нужно.")
                 : String(localized: "Именованный профиль: либо сервер, который запускает приложение, либо уже работающий экземпляр ChromaDB по адресу host:port."))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.captionText)
        }
    }

    private var localDatabaseCard: some View {
        SectionCard(title: String(localized: "Папка базы")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(app.localDatabaseURL.path)
                        .font(Theme.Font.mono)
                        .copyable(app.localDatabaseURL.path)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer()
                    Button(String(localized: "Выбрать папку…")) { model.chooseLocalDirectory(app) }
                    Button(String(localized: "По умолчанию")) { model.useDefaultLocalDirectory(app) }
                }

                let inspection = model.localDatabaseInfo
                HStack(spacing: 16) {
                    Label(
                        inspection.exists ? String(localized: "Каталог существует") : String(localized: "Каталог будет создан"),
                        systemImage: inspection.exists ? "checkmark.circle" : "plus.circle"
                    )
                    .font(Theme.Font.caption)
                    if inspection.exists {
                        Text(inspection.looksLikeChroma
                             ? String(localized: "Похоже на базу ChromaDB")
                             : String(localized: "Пока пустой каталог"))
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                        Text(inspection.sizeText)
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    }
                }

                Toggle(String(localized: "Открывать только для чтения"), isOn: Binding(
                    get: { settings.configuration.localDatabaseIsReadOnly },
                    set: { newValue in
                        // Turning it on is free; taking it off is the step that
                        // needs a deliberate answer.
                        if newValue {
                            // Saved by the store itself on change.
                            settings.configuration.localDatabaseIsReadOnly = true
                        } else {
                            model.confirmLiftingReadOnly = .localDatabase
                        }
                    }
                ))
                Text(String(localized: "Запись, импорт и синхронизация отклоняются клиентом — независимо от того, откуда пришли. Применяется при следующем подключении."))
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)

                if !app.environmentStatus.canRunServer {
                    MessageBanner(
                        kind: .warning,
                        text: String(localized: "Движок не установлен — открыть локальную базу нельзя. Установите его на экране «Статус окружения». Подключение к внешнему серверу при этом работает.")
                    )
                }
            }
        }
    }

    private var profilesCard: some View {
        SectionCard(
            title: String(localized: "Профили серверов"),
            subtitle: String(localized: "Свои профили приложение запускает и останавливает само; внешние — только подключается.")
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button {
                        model.prepareWizard(app)
                    } label: {
                        Label(String(localized: "Создать новый сервер"), systemImage: "plus")
                    }
                    Spacer()
                }

                if settings.configuration.serverProfiles.isEmpty {
                    Text(String(localized: "Профилей пока нет.")).foregroundStyle(Theme.Palette.captionText).font(Theme.Font.body)
                } else {
                    ForEach(settings.configuration.serverProfiles) { profile in
                        profileRow(profile)
                        if profile.id != settings.configuration.serverProfiles.last?.id { Divider() }
                    }
                }

                Divider().padding(.vertical, 4)
                externalForm
            }
        }
    }

    private func profileRow(_ profile: ServerProfile) -> some View {
        let isSelected = settings.configuration.selectedProfileID == profile.id
        let isThisRunning = processManager.isRunning && processManager.endpoint?.port == profile.port

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(profile.name).fontWeight(.medium)
                        if isThisRunning {
                            Text(String(localized: "запущен")).font(Theme.Font.micro)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.green.opacity(0.18))
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
                        }
                        if model.hasToken(profile, app: app) {
                            Image(systemName: "key.fill").font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                                .help(String(localized: "Токен хранится в Keychain"))
                        }
                    }
                    Text("\(profile.displayAddress) · \(profile.kind == .managed ? String(localized: "свой") : String(localized: "внешний"))")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    if profile.tenant != ChromaEndpoint.defaultTenant || profile.database != ChromaEndpoint.defaultDatabase {
                        Text("tenant: \(profile.tenant) · database: \(profile.database)")
                            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    }
                    if let path = profile.databasePath {
                        Text(path).font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }

                Spacer()

                Button(String(localized: "Проверить")) {
                    Task { await model.test(profile, app: app) }
                }
                .disabled(model.isTesting)

                if profile.kind == .managed {
                    if isThisRunning {
                        Button(String(localized: "Остановить")) { Task { await model.stopServer(app) } }
                    } else {
                        Button(String(localized: "Запустить")) { Task { await model.startManagedServer(profile, app: app) } }
                            .disabled(!app.environmentStatus.canRunServer)
                    }
                }

                Menu {
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
                    Button(String(localized: "Удалить профиль"), role: .destructive) {
                        model.delete(profile, app: app)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 40)
            }

            if model.tokenEditorProfileID == profile.id {
                HStack {
                    SecureField(String(localized: "Токен доступа (сохраняется в Keychain)"), text: $model.tokenDraft)
                        .textFieldStyle(.roundedBorder)
                    Picker("", selection: Binding(
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
                    .frame(width: 200)
                    Button(String(localized: "Сохранить")) { model.saveToken(for: profile, app: app) }
                    Button(String(localized: "Отмена")) { model.tokenEditorProfileID = nil }
                }
            }

            if let result = model.testResults[profile.id] {
                Text(result).font(Theme.Font.caption).copyable(result)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { model.select(profile, app: app) }
    }

    private var externalForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Подключиться к существующему серверу")).font(Theme.Font.control).bold()
            HStack {
                TextField(String(localized: "Имя"), text: $model.externalName).frame(width: 140)
                TextField("Host", text: $model.externalHost).frame(width: 150)
                TextField("Port", text: $model.externalPort).frame(width: 70)
                Toggle("HTTPS", isOn: $model.externalTLS)
            }
            HStack {
                TextField("tenant", text: $model.externalTenant).frame(width: 150)
                TextField("database", text: $model.externalDatabase).frame(width: 150)
                // Databases can be listed, tenants cannot — the server answers
                // 405 to a tenant listing, so only one of the two gets
                // a picker.
                Button(String(localized: "Обзор баз…")) {
                    Task { await model.browseDatabases(app) }
                }
                .disabled(model.isBrowsingDatabases)
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                SecureField(String(localized: "Токен (необязательно)"), text: $model.externalToken).frame(width: 200)
                // Заголовок токена выбирается здесь, а не только у уже
                // созданного профиля: ChromaDB принимает либо Authorization,
                // либо X-Chroma-Token — смотря как её настроили, и с неверным
                // заголовком профиль создаётся молча нерабочим.
                Picker("", selection: $model.externalTokenHeader) {
                    ForEach(ServerProfile.TokenHeader.allCases, id: \.self) { header in
                        Text(header.title).tag(header)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
                .disabled(model.externalToken.isEmpty)
                Button(String(localized: "Добавить")) { model.addExternalProfile(app) }
                    .buttonStyle(.chromaNormal)
                Spacer(minLength: 0)
            }
            if !model.availableDatabases.isEmpty {
                HStack(spacing: 6) {
                    Text(String(localized: "Базы тенанта:")).font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    ForEach(model.availableDatabases, id: \.self) { name in
                        Button(name) { model.externalDatabase = name }
                            .buttonStyle(.link)
                            .font(Theme.Font.micro)
                    }
                }
            }
            Text(String(localized: "Токен сохраняется в Keychain и не попадает ни в конфигурацию, ни в логи."))
                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
        }
        .textFieldStyle(.roundedBorder)
    }

    private var wizard: some View {
        SheetShell(
            title: String(localized: "Новый сервер"),
            subtitle: String(localized: "Параметры сохранятся как профиль; запускать и останавливать его можно одной кнопкой."),
            help: String(localized: "Сервер, который запускает это приложение, всегда слушает 127.0.0.1: доступ с других машин идёт через прокси — единственную часть, которая проверяет ключи. Приложение сгенерирует YAML-конфигурацию сервера и запустит «chroma run <config>»."),
            width: 580,
            height: nil,
            scrolls: false
        ) {
            VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                TextField(String(localized: "Имя профиля"), text: $model.draftName)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 10) {
                    TextField(String(localized: "Каталог базы"), text: $model.draftPath)
                        .textFieldStyle(.roundedBorder)
                    Button(String(localized: "Выбрать…")) { model.chooseDraftPath() }
                        .buttonStyle(.chromaSecondary)
                }
                HStack(spacing: 10) {
                    Text("Порт").font(Theme.Font.control)
                    TextField("Port", text: $model.draftPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(String(localized: "Разрешить сброс базы (allow_reset)"), isOn: $model.draftAllowReset)
                        .font(Theme.Font.control)
                    Text("Без этого сервер отказывает в сбросе — даже вам.")
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        .padding(.leading, 18)
                }
            }
        } actions: {
            Button(String(localized: "Отмена")) { model.showServerWizard = false }
                .buttonStyle(.chromaNormal)
            Button(String(localized: "Создать профиль")) { model.createManagedProfile(app) }
                .buttonStyle(.chromaPrimary)
        }
    }
}
