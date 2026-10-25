import SwiftUI
import ChromaCore

/// «Источники» — тип Б: список источников, подробности выбранного —
/// в инспекторе справа.
///
/// Действия над выбранным — тулбар и контекстное меню; «Синхронизировать
/// все» — главная кнопка тулбара. План синхронизации и разбор исчезнувших
/// файлов — листы: это отдельные задачи со своим ответом, а не строки
/// длинного экрана, до которых надо долистать.
struct SourcesSection: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var model: SourcesViewModel
    @ObservedObject var embeddings: EmbeddingsViewModel
    @ObservedObject var autoSync: AutoSyncCoordinator
    /// Перейти на вкладку «Диагностика» этого экрана.
    var openDiagnostics: () -> Void = {}

    @Environment(\.openSettings) private var openSettings
    @State private var selection: UUID?
    @SceneStorage("sources.inspector") private var showsInspector = true
    @State private var showsDecisions = false
    /// Сводка, открытая в листе «Подробнее…», — своя копия, а не
    /// `model.lastSummary`: очередь синхронизаций идёт дальше, пока
    /// лист открыт, и запуск следующего источника обнулял сводку модели —
    /// лист оставался пустым, без кнопки «Закрыть».
    @State private var shownSummary: SyncSummary?

    /// Открыт ли лист сводки: он открыт, пока у него есть своя копия.
    private var showsSummary: Binding<Bool> {
        Binding(get: { shownSummary != nil }, set: { if !$0 { shownSummary = nil } })
    }
    /// Источник, для которого спрашивается «Переизвлечь и переэмбедить».
    @State private var reextractCandidate: DataSource?

    private var sources: [DataSource] { settings.configuration.dataSources }

    private var selectedSource: DataSource? {
        guard let selection else { return nil }
        return sources.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            topRows
            if sources.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "Источников пока нет"), systemImage: "folder.badge.plus")
                } description: {
                    Text("Источник — это папка, сайт или репозиторий, который становится коллекцией и обновляется по вашей команде. Папку можно просто перетащить на окно.")
                } actions: {
                    addMenu
                        .fixedSize()
                }
            } else {
                sourceList
            }
        }
        .toolbar { toolbarContent }
        .fittingInspector(isPresented: $showsInspector) {
            Group {
                if let source = selectedSource {
                    SourceInspector(
                        source: source, model: model, autoSync: autoSync,
                        showDecisions: { showsDecisions = true },
                        askReextract: { reextractCandidate = $0 }
                    )
                } else {
                    InspectorPlaceholder(String(localized: "Выберите источник в списке."))
                }
            }
        }
        .onAppear {
            model.refreshManifests(app)
            if selection == nil { selection = sources.first?.id }
            // Папку могли перетащить на окно ещё до того, как этот экран
            // открылся.
            model.beginEditingDroppedFolder(app)
        }
        .onChange(of: model.pendingDrop) { model.beginEditingDroppedFolder(app) }
        // Папок могло быть несколько: закрыли редактор — открывается
        // следующая, и ни одна не теряется молча.
        .onChange(of: model.draft == nil) { model.beginEditingDroppedFolder(app) }
        // Источник, добавленный или синхронизированный где-то ещё, иначе
        // остался бы с фактами прошлого захода на экран.
        .onChange(of: sources.map(\.id)) {
            model.refreshManifests(app)
            if let selection, !sources.contains(where: { $0.id == selection }) {
                self.selection = sources.first?.id
            }
        }
        .sheet(isPresented: Binding(
            get: { model.draft != nil },
            set: { if !$0 { model.cancelDraft() } }
        )) {
            SourceEditorSheet(model: model, embeddings: embeddings)
        }
        .sheet(isPresented: Binding(
            get: { model.tableMappingSource != nil },
            set: { if !$0 { model.tableMappingSource = nil } }
        )) {
            if let source = sources.first(where: { $0.id == model.tableMappingSource }) {
                TableMappingSheet(model: model.tableMapping, source: source) {
                    model.tableMappingSource = nil
                }
            }
        }
        // По листу на каждый план, один за другим: источников можно
        // поставить несколько, и у каждого свой ответ на «что это
        // затронет». Закрыли один — открывается следующий.
        .sheet(isPresented: Binding(
            get: { currentPlan != nil && model.draft == nil },
            set: { if !$0, let plan = currentPlan { dismiss(plan) } }
        )) {
            if let plan = currentPlan {
                SyncPlanSheet(plan: plan, model: model) { dismiss(plan) }
            }
        }
        .sheet(isPresented: $showsDecisions) {
            PendingDecisionsSheet(model: model) { showsDecisions = false }
        }
        .sheet(isPresented: showsSummary) {
            if let summary = shownSummary {
                SyncSummarySheet(summary: summary, openDiagnostics: openDiagnostics) { shownSummary = nil }
            }
        }
        // Правило 3: сначала список, потом действие. Спрашивается **что именно
        // исчезнет** и что останется — иначе человек согласится, думая, что
        // удаляет коллекцию, или откажется, думая, что удаляет папку с диска.
        .confirmationDialog(
            model.sourcePendingRemoval.map { String(localized: "Убрать источник «\($0.name)» из списка?") } ?? "",
            isPresented: Binding(
                get: { model.sourcePendingRemoval != nil },
                set: { if !$0 { model.sourcePendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Убрать из списка"), role: .destructive) {
                if let source = model.sourcePendingRemoval {
                    model.removeSource(source, app: app)
                }
                model.sourcePendingRemoval = nil
            }
            Button(String(localized: "Отменить"), role: .cancel) { model.sourcePendingRemoval = nil }
        } message: {
            if let source = model.sourcePendingRemoval {
                Text("Папка на диске и документы в коллекции «\(source.collectionName)» останутся нетронутыми. Исчезнут настройки самого источника: стратегия и параметры нарезки, расписания, поля метаданных и профили таблиц — восстановить их будет неоткуда.")
            }
        }
        // столько файлов разом не исчезает по воле человека. Вопрос
        // задаётся отдельно от всех прочих — ответ «да» стоит тысяч
        // документов, и утонуть в строке в углу экрана он не должен.
        .confirmationDialog(
            model.massRemoval.map { String(localized: "Источник «\($0.source.name)»: файлы исчезли с диска") } ?? "",
            isPresented: Binding(
                get: { model.massRemoval != nil },
                set: { if !$0 { model.massRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Подтвердить: файлы действительно удалены"), role: .destructive) {
                if let prompt = model.massRemoval { model.confirmMassRemoval(prompt, app: app) }
                model.massRemoval = nil
            }
            Button(String(localized: "Отмена — проверю диск"), role: .cancel) { model.massRemoval = nil }
        } message: {
            if let prompt = model.massRemoval { Text(prompt.message) }
        }
        // путь тот же, а диск другой. Принять новый диск — решение
        // человека, и спрашивается оно отдельным вопросом, как и пропажа.
        .confirmationDialog(
            model.volumeMismatch.map { String(localized: "Источник «\($0.sourceName)» на другом диске") } ?? "",
            isPresented: Binding(
                get: { model.volumeMismatch != nil },
                set: { if !$0 { model.volumeMismatch = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Это тот же источник на новом диске")) {
                if let prompt = model.volumeMismatch { model.acceptNewVolume(prompt, app: app) }
                model.volumeMismatch = nil
            }
            Button(String(localized: "Отмена — проверю диск"), role: .cancel) { model.volumeMismatch = nil }
        } message: {
            if let prompt = model.volumeMismatch { Text(prompt.message) }
        }
        // сказано, но не сделано — обновление приложения не запускает
        // часы работы модели само. Бэкап называется в самом вопросе.
        .confirmationDialog(
            reextractCandidate.map { String(localized: "Переизвлечь и переэмбедить «\($0.name)»?") } ?? "",
            isPresented: Binding(
                get: { reextractCandidate != nil },
                set: { if !$0 { reextractCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Переизвлечь и переэмбедить")) {
                if let source = reextractCandidate { model.reextract(source, app: app) }
                reextractCandidate = nil
            }
            Button(String(localized: "Отменить"), role: .cancel) { reextractCandidate = nil }
        } message: {
            if let source = reextractCandidate {
                let stale = model.staleExtraction[source.id] ?? []
                Text("Сначала делается бэкап. Затем файлы, извлечённые прежней версией экстрактора (\(stale.count.plainDigits): \(Set(stale.map(\.previous.text)).sorted().joined(separator: ", ")) → \(stale.first?.current.text ?? "")), будут прочитаны заново и пересчитаны моделью.")
            }
        }
    }

    // MARK: - Над списком

    /// Строки над списком: то, из-за чего сюда пришли, — что сейчас идёт и
    /// что ждёт решения. Как на экране коллекций: строки и черта под ними.
    @ViewBuilder
    private var topRows: some View {
        let removalCount = model.pendingRemovals.values.reduce(0) { $0 + $1.count }
        let sheetCount = model.pendingRowRemovals.values.reduce(0) { $0 + $1.count }
        let pausedMatters = settings.configuration.automaticSyncPaused
            && sources.contains(where: { $0.triggers.isAnyEnabled })
        let visible = model.errorMessage != nil || model.infoMessage != nil
            || settings.persistenceProblem != nil || pausedMatters || model.isBusy
            || removalCount + sheetCount > 0 || model.lastSummary != nil

        if visible {
            VStack(alignment: .leading) {
                if let error = model.errorMessage {
                    HStack {
                        Notice(.warning, error)
                        Spacer()
                        Button(String(localized: "Скрыть")) { model.errorMessage = nil }
                            .buttonStyle(.borderless)
                    }
                }
                if let message = model.infoMessage {
                    HStack {
                        Notice(.info, message)
                        Spacer()
                        Button(String(localized: "Скрыть")) { model.infoMessage = nil }
                            .buttonStyle(.borderless)
                    }
                }
                // Список источников живёт в config.json. Если файл не
                // прочитался, список на экране пуст — и добавление нового
                // источника ничего не восстановит, а старый файл трогать нельзя.
                if let problem = settings.persistenceProblem {
                    HStack {
                        Notice(.warning, problem)
                        Spacer()
                        Button(String(localized: "Перечитать настройки")) { settings.reload() }
                            .help(String(localized: "Рядом с config.json лежит config.previous.json — предыдущая сохранённая версия."))
                    }
                }
                // Автоматическая индексация на паузе — это состояние, из-за
                // которого источники «не обновляются сами», и оно должно быть
                // видно (правило 2 Приложения 5).
                if pausedMatters {
                    HStack {
                        Notice(.warning, String(localized: "Автоматическая индексация приостановлена — по расписанию и при изменениях ничего не запустится."))
                        Spacer()
                        Button(String(localized: "Возобновить")) { autoSync.setPaused(false, app: app) }
                    }
                }
                // Идущая синхронизация. Отдельной вьюхой (см. `SyncProgressRows`):
                // перестраивать экран четыре раза в секунду ради полоски нельзя.
                if model.isBusy {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading) {
                            SyncProgressRows(label: progressLabel)
                        }
                        Spacer()
                        // «Все»: у каждого источника есть своя «Остановить»,
                        // и эта обязана отличаться от неё.
                        Button(String(localized: "Остановить все"), role: .destructive) { model.cancel() }
                    }
                    .help(String(localized: "Модель обслуживает по одному источнику за раз. Остальные можно поставить в очередь и уйти — они пойдут сами, один за другим."))
                }
                if removalCount + sheetCount > 0 {
                    HStack {
                        Notice(.warning, decisionsLine(files: removalCount, sheets: sheetCount))
                        Spacer()
                        Button(String(localized: "Разобрать…")) { showsDecisions = true }
                    }
                }
                if let summary = model.lastSummary {
                    HStack {
                        StatusLabel(
                            summary.skipped.isEmpty && summary.tableWarnings.isEmpty && summary.markedForAttention.isEmpty
                                ? .ok : .warning,
                            String(localized: "«\(summary.sourceName)»: \(summary.line)")
                        )
                        .lineLimit(1)
                        .truncationMode(.tail)
                        Spacer()
                        Button(String(localized: "Подробнее…")) { shownSummary = summary }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .padding()
            Divider()
        }
    }

    private func decisionsLine(files: Int, sheets: Int) -> String {
        switch (files > 0, sheets > 0) {
        case (true, true):
            return String(localized: "Исчезли с диска или вышли из источника файлы (\(files.plainDigits)) и листы таблиц (\(sheets.plainDigits)) — документы ждут вашего решения.")
        case (true, false):
            return String(localized: "Файлы исчезли с диска или вышли из источника: \(files.plainDigits) — документы ждут вашего решения.")
        default:
            return String(localized: "Листы таблиц потеряли строки: \(sheets.plainDigits) — строки ждут вашего решения.")
        }
    }

    // MARK: - Список

    private var sourceList: some View {
        List(selection: $selection) {
            ForEach(sources) { source in
                SourceRow(
                    source: source,
                    state: rowState(source),
                    isBusy: model.isBusy(source.id)
                )
                .tag(source.id)
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let source = sources.first(where: { $0.id == id }) {
                sourceMenu(source)
            }
        } primaryAction: { ids in
            if let id = ids.first, let source = sources.first(where: { $0.id == id }),
               !model.isBusy(source.id) {
                model.beginEditing(source)
            }
        }
        .onDeleteCommand {
            if let source = selectedSource { model.sourcePendingRemoval = source }
        }
    }

    /// Состояние строки — одно слово и цвет; подробности — в инспекторе.
    private func rowState(_ source: DataSource) -> (StatusLabel.State, String) {
        if model.isBusy(source.id) {
            return (.ok, String(localized: "синхронизируется"))
        }
        if model.pendingConfirmations.contains(source.id) {
            return (.warning, String(localized: "ждёт подтверждения"))
        }
        if model.recoveryBlocks[source.id] != nil {
            return (.warning, String(localized: "автозапуск приостановлен"))
        }
        if SourceInspector.needsAttention(source, model: model) {
            return (.warning, String(localized: "требует решения"))
        }
        switch model.syncStatus(of: source.id) {
        case .unknown:
            return (.off, String(localized: "загружается…"))
        case .neverSynced:
            return (.off, String(localized: "не синхронизирован"))
        case .synced:
            return (.ok, String(localized: "синхронизирован"))
        }
    }

    // MARK: - Действия

    @ViewBuilder
    private func sourceMenu(_ source: DataSource) -> some View {
        let busy = model.isBusy(source.id)
        if busy {
            Button(String(localized: "Остановить")) { model.cancel(sourceID: source.id) }
        } else if model.pendingConfirmations.contains(source.id) {
            Button(String(localized: "Подтвердить запуск")) { model.runPlannedSync(source, app: app) }
                .disabled(!app.connection.isConnected)
        } else {
            Button(String(localized: "Синхронизировать")) { model.sync(source, app: app) }
                .disabled(!app.connection.isConnected)
        }
        Button(String(localized: "План…")) { model.preview(source, app: app) }
            .disabled(busy)
        Divider()
        Button(String(localized: "Настроить…")) { model.beginEditing(source) }
            .disabled(busy)
        // Копия не трогает оригинал, поэтому и во время его прогона.
        Button(String(localized: "Скопировать источник…")) { model.beginCopying(source, app: app) }
        // Only for sources that actually name a table format.
        if source.fileExtensions.contains(where: TabularFormat.allExtensions.contains) {
            Button(String(localized: "Таблицы…")) { model.tableMappingSource = source.id }
                .disabled(busy)
        }
        if !(model.staleExtraction[source.id] ?? []).isEmpty {
            Button(String(localized: "Переизвлечь и переэмбедить…")) { reextractCandidate = source }
                .disabled(busy || !app.connection.isConnected)
        }
        if !source.isWeb {
            Button(String(localized: "Показать в Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.path)])
            }
        }
        Divider()
        Button(String(localized: "Убрать источник из списка…"), role: .destructive) {
            model.sourcePendingRemoval = source
        }
    }

    private var addMenu: some View {
        Menu {
            Button(String(localized: "Папку…")) { model.addSource(app) }
            Button(String(localized: "Сайт…")) { model.addWebSource(app) }
            Button(String(localized: "Репозиторий…")) { model.addGitSource(app) }
        } label: {
            Label(String(localized: "Добавить"), systemImage: "plus")
        }
        .help(String(localized: "Добавить источник: папку, сайт или git-репозиторий"))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            addMenu
            // Обычная кнопка, не выделенная (v3): в тулбаре macOS
            // выделенных нет. Синхронизация выбранного — в меню «Ещё» и в
            // контекстном меню строки.
            Button {
                model.syncAll(app)
            } label: {
                Label(String(localized: "Синхронизировать все"), systemImage: "arrow.triangle.2.circlepath")
            }
            .help(String(localized: "Синхронизировать все источники"))
            .disabled(model.isSyncingAll || sources.isEmpty || !app.connection.isConnected)
            Toggle(isOn: $showsInspector) {
                Label(String(localized: "Инспектор"), systemImage: "sidebar.right")
            }
            .toggleStyle(.button)
            .help(String(localized: "Показать или скрыть подробности источника"))
            .keyboardShortcut("i", modifiers: [.command, .option])
            Menu {
                // То же меню, что у строки: одно место правды о действиях
                // над источником.
                if let source = selectedSource {
                    Section(source.name) { sourceMenu(source) }
                    Divider()
                }
                Button(String(localized: "Правила запуска и умолчания нарезки…")) {
                    UserDefaults.standard.set(SettingsWindow.Tab.sources.rawValue, forKey: SettingsWindow.tabKey)
                    openSettings()
                }
            } label: {
                Label(String(localized: "Ещё"), systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: - План

    /// Планы в том же порядке, в каком идут источники: словарь отдаёт ключи
    /// как придётся, и листы открывались бы вразнобой.
    private var currentPlan: SyncPlan? {
        sources.lazy.compactMap { model.plans[$0.id] }.first
    }

    private func dismiss(_ plan: SyncPlan) {
        if model.pendingConfirmations.contains(plan.sourceID) {
            model.cancelPendingSync(plan.sourceID)
        } else {
            model.plans[plan.sourceID] = nil
        }
    }

    /// An automatic run names its trigger, and a queued one says it is waiting:
    /// work happening without a visible reason is what the spec forbids.
    private func progressLabel(_ task: QueuedTaskInfo) -> String {
        let reason = model.activeReason?.isAutomatic == true
            ? " · \(model.activeReason?.title ?? "")"
            : ""
        guard task.state == .running else {
            return String(localized: "\(task.title) — в очереди\(reason)")
        }
        return "\(task.title)\(reason)"
    }

    static func seconds(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : (value).decimal(1)
    }
}

// MARK: - Строка списка

private struct SourceRow: View {
    let source: DataSource
    let state: (StatusLabel.State, String)
    let isBusy: Bool

    var body: some View {
        HStack {
            // Как у строк «Коллекций» (v3): имя и подпись, обе в одну строку.
            VStack(alignment: .leading) {
                Text(source.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(source.path)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if isBusy {
                ProgressView().controlSize(.small)
            }
            StatusLabel(state.0, state.1).dotOnly()
        }
        .help(source.path)
    }
}

// MARK: - Инспектор

/// Подробности источника: как он устроен, чем закончил прошлый раз и что
/// у него требует решения — каждое с действием в той же строке.
private struct SourceInspector: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    let source: DataSource
    @ObservedObject var model: SourcesViewModel
    @ObservedObject var autoSync: AutoSyncCoordinator
    let showDecisions: () -> Void
    let askReextract: (DataSource) -> Void

    /// Прошлый прогон — строками с подписями (v5); без манифеста — одной
    /// строкой состояния.
    ///
    /// Числа — файлы и записи обоих манифестов, документов и таблиц.
    /// Раньше здесь стоял только файловый манифест, и у источника с книгами
    /// записей выходило меньше, чем в коллекции: у одной коллекции 951 против
    /// 1 080 — 129 листов шести книг учитываются в манифесте таблиц.
    ///
    /// Показываются они, как и прежде, когда манифест прочитан, — а не по
    /// `SourceSyncStatus.synced`: тот пустой манифест называет «ещё не
    /// синхронизирован», даже если прогон был и все файлы пропущены, а здесь
    /// место фактам — ноль файлов и дата (ревью).
    @ViewBuilder
    private var lastRunRows: some View {
        let info = model.manifestInfo[source.id]
        let tableRows = model.tableRows[source.id] ?? 0
        if info != nil || tableRows > 0 {
            let chunks = info?.chunks ?? 0
            LabeledContent(String(localized: "Файлов в манифесте"), value: ((info?.files ?? 0) + (model.tableFiles[source.id] ?? 0)).formatted())
            LabeledContent(String(localized: "Записей"), value: (chunks + tableRows).formatted())
            if chunks > 0, tableRows > 0 {
                LabeledContent(String(localized: "Из них из таблиц"), value: tableRows.formatted())
            }
            if let updatedAt = info?.updatedAt {
                LabeledContent(String(localized: "Обновлён"), value: updatedAt.formatted(date: .abbreviated, time: .shortened))
            }
        } else {
            LabeledContent(String(localized: "Прошлый раз"), value: model.syncStatus(of: source.id).line)
        }
    }

    /// Параметры нарезки — по строке на параметр, своими для каждой стратегии.
    private var chunkingRows: [(String, String)] {
        [(String(localized: "Стратегия"), source.chunking.strategy.title)] + source.chunking.parameterRows
    }

    /// Есть ли у источника то, что ждёт человека.
    static func needsAttention(_ source: DataSource, model: SourcesViewModel) -> Bool {
        !(model.pendingRemovals[source.id] ?? []).isEmpty
            || !(model.pendingRowRemovals[source.id] ?? []).isEmpty
            || !(model.staleExtraction[source.id] ?? []).isEmpty
            || (model.outdatedMetadata[source.id] ?? 0) > 0
            || !(model.sheetsAwaitingWrite[source.id] ?? []).isEmpty
            || !(model.newFolderLevels[source.id] ?? []).isEmpty
            || model.gitStatus[source.id]?.branchChangeNote != nil
    }

    private var busy: Bool { model.isBusy(source.id) }
    private var canWrite: Bool { !busy && app.connection.isConnected }

    var body: some View {
        Form {
            Section {
                // Длинное — подписью сверху, короткое — строкой (v3).
                InspectorField(String(localized: "Путь"), source.path, monospaced: true)
                LabeledContent(String(localized: "Вид"), value: kindLine)
                LabeledContent(String(localized: "Куда")) {
                    Text(targetsText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(targetsText)
                }
                LabeledContent(String(localized: "Запуск")) {
                    Text(triggerText)
                        .foregroundStyle(source.triggers.isAnyEnabled && settings.configuration.automaticSyncPaused
                                         ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                lastRunRows
            } header: {
                Text(source.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
            } footer: {
                // Действия над источником — в тулбаре и контекстном меню, здесь
                // их не дублируем (v3). Почему запуск остановлен — здесь же
                //. Причина берётся у самого плана: два своих текста
                // разошлись бы при первой правке порога.
                if model.pendingConfirmations.contains(source.id),
                   let plan = model.plans[source.id] {
                    let reasons = plan.confirmationReasons(
                        threshold: settings.configuration.syncPreviewThresholdFiles
                    )
                    Notice(.warning, (reasons.map(\.sentence) + [String(localized: "Запуск ждёт подтверждения — в контекстном меню источника.")])
                        .joined(separator: " "))
                }
            }

            // Нарезка — подписанными строками (v5): одна подпись на весь
            // набор параметров оставляла значения без названий.
            Section {
                ForEach(chunkingRows, id: \.0) { row in
                    LabeledContent(row.0, value: row.1)
                }
            } header: {
                Text("Нарезка")
            }

            attention

            if !source.excludedPaths.isEmpty {
                // an exclusion the user cannot see is a file that
                // silently stopped being indexed (rule 2 Приложения 5).
                Section {
                    ForEach(source.excludedPaths, id: \.self) { path in
                        LabeledContent {
                            Button(String(localized: "Вернуть")) { model.include(path, in: source, app: app) }
                        } label: {
                            Text(path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(path)
                        }
                    }
                } header: {
                    Text("Исключено из источника")
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Всё, что у источника требует решения или объяснения. Каждая строка
    /// с предупреждением — с действием рядом.
    @ViewBuilder
    private var attention: some View {
        let pending = model.pendingRemovals[source.id] ?? []
        let rows = model.pendingRowRemovals[source.id] ?? []
        let stale = model.staleExtraction[source.id] ?? []
        let git = model.gitStatus[source.id]
        let outdated = model.outdatedMetadata[source.id] ?? 0
        let awaiting = model.sheetsAwaitingWrite[source.id] ?? []
        let level = (model.newFolderLevels[source.id] ?? []).first
        let hasAny = model.recoveryBlocks[source.id] != nil || !pending.isEmpty || !rows.isEmpty
            || !stale.isEmpty || outdated > 0 || !awaiting.isEmpty || level != nil || git != nil

        if hasAny {
            Section {
                // Ядро приостанавливает автоматические режимы для источника,
                // чья прошлая синхронизация оборвалась.
                if let reason = model.recoveryBlocks[source.id] {
                    row(String(localized: "Автоматическая индексация приостановлена: \(reason)")) {
                        Button(String(localized: "Синхронизировать вручную")) { model.sync(source, app: app) }
                            .disabled(!canWrite)
                    }
                }
                if !pending.isEmpty || !rows.isEmpty {
                    row(String(localized: "Исчезло с диска: файлов \(pending.count.plainDigits), листов \(rows.count.plainDigits) — ждут вашего решения")) {
                        Button(String(localized: "Разобрать…"), action: showDecisions)
                    }
                }
                // сказано, но не сделано. Переиндексация репозитория
                // стоит часов работы модели.
                if let note = git?.branchChangeNote {
                    Notice(.warning, note)
                }
                if let git, git.hasGit, !git.isRepository {
                    Notice(.info, String(localized: "В этой папке нет git-репозитория — источник индексируется обычным обходом."))
                }
                if let git, !git.hasGit {
                    Notice(.warning, String(localized: "Git не установлен (`xcode-select --install`) — репозиторий индексируется как обычная папка."))
                }
                // said, never done. The line stays until the user
                // presses the button next to it.
                if !stale.isEmpty {
                    row(String(localized: "Извлечены прежней версией экстрактора: \(stale.count.plainDigits)")) {
                        Button(String(localized: "Переизвлечь…")) { askReextract(source) }
                            .disabled(!canWrite)
                    }
                }
                // поля источника изменились, а в базе лежат прежние.
                if outdated > 0 {
                    row(String(localized: "Поля в базе записаны прежними настройками: \(outdated.plainDigits) файлов")) {
                        Button(String(localized: "Обновить поля")) { model.refreshMetadata(source, app: app) }
                            .disabled(!canWrite)
                            .help(String(localized: "Переписываются только метаданные чанков: векторы не пересчитываются, модель не вызывается. Сначала делается бэкап."))
                    }
                }
                // лист очищен под переиндексацию, а записать его заново
                // некому до следующего прогона.
                if !awaiting.isEmpty {
                    row(String(localized: "Листов очищено под переиндексацию: \(awaiting.count.plainDigits) — их строк в базе сейчас нет")) {
                        Button(String(localized: "Синхронизировать")) { model.sync(source, app: app) }
                            .disabled(!canWrite)
                            .help(String(localized: "Ждут записи: \(awaiting.prefix(3).map(\.title).joined(separator: ", "))\(awaiting.count > 3 ? " и ещё \((awaiting.count - 3).plainDigits)" : ""). Обычная синхронизация запишет их заново — по нынешней разметке."))
                    }
                }
                // в папке появилась ещё одна ступень. Приложение не
                // выдумывает ей имя — говорит и ждёт.
                if let level {
                    row(String(localized: "Появился уровень вложенности \(level.number.plainDigits): \(level.folderCount.plainDigits) папок (\(level.examples.joined(separator: ", ")))")) {
                        Button(String(localized: "Назвать уровень…")) { model.beginEditing(source) }
                            .disabled(busy)
                            .help(String(localized: "Пока поле не задано, названия этих папок в метаданные не пишутся. Уже проиндексированные файлы при этом не трогаются."))
                    }
                }
            } header: {
                Text("Требует решения")
            }
        }
    }

    private func row<Action: View>(_ text: String, @ViewBuilder action: () -> Action) -> some View {
        VStack(alignment: .leading) {
            Notice(.warning, text)
            HStack {
                Spacer()
                action()
            }
        }
    }

    /// Чем источник является.
    private var kindLine: String {
        if source.isWeb { return webSummary }
        if let git = source.git {
            let scope = git.indexesWorkingCopy
                ? String(localized: "рабочая копия как есть")
                : String(localized: "только последний коммит")
            let branch = model.gitStatus[source.id]?.branch.map { String(localized: "ветка \($0)") }
                ?? String(localized: "git-репозиторий")
            return "\(branch), \(scope)"
        }
        return source.mapping.title
    }

    /// Строка про веб-источник: вид и то, чем он ограничен.
    private var webSummary: String {
        guard let web = source.web else { return "" }
        switch web.kind {
        case .page:
            return String(localized: "одна страница")
        case .list:
            return String(localized: "список адресов: \((web.additionalURLs.count + 1).plainDigits)")
        case .site:
            let robots = web.respectsRobots
                ? String(localized: "robots.txt соблюдается")
                : String(localized: "robots.txt отключён")
            return String(localized: "обход сайта: глубина \(web.maxDepth.plainDigits), не больше \(web.maxPages.plainDigits) страниц, пауза \(SourcesSection.seconds(web.delaySeconds)) с, \(robots)")
        }
    }

    private var triggerText: String {
        guard source.triggers.isAnyEnabled else { return String(localized: "только вручную") }
        if settings.configuration.automaticSyncPaused {
            return String(localized: "\(source.triggers.summary) — приостановлено")
        }
        if let next = autoSync.nextRun[source.id] {
            return String(localized: "\(source.triggers.summary) · следующий \(next.formatted(date: .omitted, time: .shortened))")
        }
        return source.triggers.summary
    }

    private var targetsText: String {
        // Коллекции документов и таблиц вместе: книги учитываются в своём
        // манифесте, и коллекция, куда писали только они, иначе пропадала
        // (ревью).
        let written = Set((model.manifestInfo[source.id]?.collections ?? []) + (model.tableCollections[source.id] ?? []))
        if !written.isEmpty {
            return written.sorted().joined(separator: ", ")
        }
        switch source.mapping {
        case .folderToCollection, .singleCollectionWithRelativePath:
            return String(localized: "коллекция «\(source.collectionName)»")
        case .subfoldersToCollections:
            return String(localized: "коллекции по подпапкам, файлы в корне — в «\(source.collectionName)»")
        case .manualRule:
            return String(localized: "имя коллекции по правилу /\(source.rulePattern)/ → \(source.ruleTemplate)")
        }
    }
}

// MARK: - План синхронизации

/// Предпросмотр синхронизации одного источника: что будет записано, что
/// пропущено, сколько это стоит. Если запуск остановили ворота — здесь же его
/// подтверждают.
private struct SyncPlanSheet: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    let plan: SyncPlan
    @ObservedObject var model: SourcesViewModel
    let close: () -> Void

    private var source: DataSource? {
        settings.configuration.dataSources.first { $0.id == plan.sourceID }
    }

    private var isPending: Bool { model.pendingConfirmations.contains(plan.sourceID) }

    private var includedWriteCount: Int {
        plan.writeItems.filter { !model.isExcluded($0.relativePath, in: plan.sourceID) }.count
    }

    var body: some View {
        SheetFrame(width: .wide, height: .tall) {
            Section {
                Text(plan.summaryLine)
                if !plan.targetCollections.isEmpty {
                    LabeledContent(String(localized: "Коллекции"), value: plan.targetCollections.joined(separator: ", "))
                }
                if let source {
                    let estimate = model.estimate(for: plan, source: source, app: app)
                    LabeledContent(String(localized: "Оценка"), value: estimateLine(chunks: estimate.chunks, time: estimate.time))
                }
            } header: {
                SectionHeader(
                    String(localized: "План синхронизации «\(plan.sourceName)»"),
                    help: String(localized: "Сравнение папки с манифестом. Ничего не записано и не посчитано — это только предпросмотр.")
                )
            } footer: {
                if isPending {
                    // Текст — у самой причины.
                    let reasons = plan.confirmationReasons(
                        threshold: settings.configuration.syncPreviewThresholdFiles
                    )
                    Notice(.warning, (reasons.map(\.sentence)
                                      + [String(localized: "Подтвердите запуск.")]).joined(separator: " "))
                }
            }

            filesSection

            if let estimate = model.tableEstimates[plan.sourceID], estimate.needsConfirmation, let source {
                Section {
                    // the offer to try the first rows stands next to
                    // the button that would spend hours of the model.
                    StepperRow(
                        String(localized: "Строк в пробном прогоне"),
                        value: $model.sampleRowCount, in: 10...5_000, step: 50
                    )
                    HStack {
                        Spacer()
                        Button(String(localized: "Попробовать на выборке")) { model.runSample(source, app: app) }
                            .disabled(model.isBusy(source.id) || !app.connection.isConnected)
                    }
                } header: {
                    Text("Таблицы")
                } footer: {
                    VStack(alignment: .leading) {
                        Notice(.warning, String(localized: "Строк из таблиц: \(estimate.embeddings.plainDigits) — столько же обращений к модели. \(estimate.line)."))
                        Text("Пока идёт этот прогон, модель занята: другие запросы будут ждать. Имеет смысл сначала посмотреть на выборке, что получается из строк.")
                    }
                }
            }
        } actions: {
            Spacer()
            Button(isPending ? String(localized: "Отменить запуск") : String(localized: "Закрыть"), action: close)
                .keyboardShortcut(.cancelAction)
            if let source, plan.hasWork {
                Button(includedWriteCount == plan.writeItems.count
                       ? String(localized: "Подтвердить и синхронизировать")
                       : String(localized: "Синхронизировать выбранное (\(includedWriteCount.plainDigits))")) {
                    model.runPlannedSync(source, app: app)
                }
                .primaryButtonStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(includedWriteCount == 0 || model.isBusy(source.id) || !app.connection.isConnected)
            }
        }
    }

    @ViewBuilder
    private var filesSection: some View {
        // Не взятые — своей секцией: в общем списке они стояли
        // вперемешку с новыми, а список обрезан на сорока, и пропущенный файл
        // из середины папки до экрана не доходил.
        let refused = plan.items.filter { !$0.kind.writesDocuments && $0.kind != .unchanged }
        let interesting = plan.items.filter { $0.kind.writesDocuments }
        if !refused.isEmpty {
            Section {
                ForEach(refused.prefix(40)) { item in itemLabel(item) }
            } header: {
                Text("Не будут взяты: \(refused.count.plainDigits)")
            } footer: {
                if refused.count > 40 {
                    Text("…и ещё \((refused.count - 40).plainDigits) — полный список после запуска на вкладке «Диагностика»")
                }
            }
        }
        IgnoredFilesSection(ignored: plan.ignored)
        Section {
            if interesting.isEmpty {
                Text(refused.isEmpty
                     ? String(localized: "Все файлы уже проиндексированы в текущей конфигурации.")
                     : String(localized: "Записывать нечего: остальные файлы уже проиндексированы."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(interesting.prefix(40)) { item in
                    // Флажок — только у файла, который действительно будет
                    // записан: пропущенные в базу не попадут в любом случае.
                    if item.kind.writesDocuments {
                        Toggle(isOn: Binding(
                            get: { !model.isExcluded(item.relativePath, in: plan.sourceID) },
                            set: { _ in model.toggleExcluded(item.relativePath, in: plan.sourceID) }
                        )) {
                            itemLabel(item)
                        }
                        .toggleStyle(.checkbox)
                    } else {
                        itemLabel(item)
                    }
                }
            }
        } header: {
            Text("Файлы")
        } footer: {
            if interesting.count > 40 {
                Text("…и ещё \((interesting.count - 40).plainDigits)")
            }
        }
    }

    private func itemLabel(_ item: SyncPlanItem) -> some View {
        Label {
            VStack(alignment: .leading) {
                Text(item.relativePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(itemDetail(item))
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon(item.kind))
                .foregroundStyle(.secondary)
        }
        .help(item.relativePath)
    }

    private func itemDetail(_ item: SyncPlanItem) -> String {
        var parts = [item.kind.title]
        if let detail = item.kind.detail { parts.append(detail) }
        if let collection = item.collectionName, item.kind.writesDocuments { parts.append(collection) }
        return parts.joined(separator: " · ")
    }

    private func icon(_ kind: SyncItemKind) -> String {
        switch kind {
        case .new: return "plus.circle"
        case .changed: return "pencil.circle"
        case .unchanged: return "checkmark.circle"
        case .skipped, .unroutable: return "exclamationmark.triangle"
        }
    }

    private func estimateLine(chunks: Int, time: SyncTimeEstimate?) -> String {
        guard chunks > 0 else { return "≈0 чанков" }
        guard let seconds = time?.totalSeconds, seconds > 0 else {
            return "≈\(chunks.plainDigits) чанков · оценка времени пока недоступна (нет прошлых прогонов этой стратегии или модели)"
        }
        return "≈\(chunks.plainDigits) чанков · \(Self.durationText(seconds))"
    }

    /// Carries its own «≈» so the sub-second case can be words instead of a
    /// number: «≈0 с» read as a placeholder rather than as «мгновенно».
    private static func durationText(_ seconds: Double) -> String {
        if seconds < 1 { return String(localized: "меньше секунды") }
        if seconds < 60 { return String(format: "≈%.0f с", seconds) }
        let minutes = seconds / 60
        if minutes < 60 { return String(format: "≈%.0f мин", minutes) }
        return String(localized: "≈\((minutes / 60).decimal(1)) ч")
    }
}

// MARK: - Не взятые по расширению

/// Файлы папки, которых нет в источнике из-за расширения: по строке
/// на расширение — сотня сканов `.jpg` — это одно решение, а не сто.
struct IgnoredFilesSection: View {
    let ignored: IgnoredFiles

    var body: some View {
        if !ignored.isEmpty {
            Section {
                ForEach(ignored.unsupported + ignored.notSelected, id: \.fileExtension) { item in
                    LabeledContent(
                        "\(IgnoredFiles.title(item.fileExtension)) — \(item.count.plainDigits)",
                        value: IgnoredFiles.reason(item.fileExtension)
                    )
                }
            } header: {
                Text("Не взяты по расширению: \(ignored.total.plainDigits)")
            } footer: {
                Text(ignored.notSelected.isEmpty
                     ? String(localized: "Эти форматы приложение не читает. В базу из них ничего не попало.")
                     : String(localized: "Расширения выбираются в настройках источника. Форматы с пометкой «не поддерживается» приложение не читает вовсе."))
            }
        }
    }
}

// MARK: - Итог синхронизации

private struct SyncSummarySheet: View {
    let summary: SyncSummary
    /// Перейти на вкладку «Диагностика» — там все пропущенные, без предела
    /// в десять строк.
    var openDiagnostics: () -> Void = {}
    let close: () -> Void

    var body: some View {
        // Фиксированная высота с прокруткой: подогнанное под содержимое окно
        // вырастало выше экрана, и «Закрыть» уходила за край.
        SheetFrame(width: .wide, height: .tall) {
            Section {
                Text(summary.line)
                LabeledContent(String(localized: "Модель"), value: summary.embeddingModel)
                if let dimension = summary.dimension {
                    LabeledContent(String(localized: "Размерность"), value: String(dimension))
                }
                LabeledContent(String(localized: "Время"), value: SecondsText.line(summary.duration))
                if !summary.collections.isEmpty {
                    LabeledContent(String(localized: "Коллекции"), value: summary.collections.joined(separator: ", "))
                }
            } header: {
                Text("Результат синхронизации «\(summary.sourceName)»")
            } footer: {
                if summary.wroteNothing {
                    Text("Изменений на диске не было — векторы не пересчитывались.")
                }
            }

            if !summary.markedForAttention.isEmpty || summary.tableRowsNeedingDecision > 0 {
                Section {
                    if !summary.markedForAttention.isEmpty {
                        Notice(.warning, String(localized: "Помечено «требуют внимания» (схема не закрыта): \(summary.markedForAttention.count)"))
                    }
                    if summary.tableRowsNeedingDecision > 0 {
                        Notice(.warning, String(localized: "Строк таблиц исчезло из файлов: \(summary.tableRowsNeedingDecision.plainDigits) — ждут решения, из базы ничего не удалено"))
                    }
                }
            }

            if !summary.skipped.isEmpty {
                let byReason = summary.skippedByReason
                Section {
                    // Причина — заголовком строки, файлы — под ней.
                    // В две колонки `LabeledContent` длинная причина
                    // прижималась к правому краю и резалась, а одинаковые
                    // причины занимали все десять мест.
                    ForEach(Array(byReason.prefix(10).enumerated()), id: \.offset) { _, group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.reason)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(Self.files(group.files))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .help(group.files.prefix(50).joined(separator: "\n"))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .copyable(([group.reason] + group.files).joined(separator: "\n"))
                    }
                } header: {
                    Text("Пропущено файлов: \(summary.skipped.count)")
                } footer: {
                    HStack {
                        if byReason.count > 10 {
                            Text("…и ещё причин: \(byReason.count - 10)")
                        }
                        Spacer()
                        // Там — непрочитанные файлы полным списком. Исключённые
                        // руками и строки таблиц с повторным ключом туда
                        // не идут: это не находки, — и «все» кнопка не обещает.
                        Button(String(localized: "Открыть «Диагностику»")) {
                            close()
                            openDiagnostics()
                        }
                        .help(String(localized: "Непрочитанные файлы полным списком — с причиной и тем, что можно сделать с каждым"))
                    }
                }
            }

            IgnoredFilesSection(ignored: summary.ignored)

            // Оговорки табличного конвейера: раньше они считались и терялись
            // по дороге.
            if !summary.tableWarnings.isEmpty {
                Section {
                    ForEach(Array(summary.tableWarnings.prefix(10).enumerated()), id: \.offset) { _, warning in
                        Text(warning)
                    }
                } header: {
                    Text("Таблицы прочитаны с оговорками: \(summary.tableWarnings.count)")
                } footer: {
                    if summary.tableWarnings.count > 10 {
                        Text("…и ещё \(summary.tableWarnings.count - 10)")
                    }
                }
            }
        } actions: {
            Spacer()
            Button(String(localized: "Закрыть"), action: close)
                .keyboardShortcut(.defaultAction)
        }
    }

    /// «а.xlsx → Лист1» или «128 файлов: а.xlsx → Лист1, б.xlsx → Лист2, …».
    private static func files(_ files: [String]) -> String {
        guard files.count > 1 else { return files.first ?? "" }
        let shown = files.prefix(3).joined(separator: ", ")
        let count = RussianCount.phrase(files.count, "файл", "файла", "файлов")
        return files.count > 3 ? "\(count): \(shown), …" : "\(count): \(shown)"
    }
}

// MARK: - Требуют решения

/// Файлы и листы таблиц, исчезнувшие из источников.
///
/// Выбор флажками и одно решение на всё выбранное: исчезнувших файлов бывает
/// шесть десятков, и нажимать по каждой строке — работа, которой не должно
/// быть. Автоматически приложение ничего не удаляет.
private struct PendingDecisionsSheet: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var model: SourcesViewModel
    let close: () -> Void

    /// Ключ — источник и путь: пути в разных источниках совпадают.
    @State private var chosenFiles: Set<String> = []
    @State private var chosenSheets: Set<String> = []
    /// Сколько исчезнувших файлов показывать сразу.
    @State private var limit = 50

    private var sources: [DataSource] { settings.configuration.dataSources }

    var body: some View {
        SheetFrame(width: .wide, height: .tall) {
            Section {
                // Разбор идёт файл за файлом и длится секунды. Без этой строки
                // нажатие выглядело потерянным.
                if let progress = model.resolveProgress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                        Text(progress.text)
                    }
                } else {
                    Text("Документы остаются в базе, пока вы не решите иначе.")
                }
            } header: {
                SectionHeader(
                    String(localized: "Требуют решения"),
                    help: String(localized: "Файлы и строки таблиц исчезли из источника. Автоматически приложение ничего не удаляет: исчезновение бывает и правкой, и сбоем выгрузки или отключённым диском.")
                )
            }

            ForEach(sources) { source in
                if let removals = model.pendingRemovals[source.id], !removals.isEmpty {
                    fileSection(source, removals)
                }
            }
            ForEach(sources) { source in
                if let removals = model.pendingRowRemovals[source.id], !removals.isEmpty {
                    sheetSection(source, removals)
                }
            }
        } actions: {
            Spacer()
            Button(String(localized: "Готово"), action: close)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func key(_ source: DataSource, _ path: String) -> String {
        "\(source.id.uuidString)|\(path)"
    }

    private func fileSection(_ source: DataSource, _ removals: [PendingRemoval]) -> some View {
        let chosen = removals.filter { chosenFiles.contains(key(source, $0.relativePath)) }
        return Section {
            // «Выбрать все» выбирает все, а не только показанные: решение
            // принимается обо всём наборе.
            Toggle(String(localized: "Выбрать все"), isOn: Binding(
                get: { !removals.isEmpty && chosen.count == removals.count },
                set: { isOn in
                    let keys = removals.map { key(source, $0.relativePath) }
                    if isOn { chosenFiles.formUnion(keys) } else { chosenFiles.subtract(keys) }
                }
            ))
            .toggleStyle(.checkbox)
            // Строк столько же, сколько исчезло файлов, а исчезнуть может
            // папка целиком — восемьсот строк раскладываются секундами.
            ForEach(removals.prefix(limit)) { removal in
                Toggle(isOn: Binding(
                    get: { chosenFiles.contains(key(source, removal.relativePath)) },
                    set: { isOn in
                        let item = key(source, removal.relativePath)
                        if isOn { chosenFiles.insert(item) } else { chosenFiles.remove(item) }
                    }
                )) {
                    VStack(alignment: .leading) {
                        Text(removal.relativePath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("коллекция «\(removal.collectionName)» · чанков \(removal.chunkIDs.count) · замечено \(removal.noticedAt.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .help(removal.relativePath)
            }
            if removals.count > limit {
                HStack {
                    Text("показаны первые \(limit.plainDigits) из \(removals.count.plainDigits)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(String(localized: "Показать ещё 50")) { limit += 50 }
                        .buttonStyle(.link)
                }
            }
            HStack {
                Text(chosen.isEmpty
                     ? String(localized: "Ничего не выбрано")
                     : String(localized: "Выбрано \(chosen.count.plainDigits) из \(removals.count.plainDigits)"))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Оставить в базе")) {
                    model.resolve(chosen, decision: .keepInDatabase, source: source, app: app)
                    chosenFiles.subtract(chosen.map { key(source, $0.relativePath) })
                }
                .disabled(chosen.isEmpty || model.resolveProgress != nil)
                Button(String(localized: "Удалить из базы"), role: .destructive) {
                    model.resolve(chosen, decision: .deleteChunks, source: source, app: app)
                    chosenFiles.subtract(chosen.map { key(source, $0.relativePath) })
                }
                // Решение принимается здесь, без вопроса после, — красная.
                .destructiveButtonStyle()
                .disabled(chosen.isEmpty || !app.connection.isConnected || model.resolveProgress != nil)
            }
        } header: {
            Text("\(source.name) · исчезнувшие файлы")
        }
    }

    /// Решение принимается **о листе целиком**: строк там бывают тысячи, а
    /// вопрос к ним один — «это правка файла или сбой выгрузки».
    private func sheetSection(_ source: DataSource, _ removals: [PendingRowRemoval]) -> some View {
        let chosen = removals.filter { chosenSheets.contains(key(source, $0.id)) }
        return Section {
            ForEach(removals) { removal in
                Toggle(isOn: Binding(
                    get: { chosenSheets.contains(key(source, removal.id)) },
                    set: { isOn in
                        let item = key(source, removal.id)
                        if isOn { chosenSheets.insert(item) } else { chosenSheets.remove(item) }
                    }
                )) {
                    VStack(alignment: .leading) {
                        Text("\(removal.relativePath) → \(removal.sheetName)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("коллекция «\(removal.collectionName)» · строк \(removal.rows.count.plainDigits) · замечено \(removal.noticedAt.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(.secondary)
                        // Какие именно строки: без этого «исчезло 40» ничего
                        // не говорит о том, правка это или сбой выгрузки.
                        Text(removal.rowLabels.prefix(6).joined(separator: ", ")
                             + (removal.rows.count > 6 ? String(localized: "…и ещё \(removal.rows.count - 6)") : ""))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            HStack {
                Spacer()
                Button(String(localized: "Оставить в базе")) {
                    model.resolveRows(chosen, decision: .keepInDatabase, source: source, app: app)
                    chosenSheets.subtract(chosen.map { key(source, $0.id) })
                }
                .disabled(chosen.isEmpty || model.resolveProgress != nil)
                Button(String(localized: "Удалить из базы"), role: .destructive) {
                    model.resolveRows(chosen, decision: .deleteChunks, source: source, app: app)
                    chosenSheets.subtract(chosen.map { key(source, $0.id) })
                }
                // Решение принимается здесь, без вопроса после, — красная.
                .destructiveButtonStyle()
                .disabled(chosen.isEmpty || !app.connection.isConnected || model.resolveProgress != nil)
            }
        } header: {
            Text("\(source.name) · строки таблиц")
        }
    }
}

// MARK: - Editor

/// Everything about one source in one sheet: mapping, extensions, chunking
/// parameters and the hookup with the target collection's schema.
///
/// Форма секциями (тип А): что читать, куда класть, как резать, когда
/// обновлять. Числа — строками со стрелками или слайдером, длинные
/// пояснения — в «?» заголовков и подсказках; цена операции остаётся
/// строкой на экране.
struct SourceEditorSheet: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var schemaStore: SchemaStore
    @ObservedObject var model: SourcesViewModel
    @ObservedObject var embeddings: EmbeddingsViewModel

    @State private var coverage: SourceSchemaCoverage?
    /// Что случилось после нажатия в секции схемы. Раньше ответ уходил в
    /// `infoMessage` экрана источников — то есть **за лист**, и кнопка со
    /// стороны выглядела нерабочей.
    @State private var schemaNotice: String?
    /// Ответ кнопок умолчаний нарезки — по той же причине здесь, а не
    /// в `infoMessage`: сообщение экрана источников уходит **за лист**.
    @State private var chunkingNotice: String?
    /// Измеренный предел чтения модели этого источника.
    @State private var inputLimit: Int?
    @State private var isMeasuringLimit = false
    @State private var limitMeasured = false
    /// Проба сорвалась. Отдельно от «предела не нашлось»: это
    /// противоположные ответы, и путать их значит говорить «модель читает
    /// сколько угодно» там, где на самом деле не удалось спросить.
    @State private var limitProbeFailed = false
    @State private var showExtendedGeneration = false

    /// asked once per chat model and remembered, so the indicator can say
    /// which mode a run will actually use before it starts.
    enum StructuredOutputSupport { case unknown, waiting, checking, supported, unsupported }
    @State private var structuredOutputSupport: StructuredOutputSupport = .unknown

    var body: some View {
        SheetFrame(width: .wide, height: .tall) {
            if model.draft != nil {
                identity
                if model.draft?.isWeb == true {
                    webBasics
                } else {
                    if model.draft?.isGit == true { gitBasics }
                    basics
                    reading
                    mapping
                    pathLevels
                }
                chunking
                contextSection
                modelReadingLimit
                chunkingDefaults
                triggers
                metadata
                schemaHookup
            }
        } actions: {
            if let problem = ruleProblem ?? model.pathLevelProblem {
                Notice(.warning, problem)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Spacer()
            }
            Button(String(localized: "Отменить")) { model.cancelDraft() }
                .keyboardShortcut(.cancelAction)
            Button(model.draftIsNew
                   ? String(localized: "Добавить")
                   : String(localized: "Сохранить")) { model.saveDraft(app) }
                .primaryButtonStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(ruleProblem != nil || model.pathLevelProblem != nil)
        }
        // Обход папки — и при смене папки в самом редакторе: уровни и счёт
        // расширений иначе оставались от прежней.
        .task(id: "\(model.draft?.id.uuidString ?? "")|\(model.draft?.path ?? "")") {
            model.scanDraftLevels(app)
        }
        .task(id: model.draft?.id) {
            await refreshCoverage()
            showExtendedGeneration = model.draft?.chunking.generation.usesExtendedBlockValues ?? false
        }
        .task(id: model.draft?.chunking.chatModel) { await refreshStructuredOutputSupport() }
        // Поля из пути — такая же часть договора с коллекцией, как ручные:
        // изменили уровень — секция схемы обязана ответить сразу.
        .task(id: model.draft?.metadataSignature) { await refreshCoverage() }
    }

    /// Probes the chosen chat model once. Only for LLM-based chunking: no other
    /// strategy calls a chat model, so asking would load one for nothing.
    ///
    /// **Через очередь, и последней в ней**. Проба — это запрос к чужой
    /// модели: LM Studio грузит её тут же, а занятую выгружает, и идущая
    /// индексация падает с «Model was unloaded while the request was still in
    /// queue». Настройка источника ничего не индексирует, поэтому и права
    /// прервать индексацию у неё нет: очередь держит группу «локальная модель»
    /// строго последовательной, а `.background` ставит пробу за всем, что уже
    /// начато. Пока она ждёт, форма так и говорит.
    private func refreshStructuredOutputSupport() async {
        guard let draft = model.draft, draft.chunking.strategy == .llmBased,
              let chatModel = draft.chunking.chatModel, !chatModel.isEmpty else {
            structuredOutputSupport = .unknown
            return
        }
        guard let lmStudio = try? app.makeLMStudioClient() else {
            structuredOutputSupport = .unknown
            return
        }
        structuredOutputSupport = await app.queue.isRunning(group: .lmStudio) ? .waiting : .checking
        let ticket = QueueTicket(
            title: String(localized: "Проверка модели «\(chatModel)»"),
            priority: .background,
            group: .lmStudio,
            connectionID: app.connectionID
        )
        // Закрыли лист — задача вида отменяется, и ожидание в очереди вместе
        // с ней: держать очередь ради ответа, который некому показать, незачем.
        let probe: Bool?
        do {
            probe = try await app.queue.run(ticket) { _ in
                await lmStudio.supportsStructuredOutput(model: chatModel)
            }
        } catch {
            probe = nil
        }
        guard let supported = probe else {
            structuredOutputSupport = .unknown
            return
        }
        structuredOutputSupport = supported ? .supported : .unsupported
    }

    /// The draft being edited, as a non-optional binding the fields can use.
    ///
    /// The setter refuses to write when there is no draft any more, and that
    /// guard is the whole point. Saving sets `model.draft` to `nil`, and the
    /// sheet starts to go away — but a field still on screen commits its value
    /// on the way out. Without the guard that write goes through `get`, which
    /// hands back a **brand-new empty** `DataSource`, and stores it: the draft
    /// comes back from the dead, `draft != nil` is true again, and the editor
    /// reopens on an empty form right after a source was added successfully.
    private var draft: Binding<DataSource> {
        Binding(
            get: { model.draft ?? DataSource(name: "", path: "", collectionName: "") },
            set: { updated in
                guard model.draft != nil else { return }
                model.draft = updated
            }
        )
    }

    private var ruleProblem: String? {
        guard let source = model.draft, source.mapping.needsRule else { return nil }
        return CollectionRouter.ruleProblem(pattern: source.rulePattern, template: source.ruleTemplate)
    }

    // MARK: Sections

    /// Имя источника и откуда он читает.
    private var identity: some View {
        Section {
            TextField(String(localized: "Имя источника"), text: draft.name)
            if model.draft?.isWeb != true {
                LabeledContent(String(localized: "Папка")) {
                    HStack {
                        Text(draft.wrappedValue.path)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .copyable(draft.wrappedValue.path)
                        // Папку нового источника можно сменить здесь же: у копии
                        // она взята у оригинала. У заведённого источника
                        // смена папки — переезд, и у неё своя дорога.
                        if model.draftIsNew {
                            Spacer()
                            Button(String(localized: "Другая папка…")) { model.chooseDraftFolder() }
                        }
                    }
                }
            }
            if model.draftDuplicatesOriginal, let original = model.draftCopiedFrom {
                Notice(.warning, String(localized: "Копия читает ту же папку и пишет в те же коллекции, что «\(original.name)»: каждый файл лёг бы в базу дважды. Смените папку или коллекцию."))
            }
        } header: {
            SectionHeader(
                model.draftCopiedFrom.map { String(localized: "Копия источника «\($0.name)»") }
                    ?? (model.draftIsNew
                        ? String(localized: "Новый источник")
                        : String(localized: "Настройка источника")),
                help: String(localized: "Источник — это папка, сайт или репозиторий, за которым приложение следит. Настройки ниже описывают, что из него читать, куда класть, как резать и когда обновлять. Изменение размеров чанков или модели у уже проиндексированного источника означает пересчёт всех его файлов при следующей синхронизации.")
            )
        } footer: {
            Text("Файлы источника разрезаются на чанки и попадают в коллекцию. Ничего не индексируется, пока источник не синхронизирован.")
        }
    }

    /// Настройка git-репозитория. Идёт **над** общими настройками папки:
    /// расширения, OCR и остальное репозиторию нужны ровно так же, разница
    /// только в том, кто составляет список файлов.
    private var gitBasics: some View {
        let git = Binding(
            get: { draft.wrappedValue.git ?? GitSourceSettings() },
            set: { draft.wrappedValue.git = $0 }
        )
        return Section {
            Picker(String(localized: "Индексировать"), selection: git.indexesWorkingCopy) {
                Text("рабочую копию как есть").tag(true)
                Text("только последний коммит").tag(false)
            }
            .pickerStyle(.radioGroup)
            readingOption(
                String(localized: "Записывать автора и дату последнего коммита"),
                note: String(localized: "Добавит last_commit_author и last_commit_date. Это отдельный вызов git на каждый файл."),
                isOn: git.includesCommitInfo
            )
            CommaListField(
                String(localized: "Исключения масками через запятую (*.lock, vendor/*)"),
                items: git.excludedGlobs
            )
        } header: {
            SectionHeader(
                String(localized: "Репозиторий"),
                help: String(localized: "В индекс не попадут ни .git, ни то, что перечислено в .gitignore, а что изменилось с прошлого раза, скажет один вызов вместо десятков тысяч чтений. Маски исключений действуют поверх .gitignore, а не вместо него. Подмодули не обходятся: их файлы принадлежат другому репозиторию.")
            )
        } footer: {
            Text("Список файлов даёт git, а не обход папки. «Как есть» берёт и незакоммиченные правки — обычно этого и хотят. «Только последний коммит» кладёт в базу ровно то, что видят остальные.")
        }
    }

    /// Настройка веб-источника.
    @ViewBuilder
    private var webBasics: some View {
        let web = Binding(
            get: { draft.wrappedValue.web ?? WebSourceSettings() },
            set: { draft.wrappedValue.web = $0 }
        )
        Section {
            Picker(String(localized: "Вид источника"), selection: web.kind) {
                ForEach(WebSourceSettings.Kind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            TextField(String(localized: "Адрес"), text: web.startURL, prompt: Text(verbatim: "https://example.org/страница"))

            if web.wrappedValue.kind == .list {
                LabeledContent(String(localized: "Остальные адреса, по одному в строке")) {
                    TextEditor(text: Binding(
                        get: { web.wrappedValue.additionalURLs.joined(separator: "\n") },
                        set: { web.wrappedValue.additionalURLs = $0.components(separatedBy: .newlines) }
                    ))
                    .font(.body.monospaced())
                    .textArea()
                }
            }

            if web.wrappedValue.kind == .site {
                StepperRow(String(localized: "Глубина"), value: web.maxDepth, in: 0...10)
                StepperRow(String(localized: "Не больше страниц"), value: web.maxPages, in: 1...5000, step: 10)
                DecimalStepperRow(
                    String(localized: "Пауза между запросами, с"),
                    value: web.delaySeconds, in: 0...60, step: 0.5
                )
                StepperRow(String(localized: "Не больше, МБ"), value: web.maxTotalMegabytes, in: 1...5000, step: 50)
                Toggle(String(localized: "Использовать карту сайта (sitemap.xml)"), isOn: web.usesSitemap)
                // Домены теперь и обрезаются: « b.ru» с пробелом
                // не совпадал ни с одним адресом.
                CommaListField(
                    String(localized: "Другие разрешённые домены через запятую"),
                    items: web.extraHosts
                )
            }

            Toggle(String(localized: "Соблюдать robots.txt"), isOn: web.respectsRobots)
        } header: {
            SectionHeader(
                String(localized: "Адрес и обход"),
                help: String(localized: "Ограничения обхода обязательны все четыре: без них источник превращается в неуправляемого краулера. Когда одно из них срабатывает, обход останавливается и говорит об этом в сводке — молча закончиться он не может. Карта сайта полнее обхода по ссылкам: страницу, на которую нет ссылок с главной, по ссылкам не найти; когда карта нашлась, по ссылкам приложение не ходит вовсе. По умолчанию обход не выходит за пределы исходного домена, www. считается тем же сайтом.")
            )
        } footer: {
            VStack(alignment: .leading) {
                if let problem = web.wrappedValue.problem {
                    Notice(.warning, problem)
                }
                // Исключение сильнее правила: обращение наружу от вашего
                // имени остаётся на экране целиком, а не под «?».
                if !web.wrappedValue.respectsRobots {
                    Notice(.warning, String(localized: "robots.txt — это то, о чём сайт просит прямо. Отключайте только для собственных доменов: на чужом сервере это чужие правила, и нарушать их приложение будет вашим именем. Отключение записывается в журнал при каждом запуске."))
                }
                Text(web.wrappedValue.kind.explanation)
            }
        }

        Section {
            TextField(String(localized: "Коллекция"), text: draft.collectionName)
            embeddingModelPicker
            readingOption(
                String(localized: "Извлекать метаданные документа"),
                note: String(localized: "Заголовок и язык страницы — в метаданные каждого чанка."),
                isOn: draft.includeDocumentMetadata
            )
        } header: {
            SectionHeader(
                String(localized: "Куда попадают страницы"),
                help: String(localized: "Адрес, время загрузки, код ответа и content_type пишутся в каждый чанк всегда — без них нельзя понять, откуда он взялся. Смена модели у уже проиндексированного источника пересчитает все его страницы.")
            )
        } footer: {
            Text("Все страницы источника идут в одну коллекцию: у страницы нет папки, по которой её можно было бы разложить.")
        }
    }

    private var embeddingModelPicker: some View {
        Picker(String(localized: "Модель эмбеддинга"), selection: Binding(
            get: { draft.wrappedValue.embeddingModel ?? "" },
            set: { draft.wrappedValue.embeddingModel = $0.isEmpty ? nil : $0 }
        )) {
            Text("по умолчанию (\(settings.configuration.defaultEmbeddingModel ?? "не выбрана"))").tag("")
            ForEach(embeddings.embeddingModels) { item in
                Text(item.id).tag(item.id)
            }
        }
    }

    /// Какие файлы из папки читать: группами, у каждого расширения —
    /// сколько таких файлов в папке. Перечень того, как читается каждый
    /// формат, — под «?».
    private var basics: some View {
        let counts = model.draftExtensionCounts
        let chosen = Set(draft.wrappedValue.fileExtensions)
        return Section {
            ForEach(ExtensionGroup.allCases) { group in
                extensionGroup(group, chosen: chosen, counts: counts)
            }
            // Свои расширения — те, которых нет в группах: файл `.log`,
            // прочитанный как текст, или `.markdown` под другим именем.
            CommaListField(
                String(localized: "Свои расширения через запятую"),
                items: draft.wrappedValue.fileExtensions.filter { ExtensionGroup.of($0) == nil },
                clean: { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .")) },
                commit: { custom in
                    let grouped = draft.wrappedValue.fileExtensions.filter { ExtensionGroup.of($0) != nil }
                    draft.wrappedValue.fileExtensions = grouped + custom.filter { !grouped.contains($0) }
                }
            )
            .id(draft.wrappedValue.fileExtensions.filter { ExtensionGroup.of($0) == nil })
            HStack {
                if let counts {
                    let unread = counts.filter { IgnoredFiles.isUnsupported($0.key) && !chosen.contains($0.key) }
                    if !unread.isEmpty {
                        Text("Не читается: \(unread.sorted { $0.value > $1.value }.prefix(6).map { "\(IgnoredFiles.title($0.key)) \($0.value.plainDigits)" }.joined(separator: ", "))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                } else if model.draftLevelsScanning {
                    Text("Считаются файлы папки…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                // Сузить список — одно движение, а собрать его обратно по
                // памяти нельзя: пусть возврат к полному стоит одно нажатие.
                if let counts {
                    let present = TextExtractor.supportedExtensions.filter { (counts[$0] ?? 0) > 0 }
                    Button(String(localized: "Только найденные в папке")) {
                        draft.wrappedValue.fileExtensions = present
                    }
                    .disabled(present.isEmpty || Set(present) == chosen)
                    .help(String(localized: "Отметить поддерживаемые расширения, файлы которых в папке есть, и снять остальные"))
                }
                Button(String(localized: "Все поддерживаемые")) {
                    draft.wrappedValue.fileExtensions = TextExtractor.supportedExtensions
                }
                .disabled(chosen == Set(TextExtractor.supportedExtensions))
            }
            Toggle(String(localized: "Рекурсивно"), isOn: draft.recursive)
            StepperRow(
                String(localized: "Не читать файлы больше, МБ"),
                value: draft.maxFileSizeMB, in: 1...500, step: 5
            )
        } header: {
            SectionHeader(
                String(localized: "Папка и файлы"),
                help: String(localized: "Читаются напрямую: текст, Markdown, код, JSON и XML. HTML — своим разбором: скрипты, стили и меню выбрасываются, заголовки h1–h6 становятся структурой. PDF — через PDFKit; скан без текстового слоя — распознаванием, если оно включено у источника. Word (.docx и двоичный .doc) — своим разбором: заголовки, нумерация пунктов, таблицы, сноски и замечания рецензентов; то, что извлечь не удалось, названо пометкой у файла в «Диагностике». RTF и OpenDocument — средствами системы, таблицы приводятся к тексту. EPUB — по оглавлению книги; книга с DRM попадает в «требуют решения». Презентации .pptx — слайд за слайдом, с заметками докладчика; .key и .pages — через сами программы. Таблицы (.xlsx, .xlsm, .xls, .ods, .numbers, .csv, .tsv) идут своим путём: строка становится отдельным документом по профилю сопоставления (кнопка «Таблицы»), а лист без подходящего профиля — текстом. Не читаются: двоичные .xlsb и .ppt, .mobi.")
            )
        } footer: {
            Text("Пропущенные по размеру видны в списке «Пропущено файлов» после прогона.")
        }
    }

    /// Выбранные расширения в порядке списка поддерживаемых, свои — следом:
    /// порядок не зависит от того, в какой последовательности щёлкали флажки,
    /// а первое расширение (по нему стенд выбирает вид предпросмотра) —
    /// всегда одно и то же.
    private static func ordered(_ chosen: Set<String>) -> [String] {
        let known = TextExtractor.supportedExtensions.filter(chosen.contains)
        return known + chosen.subtracting(known).sorted()
    }

    /// Группа расширений: флажок на всю группу и по флажку на расширение,
    /// с числом таких файлов в папке.
    @ViewBuilder
    private func extensionGroup(_ group: ExtensionGroup, chosen: Set<String>, counts: [String: Int]?) -> some View {
        let members = group.extensions
        let picked = members.filter(chosen.contains)
        let inFolder = counts.map { counts in members.reduce(0) { $0 + (counts[$1] ?? 0) } }
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { picked.count == members.count },
                set: { on in
                    draft.wrappedValue.fileExtensions = Self.ordered(
                        Set(draft.wrappedValue.fileExtensions).subtracting(members).union(on ? members : [])
                    )
                }
            )) {
                HStack(spacing: 4) {
                    Text(group.title)
                    if let inFolder {
                        Text("· \(RussianCount.phrase(inFolder, "файл", "файла", "файлов"))")
                            .foregroundStyle(.secondary)
                    }
                    if !picked.isEmpty, picked.count < members.count {
                        Text("· отмечено \(picked.count.plainDigits) из \(members.count.plainDigits)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(members, id: \.self) { fileExtension in
                    Toggle(isOn: Binding(
                        get: { chosen.contains(fileExtension) },
                        set: { on in
                            var chosen = Set(draft.wrappedValue.fileExtensions)
                            if on { chosen.insert(fileExtension) } else { chosen.remove(fileExtension) }
                            draft.wrappedValue.fileExtensions = Self.ordered(chosen)
                        }
                    )) {
                        HStack(spacing: 3) {
                            Text(verbatim: ".\(fileExtension)")
                            if let count = counts?[fileExtension], count > 0 {
                                Text(count.plainDigits).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                }
            }
            .padding(.leading, 20)
        }
    }

    /// Как читать то, что не текст: сканы, Pages и Numbers, свойства документа.
    private var reading: some View {
        Section {
            readingOption(
                String(localized: "Распознавать сканированные документы (OCR)"),
                note: String(localized: "Для PDF без текстового слоя. На порядок медленнее: папка из тысячи файлов — часы."),
                isOn: draft.ocrEnabled
            )
            if draft.wrappedValue.ocrEnabled { ocrLanguages }

            readingOption(
                String(localized: "Читать Pages и Keynote через экспорт"),
                note: String(localized: "Поднимает окно программы, и macOS один раз спросит разрешение на автоматизацию."),
                isOn: draft.iWorkExportEnabled
            )
            if draft.wrappedValue.iWorkExportEnabled {
                readingOption(
                    String(localized: "Разрешить и при автоматической синхронизации"),
                    note: String(localized: "Иначе индексация по расписанию начнёт открывать окна Pages, пока вы работаете."),
                    isOn: draft.iWorkExportInAutomaticRuns
                )
            }

            // Флаг существовал в модели с, но переключателя у него не
            // было — то есть путь через Numbers был выключен навсегда, и
            // .numbers молча падали в «требуют решения» с причиной «экспорт
            // выключен в настройках источника», которую негде было включить.
            readingOption(
                String(localized: "Читать .numbers и .xls через Numbers"),
                note: String(localized: "Те же условия, что у Pages, и при автоматической синхронизации не работает никогда."),
                isOn: draft.numbersExportEnabled
            )

            // лист, под который не подошёл ни один профиль, раньше
            // пропадал из базы целиком — теперь по умолчанию пишется текстом.
            readingOption(
                String(localized: "Листы без подходящего профиля — записывать текстом"),
                note: String(localized: "Лист таблицы, под который не подошёл ни один профиль, попадает в базу как документ: текст ищется, фильтров по колонкам нет. Выключено — такой лист ждёт решения в «Диагностике»."),
                isOn: draft.unmatchedSheetsAsText
            )

            readingOption(
                String(localized: "Извлекать метаданные документа"),
                note: String(localized: "document_title, document_author, document_language и document_created — в каждый чанк."),
                isOn: draft.includeDocumentMetadata
            )
        } header: {
            Text("Чтение")
        } footer: {
            // Предупреждение показывается только тем, кого оно касается:
            // структуру используют две стратегии из шести.
            if draft.wrappedValue.ocrEnabled,
               [.documentBased, .hierarchical].contains(draft.wrappedValue.chunking.strategy) {
                Notice(.warning, String(localized: "У распознанных страниц нет структуры, поэтому «\(draft.wrappedValue.chunking.strategy.title)» к ним не применится — они будут нарезаны Recursive. Остальные стратегии структуру не используют и работают как выбраны."))
            }
        }
    }

    /// Languages this machine can recognise — asked of Vision, never hardcoded:
    /// the list differs between macOS versions.
    @ViewBuilder
    private var ocrLanguages: some View {
        let supported = VisionOCRExtractor.supportedLanguages()
        if supported.isEmpty {
            Notice(.warning, String(localized: "Система не сообщила ни одного языка распознавания — распознавание работать не будет."))
        } else {
            OCRLanguagesRow(languages: draft.ocrLanguages, supported: supported)
        }
    }

    /// Переключатель чтения и одна строка о следствии — подписью под ним.
    private func readingOption(_ title: String, note: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
            Text(note)
        }
    }

    private var mapping: some View {
        Section {
            Picker(String(localized: "Режим маппинга"), selection: draft.mapping) {
                ForEach(SourceMapping.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)

            TextField(
                draft.wrappedValue.mapping == .subfoldersToCollections
                    ? String(localized: "Коллекция для файлов в корне")
                    : String(localized: "Коллекция"),
                text: draft.collectionName,
                prompt: Text("имя коллекции")
            )
            Picker(String(localized: "Метрика новых коллекций"), selection: draft.metric) {
                ForEach(DistanceMetric.allCases) { metric in
                    Text(metric.title).tag(metric)
                }
            }
            embeddingModelPicker

            if draft.wrappedValue.mapping.needsRule {
                TextField(String(localized: "Регулярное выражение по относительному пути"), text: draft.rulePattern)
                    .font(.body.monospaced())
                TextField(String(localized: "Шаблон имени коллекции ($1, $2…)"), text: draft.ruleTemplate)
                    .font(.body.monospaced())
                Toggle(String(localized: "Файлы, не подошедшие под правило, — в коллекцию по умолчанию"), isOn: draft.ruleUsesFallbackCollection)
            }
        } header: {
            SectionHeader(
                String(localized: "Куда попадают файлы"),
                help: String(localized: "Одна папка может наполнять одну коллекцию, по коллекции на подпапку или коллекции по правилу из пути. Метрика действует только на коллекции, которых ещё нет: у существующей её изменить нельзя. Смена модели эмбеддинга у уже проиндексированного источника пересчитает все его файлы — векторы разных моделей несравнимы.")
            )
        } footer: {
            VStack(alignment: .leading) {
                if let problem = CollectionNaming.firstProblem(with: draft.wrappedValue.collectionName) {
                    Notice(.warning, String(localized: "\(problem) Имя будет приведено к «\(CollectionNaming.sanitize(draft.wrappedValue.collectionName))»."))
                }
                Text(draft.wrappedValue.mapping.summary)
                if draft.wrappedValue.mapping.needsRule {
                    Text("Например: выражение `^([^/]+)/` и шаблон `$1` дадут имя коллекции по первой папке пути.")
                }
            }
        }
    }

    /// Уровни вложенности как поля метаданных.
    ///
    /// Отдельной секцией, а не пятым режимом маппинга: режим отвечает на вопрос
    /// «в какую коллекцию», уровни — «что известно о файле из его места
    /// в дереве». Пустая секция ничего не меняет, и источник ведёт себя ровно
    /// как прежде.
    private var pathLevels: some View {
        Section {
            if model.draftLevelsScanning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Считаем уровни папки…").foregroundStyle(.secondary)
                }
            } else if let problem = model.draftLevelsProblem {
                Notice(.warning, String(localized: "Папку прочитать не удалось: \(problem)"))
            } else if let levels = model.draftFolderLevels, levels.isEmpty,
                      draft.wrappedValue.pathLevels.isEmpty {
                Text("Внутри папки нет подпапок с подходящими файлами — полям из пути неоткуда взяться.")
                    .foregroundStyle(.secondary)
            }

            // Строка находит свой уровень по идентификатору, а не по номеру
            //: привязка «элемент № i» переживала сам черновик —
            // закрытое окно опустошало список, а поле в фокусе ещё
            // дописывало текст в элемент, которого нет, и приложение падало.
            ForEach(Array(draft.wrappedValue.pathLevels.enumerated()), id: \.element.id) { index, level in
                pathLevelRow(index: index, level: levelBinding(level))
            }

            if !draft.wrappedValue.pathLevels.filter(\.isNamed).isEmpty {
                pathLevelPreview
            }
        } header: {
            SectionHeader(
                String(localized: "Поля из пути"),
                help: String(localized: "Уровень — это папка на своей глубине: первый уровень внутри папки источника, второй внутри него и так далее. Имя поля пишется латиницей: по нему фильтруют запросы и ходят внешние клиенты. Значение берётся с папки как есть — хоть кириллицей, хоть с пробелами. Уровень без имени не пишется никуда. Изменение полей не пересчитывает векторы: их можно обновить отдельной операцией.")
            )
        } footer: {
            VStack(alignment: .leading) {
                Text("Названия папок становятся полями каждого чанка — по ним потом фильтруют выдачу.")
                if let levels = model.draftFolderLevels, levels.deeperThanLimit {
                    Text("В папке есть пути глубже \(PathLevel.maximumLevels.plainDigits) уровней — их названия полями не станут.")
                }
            }
        }
    }

    /// Привязка к уровню по идентификатору. Уровня уже нет —
    /// читается последнее известное значение, а запись не делает ничего.
    private func levelBinding(_ level: PathLevel) -> Binding<PathLevel> {
        Binding(
            get: { model.draft?.pathLevels.first { $0.id == level.id } ?? level },
            set: { updated in
                guard let index = model.draft?.pathLevels.firstIndex(where: { $0.id == level.id }) else { return }
                model.draft?.pathLevels[index] = updated
            }
        )
    }

    /// Ширины колонок строки уровня — одни на все уровни.
    private static let levelKeyWidth: CGFloat = 210
    private static let levelTypeWidth: CGFloat = 110
    private static let levelFallbackWidth: CGFloat = 170

    /// Одна строка уровня: что в нём лежит, как назвать и что писать файлам,
    /// которые до него не достают.
    @ViewBuilder
    private func pathLevelRow(index: Int, level: Binding<PathLevel>) -> some View {
        let known = model.draftFolderLevels?.levels.first { $0.number == index + 1 }
        VStack(alignment: .leading) {
            LabeledContent(String(localized: "Уровень \((index + 1).plainDigits)")) {
                HStack {
                    // Постоянной ширины и с текстом слева: поле
                    // ужималось по длине введённого имени — «OGV» короче
                    // подсказки, — и строка уровня съезжала относительно
                    // соседних.
                    TextField(String(localized: "Имя поля"), text: level.key, prompt: Text("имя поля (латиницей)"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .multilineTextAlignment(.leading)
                        .frame(width: Self.levelKeyWidth)
                    Picker(String(localized: "Тип"), selection: level.type) {
                        ForEach(MetadataFieldType.allCases) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    .labelsHidden()
                    .frame(width: Self.levelTypeWidth)
                    TextField(String(localized: "Если папки нет"), text: level.fallbackValue, prompt: Text("если папки нет"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(width: Self.levelFallbackWidth)
                }
            }
            if let known {
                Text("\(known.folderCount.plainDigits) папок: \(known.examples.joined(separator: ", "))\(known.folderCount > known.examples.count ? "…" : "")")
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            if let problem = PathLevel.keyProblem(level.wrappedValue.key) {
                Notice(.warning, problem)
            } else if level.wrappedValue.isNamed, let known {
                // Две вещи, о которых честнее сказать до прогона: сколько файлов
                // останутся без поля и сколько папок не приводятся к типу.
                if known.filesAbove > 0 {
                    Text("\(known.filesAbove.plainDigits) файлов лежат выше этого уровня\(level.wrappedValue.fallbackValue.isEmpty ? " — у них поля не будет" : " — им запишется «\(level.wrappedValue.fallbackValue)»").")
                        .foregroundStyle(.secondary)
                }
                let mismatched = known.namesNotMatching(level.wrappedValue)
                if !mismatched.isEmpty {
                    Notice(.warning, String(localized: "Не разбираются как \(level.wrappedValue.type.title): \(mismatched.prefix(3).joined(separator: ", "))\(mismatched.count > 3 ? "…" : "") — \(mismatched.count.plainDigits) из \(known.names.count.plainDigits). Таким файлам поле не запишется."))
                }
            }
        }
    }

    /// Предпросмотр на настоящих путях: показать результат на выдуманном
    /// `folder/file.txt` значит показать не то.
    @ViewBuilder
    private var pathLevelPreview: some View {
        let source = draft.wrappedValue
        let samples = model.draftFolderLevels?.samplePaths ?? []
        if !samples.isEmpty {
            VStack(alignment: .leading) {
                Text("Так это запишется:")
                ForEach(samples, id: \.self) { path in
                    let fields = CollectionRouter.levelFields(for: path, levels: source.pathLevels)
                    Text("\(path) → \(fields.isEmpty ? String(localized: "полей нет") : fields.keys.sorted().map { "\($0)=\(fields[$0]?.displayString ?? "")" }.joined(separator: ", "))")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var chunking: some View {
        Section {
            Picker(String(localized: "Стратегия"), selection: draft.chunking.strategy) {
                ForEach(ChunkStrategy.allCases) { strategy in
                    Text(strategy.title).tag(strategy)
                }
            }

            // Only the parameters of the chosen strategy are shown.
            ChunkingParametersRows(
                chunking: draft.chunking,
                separatorsText: $model.draftSeparators,
                fileExtension: draft.wrappedValue.fileExtensions.first,
                embeddingModels: embeddings.embeddingModels.map(\.id),
                embeddingModelDefaultTitle: String(localized: "та же, что у источника"),
                chatModels: chatModelOptions
            ) {
                structuredOutputRow
                extendedGenerationBlock
            }
        } header: {
            SectionHeader(
                String(localized: "Как резать на чанки"),
                help: String(localized: "Стратегия определяет, где проходят границы чанков: по размеру, по структуре документа, по смыслу или моделью. Рекомендация под выбором — о том, для каких документов эта стратегия задумана. Токены считаются приблизительно: LM Studio не отдаёт токенайзер модели через API.")
            )
        } footer: {
            VStack(alignment: .leading) {
                if let problem = draft.wrappedValue.chunking.problem {
                    Notice(.warning, problem)
                }
                if let warning = draft.wrappedValue.chunking.strategy.costWarning {
                    // Said before the run, not after it.
                    Notice(.warning, warning)
                }
                Text(draft.wrappedValue.chunking.strategy.summary)
                Text(draft.wrappedValue.chunking.strategy.recommendation)
                // Исключение сильнее правила: пересчёт векторов не прячется
                // под «?» — он остаётся строкой на экране.
                Text("Изменение параметров — это новая нарезка: при следующей синхронизации все файлы источника будут перечанкованы и переэмбежены.")
            }
        }
        // Умолчания подставляются при переключении стратегии — и только
        // у нового источника. У заведённого числа его собственные.
        .onChange(of: draft.wrappedValue.chunking.strategy) { _, strategy in
            model.chunkingStrategyChanged(to: strategy, app: app)
        }
    }

    /// Контекст в вектор и обогащение чат-моделью.
    ///
    /// Отдельной секцией, а не в параметрах стратегии: работает при любой из
    /// них и меняет содержимое коллекции, то есть требует переиндексации.
    private var contextSection: some View {
        Section {
            Toggle(isOn: draft.chunking.contextPrefix) {
                Text("Дописывать контекст перед вычислением вектора")
                Text("В модель уходит «Документ → Раздел → Подраздел» перед текстом чанка; в самом документе этой строки нет.")
            }
            .help(String(localized: "Чанк «превышение допустимого значения приводит к отказу» без этой строки не находится ничем: в нём нет ни одного слова о том, о чём он. Сюда же попадает вводная фраза списка — та, что кончается двоеточием: пункт «восстановление работоспособности в течение четырёх часов» без неё не говорит, чего восстановление и кто обязан."))

            enrichmentRow
        } header: {
            Text("Контекст в вектор")
        } footer: {
            if draft.wrappedValue.chunking.contextPrefix {
                Notice(.warning, String(localized: "Это меняет содержимое коллекции: при следующей синхронизации все файлы источника будут переэмбежены."))
            }
        }
    }

    /// Контекстное обогащение чат-моделью.
    ///
    /// Правило приложения 5 в самой прямой форме: операция, которая займёт
    /// часы, обязана назвать свою цену **до** запуска. Поэтому под
    /// переключателем стоит не описание пользы, а число вызовов и время —
    /// и время не выдумывается: без замера скорости модели его нет вовсе.
    @ViewBuilder
    private var enrichmentRow: some View {
        let chunking = draft.wrappedValue.chunking
        Toggle(isOn: draft.chunking.contextEnrichment) {
            Text("Обогащать контекст чат-моделью")
            Text("Модель пишет одно-два предложения о том, о чём документ и где в нём фрагмент; они уходят в вектор.")
        }
        .help(String(localized: "В документе этих предложений нет. Заметно помогает там, где заголовков нет и структурная строка молчит."))

        if chunking.contextEnrichment {
            Picker(String(localized: "Модель обогащения"), selection: Binding(
                get: { chunking.resolvedEnrichmentModel ?? "" },
                set: { draft.wrappedValue.chunking.enrichmentModel = $0.isEmpty ? nil : $0 }
            )) {
                Text("не выбрана").tag("")
                ForEach(chatModelOptions, id: \.self) { id in
                    Text(id).tag(id)
                }
            }
            Notice(.warning, enrichmentCostLine)
            if (chunking.resolvedEnrichmentModel ?? "").isEmpty {
                Notice(.warning, String(localized: "Без выбранной модели обогащение не выполняется: фрагменты уйдут в эмбеддинг как есть."))
            }
        }
    }

    /// Цена обогащения словами: вызовов столько же, сколько чанков.
    ///
    /// Число чанков берётся из манифеста источника — это то, что он написал
    /// в прошлый раз. Пока источник не синхронизирован, называть количество
    /// нечем, и вместо выдуманного числа говорится правило. Время — только по
    /// измеренной скорости этой модели; не измерена — не называется (правило 4
    /// приложения 5).
    private var enrichmentCostLine: String {
        let chunking = draft.wrappedValue.chunking
        let chatModel = chunking.resolvedEnrichmentModel ?? ""
        // Строки таблиц живут в своём манифесте и в `chunks` не входят:
        // у источника таблиц счёт вызовов был бы иначе нулевым.
        let sourceID = draft.wrappedValue.id
        let counted = (model.manifestInfo[sourceID]?.chunks ?? 0) + (model.tableRows[sourceID] ?? 0)
        guard counted > 0 else {
            return String(localized: "Один вызов чат-модели на каждый чанк. Сколько их будет, станет известно после первой синхронизации источника.")
        }
        // Секунды на вызов — по фактической скорости **чат-модели**, тем же
        // счётчиком, что и у стенда оценки. Замер F3 сюда не годится:
        // он мерит пропускную способность эмбеддинга — сотни текстов
        // в секунду, — а генерация идёт секундами на вызов, и разница тут
        // в три порядка. Не измерено — не называется (правило 4 приложения 5).
        let estimate = ContextEnricher.estimate(
            chunks: counted,
            secondsPerCall: model.lastPlanMetrics.judgeSecondsPerCall(model: chatModel),
            basis: .measuredWork
        )
        // Не `estimate.line`: та строка написана про строки таблиц и здесь
        // читалась бы про чужое. Берём из неё только время.
        if let duration = estimate.durationText {
            return String(localized: "Один вызов чат-модели на чанк: \(counted.plainDigits) вызовов, \(duration) работы модели.")
        }
        return String(localized: "Один вызов чат-модели на чанк: \(counted.plainDigits) вызовов. Сколько это займёт — неизвестно: скорость этой модели ещё не измерялась.")
    }

    /// Сколько модель читает за раз — и влезает ли в это нарезка.
    ///
    /// Спрашивается здесь, потому что здесь и задаётся размер: узнать, что
    /// чанк длиннее читаемого, посреди прогона — узнать слишком поздно.
    /// Число не спрашивается у модели, а **измеряется**: то, что она о себе
    /// сообщает, с её поведением не совпадает. Проба стоит семи-восьми
    /// вызовов, поэтому она по кнопке, а не сама собой, и однажды измеренное
    /// помнится между запусками.
    private var modelReadingLimit: some View {
        let chunking = draft.wrappedValue.chunking
        let largest = chunking.largestChunkCharacters
        let model = draft.wrappedValue.embeddingModel
            ?? settings.configuration.defaultEmbeddingModel

        return Section {
            LabeledContent(String(localized: "Сколько модель читает")) {
                if let inputLimit {
                    Text("≈ \(inputLimit.plainDigits) знаков за раз")
                } else if limitProbeFailed {
                    StatusLabel(.error, String(localized: "измерить не вышло — модель не ответила"))
                } else if limitMeasured {
                    Text("больше \(EmbeddingInputProbe.maximumProbeCharacters.plainDigits) знаков — предела не нашлось")
                } else {
                    Text("не измерялось")
                }
                if isMeasuringLimit {
                    ProgressView().controlSize(.small)
                } else if let model, !model.isEmpty {
                    Button(limitMeasured ? String(localized: "Измерить заново") : String(localized: "Измерить")) {
                        Task { await measureLimit(model: model) }
                    }
                }
            }
        } header: {
            Text("Предел чтения модели")
        } footer: {
            if let largest, let inputLimit, largest > inputLimit {
                Notice(.warning, String(localized: "При этих настройках чанк дорастает до \(largest.plainDigits) знаков — больше, чем модель читает. Такой файл уйдёт в пропущенные, а не в базу: вектор описывал бы только начало чанка."))
            } else if largest == nil {
                Notice(.warning, String(localized: "Размер чанка при этих настройках ничем не ограничен: у document-based это «не делить», у LLM-based — то, что вернёт чат-модель. Приложение проверит каждый чанк на прогоне и пропустит файл, если он не влезет."))
            } else {
                Text("Модель молча обрезает то, что не влезло, — вектор считается по началу чанка, и ни в ответе, ни в выдаче это не видно. Поэтому предел измеряется пробой, а не берётся из того, что модель о себе сообщает.")
            }
        }
        .task(id: draft.wrappedValue.embeddingModel ?? "") {
            // Сначала забыть прежнее: число принадлежит модели, и оставить
            // его на экране после смены модели значит показать чужое.
            inputLimit = nil
            limitMeasured = false
            limitProbeFailed = false
            // Уже измеренное показывается сразу; мерить само собой — нет.
            guard let model, !model.isEmpty else { return }
            // Свежесть проверяется тем же признаком, что и в ядре:
            // иначе форма одобряла бы настройки числом, которое синхронизация
            // считает устаревшим и меряет заново.
            let loaded = await (try? app.makeLMStudioClient())?
                .reportedLoadedContextLength(of: model) ?? nil
            if let known = await app.embeddingLimits.limit(for: model),
               known.isFresh(loadedContext: loaded) {
                inputLimit = known.characters
                limitMeasured = true
            }
        }
    }

    private func measureLimit(model: String) async {
        isMeasuringLimit = true
        defer { isMeasuringLimit = false }
        guard let lmStudio = try? app.makeLMStudioClient() else {
            chunkingNotice = String(localized: "LM Studio недоступна — измерить предел нечем.")
            return
        }
        // Прежнее не стирается до успеха: сорвавшаяся проба не должна
        // отнимать то, что уже было измерено. Удачная — перезапишет
        // сама, `remember` заменяет запись по имени модели.
        // Через очередь: проба — это семь-восемь вызовов модели, то есть
        // длительная операция, и отнимать модель у идущей синхронизации
        // она не должна. Приоритет человека у экрана: он ждёт ответа
        // здесь и сейчас.
        // `do/catch`, а не `try?`: тот схлопывает вложенный `Optional`,
        // и «очередь сорвалась» стало бы неотличимо от «предела не нашлось»
        // — а это противоположные ответы.
        let probe: EmbeddingInputProbe.Outcome
        do {
            probe = try await app.queue.run(QueueTicket(
                title: String(localized: "Замер предела чтения модели «\(model)»"),
                priority: .interactive,
                group: .lmStudio,
                connectionID: app.connectionID
            )) { _ in
                // Мимо кэша векторов: тексты пробы больше не понадобятся
                // никогда, а вытеснят они настоящие чанки.
                // Исход, а не число: «модель не ответила» внутри пробы и
                // «предела не нашлось» иначе приходили одним `nil`, и форма
                // объявляла предел отсутствующим ровно тогда, когда его
                // не измеряли вовсе.
                await EmbeddingInputProbe.measureOutcome { text in
                    try await lmStudio.embedIgnoringCache(texts: [text], model: model).first ?? []
                }
            }
        } catch {
            probe = .failed
        }
        guard probe != .failed else {
            guard (draft.wrappedValue.embeddingModel ?? "") == model else { return }
            limitProbeFailed = true
            chunkingNotice = String(localized: "Замер не удался: модель не ответила. Прежнее измеренное значение сохранено.")
            return
        }
        let outcome: Int? = { if case .measured(let value) = probe { return value }; return nil }()
        // Пока шёл замер, модель в форме могли сменить: число прежней модели
        // на экране новой — чужой предел и неверное предупреждение о размере
        // чанка. Запоминается оно всё равно — за той моделью, что мерили.
        if (draft.wrappedValue.embeddingModel ?? "") == model {
            limitProbeFailed = false
            limitMeasured = true
            inputLimit = outcome
        }
        if let measured = outcome {
            // Контекст загрузки пишется вместе с числом: без него
            // ядро сверяет `nil` с настоящим контекстом, признаёт запись
            // устаревшей и гоняет пробу заново — то есть ручной замер
            // не экономил ни одного вызова модели.
            await app.embeddingLimits.remember(
                MeasuredInputLimit(
                    model: model,
                    characters: measured,
                    loadedContext: await lmStudio.reportedLoadedContextLength(of: model)
                )
            )
            app.log.record(
                .info, "Модели",
                "Модель «\(model)» читает за раз не больше \(measured.plainDigits) знаков — измерено пробой"
            )
        }
    }

    /// Умолчания нарезки.
    ///
    /// Здесь, а не на отдельном экране настроек: параметры стратегии
    /// настраивают в этом самом окне, теми же полями, и «пусть теперь так
    /// будет у всех» — это продолжение того же движения, а не отдельная
    /// работа в другом месте. Умолчание у каждой стратегии своё: переключение
    /// стратегии не должно возвращать заводские 512 токенов человеку, который
    /// уже настроил её под свои документы.
    private var chunkingDefaults: some View {
        let strategy = draft.wrappedValue.chunking.strategy
        let isOwn = settings.configuration.hasOwnChunkingDefault(for: strategy)
        let isForNewSources = (settings.configuration.defaultChunkingStrategy ?? ChunkingConfiguration().strategy) == strategy

        return Section {
            HStack {
                Button(String(localized: "Сделать умолчанием")) {
                    chunkingNotice = model.makeChunkingDefault(app)
                }
                .help(String(localized: "Запомнить эти значения для стратегии «\(strategy.title)» и заводить новые источники с ней"))
                Button(String(localized: "Взять умолчание")) {
                    chunkingNotice = model.takeChunkingDefault(app)
                }
                .help(String(localized: "Подставить сюда умолчания стратегии «\(strategy.title)»"))
                Spacer()
                if isOwn {
                    Button(String(localized: "Забыть умолчание")) {
                        chunkingNotice = model.forgetChunkingDefault(app)
                    }
                    .help(String(localized: "Вернуть заводские значения стратегии «\(strategy.title)». Настройки этого источника не изменятся"))
                }
            }
        } header: {
            Text("Умолчания нарезки")
        } footer: {
            VStack(alignment: .leading) {
                if let chunkingNotice {
                    Notice(.info, chunkingNotice)
                }
                Text(
                    isOwn
                        ? (isForNewSources
                           ? String(localized: "У стратегии «\(strategy.title)» ваши умолчания, и новые источники заводятся с ней.")
                           : String(localized: "У стратегии «\(strategy.title)» ваши умолчания. Новые источники заводятся с другой стратегией."))
                        : String(localized: "У стратегии «\(strategy.title)» пока заводские умолчания.")
                )
            }
        }
    }

    // MARK: Параметры стратегий — общие с окном пересчёта

    /// The model saved in the source stays in the list even before the list is
    /// loaded, so the picker never contradicts the indicator below it.
    private var chatModelOptions: [String] {
        ModelPickerOptions.merging(
            configured: draft.wrappedValue.chunking.chatModel,
            into: embeddings.chatModels.map(\.id)
        )
    }

    /// the form has to say which mode it is in — a schema-constrained
    /// answer and a best-effort parse fail in completely different ways.
    @ViewBuilder
    private var structuredOutputRow: some View {
        Toggle(String(localized: "Structured Output (ответ по JSON-схеме)"), isOn: draft.chunking.useStructuredOutput)
        switch structuredOutputSupport {
        case .unknown:
            Text("Поддержка схемы у выбранной модели ещё не проверена.")
                .foregroundStyle(.secondary)
        case .waiting:
            Text("Локальная модель сейчас занята другой задачей — проверим поддержку схемы, когда она освободится. Источник можно сохранить и не дожидаясь.")
                .foregroundStyle(.secondary)
        case .checking:
            HStack {
                ProgressView().controlSize(.small)
                Text("Проверяем поддержку схемы…").foregroundStyle(.secondary)
            }
        case .supported:
            if draft.wrappedValue.chunking.useStructuredOutput {
                StatusLabel(.ok, String(localized: "Структурированный вывод поддерживается: сломанный JSON невозможен, резервный разбор не понадобится."))
            } else {
                Notice(.warning, String(localized: "Модель поддерживает схему, но переключатель выключен — используется резервный разбор."))
            }
        case .unsupported:
            Notice(.warning, String(localized: "Структурированный вывод недоступен для этой модели — используется резервный разбор и правило «если ответ не по формату»."))
        }
    }

    /// collapsed, and «empty means the field is not sent» — the same rule
    /// the HNSW parameters follow. Only parameters confirmed against a
    /// live LM Studio appear; `presence_penalty` is accepted and then ignored,
    /// so it is absent entirely rather than shown greyed out.
    private var extendedGenerationBlock: some View {
        DisclosureGroup(isExpanded: $showExtendedGeneration) {
            optionalField("top_p", value: draft.chunking.generation.topP, placeholder: "0…1")
            optionalIntField("top_k", value: draft.chunking.generation.topK, placeholder: "целое")
            optionalField("min_p", value: draft.chunking.generation.minP, placeholder: "0…1")
            optionalField("repeat_penalty", value: draft.chunking.generation.repeatPenalty, placeholder: "напр. 1.1")
            optionalField("frequency_penalty", value: draft.chunking.generation.frequencyPenalty, placeholder: "−2…2")
            optionalIntField("max_tokens", value: draft.chunking.generation.maxTokens, placeholder: "считается сам")
                // Единственное исключение из правила «пусто — не передаётся»,
                // и оно названо: это не догадка о чужом умолчании, а
                // требование G3 — предел считает приложение.
                .help(String(localized: "Кроме max_tokens при LLM-нарезке: пустое поле означает «считает приложение» — от размера окна и от того, сколько модель успевает написать за таймаут. Без предела модель, ушедшая в повтор, пишет до конца контекста и обрывается таймаутом. Модель, отвечающая рассуждением, тратит на него тот же лимит: слишком маленький max_tokens обрывает ответ до полезной части, и он считается некорректным."))
            Text("Пустое поле — параметр не передаётся вовсе: подставлять собственное представление о значении по умолчанию нельзя, у сервера и модели оно может быть другим. При temperature = 0 эти параметры на результат почти не влияют.")
                .foregroundStyle(.secondary)
        } label: {
            Text("Расширенные параметры")
                .togglesDisclosure($showExtendedGeneration)
        }
    }

    private func optionalField(_ title: String, value: Binding<Double?>, placeholder: String) -> some View {
        LabeledContent(title) {
            OptionalNumberField(
                placeholder: placeholder, value: value,
                parse: { Double($0.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "−", with: "-")) },
                format: { $0.formatted() }
            )
        }
    }

    private func optionalIntField(_ title: String, value: Binding<Int?>, placeholder: String) -> some View {
        LabeledContent(title) {
            OptionalNumberField(
                placeholder: placeholder, value: value,
                parse: { Int($0) }, format: { String($0) }
            )
        }
    }

    private var triggers: some View {
        Section {
            Toggle(String(localized: "Вручную — из списка источников"), isOn: .constant(true))
                .disabled(true)
                .help(String(localized: "Ручной запуск доступен всегда"))

            Toggle(String(localized: "При запуске приложения"), isOn: draft.triggers.onLaunch)

            Toggle(String(localized: "По расписанию"), isOn: draft.triggers.scheduled)
            if draft.wrappedValue.triggers.scheduled {
                Picker(String(localized: "Режим"), selection: draft.triggers.schedule.kind) {
                    ForEach(SyncSchedule.Kind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.radioGroup)

                if draft.wrappedValue.triggers.schedule.kind == .interval {
                    StepperRow(
                        String(localized: "Интервал, мин"),
                        value: draft.triggers.schedule.intervalMinutes, in: 5...1440, step: 5
                    )
                } else {
                    StepperRow(String(localized: "Час"), value: draft.triggers.schedule.hour, in: 0...23)
                    StepperRow(String(localized: "Минута"), value: draft.triggers.schedule.minute, in: 0...59, step: 5)
                }
            }

            Toggle(String(localized: "При изменениях в папке (FSEvents)"), isOn: draft.triggers.onFileChanges)
            if draft.wrappedValue.triggers.onFileChanges {
                DecimalStepperRow(
                    String(localized: "Пауза после последнего изменения, с"),
                    value: draft.triggers.debounceSeconds, in: 1...120, step: 1
                )
            }
        } header: {
            SectionHeader(
                String(localized: "Когда синхронизировать"),
                help: String(localized: "Таймеры живут, пока приложение запущено: фоновых демонов и launchd-агентов приложение не устанавливает. Запуск по изменениям в папке ждёт, пока правки утихнут, — массовое копирование даёт один запуск, а не сотню.")
            )
        } footer: {
            Text("Режимы комбинируются. Удаления не выполняются автоматически ни в одном режиме: исчезнувшие файлы попадают в «Требуют решения».")
        }
    }

    private var metadata: some View {
        Section {
            ForEach($model.draftMetadataRows) { $row in
                HStack {
                    TextField(String(localized: "Ключ"), text: $row.key, prompt: Text("ключ"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    TextField(String(localized: "Значение"), text: $row.value, prompt: Text("значение"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    Button {
                        model.draftMetadataRows.removeAll { $0.id == row.id }
                        if model.draftMetadataRows.isEmpty { model.draftMetadataRows = [.init()] }
                    } label: {
                        Label(String(localized: "Убрать поле"), systemImage: "minus.circle")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Убрать поле"))
                }
            }
            HStack {
                Spacer()
                Button(String(localized: "Добавить поле")) {
                    model.draftMetadataRows.append(.init())
                }
            }
        } header: {
            SectionHeader(
                String(localized: "Метаданные источника"),
                // The extraction fields are listed separately because they are
                // not all unconditional: page_number and heading_path exist
                // only where the document has pages or an outline.
                help: String(localized: "Приложение и так пишет в каждый чанк: \(SourceSyncService.autoMetadataKeys.joined(separator: ", ")). От извлечения добавляются \(SourceSyncService.extractionMetadataKeys.joined(separator: ", ")), а где документ это позволяет — page_number, page_count, heading_path и extraction_warnings. Поля ниже добавляются к ним, а не вместо них.")
            )
        } footer: {
            Text("Свои поля, которые добавятся к каждому чанку этого источника.")
        }
    }

    private var schemaHookup: some View {
        Section {
            if let coverage {
                if coverage.isSatisfied {
                    StatusLabel(.ok, String(localized: "Схема коллекции «\(coverage.collectionName)» закрыта полностью."))
                } else {
                    if !coverage.uncoveredRequiredFields.isEmpty {
                        Notice(.warning, String(localized: "Не закрыты обязательные поля: \(coverage.uncoveredRequiredFields.joined(separator: ", "))"))
                    }
                    ForEach(coverage.typeProblems) { problem in
                        Notice(.warning, problem.message)
                    }
                    Picker(String(localized: "Если поля не закрыты"), selection: draft.unresolvedSchemaPolicy) {
                        ForEach(UnresolvedSchemaPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }
                LabeledContent(String(localized: "Источник даёт поля"), value: coverage.providedKeys.joined(separator: ", "))
            } else {
                Text("У коллекции «\(CollectionNaming.sanitize(draft.wrappedValue.collectionName))» схемы нет — метаданные ничем не ограничены.")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(String(localized: "Сгенерировать черновик схемы из полей источника")) {
                        guard var source = model.draft else { return }
                        // Поля берутся из того, что набрано **в этом листе**,
                        // а не из сохранённого источника: иначе кнопка молчит
                        // ровно тогда, когда её и нажимают — сразу после того,
                        // как поля вписали.
                        source.customMetadata = Dictionary(
                            model.draftMetadataRows
                                .map { ($0.key.trimmingCharacters(in: .whitespaces), $0.value) }
                                .filter { !$0.0.isEmpty },
                            uniquingKeysWith: { _, last in last }
                        )
                        model.draftSchemaFromSource(source, app: app)
                        schemaNotice = model.infoMessage
                        model.infoMessage = nil
                        Task { await refreshCoverage() }
                    }
                    // Поля из пути — тоже поля источника, и черновик
                    // их берёт; кнопка же гасла, пока не набрано ручное
                    // поле, — у источника с одними уровнями папок навсегда.
                    .disabled(
                        model.draftMetadataRows.allSatisfy { $0.key.trimmingCharacters(in: .whitespaces).isEmpty }
                            && !draft.wrappedValue.pathLevels.contains(where: \.isNamed)
                    )
                }
                if let schemaNotice {
                    HStack {
                        Notice(.info, schemaNotice)
                        Spacer()
                        Button(String(localized: "Скрыть")) { self.schemaNotice = nil }
                            .buttonStyle(.borderless)
                    }
                }
            }
        } header: {
            SectionHeader(
                String(localized: "Схема целевой коллекции"),
                help: String(localized: "Схема — договор коллекции о метаданных: какие ключи обязательны и какого они типа. Источник закрывает её своими полями — автоматическими, извлечёнными и добавленными вручную. Если обязательное поле не закрыто, приложение спрашивает, что делать с такими чанками, а не решает само.")
            )
        } footer: {
            Text("Совпадают ли поля источника с тем, что коллекция от них ждёт.")
        }
    }

    private func refreshCoverage() async {
        guard var source = model.draft else { return }
        source.customMetadata = Dictionary(
            model.draftMetadataRows
                .map { ($0.key.trimmingCharacters(in: .whitespaces), $0.value) }
                .filter { !$0.0.isEmpty },
            uniquingKeysWith: { _, last in last }
        )
        coverage = await model.coverage(for: source, app: app)
    }
}

/// Полосы синхронизации — отдельным наблюдателем очереди.
///
/// Экран источников самый тяжёлый в приложении: 280 строк текста и 84 мелких
/// подписи. Пока он читал очередь сам, каждое её сообщение о прогрессе —
/// четырежды в секунду — перестраивало его целиком. Здесь перестраиваются
/// только полосы.
private struct SyncProgressRows: View {
    @EnvironmentObject private var queueMirror: QueueMirror
    /// Подпись собирает экран: она зависит от того, чем вызвана синхронизация,
    /// а это знание живёт в его модели.
    let label: (QueuedTaskInfo) -> String

    var body: some View {
        ForEach(queueMirror.tasks(titledWith: QueueMirror.TitlePrefix.sync)) { task in
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: task.progress ?? 0) {
                    Text(label(task))
                }
                if let detail = task.detail {
                    Text(detail).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }
}

/// Поле необязательного числа, в котором можно **набрать** число.
///
/// Прежде текст поля каждый раз собирался из разобранного значения: «1.»
/// разбиралось в 1 и печаталось «1» — точка съедалась, следующая цифра
/// давала 11 вместо 1.1, а одинокий минус очищал поле. Здесь текст свой:
/// неразобранное («1.», «-») — это ввод на полпути, и значение он не трогает;
/// переписывается текст, только когда значение поменяли снаружи.
private struct OptionalNumberField<Value: Equatable>: View {
    let placeholder: String
    @Binding var value: Value?
    let parse: (String) -> Value?
    let format: (Value) -> String
    @State private var text = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .onAppear { text = value.map(format) ?? "" }
            .onChange(of: text) { _, typed in
                let trimmed = typed.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    value = nil
                } else if let parsed = parse(trimmed) {
                    value = parsed
                }
            }
            .onChange(of: value) { _, current in
                let shown = parse(text.trimmingCharacters(in: .whitespaces))
                if shown != current { text = current.map(format) ?? "" }
            }
    }
}

// MARK: - Языки распознавания

/// Языки распознавания: «автоматически», «русский и английский»
/// или свой набор.
///
/// Было меню с флажками на все языки системы — их десятки, пункты в листе
/// настроек выглядели погашенными, а нужны почти всегда два ответа:
/// «пусть Vision решит» (русский он узнаёт и так) и «русский с английским».
/// Остальное — в отдельном списке за «Другие…».
private struct OCRLanguagesRow: View {
    @Binding var languages: [String]
    let supported: [String]
    @State private var choosingOthers = false

    private enum Preset: Hashable { case automatic, russianAndEnglish, other }

    /// Русский первым: Vision читает список как порядок предпочтения.
    private static let russianAndEnglish = ["ru-RU", "en-US"]

    private var preset: Preset {
        if languages.isEmpty { return .automatic }
        if Set(languages) == Set(Self.russianAndEnglish) { return .russianAndEnglish }
        return .other
    }

    var body: some View {
        let offersPair = Set(Self.russianAndEnglish).isSubset(of: supported)
        LabeledContent(String(localized: "Языки распознавания")) {
            HStack {
                Picker("", selection: Binding(
                    get: { preset },
                    set: { chosen in
                        switch chosen {
                        case .automatic: languages = []
                        case .russianAndEnglish: languages = Self.russianAndEnglish
                        case .other: choosingOthers = true
                        }
                    }
                )) {
                    Text("Автоматически").tag(Preset.automatic)
                    if offersPair { Text("Русский и английский").tag(Preset.russianAndEnglish) }
                    Text(preset == .other ? Self.names(languages) : String(localized: "Другие…")).tag(Preset.other)
                }
                .labelsHidden()
                .fixedSize()
                if preset == .other {
                    Button(String(localized: "Изменить…")) { choosingOthers = true }
                }
            }
            .popover(isPresented: $choosingOthers, arrowEdge: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(supported, id: \.self) { language in
                            Toggle(Self.name(language), isOn: Binding(
                                get: { languages.contains(language) },
                                set: { isOn in
                                    var set = Set(languages)
                                    if isOn { set.insert(language) } else { set.remove(language) }
                                    languages = set.sorted()
                                }
                            ))
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding(12)
                }
                .frame(width: 260, height: 320)
            }
        }
        .help(String(localized: "«Автоматически» — Vision выбирает сам и русский узнаёт без подсказки. Свой набор нужен для редких языков; каждый лишний язык замедляет распознавание. Доступно на этой системе: \(supported.count)."))
    }

    /// «русский (Россия)» вместо «ru-RU».
    static func name(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    static func names(_ identifiers: [String]) -> String {
        identifiers.map(name).joined(separator: ", ")
    }
}
