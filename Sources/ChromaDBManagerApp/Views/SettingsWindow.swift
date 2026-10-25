import SwiftUI
import ChromaCore

/// Окно «Настройки» (⌘) — настройки самого приложения.
///
/// Здесь то, что настраивают раз и потом не трогают: язык, строка меню,
/// уведомления, сроки хранения, проверка обновлений, перенос настроек.
/// На экранах разделов остаётся работа с базой, а не устройство приложения.
struct SettingsWindow: View {
    /// Открытая вкладка. Экран раздела может открыть окно сразу на своей —
    /// «Источники → Ещё → Правила запуска…».
    @AppStorage(SettingsWindow.tabKey) private var tab = Tab.general.rawValue

    static let tabKey = "settings.tab"

    enum Tab: String {
        case general, sources, notifications, storage, updates, transfer
    }

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsTab()
                .tabItem { Label(String(localized: "Основные"), systemImage: "gearshape") }
                .tag(Tab.general.rawValue)
            SourcesSettingsTab()
                .tabItem { Label(String(localized: "Источники"), systemImage: "folder") }
                .tag(Tab.sources.rawValue)
            NotificationSettingsTab()
                .tabItem { Label(String(localized: "Уведомления"), systemImage: "bell") }
                .tag(Tab.notifications.rawValue)
            StorageSettingsTab()
                .tabItem { Label(String(localized: "Хранение"), systemImage: "externaldrive") }
                .tag(Tab.storage.rawValue)
            UpdateSettingsTab()
                .tabItem { Label(String(localized: "Обновления"), systemImage: "arrow.down.circle") }
                .tag(Tab.updates.rawValue)
            TransferSettingsTab()
                .tabItem { Label(String(localized: "Перенос"), systemImage: "arrow.left.arrow.right") }
                .tag(Tab.transfer.rawValue)
        }
        // Окно настроек в macOS — фиксированной ширины.
        .settingsWindowWidth()
    }
}

// MARK: - Источники

/// Правила, общие для всех источников: когда показывать план и можно ли
/// запускать автоматически; умолчания нарезки новых источников.
private struct SourcesSettingsTab: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @State private var confirmingForget = false

    var body: some View {
        Form {
            Section {
                // below this, «Синхронизировать» just runs; above it, the
                // plan is shown first and has to be confirmed (rule 4,
                // Приложение 5). Step of 5, not 10: a threshold you cannot set
                // to 3 is not really tunable.
                StepperRow(
                    String(localized: "Показывать план, если файлов больше"),
                    value: Binding(
                        get: { settings.configuration.syncPreviewThresholdFiles },
                        set: { settings.configuration.syncPreviewThresholdFiles = max(0, $0) }
                    ),
                    in: 0...10_000, step: 5
                )
                // Поле со стрелками (v6 A2); слово «всегда» в поле не впишешь —
                // что значит ноль, сказано в подсказке.
                .help(String(localized: "0 — показывать план перед каждым запуском."))
                Toggle(String(localized: "Приостановить всю автоматическую индексацию"), isOn: Binding(
                    get: { settings.configuration.automaticSyncPaused },
                    set: { app.autoSync.setPaused($0, app: app) }
                ))
            } header: {
                Text("Правила запуска")
            } footer: {
                Text("Пауза — на случай, когда LM Studio занята другой задачей. Ручная синхронизация продолжает работать.")
            }

            chunkingDefaults

            Section {
                HowItWorks(screen: "sources", String(localized: "Папка → коллекция с инкрементальной синхронизацией: без изменений на диске повторный запуск не пересчитывает векторы. Изменение параметров нарезки — это новая нарезка: при следующей синхронизации все файлы источника будут перечанкованы и переэмбежены. Удаления не выполняются автоматически ни в одном режиме: исчезнувшие файлы попадают в «Требуют решения». Таймеры живут, пока приложение запущено, — фоновых демонов приложение не устанавливает."))
            }
        }
        .settingsTabForm()
    }

    /// Что стоит в умолчаниях нарезки. Параметры правятся в листе
    /// источника — второй редактор тех же двадцати значений разошёлся
    /// бы с первым. Здесь — стратегия нового источника (одно значение,
    /// пикером), что задано по каждой стратегии — строками, как в инспекторе
    /// источника (v6), и единственное действие, которому в листе источника не
    /// место: забыть всё разом.
    @ViewBuilder
    private var chunkingDefaults: some View {
        let configuration = settings.configuration
        let own = ChunkStrategy.allCases.filter { configuration.hasOwnChunkingDefault(for: $0) }

        Section {
            Picker(String(localized: "Стратегия нового источника"), selection: Binding(
                get: { settings.configuration.defaultChunkingStrategy ?? ChunkingConfiguration().strategy },
                set: { settings.configuration.defaultChunkingStrategy = $0 }
            )) {
                ForEach(ChunkStrategy.allCases) { strategy in
                    Text(strategy.title).tag(strategy)
                }
            }
            if own.isEmpty {
                Text("Своих значений не задано ни у одной стратегии — везде заводские.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Умолчания нарезки")
        } footer: {
            Text("Параметры задаются в листе источника — блок «Умолчания» под параметрами стратегии. «Взять умолчание» подставляет их в открытый источник.")
        }

        // По секции на стратегию со своими значениями: «свои умолчания у трёх
        // стратегий» не отвечает на вопрос, какие именно.
        ForEach(own) { item in
            Section {
                ForEach(configuration.chunkingDefault(for: item).parameterRows, id: \.0) { row in
                    LabeledContent(row.0, value: row.1)
                }
            } header: {
                Text(String(localized: "Свои умолчания: \(item.title)"))
            }
        }

        if !own.isEmpty {
            Section {
                HStack {
                    Spacer()
                    Button(String(localized: "Забыть все умолчания…"), role: .destructive) {
                        confirmingForget = true
                    }
                    .confirmationDialog(
                        String(localized: "Забыть свои умолчания нарезки?"),
                        isPresented: $confirmingForget,
                        titleVisibility: .visible
                    ) {
                        Button(String(localized: "Забыть"), role: .destructive) {
                            for item in own { settings.configuration.clearChunkingDefault(for: item) }
                        }
                        Button(String(localized: "Отменить"), role: .cancel) {}
                    } message: {
                        Text("Новые источники получат заводские значения. Заведённые источники это не тронет: у них свои значения.")
                    }
                }
            }
        }
    }
}

// MARK: - Основные

private struct GeneralSettingsTab: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    private let languages = InterfaceLanguageStore()
    @State private var needsRestart = false

    private var menuBar: MenuBarPreferences { settings.configuration.menuBar }

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Язык интерфейса"), selection: Binding(
                    get: { languages.current },
                    set: { chosen in
                        needsRestart = languages.apply(chosen)
                        app.log.record(.info, "Интерфейс", "Язык интерфейса: \(chosen.title)")
                    }
                )) {
                    ForEach(InterfaceLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                if needsRestart {
                    LabeledContent {
                        Button(String(localized: "Перезапустить")) {
                            AppDelegate.relaunchOnExit = true
                            NSApplication.shared.terminate(nil)
                        }
                    } label: {
                        Text("Язык поменяется при следующем запуске.")
                    }
                }
            } header: {
                SectionHeader(
                    String(localized: "Язык"),
                    help: String(localized: "Английский перевод неполный: строки без перевода остаются русскими. Это видно сразу и ничего не ломает — приложение ищет текст по русской строке из кода.")
                )
            } footer: {
                Text("По умолчанию — как в системе. Выбор применится при следующем запуске.")
            }

            Section {
                Toggle(String(localized: "Показывать значок в строке меню"), isOn: Binding(
                    get: { menuBar.showsIcon },
                    set: { settings.configuration.menuBar.showsIcon = $0 }
                ))
                Toggle(String(localized: "Оставаться в строке меню после закрытия окна"), isOn: Binding(
                    get: { menuBar.keepsRunningWithoutWindow },
                    set: { settings.configuration.menuBar.keepsRunningWithoutWindow = $0 }
                ))
                // Без значка приложение без окна было бы недостижимо ничем,
                // кроме принудительного завершения.
                .disabled(!menuBar.showsIcon)
            } header: {
                SectionHeader(
                    String(localized: "Строка меню"),
                    help: String(localized: "Значок в строке меню показывает, идёт ли индексация, и позволяет поставить её на паузу и поискать, не открывая окно. MCP-сервер, пока приложение живёт в строке меню, остаётся поднятым: агент работает с базой и при закрытом окне.")
                )
            } footer: {
                // Подпись — под теми переключателями, к которым относится (v4).
                Text(menuBar.showsIcon
                     ? String(localized: "Без окна значок в Dock убирается.")
                     : String(localized: "Без значка приложение закрывается вместе с окном."))
            }

            Section {
                Toggle(String(localized: "Глобальная горячая клавиша"), isOn: Binding(
                    get: { menuBar.globalHotKeyEnabled },
                    set: { settings.configuration.menuBar.globalHotKeyEnabled = $0 }
                ))
                Picker(String(localized: "Сочетание"), selection: Binding(
                    get: { menuBar.hotKey.keyCode },
                    set: { settings.configuration.menuBar.hotKey.keyCode = $0 }
                )) {
                    ForEach(HotKeyCombination.selectableKeys, id: \.code) { key in
                        Text(verbatim: "⌃⌥⌘\(key.name)").tag(key.code)
                    }
                }
                .disabled(!menuBar.globalHotKeyEnabled)
                LabeledContent(String(localized: "Результатов в быстром поиске")) {
                    // Поле и стрелки, как «Предел, ГБ» на «Хранении» (v5).
                    TextField(String(localized: "Результатов в быстром поиске"), value: Binding(
                        get: { menuBar.quickSearchResultCount },
                        set: { settings.configuration.menuBar.quickSearchResultCount = max(1, min(20, $0)) }
                    ), format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .numberFieldWidth()
                    Stepper(String(localized: "Результатов в быстром поиске"), value: Binding(
                        get: { menuBar.quickSearchResultCount },
                        set: { settings.configuration.menuBar.quickSearchResultCount = max(1, min(20, $0)) }
                    ), in: 1...20)
                    .labelsHidden()
                }
            } header: {
                Text("Быстрый поиск")
            }

            Section {
                Toggle(
                    String(localized: "Запускать сервер при старте приложения"),
                    isOn: $settings.configuration.autoStartServerOnLaunch
                )
            } header: {
                Text("Запуск")
            } footer: {
                Text(settings.configuration.autoStartServerOnLaunch
                     ? String(localized: "При открытии приложение само подключится к базе.")
                     : String(localized: "Приложение откроется без подключения."))
            }
        }
        .settingsTabForm()
        .toggleStyle(.switch)
    }
}

// MARK: - Уведомления

private struct NotificationSettingsTab: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var notifier: Notifier
    @StateObject private var security = SecurityViewModel()

    private var isSupported: Bool {
        if case .unsupported = notifier.availability { return false }
        return true
    }

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Показывать уведомления"), isOn: Binding(
                    get: { settings.configuration.notificationsEnabled },
                    set: { isOn in Task { await security.setNotifications(isOn, app: app) } }
                ))
                .disabled(!isSupported)
            } footer: {
                switch notifier.availability {
                case .unsupported(let reason):
                    Notice(.warning, String(localized: "Уведомления недоступны: \(reason)."))
                case .denied:
                    Notice(.warning, String(localized: "macOS отклонил запрос. Включить можно в «Системных настройках» → «Уведомления»."))
                case .ready, .unknown:
                    Text("Сервер упал, кому-то отказано в доступе, выполнена экстренная остановка.")
                }
            }

            Section {
                Picker(String(localized: "Уведомлять"), selection: $settings.configuration.operationNotifications) {
                    ForEach(OperationNotificationPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                // Каждый вариант — своей строкой, как «Доступ по сети» (v4):
                // с подписью строки группа ложилась в ряд. Подпись — заголовок.
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .disabled(!settings.configuration.notificationsEnabled)
            } header: {
                Text("Итоги фоновых операций")
            } footer: {
                Text(settings.configuration.notificationsEnabled
                     ? settings.configuration.operationNotifications.explanation
                     : String(localized: "Пока уведомления выключены, итоги никуда не отправляются."))
            }
        }
        .settingsTabForm()
        .toggleStyle(.switch)
    }
}

// MARK: - Хранение

private struct StorageSettingsTab: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var trash = TrashViewModel()
    @ObservedObject private var embeddings = AppEnvironment.shared.embeddingsModel
    @State private var confirmingOrphans = false
    /// Файлы удалённых источников — читаются с диска при открытии вкладки
    /// и после удаления, а не при каждой перерисовке.
    @State private var orphans: (files: [URL], bytes: Int64) = ([], 0)

    private static let gigabyte = 1_073_741_824.0

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Размер файла"), selection: retention(\.megabytesPerFile)) {
                    ForEach([5, 10, 25, 100], id: \.self) { Text("\($0.plainDigits) МБ").tag($0) }
                }
                Picker(String(localized: "Файлов хранить"), selection: retention(\.filesKept)) {
                    ForEach([2, 5, 10, 20], id: \.self) { Text($0.plainDigits).tag($0) }
                }
                Picker(String(localized: "Строк на экране"), selection: retention(\.inMemoryLines)) {
                    ForEach([1000, 5000, 20000], id: \.self) { Text($0.formatted()).tag($0) }
                }
                LabeledContent(String(localized: "Папка")) {
                    Text(AppPaths.logsDirectory.path)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(AppPaths.logsDirectory.path)
                    // Действие в самой строке (v6): контекстное меню не
                    // находят. Значком — ширина окна «Настроек» постоянная.
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([logsURL])
                    } label: {
                        Label(String(localized: "Показать в Finder"), systemImage: "folder")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Показать в Finder"))
                }
                .contextMenu {
                    Button(String(localized: "Показать в Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([logsURL])
                    }
                }
            } header: {
                SectionHeader(
                    String(localized: "Логи"),
                    help: String(localized: "Файл на диске переживает перезапуск приложения, окно «Событий» — нет: на экране показаны записи текущей сессии. Токены и ключи маскируются до записи, а не при показе.")
                )
            } footer: {
                Text("Старше срока или сверх предела — удаляется без спроса.")
            }

            Section {
                Toggle(String(localized: "Использовать корзину"), isOn: Binding(
                    get: { settings.configuration.trashEnabled },
                    set: { trash.setTrashEnabled($0, app: app) }
                ))
                Picker(String(localized: "Хранить"), selection: Binding(
                    get: { settings.configuration.trashRetentionDays },
                    set: { trash.applyRetention(days: $0, app: app) }
                )) {
                    ForEach([7, 14, 30, 90], id: \.self) { Text(String(localized: "\($0.plainDigits) дн.")).tag($0) }
                }
                gigabytes(
                    String(localized: "Предел, ГБ"),
                    value: Double(settings.configuration.trashLimitBytes) / Self.gigabyte,
                    range: 0.25...20, step: 0.25
                ) { trash.applyLimit(gigabytes: $0, app: app) }
            } header: {
                Text("Корзина")
            } footer: {
                Text("Старше срока и сверх предела — вытесняется, начиная с самых старых.")
            }

            Section {
                gigabytes(
                    String(localized: "Предел, ГБ"),
                    value: Double(settings.configuration.embeddingCacheLimitBytes) / Self.gigabyte,
                    range: 0.5...50, step: 0.5
                ) { value in Task { await embeddings.applyCacheLimit(app, gigabytes: value) } }
            } header: {
                Text("Кэш эмбеддингов")
            } footer: {
                Text("При переполнении вытесняется то, к чему дольше всего не обращались.")
            }

            orphanedSourceFiles
        }
        .settingsTabForm()
        .toggleStyle(.switch)
        .onAppear { rereadOrphans() }
        .onChange(of: settings.configuration.dataSources.map(\.id)) { rereadOrphans() }
    }

    private var logsURL: URL { app.log.logFileURL ?? AppPaths.logsDirectory }

    /// Файлы состояния удалённых источников. Только кнопкой и только
    /// когда источники в настройках есть: пустой список — это скорее
    /// потерянные настройки, чем удалённые источники.
    @ViewBuilder
    private var orphanedSourceFiles: some View {
        if !orphans.files.isEmpty {
            Section {
                LabeledContent(String(localized: "Занято")) {
                    Text(ByteCountFormatter.string(fromByteCount: orphans.bytes, countStyle: .file))
                    Button(String(localized: "Удалить…")) { confirmingOrphans = true }
                }
            } header: {
                Text("Данные удалённых источников")
            } footer: {
                Text("Манифесты источников, которых больше нет в списке. С ними источник, добавленный заново с тем же идентификатором, не переиндексируется; без них — переиндексируется. Документы в базе не затрагиваются.")
            }
            .confirmationDialog(
                String(localized: "Удалить данные удалённых источников?"),
                isPresented: $confirmingOrphans,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Удалить"), role: .destructive) {
                    let removed = orphans
                    SourceStateFiles.remove(removed.files)
                    app.log.record(.info, "Источники", "Удалены файлы состояния удалённых источников: \(removed.files.count.plainDigits), \(ByteCountFormatter.string(fromByteCount: removed.bytes, countStyle: .file))")
                    rereadOrphans()
                }
                Button(String(localized: "Отменить"), role: .cancel) {}
            }
        }
    }

    private func rereadOrphans() {
        let sources = settings.configuration.dataSources
        orphans = sources.isEmpty ? ([], 0) : SourceStateFiles.orphans(keeping: Set(sources.map(\.id)))
    }

    private func retention(_ keyPath: WritableKeyPath<LogRetention, Int>) -> Binding<Int> {
        Binding(
            get: { settings.configuration.logRetention[keyPath: keyPath] },
            set: {
                settings.configuration.logRetention[keyPath: keyPath] = $0
                app.log.apply(settings.configuration.logRetention)
            }
        )
    }

    /// Число с единицей в подписи: поле и шаги рядом.
    private func gigabytes(
        _ title: String, value: Double, range: ClosedRange<Double>, step: Double,
        apply: @escaping (Double) -> Void
    ) -> some View {
        let binding = Binding(get: { value }, set: { apply(min(max($0, range.lowerBound), range.upperBound)) })
        return LabeledContent(title) {
            TextField(title, value: binding, format: .number.precision(.fractionLength(0...2)))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .numberFieldWidth()
            Stepper(title, value: binding, in: range, step: step)
                .labelsHidden()
        }
    }
}

// MARK: - Обновления

private struct UpdateSettingsTab: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var environment = EnvironmentViewModel()

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Версия"), value: AppUpdateChecker.currentVersion()
                    ?? String(localized: "неизвестна"))
                LabeledContent {
                    if environment.isCheckingAppUpdate {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(String(localized: "Проверить обновления")) {
                            Task { await environment.checkAppUpdates(app) }
                        }
                    }
                } label: {
                    Text(updateSummary)
                }
                if case .available(let release, _) = environment.appUpdate {
                    LabeledContent {
                        Button(String(localized: "Открыть страницу релиза")) { environment.openReleasePage(release) }
                            .buttonStyle(.link)
                    } label: {
                        StatusLabel(.warning, String(localized: "Доступна версия \(release.version)"))
                    }
                }
                Toggle(String(localized: "Проверять обновления приложения при запуске"),
                       isOn: $settings.configuration.checkAppUpdatesOnLaunch)
            } header: {
                SectionHeader(
                    String(localized: "Приложение"),
                    help: String(localized: "Встроенного автообновления в приложении нет и не будет: сборка распространяется через GitHub, и решение обновиться остаётся за вами.")
                )
            } footer: {
                if let error = environment.appUpdateError {
                    Notice(.warning, error)
                } else {
                    Text("Проверка спрашивает GitHub и ничего не скачивает. Пока переключатель выключен, приложение не выходит в сеть само.")
                }
            }

            Section {
                Toggle(String(localized: "Проверять обновления движка при запуске"),
                       isOn: $settings.configuration.checkUpdatesAutomatically)
            } header: {
                Text("Движок ChromaDB")
            } footer: {
                Text("Проверка обращается к GitHub или PyPI. Обновление ставится на вкладке «Установка».")
            }
        }
        .settingsTabForm()
        .toggleStyle(.switch)
    }

    private var updateSummary: String {
        switch environment.appUpdate {
        case .upToDate: return String(localized: "Установлена последняя версия.")
        case .available: return String(localized: "Есть новая версия.")
        case .unknownCurrentVersion: return String(localized: "Версию сравнить не с чем.")
        case .none: return String(localized: "Ещё не проверялось.")
        }
    }
}

// MARK: - Перенос

private struct TransferSettingsTab: View {
    @EnvironmentObject private var app: AppEnvironment
    @StateObject private var transfer = SettingsTransferViewModel()

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    HStack {
                        Button(String(localized: "Экспортировать…")) { transfer.export(app) }
                        Button(String(localized: "Импортировать…")) { transfer.chooseFileForImport(app) }
                    }
                } label: {
                    Text("Файл настроек")
                }
            } header: {
                SectionHeader(
                    String(localized: "Перенос настроек"),
                    help: String(localized: "Один файл со всем, кроме секретов: профили подключений, источники, схемы метаданных, сохранённые фильтры, клиенты и общие настройки. Коллекции и векторы это не переносит — для них есть экспорт коллекции.")
                )
            } footer: {
                if let error = transfer.errorMessage {
                    Notice(.warning, error)
                } else if let status = transfer.statusMessage {
                    Text(status)
                } else {
                    Notice(.info, String(localized: "Токены серверов и ключи клиентов не переносятся: они в Keychain и на другой машине выпускаются заново."))
                }
            }
        }
        .settingsTabForm()
        .sheet(item: $transfer.pending) { pending in
            SettingsImportSheet(transfer: transfer, pending: pending)
        }
    }
}

/// Что изменит импорт — до того, как что-то записано.
private struct SettingsImportSheet: View {
    @EnvironmentObject private var app: AppEnvironment
    @ObservedObject var transfer: SettingsTransferViewModel
    let pending: SettingsTransferViewModel.PendingImport

    var body: some View {
        let plan = pending.plan
        VStack(spacing: 0) {
            Form {
                Section {
                    row(String(localized: "Профили подключений"), plan.profiles)
                    row(String(localized: "Источники"), plan.sources)
                    row(String(localized: "Схемы метаданных"), plan.schemas)
                    row(String(localized: "Сохранённые фильтры"), plan.filters)
                    row(String(localized: "Клиенты"), plan.clients)
                    row(String(localized: "Общие профили таблиц"), plan.tableProfiles)
                } header: {
                    Text(verbatim: pending.fileName)
                } footer: {
                    Text("Записи с теми же идентификаторами заменяются, остальное добавляется; ничего не удаляется.")
                }

                Section {
                    Toggle(String(localized: "Применить общие настройки приложения"), isOn: Binding(
                        get: { transfer.pending?.includePreferences ?? true },
                        set: { transfer.pending?.includePreferences = $0 }
                    ))
                } footer: {
                    Text("Адрес LM Studio, модель по умолчанию, кэш, таймауты, хранение логов, корзина, порог предпросмотра.")
                }

                if !plan.missingFolders.isEmpty || !plan.profilesNeedingToken.isEmpty || !plan.clientsNeedingKey.isEmpty {
                    Section {
                        if !plan.missingFolders.isEmpty {
                            Notice(.warning, String(localized: "Папок нет на этом компьютере: \(plan.missingFolders.count.plainDigits). Источник появится, но синхронизировать ему будет нечего, пока путь не поправлен."))
                        }
                        if !plan.profilesNeedingToken.isEmpty {
                            Notice(.info, String(localized: "Токен нужно ввести заново: \(plan.profilesNeedingToken.joined(separator: ", "))"))
                        }
                        if !plan.clientsNeedingKey.isEmpty {
                            Notice(.info, String(localized: "Ключ нужно выпустить заново: \(plan.clientsNeedingKey.joined(separator: ", "))"))
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button(String(localized: "Отменить")) { transfer.cancelImport() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Импортировать")) { transfer.confirmImport(app) }
                    .primaryButtonStyle()
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.isEmpty)
            }
            .padding()
        }
        .frame(width: SheetWidth.regular.points)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ title: String, _ category: SettingsImportPlan.Category) -> some View {
        LabeledContent(title, value: category.isEmpty
            ? String(localized: "нет")
            : String(localized: "добавится \(category.added.plainDigits), заменится \(category.replaced.plainDigits)"))
    }
}
