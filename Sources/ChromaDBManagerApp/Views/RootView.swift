import SwiftUI
import UniformTypeIdentifiers
import ChromaCore

/// Группа бокового меню.
///
/// Двенадцать плоских пунктов свернулись в четыре группы и одиннадцать
/// экранов. Группа отвечает на вопрос «где искать», и потому их ровно
/// столько, сколько человек удерживает в голове, не перечитывая.
enum SidebarGroup: String, CaseIterable, Identifiable {
    case database
    case data
    case access
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .database: return String(localized: "База")
        case .data: return String(localized: "Данные")
        case .access: return String(localized: "Доступ")
        case .system: return String(localized: "Система")
        }
    }

    var sections: [SidebarSection] {
        SidebarSection.allCases.filter { $0.group == self }
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case overview
    /// «Установка» — бывшее «Окружение». Стоит сразу под «Обзором»: с неё
    /// начинают, пока движка нет, и к ней возвращаются, когда он сломался
    ///. Идентификатор `environment` сохранён — по нему приложение
    /// помнит открытую вкладку, и переименование сбросило бы это у всех.
    case environment
    case collections
    case sources
    case models
    case evaluation
    case trash
    case clients
    case security
    case tasks
    case logs

    var id: String { rawValue }

    var group: SidebarGroup {
        switch self {
        case .overview, .environment, .collections: return .database
        case .sources, .models, .evaluation, .trash: return .data
        case .clients, .security: return .access
        case .tasks, .logs: return .system
        }
    }

    var title: String {
        switch self {
        case .overview: return String(localized: "Обзор")
        case .collections: return String(localized: "Коллекции")
        case .sources: return String(localized: "Источники")
        case .models: return String(localized: "Модели")
        case .evaluation: return String(localized: "Оценка")
        case .trash: return String(localized: "Корзина")
        case .clients: return String(localized: "Клиенты")
        case .security: return String(localized: "Безопасность")
        case .environment: return String(localized: "Установка")
        case .tasks: return String(localized: "Задачи")
        case .logs: return String(localized: "Логи")
        }
    }

    /// Строка под заголовком экрана: о чём этот экран, одним предложением.
    var subtitle: String {
        switch self {
        case .overview: return String(localized: "Подключение и что работает")
        case .collections: return String(localized: "Документы, поиск и правила метаданных")
        case .sources: return String(localized: "Папки, сайты и репозитории")
        case .models: return String(localized: "LM Studio, модели и кэш векторов")
        case .evaluation: return String(localized: "Наборы запросов, варианты и прогоны")
        case .trash: return String(localized: "Удалённое, что можно вернуть")
        case .clients: return String(localized: "Ключи клиентов и доступ по MCP")
        case .security: return String(localized: "Что открыто наружу")
        case .environment: return String(localized: "Движок, копии и данные приложения")
        case .tasks: return String(localized: "Очередь длительных операций")
        case .logs: return String(localized: "События приложения и журнал доступа")
        }
    }

    /// Вкладки экрана — разрезы одной темы, а не разные темы.
    ///
    /// Правило дизайн-системы: от двух до пяти; первая — то, ради чего экран
    /// открывают. Пустой список означает, что резать нечего, и полосы вкладок
    /// на экране нет вовсе.
    var tabs: [String] {
        switch self {
        // Вкладки «Сервер» нет (v6 B1): строка процесса с кнопками — в
        // «Состояние → Сейчас», запуск при старте — в Настройках.
        case .overview: return [
            String(localized: "Состояние"), String(localized: "Подключение"),
        ]
        case .sources: return [
            String(localized: "Источники"), String(localized: "Диагностика"), String(localized: "Стенд"),
        ]
        // Подключение к LM Studio — своей вкладкой (v3): форма над
        // таблицей моделей была узкой полосой над широкой таблицей.
        case .models: return [
            String(localized: "Модели"), String(localized: "Подключение"),
            String(localized: "Кэш"), String(localized: "Замеры"),
        ]
        // «Проверки» влились в «Установку»: проверка и установка — один
        // разговор, и держать их на разных вкладках значило просить человека
        // прыгать между «чего не хватает» и «как поставить».
        case .environment: return [
            String(localized: "Установка"), String(localized: "Резервные копии"),
            String(localized: "Управление данными"),
        ]
        // «Хранение» — в окне «Настройки».
        case .logs: return [
            String(localized: "События"), String(localized: "Доступ"),
            String(localized: "Сервер"),
        ]
        // Три разреза одной темы, как в макете: чем прогонять, что прогонять
        // и что получилось.
        case .evaluation: return [
            String(localized: "Набор запросов"), String(localized: "Варианты"),
            String(localized: "Прогоны"),
        ]
        // Ключи — кто ходит, MCP — как ходят агенты. Что делали — в «Логи →
        // Доступ»: журнал был здесь вторым экземпляром.
        case .clients: return [
            String(localized: "Ключи"), String(localized: "MCP"),
        ]
        // Сводка — что сейчас открыто, «Доступ по сети» — где это решается.
        // «Уведомления» — в окне «Настройки».
        case .security: return [
            String(localized: "Сводка"), String(localized: "Доступ по сети"),
        ]
        // У «Коллекций» вкладки свои и живут они у выбранной коллекции:
        // «Документы» и «Поиск» — это стороны одной коллекции, а не разделы
        // приложения. Полоса вкладок под именем раздела утверждала обратное
        //.
        case .collections, .trash, .tasks:
            return []
        }
    }

    /// Индекс вкладки по её названию.
    ///
    /// Числами такие переходы записывать нельзя: вкладки переставляют и
    /// объединяют, и «второй по счёту» назавтра оказывается другим разделом.
    /// Промах возвращает 0 — первая вкладка всегда существует.
    func tabIndex(_ title: String) -> Int {
        tabs.firstIndex(of: title) ?? 0
    }

    var icon: String {
        switch self {
        case .overview: return "circle.circle"
        case .collections: return "tray.full"
        case .sources: return "folder.badge.gearshape"
        case .models: return "cpu"
        case .evaluation: return "chart.bar.doc.horizontal"
        case .trash: return "trash"
        case .clients: return "key.horizontal"
        case .security: return "lock.shield"
        case .environment: return "checkmark.seal"
        case .tasks: return "list.bullet.indent"
        case .logs: return "list.bullet.rectangle"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    /// Открытый раздел — помнит окно: после перезапуска человек там, где был.
    @SceneStorage("section") private var sectionID = SidebarSection.overview.rawValue
    /// Открытая вкладка каждого раздела — своя, и она переживает переход на
    /// соседний раздел и обратно. Ключ у каждого раздела отдельный:
    /// `@SceneStorage` хранит только простые значения.
    @SceneStorage("tab.overview") private var overviewTab = 0
    @SceneStorage("tab.environment") private var environmentTab = 0
    @SceneStorage("tab.sources") private var sourcesTab = 0
    // Новый ключ: у «Кэша» и «Замеров» сдвинулись номера, прежний
    // сохранённый индекс открыл бы не ту вкладку.
    @SceneStorage("tab.models.v3") private var modelsTab = 0
    @SceneStorage("tab.evaluation") private var evaluationTab = 0
    @SceneStorage("tab.clients") private var clientsTab = 0
    @SceneStorage("tab.security") private var securityTab = 0
    @SceneStorage("tab.logs") private var logsTab = 0

    @StateObject private var environmentModel = EnvironmentViewModel()
    @StateObject private var connectionModel = ConnectionViewModel()
    @StateObject private var serverModel = ServerViewModel()
    @StateObject private var clientsModel = ClientsViewModel()
    @StateObject private var securityModel = SecurityViewModel()
    @StateObject private var collectionsModel = CollectionsViewModel()
    @StateObject private var evaluationModel = EvaluationViewModel()
    @StateObject private var trashModel = TrashViewModel()
    @StateObject private var diskUsageModel = DiskUsageViewModel()
    // Не `@StateObject`: эти живут дольше окна (см. `AppEnvironment.sourcesModel`).
    @ObservedObject private var embeddingsModel = AppEnvironment.shared.embeddingsModel
    @ObservedObject private var sourcesModel = AppEnvironment.shared.sourcesModel
    @ObservedObject private var autoSync = AppEnvironment.shared.autoSync
    @ObservedObject private var reembedding = AppEnvironment.shared.reembedding
    /// Что бросили на окно и о чём ещё не спросили.
    @State private var droppedItems: DroppedItems?
    /// «Новая коллекция…» из строки меню: лист открывает сам экран коллекций.
    @State private var newCollectionRequested = false
    @State private var newClientRequested = false
    /// Поиск журнала доступа — «Клиенты → Показать в журнале» кладёт сюда
    /// имя клиента.
    @State private var accessQuery = ""
    /// «Остановить сервер…» из строки меню ждёт подтверждения.
    @State private var confirmingServerStop = false
    /// Мост к строке меню: один на окно. `@State`, а не `@StateObject`: окну
    /// незачем перерисовываться, когда меняется доступность пунктов меню.
    @State private var commandCenter = MainWindowCommandCenter()

    var body: some View {
        NavigationSplitView {
            // Группы вместо плоского списка: рубрика говорит, где искать,
            // и двенадцать пунктов перестают быть одной длинной колонкой
            //. Шрифт, размер значков и выделение — системные: их
            // задаёт настройка «Размер значков в боковой панели» и акцент.
            List(selection: selectionBinding) {
                ForEach(SidebarGroup.allCases) { group in
                    Section(group.title) {
                        ForEach(group.sections) { section in
                            Label(section.title, systemImage: section.icon)
                                .help(section.subtitle)
                                // Находки диагностики — бейджем у раздела, а не
                                // числом в сегменте (v3): сегмент с числом
                                // был шире соседних. Ноль бейдж не рисует.
                                .badge(section == .sources ? sourcesModel.problemCount : 0)
                                // `tag` — последним: модификатор после него
                                // оборачивает строку, и список терял выбор.
                                .tag(section)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .sidebarColumnWidth()
            // Состояние подключения — внизу боковой панели: видно с любого
            // раздела, и нижняя строка окна, повторявшая его, больше не нужна.
            // `bottomBar`, а не голый `safeAreaInset`: при низком окне список
            // уезжает под строку, и без фона «Логи» просвечивали сквозь неё.
            .bottomBar {
                ConnectionStatusFooter(collectionsModel: collectionsModel, autoSync: autoSync)
            }
        } detail: {
            VStack(spacing: 0) {
                settingsAlarm
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Заголовок — системный, в полосе окна; подзаголовка нет (v3):
            // рядом с вкладками он обрезался. О чём раздел — подсказка у
            // пункта сайдбара.
            .navigationTitle(currentSection.title)
            // Вкладки — слева, на месте заголовка: так они не сдвигаются,
            // когда у вкладки другие кнопки справа.
            .hidesToolbarTitle(!currentSection.tabs.isEmpty || currentSection == .collections)
            .toolbar {
                // Вкладки раздела — сегментами в тулбаре, всегда на одном
                // месте, а не в содержимом, где их высота зависит от экрана.
                if !currentSection.tabs.isEmpty {
                    ToolbarItem(placement: .navigation) {
                        sectionTabs
                    }
                }
            }
        }
        .mainWindowMinimumSize()
        .focusedSceneObject(commandCenter)
        .onAppear { commandCenter.perform = { perform($0) } }
        .onChange(of: commandState, initial: true) { _, state in
            commandCenter.update(state)
        }
        .confirmationDialog(
            String(localized: "Остановить сервер ChromaDB?"),
            isPresented: $confirmingServerStop
        ) {
            Button(String(localized: "Остановить"), role: .destructive) {
                Task { await serverModel.stop(app) }
            }
            Button(String(localized: "Отменить"), role: .cancel) {}
        } message: {
            Text("Пока сервер стоит, недоступны коллекции, поиск и агенты. Данные не трогаются: база — это папка на диске.")
        }
        .task { await startUp() }
        // Находки диагностики — сразу, а не когда впервые откроют список
        // «Источников»: по ним бейдж в сайдбаре, и «Диагностика», открытая
        // первой, иначе говорила «замечаний нет».
        .task { sourcesModel.refreshManifests(app) }
        // файлы и папки можно бросить прямо на окно. Приложение не
        // решает за человека, что с ними делать, — оно спрашивает.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadDroppedURLs(providers)
            return true
        }
        .sheet(isPresented: Binding(
            get: { droppedItems?.hasSomethingToDo == true },
            set: { if !$0 { droppedItems = nil } }
        )) {
            if let items = droppedItems {
                DropSheet(
                    items: items,
                    registerSources: { urls in
                        droppedItems = nil
                        selection = .sources
                        // И первая вкладка раздела: брошенное подхватывает
                        // список источников, и с «Диагностики» или «Стенда»
                        // его не было на экране — не открывалось ничего.
                        setTab(0, for: .sources)
                        sourcesModel.pendingDrop = urls
                    },
                    addDocuments: { urls, collectionName in
                        droppedItems = nil
                        selection = .collections
                        collectionsModel.pendingSelectionName = collectionName
                        collectionsModel.pendingFileImport = urls
                    },
                    cancel: { droppedItems = nil }
                )
            }
        }
        // Просьбы извне — из строки меню, из «Служб», из перетаскивания
        // и из интентов. Разбираются в одном месте.
        .onChange(of: app.pendingRequest) { _, request in
            guard let request else { return }
            handle(request)
            app.pendingRequest = nil
        }
        .onAppear {
            if let request = app.pendingRequest {
                handle(request)
                app.pendingRequest = nil
            }
        }
    }

    /// Читает адреса из того, что бросили на окно.
    ///
    /// Асинхронно, потому что провайдер отдаёт их не сразу: `onDrop` обязан
    /// ответить немедленно, иначе перетаскивание выглядит зависшим.
    private func loadDroppedURLs(_ providers: [NSItemProvider]) {
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                guard let item = try? await provider.loadItem(
                    forTypeIdentifier: UTType.fileURL.identifier
                ) else { continue }
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                } else if let url = item as? URL {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return }
            let items = DroppedItems.classify(urls)
            if items.hasSomethingToDo {
                droppedItems = items
            } else {
                // Одни нечитаемые файлы: молчать нельзя — человек бросил их
                // намеренно, — но и выбор предлагать не из чего.
                app.lastError = String(localized: "Эти файлы приложение не читает: \(items.unsupported.map(\.lastPathComponent).joined(separator: ", "))")
            }
        }
    }

    /// Что делать с просьбой извне.
    ///
    /// Окно переключается на нужный экран и подставляет то, что попросили;
    /// само действие человек подтверждает сам — приложение, добавляющее
    /// документы без спроса, доверия не заслуживает.
    private func handle(_ request: ExternalRequest) {
        switch request {
        case .search(let collection, let text):
            selection = .collections
            collectionsModel.pendingSelectionName = collection
            collectionsModel.queryText = text
            collectionsModel.pendingSearchTab = true
        case .sources:
            selection = .sources
        case .dropped(let urls):
            // И с Dock, и из «Служб» приходят и файлы, и папки — вопрос
            // задаётся один и тот же, что и при броске на окно.
            let items = DroppedItems.classify(urls)
            if items.hasSomethingToDo {
                droppedItems = items
            } else {
                app.lastError = String(localized: "Эти файлы приложение не читает: \(items.unsupported.map(\.lastPathComponent).joined(separator: ", "))")
            }
        case .addText(let text):
            selection = .collections
            collectionsModel.pendingImportText = text
        case .syncSource(let id):
            // Тем же путём, что кнопка на экране: с планом, проверками
            // и очередью — второй синхронизации в приложении нет.
            selection = .sources
            guard let source = settings.configuration.dataSources.first(where: { $0.id == id })
            else { return }
            sourcesModel.sync(source, app: app)
        }
    }

    /// Startup does not touch the network: versions are only checked when the
    /// user asks — or when they turned the option on themselves.
    private func startUp() async {
        // Главное окно открывается заново при каждом возврате из строки меню,
        // и `.task` запускается вместе с ним. Второй запуск подключался
        // поверх живого подключения — останавливал сервер под идущей
        // синхронизацией — и повторял синхронизации «при запуске».
        guard !app.didStartUp else {
            await environmentModel.refresh(app)
            return
        }
        app.didStartUp = true
        settings.saveNow()
        app.refreshOrphans()
        await environmentModel.refresh(app)

        // Единственное обращение к сети при старте — и только когда галочка
        // включена руками. Молчаливая: недоступный GitHub не повод
        // встречать человека сообщением об ошибке.
        //
        // **Рядом с запуском, а не внутри него.** С `await` в этой строке
        // сеть без выхода в интернет задерживала бы всё последующее —
        // подключение к базе и автоматическую синхронизацию — на таймаут
        // запроса, то есть до двадцати секунд. Проверка версии столько
        // внимания не стоит.
        if settings.configuration.checkAppUpdatesOnLaunch {
            Task { await environmentModel.checkAppUpdates(app, automatic: true) }
        }

        // Starting on launch is a setting; when it is off the app
        // opens disconnected and waits for the button on the «Сервер» screen.
        let canConnect = settings.configuration.mode == .server || app.environmentStatus.canRunServer
        if canConnect && settings.configuration.autoStartServerOnLaunch {
            await app.connect()
            await collectionsModel.refresh(app)
        }

        // Automatic syncs start only after the interface is up: the spec requires
        // the "on launch" mode not to block the window.
        autoSync.start(app: app, sources: sourcesModel)

        // Список моделей LM Studio держится свежим сам: его читают четыре
        // экрана и пять листов, и до этого он появлялся, только если человек
        // сам нажал «Проверить соединение».
        embeddingsModel.startAutomaticRefresh(app)
    }

    /// Открытый раздел; `nil` у списка — это «ничего не выбрано», и тогда
    /// показывается «Обзор».
    private var selection: SidebarSection? {
        get { SidebarSection(rawValue: sectionID) }
        nonmutating set { sectionID = (newValue ?? .overview).rawValue }
    }

    private var selectionBinding: Binding<SidebarSection?> {
        Binding(get: { selection }, set: { selection = $0 })
    }

    private var currentSection: SidebarSection { selection ?? .overview }

    /// Вкладки раздела — нативным сегментом.
    private var sectionTabs: some View {
        let section = currentSection
        return Picker(String(localized: "Раздел"), selection: Binding(
            get: { tab(for: section) },
            set: { setTab($0, for: section) }
        )) {
            ForEach(Array(section.tabs.enumerated()), id: \.offset) { index, title in
                Text(title).tag(index)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private func tab(for section: SidebarSection) -> Int {
        switch section {
        // Вкладки «Сервер» больше нет — сохранённый индекс 2 ведёт на «Состояние».
        case .overview: return overviewTab < 2 ? overviewTab : 0
        case .environment: return environmentTab
        case .sources: return sourcesTab
        case .models: return modelsTab
        case .evaluation: return evaluationTab
        // Вкладки «Журнал» больше нет — сохранённый индекс 2 ведёт на «Ключи».
        case .clients: return clientsTab < 2 ? clientsTab : 0
        // Вкладки «Уведомления» больше нет — сохранённый индекс 2 ведёт на «Сводку».
        case .security: return securityTab < 2 ? securityTab : 0
        // Вкладки «Хранение» больше нет: прежний индекс 3 («Сервер») стал 2.
        case .logs: return logsTab == 3 ? 2 : logsTab
        case .collections, .trash, .tasks: return 0
        }
    }

    private func setTab(_ index: Int, for section: SidebarSection) {
        switch section {
        case .overview: overviewTab = index
        case .environment: environmentTab = index
        case .sources: sourcesTab = index
        case .models: modelsTab = index
        case .evaluation: evaluationTab = index
        case .clients: clientsTab = index
        case .security: securityTab = index
        case .logs: logsTab = index
        case .collections, .trash, .tasks: break
        }
    }

    /// Открытая вкладка текущего раздела.
    private var openTab: Int { tab(for: currentSection) }

    /// Что из команд строки меню доступно сейчас.
    private var commandState: MainWindowCommandState {
        let connected = app.connection.isConnected
        var state = MainWindowCommandState()
        state.canConnect = !connected && app.connection != .connecting
        state.canDisconnect = connected
        // Сервер своего процесса — только у локальной базы; у внешнего
        // сервера управлять нечем. Подключена локальная база — значит,
        // её сервер работает.
        state.isServerRunning = connected && settings.configuration.mode == .localDatabase
        state.canBackUp = !environmentModel.isBusy && environmentModel.backupTarget(app) != nil
        if currentSection == .collections, let collection = collectionsModel.selected {
            state.hasCollection = true
            state.canSearch = collection.isBound && !collectionsModel.isQuerying
            state.canAddDocuments = collection.isBound
            state.canReembed = collection.isBound && (collection.documentCount ?? 0) > 0
        }
        state.tabs = currentSection.tabs
        return state
    }

    /// Команда строки меню — тем же путём, что кнопка на экране.
    private func perform(_ command: MainWindowCommand) {
        switch command {
        case .newCollection:
            selection = .collections
            newCollectionRequested = true
        case .newSource:
            selection = .sources
            setTab(0, for: .sources)
            sourcesModel.addSource(app)
        case .newClientKey:
            selection = .clients
            setTab(0, for: .clients)
            newClientRequested = true
        case .connect:
            Task {
                await app.connect()
                await collectionsModel.refresh(app)
            }
        case .disconnect:
            Task { await app.disconnect() }
        case .restartServer:
            Task { await serverModel.restart(app, collectionsModel: collectionsModel) }
        case .stopServer:
            confirmingServerStop = true
        case .backUp:
            // Копию видно там, где копии живут: ход и итог — на вкладке.
            selection = .environment
            setTab(1, for: .environment)
            environmentModel.makeBackupNow(app)
        case .search:
            collectionsModel.pendingSearchTab = true
            Task { await collectionsModel.runQuery(app) }
        case .addDocuments:
            collectionsModel.beginAddingDocument(app)
        case .export:
            collectionsModel.showExportSheet = true
        case .reembed:
            guard let collection = collectionsModel.selected else { return }
            reembedding.begin(collection: collection, app: app)
        case .selectTab(let index):
            setTab(index, for: currentSection)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch currentSection {
        case .overview:
            switch openTab {
            case 1:
                ConnectionView(model: connectionModel, collectionsModel: collectionsModel)
            default:
                OverviewView(
                    server: serverModel, collectionsModel: collectionsModel,
                    environment: environmentModel, sources: sourcesModel,
                    embeddings: embeddingsModel, diskUsage: diskUsageModel,
                    // Переход помнит и раздел, и вкладку: «Подключение» вело
                    // на «Обзор», где мы и так стояли, а «Копии» — в тот
                    // раздел, но на вкладку, открытую в прошлый раз.
                    go: { section, tab in
                        selection = section
                        if let tab { setTab(tab, for: section) }
                    }
                )
            }
        case .collections:
            CollectionsView(
                model: collectionsModel, embeddingsModel: embeddingsModel, reembedding: reembedding,
                newCollectionRequested: $newCollectionRequested
            )
        case .sources:
            SourcesScreen(
                model: sourcesModel, embeddings: embeddingsModel,
                autoSync: autoSync, tab: openTab,
                openTab: { index in setTab(index, for: .sources) }
            )
        case .models:
            EmbeddingsView(
                model: embeddingsModel, sources: sourcesModel,
                autoSync: autoSync, collectionsModel: collectionsModel, tab: openTab
            )
        case .evaluation:
            EvaluationView(
                model: evaluationModel, tab: openTab,
                openTab: { index in setTab(index, for: .evaluation) }
            )
        case .trash:
            TrashView(model: trashModel)
        case .clients:
            ClientsView(
                model: clientsModel, mcp: app.mcp, tab: openTab,
                newClientRequested: $newClientRequested,
                showInJournal: { client in
                    // Журнал доступа — в «Логах», отобранный по клиенту.
                    accessQuery = client.name
                    selection = .logs
                    setTab(1, for: .logs)
                }
            )
        case .security:
            SecurityView(
                model: securityModel, serverModel: serverModel, tab: openTab,
                openTab: { index in setTab(index, for: .security) }
            )
        case .environment:
            EnvironmentStatusView(model: environmentModel, tab: openTab)
        case .tasks:
            TasksView(sources: sourcesModel)
        case .logs:
            LogsView(reembedding: reembedding, serverModel: serverModel, tab: openTab, auditSearch: $accessQuery)
        }
    }

    /// Настройки изменились так, как в обычной работе не изменяются.
    ///
    /// Наверху окна и над любым разделом: это ровно тот случай, ради которого
    /// написано правило 2 — молча ничего не происходит. Одиннадцать источников
    /// исчезли без единого слова на экране, и найдено это было через сутки,
    /// глазами.
    ///
    /// Закрывается кнопкой, а не таймером: сообщение, исчезающее само, человек
    /// пропустит ровно тогда, когда отойдёт от машины.
    @ViewBuilder
    private var settingsAlarm: some View {
        if let rewrite = settings.foreignRewrite {
            // Настройки переписала другая сборка: что пропало
            // и одна кнопка, чтобы вернуть.
            VStack(alignment: .leading) {
                HStack(alignment: .top) {
                    Notice(.warning, String(localized: "Настройки переписаны другой версией приложения — скорее всего, запускалась старая копия. Пропало: \(rewrite.lost.prefix(6).joined(separator: "; "))\(rewrite.lost.count > 6 ? "…" : "")."))
                    Spacer()
                    Button(String(localized: "Вернуть")) { settings.restoreForeignLosses() }
                        .buttonStyle(.borderedProminent)
                    Button(String(localized: "Оставить как есть")) { settings.acceptForeignRewrite() }
                }
                Text("Возвращается только пропавшее, ничего из изменённого не затирается. Старые копии приложения лучше не запускать: они переписывают настройки по-своему.")
                    .foregroundStyle(.secondary)
            }
            .padding()
            Divider()
        } else if let loss = settings.loss {
            VStack(alignment: .leading) {
                HStack(alignment: .top) {
                    Notice(.warning, loss.message)
                    Spacer()
                    Button(String(localized: "Понятно")) { settings.acknowledgeLoss() }
                }
                if let snapshot = loss.snapshot {
                    HStack {
                        Text("Снимок остаётся на диске, пока его не удалят вручную.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(String(localized: "Показать снимок в Finder")) {
                            NSWorkspace.shared.activateFileViewerSelecting([snapshot])
                        }
                    }
                }
            }
            .padding()
            Divider()
        } else if settings.recoveredFromPreviousCopy {
            VStack(alignment: .leading) {
                HStack(alignment: .top) {
                    Notice(.warning, String(localized: "Файла настроек на месте не оказалось — они подняты из копии «как было». Проверьте, всё ли на месте: правки, сделанные последними, могли в копию не попасть."))
                    Spacer()
                    Button(String(localized: "Понятно")) { settings.acknowledgeRecovery() }
                }
            }
            .padding()
            Divider()
        }
    }

    static func uptimeText(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
