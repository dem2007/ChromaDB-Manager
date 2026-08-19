import SwiftUI
import ChromaCore

struct EnvironmentStatusView: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var model: EnvironmentViewModel
    /// moving this machine's setup to another one.
    @StateObject private var transfer = SettingsTransferViewModel()
    /// Какой разрез экрана открыт: «Проверки», «Установка», «Копии», «Данные».
    var tab: Int = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                if let error = model.errorMessage {
                    MessageBanner(kind: .error, text: error) { model.errorMessage = nil }
                }
                if let hint = model.hint {
                    MessageBanner(kind: .warning, text: hint) { model.hint = nil }
                }
                if let info = model.infoMessage {
                    MessageBanner(kind: .success, text: info) { model.infoMessage = nil }
                }
                if model.verificationFailed {
                    MessageBanner(
                        kind: .error,
                        text: String(localized: "Обновление не прошло проверку целостности. Восстановите резервную копию — список ниже.")
                    )
                }

                // Вкладки — разрезы одной темы «окружение приложения», а не
                // разные темы: движок, его установка, копии базы и данные
                // самого приложения. Порядок внутри вкладки прежний.
                switch tab {
                case 1:
                    backupsCard
                    // Сжатие базы — рядом с копиями: порядок в нём начинается
                    // с копии, и держать их на разных вкладках значит просить
                    // человека прыгать.
                    maintenanceCard
                case 2:
                    // Про само приложение, а не про движок: версия, перенос
                    // настроек, строка меню и стирание данных — одна тема.
                    appUpdateCard
                    wipeCard
                    transferCard
                    MenuBarSettingsCard()
                default:
                    // Сначала — чего не хватает, потом — как это поставить:
                    // проверки и установка стали одной вкладкой.
                    checksCard
                    // Python больше не карточка: он нужен только второму
                    // способу установки и живёт его параметрами.
                    installCard
                    // Процессы chroma от прошлых запусков переехали на «Обзор»
                    //: они держат порт и базу, и место такой находке —
                    // на первом экране, а не на вкладке, до которой надо
                    // додуматься.
                    consoleCard
                    permissionsCard
                }
            }
            .padding(.top, 4)
            .pageContentPadding()
        }
        .sheet(item: $transfer.pending) { pending in importConfirmation(pending) }
        .sheet(isPresented: $model.showStandaloneConfirmation) { standaloneConfirmation }
        .sheet(isPresented: $model.showUpgradeSheet) { upgradeSheet }
        .task {
            model.refreshBackups(app)
            await model.probeMaintenance(app)
        }
    }

    // MARK: - Обновления приложения

    /// Проверка новой версии — по кнопке или с явно включённой галочкой.
    ///
    /// Скачивать и ставить приложение само не будет никогда: это чужая машина
    /// и чужое решение. Кнопка открывает страницу релиза, дальше человек
    /// разбирается сам — тем более что сборка не нотаризована, и подсунуть ей
    /// автообновление означало бы подсунуть непроверенный бинарник.
    private var appUpdateCard: some View {
        SectionCard(
            title: String(localized: "Версия приложения"),
            subtitle: String(localized: "Проверка спрашивает страницу релизов на GitHub и ничего не скачивает. Обновление ставится руками."),
            help: String(localized: "Встроенного автообновления в приложении нет и не будет: сборка распространяется через GitHub, и решение обновиться остаётся за вами.")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(AppUpdateChecker.currentVersion().map { String(localized: "Установлена версия \($0)") }
                        ?? String(localized: "Версия неизвестна: приложение запущено не из бандла"))
                        .font(Theme.Font.body)
                    Spacer()
                    if model.isCheckingAppUpdate {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(String(localized: "Проверить обновления")) {
                            Task { await model.checkAppUpdates(app) }
                        }
                        .buttonStyle(.chromaNormal)
                    }
                }

                if let error = model.appUpdateError {
                    Text(error).font(Theme.Font.caption).foregroundStyle(Theme.Palette.danger)
                }

                switch model.appUpdate {
                case .available(let release, _):
                    releaseDetails(release, isNew: true)
                case .upToDate:
                    Text(String(localized: "Установлена последняя версия."))
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                case .unknownCurrentVersion(let release):
                    Text(String(localized: "Сравнить не с чем: версия есть только у собранного приложения. Последний выпущенный релиз показан ниже."))
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    if let release { releaseDetails(release, isNew: false) }
                case .none:
                    EmptyView()
                }

                Divider()

                Toggle(String(localized: "Проверять обновления приложения при запуске"), isOn: Binding(
                    get: { settings.configuration.checkAppUpdatesOnLaunch },
                    set: { settings.configuration.checkAppUpdatesOnLaunch = $0 }
                ))
                Text(String(localized: "Выключено по умолчанию: пока галочка снята, приложение не обращается к GitHub само."))
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
            }
        }
    }

    @ViewBuilder
    private func releaseDetails(_ release: AppRelease, isNew: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(isNew
                    ? String(localized: "Доступна версия \(release.version)")
                    : String(localized: "Последний релиз: \(release.version)"))
                    .font(Theme.Font.body)
                    .foregroundStyle(isNew ? Theme.Palette.attention : Theme.Palette.captionText)
                if let date = release.publishedAt {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                }
            }
            if !release.notes.isEmpty {
                // Описание релиза показывается как есть и целиком: сокращать
                // чужой список изменений — значит решать за человека, что ему
                // важно. Длинный список прокручивается вместе с экраном.
                Text(release.notes)
                    .font(Theme.Font.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(String(localized: "Открыть страницу релиза")) { model.openReleasePage(release) }
        }
    }

    // MARK: - Перенос настроек

    private var transferCard: some View {
        SectionCard(
            title: String(localized: "Перенос настроек"),
            subtitle: String(localized: "Один файл со всем, кроме секретов: профили подключений, источники, схемы метаданных, сохранённые фильтры, клиенты и общие настройки приложения.")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if let error = transfer.errorMessage {
                    MessageBanner(kind: .error, text: error) { transfer.errorMessage = nil }
                }
                if let status = transfer.statusMessage {
                    MessageBanner(kind: .success, text: status) { transfer.statusMessage = nil }
                }

                HStack {
                    Button(String(localized: "Экспортировать настройки")) { transfer.export(app) }
                        .buttonStyle(.chromaNormal)
                    Button(String(localized: "Импортировать настройки…")) { transfer.chooseFileForImport(app) }
                        .buttonStyle(.chromaNormal)
                    Spacer()
                }

                Text(String(localized: "Токены серверов и ключи клиентов не экспортируются никогда — они лежат в Keychain и на другой машине запрашиваются заново. Импортированный клиент остаётся без ключа и никого не пропускает, пока ключ не выпущен."))
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(localized: "Коллекции и векторы это не переносит — для них есть экспорт коллекции. Вместе они дают полный перенос на другую машину."))
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The plan, before anything is written: an import that merged on the spot
    /// would be the one place in the app where everything changes at once with
    /// nothing shown (rule 2 of Приложение 5).
    private func importConfirmation(_ pending: SettingsTransferViewModel.PendingImport) -> some View {
        let plan = pending.plan
        return SheetShell(
            title: String(localized: "Импорт настроек"),
            subtitle: String(localized: "Файл «\(pending.fileName)», записан \(pending.bundle.exportedAt.formatted(date: .abbreviated, time: .shortened)), версия приложения \(pending.bundle.appVersion)."),
            help: String(localized: "Ничего не записывается, пока вы не подтвердите. Записи с теми же идентификаторами заменяются, остальное добавляется, и ничего из того, чего нет в файле, не удаляется. Токены серверов и ключи клиентов не переносятся никогда — они лежат в Keychain."),
            width: 520,
            height: nil,
            scrolls: false
        ) {
            if plan.isEmpty {
                Text(String(localized: "В файле нет ни одной записи — импортировать нечего."))
                    .foregroundStyle(Theme.Palette.attention)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    planRow(String(localized: "Профили подключений"), plan.profiles)
                    planRow(String(localized: "Источники"), plan.sources)
                    planRow(String(localized: "Схемы метаданных"), plan.schemas)
                    planRow(String(localized: "Сохранённые фильтры"), plan.filters)
                    planRow(String(localized: "Клиенты"), plan.clients)
                    planRow(String(localized: "Общие профили таблиц"), plan.tableProfiles)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Toggle(String(localized: "Применить общие настройки приложения"), isOn: Binding(
                    get: { transfer.pending?.includePreferences ?? true },
                    set: { transfer.pending?.includePreferences = $0 }
                ))
                .font(Theme.Font.control)
                Text(String(localized: "Адрес LM Studio, модель по умолчанию, кэш, таймауты, хранение логов, корзина, порог предпросмотра."))
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 18)
            }

            if !plan.missingFolders.isEmpty {
                Text(String(localized: "Папок нет на этом компьютере: \(plan.missingFolders.count.plainDigits). Источник появится, но синхронизировать ему будет нечего, пока путь не поправлен."))
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !plan.profilesNeedingToken.isEmpty {
                Text(String(localized: "Токен нужно ввести заново: \(plan.profilesNeedingToken.joined(separator: ", "))"))
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !plan.clientsNeedingKey.isEmpty {
                Text(String(localized: "Ключ нужно выпустить заново: \(plan.clientsNeedingKey.joined(separator: ", "))"))
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Button(String(localized: "Отмена")) { transfer.cancelImport() }
                .buttonStyle(.chromaNormal)
            Button(String(localized: "Импортировать")) { transfer.confirmImport(app) }
                .buttonStyle(.chromaPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(plan.isEmpty)
        }
    }

    private func planRow(_ title: String, _ category: SettingsImportPlan.Category) -> some View {
        HStack {
            Text(title).font(Theme.Font.body)
                .frame(width: 200, alignment: .leading)
            Text(category.isEmpty
                 ? String(localized: "нет")
                 : String(localized: "добавится \(category.added.plainDigits), заменится \(category.replaced.plainDigits)"))
                .font(Theme.Font.body)
                .foregroundStyle(category.isEmpty ? .secondary : .primary)
            Spacer()
        }
    }

    /// Проверки окружения — и кнопка, которая их повторяет.
    ///
    /// Время последней проверки и «Проверить заново» стояли строкой над
    /// карточкой, как заголовок экрана: подпись про окружение читалась дважды,
    /// а кнопка относилась неизвестно к чему. В макете и то и другое — часть
    /// самой карточки.
    private var checksCard: some View {
        let items = app.environmentStatus.items(for: settings.configuration.preferredInstallPath)
        return SectionCard(
            title: String(localized: "Проверки"),
            // Проверки показываются те, что относятся к выбранному способу
            // установки, — поэтому экран и говорит, к какому именно.
            subtitle: app.environmentStatus.checkedAt.map {
                String(localized: "Последняя проверка в \($0.formatted(date: .omitted, time: .standard)). Способ установки — «\(settings.configuration.preferredInstallPath.title)»; проверки других способов не показываются.")
            } ?? String(localized: "Идёт первая проверка… Способ установки — «\(settings.configuration.preferredInstallPath.title)»; проверки других способов не показываются."),
            help: String(localized: "Движок — это Chroma CLI: именно он запускает сервер. Автономному бинарнику Python не нужен вовсе, поэтому при нём проверки Python, pip и пакета chromadb не показываются: они не о вашем случае. Способ установки меняется на соседней вкладке.")
        ) {
            VStack(alignment: .leading, spacing: Theme.Padding.cardContentSpacing) {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        CheckRow(item: item, action: action(for: item))
                        if item.id != items.last?.id { Divider() }
                    }
                }
                HStack(spacing: 10) {
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                        Text(model.busyTitle).font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.captionText)
                        Button(String(localized: "Остановить")) { model.cancel() }
                            .buttonStyle(.chromaSecondary)
                    } else {
                        Button(String(localized: "Проверить заново")) {
                            Task { await model.refresh(app, checkUpdates: false) }
                        }
                        .buttonStyle(.chromaNormal)
                    }
                    Spacer()
                }
            }
        }
    }

    private func action(for item: CheckItem) -> (title: String, handler: () -> Void)? {
        switch item.id {
        case "updates":
            return (String(localized: "Проверить"), { model.checkForUpdates(app) })
        case "engine" where app.environmentStatus.updateAvailable:
            return (String(localized: "Обновить"), { model.showUpgradeSheet = true })
        case "pip" where app.environmentStatus.pipVersion == nil && app.environmentStatus.activeInterpreter != nil:
            return (String(localized: "Починить pip"), { model.bootstrapPip(app) })
        default:
            return nil
        }
    }

    /// Установка движка — два способа строками, как в макете.
    ///
    /// Способов ровно два, и они взаимоисключающие: выбор — это не поле формы
    /// среди прочих, а развилка, с которой начинается вся вкладка. Поэтому оба
    /// варианта названы вместе с последствием («без Python» / «нужен Python»),
    /// а у выбранного тут же лежат его параметры: раньше параметры второго
    /// способа стояли отдельной карточкой «Python», которую при первом способе
    /// читали впустую.
    private var installCard: some View {
        SectionCard(
            title: String(localized: "Установка движка"),
            subtitle: String(localized: "Приложение показывает точный адрес загрузки и команду до того, как что-либо запускает."),
            help: String(localized: "Автономный бинарник берётся из официального релиза проекта на GitHub и кладётся в каталог приложения: в /usr/local/bin нужен sudo, которого у приложения нет. Второй способ — pip install chromadb в отдельное виртуальное окружение приложения; системный Python и Homebrew-питон он не затрагивает (PEP 668).")
        ) {
            VStack(alignment: .leading, spacing: 12) {
                installOption(.standalone)
                installOption(.managedVenv)

                installActions

                Toggle(String(localized: "Проверять обновления автоматически при запуске"), isOn: Binding(
                    get: { settings.configuration.checkUpdatesAutomatically },
                    set: { settings.configuration.checkUpdatesAutomatically = $0 }
                ))
                .font(Theme.Font.body)
                Text(String(localized: "Выключено по умолчанию: проверка обращается к GitHub или PyPI."))
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
            }
        }
    }

    /// Один способ установки: точка выбора, название, следствие — и параметры
    /// внутри, если у способа они есть и он выбран.
    private func installOption(_ path: EngineInstallPath) -> some View {
        let isSelected = settings.configuration.preferredInstallPath == path
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                settings.configuration.preferredInstallPath = path
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    RadioMark(isOn: isSelected)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(path.title)
                            .font(Theme.Font.control)
                            .foregroundStyle(Theme.Palette.primaryText)
                        Text(installSummary(path))
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.captionText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isSelected, path == .managedVenv {
                Divider()
                pythonParameters
            }
        }
        .padding(.horizontal, Theme.Padding.rowHorizontal)
        .padding(.vertical, Theme.Padding.rowVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Theme.Palette.accent.opacity(0.08) : Theme.Palette.subtleFill)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.row).strokeBorder(
                isSelected ? Theme.Palette.accent.opacity(0.35) : Theme.Palette.border,
                lineWidth: 1
            )
        )
    }

    private func installSummary(_ path: EngineInstallPath) -> String {
        switch path {
        case .standalone:
            return String(localized: "Готовый бинарник из релиза проекта. Python не нужен вовсе.")
        case .managedVenv:
            return String(localized: "Пакет chromadb в собственном окружении приложения. Нужен Python 3.")
        }
    }

    /// Параметры второго способа: чем создавать venv и где взять Python.
    private var pythonParameters: some View {
        VStack(alignment: .leading, spacing: 10) {
            if app.environmentStatus.interpreters.isEmpty {
                Text(String(localized: "Интерпретаторы Python 3 не найдены — поставьте любой из двух кнопок ниже."))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker(String(localized: "Базовый интерпретатор для venv"), selection: Binding(
                    get: { settings.configuration.preferredPythonPath ?? app.environmentStatus.activeInterpreter?.path ?? "" },
                    set: { newValue in
                        settings.configuration.preferredPythonPath = newValue
                        Task { await model.refresh(app, checkUpdates: false) }
                    }
                )) {
                    ForEach(app.environmentStatus.interpreters) { interpreter in
                        Text(interpreter.displayName).tag(interpreter.path)
                    }
                }
                .pickerStyle(.menu)
                .font(Theme.Font.control)
            }

            HStack(spacing: 10) {
                Button(String(localized: "Установить Python (Homebrew)")) {
                    model.installPythonWithHomebrew(app)
                }
                .buttonStyle(.chromaNormal)
                .disabled(app.environmentStatus.homebrewPath == nil || model.isBusy)
                .help(app.environmentStatus.homebrewPath.map { "\($0) install python@3.12" }
                      ?? String(localized: "Homebrew не найден в системе"))

                Button(String(localized: "Скачать с python.org")) {
                    model.openPythonDownloadPage()
                }
                .buttonStyle(.chromaNormal)
                Spacer(minLength: 0)
            }
        }
    }

    /// Действия способа: слева — установка выбранным способом, справа —
    /// обновление уже стоящего движка. Синяя в ряду одна: пока движка нет,
    /// главное — поставить; когда стоит — обновить.
    private var installActions: some View {
        let isStandalone = settings.configuration.preferredInstallPath == .standalone
        // «Установлено» — про выбранный способ, а не про движок вообще:
        // найденный автономный бинарник ничего не говорит о том, есть ли
        // пакет в venv, и надпись «Переустановить в venv» на пустом venv
        // была бы неправдой.
        let isReady = isStandalone
            ? app.environmentStatus.isEngineInstalled
            : app.environmentStatus.chromadbPackageVersion != nil
        return HStack(spacing: 10) {
            if isStandalone {
                Button(isReady
                       ? String(localized: "Переустановить CLI")
                       : String(localized: "Установить ChromaDB")) {
                    model.prepareStandaloneInstall(app)
                }
                .buttonStyle(isReady ? .chromaNormal : .chromaPrimary)
                .disabled(model.isBusy)

                Button(String(localized: "Открыть install.sh")) { model.openInstallScriptPage() }
                    .buttonStyle(.chromaNormal)
                    .help(InstallationService.officialInstallScriptURL.absoluteString)
            } else {
                Button(isReady
                       ? String(localized: "Переустановить в venv")
                       : String(localized: "Установить в venv")) {
                    model.installIntoVenv(app)
                }
                .buttonStyle(isReady ? .chromaNormal : .chromaPrimary)
                .disabled(model.isBusy)
            }

            Spacer(minLength: 0)

            Button(String(localized: "Обновить движок")) { model.showUpgradeSheet = true }
                .buttonStyle(isReady ? .chromaPrimary : .chromaNormal)
                .disabled(model.isBusy || !app.environmentStatus.isEngineInstalled)
        }
    }

    private var backupsCard: some View {
        SectionCard(
            title: String(localized: "Резервные копии"),
            subtitle: String(localized: "Копия снимается при остановленном сервере — копировать файлы работающей SQLite нельзя. Поэтому копирование и восстановление идут общей очередью и ждут, пока она освободится.")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button(String(localized: "Сделать копию сейчас")) {
                        model.makeBackupNow(app)
                    }
                    .buttonStyle(.chromaPrimary)
                    .disabled(model.isBusy || model.backupTarget(app) == nil)

                    Button(String(localized: "Обновить список")) { model.refreshBackups(app) }
                        .buttonStyle(.chromaNormal)
                    Spacer()
                    Text(AppPaths.backupsDirectory.path)
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        .lineLimit(1).truncationMode(.middle)
                }

                // Room needed vs room available, before anything is copied.
                if let space = model.backupSpace(app) {
                    Text(space.fits
                         ? String(localized: "Нужно \(space.requiredText), свободно \(space.availableText)")
                         : String(localized: "Недостаточно места: нужно \(space.requiredText), свободно \(space.availableText)"))
                        .font(Theme.Font.caption)
                        .foregroundStyle(space.fits ? Theme.Palette.captionText : Theme.Palette.attention)
                }

                if model.backups.isEmpty {
                    Text(String(localized: "Копий пока нет.")).font(Theme.Font.body).foregroundStyle(Theme.Palette.captionText)
                } else {
                    ForEach(model.backups) { backup in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(backup.name).font(Theme.Font.body)
                                Text("\(backup.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(backup.sizeText)")
                                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                                // An interrupted copy looks like a valid one in
                                // a list of names and sizes — so it says so.
                                if backup.isIncomplete {
                                    Label(
                                        String(localized: "повреждена, восстановление недоступно"),
                                        systemImage: "exclamationmark.octagon"
                                    )
                                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.danger)
                                }
                            }
                            Spacer()
                            Button(String(localized: "Восстановить")) { model.restore(backup, app: app) }
                                .buttonStyle(.chromaNormal)
                                .disabled(model.isBusy || backup.isIncomplete)
                            // Спрашивает, а не удаляет: копия уходит навсегда,
                            // и кнопка стоит вплотную к «Восстановить».
                            Button(role: .destructive) {
                                model.askToDelete(backup)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help(String(localized: "Удалить копию \(backup.name)"))
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        // Вопрос задаётся о **той самой** копии: имя, дата и размер в тексте,
        // потому что строки в списке различаются только ими.
        //
        // Через `presenting:`, а не чтением поля внутри кнопки: SwiftUI
        // закрывает диалог, сбрасывая `isPresented`, и сеттер этого биндинга
        // обнуляет `pendingBackupDeletion`. Действие, которое прочитало бы
        // поле у модели, рисковало увидеть уже `nil` — то есть тихо не
        // удалить ничего. Здесь копия приезжает в замыкание значением.
        .confirmationDialog(
            String(localized: "Точно удалить копию?"),
            isPresented: Binding(
                get: { model.pendingBackupDeletion != nil },
                set: { if !$0 { model.pendingBackupDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: model.pendingBackupDeletion
        ) { backup in
            Button(String(localized: "Удалить копию"), role: .destructive) {
                model.delete(backup, app: app)
            }
            Button(String(localized: "Отмена"), role: .cancel) { model.pendingBackupDeletion = nil }
        } message: { backup in
            Text(String(localized: "\(backup.name) — \(backup.createdAt.formatted(date: .abbreviated, time: .shortened)), \(backup.sizeText). Копия удаляется с диска навсегда; восстановить базу из неё будет нельзя."))
        }
    }

    /// Vacuum — shown only when the installed CLI actually has the command,
    /// and only for a database whose files the app can reach.
    @ViewBuilder
    private var maintenanceCard: some View {
        if model.maintenanceAvailable, let target = model.backupTarget(app) {
            AdvancedSection(place: "environment.vacuum", title: String(localized: "Обслуживание базы")) {
                Text("После массовых удалений файл базы не уменьшается сам: SQLite не отдаёт освободившееся место системе.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Порядок: резервная копия → остановка сервера → сжатие → запуск → проверка. Времени занимает примерно как копирование базы (сейчас \(ByteCountFormatter.string(fromByteCount: model.databaseSize(app), countStyle: .file))). Идёт общей очередью задач: если что-то индексируется, сжатие дождётся конца, а не оборвёт работу."))
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button {
                            model.runMaintenance(app)
                        } label: {
                            Label(String(localized: "Сжать базу"), systemImage: "arrow.down.circle")
                        }
                        .disabled(model.isBusy)
                        Text(target.path)
                            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                    }
                    if let result = model.lastMaintenance {
                        Text(result.summary).font(Theme.Font.caption).foregroundStyle(Theme.Palette.running)
                    }
                }
            }
        }
    }

    /// «Удалить все данные приложения» — with the list spelled out, the
    /// databases named as untouched, and a word to type.
    private var wipeCard: some View {
        SectionCard(
            title: String(localized: "Удаление данных приложения"),
            subtitle: String(localized: "Удаляет то, что создало приложение. Ваши базы данных остаются на месте."),
            tone: .danger
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.wipePlan(app)) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if item.isOptional {
                                Toggle(isOn: $model.wipeIncludesBackups) { Text(item.title) }
                                    .toggleStyle(.checkbox)
                            } else {
                                Text("• " + item.title)
                            }
                            Text(item.detail)
                                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                                .lineLimit(1).truncationMode(.middle)
                            if let size = item.sizeText {
                                Text(size).font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                            }
                            Spacer()
                        }
                        .font(Theme.Font.body)

                        // Красным, а не оранжевым: оранжевый в приложении
                        // значит «требует решения», а тут речь о том, что
                        // будет удалено безвозвратно. И точкой, а не
                        // треугольником: иконок-эмоций в приложении нет.
                        if let note = item.note {
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(Theme.Palette.danger)
                                    .frame(width: Theme.Size.statusDot, height: Theme.Size.statusDot)
                                    .padding(.top, 4)
                                Text(note)
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(Theme.Palette.danger)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.leading, 12)
                        }
                    }
                }

                let untouched = model.wipeUntouchedPaths(app)
                if !untouched.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Не будет удалено ни при каких условиях:")).font(Theme.Font.caption).bold()
                        ForEach(untouched, id: \.self) { path in
                            Text(path)
                                .font(Theme.Font.mono)
                                .foregroundStyle(Theme.Palette.captionText)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }

                HStack {
                    TextField(String(localized: "введите УДАЛИТЬ"), text: $model.wipeConfirmation)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    Button(String(localized: "Удалить все данные"), role: .destructive) {
                        model.wipeAllData(app)
                    }
                        .buttonStyle(.chromaDanger)
                    .disabled(model.wipeConfirmation != "УДАЛИТЬ" || model.isBusy)
                    Spacer()
                }
            }
        }
    }

    private var consoleCard: some View {
        SectionCard(title: String(localized: "Вывод команд")) {
            VStack(alignment: .leading, spacing: 8) {
                ConsoleView(lines: model.consoleLines, minHeight: 180, caption: String(localized: "Вывод команд"))
                HStack {
                    Button(String(localized: "Очистить")) { model.clearConsole() }
                        .buttonStyle(.chromaNormal)
                        .disabled(model.consoleLines.isEmpty)
                    Spacer()
                    if model.isBusy { ProgressView().controlSize(.small) }
                }
            }
        }
    }

    private var permissionsCard: some View {
        SectionCard(title: String(localized: "Зачем приложению права на выполнение команд")) {
            Text(String(localized: """
            Приложение запускает у вас те же команды, что вы выполняли бы в терминале: скачивание \
            бинарника Chroma CLI, python3 -m venv, pip install, chroma run. Каждая команда печатается \
            в поле выше до запуска, а её вывод виден в реальном времени и попадает в раздел «Логи». \
            Приложение не работает в песочнице — иначе оно не смогло бы запускать эти процессы. \
            Сеть используется только для загрузки движка, проверки версий и обращений к вашим локальным \
            ChromaDB и LM Studio.
            """))
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Palette.captionText)
        }
    }

    // MARK: - Sheets

    private var standaloneConfirmation: some View {
        SheetShell(
            title: String(localized: "Установка Chroma CLI"),
            subtitle: String(localized: "Что именно будет скачано и куда положено — до того, как что-либо начнётся."),
            width: 620,
            height: nil,
            scrolls: false
        ) {
            if let plan = model.standalonePlan {
                VStack(alignment: .leading, spacing: 8) {
                    labeled(String(localized: "Версия"), plan.version)
                    labeled(String(localized: "Файл"), "\(plan.assetName) · \(plan.sizeText)")
                    labeled(String(localized: "Источник"), plan.downloadURL.absoluteString)
                    labeled(String(localized: "Куда"), plan.destination.path)
                }
                Text(String(localized: "Будет выполнено:")).font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                Text(plan.equivalentCommand)
                    .font(Theme.Font.mono)
                    .copyable(plan.equivalentCommand)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.Palette.subtleFill)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.field))
            }
        } actions: {
            Button(String(localized: "Отмена")) { model.showStandaloneConfirmation = false }
                .buttonStyle(.chromaNormal)
            Button(String(localized: "Скачать и установить")) { model.confirmStandaloneInstall(app) }
                .buttonStyle(.chromaPrimary)
        }
    }

    private var upgradeSheet: some View {
        SheetShell(
            title: String(localized: "Обновление движка"),
            subtitle: String(localized: "Миграции формата хранения необратимы, поэтому копия базы снимается до обновления."),
            help: String(localized: "Перед обновлением приложение остановит сервер и скопирует каталог базы. После обновления оно проверит, что база открывается и число документов в коллекциях совпадает с зафиксированным."),
            width: 560,
            height: nil,
            scrolls: false
        ) {
            VStack(alignment: .leading, spacing: 6) {
                labeled(String(localized: "Установлено"), app.environmentStatus.installedVersion ?? "—")
                labeled(String(localized: "Доступно"), app.environmentStatus.latestVersion ?? String(localized: "не проверялось"))
                labeled(String(localized: "Способ"), settings.configuration.preferredInstallPath.title)
                if let target = model.backupTarget(app) {
                    labeled(String(localized: "База для копии"), target.path)
                }
            }

            // Красным: пропуск копии перед необратимой миграцией — это
            // согласие потерять базу, а не «требует внимания».
            Toggle(String(localized: "Пропустить резервную копию — понимаю риск"), isOn: $model.acknowledgeSkippingBackup)
                .font(Theme.Font.body)
                .foregroundStyle(model.acknowledgeSkippingBackup ? Theme.Palette.danger : Theme.Palette.primaryText)
        } actions: {
            Button(String(localized: "Отмена")) { model.showUpgradeSheet = false }
                .buttonStyle(.chromaNormal)
            Button(String(localized: "Обновить")) { model.upgrade(app) }
                .buttonStyle(.chromaPrimary)
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title).font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText).frame(width: 130, alignment: .leading)
            Text(value).font(Theme.Font.body).copyable(value)
        }
    }

    // MARK: - Log panel

}
