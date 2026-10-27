import SwiftUI
import ChromaCore

/// «Оценка» — прогон набора запросов по нескольким вариантам.
///
/// The screen shows the plan, then what the plan will cost, then the run. The
/// order is the point: D1.2 makes the cost mandatory before the start, because
/// a set of twenty queries against four variants is eighty searches and up to
/// eighty calls to a local model that nothing else can use meanwhile.
///
/// «Набор запросов» — тип Б: набор выбирается в тулбаре, запросы — таблица.
/// «Варианты» — форма: варианты, стоимость, «Прогнать». «Прогоны» — три
/// части сегментами над содержимым: история (таблица), отчёт (форма) и
/// разметка (сетка выдач вариантов рядом).
struct EvaluationView: View {
    @EnvironmentObject private var app: AppEnvironment
    @ObservedObject var model: EvaluationViewModel
    /// Разрез экрана: «Набор запросов», «Варианты», «Прогоны».
    var tab: Int = 0
    /// Перейти на соседнюю вкладку — например, к готовому прогону.
    var openTab: (Int) -> Void = { _ in }
    /// «Просмотр доступен и из результатов стенда оценки — при разметке
    /// результатов посмотреть исходник особенно нужно».
    @StateObject private var viewer = DocumentViewerViewModel()
    /// Раскрыт ли промпт оценки — по той же причине, что и таймауты.
    @State private var showingJudgePrompt = false
    /// Выбранные запросы набора.
    @State private var selectedQueries: Set<UUID> = []
    /// Часть вкладки «Прогоны».
    @SceneStorage("evaluation.runsPart") private var runsPart = RunsPart.history.rawValue
    @State private var selectedRun: UUID?
    /// Порядок, ширины и видимость колонок — помнит окно (v3).
    @SceneStorage("table.runs.v4") private var runColumns: TableColumnCustomization<EvaluationRunSummary>
    @SceneStorage("table.queries.v3") private var queryColumns: TableColumnCustomization<EvaluationQuery>
    /// Сохранённый прогон, ждущий подтверждения удаления.
    @State private var runPendingDeletion: EvaluationRunSummary?

    enum RunsPart: String, CaseIterable, Identifiable {
        case history, report, marking
        var id: String { rawValue }
        var title: String {
            switch self {
            case .history: return String(localized: "История")
            case .report: return String(localized: "Отчёт")
            case .marking: return String(localized: "Разметка")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            banners
            switch tab {
            case 1:
                variantsForm
            case 2:
                runsTab
            default:
                setTab
            }
        }
        .task { await model.load(app) }
        .sheet(isPresented: Binding(
            get: { model.draft != nil },
            set: { if !$0 { model.draft = nil } }
        )) {
            variantSheet
        }
        .sheet(isPresented: Binding(
            get: { viewer.request != nil },
            set: { if !$0 { viewer.close() } }
        )) {
            DocumentViewerSheet(model: viewer)
        }
        .sheet(isPresented: Binding(
            get: { model.setDraft != nil },
            set: { if !$0 { model.setDraft = nil } }
        )) {
            setSheet
        }
        .sheet(isPresented: Binding(
            get: { model.queryDraft != nil },
            set: { if !$0 { model.queryDraft = nil } }
        )) {
            querySheet
        }
        // Удаление набора уносит эталон — часы ручной работы. Спрашиваем, и
        // говорим, сколько именно отметок исчезнет (правило 1).
        .confirmationDialog(
            model.setPendingDeletion.map { String(localized: "Удалить набор «\($0.name)»?") } ?? "",
            isPresented: Binding(
                get: { model.setPendingDeletion != nil },
                set: { if !$0 { model.setPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Удалить набор"), role: .destructive) { model.deleteSet(app) }
            Button(String(localized: "Отменить"), role: .cancel) { model.setPendingDeletion = nil }
        } message: {
            if let set = model.setPendingDeletion {
                Text("Вместе с набором исчезнет его эталон: \(set.line). Сохранённые прогоны останутся — они хранят свои запросы целиком.")
            }
        }
        .confirmationDialog(
            String(localized: "Удалить запрос из набора?"),
            isPresented: Binding(
                get: { model.queryPendingDeletion != nil },
                set: { if !$0 { model.queryPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Удалить"), role: .destructive) { model.removeQuery(app) }
            Button(String(localized: "Отменить"), role: .cancel) { model.queryPendingDeletion = nil }
        } message: {
            if let query = model.queryPendingDeletion {
                Text(query.hasGroundTruth
                     ? "«\(query.text)» — вместе с запросом исчезнут и его отметки эталона."
                     : "«\(query.text)»")
            }
        }
        // Сохранённый прогон — часы работы модели; удаляется с вопросом.
        .confirmationDialog(
            runPendingDeletion.map { String(localized: "Удалить прогон «\($0.name)»?") } ?? "",
            isPresented: Binding(
                get: { runPendingDeletion != nil },
                set: { if !$0 { runPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Удалить прогон"), role: .destructive) {
                if let summary = runPendingDeletion { model.removeRun(summary, app: app) }
                runPendingDeletion = nil
            }
            Button(String(localized: "Отменить"), role: .cancel) { runPendingDeletion = nil }
        } message: {
            Text("Прогон удалится вместе с выдачей и метриками. Эталон набора останется: отметки живут в наборе, а не в прогоне.")
        }
        // 5 требует предупредить дважды: о стоимости и о том, что оценка
        // модели не истина. Оба предупреждения — в этом окне, до первого
        // вызова модели.
        .confirmationDialog(
            String(localized: "Запустить оценку чат-моделью?"),
            isPresented: Binding(
                get: { model.pendingJudgement != nil },
                set: { if !$0 { model.pendingJudgement = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Оценить")) { model.startJudgement(app) }
            Button(String(localized: "Отменить"), role: .cancel) { model.cancelPendingJudgement() }
        } message: {
            if let cost = model.pendingJudgement {
                Text("\(cost.line).\n\nПока идёт оценка, модель занята только этим. Её вывод — мнение модели, а не истина: он не попадает ни в эталон, ни в метрики, и принимать его нужно по одному, вручную.")
            }
        }
    }

    /// Сообщения — строками над содержимым, как на остальных экранах.
    @ViewBuilder
    private var banners: some View {
        let problem = app.querySets.persistenceProblem
        if model.errorMessage != nil || model.statusMessage != nil || model.exportMessage != nil || problem != nil {
            VStack(alignment: .leading) {
                if let error = model.errorMessage {
                    dismissible(Notice(.warning, error)) { model.errorMessage = nil }
                }
                if let status = model.statusMessage {
                    dismissible(Notice(.info, status)) { model.statusMessage = nil }
                }
                if let exported = model.exportMessage {
                    dismissible(Notice(.info, exported)) { model.exportMessage = nil }
                }
                // Эталон разметки — часы ручной работы. Если файл наборов не
                // прочитался, приложение ничего в него не пишет, и знать об
                // этом надо до, а не после разметки.
                if let problem {
                    Notice(.warning, problem)
                }
            }
            .padding()
            Divider()
        }
    }

    private func dismissible<Content: View>(_ content: Content, hide: @escaping () -> Void) -> some View {
        HStack {
            content
            Spacer()
            Button(String(localized: "Скрыть"), action: hide)
                .buttonStyle(.borderless)
        }
    }

    // MARK: - Набор запросов

    private var setTab: some View {
        VStack(spacing: 0) {
            if model.sets.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "Наборов пока нет"), systemImage: "list.bullet.rectangle")
                } description: {
                    Text("Основной способ наполнения — кнопка «В набор» в истории поиска на экране коллекции: двадцать запросов руками никто не пишет. Можно и создать набор здесь.")
                } actions: {
                    Button(String(localized: "Новый набор…")) { model.newSet() }
                    Button(String(localized: "Импорт набора…")) { model.importSet(app) }
                }
                // Всё место под баннерами — пустому состоянию: иначе стопка
                // вставала по центру, и баннер висел посреди экрана.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let set = model.selectedSet {
                if set.queries.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "В наборе нет запросов"), systemImage: "text.magnifyingglass")
                    } description: {
                        Text("Выполните запрос на экране «Коллекции» и нажмите «В набор» под ним — или впишите запрос сами.")
                    } actions: {
                        Button(String(localized: "Добавить запрос…")) { model.newQuery() }
                            .disabled(model.isRunning)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    queryTable(set)
                }
                setFooter(set)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if tab == 0 {
                    if !model.sets.isEmpty {
                        Picker(String(localized: "Набор"), selection: Binding(
                            get: { model.selectedSetID },
                            set: { newValue in
                                model.selectedSetID = newValue
                                selectedQueries.removeAll()
                                Task { await model.updateCost(app) }
                            }
                        )) {
                            ForEach(model.sets) { set in
                                Text(set.name).tag(Optional(set.id))
                            }
                        }
                        .help(String(localized: "Набор запросов"))
                    }
                    Button {
                        model.newQuery()
                    } label: {
                        Label(String(localized: "Добавить запрос…"), systemImage: "plus")
                    }
                    .help(String(localized: "Добавить запрос в набор"))
                    .disabled(model.selectedSet == nil || model.isRunning)
                    Menu {
                        Button(String(localized: "Новый набор…")) { model.newSet() }
                        Button(String(localized: "Переименовать…")) { model.renameSet() }
                            .disabled(model.selectedSet == nil)
                        Divider()
                        Button(String(localized: "Экспорт набора…")) { model.exportSet(app) }
                            .disabled(model.selectedSet == nil)
                        Button(String(localized: "Импорт набора…")) { model.importSet(app) }
                        Divider()
                        Button(String(localized: "Удалить набор…"), role: .destructive) { model.requestSetDeletion() }
                            .disabled(model.selectedSet == nil)
                    } label: {
                        Label(String(localized: "Ещё"), systemImage: "ellipsis.circle")
                    }
                }
            }
        }
    }

    /// Запросы набора: текст, эталон, теги — правка и удаление из меню.
    private func queryTable(_ set: QuerySet) -> some View {
        Table(set.queries, selection: $selectedQueries, columnCustomization: $queryColumns) {
            TableColumn(String(localized: "Запрос")) { query in
                Text(query.text)
                    .lineLimit(1)
                    .help(query.text)
            }
            .customizationID("query")
            TableColumn(String(localized: "Эталон")) { query in
                let marks = query.fragments.count + query.documents.count
                Text(marks == 0
                     ? String(localized: "нет")
                     : RussianCount.phrase(marks, "отметка", "отметки", "отметок"))
                    .foregroundStyle(marks == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            }
            // С потолком: растянутая на широком окне колонка не отдавала
            // место обратно, и в узком появлялась горизонтальная прокрутка.
            // Тянется и сжимается «Запрос».
            .width(min: 80, ideal: 110, max: 140)
            .customizationID("reference")
            TableColumn(String(localized: "Теги и фильтр")) { query in
                Text(Self.queryExtras(query))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 100, ideal: 200, max: 280)
            .customizationID("extras")
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if ids.count == 1, let id = ids.first, let query = set.queries.first(where: { $0.id == id }) {
                Button(String(localized: "Править…")) { model.editQuery(query) }
                    .disabled(model.isRunning)
                Divider()
                Button(String(localized: "Удалить…"), role: .destructive) { model.queryPendingDeletion = query }
                    .disabled(model.isRunning)
            }
        } primaryAction: { ids in
            if let id = ids.first, let query = set.queries.first(where: { $0.id == id }), !model.isRunning {
                model.editQuery(query)
            }
        }
        .onDeleteCommand {
            if selectedQueries.count == 1, let id = selectedQueries.first,
               let query = set.queries.first(where: { $0.id == id }), !model.isRunning {
                model.queryPendingDeletion = query
            }
        }
    }

    private func setFooter(_ set: QuerySet) -> some View {
        // Внизу — только счёт; заметка набора (бывает длинной, с путями к
        // документам) — в «?» (v6).
        let about = String(localized: "Набор принадлежит задаче, а не коллекции: один и тот же набор гоняется по разным вариантам. Запросы без эталона всё равно прогоняются — их выдачу можно разметить прямо в результатах.")
        return TableFooter(
            set.line,
            help: set.note.isEmpty ? about : "\(set.note)\n\n\(about)"
        )
    }

    /// Что известно про запрос, кроме текста и эталона.
    private static func queryExtras(_ query: EvaluationQuery) -> String {
        var parts: [String] = []
        if query.filter != nil { parts.append(String(localized: "с фильтром")) }
        if !query.tags.isEmpty { parts.append(query.tags.joined(separator: ", ")) }
        if !query.comment.isEmpty { parts.append(query.comment) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    // MARK: - Варианты и прогон

    /// Вариантов нет — пустое состояние на всю вкладку, без формы и без
    /// секции «Прогон» с неактивной кнопкой (v6 B3).
    @ViewBuilder
    private var variantsForm: some View {
        if model.variants.isEmpty {
            ContentUnavailableView {
                Label(String(localized: "Вариантов нет"), systemImage: "square.split.2x1")
            } description: {
                Text(model.collections.isEmpty
                     ? String(localized: "Нет подключения к базе или в ней нет коллекций.")
                     : String(localized: "Добавьте хотя бы один — сравнивать можно и два профиля поиска одной коллекции, это не требует клонирования."))
            } actions: {
                Button(String(localized: "Добавить вариант…")) { model.beginVariant(app) }
                    .disabled(model.isRunning || model.collections.isEmpty)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            variantsAndRunForm
        }
    }

    private var variantsAndRunForm: some View {
        Form {
            // Прогон закончился — сказать об этом и увести к результатам.
            if let run = model.lastRun, !model.isRunning {
                Section {
                    LabeledContent {
                        Button(String(localized: "Открыть прогон")) {
                            runsPart = RunsPart.report.rawValue
                            openTab(2)
                        }
                    } label: {
                        StatusLabel(.ok, String(localized: "Готов прогон «\(run.name)»"))
                    }
                }
            }

            Section {
                ForEach(model.variants) { variant in
                    LabeledContent {
                        Button(String(localized: "Убрать")) { model.removeVariant(variant, app: app) }
                            .disabled(model.isRunning)
                    } label: {
                        Text(variant.name)
                        Text(variant.note.isEmpty ? variant.line : "\(variant.line) · \(variant.note)")
                    }
                }
                HStack {
                    Spacer()
                    Button(String(localized: "Добавить вариант…")) { model.beginVariant(app) }
                        .disabled(model.isRunning || model.collections.isEmpty)
                }
            } header: {
                SectionHeader(
                    String(localized: "Варианты"),
                    help: String(localized: "Вариант — это коллекция плюс профиль поиска. Метрика расстояния и модель берутся из самой коллекции — их нельзя выбрать здесь. Чтобы сравнить другую модель или стратегию, склонируйте коллекцию: «Коллекции» → «Пересчитать векторы…» → «Клонировать».")
                )
            } footer: {
                if model.collections.isEmpty {
                    Notice(.warning, String(localized: "Нет подключения к базе или в ней нет коллекций."))
                }
            }

            Section {
                if let cost = model.cost {
                    LabeledContent(String(localized: "Стоимость")) {
                        Text(cost.line).copyable(cost.line)
                    }
                } else {
                    Text("Выберите набор и хотя бы один вариант — тогда здесь появится стоимость прогона.")
                        .foregroundStyle(.secondary)
                }
                if let progress = model.progress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                        Text(progress.line)
                    }
                }
                HStack {
                    Spacer()
                    if model.isRunning {
                        Button(String(localized: "Остановить")) { model.cancel() }
                            .help(String(localized: "Отмена сохраняет уже полученные результаты и помечает прогон неполным."))
                    }
                    // Без Return (v4 A7): кнопку по Return macOS красит синим, а
                    // выделенная бывает только в листах; прогон — долгий, его
                    // не запускают нечаянным нажатием в поле.
                    Button(String(localized: "Прогнать")) { model.run(app) }
                        .disabled(!model.canRun)
                }
            } header: {
                Text("Прогон")
            } footer: {
                if let cost = model.cost, cost.isLong {
                    Notice(.warning, String(localized: "Прогон длинный: пока он идёт, локальная модель занята — синхронизация и поиск встанут в очередь за ним."))
                } else {
                    Text("Вектор запроса считается один раз на модель и переиспользуется всеми вариантами с той же моделью.")
                }
            }

            Section {
                HowItWorks(screen: "evaluation", String(localized: "Один набор запросов, несколько вариантов — и одна и та же выдача, сохранённая целиком. Вектор запроса считается один раз на модель и переиспользуется всеми вариантами с той же моделью. Вариант — это коллекция плюс профиль поиска. Метрика расстояния и модель берутся из самой коллекции: сравнить другую модель или стратегию можно только по уже существующим коллекциям, потому что модель привязана к коллекции навсегда."))
            }
        }
        .formStyle(.grouped)
    }

    private var variantSheet: some View {
        SheetForm(
            cancel: { model.draft = nil },
            confirmTitle: String(localized: "Добавить"),
            confirm: { Task { await model.addVariant(app) } }
        ) {
            if let draft = model.draft {
                Section {
                    Picker(String(localized: "Коллекция"), selection: Binding(
                        get: { draft.collectionName },
                        set: { name in
                            model.draft?.collectionName = name
                            model.draft?.profileID = nil
                            model.draft?.name = name
                        }
                    )) {
                        ForEach(model.collections) { collection in
                            Text(collection.name).tag(collection.name)
                        }
                    }
                    Picker(String(localized: "Профиль поиска"), selection: Binding(
                        get: { model.draft?.profileID },
                        set: { model.draft?.profileID = $0 }
                    )) {
                        Text("Действующий для коллекции").tag(UUID?.none)
                        ForEach(model.profiles(for: draft.collectionName, app: app)) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }
                    StepperRow("n_results", value: Binding(
                        get: { model.draft?.nResults ?? 10 },
                        set: { model.draft?.nResults = $0 }
                    ), in: 1...50)
                    TextField(String(localized: "Название в отчёте"), text: Binding(
                        get: { model.draft?.name ?? "" },
                        set: { model.draft?.name = $0 }
                    ))
                } header: {
                    SectionHeader(
                        String(localized: "Новый вариант"),
                        help: String(localized: "Название варианта становится заголовком колонки в отчёте. Понятное имя («512 символов», «с переранжированием») читается через месяц, имя коллекции — нет.")
                    )
                } footer: {
                    Text("Вариант — это коллекция плюс профиль поиска: их и сравнивает прогон.")
                }
            }
        }
    }

    // MARK: - Набор и запрос: листы

    private var setSheet: some View {
        SheetForm(
            cancel: { model.setDraft = nil },
            confirmTitle: String(localized: "Сохранить"),
            confirmDisabled: (model.setDraft?.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
            confirm: { model.saveSet(app) }
        ) {
            Section {
                TextField(String(localized: "Название"), text: Binding(
                    get: { model.setDraft?.name ?? "" },
                    set: { model.setDraft?.name = $0 }
                ))
                TextField(String(localized: "Заметка"), text: Binding(
                    get: { model.setDraft?.note ?? "" },
                    set: { model.setDraft?.note = $0 }
                ), axis: .vertical)
                .lineLimit(2...4)
            } header: {
                Text(model.setDraft?.isNew == true
                     ? String(localized: "Новый набор")
                     : String(localized: "Переименовать набор"))
            } footer: {
                Text("Набор принадлежит задаче, а не коллекции: один и тот же набор гоняется по разным вариантам.")
            }
        }
    }

    private var querySheet: some View {
        SheetForm(
            width: .wide,
            cancel: { model.queryDraft = nil },
            confirmTitle: String(localized: "Сохранить"),
            confirmDisabled: (model.queryDraft?.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
            confirm: { model.saveQuery(app) }
        ) {
            Section {
                TextField(String(localized: "Текст запроса"), text: Binding(
                    get: { model.queryDraft?.text ?? "" },
                    set: { model.queryDraft?.text = $0 }
                ), axis: .vertical)
                .lineLimit(2...5)
                TextField(String(localized: "Теги через запятую"), text: Binding(
                    get: { model.queryDraft?.tags ?? "" },
                    set: { model.queryDraft?.tags = $0 }
                ))
                TextField(String(localized: "Комментарий"), text: Binding(
                    get: { model.queryDraft?.comment ?? "" },
                    set: { model.queryDraft?.comment = $0 }
                ))
            } header: {
                Text(model.queryDraft?.isNew == true
                     ? String(localized: "Новый запрос")
                     : String(localized: "Правка запроса"))
            } footer: {
                Text(model.queryDraft?.isNew == false
                     ? String(localized: "Эталон запроса правка не трогает: отметки релевантности — отдельная работа.")
                     : String(localized: "Запрос набора: его текст и, если нужно, фильтр по метаданным."))
            }
            queryFilterSection
        }
    }

    /// Фильтр — тот же редактор, что на экране поиска, а не его копия.
    private var queryFilterSection: some View {
        Section {
            Toggle(String(localized: "Применять фильтр"), isOn: Binding(
                get: { model.queryDraft?.filter != nil },
                set: { model.queryDraft?.filter = $0 ? (model.queryDraft?.filter ?? DocumentFilter()) : nil }
            ))
            if model.queryDraft?.filter != nil {
                FilterNodeEditor(
                    node: Binding(
                        get: { model.queryDraft?.filter?.root ?? .group(.and, []) },
                        set: { model.queryDraft?.filter?.root = $0 }
                    ),
                    knownFields: model.filterFields(app),
                    depth: 0,
                    onRemove: nil
                )
            }
        } header: {
            Text("Фильтр")
        } footer: {
            if model.queryDraft?.filter != nil {
                Text("Фильтр применяется вместе с запросом, как на экране поиска. Поля предлагаются по схемам всех коллекций — набор не привязан к одной.")
            }
        }
    }

    // MARK: - Прогоны

    private var runsTab: some View {
        VStack(spacing: 0) {
            runsPartBar
            switch RunsPart(rawValue: runsPart) ?? .history {
            case .history:
                historyTable
            case .report:
                if model.lastRun != nil {
                    reportForm
                } else {
                    noOpenRun
                }
            case .marking:
                if let run = model.lastRun {
                    markingPane(run)
                } else {
                    noOpenRun
                }
            }
        }
        // Сегменты частей — в начале содержимого, и прижаты к верху всегда:
        // заглушка пустой истории во всю высоту не растягивается, и без этого
        // вся стопка центрировалась вместе с сегментами.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Части прогонов — уровнем ниже вкладок экрана, сегментами в начале
    /// содержимого, как «Документы / Поиск / Обзор» у коллекции: сначала
    /// «что за экран», потом «какую его часть смотреть». Меню в тулбаре
    /// (v6 B2) стояло вровень с вкладками экрана и читалось как ещё одна
    /// из них. Справа — какой прогон открыт: отчёт и разметка — о нём.
    private var runsPartBar: some View {
        HStack(spacing: 12) {
            Picker(String(localized: "Часть прогонов"), selection: $runsPart) {
                ForEach(RunsPart.allCases) { part in
                    Text(part.title).tag(part.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if let run = model.lastRun {
                Text("Открыт «\(run.name)»")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding()
    }

    private var noOpenRun: some View {
        ContentUnavailableView {
            Label(String(localized: "Прогон не открыт"), systemImage: "chart.bar.doc.horizontal")
        } description: {
            Text(model.runs.isEmpty
                 ? String(localized: "Соберите набор запросов, добавьте хотя бы один вариант и нажмите «Прогнать» на вкладке «Варианты».")
                 : String(localized: "Откройте прогон в «Истории» — двойным щелчком."))
        } actions: {
            if !model.runs.isEmpty {
                Button(String(localized: "Показать историю")) { runsPart = RunsPart.history.rawValue }
            }
        }
        // Во всю высоту: иначе стопка центрируется, и переключатель частей
        // висит посреди окна.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Сохранённые прогоны — таблица; «Открыть» — двойной щелчок.
    @ViewBuilder
    private var historyTable: some View {
        if model.runs.isEmpty {
            ContentUnavailableView {
                Label(String(localized: "Прогонов пока нет"), systemImage: "chart.bar.doc.horizontal")
            } description: {
                Text("Прогон хранится целиком — с датой, версией приложения и полными параметрами вариантов. Соберите набор, добавьте вариант и нажмите «Прогнать» на вкладке «Варианты».")
            }
            // Во всю оставшуюся высоту — по центру под сегментами частей.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(model.runs, selection: $selectedRun, columnCustomization: $runColumns) {
                // Название, дата, набор, число запросов; варианты — главная
                // колонка, без ширины: в ней самый длинный текст (v6 B2).
                TableColumn(String(localized: "Название")) { summary in
                    HStack {
                        let title = summary.name.isEmpty
                            ? summary.startedAt.formatted(date: .abbreviated, time: .shortened)
                            : summary.name
                        Text(title).lineLimit(1).help(title)
                        if summary.id == model.lastRun?.id {
                            Text("открыт").foregroundStyle(.secondary)
                        }
                    }
                }
                .width(min: 120, ideal: 200, max: 320)
                .customizationID("name")
                TableColumn(String(localized: "Дата")) { summary in
                    HStack {
                        Text(summary.startedAt.formatted(date: .abbreviated, time: .shortened))
                        if !summary.isComplete {
                            StatusLabel(.warning, String(localized: "неполный"))
                        }
                    }
                }
                .width(min: 110, ideal: 140, max: 220)
                .customizationID("date")
                TableColumn(String(localized: "Набор")) { summary in
                    Text(summary.querySetName).foregroundStyle(.secondary).lineLimit(1)
                        .help(summary.querySetName)
                }
                .width(min: 100, ideal: 160, max: 220)
                .customizationID("set")
                TableColumn(String(localized: "Запросов")) { summary in
                    Text(summary.queryCount.formatted()).monospacedDigit()
                }
                .width(min: 60, ideal: 80, max: 110)
                .alignment(.numeric)
                .customizationID("count")
                TableColumn(String(localized: "Варианты")) { summary in
                    Text(summary.variantNames.joined(separator: ", "))
                        .foregroundStyle(.secondary).lineLimit(1)
                        .help(summary.variantNames.joined(separator: ", "))
                }
                .customizationID("variants")
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first, let summary = model.runs.first(where: { $0.id == id }) {
                    Button(String(localized: "Открыть")) { open(summary) }
                    Divider()
                    Button(String(localized: "Удалить…"), role: .destructive) { runPendingDeletion = summary }
                }
            } primaryAction: { ids in
                if let id = ids.first, let summary = model.runs.first(where: { $0.id == id }) {
                    open(summary)
                }
            }
            .onDeleteCommand {
                if let id = selectedRun, let summary = model.runs.first(where: { $0.id == id }) {
                    runPendingDeletion = summary
                }
            }
        }
    }

    private func open(_ summary: EvaluationRunSummary) {
        model.openRun(summary, app: app)
        runsPart = RunsPart.report.rawValue
    }

    // MARK: - Отчёт

    private var reportForm: some View {
        Form {
            Section {
                ksControl
                if let table = model.table(app) { metricTable(table) }
            } header: {
                SectionHeader(
                    String(localized: "Отчёт"),
                    help: String(localized: "Лучшее значение в столбце выделено — но только когда вариантов больше одного и значения различаются: «лучший из одинаковых» это не вывод. Метрики — набором чисел, и намеренно без единой «общей оценки качества»: одно число прячет, какая из его частей сдвинулась.")
                )
            } footer: {
                // Оговорка сразу под таблицей: она про то, как читать числа,
                // которые человек видит сейчас.
                if let caveat = model.lengthCaveat {
                    Notice(.warning, caveat)
                }
            }

            metricsSections
            divergentSection
            comparisonSection
            judgeSection

            Section {
                HStack {
                    Spacer()
                    Button(String(localized: "Экспорт в Markdown…")) { model.export(markdown: true, app: app) }
                    Button(String(localized: "Экспорт в JSON…")) { model.export(markdown: false, app: app) }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Настройка k. Стоит над таблицей, потому что меняет её столбцы.
    private var ksControl: some View {
        LabeledContent(String(localized: "Считать @k для")) {
            HStack {
                ForEach([1, 3, 5, 10, 20], id: \.self) { k in
                    Toggle("@\(k)", isOn: Binding(
                        get: { model.ks(app).contains(k) },
                        set: { _ in toggleK(k) }
                    ))
                    .toggleStyle(.button)
                }
            }
        }
    }

    /// Снять последний оставшийся k нельзя: таблица без единой метрики
    /// выглядит поломкой, а не настройкой.
    private func toggleK(_ k: Int) {
        var current = Set(model.ks(app))
        if current.contains(k) {
            guard current.count > 1 else { return }
            current.remove(k)
        } else {
            current.insert(k)
        }
        app.settings.configuration.evaluationKs = EvaluationMetrics.sanitisedKs(Array(current))
        model.refreshForChangedKs(app)
    }

    /// Метрики строками, варианты колонками — сеткой в строке формы.
    private func metricTable(_ table: EvaluationReport.Table) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Метрика").bold()
                    ForEach(Array(table.variantNames.enumerated()), id: \.offset) { _, name in
                        Text(name).bold().lineLimit(1)
                    }
                }
                Divider()
                ForEach(table.columns) { column in
                    GridRow {
                        Text(column.title)
                        ForEach(Array(column.cells.enumerated()), id: \.offset) { _, cell in
                            Text(cell.text)
                                .monospacedDigit()
                                // Полужирный, а не цвет: цветом на этом экране
                                // уже размечены оценки релевантности.
                                .fontWeight(cell.isBest ? .bold : .regular)
                                .foregroundStyle(cell.value == nil ? Color.secondary : Color.primary)
                        }
                    }
                }
            }
        }
    }

    /// Подробности метрик по варианту: задержки, охват, оговорки.
    @ViewBuilder
    private var metricsSections: some View {
        ForEach(model.metrics, id: \.variantID) { variantMetrics in
            Section {
                LabeledContent("hit rate", value: Self.line("", variantMetrics.hitRate).trimmingCharacters(in: .whitespaces))
                LabeledContent("recall", value: Self.line("", variantMetrics.recall).trimmingCharacters(in: .whitespaces))
                LabeledContent("nDCG", value: Self.line("", variantMetrics.ndcg).trimmingCharacters(in: .whitespaces))
                LabeledContent("MRR", value: "\(variantMetrics.mrr.text)\(Self.basis(variantMetrics.mrr))")
                // Цена попадания: сколько знаков агент прочтёт на
                // один полезный результат. Меньше — лучше.
                LabeledContent(
                    String(localized: "Знаков на полезный"),
                    value: Self.line("", variantMetrics.charactersPerUseful, scale: .characters).trimmingCharacters(in: .whitespaces)
                )
                if let latency = variantMetrics.searchLatency {
                    LabeledContent(String(localized: "Поиск"), value: latency.line)
                }
                if let latency = variantMetrics.embeddingLatency {
                    LabeledContent(
                        String(localized: "Вектор запроса"),
                        value: String(localized: "\(latency.line) (посчитан \(RussianCount.phrase(latency.samples, "раз", "раза", "раз")))")
                    )
                }
            } header: {
                Text(variantMetrics.variantName)
            } footer: {
                VStack(alignment: .leading) {
                    ForEach(variantMetrics.truncatedKs, id: \.self) { k in
                        if let note = variantMetrics.note(for: k) {
                            Notice(.warning, note)
                        }
                    }
                    if let reason = Self.firstReason(variantMetrics) {
                        Text("«—» значит «неприменима»: \(reason)")
                    }
                    if variantMetrics.coverage.isComplete {
                        Text(variantMetrics.coverage.line)
                    } else {
                        Notice(.warning, variantMetrics.coverage.line + String(localized: " — метрики предварительные"))
                    }
                }
            }
        }
    }

    private var divergentSection: some View {
        let rows = model.rows
        let divergent = EvaluationReport.mostDivergent(rows)
        let shown = model.showAllQueries ? rows : divergent
        return Section {
            if !rows.isEmpty {
                Toggle(String(localized: "Показывать все запросы"), isOn: $model.showAllQueries)
            }
            if shown.isEmpty {
                Text(model.showAllQueries
                     ? "Запросов нет."
                     : "Расхождений нет: на всех запросах варианты повели себя одинаково либо судить не по чему — разметки не хватает.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(shown) { row in
                    VStack(alignment: .leading) {
                        Text(row.text).bold().lineLimit(2)
                        // Имена берутся из прогона, а не из плана на экране:
                        // у открытого сохранённого прогона план пуст.
                        ForEach(Array(zip((model.lastRun?.variants ?? []).map(\.name), row.outcomes)), id: \.0) { name, outcome in
                            outcomeLine(name: name, outcome: outcome)
                        }
                    }
                }
            }
        } header: {
            Text(model.showAllQueries ? "Все запросы" : "Где варианты разошлись сильнее всего")
        }
    }

    /// «Не нашёл» — предупреждение: это вывод о варианте. «Не размечено» —
    /// серым: это отсутствие вывода, и красить его как провал значило бы
    /// обвинять вариант в том, чего никто не проверял.
    @ViewBuilder
    private func outcomeLine(name: String, outcome: EvaluationReport.QueryOutcome) -> some View {
        let text = "\(name): \(outcome.text)"
        switch outcome {
        case .found: Text(text)
        case .missed: StatusLabel(.warning, text)
        case .unmarked: Text(text).foregroundStyle(.secondary)
        case .failed: StatusLabel(.error, text)
        }
    }

    private var comparisonSection: some View {
        Section {
            Picker(String(localized: "Сравнить с прогоном"), selection: Binding(
                get: { model.comparisonRunID },
                set: { model.selectComparison($0, app: app) }
            )) {
                Text("не сравнивать").tag(UUID?.none)
                ForEach(model.runs.filter { $0.id != model.lastRun?.id }) { summary in
                    Text(summary.name).tag(UUID?.some(summary.id))
                }
            }
            if let comparison = model.comparison {
                ForEach(comparison.variants) { item in
                    VStack(alignment: .leading) {
                        Text(item.variantName).bold()
                        ForEach(item.deltas) { delta in
                            if delta.before != nil || delta.after != nil {
                                deltaLine(delta)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Сравнение")
        } footer: {
            if let comparison = model.comparison,
               !comparison.onlyInBefore.isEmpty || !comparison.onlyInAfter.isEmpty {
                Notice(.warning, "Сопоставлены только варианты с совпадающим именем."
                       + (comparison.onlyInBefore.isEmpty ? "" : " Только в «\(comparison.before)»: \(comparison.onlyInBefore.joined(separator: ", ")).")
                       + (comparison.onlyInAfter.isEmpty ? "" : " Только в «\(comparison.after)»: \(comparison.onlyInAfter.joined(separator: ", ")).")
                )
            }
        }
    }

    /// Без вердикта — обычным цветом. «Не изменилось» это не «не улучшилось».
    @ViewBuilder
    private func deltaLine(_ delta: EvaluationReport.MetricDelta) -> some View {
        let text = "\(delta.title): \(delta.beforeText) → \(delta.afterText)"
            + (delta.changeText.map { " (\($0))" } ?? "")
        switch delta.improved {
        case true?: StatusLabel(.ok, text).monospacedDigit()
        case false?: StatusLabel(.warning, text).monospacedDigit()
        default: Text(text).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    // MARK: - Оценка чат-моделью

    /// Необязательный режим, выключенный по умолчанию. Стоит **после** отчёта:
    /// оценка модели — подсказка разметчику, а не источник чисел в таблице.
    private var judgeSection: some View {
        Section {
            Toggle(String(localized: "Оценивать чат-моделью"), isOn: Binding(
                get: { app.settings.configuration.modelJudgeEnabled },
                set: { enabled in
                    app.settings.configuration.modelJudgeEnabled = enabled
                    Task { await model.updateJudgeCost(app) }
                }
            ))
            if app.settings.configuration.modelJudgeEnabled {
                judgeSettings
            }
        } header: {
            SectionHeader(
                String(localized: "Оценка чат-моделью"),
                help: String(localized: "Модель проходит по каждому результату каждого варианта и говорит, отвечает ли он на запрос. Это подсказка для разметки, а не разметка: в эталон и в метрики оценка модели не попадает — её можно только принять вручную.")
            )
        } footer: {
            // Причина провала — **всегда**, а не только когда оценки есть:
            // «модель не ответила на 40 из 40» и ноль оценок — одно событие
            //.
            if let set = model.judgements {
                VStack(alignment: .leading) {
                    if !set.judgements.isEmpty { Text(set.line) }
                    if !set.note.isEmpty { Notice(.warning, set.note) }
                }
            }
        }
    }

    @ViewBuilder
    private var judgeSettings: some View {
        Picker(String(localized: "Модель"), selection: Binding(
            get: { app.settings.configuration.modelJudgeModel },
            set: { newValue in
                app.settings.configuration.modelJudgeModel = newValue
                Task { await model.updateJudgeCost(app) }
            }
        )) {
            Text("не выбрана").tag(String?.none)
            ForEach(model.chatModels) { item in
                Text(item.id).tag(Optional(item.id))
            }
        }

        DisclosureGroup(isExpanded: $showingJudgePrompt) {
            TextEditor(text: Binding(
                get: { app.settings.configuration.modelJudgePrompt.text },
                set: { app.settings.configuration.modelJudgePrompt.text = $0 }
            ))
            .font(.body.monospaced())
            .textArea()
            Text("Подстановки \(JudgePrompt.queryPlaceholder) и \(JudgePrompt.documentPlaceholder) обязательны. Форма ответа задана схемой и не редактируется: разбор ответа написан ровно под неё.")
                .foregroundStyle(.secondary)
            if let problem = app.settings.configuration.modelJudgePrompt.problem {
                Notice(.warning, problem)
            }
            if !app.settings.configuration.modelJudgePrompt.isDefault {
                Button(String(localized: "Вернуть исходный промпт")) {
                    app.settings.configuration.modelJudgePrompt = JudgePrompt()
                }
            }
        } label: {
            Text("Промпт оценки").togglesDisclosure($showingJudgePrompt)
        }
        // Промпт входит в отпечаток оценки: правленый — это новые вызовы.
        .onChange(of: app.settings.configuration.modelJudgePrompt.fingerprint) { _, _ in
            Task { await model.updateJudgeCost(app) }
        }

        if let cost = model.judgeCost {
            LabeledContent(String(localized: "Стоимость")) {
                Text(cost.line).copyable(cost.line)
            }
            if cost.isLong {
                Notice(.warning, String(localized: "Пока идёт оценка, локальная модель занята: синхронизация, чанкинг и поиск встанут в очередь за ней."))
            }
        }

        if let progress = model.judgeProgress {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                Text(progress.line)
            }
        }

        HStack {
            if let cost = model.judgeCost, cost.calls == 0, cost.alreadyJudged > 0, !model.isJudging {
                // «Ещё не считали» — не то же самое, что «нечего делать».
                Text("Всё оценено этой редакцией промпта. Правка промпта делает оценки заново.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isJudging {
                Button(String(localized: "Остановить")) { model.cancelJudgement() }
                    .help(String(localized: "Отмена сохраняет уже полученные оценки."))
            }
            Button(String(localized: "Оценить моделью…")) { Task { await model.requestJudgement(app) } }
                .disabled(model.isJudging
                          || app.settings.configuration.modelJudgeModel == nil
                          || (model.judgeCost?.calls ?? 0) == 0)
        }
    }

    // MARK: - Разметка

    /// Выдачи вариантов рядом — разметка прямо здесь.
    private func markingPane(_ run: EvaluationRun) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading) {
                // Фактическое число вызовов эмбеддинга — часть подписи: сравнить
                // его с оценкой должно быть возможно и через месяц.
                Text(run.line + String(localized: " · вызовов эмбеддинга: \(run.embeddingCalls)"))
                    .foregroundStyle(.secondary)
                if !run.note.isEmpty {
                    Notice(.warning, run.note)
                }
                HStack {
                    Text("Отметка уходит в эталон набора как фрагмент найденного текста.")
                        .foregroundStyle(.secondary)
                    InfoButton(String(localized: "Отметка «релевантен / частично / нерелевантен» уходит в эталон набора как фрагмент найденного текста — она переживёт перенарезку и будет работать для других вариантов. Повторное нажатие той же оценки снимает её."))
                }
            }
            .padding()
            Divider()

            // LazyVStack, а не VStack: прогон из пяти вариантов по десять
            // результатов — это двести ячеек, и обычный стек строит их все
            // до первого показа. Одна прокрутка обеих осей на всю
            // панель: иначе ленивый стек не ленив вовсе.
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(run.queries) { query in
                        VStack(alignment: .leading, spacing: 6) {
                            // Место под две строки — всегда, и ширина по
                            // сетке.
                            Text(query.text).font(.body).bold()
                                .lineLimit(2, reservesSpace: true)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: Self.gridWidth(for: run), alignment: .leading)
                            // Теги и фильтр — что искать в выдаче:
                            // «факт» ждёт одного значения, «раздел» — целого
                            // куска, а фильтр говорит, где искал поиск.
                            // Комментарий запроса сюда не идёт: в нём ответ,
                            // и разметка по нему перестаёт быть слепой.
                            let hint = Self.queryHint(query)
                            Text(hint)
                                .font(.subheadline).foregroundStyle(.secondary)
                                .lineLimit(1)
                                .help(hint)
                                .frame(width: Self.gridWidth(for: run), height: Self.queryHintHeight, alignment: .leading)
                            // Варианты — колонками рядом.
                            comparisonGrid(run: run, query: query)
                            Divider().frame(width: Self.gridWidth(for: run))
                        }
                        // Высота блока закреплена: ленивый список
                        // оценивает высоту ещё не построенного, и прокрутка
                        // вверх перескакивала.
                        .frame(height: blockHeight(run: run, query: query), alignment: .topLeading)
                    }
                }
                .padding()
                // Место под полосы прокрутки: полосы рисуются поверх
                // содержимого и накрывали значок «показать в источнике».
                .padding(.trailing, Self.scrollerClearance)
                .padding(.bottom, Self.scrollerClearance)
            }
            // Сетка уже панели стоит у левого края, а не посередине.
            .defaultScrollAnchor(.topLeading)
            // Панель занимает всё место под шапкой: разметка идёт здесь, и на
            // большом экране она обязана быть большой.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Ячейка разметки

    /// Оценка модели у одного результата — рядом с кнопками разметки, но
    /// заметно другой: курсив, серым, со словом «модель». Спутать её с
    /// собственной отметкой человека нельзя.
    @ViewBuilder
    private func judgementRow(queryID: UUID, variantID: UUID, hit: EvaluationHit) -> some View {
        if let judgement = model.judgement(queryID: queryID, variantID: variantID, hit: hit) {
            let accepted = model.grade(queryID: queryID, variantID: variantID, hit: hit) == judgement.grade
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("модель: \(judgement.grade.title)")
                        .font(.caption).italic()
                        .foregroundStyle(.secondary)
                    if accepted {
                        Text("принято").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("принять") {
                            model.acceptJudgement(judgement, hit: hit, app: app)
                        }
                        .buttonStyle(.borderless).controlSize(.small)
                    }
                }
                if !judgement.reason.isEmpty {
                    Text(judgement.reason)
                        .font(.caption).italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Сколько строк результатов у этого запроса — столько, сколько у самого
    /// длинного варианта: пустые ячейки держат колонку.
    static func rowCount(run: EvaluationRun, query: EvaluationQuery) -> Int {
        run.variants
            .map { run.result(query: query.id, variant: $0.id)?.hits.count ?? 0 }
            .max() ?? 0
    }

    /// Подпись запроса — ровно две строки, всегда. 32 pt при кегле
    /// `.body`; сторож меряет.
    static let queryTitleHeight: CGFloat = 32
    /// Строка тегов и фильтра под подписью — одна строка `.subheadline`.
    static let queryHintHeight: CGFloat = 14

    /// Теги и фильтр запроса одной строкой.
    static func queryHint(_ query: EvaluationQuery) -> String {
        let tags = query.tags.isEmpty
            ? String(localized: "без тегов")
            : String(localized: "теги: \(query.tags.joined(separator: ", "))")
        let filter = query.filter?.summary.map { String(localized: "фильтр: \($0)") }
            ?? String(localized: "без фильтра")
        return tags + " · " + filter
    }
    /// Промежуток внутри блока и между рядами сетки — одно число, и оно
    /// стоит в обоих местах разметки.
    static let blockSpacing: CGFloat = 6
    static let dividerHeight: CGFloat = 1

    /// Высота блока одного запроса.
    ///
    /// **Складывается из уже закреплённого, а не подбирается.** Высота строки
    /// и шапки закреплены с и проверены замером настоящей разметки;
    /// подпись занимает две строки; остальное — промежутки и разделитель.
    /// Поэтому число здесь точное: ленивому списку больше нечего угадывать,
    /// и прокрутка вверх перестала дёргаться назад.
    ///
    /// Мнение модели делает строку выше — и правило здесь **то же самое**,
    /// что у самой строки: высота одна на весь прогон, как только у него
    /// появился набор мнений.
    ///
    /// Первая редакция считала иначе — спрашивала мнение по каждой ячейке,
    /// — и на прогоне, где модель оценила три ряда из десяти, блок выходил
    /// на четыреста точек короче своих же строк и наезжал на соседний.
    /// Два правила для одной высоты — это и есть ошибка; правило одно.
    private func blockHeight(run: EvaluationRun, query: EvaluationQuery) -> CGFloat {
        let rows = CGFloat(Self.rowCount(run: run, query: query))
        let grid = Self.headerHeight(for: run)
            + rows * (Self.blockSpacing + Self.rowHeight(judged: model.judgements != nil))
        return Self.queryTitleHeight + Self.blockSpacing
            + Self.queryHintHeight + Self.blockSpacing
            + grid + Self.blockSpacing + Self.dividerHeight
    }

    // MARK: - Ровные ряды

    /// Высота строки результата — одна на весь прогон.
    ///
    /// Ленивый список судит о высоте ещё не построенных запросов по
    /// построенным. Пока строки разной высоты, эта оценка расходится
    /// с действительностью, и прокрутка подпрыгивает — та же беда, что
    /// чинили в для текста, но этажом выше.
    ///
    /// Числа — из замера настоящей строки, а не из головы: 114 pt это
    /// подпись с длиной куска, пять строк текста и ряд оценок; 172 pt — то же
    /// плюс мнение модели с тремя строками причины (системные стили
    /// `.caption` и `.subheadline`, переключатели-кнопки). Сторож —
    /// `ResultRowHeightTests`: он собирает строку и меряет.
    static func rowHeight(judged: Bool) -> CGFloat { judged ? 172 : 114 }

    /// Высота шапки колонки — тоже одна на прогон.
    ///
    /// Оговорка про метаданные бывает только у прогонов, записанных до того,
    /// как их стали сохранять, — то есть либо у всех колонок прогона, либо ни
    /// у одной. Место под неё держится по прогону целиком, чтобы ряды не
    /// разъезжались на тех запросах, где она есть.
    static func headerHeight(for run: EvaluationRun) -> CGFloat {
        let needsNote = run.results.contains { result in
            !result.hits.isEmpty && result.hits.allSatisfy { $0.metadata == nil }
        }
        return needsNote ? 62 : 32
    }

    /// Ширина сетки вариантов.
    ///
    /// Ею же ограничены подпись запроса и разделитель: без этого длинный
    /// запрос растягивал содержимое панели шире сетки, и при прокрутке до
    /// него дёргалась горизонталь.
    static func gridWidth(for run: EvaluationRun) -> CGFloat {
        let columns = max(1, run.variants.count)
        return CGFloat(columns) * columnWidth + CGFloat(columns - 1) * 12
    }

    /// Сколько места оставлено полосам прокрутки панели.
    ///
    /// Накладная полоса macOS — 15 pt вместе с отбивкой от края; 18 оставляет
    /// зазор, по которому видно, что значок не прижат к ней вплотную.
    static let scrollerClearance: CGFloat = 18

    /// Ширина колонки варианта. Одна на весь экран: колонки стоят рядом,
    /// и разной ширины у них быть не может.
    ///
    /// Число не произвольное: колонка обязана вмещать строку разметки целиком
    ///. Тройка «релевантен / частично / нерелевантен» в капсулах — это
    /// 318 pt, плюс три промежутка по 4 и значок «показать в источнике». При
    /// 340 pt значок не помещался и уезжал за край колонки — видна была его
    /// половина, а нажать было не на что. Сторож — `ComparisonAlignmentTests`:
    /// он считает нужную ширину по настоящим метрикам шрифта.
    private static let columnWidth: CGFloat = 372

    /// Выдачи вариантов **сеткой**, а не стопкой колонок.
    ///
    /// Сравнивают по строкам: «что у всех на четвёртом месте». В стопке
    /// независимых колонок четвёртая строка одного варианта стоит напротив
    /// шестой у соседнего — текст у результатов разной высоты, и колонки
    /// разъезжаются тем сильнее, чем ниже смотришь. `Grid` выравнивает
    /// ячейки одной строки по самой высокой, и номера снова стоят друг
    /// напротив друга.
    private func comparisonGrid(run: EvaluationRun, query: EvaluationQuery) -> some View {
        let results = run.variants.map { run.result(query: query.id, variant: $0.id) }
        let rows = results.map { $0?.hits.count ?? 0 }.max() ?? 0
        return Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(run.variants.enumerated()), id: \.element.id) { index, variant in
                    columnHeader(run: run, variant: variant, result: results[index])
                }
            }
            ForEach(0..<rows, id: \.self) { position in
                GridRow {
                    ForEach(Array(run.variants.enumerated()), id: \.element.id) { index, variant in
                        if let hits = results[index]?.hits, position < hits.count {
                            let hit = hits[position]
                            resultRow(
                                queryID: query.id, queryText: query.text,
                                variantID: variant.id, hit: hit
                            )
                            .frame(width: Self.columnWidth, alignment: .topLeading)
                        } else {
                            // Пустая ячейка держит колонку: без неё соседние
                            // съезжают влево и сравнивать снова нечего.
                            Color.clear.frame(width: Self.columnWidth, height: 1)
                        }
                    }
                }
            }
        }
    }

    /// Шапка колонки: чей это вариант и чем кончился его поиск.
    private func columnHeader(run: EvaluationRun, variant: EvaluationVariant, result: EvaluationResult?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(variant.name).font(.subheadline).bold()
            if let failure = result?.failure {
                StatusLabel(.error, failure).font(.subheadline)
            } else if let result {
                Text(Self.timing(result)).font(.subheadline).foregroundStyle(.secondary)
                // Один раз на столбец, а не у каждого результата: причина
                // общая для всего прогона, и повторять её двадцать раз —
                // это шум, из-за которого её перестают читать.
                if !result.hits.isEmpty, result.hits.allSatisfy({ $0.metadata == nil }) {
                    Text("Прогон записан до того, как метаданные стали сохраняться: перехода к исходнику по нему нет. Прогоните набор заново.")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if result.hits.isEmpty {
                    Text("ничего не найдено").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Text("не выполнялся").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.columnWidth, height: Self.headerHeight(for: run), alignment: .topLeading)
    }

    /// Один результат с тремя кнопками — разметка прямо в отчёте.
    ///
    /// Здесь и нигде больше: главная проблема оценки в том, что эталона нет и
    /// размечать его скучно. Первый прогон и есть инструмент его создания.
    private func resultRow(
        queryID: UUID, queryText: String, variantID: UUID, hit: EvaluationHit
    ) -> some View {
        let grade = model.grade(queryID: queryID, variantID: variantID, hit: hit)
        // Готовый текст карточки, а не посчитанный здесь: `body` вызывается
        // на каждую отметку, а перебор всей выдачи стоил 695 мс.
        let card = model.card(queryID: queryID, variantID: variantID, hit: hit, query: queryText)
        return VStack(alignment: .leading, spacing: 3) {
            // Длина куска и уровень — прежде текста. На иерархической
            // коллекции родитель и его первый ребёнок начинаются одинаково, и
            // без этой строки два варианта выглядят одним и тем же результатом.
            Text(Self.rankLine(hit, card))
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1)
            // Место под пять строк — всегда, даже если текст короче (
            //).
            // Плавающая высота строки — это и есть «скачет при прокрутке»:
            // ленивый список оценивает высоту ещё не построенных кусков, и
            // каждая построенная строка сдвигает всё, что ниже.
            //
            // Показывается окрестность совпадения с запросом, а не начало
            // куска: начало у родителя и ребёнка одно и то же.
            Text(card.snippet)
                .font(.subheadline)
                .lineLimit(5, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                ForEach(RelevanceGrade.allCases) { candidate in
                    // Названия оценок не сокращаются никогда: «релеван…» и
                    // «нерелева…» отличаются четырьмя буквами в начале.
                    gradeButton(candidate, chosen: grade == candidate) {
                        model.mark(queryID: queryID, variantID: variantID, hit: hit, grade: candidate, app: app)
                    }
                }
                if grade == nil {
                    // Ужимается первым: то же самое видно по тому, что ни
                    // одна из трёх кнопок не подсвечена.
                    Text("не размечено")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).layoutPriority(-1)
                }
                Spacer(minLength: 4)
                // Размечать, не видя исходника, — гадание: чанк вырван из
                // документа, и понять, отвечает ли он на запрос, часто можно
                // только на месте.
                //
                // Кнопки нет вовсе, если исходник по этому результату не
                // найти. Неактивная кнопка с подсказкой не годится: подсказка
                // у выключенной кнопки не всплывает — проверено в окне, —
                // и человек видит серую надпись без единого объяснения.
                if !(hit.text ?? "").isEmpty && hit.metadata != nil {
                    // Значок, а не подпись: столбец варианта узкий и его
                    // ширина задана сравнением, а не этой кнопкой — со словами
                    // «в документе» названия оценок переносились на две строки.
                    Button {
                        viewer.open(
                            chunk: hit.text ?? "",
                            metadata: hit.metadata,
                            title: hit.id,
                            app: app
                        )
                    } label: {
                        Label(String(localized: "Показать фрагмент в исходном документе"), systemImage: "doc.text.magnifyingglass")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless).controlSize(.small)
                    .help(String(localized: "Показать фрагмент в исходном документе"))
                }
            }
            judgementRow(queryID: queryID, variantID: variantID, hit: hit)
        }
        .padding(.vertical, 3)
        // Высота — одна на весь прогон. Ленивый список судит о ещё
        // не построенных запросах по построенным, и пока строки разной
        // высоты, прокрутка подпрыгивает.
        .frame(height: Self.rowHeight(judged: model.judgements != nil), alignment: .topLeading)
    }

    /// Кнопка оценки: выбранная залита цветом своей оценки, остальные —
    /// обычные. Системные стили: `.borderedProminent` с цветом
    /// оценки и `.bordered` без него — выбранное видно с первого взгляда, а не
    /// по оттенку надписи. Повторное нажатие той же оценки снимает её — так
    /// устроен `mark`.
    @ViewBuilder
    private func gradeButton(_ candidate: RelevanceGrade, chosen: Bool, action: @escaping () -> Void) -> some View {
        let button = Button(candidate.title, action: action)
            .controlSize(.small)
            .fixedSize()
        if chosen {
            button
                .buttonStyle(.borderedProminent)
                .tint(Self.tint(candidate))
        } else {
            button
                .buttonStyle(.bordered)
        }
    }

    /// Заголовок строки результата: номер позиции и, если есть что сказать,
    /// длина куска с его уровнем.
    ///
    /// Номер — **всегда**, даже у результата без текста: колонки сравнивают
    /// по строкам, и «что у всех на четвёртом месте» невозможно спросить,
    /// если четвёртое место не подписано. Текст результата необязателен
    /// (`RetrievalHit.document` — `String?`), и прежняя строка это учитывала.
    static func rankLine(_ hit: EvaluationHit, _ card: EvaluationPreview.Card) -> String {
        guard let shape = card.shape else { return "\(hit.position)." }
        return "\(hit.position). \(shape)"
    }

    private static func tint(_ grade: RelevanceGrade) -> Color {
        switch grade {
        case .relevant: return .green
        case .partial: return .orange
        case .irrelevant: return .red
        }
    }

    // MARK: - Строки метрик

    private static func line(
        _ title: String, _ scores: [Int: MetricScore], scale: EvaluationReport.Scale = .ratio
    ) -> String {
        let parts = scores.keys.sorted().map { k in "@\(k) \(scale.text(scores[k]?.value))" }
        let queries = scores.values.compactMap { $0.value != nil ? $0.queries : nil }.max()
        let basis = queries.map { " · на \(RussianCount.phrase($0, "запросе", "запросах", "запросах"))" } ?? ""
        return "\(title) " + parts.joined(separator: " · ") + basis
    }

    private static func basis(_ score: MetricScore) -> String {
        guard score.value != nil else { return "" }
        return " · на \(RussianCount.phrase(score.queries, "запросе", "запросах", "запросах"))"
    }

    private static func firstReason(_ metrics: VariantMetrics) -> String? {
        let scores = Array(metrics.hitRate.values) + Array(metrics.recall.values)
            + Array(metrics.ndcg.values) + [metrics.mrr] + Array(metrics.charactersPerUseful.values)
        return scores.first { $0.value == nil && $0.reason != nil }?.reason
    }

    private static func timing(_ result: EvaluationResult) -> String {
        var parts: [String] = []
        if let seconds = result.embeddingSeconds {
            parts.append(String(localized: "вектор \(Int(seconds * 1000)) мс"))
        } else if result.reusedVector {
            parts.append(String(localized: "вектор переиспользован"))
        }
        parts.append(String(localized: "поиск \(Int(result.searchSeconds * 1000)) мс"))
        parts.append(RussianCount.phrase(result.hits.count, "результат", "результата", "результатов"))
        return parts.joined(separator: " · ")
    }
}
