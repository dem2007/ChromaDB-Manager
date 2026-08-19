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
        case .overview: return String(localized: "Куда подключено приложение и что из этого работает")
        case .collections: return String(localized: "Документы, поиск и правила метаданных")
        case .sources: return String(localized: "Папки, сайты и репозитории, которые становятся коллекциями")
        case .models: return String(localized: "Подключение к LM Studio, выбор модели и кэш векторов")
        case .evaluation: return String(localized: "Наборы запросов, варианты поиска и прогоны")
        case .trash: return String(localized: "Удалённые документы, которые ещё можно вернуть")
        case .clients: return String(localized: "Ключи внешних клиентов и доступ агентов через MCP")
        case .security: return String(localized: "Что открыто наружу и на каких условиях")
        case .environment: return String(localized: "Движок, резервные копии и данные приложения")
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
        case .overview: return [
            String(localized: "Состояние"), String(localized: "Подключение"), String(localized: "Сервер"),
        ]
        case .sources: return [
            String(localized: "Источники"), String(localized: "Диагностика"), String(localized: "Стенд"),
        ]
        case .models: return [
            String(localized: "Модели"), String(localized: "Кэш"), String(localized: "Замеры"),
        ]
        // «Проверки» влились в «Установку»: проверка и установка — один
        // разговор, и держать их на разных вкладках значило просить человека
        // прыгать между «чего не хватает» и «как поставить».
        case .environment: return [
            String(localized: "Установка"), String(localized: "Резервные копии"),
            String(localized: "Управление данными"),
        ]
        case .logs: return [
            String(localized: "События"), String(localized: "Доступ"),
            String(localized: "Хранение"), String(localized: "Сервер"),
        ]
        // Три разреза одной темы, как в макете: чем прогонять, что прогонять
        // и что получилось.
        case .evaluation: return [
            String(localized: "Набор запросов"), String(localized: "Варианты"),
            String(localized: "Прогоны"),
        ]
        // Ключи — кто ходит, MCP — как ходят агенты, журнал — что делали.
        case .clients: return [
            String(localized: "Ключи"), String(localized: "MCP"), String(localized: "Журнал"),
        ]
        // Сводка — что сейчас открыто, «Доступ по сети» — где это решается,
        // «Уведомления» — о чём предупреждать.
        case .security: return [
            String(localized: "Сводка"), String(localized: "Доступ по сети"),
            String(localized: "Уведомления"),
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

/// Время работы сервера — в отдельной вьюхе, и это не украшательство.
///
/// `ChromaProcessManager.uptime` обновляется **раз в секунду**, пока сервер
/// запущен. Пока это поле читал `RootView`, каждое такое обновление
/// перестраивало его `body` — а вместе с ним и `content`, то есть тело
/// открытого раздела. Любая работа, которую экран делает при отрисовке,
/// оплачивалась заново каждую секунду, вечно; отсюда «интерфейс подтормаживает»
/// на тяжёлых разделах при полностью простаивающем приложении.
///
/// Наблюдение за менеджером процесса живёт здесь, и перерисовывается раз
/// в секунду только эта надпись.
private struct ServerUptimeLabel: View {
    @EnvironmentObject private var processManager: ChromaProcessManager

    var body: some View {
        if processManager.isRunning, let uptime = processManager.uptime {
            Text("· \(processManager.state.title) · \(RootView.uptimeText(uptime))")
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    // Стартуем со статуса окружения: пока движок не найден, остальное бессмысленно.
    @State private var selection: SidebarSection? = .overview
    /// Открытая вкладка каждого раздела.
    @State private var tabs: [SidebarSection: Int] = [:]

    @StateObject private var environmentModel = EnvironmentViewModel()
    @StateObject private var connectionModel = ConnectionViewModel()
    @StateObject private var serverModel = ServerViewModel()
    @StateObject private var clientsModel = ClientsViewModel()
    @StateObject private var securityModel = SecurityViewModel()
    @StateObject private var collectionsModel = CollectionsViewModel()
    @StateObject private var evaluationModel = EvaluationViewModel()
    @StateObject private var trashModel = TrashViewModel()
    @StateObject private var embeddingsModel = EmbeddingsViewModel()
    @StateObject private var sourcesModel = SourcesViewModel()
    @StateObject private var autoSync = AutoSyncCoordinator()
    @StateObject private var reembedding = ReembeddingViewModel()
    /// Что бросили на окно и о чём ещё не спросили.
    @State private var droppedItems: DroppedItems?

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                // Имя приложения и одна строка о том, куда оно подключено:
                // в макете это первое, что видно, и отвечает на вопрос
                // «с чем я сейчас работаю» до открытия любого раздела.
                // Имя приложения и точка состояния рядом с ним. Строка «куда
                // подключено» жила здесь же, но она слово в слово повторяла
                // статусную строку внизу окна — а та ещё и полнее.
                HStack(spacing: 7) {
                    Text("ChromaDB Manager")
                        .font(Theme.Font.control.weight(.semibold))
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 7, height: 7)
                        .help(app.connection.title)
                }
                // Отступ слева тот же, что у рубрик «База», «Данные» — имя
                // приложения встаёт на одну вертикаль с ними, а не висит
                // отдельно; сверху — воздух, чтобы оно не липло к кнопкам окна.
                .padding(.horizontal, 15)
                .padding(.top, 14)
                .padding(.bottom, 12)

                // Группы вместо плоского списка: рубрика говорит, где искать,
                // и двенадцать пунктов перестают быть одной длинной колонкой
                //.
                List(selection: $selection) {
                    ForEach(SidebarGroup.allCases) { group in
                        Section {
                            ForEach(group.sections) { section in
                                Label(section.title, systemImage: section.icon)
                                    .font(Theme.Font.control)
                                    .tag(section)
                            }
                        } header: {
                            Text(group.title)
                                .font(Theme.Font.sectionLabel)
                                .kerning(0.6)
                                .textCase(.uppercase)
                                .foregroundStyle(Theme.Palette.caption)
                        }
                    }
                }
                .listStyle(.sidebar)
                // Сплошная синяя строка — не то, как macOS отмечает выбранный
                // пункт. Подкрашивание списка приглушает выделение до мягкой
                // вставки из макета, а выбор с клавиатуры продолжает работать —
                // чего нарисованный руками фон стоил бы.
                .tint(Theme.Palette.navSelection)
            }
            .navigationSplitViewColumnWidth(
                min: 220, ideal: Theme.Size.sidebarWidth, max: 300
            )
        } detail: {
            VStack(spacing: 0) {
                screenHeader
                settingsAlarm
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                statusBar
            }
            // Заголовок один, и он в системной полосе окна: полоса всё равно
            // есть у каждого окна macOS, и пустой она была местом, которое
            // ничего не говорит, — а над содержимым стояла вторая строка того
            // же назначения.
            //
            // Своим элементом тулбара, а не `navigationTitle`: системный
            // заголовок прижат к краю окна и не совпадает по левому краю ни
            // с подписью под ним, ни с карточками. Здесь отступ наш, и он тот
            // же, что у содержимого.
            .navigationTitle("")
            // Заголовок рисуется своим видом в титульной полосе окна, а не
            // элементом тулбара: элемент система кладёт на «стеклянную»
            // подложку с тенью и своим отступом, а нужен просто текст,
            // стоящий ровно над первой карточкой.
            .background(TitlebarTitle(text: (selection ?? .overview).title))
        }
        // Волосяная линия под титульной полосой — системный разделитель:
        // macOS рисует его, когда под полосой есть содержимое. У нас там
        // заголовок экрана на том же полотне, и линия делит не два слоя,
        // а один.
        .toolbarBackground(.hidden, for: .windowToolbar)
        // System button geometry everywhere: 7pt corners, not capsules.
        .chromaControlShape()
        // Полосы прокрутки во всех окнах приложения — накладные, чтобы они не
        // меняли ширину содержимого. Одно место на всё приложение:
        // экраны, вкладки, листы и панели.
        .background(WindowScrollerStyle().frame(width: 0, height: 0))
        .task { await startUp() }
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

    /// Шапка экрана: строка о том, чему посвящён раздел, и его вкладки.
    ///
    /// Имя раздела отсюда уехало **в заголовок окна**: системная
    /// полоса окна пустовала, а над содержимым стояла ещё одна строка того же
    /// назначения. Подпись осталась здесь — она про содержимое, а не про
    /// место в приложении, и в заголовок окна не помещается.
    @ViewBuilder
    private var screenHeader: some View {
        let section = selection ?? .overview
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(section.subtitle)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
            }
            if !section.tabs.isEmpty {
                SegmentedSelector(
                    options: Array(section.tabs.enumerated()).map { ($0.offset, $0.element) },
                    selection: Binding(
                        get: { tabs[section] ?? 0 },
                        set: { tabs[section] = $0 }
                    )
                )
                .padding(.top, 14)
            }
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.top, 4)
        .padding(.bottom, section.tabs.isEmpty ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Открытая вкладка каждого раздела — своя, и она переживает переход на
    /// соседний раздел и обратно: человек вернулся туда, где был.
    private var openTab: Int { tabs[selection ?? .overview] ?? 0 }

    /// Цвет точки состояния подключения — один на оба места, где она есть.
    private var connectionColor: Color {
        switch app.connection {
        case .connected: return Theme.Palette.running
        case .connecting: return Theme.Palette.attention
        case .failed: return Theme.Palette.danger
        case .disconnected: return Theme.Palette.stopped
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selection ?? .overview {
        case .overview:
            switch openTab {
            case 1:
                ConnectionView(model: connectionModel, collectionsModel: collectionsModel)
            case 2:
                ServerView(model: serverModel, collectionsModel: collectionsModel)
            default:
                OverviewView(
                    server: serverModel, collectionsModel: collectionsModel,
                    environment: environmentModel, sources: sourcesModel,
                    embeddings: embeddingsModel,
                    // Переход помнит и раздел, и вкладку: «Подключение» вело
                    // на «Обзор», где мы и так стояли, а «Копии» — в тот
                    // раздел, но на вкладку, открытую в прошлый раз.
                    go: { section, tab in
                        selection = section
                        if let tab { tabs[section] = tab }
                    }
                )
            }
        case .collections:
            CollectionsView(model: collectionsModel, embeddingsModel: embeddingsModel, reembedding: reembedding)
        case .sources:
            SourcesScreen(
                model: sourcesModel, embeddings: embeddingsModel,
                autoSync: autoSync, tab: openTab,
                openTab: { index in tabs[.sources] = index }
            )
        case .models:
            EmbeddingsView(
                model: embeddingsModel, sources: sourcesModel,
                autoSync: autoSync, collectionsModel: collectionsModel, tab: openTab
            )
        case .evaluation:
            EvaluationView(
                model: evaluationModel, tab: openTab,
                openTab: { index in tabs[.evaluation] = index }
            )
        case .trash:
            TrashView(model: trashModel)
        case .clients:
            ClientsView(model: clientsModel, mcp: app.mcp, tab: openTab)
        case .security:
            SecurityView(model: securityModel, serverModel: serverModel, tab: openTab)
        case .environment:
            EnvironmentStatusView(model: environmentModel, tab: openTab)
        case .tasks:
            TasksView(sources: sourcesModel)
        case .logs:
            LogsView(reembedding: reembedding, serverModel: serverModel, tab: openTab)
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
        if let loss = settings.loss {
            VStack(alignment: .leading, spacing: 8) {
                MessageBanner(kind: .error, text: loss.message) { settings.acknowledgeLoss() }
                if let snapshot = loss.snapshot {
                    HStack(spacing: 12) {
                        Button("Показать снимок в Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([snapshot])
                        }
                        Text("Снимок остаётся на диске, пока его не удалят вручную.")
                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        } else if settings.recoveredFromPreviousCopy {
            VStack(alignment: .leading, spacing: 8) {
                MessageBanner(
                    kind: .warning,
                    text: String(localized: "Файла настроек на месте не оказалось — они подняты из копии «как было». Проверьте, всё ли на месте: правки, сделанные последними, могли в копию не попасть.")
                ) { settings.acknowledgeRecovery() }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            // Точка та же, что и везде: плоская, восьми пунктов, цвет несёт
            // состояние. Эмодзи 🟢 рисуется шрифтом — он объёмный, с бликом,
            // и меняет вид от системы к системе; рядом с плоскими точками
            // карточек это выглядело как чужая деталь.
            Circle()
                .fill(connectionColor)
                .frame(width: Theme.Size.statusDot, height: Theme.Size.statusDot)
            Text(app.connection.title)
                .font(Theme.Font.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            // a permanent badge, not a checkbox buried in the profile —
            // the point is that nobody wonders why a write was refused.
            if app.connection.isReadOnly {
                Label(String(localized: "только чтение"), systemImage: "lock.fill")
                    .font(Theme.Font.tableHeader)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
                    .foregroundStyle(.orange)
                    .help(String(localized: "Подключение открыто только для чтения: запись, импорт и синхронизация отклоняются."))
            }

            // Настройки не сохраняются — это состояние, при котором любая
            // правка исчезнет после перезапуска. Значок постоянный: узнавать об
            // этом по пропавшим источникам — ровно то, что уже случилось.
            if settings.persistenceProblem != nil {
                Label(String(localized: "настройки не сохраняются"), systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Font.tableHeader)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.18), in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
                    .foregroundStyle(.red)
                    .help(settings.persistenceProblem ?? "")
            }

            if let activity = autoSync.activity {
                // Automatic work is never invisible.
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text(activity).font(Theme.Font.caption).lineLimit(1).truncationMode(.middle)
                }
            } else if settings.configuration.automaticSyncPaused,
                      settings.configuration.dataSources.contains(where: { $0.triggers.isAnyEnabled }) {
                Text("· автоиндексация на паузе")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.orange)
            }

            ServerUptimeLabel()

            Spacer()

            Text(String(localized: "Режим: \(settings.configuration.mode.title)"))
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)

            if case .connecting = app.connection {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task {
                        await app.reconnect()
                        await collectionsModel.refresh(app)
                    }
                } label: {
                    Label(String(localized: "Переподключиться"), systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Переподключиться к ChromaDB"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
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
