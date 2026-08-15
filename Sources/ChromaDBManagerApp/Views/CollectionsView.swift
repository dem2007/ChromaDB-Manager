import SwiftUI
import ChromaCore

struct CollectionsView: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var schemaStore: SchemaStore
    @ObservedObject var model: CollectionsViewModel
    @ObservedObject var embeddingsModel: EmbeddingsViewModel
    @ObservedObject var reembedding: ReembeddingViewModel
    /// Активно ли окно: от этого зависит, каким цветом система залила
    /// выбранную строку списка, — а значит, и каким цветом писать по ней.
    /// Открытая сторона выбранной коллекции.
    @State private var tab: CollectionTab = .documents
    @State private var isCreatingCollection = false
    /// просмотр исходника — своё состояние экрана, а не раздел меню.
    @StateObject private var viewer = DocumentViewerViewModel()
    /// D3, K1: инспектор живёт своим состоянием — прогон длится и после того,
    /// как окно закрыли и открыли снова.
    @StateObject private var inspector = InspectorViewModel()
    /// перенос коллекции пакетом.
    @StateObject private var transfer = TransferViewModel()

    @State private var expandedDocumentID: String?
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

    var body: some View {
        // Экран из макета: слева карточка со списком коллекций — она общая
        // для всего экрана; справа выбранная коллекция и её стороны. Разделителя
        // между колонками нет: карточки лежат на полотне, а не в двух панелях
        //.
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            banners
            HStack(alignment: .top, spacing: 18) {
                collectionListCard
                    .frame(width: Theme.Size.objectListWidth)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.bottom, Theme.contentPadding)
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
        .onChange(of: model.pendingImportText) { _, _ in model.applyPendingRequest(app) }
        .onChange(of: model.documentIDToReveal) { _, identifier in
            // «Показать существующий» opens that row rather than leaving the
            // user to find it in the list.
            guard let identifier else { return }
            expandedDocumentID = identifier
            model.documentIDToReveal = nil
        }
        .sheet(isPresented: $model.showAddDocumentSheet) { documentSheet }
        .sheet(isPresented: $model.showBindSheet) { bindSheet }
        .sheet(isPresented: $model.showDeleteSheet) { deleteSheet }
        .sheet(isPresented: $model.showResetSheet) { resetSheet }
        .sheet(isPresented: $model.showImportSheet) { importSheet }
        .sheet(isPresented: $model.showProfileEditor) { profileSheet }
        .sheet(isPresented: $isCreatingCollection) { createCollectionSheet }
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

    @ViewBuilder
    private var banners: some View {
        if model.errorMessage != nil || model.statusMessage != nil {
            VStack(spacing: 8) {
                if let error = model.errorMessage {
                    MessageBanner(kind: .error, text: error) { model.errorMessage = nil }
                }
                if let status = model.statusMessage {
                    MessageBanner(kind: .success, text: status) { model.statusMessage = nil }
                }
            }
        }
    }

    // MARK: - Список коллекций

    /// Список — карточка, а не панель окна.
    ///
    /// В макете это отдельная карточка слева: поиск наверху, строки посередине,
    /// «Новая коллекция…» внизу. Действия, относящиеся ко **всей базе** —
    /// обновить список, сбросить базу, — живут в её подвале: это единственное
    /// место экрана, которое говорит о базе целиком, а не об одной коллекции.
    private var collectionListCard: some View {
        VStack(spacing: 0) {
            listSearchField
            Rectangle().fill(Theme.Palette.rowDivider).frame(height: 1)
            collectionList
            Rectangle().fill(Theme.Palette.rowDivider).frame(height: 1)
            listFooter
        }
        .background(Theme.Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(Theme.Palette.border, lineWidth: 1)
        )
        .shadow(
            color: .black.opacity(Theme.Shadow.cardOpacity),
            radius: Theme.Shadow.cardRadius,
            y: Theme.Shadow.cardY
        )
    }

    /// Поиск и порядок над списком.
    ///
    /// Порядок — в меню, поиск — полем: искать хочется на каждом втором
    /// открытии, а менять порядок раз в месяц, и то, что делают чаще, не
    /// должно требовать лишнего нажатия.
    private var listSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.Palette.captionText).font(Theme.Font.caption)
            TextField(String(localized: "Поиск по имени"), text: $model.collectionSearch)
                .textFieldStyle(.plain)
                .font(Theme.Font.control)
            if !model.collectionSearch.isEmpty {
                Button {
                    model.collectionSearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Palette.captionText)
                }
                .buttonStyle(.borderless)
            }

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
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help(String(localized: "Порядок списка: \(app.settings.configuration.collectionListOrder.title)"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Подвал списка: создать коллекцию — и то, что относится ко всей базе.
    private var listFooter: some View {
        HStack(spacing: 8) {
            Button(String(localized: "Новая коллекция…")) {
                isCreatingCollection = true
            }
            .buttonStyle(.chromaNormal)
            .disabled(!app.connection.isConnected)
            Spacer(minLength: 0)
            if model.isLoadingCollections { ProgressView().controlSize(.small) }
            Menu {
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
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
            .help(String(localized: "Обновить список коллекций, сбросить базу"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var collectionList: some View {
        VStack(spacing: 0) {
            // Через `select(_:app:)`, а не мимо него. Раньше здесь стояли две
            // строчки — присвоить id и подгрузить документы, — и всё остальное,
            // что относится к выбранной коллекции, оставалось от предыдущей:
            // выключатель «умный поиск», список профилей, действующий профиль,
            // сохранённые фильтры, выдача и панель диагностики. На экране
            // переключатель показывал «включено», а поиск шёл по plain-профилю
            // соседней коллекции — отсюда «настройки профиля не работают» и
            // «с выключенной галочкой ровно те же результаты».
            // Выделение рисует сам список, а не система.
            //
            // С системным `List(selection:)` фон и текст меняются в разные
            // моменты: подсветку AppKit анимирует, а цвет текста SwiftUI
            // ставит мгновенно — на переходе строка успевает побыть тёмным
            // текстом на синем и белым на белом. Это и есть моргание, и оно
            // не лечится тем, когда именно записан выбор: рисуют его двое.
            // Своя заливка означает один проход — один цвет.
            List {
                ForEach(model.visibleCollections(app)) { collection in
                    collectionRow(collection)
                        // В макете строки списка разделяет воздух, а не линии:
                        // линия через всю колонку спорит с рамкой карточки.
                        .listRowSeparator(.hidden)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: Theme.Radius.row)
                                .fill(model.selectedID == collection.id
                                      ? Theme.Palette.accent
                                      : Color.clear)
                                .padding(.vertical, 1)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard model.selectedID != collection.id else { return }
                            model.selectedID = collection.id
                            Task { await model.select(collection, app: app) }
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if model.visibleCollections(app).isEmpty && !model.isLoadingCollections {
                    VStack(spacing: 6) {
                        // «Ничего не нашлось» и «коллекций нет» — разные
                        // сообщения: первое про строку поиска, второе про базу,
                        // и предлагать создать коллекцию человеку, который
                        // просто опечатался в поиске, незачем.
                        if model.collections.isEmpty {
                            Text(String(localized: "Коллекций нет"))
                                .font(Theme.Font.control)
                                .foregroundStyle(Theme.Palette.secondaryText)
                            Text(String(localized: "Создайте первую кнопкой внизу."))
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.captionText)
                                .multilineTextAlignment(.center)
                        } else {
                            Text(String(localized: "Ничего не нашлось"))
                                .font(Theme.Font.control)
                                .foregroundStyle(Theme.Palette.secondaryText)
                            Text(String(localized: "Из \(model.collections.count) коллекций ни одна не подходит под «\(model.collectionSearch)»."))
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.captionText)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
    }

    /// Строка списка — как в макете: имя и одна строка фактов под ним.
    ///
    /// Модель коллекции из строки убрана: она стоит в подписи под именем
    /// выбранной коллекции справа, а один и тот же факт не показывается
    /// дважды. Остаётся только её отсутствие — это уже не факт, а состояние,
    /// с которым нужно что-то делать.
    ///
    /// На выбранной строке цвета меняются: система заливает её акцентным
    /// синим, и серая подпись на нём не читается вовсе, а оранжевая пометка
    /// перестаёт быть заметной. Пока окно неактивно, заливка бледно-серая —
    /// там как раз нужны обычные цвета, и потому смотрим на `controlActiveState`,
    /// а не только на сам факт выбора.
    private func collectionRow(_ collection: ChromaCollection) -> some View {
        let isHighlighted = model.selectedID == collection.id
        return VStack(alignment: .leading, spacing: 3) {
            Text(collection.name)
                .font(Theme.Font.control.weight(.medium))
                .foregroundStyle(isHighlighted ? Color.white : Theme.Palette.primaryText)
                .lineLimit(1).truncationMode(.middle)
            HStack(spacing: 5) {
                Text(collection.documentCount.map {
                    RussianCount.grouped($0, "запись", "записи", "записей")
                } ?? String(localized: "записей: ?"))
                if let dimension = collection.effectiveDimension {
                    Text("· dim \(dimension)")
                }
                // Numbers from different metrics are not comparable, so the
                // metric is always in sight next to them.
                if let space = collection.space {
                    Text("· \(space.shortTitle)")
                } else {
                    Text(String(localized: "· метрика неизвестна"))
                        .foregroundStyle(isHighlighted ? Color.white : Theme.Palette.attention)
                }
            }
            .font(Theme.Font.micro)
            .foregroundStyle(isHighlighted
                             ? Color.white.opacity(0.8)
                             : Theme.Palette.captionText)

            if !collection.isBound {
                Text(String(localized: "модель не указана"))
                    .font(Theme.Font.micro)
                    .foregroundStyle(isHighlighted ? Color.white : Theme.Palette.attention)
            }
        }
        .padding(.vertical, 3)
        // Здесь имя тоже обрезано посередине, и выделять его мышью нельзя:
        // строка списка занята выбором коллекции. Остаётся правая кнопка.
        .copyable(collection.name)
    }

    /// Создание коллекции — лист, а не форма в колонке.
    ///
    /// В колонке шириной в четверть экрана выпадающий список моделей и три
    /// параметра индекса не помещались: имена моделей обрезались до
    /// «text-embedding-qwe…», а метрика — то, что нельзя изменить потом, —
    /// стояла в самом узком месте окна.
    private var createCollectionSheet: some View {
        SheetShell(
            title: String(localized: "Новая коллекция"),
            subtitle: String(localized: "Модель и метрику коллекции менять потом нельзя — только пересоздавать её."),
            help: String(localized: "Коллекция — это набор документов с общими векторами. Модель определяет, чем эти векторы считаются: сравнивать между собой можно только векторы одной модели, поэтому сменить её у готовой коллекции нельзя. Метрика — способ измерять расстояние между векторами; она задаётся при создании индекса и тоже не меняется."),
            width: 560,
            height: nil,
            scrolls: false
        ) {
            VStack(alignment: .leading, spacing: 10) {
                TextField(String(localized: "Имя (a-z, 0-9, ._-)"), text: $model.newCollectionName)
                    .textFieldStyle(.roundedBorder)
                // Says what is wrong while it is being typed, and names the rule
                // rather than «недопустимое имя».
                if let problem = model.nameProblem {
                    Text(problem).font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.attention)
                }

                Picker(String(localized: "Модель"), selection: $model.newCollectionModel) {
                    Text(String(localized: "без модели")).tag("")
                    ForEach(embeddingsModel.embeddingModels) { item in
                        Text(item.id).lineLimit(1).truncationMode(.middle).tag(item.id)
                    }
                }
                if model.newCollectionModel.isEmpty {
                    Text(String(localized: "Без модели коллекцию можно создать и читать, но добавлять документы и делать запросы — нет: векторы считает приложение, а не сервер."))
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker(String(localized: "Метрика"), selection: $model.newCollectionMetric) {
                    ForEach(DistanceMetric.allCases) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                Text(model.newCollectionMetric.explanation)
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Collapsed by default: these three change how the index is built,
            // and leaving a field empty means the server decides.
            AdvancedSection(place: "collection.index", title: String(localized: "Параметры индекса")) {
                indexField(String(localized: "ef_construction"), text: $model.draftEFConstruction)
                indexField(String(localized: "ef_search"), text: $model.draftEFSearch)
                indexField(String(localized: "max_neighbors"), text: $model.draftMaxNeighbors)
                Text(String(localized: "Пустое поле — параметр не передаётся, значение выбирает сервер. Больше max_neighbors и ef_construction — точнее поиск, но индекс тяжелее и запись медленнее."))
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            if model.isCreating { ProgressView().controlSize(.small) }
            Button(String(localized: "Отмена")) { isCreatingCollection = false }
                .buttonStyle(.chromaNormal)
            Button(String(localized: "Создать")) {
                Task {
                    await model.createCollection(app)
                    // Имя очищается только после удачного создания —
                    // по нему и видно, закрывать ли лист.
                    if model.newCollectionName.isEmpty { isCreatingCollection = false }
                }
            }
            .buttonStyle(.chromaPrimary)
            .disabled(!app.connection.isConnected || model.isCreating || model.nameProblem != nil
                      || model.newCollectionName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func indexField(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title)
                .font(Theme.Font.mono)
                .foregroundStyle(Theme.Palette.captionText)
                .frame(width: 120, alignment: .leading)
            TextField(String(localized: "по умолчанию"), text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
        }
    }

    // MARK: - Detail

    /// Re-embedding banners and cards live in the detail column, next to the
    /// collection they are about. They are deliberately not in the screen's root
    /// VStack: inserting them there left the window blank after a run (the whole
    /// NavigationSplitView stopped drawing), and this placement reads better too.
    @ViewBuilder
    private var reembeddingCards: some View {
        if let error = reembedding.errorMessage {
            MessageBanner(kind: .error, text: error) { reembedding.errorMessage = nil }
        }
        if let message = reembedding.infoMessage {
            MessageBanner(kind: .info, text: message) { reembedding.infoMessage = nil }
        }
        if reembedding.isRunning {
            ReembeddingProgressCard(model: reembedding)
        }
        if let report = reembedding.report {
            ReembeddingReportCard(report: report)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let collection = model.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                    // Пересчёт векторов идёт часами и переживает переход на
                    // соседнюю вкладку — его видно с любой. Шапка коллекции
                    // тоже: без неё вкладка «Поиск» не говорит, где ищут
                    //.
                    reembeddingCards
                    collectionHeader(collection)

                    // Полоса вкладок — под именем коллекции, а не под именем
                    // раздела: она про эту коллекцию.
                    SegmentedSelector(
                        options: CollectionTab.allCases.map { ($0, $0.title) },
                        selection: $tab
                    )

                    switch tab {
                    case .documents:
                        appliedFilterNote
                        AdvancedSection(place: "collection.filter", title: String(localized: "Фильтр по метаданным")) {
                            filterCard
                        }
                        documentsSection(collection)
                    case .search:
                        appliedFilterNote
                        queryCard(collection)
                    case .overview:
                        // Сначала состав — ради него вкладку и открывают;
                        // проверки под ним отвечают на тот же вопрос «что в
                        // этой коллекции» с другой стороны: что в ней не так.
                        // Схема говорит, как должно быть, — это «Правила»
                        //.
                        InspectorTabs(
                            model: inspector, collection: collection, only: .overview,
                            // Клик по значению фасета уводит в документы с
                            // готовым фильтром: без этого обзор — картинка,
                            // по которой нельзя перейти к тому, что она
                            // показывает (K1 → A9).
                            applyFacetFilter: { field, value in
                                model.filter = DocumentFilter(conditions: [
                                    MetadataCondition(field: field, op: .equals, value: value.displayString)
                                ])
                                tab = .documents
                                Task { await model.applyFilter(app) }
                            }
                        )
                        InspectorTabs(
                            model: inspector, collection: collection, only: .checks,
                            // Главная кнопка вкладки — у карточки состава.
                            emphasisesAction: false,
                            // Сводка о проверке одна, и стоит она наверху
                            // вкладки: модель у панелей общая.
                            showsMessages: false,
                            applyFacetFilter: { _, _ in }
                        )
                    case .topics:
                        InspectorTabs(
                            model: inspector, collection: collection,
                            only: .topics, applyFacetFilter: { _, _ in }
                        )
                    case .rules:
                        schemaCard(collection)
                    }

                    howItWorks
                }
                .padding(.top, 4)
                .padding(.bottom, 8)
                // Место под накладную полосу прокрутки — постоянное.
                .scrollGutter()
                .steadyScrollbar()
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                    reembeddingCards
                    VStack(spacing: 6) {
                        Text(String(localized: "Коллекция не выбрана"))
                            .font(Theme.Font.cardTitle)
                            .foregroundStyle(Theme.Palette.secondaryText)
                        Text(String(localized: "Выберите её в списке слева — документы, поиск и правила относятся к одной коллекции."))
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.captionText)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                    howItWorks
                }
                .padding(.top, 4)
                .padding(.bottom, 8)
                .scrollGutter()
                .steadyScrollbar()
            }
        }
    }

    /// Третий уровень текста: устройство раздела целиком, свёрнуто.
    ///
    /// Оба факта здесь — о необратимом, и оба взяты из дизайн-макета: модель
    /// и метрика выбираются один раз на всю жизнь коллекции.
    private var howItWorks: some View {
        HowItWorks(screen: "collections") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Модель привязана к коллекции навсегда: векторы, посчитанные разными моделями, несравнимы. Чтобы сравнить другую модель или стратегию, коллекцию клонируют — «Модели» → «Пересчёт векторов».")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Метрику нельзя изменить после создания — только пересоздать коллекцию. Косинусная подходит почти всем эмбеддинг-моделям: они нормированы под неё.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Документы читаются страницами по сто: у ChromaDB нет курсора, и порядок выдачи между страницами не гарантирован. Точная работа с конкретными документами — через фильтр.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }


    /// Фильтр живёт на своей вкладке, а действует на этой — значит здесь
    /// о нём должна быть строка. Иначе человек смотрит на выдачу и не знает,
    /// почему в ней сорок документов вместо десяти тысяч.
    @ViewBuilder
    private var appliedFilterNote: some View {
        if let description = model.appliedFilterDescription {
            HStack(spacing: 12) {
                Circle()
                    .fill(Theme.Palette.accent)
                    .frame(width: Theme.Size.statusDot, height: Theme.Size.statusDot)
                Text("Применён фильтр: \(description)")
                    .font(Theme.Font.control)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button(String(localized: "Сбросить")) {
                    Task { await model.clearFilter(app) }
                }
                .buttonStyle(.chromaSecondary)
            }
            .padding(.horizontal, Theme.Padding.rowHorizontal)
            .padding(.vertical, Theme.Padding.rowVertical)
            .background(Theme.Palette.accent.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.row)
                    .strokeBorder(Theme.Palette.accent.opacity(0.22), lineWidth: 1)
            )
        }
    }

    /// Карточка коллекции — по макету: имя, одна строка фактов о ней и её
    /// действия справа.
    ///
    /// Факты собраны в одну строку вместо трёх россыпью: «5 193 записи ·
    /// размерность 1024 · косинусная · модель». Всё, что нужно раз в жизни —
    /// id и служебные поля, — свёрнуто.
    private func collectionHeader(_ collection: ChromaCollection) -> some View {
        VStack(alignment: .leading, spacing: Theme.Padding.cardContentSpacing) {
            HStack(alignment: .top, spacing: 12) {
                // Имя коллекции берут руками чаще, чем кажется: его вписывают
                // в запрос из другого приложения, в команду, в переписку.
                // Выделение мышью **и** «Скопировать» в правой кнопке — потому
                // что имя длиной в экран обрезано посередине, и выделить
                // мышью можно только то, что видно, а скопировать надо целиком.
                // Модель и размерность рядом — по той же причине.
                VStack(alignment: .leading, spacing: 3) {
                    Text(collection.name).font(Theme.Font.objectTitle)
                        .lineLimit(1).truncationMode(.middle)
                        .copyable(collection.name)
                    Text(collectionFactLine(collection))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.captionText)
                        .lineLimit(1).truncationMode(.middle)
                        .copyable(collectionFactLine(collection))
                }
                .textSelection(.enabled)
                Spacer(minLength: 8)

                // Одно действие названо словом, остальные — в меню: шесть
                // подписанных кнопок не помещались рядом со списком и
                // обрезались до «Пересч…».
                Button(String(localized: "Модель…")) {
                    model.bindModelSelection = collection.boundModel ?? settings.configuration.defaultEmbeddingModel ?? ""
                    model.showBindSheet = true
                }
                .buttonStyle(.chromaNormal)
                .help(collection.isBound
                      ? String(localized: "Модель коллекции: \(collection.boundModel ?? "не указана")")
                      : String(localized: "Указать модель, которой считаются векторы этой коллекции"))

                Button(String(localized: "Добавить")) {
                    model.beginAddingDocument(app)
                }
                .buttonStyle(.chromaPrimary)
                .disabled(!collection.isBound)

                Menu {
                    Button {
                        reembedding.begin(collection: collection, app: app)
                    } label: {
                        Label(String(localized: "Пересчитать векторы…"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(!collection.isBound || (collection.documentCount ?? 0) == 0)

                    Button {
                        model.chooseImportFile(app)
                    } label: {
                        Label(String(localized: "Импорт CSV или JSON…"), systemImage: "square.and.arrow.down")
                    }
                    .disabled(!collection.isBound)

                    Divider()

                    Button {
                        model.showExportSheet = true
                    } label: {
                        Label(String(localized: "Экспорт коллекции…"), systemImage: "shippingbox")
                    }
                    .help(String(localized: "Пакет .chromaexport: одна коллекция целиком или по фильтру, с векторами или без"))

                    Button {
                        model.showImportPackageSheet = true
                    } label: {
                        Label(String(localized: "Импорт пакета .chromaexport…"), systemImage: "shippingbox.and.arrow.backward")
                    }
                    .help(String(localized: "Что не так в коллекции и что в ней вообще есть. Ничего не меняет."))

                    Divider()

                    Button(role: .destructive) {
                        model.deleteConfirmationText = ""
                        model.showDeleteSheet = true
                    } label: {
                        Label(String(localized: "Удалить коллекцию…"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 30)
                .help(String(localized: "Пересчёт векторов, импорт, удаление коллекции"))
            }

            if !collection.isBound {
                MessageBanner(
                    kind: .warning,
                    text: String(localized: "Коллекция создана не этим приложением: неизвестно, какой моделью посчитаны её векторы. Укажите модель — приложение сверит только размерность.")
                )
            }

            // Служебные поля коллекции — `_cdbm_*`, хэш параметров нарезки,
            // `hnsw:space` — читают, когда что-то не сходится, и не читают
            // никогда в остальное время. Простыня из них стояла первым, что
            // видно под именем коллекции. Идентификатор — там же:
            // он нужен ровно в тех же случаях.
            AdvancedSection(place: "collection.metadata", title: String(localized: "Служебные поля")) {
                Text("id: \(collection.id)")
                    .font(Theme.Font.mono)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .copyable(collection.id)
                MetadataTable(metadata: collection.metadata)
            }
        }
        .padding(.horizontal, Theme.Padding.cardHorizontal)
        .padding(.vertical, Theme.Padding.cardVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(Theme.Palette.border, lineWidth: 1)
        )
        .shadow(
            color: .black.opacity(Theme.Shadow.cardOpacity),
            radius: Theme.Shadow.cardRadius,
            y: Theme.Shadow.cardY
        )
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

    private var filterCard: some View {
        SectionCard(
            title: String(localized: "Фильтр по метаданным"),
            subtitle: String(localized: "Условия собираются в where-запрос ChromaDB — фильтрует сервер, а не приложение.")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                savedFilterBar

                if model.filter.usesRawJSON {
                    rawFilterEditor
                } else {
                    FilterNodeEditor(
                        node: $model.filter.root,
                        knownFields: model.filterFieldSuggestions(app),
                        depth: 0,
                        onRemove: nil
                    )
                    DocumentTextConditionsEditor(
                        conditions: $model.filter.textConditions,
                        logic: $model.filter.textLogic
                    )
                }

                // A filter the server refused must not disappear from the
                // screen: the message goes here, next to the conditions.
                if let problem = model.filterErrorMessage {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button(model.filter.usesRawJSON
                           ? String(localized: "Вернуться к конструктору")
                           : String(localized: "Редактировать как JSON")) {
                        model.toggleFilterJSONMode()
                    }
                    .buttonStyle(.chromaSecondary)

                    if let json = model.filter.whereJSONString() {
                        Text(json)
                            .font(Theme.Font.mono)
                            .foregroundStyle(Theme.Palette.captionText)
                            .lineLimit(1).truncationMode(.middle)
                            .copyable(json)
                    }
                    if let json = model.filter.whereDocumentJSONString() {
                        Text(json)
                            .font(Theme.Font.mono)
                            .foregroundStyle(Theme.Palette.captionText)
                            .lineLimit(1).truncationMode(.middle)
                            .copyable(json)
                    }
                    Spacer()
                    Button(String(localized: "Сбросить")) {
                        Task { await model.clearFilter(app) }
                    }
                    .buttonStyle(.chromaNormal)
                    .disabled(model.filter.isEmpty)
                    Button(String(localized: "Применить")) {
                        Task { await model.applyFilter(app) }
                    }
                    .buttonStyle(.chromaPrimary)
                }
            }
        }
    }

    /// Saved filters for this collection: pick one, save the current one,
    /// delete what is no longer needed.
    private var savedFilterBar: some View {
        HStack(spacing: 8) {
            if !model.savedFilters.isEmpty {
                Menu {
                    ForEach(model.savedFilters) { saved in
                        Button(saved.name) { model.applySavedFilter(saved) }
                    }
                    Divider()
                    ForEach(model.savedFilters) { saved in
                        Button(String(localized: "Удалить «\(saved.name)»"), role: .destructive) {
                            model.deleteSavedFilter(saved, app: app)
                        }
                    }
                } label: {
                    Label(String(localized: "Сохранённые (\(model.savedFilters.count))"), systemImage: "bookmark")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 190)
            }

            TextField(String(localized: "имя фильтра"), text: $model.savedFilterName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
            Button(String(localized: "Сохранить фильтр")) {
                model.saveCurrentFilter(app)
            }
            .buttonStyle(.chromaNormal)
            .disabled(model.filter.isEmpty || model.savedFilterName.trimmingCharacters(in: .whitespaces).isEmpty)
            Spacer()
        }
        .font(Theme.Font.caption)
    }

    private var rawFilterEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("where").font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
            TextField(#"{"$and": [{"n": {"$gt": 10}}]}"#, text: $model.filter.rawWhereJSON, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(Theme.Font.mono)
                .lineLimit(1...6)
            Text("where_document").font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
            TextField(#"{"$not_contains": "черновик"}"#, text: $model.filter.rawWhereDocumentJSON, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(Theme.Font.mono)
                .lineLimit(1...4)
            Text(String(localized: "Пока поля заполнены, конструктор не используется. Пустой объект {} сервер отклоняет, поэтому пустые поля просто не отправляются."))
                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Метрика коллекции, из которой пришёл результат.
    private func metric(of hit: RetrievalHit, current: ChromaCollection) -> DistanceMetric? {
        guard let name = hit.collectionName, name != current.name else { return current.space }
        return model.collections.first { $0.name == name }?.space ?? current.space
    }

    /// Что ответила каждая коллекция.
    ///
    /// Отдельной строкой на коллекцию, а не одной сводкой: коллекция, которая
    /// не ответила из-за ошибки, выглядит в общей выдаче ровно как коллекция,
    /// в которой ничего не нашлось, — и человек делает из этого неверный вывод
    /// о своих данных.
    private var collectionsReport: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let summary = model.searchSummary {
                Text(summary).font(Theme.Font.caption)
            }
            ForEach(model.searchReports, id: \.self) { report in
                HStack(spacing: 6) {
                    Circle()
                        .fill(report.failure == nil ? Theme.Palette.running : Theme.Palette.danger)
                        .frame(width: Theme.Size.statusDot, height: Theme.Size.statusDot)
                    if let failure = report.failure {
                        Text("\(report.name) — не ответила: \(failure)")
                            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("\(report.name) — найдено \(report.found.plainDigits), \(Int((report.seconds * 1000).rounded()).plainDigits) мс")
                            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    }
                    Spacer()
                }
            }
        }
    }

    /// Выбор коллекций, которые ищутся вместе с открытой.
    ///
    /// Меню, а не список чекбоксов на экране: коллекций бывает два десятка, и
    /// поиск по одной — по-прежнему самый частый случай. Выбранные названы
    /// строкой под меню, чтобы «где я сейчас ищу» читалось без открывания.
    @ViewBuilder
    private func alsoSearchInRow(_ collection: ChromaCollection) -> some View {
        let others = model.collections.filter { $0.name != collection.name }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(others, id: \.id) { other in
                            Toggle(isOn: Binding(
                                get: { model.alsoSearchIn.contains(other.name) },
                                set: { isOn in
                                    if isOn {
                                        model.alsoSearchIn.insert(other.name)
                                    } else {
                                        model.alsoSearchIn.remove(other.name)
                                    }
                                }
                            )) {
                                // Коллекция без модели искать не может, и это
                                // сказано прямо в строке выбора, а не после
                                // запроса.
                                Text(other.isBound
                                     ? other.name
                                     : String(localized: "\(other.name) — нет модели"))
                            }
                            .disabled(!other.isBound)
                        }
                    } label: {
                        Text(model.alsoSearchIn.isEmpty
                             ? String(localized: "Искать ещё в…")
                             : String(localized: "Искать ещё в: \(model.alsoSearchIn.count.plainDigits)"))
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 190)

                    if !model.alsoSearchIn.isEmpty {
                        Button(String(localized: "Только эта коллекция")) { model.alsoSearchIn = [] }
                            .buttonStyle(.link).font(Theme.Font.micro)
                    }
                    Spacer()
                }

                if !model.alsoSearchIn.isEmpty {
                    let names = ([collection.name] + model.alsoSearchIn.sorted())
                    Text("ищем в: \(names.joined(separator: ", "))")
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                    // Поведение при разных моделях — главный вопрос этого
                    // режима, и ответ на него стоит до запуска, а не после.
                    Text(multiModelNote(collection))
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Сколько моделей затронет запрос — столько раз и посчитается вектор.
    private func multiModelNote(_ collection: ChromaCollection) -> String {
        let names = Set([collection.name]).union(model.alsoSearchIn)
        let models = Set(
            model.collections
                .filter { names.contains($0.name) }
                .compactMap { $0.boundModel }
        )
        let metrics = Set(
            model.collections
                .filter { names.contains($0.name) }
                .compactMap { $0.space }
        )
        var line = String(localized: "Вектор запроса считается по разу на модель: моделей \(models.count.plainDigits).")
        if metrics.count > 1 {
            line += String(localized: " Метрики у коллекций разные, поэтому порядок задаётся слиянием рангов, а не расстояниями.")
        }
        return line
    }

    private func queryCard(_ collection: ChromaCollection) -> some View {
        SectionCard(
            title: String(localized: "Запрос"),
            subtitle: String(localized: "Текст превращается в вектор моделью коллекции, затем ищутся ближайшие документы.")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                profileBar(collection)

                TextField(String(localized: "Текст запроса"), text: $model.queryText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)

                alsoSearchInRow(collection)

                HStack {
                    Stepper("n_results: \(model.numberOfResults)", value: $model.numberOfResults, in: 1...50)
                        .frame(width: 190)
                    if !model.filter.isEmpty {
                        Toggle(String(localized: "с фильтром"), isOn: $model.applyFilterToQuery)
                            .toggleStyle(.checkbox)
                            .help(String(localized: "Условия из панели фильтра применяются к запросу вместе с вектором."))
                    }
                    // Модель коллекции здесь не повторяется: она стоит
                    // в строке фактов под именем коллекции, а один и тот же
                    // факт в двух местах расходится.
                    Spacer()
                    Button(String(localized: "История")) {
                        model.showHistory.toggle()
                        if model.showHistory { model.reloadHistory(app) }
                    }
                    .buttonStyle(.chromaNormal)
                    if model.isQuerying { ProgressView().controlSize(.small) }
                    Button(String(localized: "Выполнить")) {
                        Task { await model.runQuery(app) }
                    }
                    .buttonStyle(.chromaPrimary)
                    .disabled(model.isQuerying || !collection.isBound)
                }

                if model.showHistory { historyPanel(collection) }

                if !collection.isBound {
                    Text(String(localized: "Запрос заблокирован: у коллекции не указана модель. Другой моделью выполнять его нельзя — результаты будут бессмысленными."))
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                }

                if !model.searchReports.isEmpty { collectionsReport }

                if !model.hits.isEmpty && model.alsoSearchIn.isEmpty {
                    // The scale depends entirely on the metric, so the header
                    // says which one produced these numbers.
                    Text(collection.space.map { metric in
                        metric == .cosine
                            ? String(localized: "Метрика \(metric.shortTitle): рядом с расстоянием показана схожесть.")
                            : String(localized: "Метрика \(metric.shortTitle): показано сырое значение, в процентах его выразить нельзя.")
                    } ?? String(localized: "Метрика коллекции неизвестна — значения показаны как есть, без интерпретации."))
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                }

                if let diagnostics = model.lastRetrieval {
                    diagnosticsPanel(diagnostics)
                }

                // Тоже лениво: у результата с метаданными и контекстом
                // соседей строк не меньше, чем у документа в списке.
                LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(model.hits.enumerated()), id: \.element.id) { index, hit in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("#\(index + 1)").font(Theme.Font.caption).bold()
                            // Из какой коллекции результат — в многоколлекционном
                            // поиске это первое, что нужно знать о находке
                            //. При поиске по одной коллекции строка
                            // не нужна: она и так в шапке экрана.
                            if !model.alsoSearchIn.isEmpty, let name = hit.collectionName {
                                Text(name)
                                    .font(Theme.Font.micro)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(Theme.Palette.subtleFill)
                                    )
                            }
                            Text(hit.id).font(Theme.Font.mono).foregroundStyle(Theme.Palette.captionText)
                            Spacer()
                            // Метрика — той коллекции, из которой результат.
                            // В многоколлекционном поиске у соседа она может
                            // быть другой, и пересчитывать её расстояние в
                            // проценты по чужой шкале значило бы показать
                            // выдуманное число.
                            Text(hit.queryHit.distanceText(metric: metric(of: hit, current: collection)))
                                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                            // замкнуть петлю «нашёл → понял → пошёл
                            // к первоисточнику». Кнопка стоит у каждого
                            // результата, а не в меню: ходить к исходнику
                            // нужно на каждом втором.
                            // Пометить прямо из выдачи: увидел, что фрагмент
                            // мешает, — понизил, не уходя в список документов
                            //.
                            Menu {
                                marksMenu(
                                    for: DocumentRecord(
                                        id: hit.id, document: hit.document, metadata: hit.metadata
                                    ),
                                    // Результат из соседней коллекции метится
                                    // в ней самой, а не в открытой.
                                    collectionName: hit.collectionName,
                                    fromHit: true
                                )
                            } label: {
                                Image(systemName: "bookmark").font(Theme.Font.caption)
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 28)
                            .help(String(localized: "Закрепить, понизить или пометить устаревшим"))
                            Button(String(localized: "Показать в документе")) {
                                viewer.open(
                                    chunk: hit.document ?? "",
                                    metadata: hit.metadata,
                                    title: hit.metadata.flatMap { metadata in
                                        DocumentLocator.reference(metadata: metadata).fileName
                                    } ?? collection.name,
                                    app: app
                                )
                            }
                            .controlSize(.small)
                            .disabled((hit.document ?? "").isEmpty)
                        }
                        marksLine(of: hit.metadata)
                        // Редактор тегов открывается **здесь же**, у того
                        // результата, с которого его позвали: строки этого
                        // документа в списке слева может не быть вовсе —
                        // он с другой страницы или вовсе из другой коллекции.
                        if marksEditorID == hit.id, marksEditorFromHit {
                            marksEditor(
                                for: DocumentRecord(
                                    id: hit.id, document: hit.document, metadata: hit.metadata
                                ),
                                collectionName: hit.collectionName
                            )
                        }
                        // A result that swallowed three others is a result the
                        // user is entitled to know about.
                        if let note = hit.collapsedNote {
                            Text(note).font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                        }
                        // Which chunk actually matched, when the card is
                        // showing the section it belongs to.
                        if let matched = hit.matchedChunkID {
                            Text(String(localized: "раздел целиком; совпал чанк \(matched)"))
                                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        }
                        // Which source found this one and where it stood before
                        // the stages rearranged the list. Shown with the
                        // diagnostics rather than always: on a card that is being
                        // read for its text it is noise.
                        if model.showDiagnostics, let origin = hit.originNote {
                            Text(origin).font(Theme.Font.micro).foregroundStyle(.tertiary)
                        }
                        // Neighbours that stood *before* the match are drawn
                        // before it, so the block reads as continuous text with
                        // the found fragment in the middle.
                        ForEach(neighbours(of: hit, before: true)) { attached in
                            contextText(attached)
                        }
                        Text(hit.document ?? "—").font(Theme.Font.body).copyable(hit.document ?? "")
                        ForEach(neighbours(of: hit, before: false)) { attached in
                            contextText(attached)
                        }
                        // The parent shown beside the match rather than instead
                        // of it — dimmed, because it is context and not what
                        // the ranking is based on.
                        ForEach(hit.context.filter { $0.contextKind == .parent }) { attached in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(localized: "контекст: родительский чанк"))
                                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                                Text(attached.document ?? "—")
                                    .font(Theme.Font.body).foregroundStyle(Theme.Palette.captionText)
                                    .copyable(attached.document ?? "")
                            }
                            .padding(.leading, 8)
                        }
                        MetadataTable(metadata: hit.metadata)
                    }
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                }
            }
        }
    }

    /// Neighbouring chunks on one side of the match, in reading order.
    private func neighbours(of hit: RetrievalHit, before: Bool) -> [RetrievalHit] {
        guard let index = hit.chunkIndex else { return [] }
        return hit.context.filter {
            guard $0.contextKind == .neighbour, let position = $0.chunkIndex else { return false }
            return before ? position < index : position > index
        }
    }

    /// Attached text, dimmed: it is what surrounds the answer, not the answer.
    private func contextText(_ hit: RetrievalHit) -> some View {
        Text(hit.document ?? "—")
            .font(Theme.Font.body)
            .foregroundStyle(.tertiary)
            .copyable(hit.document ?? "")
    }

    // MARK: - Search profiles

    /// The switch, the profile in force, and everything one does with profiles.
    ///
    /// «Умный поиск» is a switch and nothing more: off, the query runs as the
    /// plain vector search of stage 2, and the profile stays exactly as it was.
    /// Without it, answering «а что найдёт обычный поиск?» would mean undoing
    /// six settings and putting them back — which is how tuning gets lost.
    @ViewBuilder
    private func profileBar(_ collection: ChromaCollection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle(String(localized: "Умный поиск"), isOn: Binding(
                    get: { model.smartSearchEnabled },
                    set: { model.setSmartSearch($0, app: app) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                // Иначе в узком окне подпись переносится по одной букве в
                // строку: у выпадающего списка рядом ширина задана жёстко, и
                // сжимается единственное, что может, — эта надпись.
                .fixedSize()
                .help(String(localized: "Выключенный конвейер — это обычный векторный поиск. Настройки профиля при этом сохраняются."))

                if model.smartSearchEnabled {
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
                            // The profile a search uses when nobody has tuned
                            // anything. It has no id because it is not on disk.
                            Text(String(localized: "По умолчанию")).tag(model.activeProfileID)
                        }
                    }
                    // Список — то, что уступает место: имя профиля читается и
                    // укороченным, а «Умный поиск» по букве в строку — нет.
                    .frame(minWidth: 140, idealWidth: 260, maxWidth: 260)

                    Button(String(localized: "Настроить…")) { model.editActiveProfile(app) }
                        .fixedSize()

                    Menu {
                        Button(String(localized: "Новый профиль…")) { model.newProfile(app) }
                        Button(String(localized: "Дублировать действующий…")) { model.duplicateActiveProfile(app) }
                        Divider()
                        Button(String(localized: "Экспорт профилей…")) { model.exportProfiles(app) }
                        Button(String(localized: "Импорт профилей…")) { model.importProfiles(app) }
                        Divider()
                        Button(String(localized: "Удалить действующий профиль"), role: .destructive) {
                            model.deleteActiveProfile(app)
                        }
                        .disabled(model.profiles.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 40)
                }
                Spacer()
            }

            if !model.smartSearchEnabled {
                Text(String(localized: "Конвейер выключен: запрос идёт как обычный векторный поиск этапа 2. Иерархия, соседи, разнообразие и переранжирование не применяются."))
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
            }
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
                    onCancel: {
                        model.showProfileEditor = false
                        model.profileDraft = nil
                    },
                    onSave: { model.saveProfileDraft(app) }
                )
            }
        }
    }

    // MARK: - Diagnostics

    /// «Как получен этот результат»: what each stage was given, what it gave
    /// back, why, and how long it took.
    ///
    /// Collapsed by default — reading a result and explaining a result are
    /// different tasks, and the second one is rarer. Without the panel, though,
    /// tuning the pipeline is guesswork and «поиск стал хуже» is unanswerable:
    /// eight stages can each be the one that dropped the document the user
    /// expected, and nothing on the card says which.
    @ViewBuilder
    private func diagnosticsPanel(_ diagnostics: RetrievalDiagnostics) -> some View {
        DisclosureGroup(isExpanded: $model.showDiagnostics) {
            VStack(alignment: .leading, spacing: 6) {
                // Why the run looked the way it did, when the reason is not any
                // one stage — «умный поиск выключен» being the case that
                // otherwise leaves eight stages all blaming the profile.
                if let note = diagnostics.note {
                    Text(note).font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                }
                if let embedding = diagnostics.embeddingLine {
                    HStack(spacing: 8) {
                        Text(embedding).font(Theme.Font.caption)
                        Text(String(localized: "считается моделью, не конвейером"))
                            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    }
                }
                ForEach(diagnostics.stages.sorted { $0.stage.order < $1.stage.order }) { report in
                    stageRow(report, slowest: diagnostics.slowestStage)
                }
                Divider()
                HStack {
                    Text(String(localized: "Всего: \(Int((diagnostics.totalDuration * 1000).rounded())) мс"))
                        .font(Theme.Font.caption).bold()
                    Spacer()
                    Button(String(localized: "Скопировать")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diagnostics.plainText, forType: .string)
                    }
                    .controlSize(.small)
                    .help(String(localized: "Панель хранит только последний запрос — скопированный текст можно приложить к вопросу."))
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Text(String(localized: "Как получен этот результат")).font(Theme.Font.caption).bold()
                Text(diagnostics.summary).font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
            }
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// One stage: what it was given, what it returned, how long it took, and why.
    ///
    /// A stage that did not run is shown greyed rather than hidden — «почему не
    /// сработало» is the question the panel exists to answer, and a stage that
    /// is simply absent from the list answers nothing.
    private func stageRow(_ report: RetrievalDiagnostics.StageReport, slowest: RetrievalStage?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(report.stage.order).")
                .font(Theme.Font.mono)
                .foregroundStyle(Theme.Palette.captionText)
                .frame(width: 16, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(report.stage.title).font(Theme.Font.caption)
                    if report.ran {
                        Text(report.inputCount == report.outputCount
                             ? String(localized: "\(report.outputCount)")
                             : String(localized: "\(report.inputCount) → \(report.outputCount)"))
                            .font(Theme.Font.mono)
                            .foregroundStyle(Theme.Palette.captionText)
                        Text(String(localized: "\(Int((report.duration * 1000).rounded())) мс"))
                            .font(Theme.Font.micro)
                            .foregroundStyle(report.stage == slowest ? .orange : .secondary)
                    } else {
                        // «Выключено» и «не выполнено» — разные новости, и
                        // печатать их одним словом значило делать жалобу
                        // «настройка не сработала» неразрешимой.
                        Text(report.outcome.title)
                            .font(Theme.Font.micro)
                            .foregroundStyle(report.failed ? .orange : .secondary)
                    }
                }
                if let note = report.note {
                    Text(note)
                        .font(Theme.Font.micro)
                        .foregroundStyle(report.failed ? .orange : .secondary)
                }
            }
            Spacer()
        }
        .opacity(report.ran || report.failed ? 1 : 0.65)
    }

    // MARK: - History

    /// Past queries of this collection: repeat one, pin it, or mark it for the
    /// evaluation stand's query set.
    ///
    /// The last of those is the point of the panel. Nobody writes twenty
    /// representative queries by hand; everybody has already typed them.
    @ViewBuilder
    private func historyPanel(_ collection: ChromaCollection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(String(localized: "поиск по истории"), text: $model.historySearch)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: model.historySearch) { _, _ in model.reloadHistory(app) }
                Spacer()
                Button(String(localized: "Очистить историю"), role: .destructive) {
                    model.clearHistory(app)
                }
                .disabled(model.history.isEmpty)
            }

            if model.history.isEmpty {
                Text(String(localized: "Здесь появятся запросы, которые вы выполняли к этой коллекции."))
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
            }

            // История держит до тысячи записей — строить их все, чтобы
            // показать десяток видимых, не стоит ничего хорошего.
            LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(model.history) { entry in
                HStack(alignment: .top, spacing: 8) {
                    Button {
                        model.togglePinned(entry, app: app)
                    } label: {
                        Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Закрепить: закреплённые не вытесняются и стоят вверху."))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.text).font(Theme.Font.body).lineLimit(2)
                        HStack(spacing: 6) {
                            Text(entry.line)
                            Text(entry.ranAt.formatted(date: .abbreviated, time: .shortened))
                            if entry.filter != nil {
                                Text(String(localized: "· с фильтром"))
                            }
                        }
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    }
                    Spacer()

                    Button(String(localized: "Подставить")) { model.restore(entry) }
                        .help(String(localized: "Запрос вернётся в поле вместе с фильтром. Выполнить его — отдельная кнопка."))
                    Button {
                        model.toggleChosenForEvaluation(entry, app: app)
                    } label: {
                        Label(
                            entry.isChosenForEvaluation
                                ? String(localized: "В наборе")
                                : String(localized: "В набор"),
                            systemImage: entry.isChosenForEvaluation ? "checkmark.seal.fill" : "checkmark.seal"
                        )
                    }
                    .help(String(localized: "Отметить для набора запросов стенда оценки качества."))
                    Button {
                        model.removeFromHistory(entry, app: app)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 3)
                Divider()
            }
            }
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Documents

    /// Документы коллекции — карточка, как всё остальное на экране.
    ///
    /// Заголовок и число показанного — в шапке карточки, объяснение про
    /// листание — под «?», кнопка «Показать ещё» — в конце списка, где её и
    /// ищут. Раньше это был голый `VStack` без карточки, а объяснение про
    /// порядок страниц висело абзацем под кнопкой.
    private func documentsSection(_ collection: ChromaCollection) -> some View {
        SectionCard(
            title: String(localized: "Документы"),
            subtitle: model.appliedFilterDescription == nil
                ? String(localized: "Показано \(model.documents.count.formatted()) из \(collection.documentCount.map { $0.formatted() } ?? "?").")
                : String(localized: "Найдено по фильтру: \(model.documents.count.formatted())."),
            help: String(localized: "ChromaDB не гарантирует порядок выдачи при листании: если коллекция меняется, страницы могут повторяться или пропускаться. Для точной работы с конкретными документами пользуйтесь фильтром.")
        ) {
            VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                // Paging by limit/offset has no guaranteed order; when the
                // collection changes under the list, say so.
                if let notice = model.contentChangedNotice {
                    MessageBanner(kind: .warning, text: notice)
                }

                if let applied = model.appliedFilterDescription {
                    Text(applied)
                        .font(Theme.Font.mono)
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .lineLimit(2)
                }

                if model.documents.isEmpty && !model.isLoadingDocuments {
                    Text(model.appliedFilterDescription == nil
                         ? String(localized: "В коллекции пока нет документов.")
                         : String(localized: "Под фильтр ничего не подошло."))
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.captionText)
                }

                // Lazy, and that is the whole difference between a tab that opens
                // and a tab you wait for. A plain VStack builds every row at once,
                // including the ninety-odd below the fold: a page of 100 documents
                // with two dozen metadata keys each is some five thousand views
                // assembled on the main thread before the screen appears. Measured
                // on this machine: 1.65 s to enter the tab, 0.33 s with this line.
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.documents) { document in
                        documentRow(document)
                    }
                }

                HStack(spacing: 8) {
                    if model.canLoadMore {
                        Button(String(localized: "Показать ещё \(CollectionsViewModel.pageSize)")) {
                            Task { await model.loadDocuments(app, reset: false) }
                        }
                        .buttonStyle(.chromaNormal)
                        .disabled(model.isLoadingDocuments)
                    }
                    Button(String(localized: "Обновить страницу")) {
                        Task { await model.reloadCurrentPage(app) }
                    }
                    .buttonStyle(.chromaSecondary)
                    .disabled(model.isLoadingDocuments || model.documents.isEmpty)
                    if model.isLoadingDocuments { ProgressView().controlSize(.small) }
                    Spacer()
                }
            }
        }
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
            Button {
                Task {
                    await model.setMark(
                        mark, for: document, app: app, collectionName: collectionName
                    )
                }
            } label: {
                // Галочка у стоящей пометки: меню обязано показывать
                // состояние, а не только предлагать действие.
                Text(marks.mark == mark ? "✓ \(mark.actionTitle)" : mark.actionTitle)
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

    /// Теги и заметка — прямо в строке документа, а не отдельным окном:
    /// это две строки текста, и открывать ради них лист значило бы уводить
    /// человека от того, что он размечает.
    @ViewBuilder
    private func marksEditor(
        for document: DocumentRecord, collectionName: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(String(localized: "Теги через запятую"), text: $marksTags)
                .textFieldStyle(.roundedBorder)
            TextField(String(localized: "Заметка"), text: $marksNote, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            HStack(spacing: 8) {
                Button(String(localized: "Сохранить")) {
                    let tags = marksTags
                    let note = marksNote
                    marksEditorID = nil
                    marksEditorCollection = nil
                    marksEditorFromHit = false
                    // Одной записью: два вызова подряд собирали бы пометки
                    // из метаданных, которые были на экране до правки, и
                    // второй стёр бы теги, записанные первым.
                    Task {
                        await model.setTagsAndNote(
                            tags: tags, note: note, for: document, app: app,
                            collectionName: collectionName
                        )
                    }
                }
                .buttonStyle(.chromaPrimary)
                Button(String(localized: "Отмена")) {
                    marksEditorID = nil
                    marksEditorCollection = nil
                    marksEditorFromHit = false
                }
                .buttonStyle(.chromaNormal)
                Spacer()
                Text("теги видны агенту и годятся для фильтра по метаданным")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
            }
        }
        .padding(.vertical, 4)
    }

    /// Что стоит на документе — строкой под его идентификатором.
    @ViewBuilder
    private func marksLine(of metadata: ChromaMetadata?) -> some View {
        let marks = DocumentMarks(metadata: metadata)
        if !marks.isEmpty {
            HStack(spacing: 6) {
                if let mark = marks.mark {
                    Text(mark.title)
                        .font(Theme.Font.micro)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(markTint(mark).opacity(0.14))
                        )
                        .foregroundStyle(markTint(mark))
                }
                if !marks.tags.isEmpty {
                    Text(marks.tagsLine)
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        .lineLimit(1).truncationMode(.tail)
                }
                if let note = marks.note, !note.isEmpty {
                    Text(note)
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Цвет — только состояние (правило 7 «как устроен экран»): закреплённое
    /// работает на выдачу, устаревшее требует решения, понижённое выключено.
    private func markTint(_ mark: DocumentMark) -> Color {
        switch mark {
        case .pinned: return Theme.Palette.running
        case .demoted: return Theme.Palette.captionText
        case .stale: return Theme.Palette.attention
        }
    }

    private func documentRow(_ document: DocumentRecord) -> some View {
        let isExpanded = expandedDocumentID == document.id
        let isEditingMetadata = metadataEditorID == document.id

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(document.id)
                    .font(Theme.Font.mono)
                    .foregroundStyle(Theme.Palette.captionText)
                    .copyable(document.id)
                Spacer()
                Button(isExpanded ? String(localized: "Свернуть") : String(localized: "Раскрыть")) {
                    expandedDocumentID = isExpanded ? nil : document.id
                    if !isExpanded {
                        Task { await model.loadVector(for: document, app: app) }
                    }
                }
                .buttonStyle(.link)
                .font(Theme.Font.caption)

                Menu {
                    Button(String(localized: "Изменить текст…")) { model.beginEditing(document, app: app) }
                    Button(String(localized: "Изменить метаданные")) {
                        metadataDraft = MetadataDraft(metadata: document.metadata)
                        metadataEditorID = document.id
                    }
                    Divider()
                    marksMenu(for: document)
                    Divider()
                    Button(String(localized: "Удалить документ"), role: .destructive) {
                        Task { await model.deleteDocument(document, app: app) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(Theme.Font.caption)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 34)
            }

            marksLine(of: document.metadata)

            Text(isExpanded ? (document.document ?? "") : document.preview)
                .font(Theme.Font.body)
                .copyable(document.document ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)

            if isExpanded, let vector = model.vectorPreviews[document.id] {
                vectorPreview(vector)
            }

            // Только если редактор позвали отсюда: тот же id мог прийти
            // из выдачи, и там у него своя строка и своя коллекция.
            if marksEditorID == document.id, !marksEditorFromHit {
                marksEditor(for: document)
            }

            if isEditingMetadata {
                metadataEditor(for: document)
            } else if isExpanded {
                // Метаданные — по «Раскрыть», вместе с полным текстом.
                // Двадцать строк `chunk_index`, `content_hash`, `file_mtime`
                // у **каждого** документа превращали список в простыню, в
                // которой не видно самих документов.
                MetadataTable(metadata: document.metadata)
            } else if let source = document.metadata?["source_file"]?.displayString
                        ?? document.metadata?["file_name"]?.displayString {
                // Одна строка вместо двадцати: откуда документ — то
                // единственное из метаданных, что нужно, не раскрывая.
                Text(source)
                    .font(Theme.Font.mono)
                    .foregroundStyle(Theme.Palette.captionText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row))
    }

    /// Raw vectors are unreadable, so only the size and the first components
    /// are shown — enough to tell two models apart at a glance.
    private func vectorPreview(_ vector: [Double]) -> some View {
        let preview = vector.prefix(8).map { String(format: "%.4f", $0) }.joined(separator: ", ")
        // Built as a String first: an interpolated ternary makes the compiler
        // hesitate between Text(String) and Text(LocalizedStringKey).
        let line: String = "[" + preview + (vector.count > 8 ? ", …" : "") + "]"
        // String.init is heavily overloaded; spelling the conversion out keeps
        // type inference (and the .font modifier below) unambiguous.
        let fullVector: String = vector.map { value in String(value) }.joined(separator: ", ")
        return VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "вектор: размерность \(vector.count.plainDigits), первые \(min(8, vector.count)) компонент"))
                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
            Text(line)
                .font(Theme.Font.mono)
                .foregroundStyle(Theme.Palette.captionText)
                .copyable(fullVector)
        }
    }

    private func metadataEditor(for document: DocumentRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($metadataDraft.rows) { $row in
                if MetadataDraft.isReserved(row.key) {
                    HStack(spacing: 6) {
                        Text(row.key).font(Theme.Font.mono).foregroundStyle(Theme.Palette.captionText)
                        Text(row.value).font(Theme.Font.mono).foregroundStyle(Theme.Palette.captionText)
                        Image(systemName: "lock").font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                            .help(String(localized: "Поле ведёт приложение: правка вручную сломала бы привязку модели"))
                    }
                } else {
                    HStack(spacing: 6) {
                        TextField(String(localized: "ключ"), text: $row.key)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                        TextField(String(localized: "значение"), text: $row.value)
                            .textFieldStyle(.roundedBorder)
                        Button(role: .destructive) {
                            metadataDraft.remove(row)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            HStack {
                Button {
                    metadataDraft.addRow()
                } label: {
                    Label(String(localized: "Поле"), systemImage: "plus")
                }
                Spacer()
                Button(String(localized: "Отмена")) { metadataEditorID = nil }
                    .buttonStyle(.chromaNormal)
                Button(String(localized: "Сохранить")) {
                    Task {
                        await model.saveMetadataOnly(for: document, draft: metadataDraft, app: app)
                        metadataEditorID = nil
                    }
                }
                .buttonStyle(.chromaPrimary)
            }
            Text(String(localized: "Вектор не пересчитывается: меняются только метаданные."))
                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Sheets

    private var documentSheet: some View {
        SheetShell(
            title: model.isEditingExistingDocument
                ? String(localized: "Изменить документ")
                : String(localized: "Добавить документ"),
            subtitle: String(localized: "Один документ — один вектор."),
            help: String(localized: "Вектор считается моделью коллекции при сохранении. У изменённого документа он пересчитывается: ChromaDB не обновляет его сама, и поиск указывал бы на старый текст. Длина текста сверяется с контекстом модели — LM Studio отвечает успехом на текст любого размера и молча векторизует только его начало."),
            width: 640,
            height: 720
        ) {
            SectionCard(
                title: String(localized: "Текст"),
                subtitle: String(localized: "То, что станет вектором и найдётся поиском.")
            ) {
                VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                    TextEditor(text: $model.documentText)
                        .font(Theme.Font.body)
                        .frame(height: 170)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.field)
                                .strokeBorder(Theme.Palette.border, lineWidth: 1)
                        )

                    // Length against the model's context: LM Studio answers 200 for a
                    // text of any size and silently embeds only its beginning.
                    if let message = model.documentContextVerdict.message {
                        Text(message)
                            .font(Theme.Font.caption)
                            .foregroundStyle(model.documentContextVerdict.blocksSending
                                             ? Theme.Palette.danger : Theme.Palette.attention)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        TextField(String(localized: "ID (необязательно — иначе UUID)"), text: $model.documentID)
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.isEditingExistingDocument)
                        Button(String(localized: "Текст из файла…")) { model.loadDocumentTextFromFile() }
                            .buttonStyle(.chromaSecondary)
                    }
                }
            }

            SectionCard(
                title: String(localized: "Метаданные"),
                subtitle: model.schema(for: model.selected, app: app).map {
                    String(localized: "По схеме коллекции: полей \($0.fields.count).")
                } ?? String(localized: "Схемы у коллекции нет — поля произвольные.")
            ) {
            VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                ForEach($model.documentMetadata.rows) { $row in
                    let field = model.schema(for: model.selected, app: app)?.field(for: row.key.trimmingCharacters(in: .whitespaces))
                    HStack(spacing: 6) {
                        TextField(String(localized: "ключ"), text: $row.key)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                            .disabled(MetadataDraft.isReserved(row.key) || field != nil)
                        TextField(field.map { "\($0.type.hint)" } ?? String(localized: "значение"), text: $row.value)
                            .textFieldStyle(.roundedBorder)
                            .disabled(MetadataDraft.isReserved(row.key))
                        if let field {
                            Text(field.isRequired ? String(localized: "обяз., \(field.type.title)") : field.type.title)
                                .font(Theme.Font.micro)
                                .foregroundStyle(field.isRequired ? Theme.Palette.attention : Theme.Palette.captionText)
                                .frame(width: 120, alignment: .leading)
                        }
                        Button {
                            model.documentMetadata.remove(row)
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(Theme.Palette.captionText)
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Убрать поле"))
                        .disabled(MetadataDraft.isReserved(row.key) || field?.isRequired == true)
                    }
                }
                HStack {
                    Button(String(localized: "Добавить поле")) { model.documentMetadata.addRow() }
                        .buttonStyle(.chromaSecondary)
                    Spacer(minLength: 0)
                }

                if !model.documentViolations.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(model.documentViolations) { violation in
                            Text(violation.message)
                                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            }

            // The server would have answered 201 and kept the old document
            //; the choice belongs to the user.
            if let conflict = model.conflictingDocumentID {
                SectionCard(
                    title: String(localized: "Такой документ уже есть"),
                    subtitle: String(localized: "Документ с идентификатором «\(conflict)» уже лежит в коллекции. Сервер бы ответил успехом и оставил прежний.")
                ) {
                    HStack(spacing: 10) {
                        Button(String(localized: "Перезаписать")) {
                            Task { await model.overwriteConflictingDocument(app) }
                        }
                        .buttonStyle(.chromaNormal)
                        Button(String(localized: "Показать существующий")) {
                            Task { await model.revealConflictingDocument(app) }
                        }
                        .buttonStyle(.chromaNormal)
                        Spacer(minLength: 0)
                    }
                }
            }
        } actions: {
            if model.isSavingDocument { ProgressView().controlSize(.small) }
            Button(String(localized: "Отмена")) {
                model.showAddDocumentSheet = false
                model.editingDocumentID = nil
            }
            .buttonStyle(.chromaNormal)
            Button(model.isEditingExistingDocument ? String(localized: "Сохранить") : String(localized: "Добавить")) {
                Task { await model.saveDocument(app) }
            }
            .buttonStyle(.chromaPrimary)
            .disabled(model.isSavingDocument || model.documentContextVerdict.blocksSending)
        }
    }

    private var importSheet: some View {
        SheetShell(
            title: String(localized: "Импорт документов"),
            subtitle: model.importTable.map { table in
                String(localized: "\(model.importFileName) · \(table.format.title) · строк: \(table.rowCount), колонок: \(table.columns.count)")
            } ?? String(localized: "Строка таблицы становится документом коллекции."),
            help: String(localized: "Одна строка файла — один документ: колонка текста становится телом документа, остальные выбранные колонки — его метаданными. Вектор считается моделью коллекции при записи, поэтому импорт идёт со скоростью модели. Строку длиннее контекста модели приложение не записывает и называет её отдельно.")
        ) {
            if let table = model.importTable {
                SectionCard(
                    title: String(localized: "Колонки"),
                    subtitle: String(localized: "Что станет текстом документа, что — его идентификатором и метаданными.")
                ) {
                    VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                HStack(spacing: 16) {
                    HStack {
                        Text(String(localized: "Текст документа"))
                        Picker("", selection: $model.importMapping.documentColumn) {
                            ForEach(table.columns, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }
                    HStack {
                        Text("ID")
                        Picker("", selection: Binding(
                            get: { model.importMapping.idColumn ?? "" },
                            set: { model.importMapping.idColumn = $0.isEmpty ? nil : $0 }
                        )) {
                            Text(String(localized: "генерировать")).tag("")
                            ForEach(table.columns, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }
                    Spacer()
                }

                Text(String(localized: "В метаданные:"))
                    .font(Theme.Font.control).foregroundStyle(Theme.Palette.secondaryText)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading) {
                    ForEach(table.columns, id: \.self) { column in
                        Toggle(column, isOn: Binding(
                            get: { model.importMapping.metadataColumns.contains(column) },
                            set: { isOn in
                                if isOn { model.importMapping.metadataColumns.insert(column) }
                                else { model.importMapping.metadataColumns.remove(column) }
                            }
                        ))
                        .font(Theme.Font.control)
                        .disabled(column == model.importMapping.documentColumn)
                    }
                }

                importPreview(table)
                    }
                }
            }

            // Chosen before the run, not asked about halfway through.
            SectionCard(
                title: String(localized: "Если ID уже есть"),
                subtitle: model.importDuplicatePolicy.explanation
            ) {
                Picker("", selection: $model.importDuplicatePolicy) {
                    ForEach(DuplicatePolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(model.isImporting)
            }

            // the queue is the only place progress lives. Читает её
            // отдельная маленькая вьюха — тело этого экрана не должно
            // перестраиваться от каждого сообщения о прогрессе.
            QueueProgressRow(titlePrefix: "Импорт в")
            if model.importSkippedInvalid > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "Пропущено по схеме: \(model.importSkippedInvalid) строк"))
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                    ForEach(model.importViolations.prefix(5)) { violation in
                        Text("• \(violation.message)").font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            if let summary = model.importSummary {
                MessageBanner(
                    kind: .success,
                    text: String(localized: "Записано \(summary.written), пропущено пустых строк \(summary.skippedEmpty), модель \(summary.model), размерность \(summary.dimension.plainDigits), за \(String(format: "%.1f", summary.duration)) с.")
                )
                if !summary.skippedDuplicates.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "Пропущено строк с существующими ID: \(summary.skippedDuplicates.count)"))
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                        Text(summary.skippedDuplicates.prefix(8).joined(separator: ", "))
                            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !summary.skippedTooLong.isEmpty {
                    // Named, not counted away: a row that was skipped is a row
                    // the user has to do something about.
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "Не записано строк длиннее контекста модели: \(summary.skippedTooLong.count)"))
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                        Text(summary.skippedTooLong.prefix(8).joined(separator: ", "))
                            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        } actions: {
            if let resumePoint = model.importResumePoint, !model.isImporting {
                Text(String(localized: "Записано \(resumePoint) — остальное можно дописать"))
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.isImporting {
                Button(String(localized: "Отменить")) { model.cancelImport() }
                    .buttonStyle(.chromaNormal)
            } else {
                Button(String(localized: "Закрыть")) { model.showImportSheet = false }
                    .buttonStyle(.chromaNormal)
                if model.importResumePoint != nil {
                    Button(String(localized: "Продолжить с места сбоя")) { model.runImport(app, resume: true) }
                        .buttonStyle(.chromaPrimary)
                } else {
                    Button(String(localized: "Импортировать")) { model.runImport(app) }
                        .buttonStyle(.chromaPrimary)
                        .disabled(model.importTable == nil || model.importMapping.documentColumn.isEmpty)
                }
            }
        }
    }

    private func importPreview(_ table: ImportTable) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Предпросмотр первых строк")).font(Theme.Font.control)
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(table.preview(5).enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 10) {
                            Text(row[model.importMapping.documentColumn] ?? "")
                                .lineLimit(1)
                                .frame(width: 300, alignment: .leading)
                            if let idColumn = model.importMapping.idColumn {
                                Text("id: \(row[idColumn] ?? "")").foregroundStyle(Theme.Palette.captionText).lineLimit(1)
                            }
                            Text(model.importMapping.metadataColumns.sorted()
                                .compactMap { key in (row[key]?.isEmpty == false) ? "\(key)=\(row[key] ?? "")" : nil }
                                .joined(separator: " · "))
                                .foregroundStyle(Theme.Palette.captionText)
                                .lineLimit(1)
                        }
                        .font(Theme.Font.mono)
                    }
                }
                .padding(6)
            }
            .frame(height: 110)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Вкладка «Правила»: схема и соответствие ей — две разные карточки.
    ///
    /// Была одна, и в ней вперемешку лежали редактор полей, проверка
    /// документов, экспорт схемы файлом, её удаление и кнопки «Отмена /
    /// Сохранить» — пять несвязанных дел в столбик. Разложено по вопросам:
    /// «как должно быть», «а как на самом деле» и «редкое».
    private func schemaCard(_ collection: ChromaCollection) -> some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            SectionCard(
                title: String(localized: "Схема метаданных"),
                subtitle: String(localized: "Какие поля обязательны, какого они типа и что подставляется по умолчанию."),
                help: String(localized: "У ChromaDB нет собственных схем, поэтому правила хранит приложение. Они применяются и к документам, добавленным вручную, и к тем, что приходят из источников: модель правил одна.")
            ) {
                schemaFields
            }

            complianceCard

            AdvancedSection(place: "collection.schema", title: String(localized: "Схема файлом")) {
                HStack(spacing: 8) {
                    Button(String(localized: "Экспорт…")) { model.exportSchema(app) }
                        .buttonStyle(.chromaNormal)
                    Button(String(localized: "Импорт…")) { model.importSchema(app) }
                        .buttonStyle(.chromaNormal)
                    Spacer()
                    if schemaStore.hasSchema(for: model.schemaDraft.collectionName) {
                        Button(String(localized: "Удалить схему")) { model.deleteSchema(app) }
                            .buttonStyle(.chromaDanger)
                    }
                }
                Text("Схему можно перенести на другую машину файлом. Удаление схемы не трогает документы — исчезают только правила.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.captionText)
            }
        }
        .task(id: collection.id) { model.beginEditingSchema(app) }
    }

    /// Поля схемы. Пустая схема — это состояние, а не пустое место: она
    /// значит «метаданные ничем не ограничены», и об этом надо сказать.
    @ViewBuilder
    private var schemaFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.schemaDraft.fields.isEmpty {
                Text("Схемы нет: в метаданных может быть что угодно. Самый быстрый способ начать — собрать черновик по документам, которые уже загружены.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach($model.schemaDraft.fields) { $field in
                    schemaFieldRow($field)
                }
                Toggle(String(localized: "Запретить поля вне схемы"), isOn: Binding(
                    get: { !model.schemaDraft.allowsExtraFields },
                    set: { model.schemaDraft.allowsExtraFields = !$0 }
                ))
                .padding(.top, 4)
            }

            if !model.schemaIssues.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.schemaIssues) { issue in
                        Text("• " + issue.message)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.attention)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack(spacing: 8) {
                Button(String(localized: "Добавить поле")) { model.addSchemaField() }
                    .buttonStyle(.chromaNormal)
                Button(String(localized: "Вывести из документов")) { model.inferSchema(app) }
                    .buttonStyle(model.schemaDraft.fields.isEmpty ? .chromaPrimary : .chromaNormal)
                    .help(String(localized: "Собрать черновик из полей загруженных документов"))
                Spacer()
                // Сохранение — единственная кнопка, меняющая что-то на диске,
                // и потому единственная синяя, когда схема уже не пуста.
                Button(String(localized: "Сохранить")) { model.saveSchema(app) }
                    .buttonStyle(model.schemaDraft.fields.isEmpty ? .chromaNormal : .chromaPrimary)
                    .disabled(model.schemaDraft.fields.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func schemaFieldRow(_ field: Binding<MetadataField>) -> some View {
        HStack(spacing: 8) {
            // Имя поля тянется, остальное фиксировано: сумма жёстких ширин
            // была шире карточки, и строка уезжала за край.
            TextField(String(localized: "поле"), text: field.key)
                .frame(minWidth: 120)
            Picker("", selection: field.type) {
                ForEach(MetadataFieldType.allCases) { type in
                    Text(type.title).tag(type)
                }
            }
            .labelsHidden()
            .frame(width: 140)
            Toggle(String(localized: "обяз."), isOn: field.isRequired)
                .frame(width: 78)
            TextField(String(localized: "по умолчанию"), text: field.defaultValue)
                .frame(width: 140)
            if field.wrappedValue.type == .date {
                Toggle(String(localized: "+unix"), isOn: field.storesTimestamp)
                    .frame(width: 76)
                    .help(String(localized: "Дополнительно писать <поле>_ts числом: ChromaDB не умеет сравнивать ISO-строки через $gt"))
            }
            Button {
                model.removeSchemaField(field.wrappedValue)
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(Theme.Palette.captionText)
            }
            .buttonStyle(.plain)
        }
    }

    /// «А как на самом деле»: соответствие документов схеме.
    ///
    /// Отдельной карточкой, потому что это другой вопрос и другая цена:
    /// проверка читает документы пачками и ничего не меняет.
    private var complianceCard: some View {
        SectionCard(
            title: String(localized: "Соответствие документов"),
            subtitle: String(localized: "Проверка читает документы и сравнивает их со схемой. В базе ничего не меняется.")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button(String(localized: "Проверить документы")) { model.runComplianceCheck(app) }
                        .buttonStyle(.chromaNormal)
                        .disabled(model.isCheckingCompliance || model.schemaDraft.fields.isEmpty)
                    if model.isCheckingCompliance {
                        ProgressView().controlSize(.small)
                        Button(String(localized: "Остановить")) { model.cancelComplianceCheck() }
                            .buttonStyle(.chromaSecondary)
                    }
                    if let progress = model.complianceProgress {
                        Text("проверено \(progress.checked) из \(progress.total)")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.captionText)
                    }
                    Spacer()
                }

                if model.schemaDraft.fields.isEmpty {
                    Text("Пока схемы нет, сравнивать не с чем.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.captionText)
                }

                if let report = model.complianceReport {
                    MessageBanner(
                        kind: report.isClean ? .success : .warning,
                        text: report.isClean
                            ? String(localized: "Проверено \(report.checked) документов — все соответствуют схеме.")
                            : String(localized: "Проверено \(report.checked), не соответствуют \(report.offending).\(report.stoppedEarly ? " Показаны первые нарушения." : "")")
                    )
                    ForEach(report.violations.prefix(20)) { violation in
                        Text("\(violation.documentID ?? "—") · \(violation.message)")
                            .font(Theme.Font.mono)
                            .foregroundStyle(Theme.Palette.secondaryText)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if report.violations.count > 20 {
                        Text("и ещё \((report.violations.count - 20).plainDigits)")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.captionText)
                    }
                }
            }
        }
    }

    private var bindSheet: some View {
        SheetShell(
            title: String(localized: "Модель коллекции"),
            subtitle: String(localized: "Чем считать векторы этой коллекции дальше."),
            help: String(localized: "Приложение не может проверить, какой моделью посчитаны уже существующие векторы, — оно сверяет только размерность. Если она не совпадёт, привязка будет отклонена."),
            width: 560,
            height: nil,
            scrolls: false
        ) {
            Picker(String(localized: "Модель"), selection: $model.bindModelSelection) {
                Text(String(localized: "— выберите —")).tag("")
                ForEach(embeddingsModel.embeddingModels) { item in
                    Text(item.id).tag(item.id)
                }
            }
            .font(Theme.Font.control)

            if embeddingsModel.embeddingModels.isEmpty {
                MessageBanner(
                    kind: .warning,
                    text: String(localized: "Список моделей пуст. Откройте «Модели» и проверьте соединение с LM Studio.")
                )
            }
        } actions: {
            if model.isBinding { ProgressView().controlSize(.small) }
            Button(String(localized: "Отмена")) { model.showBindSheet = false }
                .buttonStyle(.chromaNormal)
            Button(String(localized: "Привязать")) {
                Task { await model.bindModel(app) }
            }
            .buttonStyle(.chromaPrimary)
            .disabled(model.bindModelSelection.isEmpty || model.isBinding)
        }
    }

    private var deleteSheet: some View {
        SheetShell(
            title: String(localized: "Удалить коллекцию"),
            subtitle: model.selected.map {
                String(localized: "Будут удалены все документы и векторы коллекции «\($0.name)».")
            } ?? String(localized: "Коллекция не выбрана."),
            width: 520,
            height: nil,
            scrolls: false
        ) {
            if let collection = model.selected {
                // a collection delete is reversible exactly like a single
                // document's, as long as the trash is on — said here rather
                // than implied, since «отменить это нельзя» would now be wrong.
                Text(settings.configuration.trashEnabled
                     ? String(localized: "Документы сохранятся в «Корзине» и их можно будет восстановить.")
                     : String(localized: "Корзина выключена в настройках — отменить это будет нельзя."))
                    .font(Theme.Font.body)
                    .foregroundStyle(settings.configuration.trashEnabled ? Theme.Palette.primaryText : Theme.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)

                Text(String(localized: "Введите имя коллекции для подтверждения:"))
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                TextField(collection.name, text: $model.deleteConfirmationText)
                    .textFieldStyle(.roundedBorder)

                if model.isCapturingTrash {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(String(localized: "Сохраняем документы в корзину…")).font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    }
                }
            }
        } actions: {
            Button(String(localized: "Отмена")) { model.showDeleteSheet = false }
                .buttonStyle(.chromaNormal)
                .disabled(model.isCapturingTrash)
            Button(String(localized: "Удалить")) {
                Task { await model.deleteSelected(app) }
            }
            .buttonStyle(.chromaDanger)
            .disabled(model.selected.map { model.deleteConfirmationText != $0.name } ?? true
                      || model.isCapturingTrash)
        }
    }

    private var resetSheet: some View {
        SheetShell(
            title: String(localized: "Сброс базы"),
            subtitle: String(localized: "Будут удалены все коллекции и документы этой базы."),
            width: 520,
            height: nil,
            scrolls: false
        ) {
            if let note = model.resetAvailability(app) {
                MessageBanner(kind: .warning, text: note)
            }

            Text(String(localized: "Введите СБРОС для подтверждения:"))
                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
            TextField("СБРОС", text: $model.resetConfirmationText)
                .textFieldStyle(.roundedBorder)
        } actions: {
            Button(String(localized: "Отмена")) { model.showResetSheet = false }
                .buttonStyle(.chromaNormal)
            Button(String(localized: "Сбросить")) {
                Task { await model.resetDatabase(app) }
            }
            .buttonStyle(.chromaDanger)
            .disabled(model.resetConfirmationText != "СБРОС")
        }
    }
}
