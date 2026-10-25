import SwiftUI
import ChromaCore

struct CollectionsView: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var schemaStore: SchemaStore
    @ObservedObject var model: CollectionsViewModel
    @ObservedObject var embeddingsModel: EmbeddingsViewModel
    @ObservedObject var reembedding: ReembeddingViewModel
    /// Просьба открыть лист «Новая коллекция» извне — из строки меню (⌘N).
    /// Флагом, а не счётчиком: экран может появиться уже после просьбы, и
    /// тогда её надо подхватить при появлении, а не при изменении.
    @Binding var newCollectionRequested: Bool
    /// Активно ли окно: от этого зависит, каким цветом система залила
    /// выбранную строку списка, — а значит, и каким цветом писать по ней.
    /// Открытая сторона выбранной коллекции.
    @State private var tab: CollectionTab = .documents
    /// Ширина колонки списка — по ней поле поиска в тулбаре.
    @State private var listColumnWidth: CGFloat = 260
    /// Капсула тулбара добавляет поля по краям: столько отнимается от ширины
    /// колонки, чтобы капсула кончалась у её края, а не заходила за него.
    private static let searchFieldInset: CGFloat = 36
    @State private var isCreatingCollection = false
    /// просмотр исходника — своё состояние экрана, а не раздел меню.
    @StateObject private var viewer = DocumentViewerViewModel()
    /// D3, K1: инспектор живёт своим состоянием — прогон длится и после того,
    /// как окно закрыли и открыли снова.
    @StateObject private var inspector = InspectorViewModel()
    /// перенос коллекции пакетом.
    @StateObject private var transfer = TransferViewModel()

    @State private var metadataEditorID: String?
    @State private var metadataDraft = MetadataDraft()
    /// Документ, у которого правят теги и заметку, и сами поля.
    @State private var marksEditorID: String?
    /// Коллекция этого документа, когда он пришёл не из открытой.
    @State private var marksEditorCollection: String?
    /// Редактор позвали из выдачи, а не из списка документов: рисовать его
    /// надо у результата, иначе он открывается там, куда человек не смотрит.
    @State private var marksEditorFromHit = false
    @State private var marksTags = ""
    @State private var marksNote = ""
    /// Выбранные строки таблицы документов.
    @State private var selectedDocumentIDs: Set<String> = []
    /// Инспектор документа справа (тип Б): подробности выбранной строки.
    @SceneStorage("collections.inspector") private var showsInspector = true
    /// Порядок, ширины и видимость колонок документов — помнит окно (v3).
    @SceneStorage("table.documents.v11") private var documentColumns: TableColumnCustomization<DocumentRecord>
    @State private var showingFilter = false
    @State private var documentsToDelete: [DocumentRecord] = []
    /// Результаты, у которых раскрыты метаданные.
    @State private var hitsWithMetadata: Set<String> = []
    @State private var confirmingHistoryClear = false
    @State private var confirmingSchemaDeletion = false
    /// Удаление профиля поиска — с подтверждением: его настройки
    /// человек подбирал сам, и вернуть их нечем.
    @State private var confirmingProfileDeletion = false
    /// Удаление коллекции без копии в корзине ждёт подтверждения.
    @State private var confirmingDeleteWithoutTrash = false

    var body: some View {
        // Свой список в разделе — `SectionSplit`, а не третья колонка
        // навигации: список коллекций слева, выбранная коллекция справа.
        SectionSplit {
            collectionListColumn
        } detail: {
            // Тулбар — у детали, а не у всего экрана: macOS 26 делит
            // тулбар по колонкам, и повешенный на экран целиком он
            // доставался колонке списка.
            detail
                .toolbar { collectionToolbar }
        }
        .task {
            await model.refresh(app)
            if embeddingsModel.models.isEmpty {
                await embeddingsModel.checkConnection(app, probeUnknownModels: false)
            }
            model.applyPendingRequest(app)
        }
        // Синхронизация источника создаёт коллекции и меняет числа документов
        // в них. Пока экран открыт, он показывал бы прежние числа до тех пор,
        // пока его не переоткроют.
        .onChange(of: app.collectionsRevision) { _, _ in
            Task { await model.refreshIfStale(app) }
        }
        // Просьба извне могла прийти после того, как список уже загрузился
        //: из строки меню, из «Служб», из интента.
        .onChange(of: model.pendingSelectionName) { _, _ in model.applyPendingRequest(app) }
        .onChange(of: model.pendingSearchTab, initial: true) { _, wanted in
            guard wanted else { return }
            tab = .search
            model.pendingSearchTab = false
        }
        .onChange(of: model.pendingImportText) { _, _ in model.applyPendingRequest(app) }
        .onChange(of: model.documentIDToReveal) { _, identifier in
            // «Показать существующий» opens that row rather than leaving the
            // user to find it in the list.
            guard let identifier else { return }
            tab = .documents
            selectedDocumentIDs = [identifier]
            showsInspector = true
            model.documentIDToReveal = nil
        }
        .sheet(isPresented: $model.showAddDocumentSheet) { documentSheet }
        .sheet(isPresented: $model.showBindSheet) { bindSheet }
        .sheet(isPresented: $model.showDeleteSheet) { deleteSheet }
        .sheet(isPresented: $model.showResetSheet) { resetSheet }
        .sheet(isPresented: $model.showImportSheet) { importSheet }
        .sheet(isPresented: $model.showProfileEditor) { profileSheet }
        .sheet(isPresented: $isCreatingCollection) { createCollectionSheet }
        .sheet(isPresented: $showingFilter) { filterSheet }
        .sheet(isPresented: Binding(
            get: { metadataEditorID != nil },
            set: { if !$0 { metadataEditorID = nil } }
        )) { metadataSheet }
        // Теги и заметка из таблицы документов; у выдачи поиска — свой
        // редактор рядом с результатом (до перевода вкладки «Поиск»).
        .sheet(isPresented: Binding(
            get: { marksEditorID != nil && !marksEditorFromHit },
            set: { if !$0 { marksEditorID = nil; marksEditorCollection = nil } }
        )) { marksSheet }
        .confirmationDialog(
            documentsToDelete.count == 1
                ? String(localized: "Удалить документ?")
                : String(localized: "Удалить документы: \(documentsToDelete.count.plainDigits)?"),
            isPresented: Binding(get: { !documentsToDelete.isEmpty }, set: { if !$0 { documentsToDelete = [] } }),
            titleVisibility: .visible,
            presenting: documentsToDelete
        ) { chosen in
            Button(String(localized: "Удалить"), role: .destructive) {
                Task {
                    for document in chosen { await model.deleteDocument(document, app: app) }
                    selectedDocumentIDs = []
                }
            }
            Button(String(localized: "Отменить"), role: .cancel) {}
        } message: { _ in
            Text(settings.configuration.trashEnabled
                 ? String(localized: "Документы уйдут в корзину — их можно будет вернуть.")
                 : String(localized: "Корзина выключена — удаление необратимо."))
        }
        .onAppear { takeNewCollectionRequest() }
        .onChange(of: newCollectionRequested) { _, _ in takeNewCollectionRequest() }
        .sheet(isPresented: $model.showExportSheet) {
            TransferSheet(
                model: transfer, mode: .export, collection: model.selected,
                currentFilter: model.filter, onClose: { model.showExportSheet = false }
            )
        }
        .sheet(isPresented: $model.showImportPackageSheet) {
            TransferSheet(
                model: transfer, mode: .importing, collection: model.selected,
                currentFilter: nil,
                onClose: {
                    model.showImportPackageSheet = false
                    // Импорт добавил документы, а то и целую коллекцию. Без
                    // этого список остаётся с прежними числами до следующего
                    // случайного обновления, и человек видит, что импорта
                    // будто не было.
                    Task { await model.refresh(app) }
                }
            )
        }
        .sheet(isPresented: Binding(
            get: { viewer.request != nil },
            set: { if !$0 { viewer.close() } }
        )) {
            DocumentViewerSheet(model: viewer)
        }
        .sheet(isPresented: Binding(
            get: { reembedding.request != nil },
            set: { if !$0 { reembedding.cancelSetup() } }
        )) {
            ReembeddingSheet(model: reembedding, embeddings: embeddingsModel, collectionsModel: model)
        }
    }

    /// Сообщения экрана — строкой над содержимым выбранной коллекции.
    @ViewBuilder
    private var banners: some View {
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

    // MARK: - Список коллекций

    /// Список коллекций — системный `List(selection:)`.
    ///
    /// Выбор идёт через `select(_:app:)`: всё, что относится к выбранной
    /// коллекции, — выключатель умного поиска, профили, фильтры, выдача, —
    /// обязано смениться вместе с ней.
    /// Поиск коллекций — над их списком, а не в тулбаре: в тулбаре
    /// он стоял рядом с вкладками выбранной коллекции и читался как поиск
    /// по её документам.
    /// Поиск коллекций — в полосе тулбара над их списком: тулбар
    /// macOS 26 делится по колонкам, и поле, повешенное на колонку списка,
    /// встаёт над ней, а не рядом с вкладками коллекции, где оно читалось
    /// как поиск по документам. Своя строка поиска под тулбаром
    /// давала вторую линию, не совпадавшую с линией соседней колонки.
    private var collectionListColumn: some View {
        VStack(spacing: 0) {
            collectionList
            listFooter
        }
        // Поле поиска — ровно по ширине колонки: элемент тулбара
        // своей ширины не знает, а колонку тянут мышью.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listColumnWidth = $0 }
        // Своё поле, а не `.searchable`: системное встаёт к правому краю окна,
        // над выбранной коллекцией, и сдвигает её действия.
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(String(localized: "Найти коллекцию"), text: $model.collectionSearch)
                        .textFieldStyle(.plain)
                    if !model.collectionSearch.isEmpty {
                        Button {
                            model.collectionSearch = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "Очистить поиск"))
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: max(120, listColumnWidth - Self.searchFieldInset))
                .help(String(localized: "Поиск по именам коллекций"))
            }
        }
    }

    private var collectionList: some View {
        List(selection: Binding(
            get: { model.selectedID },
            set: { id in
                guard let id, id != model.selectedID,
                      let collection = model.collections.first(where: { $0.id == id }) else { return }
                model.selectedID = id
                Task { await model.select(collection, app: app) }
            }
        )) {
            ForEach(model.visibleCollections(app)) { collection in
                collectionRow(collection)
                    .tag(collection.id)
            }
        }
        .overlay {
            if model.visibleCollections(app).isEmpty && !model.isLoadingCollections {
                // «Ничего не нашлось» и «коллекций нет» — разные сообщения:
                // первое про строку поиска, второе про базу.
                if model.collections.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "Коллекций нет"), systemImage: "square.stack.3d.up")
                    } description: {
                        Text("Создайте первую кнопкой «+» внизу или добавьте источник — он создаст её сам.")
                    }
                } else {
                    ContentUnavailableView.search(text: model.collectionSearch)
                }
            }
        }
    }

    private func takeNewCollectionRequest() {
        guard newCollectionRequested else { return }
        newCollectionRequested = false
        if app.connection.isConnected { isCreatingCollection = true }
    }

    /// Подвал списка: «+» — новая коллекция; в меню — то, что относится ко
    /// всей базе: порядок списка, обновить, сбросить базу.
    private var listFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button {
                    isCreatingCollection = true
                } label: {
                    Label(String(localized: "Новая коллекция…"), systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(!app.connection.isConnected)
                .help(String(localized: "Новая коллекция…"))

                Menu {
                    Picker(String(localized: "Порядок"), selection: Binding(
                        get: { app.settings.configuration.collectionListOrder },
                        set: { app.settings.configuration.collectionListOrder = $0 }
                    )) {
                        ForEach(CollectionListOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button(String(localized: "Обновить список")) {
                        Task { await model.refresh(app) }
                    }
                    .disabled(!app.connection.isConnected)
                    Divider()
                    Button(String(localized: "Сбросить базу…"), role: .destructive) {
                        model.showResetSheet = true
                    }
                    .disabled(!app.connection.isConnected)
                } label: {
                    Label(String(localized: "Ещё"), systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(String(localized: "Порядок списка, обновить список, сбросить базу"))

                Spacer()
                if model.isLoadingCollections { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal)
            .padding(.vertical)
        }
    }

    /// Строка списка: имя и одна строка фактов, обе в одну строку (v3).
    /// Модель коллекции — в шапке справа; здесь остаётся только её
    /// отсутствие — это уже состояние, значком у имени.
    private func collectionRow(_ collection: ChromaCollection) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(collection.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !collection.isBound {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel(String(localized: "модель не указана"))
                }
            }
            Text(shortFacts(collection))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .monospacedDigit()
        }
        .help(collection.isBound
              ? "\(collection.name)\n\(rowFacts(collection))"
              : "\(collection.name)\n\(rowFacts(collection))\n" + String(localized: "модель не указана"))
        // Имя обрезано посередине, и выделять его мышью нельзя: строка занята
        // выбором. Остаётся правая кнопка.
        .copyable(collection.name)
    }

    /// «355 · 768 · cosine» — коротко, чтобы не обрезалось в узком списке;
    /// метрика всегда на виду рядом с числами: расстояния разных метрик
    /// несравнимы.
    private func shortFacts(_ collection: ChromaCollection) -> String {
        var parts = [collection.documentCount.map { $0.formatted() } ?? "?"]
        if let dimension = collection.effectiveDimension { parts.append(dimension.plainDigits) }
        parts.append(collection.space?.shortTitle ?? "?")
        return parts.joined(separator: " · ")
    }

    /// «9 418 записей · dim 2 560 · cosine» — полностью, в подсказке строки.
    private func rowFacts(_ collection: ChromaCollection) -> String {
        var parts = [collection.documentCount.map {
            RussianCount.grouped($0, "запись", "записи", "записей")
        } ?? String(localized: "записей: ?")]
        if let dimension = collection.effectiveDimension { parts.append("dim \(dimension)") }
        parts.append(collection.space?.shortTitle ?? String(localized: "метрика неизвестна"))
        return parts.joined(separator: " · ")
    }

    /// Создание коллекции — лист: модель и метрику потом не сменить.
    private var createCollectionSheet: some View {
        SheetForm(
            cancel: { isCreatingCollection = false },
            confirmTitle: String(localized: "Создать"),
            confirmDisabled: !app.connection.isConnected || model.isCreating || model.nameProblem != nil
                || model.newCollectionName.trimmingCharacters(in: .whitespaces).isEmpty,
            isWorking: model.isCreating,
            confirm: {
                Task {
                    await model.createCollection(app)
                    // Имя очищается только после удачного создания — по нему
                    // и видно, закрывать ли лист.
                    if model.newCollectionName.isEmpty { isCreatingCollection = false }
                }
            }
        ) {
            Section {
                TextField(String(localized: "Имя"), text: $model.newCollectionName, prompt: Text(verbatim: "a-z, 0-9, ._-"))
            } header: {
                SectionHeader(
                    String(localized: "Новая коллекция"),
                    help: String(localized: "Коллекция — это набор документов с общими векторами. Модель определяет, чем эти векторы считаются: сравнивать можно только векторы одной модели, поэтому сменить её у готовой коллекции нельзя. Метрика — способ измерять расстояние между векторами; она задаётся при создании индекса и тоже не меняется.")
                )
            } footer: {
                // Что не так — пока имя набирают, и названо правило.
                if let problem = model.nameProblem {
                    Notice(.warning, problem)
                }
            }
            Section {
                Picker(String(localized: "Модель"), selection: $model.newCollectionModel) {
                    Text(String(localized: "без модели")).tag("")
                    ForEach(embeddingsModel.embeddingModels) { item in
                        Text(item.id).tag(item.id)
                    }
                }
                Picker(String(localized: "Метрика"), selection: $model.newCollectionMetric) {
                    ForEach(DistanceMetric.allCases) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
            } footer: {
                Text(model.newCollectionModel.isEmpty
                     ? String(localized: "Без модели коллекцию можно читать, но нельзя пополнять и искать: векторы считает приложение.")
                     : model.newCollectionMetric.explanation)
            }
            // Свёрнуто: эти три меняют устройство индекса, а пустое поле
            // значит «решает сервер».
            AdvancedSection(screen: "collection.index", title: String(localized: "Параметры индекса")) {
                indexField("ef_construction", text: $model.draftEFConstruction)
                indexField("ef_search", text: $model.draftEFSearch)
                indexField("max_neighbors", text: $model.draftMaxNeighbors)
                Text("Пустое поле — значение выбирает сервер. Больше max_neighbors и ef_construction — точнее поиск, но индекс тяжелее и запись медленнее.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func indexField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text, prompt: Text("по умолчанию"))
            .font(.body.monospaced())
    }

    // MARK: - Detail

    /// Ход и итог пересчёта — строками над экраном, рядом с коллекцией, о
    /// которой они. Не в корневом VStack экрана: вставленные туда, они после
    /// пересчёта оставляли окно пустым (NavigationSplitView переставал рисовать).
    @ViewBuilder
    private var reembeddingCards: some View {
        let visible = reembedding.errorMessage != nil || reembedding.infoMessage != nil
            || reembedding.isRunning || reembedding.report != nil
        if visible {
            VStack(alignment: .leading) {
                if let error = reembedding.errorMessage {
                    HStack {
                        Notice(.warning, error)
                        Spacer()
                        Button(String(localized: "Скрыть")) { reembedding.errorMessage = nil }
                            .buttonStyle(.borderless)
                    }
                }
                if let message = reembedding.infoMessage {
                    HStack {
                        Notice(.info, message)
                        Spacer()
                        Button(String(localized: "Скрыть")) { reembedding.infoMessage = nil }
                            .buttonStyle(.borderless)
                    }
                }
                if reembedding.isRunning {
                    ReembeddingProgressRow(model: reembedding)
                }
                if let report = reembedding.report {
                    ReembeddingReportRow(report: report)
                }
            }
            .padding()
            Divider()
        }
    }

    /// Имя действующего профиля поиска — для вопроса перед удалением.
    private var activeProfileName: String {
        model.profiles.first { $0.id == model.activeProfileID }?.name ?? String(localized: "По умолчанию")
    }

    @ViewBuilder
    private var detail: some View {
        if let collection = model.selected {
            VStack(spacing: 0) {
                banners
                collectionHeader(collection)
                Divider()
                if tab == .documents {
                    documentsScreen(collection)
                } else if tab == .search {
                    searchScreen(collection)
                } else if tab == .overview {
                    insightsScreen(collection)
                } else {
                    metadataScreen(collection)
                }
            }
            // Инспектор документа — у всей детали, а не у таблицы:
            // приделанный к таблице, он начинался под шапкой коллекции,
            // и его серая колонка обрывалась на середине высоты.
            .fittingInspector(isPresented: Binding(
                get: { showsInspector && tab == .documents },
                set: { showsInspector = $0 }
            )) {
                Group {
                    if let document = inspectedDocument {
                        documentInspector(document)
                    } else {
                        InspectorPlaceholder(selectedDocumentIDs.count > 1
                            ? String(localized: "Выбрано несколько документов.")
                            : String(localized: "Выберите строку в таблице."))
                    }
                }
            }
        } else {
            VStack(spacing: 0) {
                banners
                reembeddingCards
                ContentUnavailableView {
                    Label(String(localized: "Выберите коллекцию"), systemImage: "square.stack.3d.up")
                } description: {
                    Text("Документы, поиск и правила относятся к одной коллекции.")
                }
            }
        }
    }

    /// Действия выбранной коллекции — в тулбаре у правого края.
    ///
    /// Основные действия macOS ставит к левому краю тулбара, а левый край
    /// здесь — над списком коллекций: четыре значка выбранной коллекции
    /// читались как действия списка. Действия всех коллекций — внизу списка.
    ///
    /// **Состав тулбара не зависит от выбора**. Элементы стояли под
    /// `if let collection`, и удаление коллекции снимало их все — выбор на
    /// миг становился пустым — и тут же вставляло заново для следующей.
    /// AppKit при этом оставлял в тулбаре прежний экземпляр: имя коллекции
    /// и её факты появлялись второй раз справа, а кнопки уезжали в меню переполнения «>>».
    /// Теперь элементы есть всегда; без выбранной коллекции заголовок пуст,
    /// а действия гаснут — как и на вкладках, где неприменимое гаснет, а не
    /// исчезает.
    @ToolbarContentBuilder
    private var collectionToolbar: some ToolbarContent {
        let collection = model.selected
        // Имя и факты коллекции — в полосе тулбара, слева: строка
        // над содержимым освобождается, и коллекция названа на одном
        // уровне со своими действиями. Без стеклянной подложки — это
        // заголовок, а не кнопка.
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .automatic) { collectionTitleSlot(collection) }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .automatic) { collectionTitleSlot(collection) }
        }
        // К правому краю, над выбранной коллекцией: основные действия
        // macOS ставит к левому, а левый край здесь — над списком.
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }
        ToolbarItemGroup(placement: .automatic) {
            // Набор кнопок один на всех вкладках — неприменимое гаснет,
            // а не исчезает: иначе тулбар перестраивался при каждом
            // переключении вкладки.
            Button {
                showingFilter = true
            } label: {
                Label(String(localized: "Фильтр…"),
                      systemImage: model.appliedFilterDescription == nil
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill")
            }
            .help(String(localized: "Фильтр по метаданным"))
            .disabled(collection == nil || (tab != .documents && tab != .search))
            // Переключатель, а не кнопка: состояние видно по нему
            // самому.
            Toggle(isOn: $showsInspector) {
                Label(String(localized: "Инспектор"), systemImage: "sidebar.right")
            }
            .toggleStyle(.button)
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help(String(localized: "Показать или скрыть инспектор"))
            .disabled(collection == nil || tab != .documents)
            Button {
                model.beginAddingDocument(app)
            } label: {
                // Не «+»: плюс внизу списка — новая коллекция, и два одинаковых
                // значка с разным смыслом путались.
                Label(String(localized: "Добавить документ…"), systemImage: "doc.badge.plus")
            }
            .disabled(collection?.isBound != true)
            .help(String(localized: "Добавить документ…"))

            // Значков — не больше трёх, остальное в меню (v3).
            Menu {
                // Пункты вкладок — здесь, а не в самой вкладке (v6): набор
                // меню один на все вкладки, неприменимое гаснет.
                Toggle(String(localized: "История запросов"), isOn: Binding(
                    get: { model.showHistory },
                    set: { shown in
                        model.showHistory = shown
                        if shown { model.reloadHistory(app) }
                    }
                ))
                .disabled(tab != .search)
                Menu(String(localized: "Экспорт отчёта о темах")) {
                    Button(String(localized: "Markdown…")) { inspector.exportTopics(markdown: true, app: app) }
                    Button(String(localized: "JSON…")) { inspector.exportTopics(markdown: false, app: app) }
                }
                .disabled(tab != .overview || inspector.topicReport == nil)
                Divider()
                Button(collection?.isBound == true
                       ? String(localized: "Модель: \(collection?.boundModel ?? "не указана")…")
                       : String(localized: "Указать модель…")) {
                    model.bindModelSelection = collection?.boundModel ?? settings.configuration.defaultEmbeddingModel ?? ""
                    model.showBindSheet = true
                }
                Button(String(localized: "Пересчитать векторы…")) {
                    if let collection { reembedding.begin(collection: collection, app: app) }
                }
                .disabled(collection?.isBound != true || (collection?.documentCount ?? 0) == 0)
                Button(String(localized: "Импорт CSV или JSON…")) { model.chooseImportFile(app) }
                    .disabled(collection?.isBound != true)
                Divider()
                Button(String(localized: "Экспорт коллекции…")) { model.showExportSheet = true }
                Button(String(localized: "Импорт пакета .chromaexport…")) { model.showImportPackageSheet = true }
                Divider()
                Button(String(localized: "Удалить коллекцию…"), role: .destructive) {
                    model.deleteConfirmationText = ""
                    model.deleteTooBig = nil
                    model.deleteError = nil
                    model.showDeleteSheet = true
                }
            } label: {
                Label(String(localized: "Действия с коллекцией"), systemImage: "ellipsis.circle")
            }
            .help(String(localized: "Модель, пересчёт векторов, импорт, экспорт, удаление коллекции"))
            .disabled(collection == nil)
        }
    }

    /// Место заголовка в тулбаре: имя коллекции или пусто, пока она не
    /// выбрана, — сам элемент остаётся на месте.
    @ViewBuilder
    private func collectionTitleSlot(_ collection: ChromaCollection?) -> some View {
        if let collection {
            collectionTitle(collection)
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    /// Третий уровень текста: устройство раздела целиком, свёрнуто.
    ///
    /// Оба факта здесь — о необратимом, и оба взяты из дизайн-макета: модель
    /// и метрика выбираются один раз на всю жизнь коллекции.
    /// Третий уровень текста для экранов-форм коллекции.
    private var collectionsHowItWorks: some View {
        HowItWorks(screen: "collections", String(localized: "Модель привязана к коллекции навсегда: векторы, посчитанные разными моделями, несравнимы. Чтобы сравнить другую модель или стратегию, коллекцию клонируют — «Модели» → «Пересчёт векторов». Метрику нельзя изменить после создания — только пересоздать коллекцию; косинусная подходит почти всем эмбеддинг-моделям. Документы читаются страницами по сто: у ChromaDB нет курсора, и порядок выдачи между страницами не гарантирован."))
    }

    /// Фильтр действует и на документы, и на поиск — значит на обеих
    /// вкладках о нём должна быть строка. Иначе человек смотрит на выдачу
    /// и не знает, почему в ней сорок документов вместо десяти тысяч.
    @ViewBuilder
    private var appliedFilterNote: some View {
        if let description = model.appliedFilterDescription {
            HStack {
                Label {
                    Text("Фильтр: \(description)")
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(description)
                } icon: {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "Изменить…")) { showingFilter = true }
                Button(String(localized: "Сбросить")) {
                    Task { await model.clearFilter(app) }
                }
            }
            .padding(.horizontal)
            .padding(.vertical)
        }
    }

    /// Шапка выбранной коллекции: имя и одна строка фактов. Действия —
    /// в тулбаре; служебные поля — на «Обзоре» под «Для опытных».
    ///
    /// Имя берут руками чаще, чем кажется: выделение мышью **и**
    /// «Скопировать» в правой кнопке — имя длиной в экран обрезано
    /// посередине, а скопировать надо целиком.
    /// Имя и одна строка фактов — в тулбаре.
    private func collectionTitle(_ collection: ChromaCollection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(collection.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .copyable(collection.name)
            Text(collectionFactLine(collection))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .copyable(collectionFactLine(collection))
        }
        .frame(maxWidth: 520, alignment: .leading)
        .help(Text(verbatim: "\(collection.name)\n\(collectionFactLine(collection))"))
    }

    private func collectionHeader(_ collection: ChromaCollection) -> some View {
        VStack(alignment: .leading) {
            if !collection.isBound {
                Notice(.warning, String(localized: "Коллекция создана не этим приложением: неизвестно, какой моделью посчитаны её векторы. Укажите модель — приложение сверит только размерность."))
            }
            // Вкладки — под именем коллекции, а не в тулбаре над ним:
            // сначала «какая коллекция», потом «что в ней смотреть».
            Picker(String(localized: "Вкладка коллекции"), selection: $tab) {
                ForEach(CollectionTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    /// Служебные поля коллекции — `_cdbm_*`, хэш нарезки, `hnsw:space` и id:
    /// их читают, когда что-то не сходится, и не читают в остальное время.
    private func serviceFields(_ collection: ChromaCollection) -> some View {
        AdvancedSection(screen: "collection.metadata", title: String(localized: "Служебные поля")) {
            LabeledContent(String(localized: "id")) {
                Text(collection.id)
                    .font(.body.monospaced())
                    .copyable(collection.id)
                    .copyable(collection.id)
            }
            ForEach((collection.metadata ?? [:]).keys.sorted(), id: \.self) { key in
                let value = collection.metadata?[key]?.displayString ?? ""
                LabeledContent(key) {
                    Text(value)
                        .font(.body.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .copyable(value)
                        .help(value)
                }
            }
        }
    }

    /// «Обзор» и «Темы» коллекции — формой: секции инспектора.
    private func insightsScreen(_ collection: ChromaCollection) -> some View {
        VStack(spacing: 0) {
            reembeddingCards
            Form {
                InspectorTabs(
                    model: inspector, collection: collection, only: .overview,
                    // Значение фасета уводит в документы с готовым
                    // фильтром (K1 → A9).
                    applyFacetFilter: { field, value in
                        model.filter = DocumentFilter(conditions: [
                            MetadataCondition(field: field, equals: value)
                        ])
                        tab = .documents
                        Task { await model.applyFilter(app) }
                    }
                )
                // Темы — тоже о содержании: о чём коллекция (v3).
                InspectorTabs(
                    model: inspector, collection: collection,
                    only: .topics, applyFacetFilter: { _, _ in }
                )
                InspectorTabs(
                    model: inspector, collection: collection, only: .checks,
                    showsMessages: false,
                    applyFacetFilter: { _, _ in }
                )
                Section { collectionsHowItWorks }
            }
            .formStyle(.grouped)
            .toggleStyle(.switch)
        }
    }

    /// Одна строка о коллекции: сколько записей, какой размерности, какой
    /// метрикой и какой моделью. Из макета — ровно в этом порядке.
    private func collectionFactLine(_ collection: ChromaCollection) -> String {
        var parts: [String] = []
        parts.append(collection.documentCount.map { count in
            RussianCount.grouped(count, "запись", "записи", "записей")
        } ?? String(localized: "число записей неизвестно"))
        if let dimension = collection.effectiveDimension {
            parts.append(String(localized: "размерность \(dimension.plainDigits)"))
        }
        parts.append(collection.space.map(\.shortTitle)
                     ?? String(localized: "метрика неизвестна"))
        parts.append(collection.boundModel ?? String(localized: "модель не указана"))
        return parts.joined(separator: " · ")
    }

    // MARK: - Filter

    // MARK: - Поиск

    /// «Поиск» — форма: запрос и его параметры, история, отчёт, диагностика
    /// и по секции на каждый результат.
    private func searchScreen(_ collection: ChromaCollection) -> some View {
        VStack(spacing: 0) {
            reembeddingCards
            appliedFilterNote
            Form {
                querySection(collection)
                if model.showHistory { historySection(collection) }
                // До первого запроса под формой не пусто, а сказано, что здесь
                // будет (v6).
                if model.hits.isEmpty, model.searchReports.isEmpty, model.searchSummary == nil,
                   model.lastRetrieval == nil, !model.isQuerying {
                    Section {
                        ContentUnavailableView {
                            Label(String(localized: "Введите запрос"), systemImage: "magnifyingglass")
                        } description: {
                            Text("Найденные документы появятся здесь — с оценкой близости и местом в исходном файле.")
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                if !model.searchReports.isEmpty || model.searchSummary != nil { collectionsReport }
                if let diagnostics = model.lastRetrieval {
                    diagnosticsSection(diagnostics)
                }
                // Ключ — коллекция **и** идентификатор: поиск по нескольким
                // коллекциям держит одинаковые идентификаторы из разных
                // коллекций отдельными результатами.
                ForEach(Array(model.hits.enumerated()), id: \.element.listKey) { index, hit in
                    hitSection(hit, index: index, collection: collection)
                }
            }
            .formStyle(.grouped)
        }
        .confirmationDialog(
            String(localized: "Очистить историю запросов?"),
            isPresented: $confirmingHistoryClear,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Очистить"), role: .destructive) { model.clearHistory(app) }
            Button(String(localized: "Отменить"), role: .cancel) {}
        } message: {
            Text("Закреплённые и отмеченные для стенда запросы тоже будут удалены.")
        }
    }

    private func querySection(_ collection: ChromaCollection) -> some View {
        Section {
            // Enter выполняет запрос. Поле многострочное, и
            // Return у него уходит не туда, куда ждёшь; замерено:
            // Return и Shift+Return доходят до `onSubmit` без переноса,
            // перенос строки даёт только Option+Return, а `onKeyPress`
            // видит Return раньше поля. Поэтому обработчика два; два запуска
            // разом отсекает `runQuery`.
            TextField(String(localized: "Запрос"), text: $model.queryText, prompt: Text("Текст запроса"), axis: .vertical)
                .labelsHidden()
                .lineLimit(2...5)
                .onKeyPress(phases: .down) { press in
                    guard press.key == .return,
                          press.modifiers.isDisjoint(with: [.option]) else { return .ignored }
                    guard !model.isQuerying, collection.isBound else { return .ignored }
                    Task { await model.runQuery(app) }
                    return .handled
                }
                .onSubmit {
                    guard !model.isQuerying, collection.isBound else { return }
                    Task { await model.runQuery(app) }
                }
                .help(String(localized: "Enter — выполнить запрос, Option+Enter — перенос строки."))

            Toggle(String(localized: "Умный поиск"), isOn: Binding(
                get: { model.smartSearchEnabled },
                set: { model.setSmartSearch($0, app: app) }
            ))
            .toggleStyle(.switch)
            .help(String(localized: "Выключенный конвейер — это обычный векторный поиск. Настройки профиля при этом сохраняются."))

            if model.smartSearchEnabled {
                LabeledContent(String(localized: "Профиль")) {
                    Picker(String(localized: "Профиль"), selection: Binding(
                        get: { model.activeProfileID },
                        set: { identifier in
                            guard let identifier else { return }
                            model.activateProfile(id: identifier, app: app)
                        }
                    )) {
                        ForEach(model.profiles) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                        if model.profiles.isEmpty {
                            // Профиль, которым ищут, пока никто ничего не
                            // настраивал. У него нет id: на диске его нет.
                            Text(String(localized: "По умолчанию")).tag(model.activeProfileID)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button(String(localized: "Настроить…")) { model.editActiveProfile(app) }
                    Menu {
                        Button(String(localized: "Новый профиль…")) { model.newProfile(app) }
                        Button(String(localized: "Дублировать действующий…")) { model.duplicateActiveProfile(app) }
                        Divider()
                        Button(String(localized: "Экспорт профилей…")) { model.exportProfiles(app) }
                        Button(String(localized: "Импорт профилей…")) { model.importProfiles(app) }
                        Divider()
                        Button(String(localized: "Удалить действующий профиль…"), role: .destructive) {
                            confirmingProfileDeletion = true
                        }
                        .disabled(model.profiles.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(String(localized: "Профили поиска"))
                    .accessibilityLabel(String(localized: "Профили поиска"))
                    .confirmationDialog(
                        String(localized: "Удалить профиль «\(activeProfileName)»?"),
                        isPresented: $confirmingProfileDeletion,
                        titleVisibility: .visible
                    ) {
                        Button(String(localized: "Удалить"), role: .destructive) { model.deleteActiveProfile(app) }
                        Button(String(localized: "Отменить"), role: .cancel) {}
                    } message: {
                        Text("Его настройки поиска пропадут. Документы коллекции не затронуты.")
                    }
                }
            }

            // Поле со стрелками, как все числа в формах (v6 A2).
            StepperRow(String(localized: "Результатов"), value: $model.numberOfResults, in: 1...RetrievalLimits.maximumResults)

            if !model.filter.isEmpty {
                Toggle(String(localized: "Применять фильтр"), isOn: $model.applyFilterToQuery)
                    .toggleStyle(.switch)
                    .help(String(localized: "Условия из фильтра применяются к запросу вместе с вектором."))
            }

            alsoSearchInRow(collection)

            HStack {
                // «История запросов» — в меню «⋯» тулбара (v6).
                Spacer()
                if model.isQuerying { ProgressView().controlSize(.small) }
                Button(String(localized: "Выполнить")) {
                    Task { await model.runQuery(app) }
                }
                .disabled(model.isQuerying || !collection.isBound)
                .help(String(localized: "Выполнить поиск (⌘↩)"))
            }
        } header: {
            SectionHeader(
                String(localized: "Запрос"),
                help: String(localized: "Текст превращается в вектор моделью коллекции, затем ищутся ближайшие документы. Конвейер умного поиска добавляет к этому текстовый поиск, иерархию, соседние чанки, разнообразие и переранжирование — по профилю.")
            )
        } footer: {
            if !collection.isBound {
                Notice(.warning, String(localized: "Запрос заблокирован: у коллекции не указана модель. Другой моделью выполнять его нельзя — результаты будут бессмысленными."))
            } else if !model.smartSearchEnabled {
                Text("Конвейер выключен: запрос идёт как обычный векторный поиск.")
            } else if model.lastRetrieval?.unchangedByProfile == true {
                // Прямо здесь, а не в свёрнутой диагностике: человек,
                // у которого галочка не меняет выдачу, ищет причину у неё.
                Notice(.info, String(localized: "Этот профиль не изменил выдачу: свёртка и подъём к разделу доступны только коллекции с двумя уровнями чанков, пометок в выдаче нет, а остальные стадии выключены. Разницу с обычным поиском дадут «Текстовый поиск», «Разнообразие» или «Соседние чанки» — они включаются в «Настроить…»."))
            } else if !model.alsoSearchIn.isEmpty {
                Text(multiModelNote(collection))
            }
        }
    }

    /// Какие коллекции ищутся вместе с открытой. Меню, а не список
    /// флажков: коллекций бывает два десятка, и поиск по одной — самый
    /// частый случай.
    @ViewBuilder
    private func alsoSearchInRow(_ collection: ChromaCollection) -> some View {
        let others = model.collections.filter { $0.name != collection.name }
        if !others.isEmpty {
            // «Где искать» — одним согласованным выбором (v6): только здесь, во
            // всех или в выбранных.
            let searchable = others.filter(\.isBound).map(\.name)
            // Считаются только существующие коллекции: в выборе могут
            // остаться имена удалённых.
            let chosen = model.alsoSearchIn.intersection(others.map(\.name))
            LabeledContent(String(localized: "Где искать")) {
                Menu(chosen.isEmpty
                     ? String(localized: "Только в этой коллекции")
                     : (!searchable.isEmpty && Set(searchable).isSubset(of: chosen)
                        ? String(localized: "Во всех коллекциях")
                        : String(localized: "В выбранных: \((chosen.count + 1).plainDigits)"))) {
                    Button(String(localized: "Только в этой коллекции")) { model.alsoSearchIn = [] }
                    Button(String(localized: "Во всех коллекциях")) { model.alsoSearchIn = Set(searchable) }
                        .disabled(searchable.isEmpty)
                    Divider()
                    ForEach(others, id: \.id) { other in
                        Toggle(isOn: Binding(
                            get: { model.alsoSearchIn.contains(other.name) },
                            set: { isOn in
                                if isOn { model.alsoSearchIn.insert(other.name) } else { model.alsoSearchIn.remove(other.name) }
                            }
                        )) {
                            // Коллекция без модели искать не может — это сказано
                            // в строке выбора, а не после запроса.
                            Text(other.isBound ? other.name : String(localized: "\(other.name) — нет модели"))
                        }
                        .disabled(!other.isBound)
                    }
                }
                .fixedSize()
                .help(([collection.name] + model.alsoSearchIn.sorted()).joined(separator: ", "))
            }
        }
    }

    /// Сколько моделей затронет запрос — столько раз и посчитается вектор.
    private func multiModelNote(_ collection: ChromaCollection) -> String {
        let names = Set([collection.name]).union(model.alsoSearchIn)
        let chosen = model.collections.filter { names.contains($0.name) }
        let models = Set(chosen.compactMap { $0.boundModel })
        let metrics = Set(chosen.compactMap { $0.space })
        var line = String(localized: "Ищем в: \(([collection.name] + model.alsoSearchIn.sorted()).joined(separator: ", ")). ")
        line += String(localized: "Вектор запроса считается по разу на модель: моделей \(models.count.plainDigits).")
        if metrics.count > 1 {
            line += String(localized: " Метрики у коллекций разные, поэтому порядок задаётся слиянием рангов, а не расстояниями.")
        }
        return line
    }

    /// Что ответила каждая коллекция: коллекция, не ответившая из-за
    /// ошибки, в общей выдаче выглядит ровно как пустая.
    private var collectionsReport: some View {
        Section {
            ForEach(model.searchReports, id: \.self) { report in
                if let failure = report.failure {
                    LabeledContent {
                        Text(failure)
                            .lineLimit(2)
                            .help(failure)
                    } label: {
                        StatusLabel(.error, report.name)
                    }
                } else {
                    LabeledContent {
                        Text("найдено \(report.found.plainDigits), \(Int((report.seconds * 1000).rounded()).plainDigits) мс")
                            .monospacedDigit()
                    } label: {
                        StatusLabel(.ok, report.name)
                    }
                }
            }
        } header: {
            Text(model.searchSummary ?? String(localized: "Коллекции"))
        }
    }

    /// Метрика коллекции, из которой пришёл результат.
    private func metric(of hit: RetrievalHit, current: ChromaCollection) -> DistanceMetric? {
        guard let name = hit.collectionName, name != current.name else { return current.space }
        return model.collections.first { $0.name == name }?.space ?? current.space
    }

    /// «Как получен этот результат»: что каждая стадия получила, что отдала,
    /// почему и сколько заняла. Свёрнуто: читать результат и объяснять его —
    /// разные задачи, и вторая реже.
    private func diagnosticsSection(_ diagnostics: RetrievalDiagnostics) -> some View {
        Section {
            DisclosureGroup(isExpanded: $model.showDiagnostics) {
                if let note = diagnostics.note {
                    Notice(.info, note)
                }
                if let embedding = diagnostics.embeddingLine {
                    LabeledContent(String(localized: "Вектор запроса"), value: embedding)
                }
                ForEach(diagnostics.stages.sorted { $0.stage.order < $1.stage.order }) { report in
                    stageRow(report, slowest: diagnostics.slowestStage)
                }
                LabeledContent {
                    Button(String(localized: "Скопировать")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diagnostics.plainText, forType: .string)
                    }
                    .help(String(localized: "Панель хранит только последний запрос — скопированный текст можно приложить к вопросу."))
                } label: {
                    Text(String(localized: "Всего: \(Int((diagnostics.totalDuration * 1000).rounded())) мс"))
                        .monospacedDigit()
                }
            } label: {
                LabeledContent(String(localized: "Как получен этот результат"), value: diagnostics.summary)
                    .togglesDisclosure($model.showDiagnostics)
            }
        }
    }

    /// Стадия: что получила, что вернула, сколько заняла и почему. Не
    /// сработавшая показана, а не спрятана: «почему не сработало» — вопрос,
    /// ради которого панель и есть.
    private func stageRow(_ report: RetrievalDiagnostics.StageReport, slowest: RetrievalStage?) -> some View {
        LabeledContent {
            if report.ran {
                Text(report.inputCount == report.outputCount
                     ? String(localized: "\(report.outputCount)")
                     : String(localized: "\(report.inputCount) → \(report.outputCount)"))
                    .monospacedDigit()
                Text(String(localized: "\(Int((report.duration * 1000).rounded())) мс"))
                    .monospacedDigit()
                    .foregroundStyle(report.stage == slowest ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            } else {
                // «Выключено» и «не выполнено» — разные новости.
                if report.failed {
                    StatusLabel(.warning, report.outcome.title)
                } else {
                    Text(report.outcome.title).foregroundStyle(.secondary)
                }
            }
        } label: {
            VStack(alignment: .leading) {
                Text("\(report.stage.order). \(report.stage.title)")
                if let note = report.note {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .foregroundStyle(report.ran || report.failed ? .primary : .secondary)
    }

    /// Один результат — своя секция: откуда он, насколько близок, его текст
    /// в окружении соседей, пометки и метаданные.
    private func hitSection(_ hit: RetrievalHit, index: Int, collection: ChromaCollection) -> some View {
        let record = DocumentRecord(id: hit.id, document: hit.document, metadata: hit.metadata)
        let metadataKey = hit.listKey
        return Section {
            // Соседи до совпадения — до него, после — после: блок читается
            // сплошным текстом с найденным фрагментом посередине.
            ForEach(neighbours(of: hit, before: true)) { attached in
                contextText(attached)
            }
            documentText(hit.document)
            ForEach(neighbours(of: hit, before: false)) { attached in
                contextText(attached)
            }
            // Родитель — рядом с совпадением, а не вместо него: это контекст,
            // а не то, по чему ранжировали.
            ForEach(hit.context.filter { $0.contextKind == .parent }) { attached in
                VStack(alignment: .leading) {
                    Text("контекст: родительский чанк")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    contextText(attached)
                }
            }
            // Результат, поглотивший три других, — результат, о котором
            // человек вправе знать.
            if let note = hit.collapsedNote {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
            if let matched = hit.matchedChunkID {
                Text(String(localized: "раздел целиком; совпал чанк \(matched)"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if model.showDiagnostics, let origin = hit.originNote {
                Text(origin).font(.callout).foregroundStyle(.tertiary)
            }
            marksLine(of: hit.metadata)
            // Редактор тегов — здесь же, у этого результата: строки документа
            // в списке может не быть вовсе.
            if marksEditorID == hit.id, marksEditorFromHit, marksEditorCollection == hit.collectionName {
                marksEditor(for: record, collectionName: hit.collectionName)
            }
            DisclosureGroup(isExpanded: Binding(
                get: { hitsWithMetadata.contains(metadataKey) },
                set: { shown in
                    if shown { hitsWithMetadata.insert(metadataKey) } else { hitsWithMetadata.remove(metadataKey) }
                }
            )) {
                ForEach((hit.metadata ?? [:]).keys.sorted(), id: \.self) { key in
                    let value = hit.metadata?[key]?.displayString ?? ""
                    LabeledContent(key) {
                        Text(value).lineLimit(2).truncationMode(.middle).copyable(value).help(value)
                    }
                    .font(.callout)
                }
            } label: {
                Text("Метаданные")
                    .togglesDisclosure(Binding(
                        get: { hitsWithMetadata.contains(metadataKey) },
                        set: { shown in
                            if shown { hitsWithMetadata.insert(metadataKey) } else { hitsWithMetadata.remove(metadataKey) }
                        }
                    ))
            }
            HStack {
                Spacer()
                // Пометить прямо из выдачи; результат из соседней
                // коллекции метится в ней самой.
                Menu(String(localized: "Пометить")) {
                    marksMenu(for: record, collectionName: hit.collectionName, fromHit: true)
                }
                .fixedSize()
                .help(String(localized: "Закрепить, понизить или пометить устаревшим"))
                // от найденного — к первоисточнику.
                Button(String(localized: "Показать в документе…")) {
                    viewer.open(
                        chunk: hit.document ?? "",
                        metadata: hit.metadata,
                        title: hit.metadata.flatMap { metadata in
                            DocumentLocator.reference(metadata: metadata).fileName
                        } ?? collection.name,
                        app: app
                    )
                }
                .disabled((hit.document ?? "").isEmpty)
            }
        } header: {
            HStack {
                Text("\(index + 1).")
                    .monospacedDigit()
                // Из какой коллекции результат — в многоколлекционном поиске
                // это первое, что нужно знать о находке.
                if !model.alsoSearchIn.isEmpty, let name = hit.collectionName {
                    Text(name).foregroundStyle(.secondary)
                }
                Text(hit.id)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                // Метрика — той коллекции, откуда результат.
                Text(hit.queryHit.distanceText(metric: metric(of: hit, current: collection)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } footer: {
            if index == 0, model.alsoSearchIn.isEmpty {
                // Шкала зависит от метрики — какой именно, сказано здесь.
                Text(collection.space.map { metric in
                    metric == .cosine
                        ? String(localized: "Метрика \(metric.shortTitle): рядом с расстоянием показана схожесть.")
                        : String(localized: "Метрика \(metric.shortTitle): показано сырое значение, в процентах его выразить нельзя.")
                } ?? String(localized: "Метрика коллекции неизвестна — значения показаны как есть, без интерпретации."))
            }
        }
    }

    /// Соседние чанки с одной стороны от совпадения, в порядке чтения.
    private func neighbours(of hit: RetrievalHit, before: Bool) -> [RetrievalHit] {
        guard let index = hit.chunkIndex else { return [] }
        return hit.context.filter {
            guard $0.contextKind == .neighbour, let position = $0.chunkIndex else { return false }
            return before ? position < index : position > index
        }
    }

    /// Приложенный текст — приглушённо: это то, что вокруг ответа.
    private func contextText(_ hit: RetrievalHit) -> some View {
        documentText(hit.document)
            .foregroundStyle(.tertiary)
    }

    /// Текст документа на экране — началом, без управляющих символов,
    /// двоичное — словами. Скопировать можно весь.
    @ViewBuilder
    private func documentText(_ text: String?) -> some View {
        let preview = DisplayText.preview(text)
        if preview.looksBinary {
            Notice(.warning, String(localized: "Похоже на двоичные данные, а не на текст: \(preview.totalCharacters.plainDigits) знаков, из них управляющих в начале — \(preview.controlCharacters.plainDigits). Скорее всего, файл попал в базу без извлечения текста: удалите документ или переиндексируйте источник."))
                .copyable(text ?? "")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(preview.text.isEmpty ? "—" : preview.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if preview.isTruncated {
                    Text("Показаны первые \(preview.text.count.plainDigits) из \(preview.totalCharacters.plainDigits) знаков; целиком — «Скопировать» в контекстном меню.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .copyable(text ?? "")
        }
    }

    private var profileSheet: some View {
        Group {
            if model.profileDraft != nil {
                SearchProfileSheet(
                    profile: Binding(
                        get: { model.profileDraft ?? SearchProfile(collectionName: "") },
                        set: { model.profileDraft = $0 }
                    ),
                    rerankModels: embeddingsModel.rerankModels.map(\.id),
                    rerankingTypedIDs: embeddingsModel.rerankingTypedIDs,
                    isHierarchical: model.selected?.looksHierarchical ?? false,
                    metric: model.selected?.space,
                    onCancel: {
                        model.showProfileEditor = false
                        model.profileDraft = nil
                    },
                    onSave: { model.saveProfileDraft(app) }
                )
            }
        }
    }

    /// Прошлые запросы коллекции: подставить, закрепить, отметить для
    /// набора стенда оценки. Последнее — смысл панели: двадцать показательных
    /// запросов руками не пишет никто, а набрал их уже каждый.
    private func historySection(_ collection: ChromaCollection) -> some View {
        Section {
            TextField(String(localized: "Поиск по истории"), text: $model.historySearch, prompt: Text("поиск по истории"))
                .onChange(of: model.historySearch) { _, _ in model.reloadHistory(app) }
            if model.history.isEmpty {
                Text("Здесь появятся запросы, которые вы выполняли к этой коллекции.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.history) { entry in
                LabeledContent {
                    Button(String(localized: "Подставить")) { model.restore(entry) }
                        .help(String(localized: "Запрос вернётся в поле вместе с фильтром. Выполнить его — отдельная кнопка."))
                    Menu {
                        Button(entry.isPinned ? String(localized: "Открепить") : String(localized: "Закрепить")) {
                            model.togglePinned(entry, app: app)
                        }
                        Button(entry.isChosenForEvaluation
                               ? String(localized: "Убрать из набора стенда")
                               : String(localized: "Отметить для набора стенда")) {
                            model.toggleChosenForEvaluation(entry, app: app)
                        }
                        Divider()
                        Button(String(localized: "Удалить из истории"), role: .destructive) {
                            model.removeFromHistory(entry, app: app)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(String(localized: "Закрепить, отметить для стенда, удалить"))
                    .accessibilityLabel(String(localized: "Действия с запросом"))
                } label: {
                    VStack(alignment: .leading) {
                        HStack {
                            if entry.isPinned {
                                Image(systemName: "pin.fill").foregroundStyle(.secondary)
                                    .accessibilityLabel(String(localized: "закреплён"))
                            }
                            if entry.isChosenForEvaluation {
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(.secondary)
                                    .accessibilityLabel(String(localized: "в наборе стенда"))
                            }
                            Text(entry.text).lineLimit(2)
                        }
                        Text("\(entry.line) · \(entry.ranAt.formatted(date: .abbreviated, time: .shortened))\(entry.filter != nil ? String(localized: " · с фильтром") : "")")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button(String(localized: "Очистить историю…"), role: .destructive) { confirmingHistoryClear = true }
                    .disabled(model.history.isEmpty)
            }
        } header: {
            Text("История")
        }
    }

    // MARK: - Documents

    /// Документы коллекции — карточка, как всё остальное на экране.
    ///
    /// Заголовок и число показанного — в шапке карточки, объяснение про
    /// листание — под «?», кнопка «Показать ещё» — в конце списка, где её и
    /// ищут. Раньше это был голый `VStack` без карточки, а объяснение про
    /// порядок страниц висело абзацем под кнопкой.
    // MARK: - Документы

    private var selectedDocuments: [DocumentRecord] {
        model.documents.filter { selectedDocumentIDs.contains($0.id) }
    }

    private var inspectedDocument: DocumentRecord? {
        let chosen = selectedDocuments
        return chosen.count == 1 ? chosen.first : nil
    }

    /// «Документы» — тип Б: таблица страницы документов, подробности
    /// выбранного — в инспекторе справа.
    private func documentsScreen(_ collection: ChromaCollection) -> some View {
        VStack(spacing: 0) {
            reembeddingCards
            appliedFilterNote
            // Листание limit/offset порядка не обещает; если коллекция
            // меняется под списком, это сказано.
            if let notice = model.contentChangedNotice {
                Notice(.warning, notice)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            documentsTable
                .overlay {
                    if model.documents.isEmpty && !model.isLoadingDocuments {
                        if model.appliedFilterDescription == nil {
                            ContentUnavailableView {
                                Label(String(localized: "Документов нет"), systemImage: "doc.text")
                            } description: {
                                Text("В коллекции пока нет документов.")
                            }
                        } else {
                            ContentUnavailableView {
                                Label(String(localized: "Ничего не нашлось"), systemImage: "line.3.horizontal.decrease.circle")
                            } description: {
                                Text("Под фильтр ничего не подошло.")
                            } actions: {
                                Button(String(localized: "Сбросить фильтр")) {
                                    Task { await model.clearFilter(app) }
                                }
                            }
                        }
                    }
                }
            documentsFooter(collection)
        }
        .onChange(of: selectedDocumentIDs) { _, _ in
            if let document = inspectedDocument {
                Task { await model.loadVector(for: document, app: app) }
            }
        }
    }

    private var documentsTable: some View {
        // Строки однострочные (v3): фрагмент — одной строкой, целиком — в
        // инспекторе и по наведению.
        Table(model.documents, selection: $selectedDocumentIDs, columnCustomization: $documentColumns) {
            TableColumn(String(localized: "ID")) { document in
                Text(document.id)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(document.id)
            }
            .width(min: 70, ideal: 130, max: 180)
            .customizationID("documents.id")
            TableColumn(String(localized: "Фрагмент")) { document in
                Text(document.preview)
                    .lineLimit(1)
                    .help(document.preview)
            }
            // Главная колонка — но с пределом: без него она забирала всё
            // свободное место, а ID и источник жались к минимуму.
            .width(min: 70, ideal: 240, max: 320)
            .customizationID("documents.фрагмент")
            TableColumn(String(localized: "Источник")) { document in
                let source = Self.source(of: document)
                Text(source.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "—")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(source ?? "")
            }
            .width(min: 60, ideal: 140, max: 240)
            .customizationID("documents.источник")
            TableColumn(String(localized: "Чанк")) { document in
                Text(document.metadata?["chunk_index"]?.displayString ?? "—")
                    .monospacedDigit()
            }
            .width(min: 40, ideal: 56, max: 100)
            .alignment(.numeric)
            .customizationID("documents.чанк")
            TableColumn(String(localized: "Токены")) { document in
                Text(document.metadata?["chunk_estimated_tokens"]?.displayString ?? "—")
                    .monospacedDigit()
            }
            .width(min: 52, ideal: 64, max: 100)
            .alignment(.numeric)
            .customizationID("documents.токены")
            // Значком (v5): слово «закреплён» в узкой колонке обрезалось.
            // Слово — в подсказке и для VoiceOver.
            TableColumn(String(localized: "Метка")) { document in
                if let mark = DocumentMarks(metadata: document.metadata).mark {
                    Image(systemName: Self.symbol(for: mark))
                        .foregroundStyle(.secondary)
                        .help(mark.title)
                        .accessibilityLabel(mark.title)
                }
            }
            // Постоянной ширины: заголовок целиком, а шире значку незачем.
            // «Метка», а не «Пометка»: на 900 pt таблице дорог каждый пункт.
            .width(52)
            .customizationID("documents.пометка")
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let chosen = model.documents.filter { ids.contains($0.id) }
            if chosen.count == 1, let document = chosen.first {
                Button(String(localized: "Изменить текст…")) { model.beginEditing(document, app: app) }
                Button(String(localized: "Изменить метаданные…")) {
                    metadataDraft = MetadataDraft(metadata: document.metadata)
                    metadataEditorID = document.id
                }
                Divider()
                marksMenu(for: document)
                Divider()
                Button(String(localized: "Скопировать ID")) { copy(document.id) }
            }
            if !chosen.isEmpty {
                Divider()
                Button(String(localized: "Удалить…"), role: .destructive) { documentsToDelete = chosen }
            }
        } primaryAction: { ids in
            selectedDocumentIDs = ids
            showsInspector = true
        }
        .onDeleteCommand { documentsToDelete = selectedDocuments }
        .copyable(selectedDocuments.map(\.id))
    }

    private func documentsFooter(_ collection: ChromaCollection) -> some View {
        TableFooter(
            model.appliedFilterDescription == nil
                ? String(localized: "Показано \(model.documents.count.formatted()) из \(collection.documentCount.map { $0.formatted() } ?? "?").")
                : String(localized: "Найдено по фильтру: \(model.documents.count.formatted())."),
            help: String(localized: "ChromaDB не гарантирует порядок выдачи при листании: если коллекция меняется, страницы могут повторяться или пропускаться. Для точной работы с конкретными документами пользуйтесь фильтром.")
        ) {
            if model.isLoadingDocuments { ProgressView().controlSize(.small) }
            if model.canLoadMore {
                Button(String(localized: "Показать ещё \(CollectionsViewModel.pageSize)")) {
                    Task { await model.loadDocuments(app, reset: false) }
                }
                .disabled(model.isLoadingDocuments)
            }
            Button {
                Task { await model.reloadCurrentPage(app) }
            } label: {
                Label(String(localized: "Обновить страницу"), systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(model.isLoadingDocuments || model.documents.isEmpty)
            .help(String(localized: "Обновить страницу"))
        }
    }

    /// Значок ручной пометки документа.
    private static func symbol(for mark: DocumentMark) -> String {
        switch mark {
        case .pinned: return "pin.fill"
        case .demoted: return "arrow.down.circle"
        case .stale: return "clock.badge.exclamationmark"
        }
    }

    private static func source(of document: DocumentRecord) -> String? {
        document.metadata?["source_file"]?.displayString ?? document.metadata?["file_name"]?.displayString
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Подробности документа: полный текст, пометки, метаданные, вектор.
    private func documentInspector(_ document: DocumentRecord) -> some View {
        let marks = DocumentMarks(metadata: document.metadata)
        return Form {
            // Действия над документом — в контекстном меню строки, здесь их
            // не дублируем (v3).
            Section {
                InspectorField(String(localized: "Идентификатор"), document.id, monospaced: true)
                    .copyable(document.id)
            }
            // Текст — своей секцией без подписи слева; длинный прокручивает
            // весь инспектор.
            Section {
                documentText(document.document)
            } header: {
                Text("Текст")
            }
            Section {
                LabeledContent(String(localized: "Пометка"), value: marks.mark?.title ?? String(localized: "нет"))
                if !marks.tags.isEmpty {
                    LabeledContent(String(localized: "Теги"), value: marks.tagsLine)
                }
                if let note = marks.note, !note.isEmpty {
                    InspectorField(String(localized: "Заметка"), note)
                }
            } header: {
                Text("Пометки")
            } footer: {
                Text("Теги видны агенту и годятся для фильтра по метаданным.")
            }
            Section {
                ForEach((document.metadata ?? [:]).keys.sorted(), id: \.self) { key in
                    InspectorField(key, document.metadata?[key]?.displayString ?? "")
                }
            } header: {
                Text("Метаданные")
            }
            if let vector = model.vectorPreviews[document.id] {
                Section {
                    LabeledContent(String(localized: "Размерность"), value: vector.count.formatted())
                    Text(vector.prefix(8).map { String(format: "%.4f", $0) }.joined(separator: ", ") + (vector.count > 8 ? ", …" : ""))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .copyable(vector.map { String($0) }.joined(separator: ", "))
                } header: {
                    Text("Вектор")
                } footer: {
                    Text("Первые восемь компонент — чтобы отличить модели на глаз.")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Ручные пометки

    /// Пункты меню для пометок одного документа.
    ///
    /// Пометка — переключатель: повторное нажатие снимает её. Отдельного
    /// «Снять» в меню нет — оно означало бы, что три пометки и снятие каждой
    /// это шесть пунктов там, где хватает трёх с галочкой.
    ///
    /// - Parameter collectionName: коллекция, откуда пришёл документ. При
    ///   поиске по нескольким она не совпадает с открытой, а пометка обязана
    /// лечь в ту же коллекцию, где человек её увидел.
    /// - Parameter fromHit: меню открыто у результата поиска, а не у строки
    ///   списка документов.
    @ViewBuilder
    private func marksMenu(
        for document: DocumentRecord, collectionName: String? = nil, fromHit: Bool = false
    ) -> some View {
        let marks = DocumentMarks(metadata: document.metadata)
        ForEach(DocumentMark.allCases) { mark in
            // Галочка у стоящей пометки: меню обязано показывать состояние,
            // а не только предлагать действие. Переключателем, а не «✓ »
            // в тексте: галочку меню ставит в свою колонку, и текст пункта
            // не сдвигается относительно соседей.
            Toggle(isOn: Binding(
                get: { marks.mark == mark },
                set: { _ in
                    Task {
                        await model.setMark(
                            mark, for: document, app: app, collectionName: collectionName
                        )
                    }
                }
            )) {
                Text(mark.actionTitle)
            }
        }
        Button(String(localized: "Теги и заметка…")) {
            marksEditorID = document.id
            marksEditorCollection = collectionName
            marksEditorFromHit = fromHit
            marksTags = marks.tagsLine
            marksNote = marks.note ?? ""
        }
    }

    /// Теги и заметка — у результата поиска, прямо под ним: строки этого
    /// документа в таблице может не быть вовсе.
    @ViewBuilder
    private func marksEditor(
        for document: DocumentRecord, collectionName: String? = nil
    ) -> some View {
        TextField(String(localized: "Теги"), text: $marksTags, prompt: Text("через запятую"))
        TextField(String(localized: "Заметка"), text: $marksNote, axis: .vertical)
            .lineLimit(1...4)
        HStack {
            Text("Теги видны агенту и годятся для фильтра по метаданным.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button(String(localized: "Отменить")) {
                marksEditorID = nil
                marksEditorCollection = nil
                marksEditorFromHit = false
            }
            Button(String(localized: "Сохранить")) {
                let tags = marksTags
                let note = marksNote
                marksEditorID = nil
                marksEditorCollection = nil
                marksEditorFromHit = false
                // Одной записью: два вызова подряд стёрли бы теги первого.
                Task {
                    await model.setTagsAndNote(
                        tags: tags, note: note, for: document, app: app,
                        collectionName: collectionName
                    )
                }
            }
        }
    }

    /// Что стоит на документе — одной строкой: пометка, теги, заметка.
    /// Текстом, не цветной плашкой.
    @ViewBuilder
    private func marksLine(of metadata: ChromaMetadata?) -> some View {
        let marks = DocumentMarks(metadata: metadata)
        if !marks.isEmpty {
            let parts = [marks.mark?.title, marks.tags.isEmpty ? nil : marks.tagsLine, marks.note]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            Label(parts.joined(separator: " · "), systemImage: "bookmark")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// Правка метаданных документа — без пересчёта вектора.
    @ViewBuilder
    private var metadataSheet: some View {
        if let id = metadataEditorID, let document = model.documents.first(where: { $0.id == id }) {
            SheetForm(
                cancel: { metadataEditorID = nil },
                confirmTitle: String(localized: "Сохранить"),
                confirm: {
                    Task {
                        await model.saveMetadataOnly(for: document, draft: metadataDraft, app: app)
                        metadataEditorID = nil
                    }
                }
            ) {
                Section {
                    ForEach($metadataDraft.rows) { $row in
                        if MetadataDraft.isReserved(row.key) {
                            LabeledContent(row.key) {
                                Text(row.value).foregroundStyle(.secondary)
                                Image(systemName: "lock")
                                    .foregroundStyle(.secondary)
                                    .help(String(localized: "Поле ведёт приложение: правка вручную сломала бы привязку модели"))
                            }
                        } else {
                            HStack {
                                TextField(String(localized: "ключ"), text: $row.key)
                                    .labelsHidden()
                                TextField(String(localized: "значение"), text: $row.value)
                                    .labelsHidden()
                                Button {
                                    metadataDraft.remove(row)
                                } label: {
                                    Label(String(localized: "Убрать поле"), systemImage: "minus.circle")
                                        .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.borderless)
                                .help(String(localized: "Убрать поле"))
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        Button(String(localized: "Добавить поле")) { metadataDraft.addRow() }
                    }
                } header: {
                    Text(verbatim: document.id)
                } footer: {
                    Text("Вектор не пересчитывается: меняются только метаданные.")
                }
            }
        }
    }

    /// Теги и заметка документа.
    @ViewBuilder
    private var marksSheet: some View {
        if let id = marksEditorID, let document = model.documents.first(where: { $0.id == id }) {
            SheetForm(
                cancel: { marksEditorID = nil; marksEditorCollection = nil },
                confirmTitle: String(localized: "Сохранить"),
                confirm: {
                    let tags = marksTags
                    let note = marksNote
                    let collectionName = marksEditorCollection
                    marksEditorID = nil
                    marksEditorCollection = nil
                    // Одной записью: два вызова подряд собирали бы пометки из
                    // метаданных, что были до правки, и второй стёр бы теги.
                    Task {
                        await model.setTagsAndNote(
                            tags: tags, note: note, for: document, app: app,
                            collectionName: collectionName
                        )
                    }
                }
            ) {
                Section {
                    TextField(String(localized: "Теги"), text: $marksTags, prompt: Text("через запятую"))
                    TextField(String(localized: "Заметка"), text: $marksNote, axis: .vertical)
                        .lineLimit(1...4)
                } header: {
                    Text(verbatim: document.id)
                } footer: {
                    Text("Теги видны агенту и годятся для фильтра по метаданным.")
                }
            }
        }
    }

    /// Фильтр по метаданным — листом: условия собираются в where-запрос
    /// ChromaDB, фильтрует сервер, а не приложение.
    private var filterSheet: some View {
        SheetForm(
            cancel: { showingFilter = false },
            confirmTitle: String(localized: "Применить"),
            confirm: {
                Task {
                    await model.applyFilter(app)
                    if model.filterErrorMessage == nil { showingFilter = false }
                }
            }
        ) {
            Section {
                if !model.savedFilters.isEmpty {
                    Menu(String(localized: "Сохранённые (\(model.savedFilters.count))")) {
                        ForEach(model.savedFilters) { saved in
                            Button(saved.name) { model.applySavedFilter(saved) }
                        }
                        Divider()
                        ForEach(model.savedFilters) { saved in
                            Button(String(localized: "Удалить «\(saved.name)»"), role: .destructive) {
                                model.deleteSavedFilter(saved, app: app)
                            }
                        }
                    }
                }
                LabeledContent(String(localized: "Сохранить как")) {
                    TextField(String(localized: "Сохранить как"), text: $model.savedFilterName, prompt: Text("имя фильтра"))
                        .labelsHidden()
                    Button(String(localized: "Сохранить")) { model.saveCurrentFilter(app) }
                        .fixedSize()
                        .disabled(model.filter.isEmpty || model.savedFilterName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Фильтры коллекции")
            }

            if !model.filter.usesRawJSON {
                Section {
                    FilterNodeEditor(
                        node: $model.filter.root,
                        knownFields: model.filterFieldSuggestions(app),
                        depth: 0,
                        onRemove: nil
                    )
                } header: {
                    SectionHeader(
                        String(localized: "Метаданные"),
                        help: String(localized: "Условия собираются в where-запрос ChromaDB — фильтрует сервер, а не приложение.")
                    )
                }
                Section {
                    DocumentTextConditionsEditor(
                        conditions: $model.filter.textConditions,
                        logic: $model.filter.textLogic
                    )
                } header: {
                    Text("Текст документа")
                }
            }

            AdvancedSection(screen: "collection.filter") {
                Toggle(String(localized: "Редактировать как JSON"), isOn: Binding(
                    get: { model.filter.usesRawJSON },
                    set: { if $0 != model.filter.usesRawJSON { model.toggleFilterJSONMode() } }
                ))
                if model.filter.usesRawJSON {
                    TextField(String(localized: "where"), text: $model.filter.rawWhereJSON,
                              prompt: Text(verbatim: #"{"$and": [{"n": {"$gt": 10}}]}"#), axis: .vertical)
                        .font(.body.monospaced())
                        .lineLimit(1...6)
                    TextField(String(localized: "where_document"), text: $model.filter.rawWhereDocumentJSON,
                              prompt: Text(verbatim: #"{"$not_contains": "черновик"}"#), axis: .vertical)
                        .font(.body.monospaced())
                        .lineLimit(1...4)
                } else {
                    // Оба условия, как их получит сервер: и по метаданным, и
                    // по тексту документа.
                    if let json = model.filter.whereJSONString() {
                        Text(json)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .copyable(json)
                    }
                    if let json = model.filter.whereDocumentJSONString() {
                        Text(json)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .copyable(json)
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button(String(localized: "Сбросить фильтр")) {
                        Task {
                            await model.clearFilter(app)
                            showingFilter = false
                        }
                    }
                    .disabled(model.filter.isEmpty && model.appliedFilterDescription == nil)
                }
            } footer: {
                // Фильтр, который сервер отклонил, не пропадает с экрана:
                // сообщение — здесь, рядом с условиями.
                if let problem = model.filterErrorMessage {
                    Notice(.warning, problem)
                } else if model.filter.usesRawJSON {
                    Text("Пока поля JSON заполнены, конструктор не используется. Пустой объект {} сервер отклоняет, поэтому пустые поля не отправляются.")
                }
            }
        }
    }

    // MARK: - Sheets

    private var documentSheet: some View {
        SheetForm(
            width: .wide,
            cancel: {
                model.showAddDocumentSheet = false
                model.editingDocumentID = nil
            },
            confirmTitle: model.isEditingExistingDocument ? String(localized: "Сохранить") : String(localized: "Добавить"),
            confirmDisabled: model.isSavingDocument || model.documentContextVerdict.blocksSending,
            isWorking: model.isSavingDocument,
            confirm: { Task { await model.saveDocument(app) } }
        ) {
            Section {
                TextEditor(text: $model.documentText)
                    .textArea()
                LabeledContent(String(localized: "ID")) {
                    TextField(String(localized: "ID"), text: $model.documentID, prompt: Text("необязательно — иначе UUID"))
                        .labelsHidden()
                        .disabled(model.isEditingExistingDocument)
                    Button(String(localized: "Текст из файла…")) { model.loadDocumentTextFromFile() }
                }
            } header: {
                SectionHeader(
                    model.isEditingExistingDocument ? String(localized: "Изменить документ") : String(localized: "Добавить документ"),
                    help: String(localized: "Вектор считается моделью коллекции при сохранении. У изменённого документа он пересчитывается: ChromaDB не обновляет его сама. Длина текста сверяется с контекстом модели — LM Studio отвечает успехом на текст любого размера и молча векторизует только его начало.")
                )
            } footer: {
                // Длина — против контекста модели.
                if let message = model.documentContextVerdict.message {
                    Notice(.warning, message)
                } else {
                    Text("Один документ — один вектор.")
                }
            }

            Section {
                ForEach($model.documentMetadata.rows) { $row in
                    let field = model.schema(for: model.selected, app: app)?.field(for: row.key.trimmingCharacters(in: .whitespaces))
                    HStack {
                        TextField(String(localized: "ключ"), text: $row.key)
                            .labelsHidden()
                            .disabled(MetadataDraft.isReserved(row.key) || field != nil)
                        TextField(String(localized: "значение"), text: $row.value, prompt: Text(field.map { "\($0.type.hint)" } ?? String(localized: "значение")))
                            .labelsHidden()
                            .disabled(MetadataDraft.isReserved(row.key))
                        if let field {
                            Text(field.isRequired ? String(localized: "обяз., \(field.type.title)") : field.type.title)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                        Button {
                            model.documentMetadata.remove(row)
                        } label: {
                            Label(String(localized: "Убрать поле"), systemImage: "minus.circle")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "Убрать поле"))
                        .disabled(MetadataDraft.isReserved(row.key) || field?.isRequired == true)
                    }
                }
                HStack {
                    Spacer()
                    Button(String(localized: "Добавить поле")) { model.documentMetadata.addRow() }
                }
                ForEach(model.documentViolations) { violation in
                    Notice(.warning, violation.message)
                }
            } header: {
                Text("Метаданные")
            } footer: {
                Text(model.schema(for: model.selected, app: app).map {
                    String(localized: "По схеме коллекции: полей \($0.fields.count).")
                } ?? String(localized: "Схемы у коллекции нет — поля произвольные."))
            }

            // Сервер ответил бы успехом и оставил прежний документ;
            // выбор — за человеком.
            if let conflict = model.conflictingDocumentID {
                Section {
                    HStack {
                        Spacer()
                        Button(String(localized: "Показать существующий")) {
                            Task { await model.revealConflictingDocument(app) }
                        }
                        Button(String(localized: "Перезаписать")) {
                            Task { await model.overwriteConflictingDocument(app) }
                        }
                    }
                } header: {
                    Text("Такой документ уже есть")
                } footer: {
                    Notice(.warning, String(localized: "Документ с идентификатором «\(conflict)» уже лежит в коллекции. Сервер бы ответил успехом и оставил прежний."))
                }
            }
        }
    }

    private var importSheet: some View {
        SheetFrame(width: .wide) {
            if let table = model.importTable {
                Section {
                    Picker(String(localized: "Текст документа"), selection: $model.importMapping.documentColumn) {
                        ForEach(table.columns, id: \.self) { Text($0).tag($0) }
                    }
                    Picker(String(localized: "ID"), selection: Binding(
                        get: { model.importMapping.idColumn ?? "" },
                        set: { model.importMapping.idColumn = $0.isEmpty ? nil : $0 }
                    )) {
                        Text(String(localized: "генерировать")).tag("")
                        ForEach(table.columns, id: \.self) { Text($0).tag($0) }
                    }
                } header: {
                    SectionHeader(
                        String(localized: "Импорт документов"),
                        help: String(localized: "Одна строка файла — один документ: колонка текста становится телом документа, остальные выбранные колонки — его метаданными. Вектор считается моделью коллекции при записи, поэтому импорт идёт со скоростью модели. Строку длиннее контекста модели приложение не записывает и называет её отдельно.")
                    )
                } footer: {
                    Text("\(model.importFileName) · \(table.format.title) · строк: \(table.rowCount), колонок: \(table.columns.count)")
                }

                Section {
                    ForEach(table.columns, id: \.self) { column in
                        Toggle(column, isOn: Binding(
                            get: { model.importMapping.metadataColumns.contains(column) },
                            set: { isOn in
                                if isOn { model.importMapping.metadataColumns.insert(column) }
                                else { model.importMapping.metadataColumns.remove(column) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .disabled(column == model.importMapping.documentColumn)
                    }
                } header: {
                    Text("В метаданные")
                }

                Section {
                    ForEach(Array(table.preview(5).enumerated()), id: \.offset) { _, row in
                        let metadata = model.importMapping.metadataColumns.sorted()
                            .compactMap { key in (row[key]?.isEmpty == false) ? "\(key)=\(row[key] ?? "")" : nil }
                            .joined(separator: " · ")
                        VStack(alignment: .leading) {
                            Text(row[model.importMapping.documentColumn] ?? "")
                                .lineLimit(1)
                            Text([model.importMapping.idColumn.map { "id: \(row[$0] ?? "")" }, metadata.isEmpty ? nil : metadata]
                                .compactMap { $0 }
                                .joined(separator: " · "))
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } header: {
                    Text("Предпросмотр первых строк")
                }
            }

            // Выбирается до запуска, а не спрашивается на полпути.
            Section {
                Picker(String(localized: "Если ID уже есть"), selection: $model.importDuplicatePolicy) {
                    ForEach(DuplicatePolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.isImporting)
                // ход живёт в очереди; читает его отдельный маленький вид.
                QueueProgressRow(titlePrefix: QueueMirror.TitlePrefix.import)
            } footer: {
                Text(model.importDuplicatePolicy.explanation)
            }

            if model.importSkippedInvalid > 0 || model.importSummary != nil {
                Section {
                    if model.importSkippedInvalid > 0 {
                        Notice(.warning, String(localized: "Пропущено по схеме: \(model.importSkippedInvalid) строк"))
                        ForEach(model.importViolations.prefix(5)) { violation in
                            Text(violation.message)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    if let summary = model.importSummary {
                        StatusLabel(.ok, String(localized: "Записано \(summary.written), пропущено пустых строк \(summary.skippedEmpty), модель \(summary.model), размерность \(summary.dimension.plainDigits), за \(SecondsText.line(summary.duration))."))
                        if !summary.skippedDuplicates.isEmpty {
                            Notice(.warning, String(localized: "Пропущено строк с существующими ID: \(summary.skippedDuplicates.count)"))
                            Text(summary.skippedDuplicates.prefix(8).joined(separator: ", "))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        // Названы, а не сосчитаны: пропущенная строка — строка,
                        // с которой человеку что-то делать.
                        if !summary.skippedTooLong.isEmpty {
                            Notice(.warning, String(localized: "Не записано строк длиннее контекста модели: \(summary.skippedTooLong.count)"))
                            Text(summary.skippedTooLong.prefix(8).joined(separator: ", "))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Итог")
                }
            }
        } actions: {
            if let resumePoint = model.importResumePoint, !model.isImporting {
                Text(String(localized: "Записано \(resumePoint) — остальное можно дописать"))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isImporting {
                Button(String(localized: "Отменить")) { model.cancelImport() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button(String(localized: "Закрыть")) { model.showImportSheet = false }
                    .keyboardShortcut(.cancelAction)
                if model.importResumePoint != nil {
                    Button(String(localized: "Продолжить с места сбоя")) { model.runImport(app, resume: true) }
                        .primaryButtonStyle()
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(String(localized: "Импортировать")) { model.runImport(app) }
                        .primaryButtonStyle()
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.importTable == nil || model.importMapping.documentColumn.isEmpty)
                }
            }
        }
    }

    // MARK: - Правила

    /// «Правила» — схема метаданных коллекции и проверка документов по ней.
    private func metadataScreen(_ collection: ChromaCollection) -> some View {
        VStack(spacing: 0) {
            reembeddingCards
            Form {
                schemaSection
                // Пока схемы нет, сверять не с чем — секции нет (v6 B4): одна
                // неактивная кнопка в пустой карточке ничего не говорила.
                if !model.schemaDraft.fields.isEmpty || model.complianceReport != nil {
                    complianceSection
                }
                serviceFields(collection)
                AdvancedSection(screen: "collection.schema", title: String(localized: "Схема файлом")) {
                    HStack {
                        Button(String(localized: "Экспорт…")) { model.exportSchema(app) }
                        Button(String(localized: "Импорт…")) { model.importSchema(app) }
                        Spacer()
                        if schemaStore.hasSchema(for: model.schemaDraft.collectionName) {
                            Button(String(localized: "Удалить схему…"), role: .destructive) {
                                confirmingSchemaDeletion = true
                            }
                        }
                    }
                    Text("Схему можно перенести на другую машину файлом.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Section { collectionsHowItWorks }
            }
            .formStyle(.grouped)
        }
        .task(id: collection.id) { model.beginEditingSchema(app) }
        .confirmationDialog(
            String(localized: "Удалить схему коллекции?"),
            isPresented: $confirmingSchemaDeletion,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Удалить"), role: .destructive) { model.deleteSchema(app) }
            Button(String(localized: "Отменить"), role: .cancel) {}
        } message: {
            Text("Документы не трогаются — исчезают только правила.")
        }
    }

    /// Поля схемы. Пустая схема — состояние, а не пустое место: она значит
    /// «метаданные ничем не ограничены», и об этом сказано.
    private var schemaSection: some View {
        Section {
            if model.schemaDraft.fields.isEmpty {
                Text("Схемы нет: в метаданных может быть что угодно. Быстрее всего начать с черновика по уже загруженным документам.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach($model.schemaDraft.fields) { $field in
                    schemaFieldRow($field)
                }
                Toggle(String(localized: "Запретить поля вне схемы"), isOn: Binding(
                    get: { !model.schemaDraft.allowsExtraFields },
                    set: { model.schemaDraft.allowsExtraFields = !$0 }
                ))
                .toggleStyle(.switch)
            }
            ForEach(model.schemaIssues) { issue in
                Notice(.warning, issue.message)
            }
            HStack {
                Button(String(localized: "Добавить поле")) { model.addSchemaField() }
                Spacer()
                // Сохранение — единственное, что меняет что-то на диске, и
                // потому главное, когда схема уже не пуста.
                if model.schemaDraft.fields.isEmpty {
                    Button(String(localized: "Вывести из документов")) { model.inferSchema(app) }
                        .help(String(localized: "Собрать черновик из полей загруженных документов"))
                } else {
                    Button(String(localized: "Вывести из документов")) { model.inferSchema(app) }
                        .help(String(localized: "Собрать черновик из полей загруженных документов"))
                    Button(String(localized: "Сохранить")) { model.saveSchema(app) }
                }
            }
        } header: {
            SectionHeader(
                String(localized: "Схема метаданных"),
                help: String(localized: "У ChromaDB нет собственных схем, поэтому правила хранит приложение. Они применяются и к документам, добавленным вручную, и к тем, что приходят из источников: модель правил одна.")
            )
        } footer: {
            Text("Какие поля обязательны, какого они типа и что подставляется по умолчанию.")
        }
    }

    private func schemaFieldRow(_ field: Binding<MetadataField>) -> some View {
        HStack {
            TextField(String(localized: "Поле"), text: field.key, prompt: Text("поле"))
                .labelsHidden()
            Picker(String(localized: "Тип"), selection: field.type) {
                ForEach(MetadataFieldType.allCases) { type in
                    Text(type.title).tag(type)
                }
            }
            .labelsHidden()
            .fixedSize()
            Toggle(String(localized: "обяз."), isOn: field.isRequired)
                .toggleStyle(.checkbox)
                .fixedSize()
            TextField(String(localized: "По умолчанию"), text: field.defaultValue, prompt: Text("по умолчанию"))
                .labelsHidden()
            if field.wrappedValue.type == .date {
                Toggle(String(localized: "+unix"), isOn: field.storesTimestamp)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .help(String(localized: "Дополнительно писать <поле>_ts числом: ChromaDB не умеет сравнивать ISO-строки через $gt"))
            }
            Button {
                model.removeSchemaField(field.wrappedValue)
            } label: {
                Label(String(localized: "Убрать поле"), systemImage: "minus.circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Убрать поле"))
        }
    }

    /// Соответствие документов схеме — другой вопрос и другая цена:
    /// проверка читает документы пачками и ничего не меняет.
    private var complianceSection: some View {
        Section {
            if let report = model.complianceReport {
                StatusLabel(
                    report.isClean ? .ok : .warning,
                    report.isClean
                        ? String(localized: "Проверено \(report.checked) документов — все соответствуют схеме.")
                        : String(localized: "Проверено \(report.checked), не соответствуют \(report.offending).\(report.stoppedEarly ? " Показаны первые нарушения." : "")")
                )
                ForEach(report.violations.prefix(20)) { violation in
                    Text("\(violation.documentID ?? "—") · \(violation.message)")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(violation.message)
                }
                if report.violations.count > 20 {
                    Text("и ещё \((report.violations.count - 20).plainDigits)")
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                if let progress = model.complianceProgress {
                    Text("проверено \(progress.checked) из \(progress.total)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isCheckingCompliance {
                    ProgressView().controlSize(.small)
                    Button(String(localized: "Остановить")) { model.cancelComplianceCheck() }
                }
                Button(String(localized: "Проверить документы")) { model.runComplianceCheck(app) }
                    .disabled(model.isCheckingCompliance || model.schemaDraft.fields.isEmpty)
            }
        } header: {
            Text("Соответствие документов")
        } footer: {
            Text(model.schemaDraft.fields.isEmpty
                 ? String(localized: "Пока схемы нет, сравнивать не с чем.")
                 : String(localized: "Проверка читает документы и сравнивает их со схемой. В базе ничего не меняется."))
        }
    }

    private var bindSheet: some View {
        SheetForm(
            cancel: { model.showBindSheet = false },
            confirmTitle: String(localized: "Привязать"),
            confirmDisabled: model.bindModelSelection.isEmpty || model.isBinding,
            isWorking: model.isBinding,
            confirm: { Task { await model.bindModel(app) } }
        ) {
            Section {
                Picker(String(localized: "Модель"), selection: $model.bindModelSelection) {
                    Text(String(localized: "— выберите —")).tag("")
                    ForEach(embeddingsModel.embeddingModels) { item in
                        Text(item.id).tag(item.id)
                    }
                }
            } header: {
                SectionHeader(
                    String(localized: "Модель коллекции"),
                    help: String(localized: "Приложение не может проверить, какой моделью посчитаны уже существующие векторы, — оно сверяет только размерность. Если она не совпадёт, привязка будет отклонена.")
                )
            } footer: {
                if embeddingsModel.embeddingModels.isEmpty {
                    Notice(.warning, String(localized: "Список моделей пуст. Откройте «Модели» и проверьте соединение с LM Studio."))
                } else {
                    Text("Чем считать векторы этой коллекции дальше.")
                }
            }
        }
    }

    private var deleteSheet: some View {
        SheetForm(
            cancel: { model.showDeleteSheet = false },
            confirmTitle: String(localized: "Удалить"),
            confirmDisabled: model.selected.map { model.deleteConfirmationText != $0.name } ?? true
                || model.isCapturingTrash,
            isDestructive: true,
            isWorking: model.isCapturingTrash,
            confirm: { Task { await model.deleteSelected(app) } }
        ) {
            if let collection = model.selected {
                Section {
                    TextField(String(localized: "Имя коллекции"), text: $model.deleteConfirmationText, prompt: Text(verbatim: collection.name))
                } header: {
                    Text(String(localized: "Удалить коллекцию «\(collection.name)»?"))
                } footer: {
                    // удаление коллекции обратимо, пока включена корзина,
                    // и это сказано здесь, а не подразумевается.
                    if settings.configuration.trashEnabled {
                        Text("Будут удалены все документы и векторы. Они сохранятся в «Корзине» — их можно будет восстановить. Для подтверждения введите имя коллекции.")
                    } else {
                        Notice(.warning, String(localized: "Корзина выключена — отменить удаление будет нельзя. Для подтверждения введите имя коллекции."))
                    }
                }
                // Почему не удалилось — здесь же, а не под окном.
                if let problem = model.deleteTooBig {
                    deleteTooBigSection(problem, nameConfirmed: model.deleteConfirmationText == collection.name)
                } else if let error = model.deleteError {
                    Section { Notice(.warning, error) }
                }
            }
        }
        .confirmationDialog(
            String(localized: "Удалить «\(model.deleteTooBig?.collection ?? "")» без копии?"),
            isPresented: $confirmingDeleteWithoutTrash,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Удалить безвозвратно"), role: .destructive) {
                Task { await model.deleteSelected(app, usingTrash: false) }
            }
            Button(String(localized: "Отменить"), role: .cancel) {}
        } message: {
            Text("Документы и векторы уйдут из базы, в корзину ничего не попадёт.")
        }
    }

    /// Коллекция не помещается в корзину: причина и два выхода.
    @ViewBuilder
    private func deleteTooBigSection(_ problem: CollectionTooBigForTrash, nameConfirmed: Bool) -> some View {
        Section {
            Notice(.warning, problem.errorDescription ?? "")
            if let limit = model.raisedTrashLimit(app) {
                // Файл корзины на диске длиннее её оценки: векторы в нём
                // записаны текстом.
                let disk = ByteCountFormatter.string(fromByteCount: problem.needed * 8 / 5, countStyle: .file)
                LabeledContent {
                    Button(String(localized: "Поднять и удалить")) {
                        Task { await model.raiseTrashLimitAndDelete(app) }
                    }
                    .disabled(model.isCapturingTrash || !nameConfirmed)
                } label: {
                    Text("Поднять предел корзины до \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))")
                    Text("Копия займёт на диске около \(disk) и будет храниться \(settings.configuration.trashRetentionDays.plainDigits) дн.")
                }
            }
            LabeledContent {
                Button(String(localized: "Удалить без копии…"), role: .destructive) {
                    confirmingDeleteWithoutTrash = true
                }
                .disabled(model.isCapturingTrash || !nameConfirmed)
            } label: {
                Text("Удалить без копии в корзине")
                Text("Вернуть коллекцию будет нельзя — только собрать заново из источника.")
            }
        }
    }

    private var resetSheet: some View {
        SheetForm(
            cancel: { model.showResetSheet = false },
            confirmTitle: String(localized: "Сбросить"),
            confirmDisabled: !CollectionsViewModel.confirms(
                model.resetConfirmationText, word: String(localized: "СБРОС"), russian: "СБРОС"
            ),
            isDestructive: true,
            confirm: { Task { await model.resetDatabase(app) } }
        ) {
            Section {
                TextField(String(localized: "Подтверждение"), text: $model.resetConfirmationText, prompt: Text("СБРОС"))
            } header: {
                Text("Сбросить базу?")
            } footer: {
                if let note = model.resetAvailability(app) {
                    Notice(.warning, note)
                } else {
                    Notice(.warning, String(localized: "Будут удалены все коллекции и документы этой базы. Для подтверждения введите СБРОС."))
                }
            }
        }
    }
}

private extension RetrievalHit {
    /// Ключ строки выдачи: одинаковый идентификатор в двух коллекциях —
    /// два разных результата.
    var listKey: String { "\(collectionName ?? "")\u{0}\(id)" }
}
